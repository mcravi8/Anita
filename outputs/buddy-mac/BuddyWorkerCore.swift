import Foundation
import CryptoKit
import Darwin

struct BuddyWorkerFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum BuddyRoutineAuthorization {
    static func owner(_ args:[String:Any],actor:String,runID:String,text:String,state:[String:Any])throws->String {
        let target=args["agentId"] as? String ?? actor
        guard target != actor else{return actor}
        let agents=state["agents"] as? [[String:Any]] ?? []
        guard let agent=agents.first(where:{$0["id"] as? String==target}),agents.contains(where:{$0["id"] as? String==actor}),
              let run=(state["runs"] as? [String:[String:Any]])?[runID],["starting","answering"].contains(run["status"] as? String ?? ""),
              let chat=run["target"] as? String,(chat==actor || (state["groups"] as? [[String:Any]] ?? []).contains(where:{$0["id"] as? String==chat && ($0["members"] as? [String] ?? []).contains(actor)})),
              let user=run["userId"] as? String,((state["messages"] as? [String:[[String:Any]]])?[chat] ?? []).contains(where:{$0["id"] as? String==user && $0["who"] as? String=="you" && $0["body"] as? String==text}),
              let quote=args["authorizationQuote"] as? String,quote.count>=3,text.contains(quote),
              text.range(of:#"(?i)\b(?:every|daily|weekdays|routine|schedule|interval|same.{0,25}checks)\b"#,options:.regularExpression) != nil,
              text.range(of:#"(?i)\b(?:hypothetical|example|don't|do not|never)\b|```"#,options:.regularExpression)==nil else{throw BuddyWorkerFailure(message:"Scheduling for another agent needs the user's current delegation request.")}
        let name=agent["name"] as? String ?? ""
        let named = !name.isEmpty && text.range(of:name,options:.caseInsensitive) != nil
        guard agent["managedBy"] as? String==actor || named else{throw BuddyWorkerFailure(message:"Choose the teammate named in the user's request.")}
        return target
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

/// One try at a task. `outcome` is nil while the attempt is still going.
struct BuddyAttempt {
    let taskID: String, number: Int, runID: String, provider: String, model: String, startedAt: String, endedAt: String?, outcome: String?
}

@MainActor final class BuddyWorkerStore {
    let directory: URL
    private let db: BuddyOperationsDB
    private(set) var jobs: [[String: Any]]
    private(set) var paused: Bool
    static let interrupted = Set(["running", "waiting_review", "stopping"])
    static let terminal = Set(["completed", "cancelled"])
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
        guard tasks.count <= 1000, tasks.allSatisfy({ ($0["id"] as? String).flatMap(UUID.init(uuidString:)) != nil && ($0["workspace"] as? String).flatMap(UUID.init(uuidString:)) != nil }), Set(tasks.compactMap { $0["id"] as? String }).count == tasks.count else { throw BuddyWorkerFailure(message: "Buddy couldn’t verify its saved background tasks. Restore them from the newest ZIP in Worker/Backups before starting the worker.") }
        jobs = tasks; paused = try db.meta("paused") == "1"
        if jobs.count > Self.archiveTrigger { try? archiveFinished(keeping: Self.archiveKeep) }
        try recordBaseline()
        try backfillActions()
        var interrupted: [(old: [String: Any], new: [String: Any])] = []
        for i in jobs.indices where Self.interrupted.contains(jobs[i]["status"] as? String ?? "") {
            let before = jobs[i]
            let rows = try actionStates(of: jobs[i]["id"] as? String ?? "")
            let reviews = Self.settled(jobs[i]["reviews"] as? [[String: Any]] ?? [], rows: rows, pending: "expired")
            jobs[i]["reviews"] = reviews
            let unsure = reviews.filter { $0["status"] as? String == "uncertain" }
            jobs[i]["status"] = "interrupted"
            jobs[i]["progress"] = unsure.isEmpty ? "The worker restarted. Review the last result and any external action before continuing. Nothing was automatically retried."
                : "The worker restarted while \(Self.describe(unsure)) may have been sent. Check whether it went through before continuing. Nothing was automatically retried."
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
        do { try db.transaction { try Self.commit(saved, from: old, cause: cause, in: db) } } catch { jobs[i] = old; throw error }; return jobs[i]
    }
    func create(workspace: String, agent: String, requestId: String, title: String, goal: String, kind: String, provider: String, budget: Double, model:String?=nil) throws -> [String: Any] {
        guard UUID(uuidString: workspace) != nil, UUID(uuidString: agent) != nil, !requestId.isEmpty, requestId.count <= 200,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 150,
              !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, goal.count <= 30000,
              ["research", "applications", "email", "general", "coding"].contains(kind), ["chatgpt", "claude"].contains(provider), (kind != "coding" || provider=="claude"), budget.isFinite, budget >= 0, budget <= 10 else { throw BuddyWorkerFailure(message: "Add a short task title, a clear brief, and a supported provider.") }
        if let old = jobs.first(where: { $0["workspace"] as? String == workspace && $0["agentId"] as? String == agent && $0["requestId"] as? String == requestId }) { return old }
        let heavy = liveBytes > Self.archiveSizeTrigger
        if jobs.count >= Self.archiveTrigger || heavy { try? archiveFinished(keeping: heavy ? 200 : Self.archiveKeep) }
        guard jobs.count < 1000, jobs.filter({ !Self.terminal.contains($0["status"] as? String ?? "") }).count < 30 else { throw BuddyWorkerFailure(message: "Finish or cancel some background tasks before adding more.") }
        let now = ISO8601DateFormatter().string(from: Date())
        var job: [String: Any] = ["id": UUID().uuidString, "workspace": workspace, "agentId": agent, "requestId": requestId, "title": title, "goal": goal, "kind": kind, "provider": provider, "budgetUSD": budget, "status": "queued", "progress": "Queued", "createdAt": now, "updatedAt": now, "attempt": 0, "events": [[String: Any]](), "result": "", "files": [[String: Any]]()]
        if let model,!model.isEmpty {guard model.range(of:#"^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$"#,options:.regularExpression) != nil else{throw BuddyWorkerFailure(message:"Invalid task model.")};job["model"]=model}
        let created = job
        jobs.append(job)
        do {
            try db.transaction {
                try Self.insert(created, archived: false, in: db)
                try Self.appendEvent("task.created", task: created, attempt: nil, cause: "request", payload: ["kind": kind, "provider": provider, "status": "queued"], in: db)
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

    private static func stamp() -> String { ISO8601DateFormatter().string(from: Date()) }

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
            let closed = try db.run("UPDATE attempts SET ended_at = ?, outcome = ? WHERE task_id = ? AND outcome IS NULL", [.text(stamp()), .text(after), .text(id)])
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
        try db.rows("SELECT n, run_id, provider, model, started_at, ended_at, outcome FROM attempts WHERE task_id = ? ORDER BY n", [.text(taskID)]).compactMap { row in
            guard let n = row[0].int else { return nil }
            return BuddyAttempt(taskID: taskID, number: Int(n), runID: row[1].string ?? "", provider: row[2].string ?? "", model: row[3].string ?? "", startedAt: row[4].string ?? "", endedAt: row[5].string, outcome: row[6].string)
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

    func resume(_ id: String, continuingCoding:Bool=false,additionalBudgetUSD:Double?=nil,authorizationID:String?=nil) throws -> [String: Any] {
        let job = try self.job(id)
        let authorizations=job["budgetAuthorizations"] as? [[String:Any]] ?? []
        if let authorizationID,let prior=authorizations.first(where:{$0["id"] as? String==authorizationID}) {guard prior["amountUSD"] as? Double==additionalBudgetUSD else{throw BuddyWorkerFailure(message:"The saved allowance differs from this request. Reopen the task to check it before continuing.")};return job}
        guard ["paused", "failed", "interrupted", "waiting_user"].contains(job["status"] as? String ?? "") || (continuingCoding && job["kind"] as? String=="coding" && job["status"] as? String=="completed") else { throw BuddyWorkerFailure(message: "This task can’t be resumed in its current state.") }
        var fields:[String:Any] = ["status": "queued", "progress": "Queued to continue from saved progress. Check existing external state before any send or submission."]
        if let amount=additionalBudgetUSD {
            guard job["provider"] as? String=="claude",amount.isFinite,(0.1...10).contains(amount),(job["remainingBudgetUSD"] as? Double ?? job["budgetUSD"] as? Double ?? 0)<=0,let authorizationID,UUID(uuidString:authorizationID) != nil,authorizations.count<100 else{throw BuddyWorkerFailure(message:"Choose an additional Claude allowance from $0.10 to $10 for this paused task.")}
            fields["budgetAuthorizations"]=authorizations+[["id":authorizationID,"amountUSD":amount,"at":ISO8601DateFormatter().string(from:Date())]]
            fields["uncertainBudgetUSD"]=(job["uncertainBudgetUSD"] as? Double ?? 0)+(job["reservedBudgetUSD"] as? Double ?? 0)
            fields["reservedBudgetUSD"]=0.0;fields["remainingBudgetUSD"]=amount
        } else if job["provider"] as? String=="claude",(job["remainingBudgetUSD"] as? Double ?? job["budgetUSD"] as? Double ?? 0)<=0 {throw BuddyWorkerFailure(message:"Choose an additional Claude allowance in this task before resuming. Previous unconfirmed usage stays recorded.")}
        return try update(id,fields,cause:"resume")
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
        guard values.count<=100,Set(values.compactMap{$0["id"] as? String}).count==values.count else { throw BuddyWorkerFailure(message:"Buddy couldn't verify saved routines. Restore them from the newest ZIP in Worker/Backups before starting the worker.") }
        for value in values { try Self.validate(value);guard let id=value["id"] as? String,UUID(uuidString:id) != nil,let next=value["nextRun"] as? String,ISO8601DateFormatter().date(from:next) != nil else { throw BuddyWorkerFailure(message:"A saved routine has invalid timing. Restore it from the newest ZIP in Worker/Backups before starting.") } }
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
              ["chatgpt","claude"].contains(r["provider"] as? String ?? ""),let budget=r["budgetUSD"] as? Double,budget.isFinite,(0...10).contains(budget),
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
            if action=="resume" { routines[i]["nextRun"]=ISO8601DateFormatter().string(from:try Self.next(after:now,rule:routines[i])) }
            try persist();return ["saved":true,"routine":routines[i]]
        } catch { routines=old;try? persist();throw error }
    }
    func browserScope(for job:[String:Any])->[String:Any]? {
        guard let rule=routines.first(where:{$0["id"] as? String==job["routineID"] as? String && $0["workspace"] as? String==job["workspace"] as? String && $0["agentId"] as? String==job["agentId"] as? String}),let owner=rule["browserAgentId"] as? String,let origin=rule["browserOrigin"] as? String else{return nil}
        return ["browserAgentId":owner,"browserOrigin":origin]
    }
    func runNow(_ id:String,workspace:String,agent:String,requestID:String,store:BuddyWorkerStore) throws -> [String:Any] {
        guard UUID(uuidString:requestID) != nil,let index=routines.firstIndex(where:{$0["id"] as? String==id && $0["workspace"] as? String==workspace && $0["agentId"] as? String==agent}),routines[index]["status"] as? String=="active" else{throw BuddyWorkerFailure(message:"Choose an active saved routine to run now.")}
        let rule=routines[index]
        let request="routine:manual:"+id+":"+requestID
        if let existing=store.jobs.first(where:{$0["workspace"] as? String==workspace && $0["requestId"] as? String==request}) {return existing}
        let series=rule["routineSeriesID"] as? String
        let prior=store.jobs.last{$0["workspace"] as? String==workspace && $0["agentId"] as? String==agent && ($0["routineID"] as? String==id || series != nil && $0["routineSeriesID"] as? String==series)}
        guard prior==nil || BuddyWorkerStore.terminal.contains(prior?["status"] as? String ?? "") else{throw BuddyWorkerFailure(message:"This routine already has unfinished work. Open its current task instead of starting another scan.")}
        let job=try store.create(workspace:workspace,agent:agent,requestId:request,title:rule["title"] as! String,goal:rule["goal"] as! String,kind:rule["kind"] as! String,provider:rule["provider"] as! String,budget:rule["budgetUSD"] as! Double,model:rule["model"] as? String)
        var fields:[String:Any]=["routineID":id,"inboxQuery":rule["query"] ?? "","previousRoutineResult":prior?["result"] ?? "","manualRun":true]
        for key in ["routineSeriesID","browserAgentId","browserOrigin"] {if let value=rule[key]{fields[key]=value}}
        let saved=try store.update(job["id"] as! String,fields)
        let old=routines;routines[index]["lastTaskID"]=saved["id"]
        do{try persist()}catch{routines=old;throw error}
        return saved
    }
    func resumeBlockedBy(_ job:[String:Any],now:Date=Date()) throws {
        let original=routines
        do {
            for i in routines.indices where routines[i]["status"] as? String=="needs_attention" && routines[i]["workspace"] as? String==job["workspace"] as? String && routines[i]["agentId"] as? String==job["agentId"] as? String {
                let same=routines[i]["lastTaskID"] as? String==job["id"] as? String || job["routineSeriesID"] != nil && routines[i]["routineSeriesID"] as? String==job["routineSeriesID"] as? String
                guard same,routines[i]["lastError"] as? String=="The previous run needs attention. Review it before resuming this routine." else{continue}
                routines[i]["status"]="active";routines[i]["lastError"]="";routines[i]["nextRun"]=ISO8601DateFormatter().string(from:try Self.next(after:now,rule:routines[i]))
            }
            if !NSArray(array:original).isEqual(to:routines){try persist()}
        } catch {routines=original;throw error}
    }
    func enqueueDue(store:BuddyWorkerStore,workspace:String,now:Date=Date()) throws {
        let original=routines
        do {
            for i in routines.indices where routines[i]["workspace"] as? String==workspace && routines[i]["status"] as? String=="active" {
                let r=routines[i],id=r["id"] as! String
                let series=r["routineSeriesID"] as? String
                let prior=store.jobs.last{$0["workspace"] as? String==workspace && $0["agentId"] as? String==r["agentId"] as? String && ($0["routineID"] as? String==id || series != nil && $0["routineSeriesID"] as? String==series)}
                if let prior {
                    let status=prior["status"] as? String ?? ""
                    if ["failed","interrupted","waiting_user","paused"].contains(status) { routines[i]["status"]="needs_attention";routines[i]["lastError"]="The previous run needs attention. Review it before resuming this routine.";continue }
                    if !BuddyWorkerStore.terminal.contains(status) { continue }
                }
                guard let due=r["nextRun"] as? String,let date=ISO8601DateFormatter().date(from:due),date<=now else { continue }
                let job=try store.create(workspace:workspace,agent:r["agentId"] as! String,requestId:"routine:"+id+":"+due,title:r["title"] as! String,goal:r["goal"] as! String,kind:r["kind"] as! String,provider:r["provider"] as! String,budget:r["budgetUSD"] as! Double,model:r["model"] as? String)
                // Queue creation is idempotent if the process dies before saving nextRun.
                try store.update(job["id"] as! String,["routineID":id,"inboxQuery":r["query"] as! String,"previousRoutineResult":prior?["result"] ?? "","scheduledFor":due])
                if let series {try store.update(job["id"] as! String,["routineSeriesID":series])}
                if let owner=r["browserAgentId"] as? String,let origin=r["browserOrigin"] as? String {try store.update(job["id"] as! String,["browserAgentId":owner,"browserOrigin":origin])}
                routines[i]["lastTaskID"]=job["id"];routines[i]["lastScheduledFor"]=due
                routines[i]["nextRun"]=ISO8601DateFormatter().string(from:try Self.next(after:now,rule:r))
                if let series {for j in routines.indices where j != i && routines[j]["routineSeriesID"] as? String==series && routines[j]["workspace"] as? String==workspace && routines[j]["agentId"] as? String==r["agentId"] as? String {
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
