import Foundation
import CryptoKit
import Darwin

struct BuddyWorkerFailure: LocalizedError {
    let message: String
    /// What kind of refusal this is, so a caller can tell "wrong input" from "needs the user" from "retry": failed, invalid_input, not_authorized,
    /// not_found, conflict, needs_user, outside_approved_scope or unsupported_in_background.
    var code = "failed"
    var retryable = false
    var errorDescription: String? { message }
}

/// Who may act on another agent's work: the agent itself, the team's supervisor, or the agent that manages it. Read from native state only,
/// never from prompt text.
enum BuddyAuthority {
    static func may(_ actor: String, actOn target: String, state: [String: Any], supervisor: String?) -> Bool {
        guard !actor.isEmpty else { return false }
        return actor == target || supervisor == actor
            || (state["agents"] as? [[String: Any]] ?? []).contains { $0["id"] as? String == target && $0["managedBy"] as? String == actor }
    }
}

enum BuddyRoutineAuthorization {
    static func owner(_ args:[String:Any],actor:String,runID:String,text:String,state:[String:Any])throws->String {
        let target=args["agentId"] as? String ?? actor
        let creating = ["create", ""].contains(args["action"] as? String ?? "")
        guard target != actor else{return actor}
        let agents=state["agents"] as? [[String:Any]] ?? []
        guard let agent=agents.first(where:{$0["id"] as? String==target}),agents.contains(where:{$0["id"] as? String==actor}),
              let run=(state["runs"] as? [String:[String:Any]])?[runID],["starting","answering"].contains(run["status"] as? String ?? ""),
              let chat=run["target"] as? String,(chat==actor || (state["groups"] as? [[String:Any]] ?? []).contains(where:{$0["id"] as? String==chat && ($0["members"] as? [String] ?? []).contains(actor)})),
              let user=run["userId"] as? String,((state["messages"] as? [String:[[String:Any]]])?[chat] ?? []).contains(where:{$0["id"] as? String==user && $0["who"] as? String=="you" && $0["body"] as? String==text}),
              let quote=args["authorizationQuote"] as? String,quote.count>=3,BuddyAgentChanges.normalized(text).contains(BuddyAgentChanges.normalized(quote)),
              // Only starting a routine for someone else has to sound like scheduling; pausing, resuming, changing or deleting one only has to be asked.
              !creating || (text.range(of:#"(?i)\b(?:every|each|daily|weekly|weekdays|routine|schedule|interval|same.{0,25}checks)\b"#,options:.regularExpression) != nil
                 && text.range(of:#"(?i)\b(?:hypothetical|example|don't|do not|never)\b|```"#,options:.regularExpression)==nil) else{throw BuddyWorkerFailure(message:"Scheduling for another agent needs the user's current delegation request.")}
        let name=agent["name"] as? String ?? ""
        let named = !name.isEmpty && text.range(of:name,options:.caseInsensitive) != nil
        guard agent["managedBy"] as? String==actor || named else{throw BuddyWorkerFailure(message:"Choose the teammate named in the user's request.")}
        return target
    }
}

/// Which model a scheduled run uses. A routine pins its provider when it is saved, so it never switches provider on its own (only "Switch all agents"
/// moves it, see `BuddyRoutineStore.follow`); the model is the agent's. An
/// inbox agent switched to a small model kept running its scheduled scans on the larger one it had when they were saved, at many times the cost.
enum BuddyRoutineModel {
    static func resolve(pinned:String?,provider:String,current:(provider:String,model:String)?)->String? {
        guard let current,current.provider==provider,!current.model.isEmpty else {return pinned}
        return current.model
    }
}

/// Which scheduled email checks have nothing to tell the person. A check that found nothing new, while the open items were already brought up today, is silent: it
/// is still saved in Background work, but it sends no message, no notification and is not news to the team's oversight. A check that fails the same way it just
/// did (the same wall every time) is said once, then again only after the reminder interval.
enum BuddyEmailPacing {
    static func quietJobs(_ jobs:[[String:Any]])->Set<String> {
        let stamp=ISO8601DateFormatter()
        func date(_ value:Any?)->Date {(value as? String).flatMap{stamp.date(from:$0)} ?? .distantPast}
        func gist(_ text:String)->String {text.lowercased().filter{$0.isLetter || $0==" "}.split(separator:" ").joined(separator:" ")}
        var quiet=Set<String>(),told=[String:Date]()
        let runs=jobs.filter{$0["kind"] as? String=="email" && ($0["routineSeriesID"] ?? $0["routineID"]) != nil}.sorted{date($0["createdAt"])<date($1["createdAt"])}
        for job in runs {
            let id=job["id"] as? String ?? "",series=(job["routineSeriesID"] ?? job["routineID"]) as? String ?? ""
            switch job["status"] as? String ?? "" {
            case "completed": if job["emailPacing"] as? String=="quiet" {quiet.insert(id)}
            case "failed":
                let key=series+"|"+gist(job["progress"] as? String ?? ""),at=date(job["createdAt"])
                if let last=told[key],at.timeIntervalSince(last)<20*3600 {quiet.insert(id)} else {told[key]=at}
            default: break
            }
        }
        return quiet
    }
}

enum BuddyWorkerLiveness {
    static func stalled(status:String,lastActivity:Date,now:Date=Date(),timeout:TimeInterval=180)->Bool {
        // Waiting for an actual human review or private sign-in is not a stalled model.
        ["starting","running"].contains(status) && now.timeIntervalSince(lastActivity)>timeout
    }
    /// The host ticks every second, so a gap far longer than that means the Mac was asleep (or this process was frozen) between two ticks.
    /// Returns how long, or 0 for an ordinary tick.
    static func asleep(since previous:Date,now:Date,tolerance:TimeInterval=20)->TimeInterval {
        let gap=now.timeIntervalSince(previous);return gap>tolerance ? gap : 0
    }
    /// Moves a start or activity time forward by the time spent asleep, never past `now`, so that sleeping is not counted as silence.
    static func creditingSleep(_ moment:Date,gap:TimeInterval,now:Date)->Date { min(moment.addingTimeInterval(gap),now) }
}

enum BuddyWorkerMailCompletion {
    static func normalizeLedger(_ args:[String:Any],job:[String:Any],startedAt:Date)->[String:Any] {
        guard args["path"] as? String=="agentmail-review.json",args["folderId"]==nil || args["folderId"] as? String==job["id"] as? String,let execution=job["executionRunID"] as? String,let content=args["content"] as? String,let data=content.data(using:.utf8),data.count<=256000,var ledger=try? JSONSerialization.jsonObject(with:data) as? [String:Any],let url=ledger["mailboxURL"] as? String,let page=(job["browserPages"] as? [[String:Any]])?.last(where:{$0["url"] as? String==url && $0["runID"] as? String==execution}),let stamp=page["at"] as? String,let time=ISO8601DateFormatter().date(from:stamp),time>=startedAt.addingTimeInterval(-1) else{return args}
        // Timestamps come from the browser receipt, never the model's clock.
        ledger["checkedAt"]=stamp;ledger["timestampSource"]="native-browser";ledger["nativeRunID"]=execution
        guard let saved=try? JSONSerialization.data(withJSONObject:ledger,options:[.sortedKeys]),let text=String(data:saved,encoding:.utf8) else{return args}
        var result=args;result["content"]=text;return result
    }
    static func issue(_ job:[String:Any],directory:URL,startedAt:Date,now:Date=Date())->String? {
        guard job["kind"] as? String=="email",job["browserOrigin"] as? String=="https://console.agentmail.to" else{return nil}
        guard !(job["browserPages"] as? [[String:Any]] ?? []).isEmpty else{return (job["browserError"] as? String).flatMap{$0.isEmpty ? nil:$0} ?? "AgentMail was not checked. No authenticated mailbox page was read."}
        let file=directory.appendingPathComponent("Files/agentmail-review.json")
        guard let data=try? Data(contentsOf:file),data.count<=256000,let ledger=try? JSONSerialization.jsonObject(with:data) as? [String:Any],ledger["complete"] as? Bool==true,ledger["timestampSource"] as? String=="native-browser",let execution=job["executionRunID"] as? String,ledger["nativeRunID"] as? String==execution,let checked=ledger["checkedAt"] as? String,let url=ledger["mailboxURL"] as? String,(job["browserPages"] as? [[String:Any]] ?? []).contains(where:{$0["runID"] as? String==execution && $0["url"] as? String==url && $0["at"] as? String==checked}),let time=ISO8601DateFormatter().date(from:checked),time>=startedAt.addingTimeInterval(-1),time<=now.addingTimeInterval(120),ledger["messages"] is [[String:Any]] else{return "AgentMail review is incomplete. The scan has not been marked successful; its source ledger must be finished."}
        return nil
    }
}

enum BuddyWorkerSignInPolicy {
    static func reuseGoogle(job:[String:Any],plan:[String:Any],jobs:[[String:Any]])->Bool {
        guard plan["mode"] as? String=="signin",plan["googleAvailable"] as? Bool==true,let origin=plan["origin"] as? String,let url=URL(string:origin),url.scheme=="https",url.host != nil,let workspace=job["workspace"] as? String,let agent=(job["browserAgentId"] ?? job["agentId"]) as? String,job["browserOrigin"]==nil || job["browserOrigin"] as? String==origin else{return false}
        return jobs.contains{prior in
            prior["workspace"] as? String==workspace && prior["agentId"] as? String==agent && (prior["reviews"] as? [[String:Any]] ?? []).contains{review in
                review["kind"] as? String=="authentication" && review["mode"] as? String=="signin" && review["origin"] as? String==origin && review["status"] as? String=="completed" && review["authAction"] as? String=="saved"
            }
        }
    }
}

enum BuddyWorkerWire {
    static let maximumBytes = 8 * 1024 * 1024
    static func directory(_ support: URL) -> URL {
        let digest = SHA256.hash(data: Data(support.standardizedFileURL.path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("buddy-worker-\(getuid())-\(digest)", isDirectory: true)
    }
    static func socketURL(_ support: URL) -> URL { directory(support).appendingPathComponent("control.sock") }
    static func address(_ url: URL) throws -> sockaddr_un {
        var value = sockaddr_un(); value.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(url.path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: value.sun_path) else { throw BuddyWorkerFailure(message: "Buddy’s worker socket path is too long.") }
        withUnsafeMutableBytes(of: &value.sun_path) { target in target.copyBytes(from: bytes) }
        value.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return value
    }
    static func send(_ value: [String: Any], to fd: Int32) throws {
        var data = try JSONSerialization.data(withJSONObject: value)
        guard data.count <= maximumBytes else { throw BuddyWorkerFailure(message: "This worker response is too large. Open its files instead.") }
        data.append(10)
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), data.count - offset) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw BuddyWorkerFailure(message: "The worker connection closed. Check task status before retrying.") }; offset += count
        }
    }
    static func receive(_ fd: Int32) throws -> [String: Any] {
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65536)
        while data.count <= maximumBytes {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw BuddyWorkerFailure(message: "The worker did not confirm the request. Check its task list before retrying.") }
            if let end = buffer.prefix(count).firstIndex(of: 10) {
                data.append(contentsOf: buffer.prefix(end))
                guard data.count <= maximumBytes, let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw BuddyWorkerFailure(message: "The worker returned an invalid response.") }; return result
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        throw BuddyWorkerFailure(message: "The worker message exceeded its size limit.")
    }
    static func timeouts(_ fd: Int32) {
        var timeout = timeval(tv_sec: 8, tv_usec: 0), noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
    }
    static func call(support: URL, request: [String: Any]) throws -> [String: Any] {
        let url = socketURL(support), fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BuddyWorkerFailure(message: "Couldn’t open the worker connection.") }; defer { Darwin.close(fd) }
        var parentMeta = stat()
        guard lstat(url.deletingLastPathComponent().path, &parentMeta) == 0, (parentMeta.st_mode & S_IFMT) == S_IFDIR, parentMeta.st_uid == getuid(), parentMeta.st_mode & 0o077 == 0 else { throw BuddyWorkerFailure(message: "The worker’s private connection is unavailable.") }
        var meta = stat()
        guard lstat(url.path, &meta) == 0, (meta.st_mode & S_IFMT) == S_IFSOCK, meta.st_uid == getuid(), meta.st_mode & 0o077 == 0 else { throw BuddyWorkerFailure(message: "Buddy’s background worker is offline. Start it from Background work.") }
        var address = try self.address(url); timeouts(fd)
        let code = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard code == 0 else { throw BuddyWorkerFailure(message: "Buddy’s background worker is offline. Start it from Background work.") }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { throw BuddyWorkerFailure(message: "The worker connection belongs to another account.") }
        try send(request, to: fd); let result = try receive(fd)
        if let error = result["error"] as? String { throw BuddyWorkerFailure(message: error) }; return result
    }
}

/// One entry in a task's history. `id` orders events across all tasks; `seq` orders one task's events and never skips a number.
struct BuddyTaskEvent {
    let id: Int64, taskID: String, seq: Int, type: String, cause: String, correlation: String, attempt: Int?, payload: [String: Any], at: String
}

/// An action that needed the user's approval. `state` runs proposed, approved, dispatched, then confirmed or uncertain;
/// declined, expired, not_sent and failed are the other ways it ends.
struct BuddyAction {
    let id: String, taskID: String, attempt: Int, runID: String, kind: String, tool: String, payloadHash: String, state: String
    let proposedAt: String, dispatchedAt: String?, finishedAt: String?, late: Bool, resolvedBy: String, receipt: [String: Any]
}

/// Exclusive use of a resource (a browser profile). `generation` goes up every time the resource changes hands, so a holder whose lease
/// was taken over can be recognised by its old number.
struct BuddyLease: Equatable {
    let resource: String, generation: Int64, holder: String
}

/// One try at a task. `outcome` is nil while the attempt is still going. `result` is what the task's result said when this attempt ended, so a
/// later attempt can never erase what an earlier one found.
struct BuddyAttempt {
    let taskID: String, number: Int, runID: String, provider: String, model: String, startedAt: String, endedAt: String?, outcome: String?
    var result: String? = nil
}

@MainActor final class BuddyWorkerStore {
    let directory: URL
    private let db: BuddyOperationsDB
    private(set) var jobs: [[String: Any]]
    private(set) var paused: Bool
    static let interrupted = Set(["running", "waiting_review", "stopping"])
    static let terminal = Set(["completed", "cancelled"])
    /// The tasks that count against the limit on unfinished work: those the worker is doing or will do. A failed or interrupted run occupies
    /// nothing until someone resumes it, so a string of failed scans can never stop new work being accepted. A paused task still counts, as it
    /// is meant to carry on.
    static let occupying: Set<String> = ["queued", "starting", "running", "waiting_review", "waiting_user", "paused"]
    /// Finished tasks are set aside once the history gets long, so a routine that runs every hour never fills it up. They stay in the database.
    static let archiveTrigger = 900, archiveKeep = 600, archiveSizeTrigger = 24 * 1024 * 1024
    /// One task may not grow past this, however long its history gets.
    static let rowLimit = 16 * 1024 * 1024
    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        db = try BuddyOperationsDB(directory: directory)
        try BuddyOperationsMigration.importLegacy(into: db, directory: directory)
        let tasks = try db.rows("SELECT body FROM tasks WHERE archived = 0 ORDER BY seq").compactMap { $0.first?.string }.map(BuddyOperationsDB.decode)
        guard tasks.count <= 1000, tasks.allSatisfy({ ($0["id"] as? String).flatMap(UUID.init(uuidString:)) != nil && ($0["workspace"] as? String).flatMap(UUID.init(uuidString:)) != nil }), Set(tasks.compactMap { $0["id"] as? String }).count == tasks.count else { throw BuddyWorkerFailure(message: "Buddy couldn’t verify its saved background tasks. Your chats and files are not affected. Don’t delete anything in Application Support/Buddy/Worker; ask Claude Code to repair it.") }
        jobs = tasks; paused = try db.meta("paused") == "1"
        if jobs.count > Self.archiveTrigger { try? archiveFinished(keeping: Self.archiveKeep) }
        try recordBaseline()
        try recordBudgetBaseline()
        try reconcileDecisions()
        try backfillActions()
        var interrupted: [(old: [String: Any], new: [String: Any])] = []
        let today = BuddyBudget.day(Date()), restartedAt = Self.stamp()
        for i in jobs.indices where Self.interrupted.contains(jobs[i]["status"] as? String ?? "") {
            let before = jobs[i]
            let rows = try actionStates(of: jobs[i]["id"] as? String ?? "")
            let reviews = Self.settled(jobs[i]["reviews"] as? [[String: Any]] ?? [], rows: rows, pending: "expired")
            jobs[i]["reviews"] = reviews
            let unsure = reviews.filter { $0["status"] as? String == "uncertain" }
            jobs[i]["status"] = "interrupted"
            jobs[i]["stopCause"] = "worker.restart"
            if unsure.isEmpty {
                // Nothing can have been sent, so the work is continued by itself from its saved progress (the host does it, a few times a day).
                let prior = before["recovery"] as? [String: Any]
                let tries = prior?["cause"] as? String == "worker.restart" && prior?["day"] as? String == today ? (prior?["tries"] as? Int ?? 0) : 0
                jobs[i]["recovery"] = ["cause": "worker.restart", "state": "pending", "tries": tries, "day": today, "nextAt": restartedAt]
                jobs[i]["progress"] = "The worker restarted. Buddy will continue this task automatically from its saved progress."
            } else {
                jobs[i]["progress"] = "The worker restarted while \(Self.describe(unsure)) may have been sent. Check whether it went through before continuing. Nothing was automatically retried."
            }
            interrupted.append((before, jobs[i]))
        }
        if !interrupted.isEmpty { try db.transaction { for change in interrupted { try Self.commit(change.new, from: change.old, cause: "worker.restart", in: db) } } }
        try pruneEvents()
    }
    /// Sets the oldest completed or cancelled tasks aside, leaving `keep` tasks in the list. Nothing is deleted: they stay in the database,
    /// marked as archived, and come back with `archivedJobs()`. A task that needs attention stays in the list, and so does the newest task of
    /// every routine, because the next run builds on its result. The move is one transaction, so a task is never in neither place.
    @discardableResult func archiveFinished(keeping keep: Int) throws -> Int {
        guard jobs.count > keep else { return 0 }
        func routineKey(_ job: [String: Any]) -> String? {
            guard let routine = (job["routineSeriesID"] ?? job["routineID"]) as? String else { return nil }
            return (job["workspace"] as? String ?? "") + "|" + (job["agentId"] as? String ?? "") + "|" + routine
        }
        var newest = Set<String>(), seen = Set<String>()
        for job in jobs.reversed() { if let key = routineKey(job), seen.insert(key).inserted, let id = job["id"] as? String { newest.insert(id) } }
        var excess = jobs.count - keep; var moved: [[String: Any]] = [], kept: [[String: Any]] = []
        for job in jobs {
            if excess > 0, Self.terminal.contains(job["status"] as? String ?? ""), !newest.contains(job["id"] as? String ?? "") { moved.append(job); excess -= 1 } else { kept.append(job) }
        }
        guard !moved.isEmpty else { return 0 }
        try db.transaction {
            for job in moved {
                try db.run("UPDATE tasks SET archived = 1, version = version + 1 WHERE id = ?", [.text(job["id"] as? String ?? "")])
                try Self.appendEvent("task.archived", task: job, attempt: job["attempt"] as? Int, cause: "history.limit", payload: ["status": job["status"] as? String ?? ""], in: db)
            }
        }
        jobs = kept
        return moved.count
    }
    /// Tasks that were set aside, oldest first.
    func archivedJobs() throws -> [[String: Any]] {
        try db.rows("SELECT body FROM tasks WHERE archived = 1 ORDER BY seq").compactMap { $0.first?.string }.map(BuddyOperationsDB.decode)
    }
    /// How much room the tasks in the list take, in bytes.
    var liveBytes: Int { Int((try? db.rows("SELECT COALESCE(SUM(length(CAST(body AS BLOB))), 0) FROM tasks WHERE archived = 0").first?.first?.int) ?? 0) }
    private static func row(_ job: [String: Any]) throws -> (id: String, body: String) {
        let body = try BuddyOperationsDB.encode(job)
        guard body.utf8.count <= rowLimit else { throw BuddyWorkerFailure(message: "The worker’s saved task history is full.") }
        return (job["id"] as? String ?? "", body)
    }
    static func insert(_ job: [String: Any], archived: Bool, in db: BuddyOperationsDB) throws {
        let (id, body) = try row(job)
        try db.run("INSERT INTO tasks(id, workspace, agent_id, request_id, status, kind, archived, created_at, updated_at, body) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", [
            .text(id), .text(job["workspace"] as? String ?? ""), .text(job["agentId"] as? String ?? ""), .text(job["requestId"] as? String ?? ""),
            .text(job["status"] as? String ?? ""), .text(job["kind"] as? String ?? ""), .int(archived ? 1 : 0), .text(job["createdAt"] as? String ?? ""), .text(job["updatedAt"] as? String ?? ""), .text(body)])
    }
    private static func save(_ job: [String: Any], in db: BuddyOperationsDB) throws {
        let (id, body) = try row(job)
        let changed = try db.run("UPDATE tasks SET status = ?, kind = ?, updated_at = ?, version = version + 1, body = ? WHERE id = ?", [
            .text(job["status"] as? String ?? ""), .text(job["kind"] as? String ?? ""), .text(job["updatedAt"] as? String ?? ""), .text(body), .text(id)])
        guard changed == 1 else { throw BuddyWorkerFailure(message: "This task is unavailable.") }
    }
    func job(_ id: String) throws -> [String: Any] {
        guard let job = jobs.first(where: { $0["id"] as? String == id }) else { throw BuddyWorkerFailure(message: "This background task is unavailable.") }; return job
    }
    /// Money is always kept as decimals. A literal `0` arrives as a whole number, which `as? Double` cannot read back, so a task that had
    /// just been stopped looked as if it still had its whole budget until the worker restarted (and an allowance chosen for it was refused).
    private static let amounts = ["budgetUSD", "remainingBudgetUSD", "reservedBudgetUSD", "uncertainBudgetUSD", "spentUSD"]
    private static func decimals(_ values: [String: Any]) -> [String: Any] {
        var out = values
        for key in amounts { if let whole = out[key] as? Int { out[key] = Double(whole) } }
        return out
    }
    @discardableResult func update(_ id: String, _ values: [String: Any], cause: String = "") throws -> [String: Any] {
        guard let i = jobs.firstIndex(where: { $0["id"] as? String == id }) else { throw BuddyWorkerFailure(message: "This task is unavailable.") }
        let old = jobs[i]
        var merged = old; merged.merge(Self.decimals(values)) { _, new in new }; merged["updatedAt"] = ISO8601DateFormatter().string(from: Date())
        // A copy of a review that arrives late (from the connection service) must not move an action backwards.
        if values["reviews"] != nil { merged = try keepingActionProgress(merged) }
        jobs[i] = merged
        let saved = merged
        // A run that finishes ends the older runs of the same work that stopped without finishing, in the same transaction.
        let stale = Self.superseded(by: saved, from: old, among: jobs)
        do {
            try db.transaction {
                try Self.commit(saved, from: old, cause: cause, in: db)
                for s in stale { try Self.commit(s.new, from: s.old, cause: "superseded", in: db) }
            }
        } catch { jobs[i] = old; throw error }
        for s in stale { jobs[s.index] = s.new }
        return jobs[i]
    }
    /// The older runs of the same work (the same plan task, else the same routine series or routine) that a run finishing now makes stale: ones that
    /// failed, were interrupted or paused, and that left nothing that may have been sent. They become cancelled, saying which run superseded them.
    static func superseded(by new: [String: Any], from old: [String: Any], among jobs: [[String: Any]]) -> [(index: Int, old: [String: Any], new: [String: Any])] {
        guard new["status"] as? String == "completed", old["status"] as? String != "completed" else { return [] }
        func key(_ job: [String: Any]) -> String? {
            if let plan = job["planTaskId"] as? String, !plan.isEmpty { return "plan:" + plan }
            if let routine = (job["routineSeriesID"] ?? job["routineID"]) as? String, !routine.isEmpty { return "routine:" + routine }
            return nil
        }
        guard let mine = key(new), let position = jobs.firstIndex(where: { $0["id"] as? String == new["id"] as? String }) else { return [] }
        let now = stamp()
        return jobs.enumerated().compactMap { i, job in
            guard i < position, job["workspace"] as? String == new["workspace"] as? String, key(job) == mine, ["failed", "interrupted", "paused"].contains(job["status"] as? String ?? ""),
                  !(job["reviews"] as? [[String: Any]] ?? []).contains(where: { ["uncertain", "dispatched"].contains($0["status"] as? String ?? "") }) else { return nil }
            var next = job
            next["status"] = "cancelled"; next["stopCause"] = "superseded"; next["supersededBy"] = new["id"]; next["updatedAt"] = now
            next["progress"] = "Superseded: a later run of the same work finished."
            return (i, job, next)
        }
    }
    func create(workspace: String, agent: String, requestId: String, title: String, goal: String, kind: String, provider: String, budget: Double, model:String?=nil) throws -> [String: Any] {
        guard UUID(uuidString: workspace) != nil, UUID(uuidString: agent) != nil, !requestId.isEmpty, requestId.count <= 200,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 150,
              !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, goal.count <= 30000,
              ["research", "applications", "email", "general", "coding"].contains(kind), ["chatgpt", "claude"].contains(provider), budget.isFinite, budget >= 0, budget <= BuddyRunLimit.none else { throw BuddyWorkerFailure(message: "Add a short task title, a clear brief, and a supported provider.") }
        // The same request again returns the task it already made, marked so the caller can tell (the mark is never saved).
        if let old = jobs.first(where: { $0["workspace"] as? String == workspace && $0["agentId"] as? String == agent && $0["requestId"] as? String == requestId }) { var found = old; found["deduplicated"] = true; return found }
        let heavy = liveBytes > Self.archiveSizeTrigger
        if jobs.count >= Self.archiveTrigger || heavy { try? archiveFinished(keeping: heavy ? 200 : Self.archiveKeep) }
        guard jobs.count < 1000, jobs.filter({ Self.occupying.contains($0["status"] as? String ?? "") }).count < 30 else { throw BuddyWorkerFailure(message: "Finish or cancel some background tasks before adding more.") }
        let now = ISO8601DateFormatter().string(from: Date())
        var job: [String: Any] = ["id": UUID().uuidString, "workspace": workspace, "agentId": agent, "requestId": requestId, "title": title, "goal": goal, "kind": kind, "provider": provider, "budgetUSD": budget, "status": "queued", "progress": "Queued", "createdAt": now, "updatedAt": now, "attempt": 0, "events": [[String: Any]](), "result": "", "files": [[String: Any]]()]
        if let model,!model.isEmpty {guard model.range(of:#"^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$"#,options:.regularExpression) != nil else{throw BuddyWorkerFailure(message:"Invalid task model.")};job["model"]=model}
        let created = job
        jobs.append(job)
        do {
            try db.transaction {
                try Self.insert(created, archived: false, in: db)
                try Self.appendEvent("task.created", task: created, attempt: nil, cause: "request", payload: ["kind": kind, "provider": provider, "status": "queued"], in: db)
                if provider == "claude" { try Self.appendBudget("authorize", amount: budget, task: created, attempt: nil, cause: "request", idem: "created:" + (created["id"] as? String ?? ""), in: db) }
            }
        } catch { jobs.removeLast(); throw error }
        return job
    }
    func setPaused(_ value: Bool) throws {
        let old = paused; paused = value
        do { try db.transaction { try db.setMeta("paused", value ? "1" : "0") } } catch { paused = old; throw error }
    }

    // MARK: history

    /// Statuses that end an attempt. `waiting_review` does not: the attempt is still going and is only waiting for an answer.
    static let attemptEnds: Set<String> = ["completed", "failed", "interrupted", "paused", "cancelled", "waiting_user"]
    /// Past this many events, those of archived tasks are dropped oldest first (never one a consumer has still to receive).
    static var eventLimit = 100_000

    private static func stamp(_ date: Date = Date()) -> String { ISO8601DateFormatter().string(from: date) }

    /// Adds one entry to a task's history, and one outbox row for every registered consumer. The caller's transaction holds both.
    static func appendEvent(_ type: String, task: [String: Any], attempt: Int?, cause: String = "", payload: [String: Any] = [:], in db: BuddyOperationsDB) throws {
        let id = task["id"] as? String ?? ""
        let next = try db.rows("SELECT COALESCE(MAX(seq), 0) + 1 FROM events WHERE task_id = ?", [.text(id)]).first?.first?.int ?? 1
        let attemptColumn: BuddyOperationsDB.Bind
        if let attempt { attemptColumn = .int(Int64(attempt)) } else { attemptColumn = .null }
        try db.run("INSERT INTO events(task_id, seq, type, cause, correlation, attempt, payload, created_at) VALUES(?, ?, ?, ?, ?, ?, ?, ?)",
                   [.text(id), .int(next), .text(type), .text(cause), .text(task["requestId"] as? String ?? ""), attemptColumn, .text(try BuddyOperationsDB.encode(payload)), .text(stamp())])
        try db.run("INSERT INTO outbox(event_id, consumer) SELECT ?, name FROM consumers", [.int(db.lastInsertID)])
    }

    /// Saves a changed task and, in the same transaction, writes what the change meant: an attempt that ended, the new status, an attempt that
    /// began. A change that touches none of those (progress text, a result being built up) writes the row and nothing else.
    private static func commit(_ new: [String: Any], from old: [String: Any], cause: String, in db: BuddyOperationsDB) throws {
        try save(new, in: db)
        let id = new["id"] as? String ?? "", before = old["status"] as? String ?? "", after = new["status"] as? String ?? ""
        let oldAttempt = old["attempt"] as? Int ?? 0, newAttempt = new["attempt"] as? Int ?? 0
        if before != after, attemptEnds.contains(after) {
            // Each attempt keeps its own result, so a later attempt that comes back empty cannot erase what an earlier one found.
            let closed = try db.run("UPDATE attempts SET ended_at = ?, outcome = ?, result = ? WHERE task_id = ? AND outcome IS NULL",
                                    [.text(stamp()), .text(after), .text(String((new["result"] as? String ?? "").suffix(100000))), .text(id)])
            if closed > 0 { try appendEvent("attempt.ended", task: new, attempt: oldAttempt, cause: cause, payload: ["n": oldAttempt, "outcome": after], in: db) }
        }
        if before != after { try appendEvent("task.status", task: new, attempt: newAttempt, cause: cause, payload: ["from": before, "to": after], in: db) }
        if newAttempt > oldAttempt {
            let run = new["executionRunID"] as? String ?? ""
            let opened = try db.run("INSERT OR IGNORE INTO attempts(task_id, n, run_id, provider, model, started_at) VALUES(?, ?, ?, ?, ?, ?)",
                                    [.text(id), .int(Int64(newAttempt)), .text(run), .text(new["provider"] as? String ?? ""), .text(new["model"] as? String ?? ""), .text(stamp())])
            if opened > 0 { try appendEvent("attempt.started", task: new, attempt: newAttempt, cause: cause, payload: ["n": newAttempt, "runID": run], in: db) }
        }
        try syncActions(new, from: old, cause: cause, in: db)
        try syncBudget(new, from: old, cause: cause, in: db)
        try syncDecisions(new, in: db)
    }

    /// Tasks that were already there when history began (a first start after the update) get one starting entry, so every task's
    /// history says where it began.
    private func recordBaseline() throws {
        let missing = try db.rows("SELECT id FROM tasks WHERE archived = 0 AND NOT EXISTS (SELECT 1 FROM events WHERE events.task_id = tasks.id)").compactMap { $0.first?.string }
        guard !missing.isEmpty else { return }
        let byID = Dictionary(jobs.compactMap { job in (job["id"] as? String).map { ($0, job) } }, uniquingKeysWith: { first, _ in first })
        try db.transaction {
            for id in missing { if let job = byID[id] { try Self.appendEvent("task.imported", task: job, attempt: job["attempt"] as? Int, cause: "history.begins", payload: ["status": job["status"] as? String ?? ""], in: db) } }
        }
    }

    private func pruneEvents() throws {
        let total = Int(try db.rows("SELECT COUNT(*) FROM events").first?.first?.int ?? 0)
        guard total > Self.eventLimit else { return }
        try db.transaction {
            let doomed = try db.rows("SELECT e.id FROM events e JOIN tasks t ON t.id = e.task_id WHERE t.archived = 1 AND NOT EXISTS (SELECT 1 FROM outbox o WHERE o.event_id = e.id AND o.delivered_at IS NULL) ORDER BY e.id LIMIT ?", [.int(Int64(total - Self.eventLimit))]).compactMap { $0.first?.int }
            for id in doomed { try db.run("DELETE FROM outbox WHERE event_id = ?", [.int(id)]); try db.run("DELETE FROM events WHERE id = ?", [.int(id)]) }
        }
    }

    private static let eventColumns = "e.id, e.task_id, e.seq, e.type, e.cause, e.correlation, e.attempt, e.payload, e.created_at"
    private static func event(_ row: [BuddyOperationsDB.Column]) -> BuddyTaskEvent? {
        guard row.count == 9, let id = row[0].int, let task = row[1].string, let seq = row[2].int, let type = row[3].string else { return nil }
        return BuddyTaskEvent(id: id, taskID: task, seq: Int(seq), type: type, cause: row[4].string ?? "", correlation: row[5].string ?? "", attempt: row[6].int.map { Int($0) },
                              payload: (try? BuddyOperationsDB.decode(row[7].string ?? "{}")) ?? [:], at: row[8].string ?? "")
    }
    /// A task's history in order, from just after `seq`.
    func history(of taskID: String, after seq: Int = 0) throws -> [BuddyTaskEvent] {
        try db.rows("SELECT \(Self.eventColumns) FROM events e WHERE e.task_id = ? AND e.seq > ? ORDER BY e.seq", [.text(taskID), .int(Int64(seq))]).compactMap(Self.event)
    }
    func attempts(of taskID: String) throws -> [BuddyAttempt] {
        try db.rows("SELECT n, run_id, provider, model, started_at, ended_at, outcome, result FROM attempts WHERE task_id = ? ORDER BY n", [.text(taskID)]).compactMap { row in
            guard let n = row[0].int else { return nil }
            return BuddyAttempt(taskID: taskID, number: Int(n), runID: row[1].string ?? "", provider: row[2].string ?? "", model: row[3].string ?? "", startedAt: row[4].string ?? "", endedAt: row[5].string, outcome: row[6].string, result: row[7].string)
        }
    }
    var eventCount: Int { Int((try? db.rows("SELECT COUNT(*) FROM events").first?.first?.int) ?? 0) }

    // MARK: outbox

    /// Signs a consumer up for events. From then on every new event gets a row for it, written with the event. A consumer that is already
    /// registered is left as it is; `replayHistory` also queues the events that already exist, for a consumer that needs all of them.
    func register(consumer name: String, replayHistory: Bool = false) throws {
        try db.transaction {
            let added = try db.run("INSERT OR IGNORE INTO consumers(name, registered_at) VALUES(?, ?)", [.text(name), .text(Self.stamp())])
            if added > 0, replayHistory { try db.run("INSERT OR IGNORE INTO outbox(event_id, consumer) SELECT id, ? FROM events", [.text(name)]) }
        }
    }
    /// The events a consumer has not handled yet, oldest first.
    func undelivered(for consumer: String, limit: Int = 100) throws -> [BuddyTaskEvent] {
        try db.rows("SELECT \(Self.eventColumns) FROM outbox o JOIN events e ON e.id = o.event_id WHERE o.consumer = ? AND o.delivered_at IS NULL ORDER BY e.id LIMIT ?", [.text(consumer), .int(Int64(limit))]).compactMap(Self.event)
    }
    /// Records that a consumer handled an event. `effect` runs in the same transaction, so an effect on this database and the record that
    /// it happened stand or fall together; if it throws, the event stays waiting. Handling the same event twice does nothing the second
    /// time and returns false. An effect outside this database can still repeat after a crash, so it must treat the event's `id` as its key.
    @discardableResult func deliver(_ event: BuddyTaskEvent, to consumer: String, effect: (BuddyOperationsDB) throws -> Void = { _ in }) throws -> Bool {
        try db.transaction {
            let marked = try db.run("UPDATE outbox SET delivered_at = ? WHERE event_id = ? AND consumer = ? AND delivered_at IS NULL", [.text(Self.stamp()), .int(event.id), .text(consumer)])
            guard marked == 1 else { return false }
            try effect(db)
            return true
        }
    }
    // MARK: actions

    private static let actionRank: [String: Int] = ["proposed": 1, "approved": 2, "dispatched": 3, "confirmed": 4, "declined": 4, "expired": 4, "not_sent": 4, "failed": 4, "uncertain": 4]
    private static let actionOfReview: [String: String] = ["pending": "proposed", "answered": "approved", "dispatched": "dispatched", "completed": "confirmed", "uncertain": "uncertain", "cancelled": "declined", "declined": "declined", "expired": "expired", "not_sent": "not_sent", "failed": "failed"]
    private static let reviewOfAction: [String: String] = ["proposed": "pending", "approved": "answered", "dispatched": "dispatched", "confirmed": "completed", "uncertain": "uncertain", "declined": "cancelled", "expired": "expired", "not_sent": "not_sent", "failed": "failed"]
    /// Kinds of review that this app performs itself, recording "sending" before it starts, so for them "approved" really does mean "not sent
    /// yet". A connected-service request is sent by the connection service, whose ordering this app cannot fully vouch for, so an approved one
    /// is treated as possibly sent, like a review of any unknown kind.
    private static let dispatchRecorded: Set<String> = ["browser", "authentication", "coding"]
    private static func kindOf(_ review: [String: Any]) -> String { review["kind"] as? String ?? "connection" }

    private static func canMove(from current: String, to next: String) -> Bool {
        let a = actionRank[current] ?? 0, b = actionRank[next] ?? 0
        if b > a { return true }
        return current == "uncertain" && ["confirmed", "not_sent", "failed"].contains(next)
    }
    /// A fingerprint of exactly what the user was shown, so the same operation proposed twice can be told apart from two different ones.
    static func payloadHash(_ review: [String: Any]) -> String {
        let basis: [String: Any] = ["kind": kindOf(review), "tool": review["tool"] ?? [String: Any]()]
        guard let text = try? BuddyOperationsDB.encode(basis) else { return "" }
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func describe(_ reviews: [[String: Any]]) -> String {
        if reviews.count == 1 { let name = ((reviews[0]["tool"] as? [String: Any])?["name"] as? String) ?? ""; return name.isEmpty ? "an action" : "“\(name)”" }
        return "\(reviews.count) actions"
    }

    /// Keeps one action record for every review a task shows. Called inside the transaction that saves the task, so the two always agree.
    private static func syncActions(_ new: [String: Any], from old: [String: Any], cause: String, in db: BuddyOperationsDB) throws {
        let reviews = new["reviews"] as? [[String: Any]] ?? []
        guard !reviews.isEmpty else { return }
        var before: [String: [String: Any]] = [:]
        for review in old["reviews"] as? [[String: Any]] ?? [] { if let id = review["id"] as? String { before[id] = review } }
        for review in reviews {
            guard let id = review["id"] as? String, let status = review["status"] as? String, let target = actionOfReview[status] else { continue }
            if let prior = before[id], prior["status"] as? String == status,
               NSDictionary(dictionary: prior["receipt"] as? [String: Any] ?? [:]).isEqual(to: review["receipt"] as? [String: Any] ?? [:]) { continue }
            try recordAction(review, id: id, target: target, task: new, cause: cause, in: db)
        }
    }
    private static func recordAction(_ review: [String: Any], id: String, target: String, task: [String: Any], cause: String, in db: BuddyOperationsDB) throws {
        let taskID = task["id"] as? String ?? "", run = task["executionRunID"] as? String ?? "", attempt = task["attempt"] as? Int ?? 0
        let kind = kindOf(review), tool = ((review["tool"] as? [String: Any])?["name"] as? String) ?? ""
        let receipt = (try? BuddyOperationsDB.encode(review["receipt"] as? [String: Any] ?? [:])) ?? "{}"
        let now = stamp(), finished = (actionRank[target] ?? 0) >= 4
        var payload: [String: Any] = ["id": id, "kind": kind, "tool": tool, "state": target]
        if let existing = try db.rows("SELECT state, run_id FROM actions WHERE id = ?", [.text(id)]).first, let current = existing[0].string {
            guard canMove(from: current, to: target) else { return }
            // A result that arrives from an attempt that has since been replaced is still recorded (it is a fact), but marked.
            let late = ["confirmed", "uncertain", "failed"].contains(target) && !(existing[1].string ?? "").isEmpty && existing[1].string != run
            var sets = ["state = ?", "receipt = ?"], binds: [BuddyOperationsDB.Bind] = [.text(target), .text(receipt)]
            if target == "approved" { sets.append("approved_at = ?"); binds.append(.text(now)) }
            if target == "dispatched" { sets.append("dispatched_at = ?"); binds.append(.text(now)) }
            if finished { sets.append("finished_at = ?"); binds.append(.text(now)) }
            if late { sets.append("late = 1"); payload["late"] = true }
            if (review["receipt"] as? [String: Any])?["resolvedBy"] as? String == "user" { sets.append("resolved_by = 'user'") }
            try db.run("UPDATE actions SET " + sets.joined(separator: ", ") + " WHERE id = ?", binds + [.text(id)])
            payload["from"] = current
        } else {
            let hash = payloadHash(review), rank = actionRank[target] ?? 0
            func when(_ yes: Bool) -> BuddyOperationsDB.Bind { yes ? .text(now) : .null }
            try db.run("INSERT INTO actions(id, task_id, attempt, run_id, kind, tool, payload_hash, idempotency_key, state, proposed_at, approved_at, dispatched_at, finished_at, receipt) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                       [.text(id), .text(taskID), .int(Int64(attempt)), .text(run), .text(kind), .text(tool), .text(hash), .text(hash.isEmpty ? "" : taskID + ":" + hash), .text(target), .text(now),
                        when(rank >= 2), when(target == "dispatched"), when(finished), .text(receipt)])
        }
        try appendEvent("action." + target, task: task, attempt: attempt, cause: cause, payload: payload, in: db)
    }

    func actionStates(of taskID: String) throws -> [String: String] {
        var out: [String: String] = [:]
        for row in try db.rows("SELECT id, state FROM actions WHERE task_id = ?", [.text(taskID)]) { if let id = row[0].string, let state = row[1].string { out[id] = state } }
        return out
    }
    /// A copy of a review that arrives late must not move an action backwards: the record, which only moves forward, wins.
    private func keepingActionProgress(_ job: [String: Any]) throws -> [String: Any] {
        guard var reviews = job["reviews"] as? [[String: Any]], !reviews.isEmpty else { return job }
        let rows = try actionStates(of: job["id"] as? String ?? "")
        var changed = false
        for r in reviews.indices {
            guard let id = reviews[r]["id"] as? String, let state = rows[id], let status = reviews[r]["status"] as? String, let shown = Self.actionOfReview[status], let mapped = Self.reviewOfAction[state] else { continue }
            let behind = (Self.actionRank[shown] ?? 0) < (Self.actionRank[state] ?? 0)
            let staleUncertain = shown == "uncertain" && state != "uncertain" && (Self.actionRank[state] ?? 0) >= 4
            if behind || staleUncertain { reviews[r]["status"] = mapped; changed = true }
        }
        guard changed else { return job }
        var out = job; out["reviews"] = reviews; return out
    }
    /// Reviews that already exist when action records begin get a record too, so they can be checked off like any other. An approval whose
    /// outcome was never recorded is assumed to have been sent.
    private func backfillActions() throws {
        var missing: [(job: [String: Any], review: [String: Any], id: String)] = []
        for job in jobs {
            let known = try actionStates(of: job["id"] as? String ?? "")
            for review in job["reviews"] as? [[String: Any]] ?? [] { if let id = review["id"] as? String, known[id] == nil { missing.append((job, review, id)) } }
        }
        guard !missing.isEmpty else { return }
        try db.transaction {
            for item in missing {
                let status = item.review["status"] as? String ?? "", state = status == "answered" ? "dispatched" : (Self.actionOfReview[status] ?? "uncertain")
                let hash = Self.payloadHash(item.review), tool = ((item.review["tool"] as? [String: Any])?["name"] as? String) ?? ""
                try db.run("INSERT OR IGNORE INTO actions(id, task_id, attempt, run_id, kind, tool, payload_hash, idempotency_key, state, proposed_at, receipt) VALUES(?, ?, ?, '', ?, ?, ?, ?, ?, ?, ?)",
                           [.text(item.id), .text(item.job["id"] as? String ?? ""), .int(Int64(item.job["attempt"] as? Int ?? 0)), .text(Self.kindOf(item.review)), .text(tool), .text(hash),
                            .text(hash.isEmpty ? "" : (item.job["id"] as? String ?? "") + ":" + hash), .text(state), .text(item.review["answeredAt"] as? String ?? (item.job["createdAt"] as? String ?? "")),
                            .text((try? BuddyOperationsDB.encode(item.review["receipt"] as? [String: Any] ?? [:])) ?? "{}")])
            }
        }
    }

    /// What a restart or a stop leaves each waiting action as, by how far it got. One never approved was never sent. One approved but not yet
    /// sent (where the app records sending first) was not sent. One that was being sent may have been, so the user has to check.
    static func settled(_ reviews: [[String: Any]], rows: [String: String], pending: String) -> [[String: Any]] {
        var out = reviews
        for r in out.indices {
            guard let id = out[r]["id"] as? String, let status = out[r]["status"] as? String else { continue }
            var state = actionOfReview[status] ?? ""
            if let row = rows[id], (actionRank[row] ?? 0) > (actionRank[state] ?? 0) { state = row }
            switch state {
            case "proposed": out[r]["status"] = pending
            case "approved": out[r]["status"] = (rows[id] != nil && dispatchRecorded.contains(kindOf(out[r]))) ? "not_sent" : "uncertain"
            case "dispatched": out[r]["status"] = "uncertain"
            default: break
            }
        }
        return out
    }
    /// Ends whatever a task was waiting on because it is being stopped. Anything that may have been sent becomes "uncertain".
    func settleActions(of id: String, pending: String, cause: String) throws {
        let job = try self.job(id)
        let reviews = Self.settled(job["reviews"] as? [[String: Any]] ?? [], rows: try actionStates(of: id), pending: pending)
        guard !NSArray(array: reviews).isEqual(to: job["reviews"] as? [[String: Any]] ?? []) else { return }
        try update(id, ["reviews": reviews], cause: cause)
    }

    private func reviewIndex(_ job: [String: Any], _ reviewID: String) -> (reviews: [[String: Any]], index: Int)? {
        let reviews = job["reviews"] as? [[String: Any]] ?? []
        return reviews.firstIndex { $0["id"] as? String == reviewID }.map { (reviews, $0) }
    }
    /// Records that an approved action is being handed over to be performed. This is the last step before anything leaves the Mac, and it is
    /// saved first, so a crash from here on means "may have been sent", never "approved only". It refuses when the attempt that proposed the
    /// action has been replaced, when the task is no longer working, or when an identical action is still unconfirmed in this task.
    func markDispatched(task id: String, review reviewID: String) throws {
        let job = try self.job(id)
        guard var found = reviewIndex(job, reviewID) else { throw BuddyWorkerFailure(message: "This action is no longer on the task, so it was not sent.") }
        guard ["running", "waiting_review"].contains(job["status"] as? String ?? "") else { throw BuddyWorkerFailure(message: "This attempt is no longer working, so the action was not sent.") }
        guard ["pending", "answered"].contains(found.reviews[found.index]["status"] as? String ?? "") else { throw BuddyWorkerFailure(message: "This action was already sent or finished, so it was not sent again.") }
        if let row = try db.rows("SELECT run_id FROM actions WHERE id = ?", [.text(reviewID)]).first, let proposedBy = row[0].string, !proposedBy.isEmpty, proposedBy != (job["executionRunID"] as? String ?? "") {
            throw BuddyWorkerFailure(message: "The attempt that proposed this action has been replaced, so it was not sent. Ask again from the current attempt.")
        }
        let hash = Self.payloadHash(found.reviews[found.index])
        if !hash.isEmpty, let twin = try db.rows("SELECT tool FROM actions WHERE task_id = ? AND payload_hash = ? AND id <> ? AND state IN ('dispatched', 'uncertain') LIMIT 1", [.text(id), .text(hash), .text(reviewID)]).first {
            throw BuddyWorkerFailure(message: "An identical action (\(twin[0].string ?? "")) may already have gone through, so this one was not sent. Open the task and say whether the earlier one went through.")
        }
        found.reviews[found.index]["status"] = "dispatched"; found.reviews[found.index]["dispatchedAt"] = Self.stamp()
        try update(id, ["reviews": found.reviews], cause: "dispatch")
    }
    /// Records how an action ended. It is recorded even when the attempt has been replaced meanwhile (it is a fact), and marked late.
    func finishAction(task id: String, review reviewID: String, status: String, receipt: [String: Any]) throws {
        let job = try self.job(id)
        guard var found = reviewIndex(job, reviewID) else { return }
        found.reviews[found.index]["status"] = status; found.reviews[found.index]["receipt"] = receipt
        try update(id, ["reviews": found.reviews], cause: "receipt")
    }
    /// The user's answer to "check whether this went through": it did (confirmed) or it did not (not sent).
    func resolveAction(task id: String, review reviewID: String, confirmed: Bool) throws {
        let job = try self.job(id)
        guard var found = reviewIndex(job, reviewID), found.reviews[found.index]["status"] as? String == "uncertain" else { throw BuddyWorkerFailure(message: "Only an action that is waiting to be checked can be marked.") }
        var receipt = found.reviews[found.index]["receipt"] as? [String: Any] ?? [:]
        receipt["resolvedBy"] = "user"; receipt["outcome"] = confirmed ? "went_through" : "did_not_go_through"; receipt["resolvedAt"] = Self.stamp()
        found.reviews[found.index]["status"] = confirmed ? "completed" : "not_sent"; found.reviews[found.index]["receipt"] = receipt
        try update(id, ["reviews": found.reviews], cause: "user.resolved")
    }
    func actions(of taskID: String) throws -> [BuddyAction] {
        try db.rows("SELECT id, attempt, run_id, kind, tool, payload_hash, state, proposed_at, dispatched_at, finished_at, late, resolved_by, receipt FROM actions WHERE task_id = ? ORDER BY proposed_at, id", [.text(taskID)]).compactMap { row in
            guard let id = row[0].string, let state = row[6].string else { return nil }
            return BuddyAction(id: id, taskID: taskID, attempt: Int(row[1].int ?? 0), runID: row[2].string ?? "", kind: row[3].string ?? "", tool: row[4].string ?? "", payloadHash: row[5].string ?? "", state: state,
                               proposedAt: row[7].string ?? "", dispatchedAt: row[8].string, finishedAt: row[9].string, late: row[10].int == 1, resolvedBy: row[11].string ?? "",
                               receipt: (try? BuddyOperationsDB.decode(row[12].string ?? "{}")) ?? [:])
        }
    }
    /// What the task's earlier actions came to, in words the model can act on. Native records, not the model's memory.
    func actionFacts(of taskID: String) -> String {
        guard let all = try? actions(of: taskID), !all.isEmpty else { return "" }
        let lines = all.suffix(30).compactMap { action -> String? in
            let name = action.tool.isEmpty ? "an action" : "“\(action.tool)”"
            switch action.state {
            case "confirmed": return "- \(name): done" + (action.resolvedBy == "user" ? " (the user confirmed it went through). Do not repeat it." : ". Do not repeat it.")
            case "uncertain", "dispatched": return "- \(name): unconfirmed. It may or may not have gone through, and the user has not said. Do not repeat it; tell the user to check it."
            case "not_sent": return "- \(name): was approved but not sent. It is safe to propose again if still needed."
            case "declined": return "- \(name): the user declined it. Do not propose it again unless asked."
            case "expired": return "- \(name): was never approved, so it was not sent."
            default: return nil
            }
        }
        return lines.isEmpty ? "" : "Actions from earlier attempts of this task (native record):\n" + lines.joined(separator: "\n")
    }

    // MARK: leases

    /// Exclusive use of `resource` for `holder`. A free lease, an expired one, or one whose holder `isLive` says is gone is taken over with
    /// the next generation number; the same holder asking again just renews. Returns nil while someone else holds it.
    func acquireLease(_ resource: String, holder: String, task: String, ttl: TimeInterval = 600, now: Date = Date(), isLive: (String) -> Bool = { _ in true }) throws -> BuddyLease? {
        let expires = Int64(now.timeIntervalSince1970 + ttl)
        return try db.transaction {
            guard let row = try db.rows("SELECT generation, holder, expires_at FROM leases WHERE resource = ?", [.text(resource)]).first, let generation = row[0].int else {
                try db.run("INSERT INTO leases(resource, generation, holder, task_id, acquired_at, expires_at) VALUES(?, 1, ?, ?, ?, ?)", [.text(resource), .text(holder), .text(task), .text(Self.stamp()), .int(expires)])
                return BuddyLease(resource: resource, generation: 1, holder: holder)
            }
            let current = row[1].string ?? ""
            if current == holder {
                try db.run("UPDATE leases SET expires_at = ? WHERE resource = ?", [.int(expires), .text(resource)])
                return BuddyLease(resource: resource, generation: generation, holder: holder)
            }
            let free = current.isEmpty || (row[2].int ?? 0) <= Int64(now.timeIntervalSince1970) || !isLive(current)
            guard free else { return nil }
            try db.run("UPDATE leases SET generation = ?, holder = ?, task_id = ?, acquired_at = ?, expires_at = ? WHERE resource = ?", [.int(generation + 1), .text(holder), .text(task), .text(Self.stamp()), .int(expires), .text(resource)])
            return BuddyLease(resource: resource, generation: generation + 1, holder: holder)
        }
    }
    /// Whether this is still the lease that holds the resource. Check it just before doing something that must not happen twice.
    func leaseIsCurrent(_ lease: BuddyLease) throws -> Bool {
        guard let row = try db.rows("SELECT generation, holder FROM leases WHERE resource = ?", [.text(lease.resource)]).first else { return false }
        return row[0].int == lease.generation && row[1].string == lease.holder
    }
    /// Frees the resource if this lease still holds it. The generation stays, so an old token cannot match a later lease.
    func releaseLease(_ lease: BuddyLease) throws {
        try db.run("UPDATE leases SET holder = '', task_id = '', expires_at = 0 WHERE resource = ? AND generation = ? AND holder = ?", [.text(lease.resource), .int(lease.generation), .text(lease.holder)])
    }
    func releaseLeases(heldBy task: String) throws { try db.run("UPDATE leases SET holder = '', task_id = '', expires_at = 0 WHERE task_id = ?", [.text(task)]) }
    /// A worker that has just started has no live holders: whatever the last one held is free.
    @discardableResult func breakAllLeases() throws -> Int { try db.run("UPDATE leases SET holder = '', task_id = '', expires_at = 0 WHERE holder <> ''") }

    // MARK: what needs you

    /// `audience` is who has to act: "user" (the person) or "supervisor" (the agent the task names as its supervisor).
    struct DecisionSpec { let id: String, kind: String, title: String, question: String, label: String, payload: [String: Any]; var audience = "user" }
    /// The blockers a task's state implies right now, each with the identity that makes it the same blocker next time. One sign-in problem is one
    /// entry, however many places show it. Every stop is seen by someone: a stop the person made needs nobody, a stop being retried by itself needs
    /// nobody yet, and any other stop goes to the task's supervisor if it names one, else to the person. Reviews, sign-ins, unconfirmed actions,
    /// daily limits and a provider account that needs the person (`provider.account`: a sign-in, a refused key, credit) are always the person's.
    static func desiredDecisions(_ job: [String: Any]) -> [DecisionSpec] {
        let id = job["id"] as? String ?? "", status = job["status"] as? String ?? "", attempt = job["attempt"] as? Int ?? 0, title = job["title"] as? String ?? "Background task"
        let progress = String((job["progress"] as? String ?? "").prefix(300)), cause = job["stopCause"] as? String ?? ""
        let watcher = (job["supervisorId"] as? String ?? "").isEmpty || cause == "provider.account" ? "user" : "supervisor"
        var out: [DecisionSpec] = []
        for review in job["reviews"] as? [[String: Any]] ?? [] {
            guard let reviewID = review["id"] as? String else { continue }
            let tool = (review["tool"] as? [String: Any])?["name"] as? String ?? "an action", auth = review["kind"] as? String == "authentication"
            switch review["status"] as? String ?? "" {
            case "pending":
                // A coding command Buddy judged routine is the team supervisor's to answer (`command_review`); the page shows it to the person
                // only when the supervisor lane is not answering.
                if review["route"] as? String == "supervisor", review["kind"] as? String == "coding" {
                    out.append(DecisionSpec(id: "review:" + reviewID, kind: "command_review", title: "Review: \(tool)", question: "Allow this exact command? " + ((review["assessment"] as? [String: Any])?["reason"] as? String ?? ""),
                                            label: "Review", payload: ["taskId": id, "reviewId": reviewID], audience: "supervisor"))
                    continue
                }
                let check = review["kind"] as? String == "checkpoint", ask = ((review["questions"] as? [[String: Any]])?.first?["question"] as? String) ?? ""
                out.append(DecisionSpec(id: "review:" + reviewID, kind: auth ? "signin" : "review", title: auth ? "Sign-in needs your choice" : check ? "Check the work: \(title)" : "Review: \(tool)",
                                        question: auth ? "Choose how to sign in to \(review["origin"] as? String ?? "this site")." : check ? (ask.isEmpty ? "Look at the work and say whether to continue." : ask) : "Allow this exact operation?", label: check ? "Check work" : "Review", payload: ["taskId": id, "reviewId": reviewID]))
            case "uncertain":
                out.append(DecisionSpec(id: "action:" + reviewID + ":unconfirmed", kind: "unconfirmed", title: "Check whether “\(tool)” went through",
                                        question: "Buddy stopped before it could confirm this. Look at the site or service, then say whether it went through.", label: "Check action", payload: ["taskId": id, "reviewId": reviewID]))
            default: break
            }
        }
        if status == "waiting_user" {
            let point = job["checkpoint"] as? [String: Any]
            if cause == "review.parked" {
                out.append(DecisionSpec(id: "waiting:\(id):\(attempt)", kind: "waiting", title: title, question: "Buddy set this aside so other work could run. Resume it when you can review the step it was waiting for.", label: "Open task", payload: ["taskId": id]))
            } else if point?["need"] as? String == "credential", let profile = point?["profile"] as? String, !profile.isEmpty {
                // A sign-in is always the person's. Its card opens Buddy's own sign-in box; nothing about it is ever asked in a chat.
                let service = (point?["service"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "This service"
                out.append(DecisionSpec(id: "credential:\(id):\(attempt):\(profile)", kind: "credential", title: "\(service) needs your sign-in", question: point?["question"] as? String ?? "Sign in to continue.",
                                        label: "Sign in", payload: ["taskId": id, "profile": profile]))
            } else {
                let routed = (job["checkpoint"] as? [String: Any])?["routedTo"] as? String == "supervisor" ? "supervisor" : "user"
                out.append(DecisionSpec(id: "waiting:\(id):\(attempt)", kind: "waiting", title: title, question: progress.isEmpty ? "This task is waiting for you." : progress, label: "Open task", payload: ["taskId": id], audience: routed))
            }
        }
        // A command signing in with the person's saved sign-in waits for their second step (a Duo push on their phone): it is theirs while the
        // command runs, and goes away by itself when the command ends.
        if status == "running", let wait = job["mfaWait"] as? [String: Any], let service = wait["service"] as? String {
            out.append(DecisionSpec(id: "mfa:\(id):\(wait["commandId"] as? String ?? "")", kind: "mfa", title: "Approve the \(service) Duo push on your phone",
                                    question: "A command is signing in to \(service) with your saved sign-in. Approve the Duo push on your phone; this goes away when the command ends.", label: "Open task", payload: ["taskId": id]))
        }
        if status == "failed" || status == "interrupted" {
            // While the stop is being retried by itself there is nothing to decide; once the tries are used up it is a stopped task again.
            let retrying = ["pending", "queued"].contains((job["recovery"] as? [String: Any])?["state"] as? String ?? "")
            if !retrying {
                out.append(DecisionSpec(id: "stopped:\(id):\(attempt):\(status)", kind: "stopped", title: title, question: progress.isEmpty ? "This task stopped before finishing." : progress, label: "Open task", payload: ["taskId": id], audience: watcher))
            }
        }
        if status == "paused" {
            if job["blockedBy"] as? String == "limit" {
                out.append(DecisionSpec(id: "limit:\(id):\(job["blockedAt"] as? String ?? "")", kind: "limit", title: "Daily limit reached", question: progress, label: "Open task", payload: ["taskId": id]))
            } else if !(cause.hasPrefix("user") || cause == "routine.paused" || cause == "superseded") {
                out.append(DecisionSpec(id: "paused:\(id):\(attempt):\(cause.isEmpty ? "unknown" : cause)", kind: "paused", title: title, question: progress.isEmpty ? "This task stopped by itself." : progress, label: "Open task", payload: ["taskId": id], audience: watcher))
            }
        }
        if status == "completed", !(job["reportsTo"] as? String ?? "").isEmpty, (job["acceptedAt"] as? String ?? "").isEmpty {
            let result = String((job["result"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
            out.append(DecisionSpec(id: "result:\(id):\(attempt)", kind: "result", title: "Result to review: \(title)", question: result.isEmpty ? "This task finished. Review what it delivered." : result, label: "Review result", payload: ["taskId": id], audience: "supervisor"))
        }
        return out
    }
    /// Kinds kept equal to a task's state. `allowance` is no longer opened, but stays here so rows left from before are still resolved.
    private static let derivedKinds = "('review', 'signin', 'waiting', 'allowance', 'stopped', 'unconfirmed', 'limit', 'paused', 'result', 'credential', 'mfa', 'command_review')"
    /// Keeps the open blockers of one task equal to what its state implies, in the transaction that saves it: new ones are opened, ones whose cause
    /// has ended are resolved, and each is an event, so a consumer can follow them.
    private static func syncDecisions(_ task: [String: Any], in db: BuddyOperationsDB) throws {
        let taskID = task["id"] as? String ?? "", desired = Dictionary(desiredDecisions(task).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var open: [String: String] = [:]
        for row in try db.rows("SELECT id, audience FROM decisions WHERE task_id = ? AND status = 'open' AND kind IN \(derivedKinds)", [.text(taskID)]) { if let id = row[0].string { open[id] = row[1].string ?? "user" } }
        for (id, spec) in desired where open[id] == nil {
            let added = try db.run("INSERT OR IGNORE INTO decisions(id, workspace, agent_id, task_id, kind, title, question, label, payload, created_at, audience) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                                   [.text(id), .text(task["workspace"] as? String ?? ""), .text(task["agentId"] as? String ?? ""), .text(taskID), .text(spec.kind), .text(spec.title), .text(spec.question), .text(spec.label), .text((try? BuddyOperationsDB.encode(spec.payload)) ?? "{}"), .text(stamp()), .text(spec.audience)])
            if added > 0 { try appendEvent("decision.opened", task: task, attempt: task["attempt"] as? Int, cause: spec.kind, payload: ["id": id, "kind": spec.kind], in: db) }
        }
        // The same blocker whose audience has changed (a supervisor was named, a question was routed) moves in place.
        for (id, spec) in desired { if let current = open[id], current != spec.audience { try db.run("UPDATE decisions SET audience = ? WHERE id = ?", [.text(spec.audience), .text(id)]) } }
        for id in open.keys where desired[id] == nil {
            try db.run("UPDATE decisions SET status = 'resolved', resolution = 'state_changed', resolved_at = ? WHERE id = ?", [.text(stamp()), .text(id)])
            try appendEvent("decision.resolved", task: task, attempt: task["attempt"] as? Int, cause: "state_changed", payload: ["id": id], in: db)
        }
    }
    /// Brings every live task's blockers up to date: once at start (tasks that were already waiting get their entry) and after any change.
    private func reconcileDecisions() throws {
        try db.transaction { for job in jobs { try Self.syncDecisions(job, in: db) } }
    }
    /// What needs the person now, for one workspace, oldest first.
    func openDecisions(workspace: String) throws -> [[String: Any]] {
        var out: [[String: Any]] = []
        for row in try db.rows("SELECT id, agent_id, task_id, kind, title, question, label, payload, created_at, audience FROM decisions WHERE workspace = ? AND status = 'open' ORDER BY created_at, id", [.text(workspace)]) {
            var item: [String: Any] = [:]
            item["id"] = row[0].string ?? ""; item["agentId"] = row[1].string ?? ""; item["taskId"] = row[2].string ?? ""; item["kind"] = row[3].string ?? ""
            item["title"] = row[4].string ?? ""; item["question"] = row[5].string ?? ""; item["actionLabel"] = row[6].string ?? ""
            item["payload"] = (try? BuddyOperationsDB.decode(row[7].string ?? "{}")) ?? [String: Any]()
            item["createdAt"] = row[8].string ?? ""; item["audience"] = row[9].string ?? "user"
            out.append(item)
        }
        return out
    }
    /// Marks alerts read or unread, dismissed or not, by id. Neither changes anything about the work itself.
    func setNotifications(workspace: String, ids: [String], read: Bool? = nil, dismissed: Bool? = nil) throws {
        guard !ids.isEmpty, ids.count <= 500, ids.allSatisfy({ !$0.isEmpty && $0.count <= 300 }), UUID(uuidString: workspace) != nil else { throw BuddyWorkerFailure(message: "Choose the alerts to change.") }
        guard read != nil || dismissed != nil else { return }
        try db.transaction {
            for id in ids {
                try db.run("INSERT INTO notification_state(workspace, id, read, dismissed, updated_at) VALUES(?, ?, 0, 0, ?) ON CONFLICT(workspace, id) DO NOTHING", [.text(workspace), .text(id), .text(Self.stamp())])
                if let read { try db.run("UPDATE notification_state SET read = ?, updated_at = ? WHERE workspace = ? AND id = ?", [.int(read ? 1 : 0), .text(Self.stamp()), .text(workspace), .text(id)]) }
                if let dismissed { try db.run("UPDATE notification_state SET dismissed = ?, updated_at = ? WHERE workspace = ? AND id = ?", [.int(dismissed ? 1 : 0), .text(Self.stamp()), .text(workspace), .text(id)]) }
            }
            // Alerts for work that is long gone no longer need remembering.
            try db.run("DELETE FROM notification_state WHERE updated_at < ?", [.text(Self.stamp(Date().addingTimeInterval(-90 * 86400)))])
        }
    }
    func notificationState(workspace: String) throws -> [String: [String: Any]] {
        var out: [String: [String: Any]] = [:]
        for row in try db.rows("SELECT id, read, dismissed FROM notification_state WHERE workspace = ?", [.text(workspace)]) { if let id = row[0].string { out[id] = ["read": row[1].int == 1, "dismissed": row[2].int == 1] } }
        return out
    }

    // MARK: money

    private static func number(_ value: Any?) -> Double { (value as? Double) ?? (value as? NSNumber)?.doubleValue ?? 0 }
    private static func appendBudget(_ kind: String, amount: Double, task: [String: Any], attempt: Int?, cause: String, idem: String? = nil, day: String? = nil, in db: BuddyOperationsDB) throws {
        // The "no limit" number is not money: it is never authorized, set aside or given back in the ledger.
        guard amount > 1e-9, amount < BuddyRunLimit.none / 2 else { return }
        let attemptColumn: BuddyOperationsDB.Bind
        if let attempt { attemptColumn = .int(Int64(attempt)) } else { attemptColumn = .null }
        let idemColumn: BuddyOperationsDB.Bind
        if let idem { idemColumn = .text(idem) } else { idemColumn = .null }
        try db.run("INSERT OR IGNORE INTO budget_entries(workspace, agent_id, task_id, attempt, kind, amount_usd, day, at, cause, idem) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                   [.text(task["workspace"] as? String ?? ""), .text(task["agentId"] as? String ?? ""), .text(task["id"] as? String ?? ""), attemptColumn, .text(kind), .text(String(amount)), .text(day ?? BuddyBudget.day(Date())), .text(stamp()), .text(cause), idemColumn])
    }
    /// Writes every change to what a task has set aside, spent or cannot account for as entries, in the transaction that saves the task. An
    /// attempt that ends turns its reservation into a spend (and gives back the rest); one that is abandoned turns it into an uncertain amount.
    private static func syncBudget(_ new: [String: Any], from old: [String: Any], cause: String, in db: BuddyOperationsDB) throws {
        let attempt = new["attempt"] as? Int
        let spent = max(0, number(new["spentUSD"]) - number(old["spentUSD"])), uncertain = max(0, number(new["uncertainBudgetUSD"]) - number(old["uncertainBudgetUSD"]))
        let reservedChange = number(new["reservedBudgetUSD"]) - number(old["reservedBudgetUSD"])
        try appendBudget("reserve", amount: max(0, reservedChange), task: new, attempt: attempt, cause: cause, in: db)
        try appendBudget("spend", amount: spent, task: new, attempt: attempt, cause: cause, in: db)
        try appendBudget("uncertain", amount: uncertain, task: new, attempt: attempt, cause: cause, in: db)
        try appendBudget("release", amount: max(0, -reservedChange - spent - uncertain), task: new, attempt: attempt, cause: cause, in: db)
        let known = Set((old["budgetAuthorizations"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
        for authorization in new["budgetAuthorizations"] as? [[String: Any]] ?? [] {
            guard let id = authorization["id"] as? String, !known.contains(id) else { continue }
            try appendBudget("authorize", amount: number(authorization["amountUSD"]), task: new, attempt: attempt, cause: cause, idem: "auth:" + id, in: db)
        }
    }
    /// Money already spent when the record began is entered once, on the day it was spent, so it is never counted as today's.
    private func recordBudgetBaseline() throws {
        var pending: [(job: [String: Any], spent: Double, uncertain: Double)] = []
        for job in jobs {
            let spent = Self.number(job["spentUSD"]), uncertain = Self.number(job["uncertainBudgetUSD"])
            guard spent > 1e-9 || uncertain > 1e-9, let id = job["id"] as? String else { continue }
            if (try db.rows("SELECT 1 FROM budget_entries WHERE task_id = ? LIMIT 1", [.text(id)])).isEmpty { pending.append((job, spent, uncertain)) }
        }
        guard !pending.isEmpty else { return }
        try db.transaction {
            for item in pending {
                let when = (item.job["updatedAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date.distantPast
                let day = BuddyBudget.day(when), id = item.job["id"] as? String ?? ""
                try Self.appendBudget("spend", amount: item.spent, task: item.job, attempt: nil, cause: "history.begins", idem: "baseline-spend:" + id, day: day, in: db)
                try Self.appendBudget("uncertain", amount: item.uncertain, task: item.job, attempt: nil, cause: "history.begins", idem: "baseline-uncertain:" + id, day: day, in: db)
            }
        }
    }
    /// Sets or removes a daily limit: for one agent (`scope` "agent", `id` the agent) or for the whole workspace. Nil removes it.
    func setLimit(workspace: String, scope: String, id: String = "", amount: Double?, setBy: String, quote: String = "") throws {
        guard UUID(uuidString: workspace) != nil, ["agent", "workspace"].contains(scope), scope == "workspace" || UUID(uuidString: id) != nil else { throw BuddyWorkerFailure(message: "Choose an agent or the whole workspace for this limit.") }
        try db.transaction {
            guard let amount else { try db.run("DELETE FROM limits WHERE workspace = ? AND scope = ? AND scope_id = ? AND period = 'day'", [.text(workspace), .text(scope), .text(scope == "agent" ? id : "")]); return }
            guard amount.isFinite, amount >= 0, amount <= 100000 else { throw BuddyWorkerFailure(message: "Choose a daily limit between $0 and $100,000.") }
            try db.run("INSERT INTO limits(workspace, scope, scope_id, period, amount_usd, set_by, quote, set_at) VALUES(?, ?, ?, 'day', ?, ?, ?, ?) ON CONFLICT(workspace, scope, scope_id, period) DO UPDATE SET amount_usd = excluded.amount_usd, set_by = excluded.set_by, quote = excluded.quote, set_at = excluded.set_at",
                       [.text(workspace), .text(scope), .text(scope == "agent" ? id : ""), .text(String(amount)), .text(setBy), .text(String(quote.prefix(500))), .text(Self.stamp())])
        }
    }
    func limits(workspace: String) throws -> [[String: Any]] {
        try db.rows("SELECT scope, scope_id, amount_usd, set_by, quote, set_at FROM limits WHERE workspace = ? ORDER BY scope, scope_id", [.text(workspace)]).map { row in
            ["scope": row[0].string ?? "", "id": row[1].string ?? "", "amountUSD": Double(row[2].string ?? "") ?? 0, "setBy": row[3].string ?? "", "quote": row[4].string ?? "", "setAt": row[5].string ?? ""]
        }
    }
    private var support: URL { directory.deletingLastPathComponent() }
    func exposure(workspace: String, agent: String, now: Date = Date()) throws -> BuddyBudget.Exposure { try BuddyBudget.exposure(db, support: support, workspace: workspace, agent: agent, now: now) }
    /// Today's money for every agent in a workspace, with its limit and how much room is left.
    func budgetStatus(workspace: String, agents: [String], now: Date = Date()) throws -> [String: Any] {
        var out: [String: [String: Any]] = [:]
        for agent in agents {
            let used = try exposure(workspace: workspace, agent: agent, now: now), limit = try BuddyBudget.limit(db, workspace: workspace, agent: agent)
            var row: [String: Any] = ["spent": used.spent, "uncertain": used.uncertain, "reserved": used.reserved]
            if let limit { row["limitUSD"] = limit.amount; row["limitScope"] = limit.scope; row["roomUSD"] = max(0, limit.amount - used.total) }
            out[agent] = row
        }
        return ["day": BuddyBudget.day(now), "agents": out, "limits": try limits(workspace: workspace)]
    }
    /// The money entries of one task, oldest first.
    func ledger(of taskID: String) throws -> [[String: Any]] {
        try db.rows("SELECT kind, amount_usd, day, cause, attempt FROM budget_entries WHERE task_id = ? ORDER BY id", [.text(taskID)]).map { row in
            ["kind": row[0].string ?? "", "amountUSD": Double(row[1].string ?? "") ?? 0, "day": row[2].string ?? "", "cause": row[3].string ?? "", "attempt": row[4].int.map { Int($0) } as Any? ?? NSNull()]
        }
    }
    /// Stops a task that would pass today's limit, with a plain reason, instead of starting it. It stays resumable.
    func refuseForLimit(_ id: String, limit: Double, scope: String, exposure: BuddyBudget.Exposure, wanted: Double) throws {
        func dollars(_ value: Double) -> String { String(format: "$%.2f", value) }
        let whose = scope == "agent" ? "this agent" : "the workspace"
        let message = "Today’s limit for \(whose) (\(dollars(limit))) would be passed: \(dollars(exposure.total)) is already spent or set aside, and this task needs up to \(dollars(wanted)). Raise the limit or wait until tomorrow, then resume."
        let job = try self.job(id)
        try update(id, ["status": "paused", "progress": message, "blockedBy": "limit", "blockedAt": Self.stamp()], cause: "budget.limit")
        try db.transaction { try Self.appendEvent("budget.refused", task: job, attempt: job["attempt"] as? Int, cause: "budget.limit", payload: ["limitUSD": limit, "scope": scope, "usedUSD": exposure.total, "wantedUSD": wanted], in: db) }
    }

    /// Queues a stopped task to carry on, and clears why it stopped. Runs have no allowance of their own any more, so the last two arguments (an
    /// extra allowance an older caller may still send) are ignored; they stay only so those callers keep working.
    func resume(_ id: String, continuingCoding:Bool=false,additionalBudgetUSD:Double?=nil,authorizationID:String?=nil) throws -> [String: Any] {
        let job = try self.job(id)
        guard ["paused", "failed", "interrupted", "waiting_user"].contains(job["status"] as? String ?? "") || (continuingCoding && job["kind"] as? String=="coding" && job["status"] as? String=="completed") else { throw BuddyWorkerFailure(message: "This task can’t be resumed in its current state.") }
        var fields:[String:Any] = ["status": "queued", "progress": "Queued to continue from saved progress. Check existing external state before any send or submission.", "blockedBy": "", "stopCause": ""]
        if job["provider"] as? String=="claude",(job["remainingBudgetUSD"] as? Double ?? job["budgetUSD"] as? Double ?? 0)<=0 {
            // A task from the time runs had an allowance, stopped with none left: it simply carries on, with no limit.
            fields["remainingBudgetUSD"]=BuddyRunLimit.none;fields["reservedBudgetUSD"]=0.0
        }
        return try update(id,fields,cause:"resume")
    }
}

/// How a routine's own recent runs went. Health is judged per routine, so one routine's bad run never freezes the others in its series.
enum BuddyRoutineHealth {
    static let attentionError = "The previous run needs attention. Review it before resuming this routine."
    private static let stopped: Set<String> = ["failed", "interrupted", "paused"]
    /// A run that stopped by itself, with nothing that may have been sent: the next run can safely happen.
    static func endedHarmlessly(_ prior: [String: Any]?) -> Bool {
        guard let prior, stopped.contains(prior["status"] as? String ?? ""), !(prior["stopCause"] as? String ?? "").hasPrefix("user") else { return false }
        return !(prior["reviews"] as? [[String: Any]] ?? []).contains { ["uncertain", "dispatched"].contains($0["status"] as? String ?? "") }
    }
    /// Still being worked on, or waiting to be: another run of the same work would overlap it.
    static func inFlight(_ job: [String: Any]?) -> Bool {
        guard let status = job?["status"] as? String else { return false }
        return !["completed", "cancelled"].contains(status) && !stopped.contains(status)
    }
    /// Ended without finishing: stopped, or superseded by another run of the series that did.
    static func unclean(_ job: [String: Any]) -> Bool {
        let status = job["status"] as? String ?? ""
        return stopped.contains(status) || (status == "cancelled" && job["stopCause"] as? String == "superseded")
    }
    /// Whether a routine has to wait for someone, from its own runs (oldest first): its last run waits for the person, or stopped in a way that
    /// is not harmless, or its last three runs in a row did not finish. Runs up to `clearedAfter` (the last run when someone set it going again)
    /// no longer count toward three in a row.
    static func needsAttention(_ own: [[String: Any]], clearedAfter: String? = nil) -> Bool {
        guard let last = own.last else { return false }
        let status = last["status"] as? String ?? ""
        if status == "waiting_user" { return (last["checkpoint"] as? [String: Any])?["routedTo"] as? String != "supervisor" }
        if stopped.contains(status), !endedHarmlessly(last) { return true }
        var counted = own[...]
        if let clearedAfter, !clearedAfter.isEmpty, let cut = own.lastIndex(where: { $0["id"] as? String == clearedAfter }) { counted = own[(cut + 1)...] }
        let recent = counted.suffix(3)
        return recent.count == 3 && recent.allSatisfy(unclean)
    }
}

/// Goals a scheduled run cannot carry out: a background run can use files, the browser and status tools, but cannot start coding sessions or
/// give teammates work.
enum BuddyRoutineGoals {
    static func unsupported(_ goal: String) -> Bool {
        goal.range(of: #"(?i)\b(buddy_coding_session|buddy_computer_task|start (?:the )?(?:next )?coding session|via check_in|give each agent (?:its|their) next)\b"#, options: .regularExpression) != nil
    }
}

/// Durable local schedules. One overdue occurrence runs after wake, never a burst of catch-up sends.
@MainActor final class BuddyRoutineStore {
    private let db:BuddyOperationsDB
    private(set) var routines:[[String:Any]]
    init(directory:URL) throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        db=try BuddyOperationsDB(directory:directory)
        try BuddyOperationsMigration.importLegacy(into:db,directory:directory)
        let values=try db.rows("SELECT body FROM routines ORDER BY seq").compactMap{$0.first?.string}.map(BuddyOperationsDB.decode)
        guard values.count<=100,Set(values.compactMap{$0["id"] as? String}).count==values.count else { throw BuddyWorkerFailure(message:"Buddy couldn't verify saved routines. Your chats and files are not affected. Don’t delete anything in Application Support/Buddy/Worker; ask Claude Code to repair it.") }
        for value in values { try Self.validate(value);guard let id=value["id"] as? String,UUID(uuidString:id) != nil,let next=value["nextRun"] as? String,ISO8601DateFormatter().date(from:next) != nil else { throw BuddyWorkerFailure(message:"A saved routine has invalid timing. Your chats and files are not affected. Don’t delete anything in Application Support/Buddy/Worker; ask Claude Code to repair it.") } }
        routines=values
    }
    /// Writes only what changed, in one transaction: new routines are added, edited ones updated, removed ones deleted.
    private func persist() throws {
        let saved=routines
        try db.transaction {
            var existing=[String:String]()
            for row in try db.rows("SELECT id, body FROM routines") { if let id=row[0].string,let body=row[1].string { existing[id]=body } }
            var keep=Set<String>()
            for routine in saved {
                guard let id=routine["id"] as? String else { throw BuddyWorkerFailure(message:"A routine is missing its ID.") }
                let body=try BuddyOperationsDB.encode(routine);keep.insert(id)
                if let old=existing[id] {
                    if old != body { try db.run("UPDATE routines SET workspace = ?, agent_id = ?, status = ?, version = version + 1, body = ? WHERE id = ?",[.text(routine["workspace"] as? String ?? ""),.text(routine["agentId"] as? String ?? ""),.text(routine["status"] as? String ?? ""),.text(body),.text(id)]) }
                } else { try Self.insert(routine,body:body,id:id,in:db) }
            }
            for id in existing.keys where !keep.contains(id) { try db.run("DELETE FROM routines WHERE id = ?",[.text(id)]) }
        }
    }
    static func insert(_ routine:[String:Any],body:String,id:String,in db:BuddyOperationsDB) throws {
        try db.run("INSERT INTO routines(id, workspace, agent_id, status, body) VALUES(?, ?, ?, ?, ?)",[.text(id),.text(routine["workspace"] as? String ?? ""),.text(routine["agentId"] as? String ?? ""),.text(routine["status"] as? String ?? ""),.text(body)])
    }
    fileprivate static func validate(_ r:[String:Any]) throws {
        if r["browserAgentId"] != nil || r["browserOrigin"] != nil {
            guard (r["browserAgentId"] as? String).flatMap(UUID.init(uuidString:)) != nil,let origin=r["browserOrigin"] as? String,let u=URLComponents(string:origin),u.scheme=="https",u.host != nil,u.user==nil,u.password==nil,u.path.isEmpty,u.query==nil,u.fragment==nil else{throw BuddyWorkerFailure(message:"Choose an existing browser owner and an exact HTTPS site origin.")}
        }
        guard (r["workspace"] as? String).flatMap(UUID.init(uuidString:)) != nil,(r["agentId"] as? String).flatMap(UUID.init(uuidString:)) != nil,
              let title=r["title"] as? String,!title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,title.count<=150,
              let goal=r["goal"] as? String,!goal.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,goal.count<=30000,
              let hour=r["hour"] as? Int,(0...23).contains(hour),let minute=r["minute"] as? Int,(0...59).contains(minute),
              let days=r["weekdays"] as? [Int],!days.isEmpty,Set(days).count==days.count,days.allSatisfy({(1...7).contains($0)}),
              let zone=r["timeZone"] as? String,TimeZone(identifier:zone) != nil,
              let kind=r["kind"] as? String,["email","research","applications","general"].contains(kind),
              ["chatgpt","claude"].contains(r["provider"] as? String ?? ""),let budget=r["budgetUSD"] as? Double,budget.isFinite,(0...BuddyRunLimit.none).contains(budget),
              let query=r["query"] as? String,query.count<=2000,(kind != "email" || !query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty) else { throw BuddyWorkerFailure(message:"Choose a clear brief, valid local time and days. Email routines also need a relevant Gmail search.") }
    }
    static func next(after date:Date,rule:[String:Any]) throws -> Date {
        guard let zone=(rule["timeZone"] as? String).flatMap(TimeZone.init(identifier:)),let hour=rule["hour"] as? Int,let minute=rule["minute"] as? Int,let days=rule["weekdays"] as? [Int] else { throw BuddyWorkerFailure(message:"This routine has invalid timing.") }
        var calendar=Calendar(identifier:.gregorian);calendar.timeZone=zone
        let candidates=days.compactMap { day in calendar.nextDate(after:date,matching:DateComponents(hour:hour,minute:minute,second:0,weekday:day),matchingPolicy:.nextTime,repeatedTimePolicy:.first,direction:.forward) }
        guard let value=candidates.min() else { throw BuddyWorkerFailure(message:"Could not determine the next run.") };return value
    }
    @discardableResult func manage(_ args:[String:Any],workspace:String,agent:String,requestID:String,provider:String,budget:Double,model:String?=nil,now:Date=Date()) throws -> [String:Any] {
        let action=args["action"] as? String ?? "list"
        if action=="list" { return ["routines":routines.filter{$0["workspace"] as? String==workspace && $0["agentId"] as? String==agent}] }
        let old=routines
        do {
            if action=="create",let hours=args["hours"] as? [Int] {
                guard !hours.isEmpty,hours.count<=24,Set(hours).count==hours.count,hours.allSatisfy({(0...23).contains($0)}) else{throw BuddyWorkerFailure(message:"Choose distinct daily hours from 0 to 23.")}
                var saved=[[String:Any]]()
                for hour in hours.sorted() {var one=args;one.removeValue(forKey:"hours");one["hour"]=hour;one["title"]=(args["title"] as? String ?? "Inbox check")+String(format:" (%02d:%02d)",hour,args["minute"] as? Int ?? 0);let result=try manage(one,workspace:workspace,agent:agent,requestID:requestID+":hour:\(hour)",provider:provider,budget:budget,model:model,now:now);if let r=result["routine"] as? [String:Any]{saved.append(r)}}
                let series=saved.first?["routineSeriesID"] as? String ?? saved.first!["id"] as! String
                for j in saved.indices {saved[j]["routineSeriesID"]=series;if let i=routines.firstIndex(where:{$0["id"] as? String==saved[j]["id"] as? String}){routines[i]=saved[j]}}
                try persist()
                return ["saved":true,"routines":saved,"requiresMacAwake":true]
            }
            if action=="create" || action=="update" {
                if action=="create",let existing=routines.first(where:{$0["workspace"] as? String==workspace && $0["requestID"] as? String==requestID}) { return ["saved":true,"routine":existing] }
                let index=routines.firstIndex{$0["id"] as? String==args["routineID"] as? String && $0["workspace"] as? String==workspace && $0["agentId"] as? String==agent}
                guard action=="create" || index != nil else { throw BuddyWorkerFailure(message:"This routine is no longer available.") }
                guard action != "create" || routines.count<100 else { throw BuddyWorkerFailure(message:"Pause or remove old routines before adding more.") }
                var value=index.map{routines[$0]} ?? ["id":UUID().uuidString,"workspace":workspace,"agentId":agent,"requestID":requestID,"provider":provider,"budgetUSD":budget,"hour":9,"minute":0,"weekdays":[1,2,3,4,5,6,7],"timeZone":TimeZone.current.identifier,"query":"","kind":"general"]
                if index==nil,let model,!model.isEmpty {value["model"]=model}
                for field in ["title","goal","hour","minute","weekdays","timeZone","query","kind","browserAgentId","browserOrigin"] { if let v=args[field],!(v is NSNull) { value[field]=v } }
                try Self.validate(value)
                if BuddyRoutineGoals.unsupported(value["goal"] as? String ?? "") { throw BuddyWorkerFailure(message:"A scheduled run is a background task: it can use files, the browser and status tools, but it cannot start coding sessions or give teammates work. Put team work in the team plan instead.",code:"unsupported_in_background") }
                let timingChanged=index.map {i in ["hour","minute","weekdays","timeZone"].contains{field in !NSDictionary(dictionary:["value":routines[i][field]!]).isEqual(to:["value":value[field]!])}} ?? true
                if timingChanged {value["nextRun"]=ISO8601DateFormatter().string(from:try Self.next(after:now,rule:value))}
                if index==nil {value["status"]="active";value["lastError"]=""}
                // Repeated tool calls cannot create duplicate copies of the exact same routine.
                if action=="create",let existing=routines.first(where:{r in ["workspace","agentId","title","goal","query","timeZone","browserAgentId","browserOrigin"].allSatisfy{r[$0] as? String==value[$0] as? String} && r["hour"] as? Int==value["hour"] as? Int && r["minute"] as? Int==value["minute"] as? Int && r["weekdays"] as? [Int]==value["weekdays"] as? [Int]}) { return ["saved":true,"routine":existing] }
                if let index { routines[index]=value } else { routines.append(value) }
                try persist();return ["saved":true,"routine":value,"requiresMacAwake":true]
            }
            guard let i=routines.firstIndex(where:{$0["id"] as? String==args["routineID"] as? String && $0["workspace"] as? String==workspace && $0["agentId"] as? String==agent}) else { throw BuddyWorkerFailure(message:"This routine is no longer available.") }
            if action=="delete" { routines.remove(at:i);try persist();return ["deleted":true] }
            guard ["pause","resume"].contains(action) else { throw BuddyWorkerFailure(message:"Choose create, update, pause, resume, delete or list.") }
            routines[i]["status"]=action=="pause" ? "paused":"active";routines[i]["lastError"]=""
            if action=="resume" { routines[i]["nextRun"]=try Self.resumedNext(routines[i],now:now);routines[i]["attentionClearedAfter"]=routines[i]["lastTaskID"] as? String ?? "" }
            try persist();return ["saved":true,"routine":routines[i]]
        } catch { routines=old;try? persist();throw error }
    }
    /// Where a routine that is set going again picks up: a slot it missed within the last day still runs, once; an older one is skipped, never
    /// caught up in a burst.
    static func resumedNext(_ rule:[String:Any],now:Date) throws -> String {
        let f=ISO8601DateFormatter()
        if let stamp=rule["nextRun"] as? String,let due=f.date(from:stamp),due<=now,now.timeIntervalSince(due)<24*3600 { return stamp }
        return f.string(from:try next(after:now,rule:rule))
    }
    func browserScope(for job:[String:Any])->[String:Any]? {
        guard let rule=routines.first(where:{$0["id"] as? String==job["routineID"] as? String && $0["workspace"] as? String==job["workspace"] as? String && $0["agentId"] as? String==job["agentId"] as? String}),let owner=rule["browserAgentId"] as? String,let origin=rule["browserOrigin"] as? String else{return nil}
        return ["browserAgentId":owner,"browserOrigin":origin]
    }
    /// `supervisor` is the team's supervisor now, if there is one: a run records it like any task, so its stops reach the supervisor first.
    func runNow(_ id:String,workspace:String,agent:String,requestID:String,store:BuddyWorkerStore,supervisor:String?=nil) throws -> [String:Any] {
        guard UUID(uuidString:requestID) != nil,let index=routines.firstIndex(where:{$0["id"] as? String==id && $0["workspace"] as? String==workspace && $0["agentId"] as? String==agent}),routines[index]["status"] as? String=="active" else{throw BuddyWorkerFailure(message:"Choose an active saved routine to run now.")}
        let rule=routines[index]
        let request="routine:manual:"+id+":"+requestID
        if let existing=store.jobs.first(where:{$0["workspace"] as? String==workspace && $0["requestId"] as? String==request}) {return existing}
        let series=rule["routineSeriesID"] as? String
        let prior=store.jobs.last{$0["workspace"] as? String==workspace && $0["agentId"] as? String==agent && ($0["routineID"] as? String==id || series != nil && $0["routineSeriesID"] as? String==series)}
        guard prior==nil || BuddyWorkerStore.terminal.contains(prior?["status"] as? String ?? "") else{throw BuddyWorkerFailure(message:"This routine already has unfinished work. Open its current task instead of starting another scan.")}
        let job=try store.create(workspace:workspace,agent:agent,requestId:request,title:rule["title"] as! String,goal:rule["goal"] as! String,kind:rule["kind"] as! String,provider:rule["provider"] as! String,budget:rule["provider"] as? String=="claude" ? BuddyRunLimit.none:(rule["budgetUSD"] as? Double ?? 0),model:rule["model"] as? String)
        var fields:[String:Any]=["routineID":id,"inboxQuery":rule["query"] ?? "","previousRoutineResult":prior?["result"] ?? "","manualRun":true]
        for key in ["routineSeriesID","browserAgentId","browserOrigin"] {if let value=rule[key]{fields[key]=value}}
        if let supervisor,!supervisor.isEmpty {fields["supervisorId"]=supervisor}
        let saved=try store.update(job["id"] as! String,fields)
        let old=routines;routines[index]["lastTaskID"]=saved["id"]
        do{try persist()}catch{routines=old;throw error}
        return saved
    }
    /// After "Switch all agents to …" (a new `switchID` in the AI settings) each routine of the workspace moves, once, to its agent's provider and
    /// model. Otherwise a routine keeps the provider it was saved with: changing one agent's model never moves its routines to another provider.
    /// Returns whether this switch was new to the store.
    @discardableResult func follow(workspace:String,switchID:String,agentModel:(String) throws->(provider:String,model:String)?) throws -> Bool {
        let key="routines.followedSwitch."+workspace
        guard !switchID.isEmpty,try db.meta(key) != switchID else {return false}
        let original=routines
        do {
            for i in routines.indices where routines[i]["workspace"] as? String==workspace {
                guard let agent=routines[i]["agentId"] as? String,let now=try agentModel(agent),["chatgpt","claude"].contains(now.provider),now.provider != routines[i]["provider"] as? String else {continue}
                let budget:Double=now.provider=="claude" ? BuddyRunLimit.none:0
                routines[i]["provider"]=now.provider;routines[i]["budgetUSD"]=budget
                if now.model.isEmpty {routines[i].removeValue(forKey:"model")} else {routines[i]["model"]=now.model}
            }
            if !NSArray(array:original).isEqual(to:routines) {try persist()}
            try db.setMeta(key,switchID)
            return true
        } catch {routines=original;try? persist();throw error}
    }
    func resumeBlockedBy(_ job:[String:Any],now:Date=Date()) throws {
        let original=routines
        do {
            for i in routines.indices where routines[i]["status"] as? String=="needs_attention" && routines[i]["workspace"] as? String==job["workspace"] as? String && routines[i]["agentId"] as? String==job["agentId"] as? String {
                let same=routines[i]["lastTaskID"] as? String==job["id"] as? String || job["routineSeriesID"] != nil && routines[i]["routineSeriesID"] as? String==job["routineSeriesID"] as? String
                guard same,routines[i]["lastError"] as? String==BuddyRoutineHealth.attentionError else{continue}
                routines[i]["status"]="active";routines[i]["lastError"]="";routines[i]["nextRun"]=try Self.resumedNext(routines[i],now:now)
                routines[i]["attentionClearedAfter"]=routines[i]["lastTaskID"] as? String ?? ""
            }
            if !NSArray(array:original).isEqual(to:routines){try persist()}
        } catch {routines=original;throw error}
    }
    /// `supervisor` is the team's supervisor now, if there is one: each run records it, as `runNow` does.
    func enqueueDue(store:BuddyWorkerStore,workspace:String,now:Date=Date(),supervisor:String?=nil) throws {
        let original=routines
        do {
            /// The latest run of the routine's series (or of the routine): what the next run builds on, and what it must not overlap.
            func lastRun(_ r:[String:Any])->[String:Any]? {
                let id=r["id"] as? String ?? "",series=r["routineSeriesID"] as? String
                return store.jobs.last{$0["workspace"] as? String==workspace && $0["agentId"] as? String==r["agentId"] as? String && ($0["routineID"] as? String==id || series != nil && $0["routineSeriesID"] as? String==series)}
            }
            /// The routine's own runs, oldest first. Its health is judged on these alone.
            func ownRuns(_ r:[String:Any])->[[String:Any]] {
                let id=r["id"] as? String ?? ""
                return store.jobs.filter{$0["workspace"] as? String==workspace && $0["agentId"] as? String==r["agentId"] as? String && $0["routineID"] as? String==id}
            }
            func healthy(_ r:[String:Any])->Bool { !BuddyRoutineHealth.needsAttention(ownRuns(r),clearedAfter:r["attentionClearedAfter"] as? String) }
            // Routines that were stopped for exactly that reason are set going again once their own runs no longer need anyone, keeping a slot they
            // missed in the meantime.
            for i in routines.indices where routines[i]["workspace"] as? String==workspace && routines[i]["status"] as? String=="needs_attention" && routines[i]["lastError"] as? String==BuddyRoutineHealth.attentionError && healthy(routines[i]) {
                routines[i]["status"]="active";routines[i]["lastError"]="";routines[i]["nextRun"]=try Self.resumedNext(routines[i],now:now)
            }
            for i in routines.indices where routines[i]["workspace"] as? String==workspace && routines[i]["status"] as? String=="active" {
                let r=routines[i],id=r["id"] as! String
                let series=r["routineSeriesID"] as? String
                let prior=lastRun(r)
                if !healthy(r) { routines[i]["status"]="needs_attention";routines[i]["lastError"]=BuddyRoutineHealth.attentionError;continue }
                // The series' latest run only keeps two runs of the same work from overlapping; another routine's stop is not this one's.
                if BuddyRoutineHealth.inFlight(prior) || BuddyRoutineHealth.inFlight(ownRuns(r).last) { continue }
                guard let due=r["nextRun"] as? String,let date=ISO8601DateFormatter().date(from:due),date<=now else { continue }
                let job=try store.create(workspace:workspace,agent:r["agentId"] as! String,requestId:"routine:"+id+":"+due,title:r["title"] as! String,goal:r["goal"] as! String,kind:r["kind"] as! String,provider:r["provider"] as! String,budget:r["provider"] as? String=="claude" ? BuddyRunLimit.none:(r["budgetUSD"] as? Double ?? 0),model:r["model"] as? String)
                // Queue creation is idempotent if the process dies before saving nextRun.
                var fields:[String:Any]=["routineID":id,"inboxQuery":r["query"] as! String,"previousRoutineResult":prior?["result"] ?? "","scheduledFor":due]
                if let supervisor,!supervisor.isEmpty {fields["supervisorId"]=supervisor}
                try store.update(job["id"] as! String,fields)
                if let series {try store.update(job["id"] as! String,["routineSeriesID":series])}
                if let owner=r["browserAgentId"] as? String,let origin=r["browserOrigin"] as? String {try store.update(job["id"] as! String,["browserAgentId":owner,"browserOrigin":origin])}
                routines[i]["lastTaskID"]=job["id"];routines[i]["lastScheduledFor"]=due
                routines[i]["nextRun"]=ISO8601DateFormatter().string(from:try Self.next(after:now,rule:r))
                // Active siblings that also missed their slot move on, so a wake never sends a burst. A paused or parked sibling keeps the slot it
                // missed, so setting it going again within the day still runs it.
                if let series {for j in routines.indices where j != i && routines[j]["routineSeriesID"] as? String==series && routines[j]["workspace"] as? String==workspace && routines[j]["agentId"] as? String==r["agentId"] as? String && routines[j]["status"] as? String=="active" {
                    if let stamp=routines[j]["nextRun"] as? String,let missed=ISO8601DateFormatter().date(from:stamp),missed<=now {routines[j]["nextRun"]=ISO8601DateFormatter().string(from:try Self.next(after:now,rule:routines[j]))}
                }}
            }
            if !NSArray(array:original).isEqual(to:routines) { try persist() }
        } catch { routines=original;throw error }
    }
}

/// Brings the old JSON files (`tasks.json`, `tasks-archive-*.json`, `routines.json`) into the database, once.
///
/// Before anything is changed the files are copied into a ZIP in `Worker/Backups`. They are checked exactly as the old loaders checked them,
/// so a damaged file stops the worker with the files untouched. The import is one transaction that also counts what it wrote. Only after
/// it has committed are the files renamed to `*.migrated`; they are never deleted. From then on the database is the only writer, and a file
/// with the old name is left alone, because importing it again could overwrite newer work.
@MainActor enum BuddyOperationsMigration {
    /// Test hook: runs after the import has committed and before the old files are set aside.
    static var afterImport: (() -> Void)?
    private struct Source { let name: String; let url: URL; let data: Data; var rows = 0 }

    static func importLegacy(into db: BuddyOperationsDB, directory: URL, now: Date = Date()) throws {
        if let record = try db.meta("migration") { setAside(record: record, directory: directory); return }
        let fm = FileManager.default, iso = ISO8601DateFormatter()
        func load(_ name: String, limit: Int) throws -> Source? {
            let url = directory.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path) else { return nil }
            let data = try Data(contentsOf: url)
            guard data.count <= limit else { throw BuddyWorkerFailure(message: "\(name) is too large to verify. Restore it before starting the worker.") }
            return Source(name: name, url: url, data: data)
        }
        func object(_ source: Source, version: Int = 1) throws -> [String: Any] {
            guard let saved = try? JSONSerialization.jsonObject(with: source.data) as? [String: Any], saved["version"] as? Int == version else { throw BuddyWorkerFailure(message: "Buddy couldn’t verify \(source.name). Restore it before starting the worker.") }
            return saved
        }
        func validTask(_ task: [String: Any]) -> Bool { (task["id"] as? String).flatMap(UUID.init(uuidString:)) != nil && (task["workspace"] as? String).flatMap(UUID.init(uuidString:)) != nil }

        var sources: [Source] = [], paused = false
        var live: [[String: Any]] = [], archived: [[String: Any]] = [], routines: [[String: Any]] = [], skipped = 0
        if var tasksFile = try load("tasks.json", limit: 32 * 1024 * 1024) {
            let saved = try object(tasksFile)
            guard let tasks = saved["tasks"] as? [[String: Any]], tasks.count <= 1000, tasks.allSatisfy(validTask), Set(tasks.compactMap { $0["id"] as? String }).count == tasks.count else { throw BuddyWorkerFailure(message: "Buddy couldn’t verify its saved background tasks. Restore tasks.json before starting the worker.") }
            let requests = tasks.map { "\($0["workspace"] as? String ?? "")|\($0["agentId"] as? String ?? "")|\($0["requestId"] as? String ?? "")" }.filter { !$0.hasSuffix("|") }
            guard Set(requests).count == requests.count else { throw BuddyWorkerFailure(message: "Two saved tasks claim the same request. Restore tasks.json before starting the worker.") }
            live = tasks; paused = saved["paused"] as? Bool ?? false; tasksFile.rows = tasks.count; sources.append(tasksFile)
        }
        let liveIDs = Set(live.compactMap { $0["id"] as? String })
        var archivedIDs = Set<String>()
        for name in try fm.contentsOfDirectory(atPath: directory.path).filter({ $0.hasPrefix("tasks-archive-") && $0.hasSuffix(".json") }).sorted() {
            guard var file = try load(name, limit: 32 * 1024 * 1024) else { continue }
            guard let tasks = try object(file)["tasks"] as? [[String: Any]], tasks.allSatisfy(validTask) else { throw BuddyWorkerFailure(message: "Buddy couldn’t verify \(name). Restore it before starting the worker.") }
            for task in tasks {
                guard let id = task["id"] as? String else { continue }
                if liveIDs.contains(id) || !archivedIDs.insert(id).inserted { skipped += 1 } else { archived.append(task) }
            }
            file.rows = tasks.count; sources.append(file)
        }
        if var routinesFile = try load("routines.json", limit: 8 * 1024 * 1024) {
            let saved = try object(routinesFile)
            guard let values = saved["routines"] as? [[String: Any]], values.count <= 100, Set(values.compactMap { $0["id"] as? String }).count == values.count else { throw BuddyWorkerFailure(message: "Buddy couldn't verify saved routines. Restore routines.json before starting the worker.") }
            for value in values {
                try BuddyRoutineStore.validate(value)
                guard let id = value["id"] as? String, UUID(uuidString: id) != nil, let next = value["nextRun"] as? String, iso.date(from: next) != nil else { throw BuddyWorkerFailure(message: "A saved routine has invalid timing. Repair routines.json before starting.") }
            }
            routines = values; routinesFile.rows = values.count; sources.append(routinesFile)
        }

        let stamp = iso.string(from: now)
        var record: [String: Any] = ["at": stamp, "live": live.count, "archived": archived.count, "routines": routines.count, "skippedDuplicates": skipped,
                                     "sources": sources.map { ["name": $0.name, "sha256": digest($0.data), "bytes": $0.data.count, "rows": $0.rows] as [String: Any] }]
        if !sources.isEmpty { record["backup"] = try backUp(sources, in: directory) }

        do {
            try db.transaction {
                for task in archived { try BuddyWorkerStore.insert(task, archived: true, in: db) }
                for task in live { try BuddyWorkerStore.insert(task, archived: false, in: db) }
                for routine in routines { try BuddyRoutineStore.insert(routine, body: try BuddyOperationsDB.encode(routine), id: routine["id"] as? String ?? "", in: db) }
                try db.setMeta("paused", paused ? "1" : "0")
                // Count what was written before it is allowed to commit.
                let liveCount = try db.rows("SELECT COUNT(*) FROM tasks WHERE archived = 0").first?.first?.int ?? -1
                let archivedCount = try db.rows("SELECT COUNT(*) FROM tasks WHERE archived = 1").first?.first?.int ?? -1
                let routineCount = try db.rows("SELECT COUNT(*) FROM routines").first?.first?.int ?? -1
                guard Int(liveCount) == live.count, Int(archivedCount) == archived.count, Int(routineCount) == routines.count else { throw BuddyWorkerFailure(message: "The import did not match the saved files, so nothing was changed. Your files are untouched.") }
                try db.setMeta("migration", try BuddyOperationsDB.encode(record))
            }
        } catch let failure as BuddyOperationsFailure where failure.message.contains("UNIQUE") {
            throw BuddyWorkerFailure(message: "Two saved tasks claim the same request. Restore tasks.json before starting the worker.")
        }
        afterImport?()
        if let saved = try db.meta("migration") { setAside(record: saved, directory: directory) }
    }

    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// Copies the files into a ZIP before anything else happens. The name comes from the files' contents, so a worker that keeps failing
    /// to start does not pile up copies. Returns the ZIP's name.
    private static func backUp(_ sources: [Source], in directory: URL) throws -> String {
        let fm = FileManager.default
        let folder = directory.appendingPathComponent("Backups", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let id = digest(Data(sources.map { $0.name + ":" + digest($0.data) }.joined(separator: "\n").utf8)).prefix(16)
        let zip = folder.appendingPathComponent("pre-database-\(id).zip")
        func tool(_ path: String, _ arguments: [String]) throws -> String {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments; process.standardOutput = pipe; process.standardError = Pipe()
            try process.run(); let output = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw BuddyWorkerFailure(message: "Buddy couldn’t make a backup of its saved tasks, so it did not change them.") }
            return String(decoding: output, as: UTF8.self)
        }
        func verified() -> Bool {
            guard let listing = try? tool("/usr/bin/unzip", ["-Z1", zip.path]), (try? tool("/usr/bin/unzip", ["-tq", zip.path])) != nil else { return false }
            return Set(listing.split(separator: "\n").map(String.init)) == Set(sources.map(\.name))
        }
        if fm.fileExists(atPath: zip.path), verified() { return zip.lastPathComponent }
        try? fm.removeItem(at: zip)
        _ = try tool("/usr/bin/zip", ["-q", "-j", "-X", zip.path] + sources.map(\.url.path))
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: zip.path)
        guard verified() else { try? fm.removeItem(at: zip); throw BuddyWorkerFailure(message: "Buddy couldn’t verify the backup of its saved tasks, so it did not change them.") }
        return zip.lastPathComponent
    }

    /// Renames the old files that were imported (same contents as recorded) to `*.migrated`. A file with the old name but different contents
    /// is left where it is.
    private static func setAside(record: String, directory: URL) {
        let fm = FileManager.default
        guard let saved = try? BuddyOperationsDB.decode(record), let sources = saved["sources"] as? [[String: Any]] else { return }
        for source in sources {
            guard let name = source["name"] as? String, let hash = source["sha256"] as? String else { continue }
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url), digest(data) == hash else { continue }
            var target = directory.appendingPathComponent(name + ".migrated")
            if fm.fileExists(atPath: target.path) { target = directory.appendingPathComponent(name + "." + UUID().uuidString.prefix(8) + ".migrated") }
            try? fm.moveItem(at: url, to: target)
        }
    }
}

// MARK: - Settings changed on the person's word, and standing rules

struct BuddySettingChange {
    let id: String, workspace: String, scope: String, agentID: String, field: String
    let old: Any?, new: Any?
    let actor: String, source: String, quote: String, status: String, risk: String, adopter: String, adopted: Bool, seq: Int, createdAt: String
}

struct BuddyRule {
    let id: String, workspace: String, agentID: String, kind: String, text: String, quote: String, params: [String: Any], status: String, graduated: Bool, actor: String, createdAt: String
    var reviewFirst: Int { params["reviewFirst"] as? Int ?? 0 }
    var appliesTo: [String] { params["appliesTo"] as? [String] ?? ["browser"] }
    var taskKinds: [String] { params["taskKinds"] as? [String] ?? [] }
    /// Whether it lets the agent go ahead without asking (once it has earned that). A rule that only asks more often is always safe.
    var relaxes: Bool { params["then"] as? String == "proceed" }
}

/// What may be changed on someone's word, what each value may be, and what needs one tap first. A change that raises spending or access is the only
/// kind that waits for the person; everything else applies at once, and each change keeps its old value so it can be undone.
enum BuddyAgentChanges {
    static let agentFields: Set<String> = ["name", "role", "instructions", "avatarShape", "avatarColor", "hidden", "model", "dailyLimitUSD", "proactive", "tools.web", "tools.projectFiles", "tools.desktop"]
    static let workspaceFields: Set<String> = ["dailyLimitUSD", "teamSupervisor", "teamCheckInsEnabled", "teamCheckInIntervalMinutes", "teamCheckInModel", "teamDailyLimitUSD"]
    /// Fields the page keeps in its own state, so the page has to adopt a change to them.
    static let pageFields: Set<String> = ["name", "avatarShape", "avatarColor", "hidden", "tools.web", "tools.projectFiles", "tools.desktop"]
    /// Fields the app keeps in the agent’s saved profile (where the person’s own edits and the setup interview write them), so the app adopts them.
    static let appFields: Set<String> = ["role", "instructions"]
    static func adopter(scope: String, field: String) -> String { scope == "agent" ? (pageFields.contains(field) ? "page" : appFields.contains(field) ? "app" : "") : "" }
    /// Must match BuddyAvatar (tests that compile both check it); repeated here so the worker core stands alone.
    static let avatarShapes = ["diamond", "sphere", "hex", "pill"]
    static let avatarColors = ["lilac", "blue", "peach", "mint", "red", "gold", "cobalt"]
    static let legacyShapes = ["star": "diamond", "pebble": "sphere", "cube": "hex", "clover": "pill"]
    static func shape(_ value: String) -> String? { let id = legacyShapes[value] ?? value; return avatarShapes.contains(id) ? id : nil }
    static func fields(_ scope: String) -> Set<String> { scope == "workspace" ? workspaceFields : agentFields }
    static func fail(_ message: String) -> BuddyWorkerFailure { BuddyWorkerFailure(message: message) }

    /// Quotes may differ from the message in capitals, spacing and punctuation style, and that is not a reason to refuse a genuine request.
    static func normalized(_ text: String) -> String {
        var out = text.lowercased()
        for (from, to) in [("’", "'"), ("‘", "'"), ("“", "\""), ("”", "\""), ("–", "-"), ("—", "-"), ("…", "...")] { out = out.replacingOccurrences(of: from, with: to) }
        return out.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
    /// Words that carry no request on their own. A reply made only of these ("try again", "yes, go ahead", "do it") agrees to something or asks
    /// for a retry; it never says what to change, so it cannot be the quote that authorizes a change.
    static let fillerWords: Set<String> = ["try", "again", "retry", "please", "pls", "yes", "yeah", "yep", "yup", "ok", "okay", "sure", "go", "ahead", "do", "it", "that", "this", "continue", "proceed", "thanks", "thank", "you", "fine", "now", "just", "then", "so", "and", "the", "a", "on", "more", "once", "one", "time", "good", "great", "sounds", "like", "let", "s", "lets", "keep", "going", "next", "move", "up", "me", "for"]
    static func isFiller(_ quote: String) -> Bool {
        let words = normalized(quote).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        return words.isEmpty || words.allSatisfy { fillerWords.contains($0) }
    }
    static func quoteAuthorized(_ quote: String, in text: String) -> Bool {
        let q = normalized(quote)
        return q.count >= 8 && !isFiller(q) && normalized(text).contains(q)
    }
    /// Whether the person's quoted words are about a spending limit at all: they give an amount and speak of money or a limit. "Try setting up its
    /// agents again" is a real request, but not one that sets a limit.
    static func limitQuote(_ quote: String) -> Bool {
        quote.range(of: #"\d"#, options: .regularExpression) != nil && quote.range(of: #"(?i)\$|dollar|bucks|usd|limit|cap|budget|spend"#, options: .regularExpression) != nil
    }
    /// Settings whose narrowing the supervisor, or an agent's manager, may decide on its own judgement. Limits are never among them.
    static let judgementFields: Set<String> = ["tools.web", "tools.projectFiles", "tools.desktop", "hidden", "model", "proactive", "teamCheckInIntervalMinutes"]
    /// A change that only takes reach away: a tool switched off, being hidden or shown, a different model, proactive updates off, check-ins less often.
    static func narrows(field: String, old: Any?, new: Any?) -> Bool {
        switch field {
        case "tools.web", "tools.projectFiles", "tools.desktop": return (old as? Bool) != false && (new as? Bool) == false
        case "hidden", "model": return true
        case "proactive": return (new as? Bool) == false
        case "teamCheckInIntervalMinutes": guard let before = number(old), let after = number(new) else { return false }; return after > before
        default: return false
        }
    }
    private static func boolean(_ value: Any?, _ field: String) throws -> Bool {
        if let flag = value as? Bool { return flag }
        if let text = value as? String, ["true", "on", "yes"].contains(text.lowercased()) { return true }
        if let text = value as? String, ["false", "off", "no"].contains(text.lowercased()) { return false }
        throw fail("Choose true or false for \(field).")
    }
    private static func text(_ value: Any?, _ field: String, _ limit: Int) throws -> String {
        guard let raw = value as? String else { throw fail("Give \(field) as text.") }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= limit, !trimmed.contains("\0") else { throw fail("\(field.prefix(1).uppercased() + field.dropFirst()) must be 1 to \(limit) characters.") }
        return trimmed
    }
    private static func money(_ value: Any?, _ field: String, allowNone: Bool, minimum: Double = 0) throws -> Double? {
        if value == nil || value is NSNull || (value as? String)?.lowercased() == "none" { guard allowNone else { throw fail("Choose an amount in dollars for \(field).") }; return nil }
        let amount = (value as? Double) ?? (value as? Int).map(Double.init) ?? (value as? String).flatMap(Double.init)
        guard let amount, amount.isFinite, amount >= minimum, amount <= 100000 else { throw fail("Choose \(field) between $\(minimum == 0 ? "0" : String(format: "%.2f", minimum)) and $100,000, or \"none\" for no limit.") }
        return amount
    }
    /// The value as it will be stored, or a plain message about what is allowed.
    static func normalize(scope: String, field: String, value: Any?) throws -> Any? {
        guard fields(scope).contains(field) else { throw fail("\(scope == "workspace" ? "Workspace" : "Agent") settings you can change: " + fields(scope).sorted().joined(separator: ", ") + ".") }
        switch field {
        case "name": return try text(value, "name", 40)
        case "role": return try text(value, "role", 55)
        case "instructions": return try text(value, "instructions", 1500)
        case "avatarShape":
            guard let raw = value as? String, let shape = shape(raw) else { throw fail("Choose a figure from: " + avatarShapes.joined(separator: ", ") + ".") }
            return shape
        case "avatarColor":
            guard let raw = value as? String, avatarColors.contains(raw.lowercased()) else { throw fail("Choose a colour from: " + avatarColors.joined(separator: ", ") + ".") }
            return raw.lowercased()
        case "hidden", "proactive", "tools.web", "tools.projectFiles", "tools.desktop", "teamCheckInsEnabled": return try boolean(value, field)
        case "model":
            let parsed = (value as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            guard let model = (value as? [String: Any]) ?? parsed, let provider = model["provider"] as? String, ["chatgpt", "claude"].contains(provider), let name = model["model"] as? String, name.isEmpty || name.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$"#, options: .regularExpression) != nil else {
                throw fail("Give the model as {\"provider\": \"claude\" or \"chatgpt\", \"model\": the model name}.")
            }
            if provider == "claude", !name.isEmpty, !name.hasPrefix("claude-") { throw fail("Claude models are named like claude-sonnet-5-5, claude-opus-5-5 or claude-haiku-5-5.") }
            return ["provider": provider, "model": name]
        case "dailyLimitUSD": return try money(value, field, allowNone: true)
        case "teamDailyLimitUSD": return try money(value, field, allowNone: false, minimum: 0.1)
        case "teamSupervisor":
            guard let id = value as? String, UUID(uuidString: id) != nil else { throw fail("Choose one of your agents by name.") }
            return id
        case "teamCheckInIntervalMinutes":
            let minutes = (value as? Int) ?? (value as? Double).map { Int($0) } ?? (value as? String).flatMap(Int.init)
            guard let minutes, [5, 15, 30, 60].contains(minutes) else { throw fail("Choose 5, 15, 30 or 60 minutes.") }
            return minutes
        case "teamCheckInModel":
            if value == nil || value is NSNull || (value as? String)?.isEmpty == true { return nil }
            guard let name = value as? String, name.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$"#, options: .regularExpression) != nil else { throw fail("Give a valid model name, or leave it empty for the default.") }
            return name
        default: throw fail("That setting cannot be changed.")
        }
    }
    private static func number(_ value: Any?) -> Double? { (value as? Double) ?? (value as? Int).map(Double.init) ?? (value as? NSNumber)?.doubleValue }
    /// "confirm" for a change that raises what an agent may spend or reach, "low" for everything else.
    static func risk(field: String, old: Any?, new: Any?) -> String {
        switch field {
        case "tools.web", "tools.projectFiles", "tools.desktop", "teamCheckInsEnabled": return (new as? Bool) == true && (old as? Bool) != true ? "confirm" : "low"
        case "dailyLimitUSD", "teamDailyLimitUSD":
            guard let old = number(old) else { return "low" }              // adding a cap lowers what can be spent
            guard let new = number(new) else { return "confirm" }          // removing a cap raises it
            return new > old ? "confirm" : "low"
        case "teamCheckInIntervalMinutes": return (number(new) ?? 60) < (number(old) ?? 0) ? "confirm" : "low"
        default: return "low"
        }
    }
    static func encode(_ value: Any?) -> String { guard let value, !(value is NSNull) else { return "null" }; return (try? BuddyOperationsDB.encode(["v": value]))?.replacingOccurrences(of: "{\"v\":", with: "").dropLast().description ?? "null" }
    static func decode(_ text: String) -> Any? {
        guard let value = (try? BuddyOperationsDB.decode("{\"v\":" + text + "}"))?["v"], !(value is NSNull) else { return nil }
        return value
    }

    /// Puts changes nobody has carried into their home yet onto a copy of the state, so everything that reads the state sees them at once. Applying
    /// the same changes again gives the same result.
    static func overlay(_ state: [String: Any], _ changes: [BuddySettingChange]) -> [String: Any] {
        guard !changes.isEmpty else { return state }
        var out = state, agents = out["agents"] as? [[String: Any]] ?? [], hidden = out["hiddenAgents"] as? [String] ?? []
        for change in changes.sorted(by: { $0.seq < $1.seq }) where !change.adopter.isEmpty && change.scope == "agent" {
            // An undo is recorded as a change of its own (restoring the old value), so only changes that took effect are carried.
            guard change.status == "applied", let i = agents.firstIndex(where: { $0["id"] as? String == change.agentID }) else { continue }
            let value: Any? = change.new
            switch change.field {
            case "name", "role", "avatarShape", "avatarColor": if let value { agents[i][change.field] = value }
            case "instructions": if let value { agents[i]["description"] = value }
            case "hidden": hidden.removeAll { $0 == change.agentID }; if (value as? Bool) == true { hidden.append(change.agentID) }
            default:
                if change.field.hasPrefix("tools."), let flag = value as? Bool { var tools = agents[i]["tools"] as? [String: Bool] ?? [:]; tools[String(change.field.dropFirst(6))] = flag; agents[i]["tools"] = tools }
            }
        }
        out["agents"] = agents; out["hiddenAgents"] = hidden
        return out
    }
    static func change(_ row: [BuddyOperationsDB.Column]) -> BuddySettingChange? {
        guard row.count >= 16, let id = row[0].string else { return nil }
        return BuddySettingChange(id: id, workspace: row[1].string ?? "", scope: row[2].string ?? "", agentID: row[3].string ?? "", field: row[4].string ?? "", old: BuddyAgentChanges.decode(row[5].string ?? "null"), new: BuddyAgentChanges.decode(row[6].string ?? "null"),
                                  actor: row[7].string ?? "", source: row[8].string ?? "", quote: row[9].string ?? "", status: row[10].string ?? "", risk: row[11].string ?? "low", adopter: row[12].string ?? "", adopted: row[13].int == 1, seq: Int(row[14].int ?? 0), createdAt: row[15].string ?? "")
    }
    /// Read-only: the changes nobody has carried home yet (for one adopter, or for all). Any process that reads the workspace uses this.
    static func unadopted(support: URL, workspace: String, adopter: String? = nil) -> [BuddySettingChange] {
        let directory = support.appendingPathComponent("Worker")
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(BuddyOperationsDB.fileName).path), let db = try? BuddyOperationsDB(directory: directory, existing: true),
              let rows = try? db.rows("SELECT \(columns) FROM setting_changes WHERE workspace = ? AND adopter <> '' AND adopted = 0 AND status = 'applied' ORDER BY seq", [.text(workspace)]) else { return [] }
        return rows.compactMap(change).filter { adopter == nil || $0.adopter == adopter }
    }
    static let columns = "id, workspace, scope, agent_id, field, old_value, new_value, actor, source, quote, status, risk, adopter, adopted, seq, created_at"
}

extension BuddyWorkerStore {
    private static let changeColumns = BuddyAgentChanges.columns
    private static func stamp() -> String { ISO8601DateFormatter().string(from: Date()) }

    func recordChange(workspace: String, scope: String, agent: String, field: String, old: Any?, new: Any?, actor: String, source: String, quote: String, status: String, risk: String) throws -> String {
        let id = UUID().uuidString, now = Self.stamp()
        try db.transaction {
            let seq = Int(try db.rows("SELECT COALESCE(MAX(seq), 0) + 1 FROM setting_changes WHERE workspace = ?", [.text(workspace)]).first?.first?.int ?? 1)
            try db.run("INSERT INTO setting_changes(id, workspace, scope, agent_id, field, old_value, new_value, actor, source, quote, status, risk, adopter, adopted, seq, created_at, updated_at) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?)",
                       [.text(id), .text(workspace), .text(scope), .text(agent), .text(field), .text(BuddyAgentChanges.encode(old)), .text(BuddyAgentChanges.encode(new)), .text(actor), .text(source), .text(String(quote.prefix(500))), .text(status), .text(risk),
                        .text(BuddyAgentChanges.adopter(scope: scope, field: field)), .int(Int64(seq)), .text(now), .text(now)])
        }
        return id
    }
    func change(_ id: String) throws -> BuddySettingChange? {
        try db.rows("SELECT \(Self.changeColumns) FROM setting_changes WHERE id = ?", [.text(id)]).first.flatMap(BuddyAgentChanges.change)
    }
    func changes(workspace: String, agent: String? = nil, limit: Int = 50) throws -> [BuddySettingChange] {
        let rows = agent == nil ? try db.rows("SELECT \(Self.changeColumns) FROM setting_changes WHERE workspace = ? ORDER BY seq DESC LIMIT ?", [.text(workspace), .int(Int64(limit))])
            : try db.rows("SELECT \(Self.changeColumns) FROM setting_changes WHERE workspace = ? AND agent_id = ? ORDER BY seq DESC LIMIT ?", [.text(workspace), .text(agent ?? ""), .int(Int64(limit))])
        return rows.compactMap(BuddyAgentChanges.change)
    }
    /// Changes an adopter ("page" or "app") has to carry into its own state, and has not yet.
    func unadoptedChanges(workspace: String, adopter: String) throws -> [BuddySettingChange] {
        try db.rows("SELECT \(Self.changeColumns) FROM setting_changes WHERE workspace = ? AND adopter = ? AND adopted = 0 AND status = 'applied' ORDER BY seq", [.text(workspace), .text(adopter)]).compactMap(BuddyAgentChanges.change)
    }
    func adoptChanges(workspace: String, adopter: String, ids: [String]) throws {
        guard ids.count <= 500 else { throw BuddyWorkerFailure(message: "Too many changes at once.") }
        try db.transaction { for id in ids { try db.run("UPDATE setting_changes SET adopted = 1 WHERE id = ? AND workspace = ? AND adopter = ?", [.text(id), .text(workspace), .text(adopter)]) } }
    }
    func setChange(_ id: String, status: String, old: Any?? = nil) throws {
        try db.transaction {
            if let old { try db.run("UPDATE setting_changes SET old_value = ? WHERE id = ?", [.text(BuddyAgentChanges.encode(old)), .text(id)]) }
            try db.run("UPDATE setting_changes SET status = ?, updated_at = ? WHERE id = ?", [.text(status), .text(Self.stamp()), .text(id)])
        }
    }
    /// A question or notice that is not about a task (a change waiting for the person's OK, a rule that has earned its freedom).
    /// `audience` is who has to act on it: "user" (the person) or "supervisor".
    func openDecision(workspace: String, id: String, agent: String, kind: String, title: String, question: String, label: String, payload: [String: Any], audience: String = "user") throws {
        guard ["confirm", "notice", "escalation"].contains(kind) else { throw BuddyWorkerFailure(message: "Unknown kind of notice.") }
        guard ["user", "supervisor"].contains(audience) else { throw BuddyWorkerFailure(message: "A notice is for the user or the supervisor.", code: "invalid_input") }
        try db.run("INSERT OR IGNORE INTO decisions(id, workspace, agent_id, task_id, kind, title, question, label, payload, created_at, audience) VALUES(?, ?, ?, '', ?, ?, ?, ?, ?, ?, ?)",
                   [.text(id), .text(workspace), .text(agent), .text(kind), .text(String(title.prefix(300))), .text(String(question.prefix(1200))), .text(label), .text((try? BuddyOperationsDB.encode(payload)) ?? "{}"), .text(Self.stamp()), .text(audience)])
    }
    func closeDecision(id: String, resolution: String) throws {
        try db.run("UPDATE decisions SET status = 'resolved', resolution = ?, resolved_at = ? WHERE id = ? AND status = 'open'", [.text(resolution), .text(Self.stamp()), .text(id)])
    }
    /// Someone (the person, or an agent such as the supervisor) settled an open entry. A blocker that a task's state implies stays settled until that
    /// state changes; resolving one that is already resolved changes nothing.
    func resolveDecision(id: String, by: String, resolution: String) throws {
        guard !id.isEmpty, !by.isEmpty, by.count <= 200, !resolution.isEmpty, resolution.count <= 200 else { throw BuddyWorkerFailure(message: "Say which entry, who resolved it and how.", code: "invalid_input") }
        try db.transaction {
            guard let row = try db.rows("SELECT task_id, status FROM decisions WHERE id = ?", [.text(id)]).first else { throw BuddyWorkerFailure(message: "This entry is no longer available.", code: "not_found") }
            guard row[1].string == "open" else { return }
            try db.run("UPDATE decisions SET status = 'resolved', resolution = ?, resolved_by = ?, resolved_at = ? WHERE id = ? AND status = 'open'", [.text(resolution), .text(by), .text(Self.stamp()), .text(id)])
            if let taskID = row[0].string, !taskID.isEmpty, let task = jobs.first(where: { $0["id"] as? String == taskID }) {
                try Self.appendEvent("decision.resolved", task: task, attempt: task["attempt"] as? Int, cause: resolution, payload: ["id": id, "by": by], in: db)
            }
        }
    }

    // MARK: rules

    private static let ruleColumns = "id, workspace, agent_id, kind, text, quote, params, status, graduated, actor, created_at"
    private static func rule(_ row: [BuddyOperationsDB.Column]) -> BuddyRule? {
        guard row.count >= 11, let id = row[0].string else { return nil }
        return BuddyRule(id: id, workspace: row[1].string ?? "", agentID: row[2].string ?? "", kind: row[3].string ?? "", text: row[4].string ?? "", quote: row[5].string ?? "", params: (try? BuddyOperationsDB.decode(row[6].string ?? "{}")) ?? [:],
                         status: row[7].string ?? "", graduated: row[8].int == 1, actor: row[9].string ?? "", createdAt: row[10].string ?? "")
    }
    /// `kind` is "review_gate" (a check the person asked for) or "directive" (how the person wants the agent, or with `agent` set to the workspace
    /// id the whole team, to work).
    func addRule(workspace: String, agent: String, text: String, quote: String, params: [String: Any], status: String, actor: String, kind: String = "review_gate") throws -> String {
        guard UUID(uuidString: workspace) != nil, UUID(uuidString: agent) != nil, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 600 else { throw BuddyWorkerFailure(message: "Give the rule in plain words, up to 600 characters.") }
        guard ["review_gate", "directive"].contains(kind) else { throw BuddyWorkerFailure(message: "Unknown kind of rule.", code: "invalid_input") }
        guard try db.rows("SELECT COUNT(*) FROM rules WHERE workspace = ? AND agent_id = ? AND status <> 'revoked'", [.text(workspace), .text(agent)]).first?.first?.int ?? 0 < 30 else { throw BuddyWorkerFailure(message: "This agent already has 30 rules. Remove one first.") }
        let id = UUID().uuidString, now = Self.stamp()
        try db.run("INSERT INTO rules(id, workspace, agent_id, kind, text, quote, params, status, graduated, actor, created_at, updated_at) VALUES(?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?)",
                   [.text(id), .text(workspace), .text(agent), .text(kind), .text(text), .text(String(quote.prefix(500))), .text((try? BuddyOperationsDB.encode(params)) ?? "{}"), .text(status), .text(actor), .text(now), .text(now)])
        return id
    }
    func rule(_ id: String) throws -> BuddyRule? { try db.rows("SELECT \(Self.ruleColumns) FROM rules WHERE id = ?", [.text(id)]).first.flatMap(Self.rule) }
    /// The rules for one agent include the team's (stored under the workspace id), oldest first.
    func rules(workspace: String, agent: String? = nil, includeRevoked: Bool = false) throws -> [BuddyRule] {
        let all = try db.rows("SELECT \(Self.ruleColumns) FROM rules WHERE workspace = ? ORDER BY created_at, rowid", [.text(workspace)]).compactMap(Self.rule)
        return all.filter { (agent == nil || $0.agentID == agent || $0.agentID == workspace) && (includeRevoked || $0.status != "revoked") }
    }
    func setRule(_ id: String, status: String) throws {
        guard ["pending", "active", "paused", "revoked"].contains(status) else { throw BuddyWorkerFailure(message: "Unknown rule state.") }
        try db.run("UPDATE rules SET status = ?, updated_at = ? WHERE id = ?", [.text(status), .text(Self.stamp()), .text(id)])
    }
    func approvals(rule id: String) throws -> Int { Int(try db.rows("SELECT COUNT(*) FROM rule_approvals WHERE rule_id = ?", [.text(id)]).first?.first?.int ?? 0) }
    /// Counts a review the person approved under a rule, once. Reaching the number the rule asked for is what earns the agent its freedom; it
    /// is recorded with the approval, so it cannot happen without the count or the count without it.
    @discardableResult func countApproval(rule id: String, review: String, agentName: String = "The agent") throws -> (count: Int, graduated: Bool) {
        guard let rule = try rule(id), rule.status == "active" else { throw BuddyWorkerFailure(message: "This rule is not active.") }
        return try db.transaction {
            try db.run("INSERT OR IGNORE INTO rule_approvals(rule_id, review_id, at) VALUES(?, ?, ?)", [.text(id), .text(review), .text(Self.stamp())])
            let count = try approvals(rule: id)
            let earned = rule.relaxes && rule.reviewFirst > 0 && count >= rule.reviewFirst
            if earned && !rule.graduated {
                try db.run("UPDATE rules SET graduated = 1, updated_at = ? WHERE id = ?", [.text(Self.stamp()), .text(id)])
                try openDecision(workspace: rule.workspace, id: "graduated:" + id + ":" + String(count), agent: rule.agentID, kind: "notice", title: "\(agentName) now works without asking",
                                 question: "You approved \(count) checks of “\(rule.text.prefix(160))”, so \(agentName) now continues at this step without asking you each time. Pause or remove the rule from the agent’s settings whenever you like.", label: "Review rule", payload: ["ruleId": id])
            }
            return (count, earned || rule.graduated)
        }
    }
    /// Takes away what a rule earned (the person said to stop): the approvals stay on record, but the agent has to be reviewed again from the start.
    func resetRule(_ id: String) throws {
        try db.transaction { try db.run("DELETE FROM rule_approvals WHERE rule_id = ?", [.text(id)]); try db.run("UPDATE rules SET graduated = 0, updated_at = ? WHERE id = ?", [.text(Self.stamp()), .text(id)]) }
    }
    /// The rule, if any, that lets this task's browser operations go ahead without asking: active, relaxing, covering the browser and this kind of
    /// task, and either earned (enough reviews approved) or already checked by the person in this very task.
    func autoApprovingRule(for job: [String: Any], tool: String = "browser") throws -> BuddyRule? {
        guard let workspace = job["workspace"] as? String, let agent = job["agentId"] as? String else { return nil }
        let checked = Set(job["checkpoints"] as? [String] ?? []), kind = job["kind"] as? String ?? ""
        return try rules(workspace: workspace, agent: agent).first { rule in
            rule.status == "active" && rule.relaxes && rule.appliesTo.contains(tool) && (rule.taskKinds.isEmpty || rule.taskKinds.contains(kind)) && (rule.graduated || checked.contains(rule.id))
        }
    }
    /// The active rules that ask for a review before the agent goes ahead, for the agent that is about to do the work.
    func reviewRules(workspace: String, agent: String, kind: String) throws -> [BuddyRule] {
        try rules(workspace: workspace, agent: agent).filter { $0.status == "active" && $0.relaxes && $0.reviewFirst > 0 && ($0.taskKinds.isEmpty || $0.taskKinds.contains(kind)) }
    }
    /// Standing rules as the agent is told them. They are also enforced natively; the telling only lets the agent do its part (showing the work).
    func rulesGuidance(workspace: String, agent: String) -> String {
        guard let all = try? rules(workspace: workspace, agent: agent).filter({ $0.status == "active" }), !all.isEmpty else { return "" }
        let directives = all.filter { $0.kind == "directive" }.reversed().map { (quote: $0.quote, rule: $0.text) }, gates = all.filter { $0.kind != "directive" }
        var parts: [String] = []
        if !directives.isEmpty { parts.append(BuddyRulesReader.directives(directives)) }
        guard !gates.isEmpty else { return parts.joined(separator: "\n\n") }
        let lines = gates.map { rule -> String in
            var line = "- [\(rule.id.prefix(8))] \(rule.text)"
            if rule.relaxes && rule.reviewFirst > 0 {
                let done = (try? approvals(rule: rule.id)) ?? 0
                line += rule.graduated ? " Status: the user has approved this \(done) times, so you may now go ahead without asking for it."
                    : " Status: \(done) of \(rule.reviewFirst) reviewed by the user so far. Until then, before you finish the work that this covers, call buddy_review_checkpoint with rule \"\(rule.id)\" and show them what you prepared; wait for their answer."
            }
            return line
        }
        parts.append("Standing rules from the user for you (they are enforced natively; follow them exactly):\n" + lines.joined(separator: "\n"))
        return parts.joined(separator: "\n\n")
    }
}

/// The standing rules a reader outside the worker needs: the guidance an agent is told. Read-only.
enum BuddyRulesReader {
    /// The person's standing directives, newest first, as every agent is told them: ahead of everything else, and above the saved configuration.
    static func directives(_ items: [(quote: String, rule: String)]) -> String {
        "Standing directives from the user, newest first. They are newer than your saved configuration and override it wherever they conflict:\n"
            + items.map { $0.quote.isEmpty ? "- \($0.rule)" : "- “\($0.quote)” → \($0.rule)" }.joined(separator: "\n")
    }
    @MainActor static func guidance(support: URL, workspace: String, agent: String) -> String {
        let directory = support.appendingPathComponent("Worker")
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(BuddyOperationsDB.fileName).path), let db = try? BuddyOperationsDB(directory: directory, existing: true),
              let all = try? db.rows("SELECT id, text, params, graduated, kind, quote FROM rules WHERE workspace = ? AND agent_id IN (?, ?) AND status = 'active' ORDER BY created_at, rowid", [.text(workspace), .text(agent), .text(workspace)]), !all.isEmpty else { return "" }
        let directives = all.filter { $0[4].string == "directive" }.reversed().map { (quote: $0[5].string ?? "", rule: $0[1].string ?? "") }, rows = all.filter { $0[4].string != "directive" }
        var parts: [String] = []
        if !directives.isEmpty { parts.append(Self.directives(directives)) }
        guard !rows.isEmpty else { return parts.joined(separator: "\n\n") }
        let lines = rows.map { row -> String in
            let id = row[0].string ?? "", params = (try? BuddyOperationsDB.decode(row[2].string ?? "{}")) ?? [:], first = params["reviewFirst"] as? Int ?? 0, graduated = row[3].int == 1
            var line = "- [\(id.prefix(8))] \(row[1].string ?? "")"
            if params["then"] as? String == "proceed", first > 0 {
                let done = Int((try? db.rows("SELECT COUNT(*) FROM rule_approvals WHERE rule_id = ?", [.text(id)]).first?.first?.int) ?? 0)
                line += graduated ? " Status: the user has approved this \(done) times, so the agent now goes ahead without asking for it." : " Status: \(done) of \(first) reviewed by the user so far. Background tasks show their work to the user for these checks on their own; never skip a check or tell the user it can be skipped."
            }
            return line
        }
        parts.append("Standing rules from the user for you (they are enforced natively; follow them exactly):\n" + lines.joined(separator: "\n"))
        return parts.joined(separator: "\n\n")
    }
}

// MARK: - The engine: change a setting, keep a rule, on the person's word

/// Applies what the person asked for in their own words. The model names the change and quotes the sentence it came from; the quote is checked
/// against what the person really wrote, so a web page, an email or another agent can never cause one. Everything is journaled with its old value.
@MainActor final class BuddyAgentSettings {
    let store: BuddyWorkerStore, workspace: String
    var agents: () throws -> [[String: Any]] = { [] }
    var supervisor: () -> String? = { nil }
    /// The setting's value now (agent or workspace scope), from wherever it truly lives.
    var read: (_ scope: String, _ agent: String, _ field: String) throws -> Any? = { _, _, _ in nil }
    /// Puts a value where it truly lives. Only for settings the app itself owns; the page's own fields are carried by the journal until it adopts them.
    var write: (_ scope: String, _ agent: String, _ field: String, _ value: Any?) throws -> Void = { _, _, _, _ in }
    var announce: () -> Void = {}
    init(store: BuddyWorkerStore, workspace: String) { self.store = store; self.workspace = workspace }

    private func fail(_ message: String) -> BuddyWorkerFailure { BuddyWorkerFailure(message: message) }
    static let labels: [String: String] = ["name": "name", "role": "role", "instructions": "instructions", "avatarShape": "figure", "avatarColor": "colour", "hidden": "visibility", "model": "model", "dailyLimitUSD": "daily spending limit",
        "proactive": "proactive updates", "tools.web": "web access (also needed for website tasks)", "tools.projectFiles": "file access", "tools.desktop": "Mac app access (also needed for website tasks)", "teamCheckInsEnabled": "team check-ins", "teamCheckInIntervalMinutes": "team check-in interval",
        "teamCheckInModel": "team check-in model", "teamDailyLimitUSD": "team check-in limit", "teamSupervisor": "team supervisor"]
    private func name(of agent: String) -> String { ((try? agents())?.first { $0["id"] as? String == agent }?["name"] as? String) ?? "this agent" }
    func describe(_ field: String, _ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return field.hasSuffix("LimitUSD") ? "no limit" : "the default" }
        switch field {
        case "hidden": return (value as? Bool) == true ? "hidden" : "shown"
        case "model": let m = value as? [String: Any]; return [m?["provider"] as? String, (m?["model"] as? String).flatMap { $0.isEmpty ? nil : $0 }].compactMap { $0 }.joined(separator: " · ")
        case "dailyLimitUSD", "teamDailyLimitUSD": let n = (value as? Double) ?? (value as? Int).map(Double.init) ?? 0; return String(format: "$%.2f a day", n)
        case "teamCheckInIntervalMinutes": return "every \(value) minutes"
        case "teamSupervisor": return name(of: value as? String ?? "")
        case "instructions": return "“" + String((value as? String ?? "").prefix(140)) + ((value as? String ?? "").count > 140 ? "…" : "") + "”"
        default: if let flag = value as? Bool { return flag ? "on" : "off" }; return "“\(value)”"
        }
    }
    private func line(_ scope: String, _ agent: String, _ field: String, from old: Any?, to new: Any?) -> String {
        let label = Self.labels[field] ?? field, who = scope == "workspace" ? "the workspace’s" : name(of: agent) + "’s"
        return "\(who) \(label): \(describe(field, old)) → \(describe(field, new))"
    }
    private func same(_ a: Any?, _ b: Any?) -> Bool { BuddyAgentChanges.encode(a) == BuddyAgentChanges.encode(b) }
    private func current(_ scope: String, _ agent: String, _ field: String) throws -> Any? {
        if field == "dailyLimitUSD" {
            return try store.limits(workspace: workspace).first { $0["scope"] as? String == scope && ($0["id"] as? String ?? "") == (scope == "agent" ? agent : "") }?["amountUSD"]
        }
        return try read(scope, agent, field)
    }
    private func put(_ scope: String, _ agent: String, _ field: String, _ value: Any?, by: String, quote: String) throws {
        if field == "dailyLimitUSD" { try store.setLimit(workspace: workspace, scope: scope, id: agent, amount: (value as? Double) ?? (value as? Int).map(Double.init), setBy: by, quote: quote); return }
        if !BuddyAgentChanges.adopter(scope: scope, field: field).isEmpty { return }
        try write(scope, agent, field, value)
    }
    /// The person acting on screen may always. An agent needs the person's own words for it, and may act for itself, for a teammate it manages,
    /// or (as the supervisor, Chief) for anyone or the whole workspace.
    private func authorize(actor: String?, text: String, quote: String, scope: String, target: String) throws {
        guard let actor else { return }
        guard BuddyAgentChanges.quoteAuthorized(quote, in: text) else { throw fail("I can only do this when you ask for it. Quote the exact words from your message that ask for it, at least a few words.") }
        let boss = supervisor() == actor
        if scope == "workspace" { guard boss else { throw fail("Only the team’s supervisor can change workspace-wide settings.") }; return }
        let managed = (try agents()).first { $0["id"] as? String == target }?["managedBy"] as? String == actor
        guard actor == target || boss || managed else { throw fail("You can change your own settings. Changing another agent’s needs the supervisor, or the agent that manages it.") }
    }
    private func targetAgent(_ args: [String: Any], actor: String?, scope: String) throws -> String {
        guard scope == "agent" else { return "" }
        let target = args["agentId"] as? String ?? actor ?? ""
        guard UUID(uuidString: target) != nil, (try agents()).contains(where: { $0["id"] as? String == target }) else { throw fail("This agent is no longer in your workspace.") }
        return target
    }

    /// Whether `actor` oversees `target`: the supervisor oversees everyone and the workspace, a manager the agents it manages.
    private func oversees(_ actor: String, scope: String, target: String) throws -> Bool {
        guard !actor.isEmpty else { return false }
        if supervisor() == actor { return true }
        guard scope == "agent" else { return false }
        return try agents().first { $0["id"] as? String == target }?["managedBy"] as? String == actor
    }
    func change(actor: String?, text: String, args: [String: Any], source: String? = nil) throws -> [String: Any] {
        let scope = args["scope"] as? String ?? "agent"
        guard ["agent", "workspace"].contains(scope) else { throw fail("Choose agent or workspace.") }
        let target = try targetAgent(args, actor: actor, scope: scope), quote = args["quote"] as? String ?? ""
        let field = args["field"] as? String ?? ""
        // The supervisor, or a teammate's manager, may narrow that teammate's reach on its own judgement, without the person's words. Its own
        // settings, anything that widens, and every limit still need them.
        var judgement = false
        if let actor, actor != target, BuddyAgentChanges.judgementFields.contains(field), !BuddyAgentChanges.quoteAuthorized(quote, in: text), try oversees(actor, scope: scope, target: target) { judgement = true }
        if !judgement { try authorize(actor: actor, text: text, quote: quote, scope: scope, target: target) }
        var wantedValue = args["value"]
        if field == "teamSupervisor" {
            // The person says who by name; the setting holds the agent's id.
            let wanted = (wantedValue as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), all = try agents()
            let matches = all.filter { ($0["id"] as? String ?? "").lowercased() == wanted || ($0["name"] as? String ?? "").lowercased() == wanted }
            guard matches.count == 1, let id = matches[0]["id"] as? String else { throw fail("Name one of these agents: " + all.compactMap { $0["name"] as? String }.joined(separator: ", ") + ".") }
            wantedValue = id
        }
        let new = try BuddyAgentChanges.normalize(scope: scope, field: field, value: wantedValue)
        if field == "name", let wanted = new as? String, try agents().contains(where: { $0["id"] as? String != target && ($0["name"] as? String)?.lowercased() == wanted.lowercased() }) { throw fail("Another agent already has that name. Choose a different one.") }
        let old = try current(scope, target, field)
        if same(old, new) { return ["saved": true, "unchanged": true, "message": "That is already the setting: " + line(scope, target, field, from: old, to: new)] }
        if judgement, !BuddyAgentChanges.narrows(field: field, old: old, new: new) { try authorize(actor: actor, text: text, quote: quote, scope: scope, target: target) }
        let by = actor == nil ? "user" : "chat", risk = actor == nil || judgement ? "low" : BuddyAgentChanges.risk(field: field, old: old, new: new)
        let origin = source ?? (judgement ? "supervisor-judgement" : actor == nil ? "screen" : "chat"), said = judgement ? "" : quote
        // Only the person sets a daily limit: an agent adding or lowering one has to quote the person's own words about it, with the amount.
        if actor != nil, ["dailyLimitUSD", "teamDailyLimitUSD"].contains(field), risk != "confirm", !BuddyAgentChanges.limitQuote(said) { throw fail("Quote the user's own words that set this limit, with the amount.") }
        if risk == "confirm" {
            let id = try store.recordChange(workspace: workspace, scope: scope, agent: target, field: field, old: old, new: new, actor: by, source: origin, quote: said, status: "pending", risk: risk)
            try store.openDecision(workspace: workspace, id: "change:" + id, agent: target, kind: "confirm", title: "Allow this change?", question: "You asked for this in chat: " + line(scope, target, field, from: old, to: new) + ". It gives more access or room to spend, so it waits for your OK.", label: "Allow", payload: ["changeId": id])
            announce()
            return ["saved": false, "needsConfirmation": true, "changeId": id, "message": "This gives more access or room to spend, so nothing has changed yet. A card in Notifications is waiting for the user’s OK. Do not say it is done."]
        }
        // A setting the app itself holds is written after the journal entry says "applying" and confirmed after, so being stopped half way is
        // sorted out by reconcile(). A field someone else carries home is applied by the entry itself.
        let direct = BuddyAgentChanges.adopter(scope: scope, field: field).isEmpty
        let id = try store.recordChange(workspace: workspace, scope: scope, agent: target, field: field, old: old, new: new, actor: by, source: origin, quote: said, status: direct ? "applying" : "applied", risk: risk)
        if direct { do { try put(scope, target, field, new, by: by, quote: said); try store.setChange(id, status: "applied") } catch { try? store.setChange(id, status: "failed"); throw error } }
        announce()
        return ["saved": true, "changeId": id, "canUndo": true, "message": "Done. " + line(scope, target, field, from: old, to: new) + ". It can be undone from the agent’s settings or by asking."]
    }

    /// The person answers a change that was waiting for their OK. Only the person, on screen.
    func answer(changeID: String, allow: Bool) throws -> [String: Any] {
        guard let change = try store.change(changeID), change.workspace == workspace, change.status == "pending" else { throw fail("This request was already answered.") }
        guard allow else {
            try store.setChange(changeID, status: "declined"); try store.closeDecision(id: "change:" + changeID, resolution: "declined"); announce()
            return ["saved": false, "declined": true, "message": "Left as it was."]
        }
        let now = try current(change.scope, change.agentID, change.field), direct = BuddyAgentChanges.adopter(scope: change.scope, field: change.field).isEmpty
        try store.setChange(changeID, status: direct ? "applying" : "applied", old: .some(now))
        if direct { do { try put(change.scope, change.agentID, change.field, change.new, by: "user", quote: change.quote); try store.setChange(changeID, status: "applied") } catch { try? store.setChange(changeID, status: "failed"); throw error } }
        try store.closeDecision(id: "change:" + changeID, resolution: "allowed"); announce()
        return ["saved": true, "changeId": changeID, "message": "Done. " + line(change.scope, change.agentID, change.field, from: now, to: change.new)]
    }

    /// After the worker was stopped half way through a change: if the setting now holds the new value the change took effect, otherwise it did not.
    func reconcile() throws {
        for change in try store.changes(workspace: workspace, limit: 200) where change.status == "applying" {
            let value: Any?
            do { value = try current(change.scope, change.agentID, change.field) } catch { continue }
            try store.setChange(change.id, status: same(value, change.new) ? "applied" : "failed")
            try store.closeDecision(id: "change:" + change.id, resolution: "reconciled")
        }
    }
    /// Puts a setting back to what it was before a change. Only the newest change to a setting can be undone, so nothing newer is wiped by accident.
    func undo(actor: String?, text: String, args: [String: Any]) throws -> [String: Any] {
        guard let id = args["changeId"] as? String, let original = try store.change(id), original.workspace == workspace else { throw fail("Choose a change from the list.") }
        guard original.status == "applied" else { throw fail("Only a change that took effect can be undone.") }
        let newer = try store.changes(workspace: workspace, agent: original.scope == "agent" ? original.agentID : nil, limit: 200).first { $0.seq > original.seq && $0.field == original.field && $0.scope == original.scope && $0.agentID == original.agentID && ["applied", "pending"].contains($0.status) }
        guard newer == nil else { throw fail("This setting was changed again afterwards. Undo the newer change first.") }
        var next: [String: Any] = ["scope": original.scope, "field": original.field, "value": original.old as Any? ?? NSNull(), "quote": args["quote"] as? String ?? ""]
        if original.scope == "agent" { next["agentId"] = original.agentID }
        let result = try change(actor: actor, text: text, args: next, source: "undo:" + id)
        if result["saved"] as? Bool == true { try store.setChange(id, status: "undone") }
        var out = result; out["undid"] = id
        return out
    }
    /// Every setting the person (or the supervisor) can change now, as it stands, so the agent can answer "what is X set to".
    func snapshot(agent: String?, workspaceFields: Bool) throws -> [String: Any] {
        var out: [String: Any] = [:]
        if let agent, UUID(uuidString: agent) != nil, (try agents()).contains(where: { $0["id"] as? String == agent }) {
            var values: [String: Any] = [:]
            for field in BuddyAgentChanges.agentFields.sorted() {
                // Changing instructions means sending the whole new text, so the whole current text is shown, not a preview of it.
                if field == "instructions" { values[field] = try current("agent", agent, field) as? String ?? "" } else { values[field] = describe(field, try current("agent", agent, field)) }
            }
            out["agent"] = ["id": agent, "name": name(of: agent), "settings": values]
        }
        if workspaceFields {
            var values: [String: Any] = [:]
            for field in BuddyAgentChanges.workspaceFields.sorted() { values[field] = describe(field, try current("workspace", "", field)) }
            out["workspace"] = values
        }
        return out
    }
    func list(agent: String?, limit: Int = 30) throws -> [[String: Any]] {
        let all = try store.changes(workspace: workspace, agent: agent, limit: limit)
        return all.map { c in
            let latest = !all.contains { $0.seq > c.seq && $0.field == c.field && $0.scope == c.scope && $0.agentID == c.agentID && ["applied", "pending"].contains($0.status) }
            return ["id": c.id, "agentId": c.agentID, "scope": c.scope, "field": c.field, "label": Self.labels[c.field] ?? c.field, "status": c.status, "summary": line(c.scope, c.agentID, c.field, from: c.old, to: c.new), "by": c.actor, "at": c.createdAt, "canUndo": c.status == "applied" && latest && !c.source.hasPrefix("undo:")]
        }
    }

    // MARK: rules

    private func ruleDescription(_ rule: BuddyRule) -> String {
        var out = rule.text
        if rule.relaxes && rule.reviewFirst > 0 { out += rule.graduated ? " (earned: continues without asking)" : " (\((try? store.approvals(rule: rule.id)) ?? 0) of \(rule.reviewFirst) checks approved)" }
        return out
    }
    func addRule(actor: String?, text: String, args: [String: Any]) throws -> [String: Any] {
        if args["kind"] as? String == "directive" { return try addDirective(actor: actor, text: text, args: args) }
        let target = try targetAgent(args, actor: actor, scope: "agent"), quote = args["quote"] as? String ?? ""
        try authorize(actor: actor, text: text, quote: quote, scope: "agent", target: target)
        guard let rule = (args["rule"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), rule.count >= 8, rule.count <= 600 else { throw fail("Write the rule in plain words, 8 to 600 characters.") }
        let proceed = (args["then"] as? String ?? "ask") == "proceed"
        var params: [String: Any] = ["then": proceed ? "proceed" : "ask"]
        if proceed {
            let first = (args["reviewFirst"] as? Int) ?? (args["reviewFirst"] as? Double).map { Int($0) } ?? 0
            guard (1...20).contains(first) else { throw fail("Say how many checks the person wants first, from 1 to 20.") }
            params["reviewFirst"] = first
        }
        let covered = (args["appliesTo"] as? [String]) ?? ["browser"]
        guard !covered.isEmpty, covered.allSatisfy({ $0 == "browser" }) else { throw fail("Rules can cover the agent’s browser steps. Emails and other connected-service actions always ask.") }
        params["appliesTo"] = covered
        let kinds = (args["taskKinds"] as? [String]) ?? []
        guard kinds.allSatisfy({ ["research", "applications", "email", "general"].contains($0) }) else { throw fail("Task kinds can be research, applications, email or general.") }
        params["taskKinds"] = kinds
        let id = try store.addRule(workspace: workspace, agent: target, text: rule, quote: quote, params: params, status: "active", actor: actor == nil ? "user" : "chat")
        announce()
        let first = params["reviewFirst"] as? Int ?? 0
        let detail = proceed ? "The first \(first) time\(first == 1 ? "" : "s"), \(name(of: target)) will show you the work first and wait for your OK (a card appears in Notifications). Once you have approved \(first), \(name(of: target)) continues at that step without asking. Sign-ins, passwords, payments and emails still always ask."
                                : "\(name(of: target)) will show you the work first every time."
        return ["saved": true, "ruleId": id, "message": "Saved for \(name(of: target)): “\(rule)”. " + detail, "checkpointInstruction": "Before you begin the covered work, call buddy_review_checkpoint with rule \"\(id)\"."]
    }
    /// A standing directive: how the person wants an agent (scope "agent") or the whole team (scope "team", recorded by the supervisor) to work, in
    /// their own quoted words. It is told first, above the agent's saved configuration, and never relaxes a check.
    private func addDirective(actor: String?, text: String, args: [String: Any]) throws -> [String: Any] {
        let scope = args["scope"] as? String ?? "agent", quote = args["quote"] as? String ?? ""
        guard ["agent", "team"].contains(scope) else { throw fail("Choose agent or team for a directive.") }
        let target: String
        if scope == "team" { try authorize(actor: actor, text: text, quote: quote, scope: "workspace", target: ""); target = workspace }
        else { target = try targetAgent(args, actor: actor, scope: "agent"); try authorize(actor: actor, text: text, quote: quote, scope: "agent", target: target) }
        guard let rule = (args["rule"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), rule.count >= 8, rule.count <= 600 else { throw fail("Write the directive in plain words, 8 to 600 characters.") }
        let id = try store.addRule(workspace: workspace, agent: target, text: rule, quote: quote, params: ["scope": scope], status: "active", actor: actor == nil ? "user" : "chat", kind: "directive")
        announce()
        let who = scope == "team" ? "the whole team" : name(of: target)
        return ["saved": true, "ruleId": id, "message": "Saved as a standing directive for \(who): “\(rule)”. It is told first, above saved instructions. It never relaxes a check that needs the person."]
    }
    func manageRule(actor: String?, text: String, args: [String: Any]) throws -> [String: Any] {
        guard let id = args["ruleId"] as? String, let rule = try store.rule(id), rule.workspace == workspace, rule.status != "revoked" else { throw fail("Choose a rule from the list.") }
        try authorize(actor: actor, text: text, quote: args["quote"] as? String ?? "", scope: "agent", target: rule.agentID)
        switch args["action"] as? String ?? "" {
        case "pause": try store.setRule(id, status: "paused")
        case "resume": try store.setRule(id, status: "active")
        case "remove": try store.setRule(id, status: "revoked")
        case "reset": try store.resetRule(id)
        default: throw fail("Choose pause, resume, remove or reset.")
        }
        announce()
        let verb = ["pause": "Paused", "resume": "Back on", "remove": "Removed", "reset": "Starting over (checks come back until it earns it again)"][args["action"] as? String ?? ""] ?? "Done"
        return ["saved": true, "ruleId": id, "message": "\(verb): “\(rule.text.prefix(160))”."]
    }
    func listRules(agent: String?) throws -> [[String: Any]] {
        try store.rules(workspace: workspace, agent: agent, includeRevoked: false).map { r in
            ["id": r.id, "agentId": r.agentID, "text": r.text, "status": r.status, "summary": ruleDescription(r), "approved": (try? store.approvals(rule: r.id)) ?? 0, "needed": r.relaxes ? r.reviewFirst : 0, "earned": r.graduated, "relaxes": r.relaxes, "createdAt": r.createdAt]
        }
    }
}
