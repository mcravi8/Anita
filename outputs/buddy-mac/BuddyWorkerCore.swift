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

@MainActor final class BuddyWorkerStore {
    let directory: URL
    private let url: URL
    private(set) var jobs: [[String: Any]]
    private(set) var paused: Bool
    static let interrupted = Set(["running", "waiting_review", "stopping"])
    static let terminal = Set(["completed", "cancelled"])
    /// Finished tasks move to an archive file once the history gets long, so a routine that runs every hour never fills it up.
    static let archiveTrigger = 900, archiveKeep = 600, archiveSizeTrigger = 24 * 1024 * 1024
    init(directory: URL) throws {
        self.directory = directory; url = directory.appendingPathComponent("tasks.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            guard data.count <= 32 * 1024 * 1024, let saved = try JSONSerialization.jsonObject(with: data) as? [String: Any], saved["version"] as? Int == 1, let tasks = saved["tasks"] as? [[String: Any]], tasks.count <= 1000,
                  tasks.allSatisfy({ ($0["id"] as? String).flatMap(UUID.init(uuidString:)) != nil && ($0["workspace"] as? String).flatMap(UUID.init(uuidString:)) != nil }), Set(tasks.compactMap { $0["id"] as? String }).count == tasks.count else { throw BuddyWorkerFailure(message: "Buddy couldn’t verify its saved background tasks. Restore tasks.json before starting the worker.") }
            jobs = tasks; paused = saved["paused"] as? Bool ?? false
        } else { jobs = []; paused = false }
        if jobs.count > Self.archiveTrigger { try? archiveFinished(keeping: Self.archiveKeep) }
        for i in jobs.indices where Self.interrupted.contains(jobs[i]["status"] as? String ?? "") {
            var reviews = jobs[i]["reviews"] as? [[String: Any]] ?? []
            for r in reviews.indices { if reviews[r]["status"] as? String == "pending" { reviews[r]["status"] = "expired" } else if reviews[r]["status"] as? String == "answered" { reviews[r]["status"] = "uncertain" } }
            jobs[i]["reviews"] = reviews
            jobs[i]["status"] = "interrupted"; jobs[i]["progress"] = "The worker restarted. Review the last result and any external action before continuing. Nothing was automatically retried."
        }
        try persist()
    }
    /// Moves the oldest completed or cancelled tasks into their own file, leaving `keep` tasks in the list. Nothing is deleted. A task that
    /// needs attention stays, and so does the newest task of every routine, because the next run builds on its result. The tasks leave the
    /// list only after the archive file is safely written.
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
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let file = directory.appendingPathComponent("tasks-archive-\(stamp)-\(UUID().uuidString.prefix(8)).json")
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "archivedAt": stamp, "tasks": moved], options: [.sortedKeys])
        try data.write(to: file, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        jobs = kept
        return moved.count
    }
    func persist() throws {
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "paused": paused, "tasks": jobs], options: [.sortedKeys])
        guard data.count <= 32 * 1024 * 1024 else { throw BuddyWorkerFailure(message: "The worker’s saved task history is full.") }
        try data.write(to: url, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let file = try FileHandle(forWritingTo: url); try file.synchronize(); try file.close()
    }
    func job(_ id: String) throws -> [String: Any] {
        guard let job = jobs.first(where: { $0["id"] as? String == id }) else { throw BuddyWorkerFailure(message: "This background task is unavailable.") }; return job
    }
    @discardableResult func update(_ id: String, _ values: [String: Any]) throws -> [String: Any] {
        guard let i = jobs.firstIndex(where: { $0["id"] as? String == id }) else { throw BuddyWorkerFailure(message: "This task is unavailable.") }
        let old = jobs[i]; jobs[i].merge(values) { _, new in new }; jobs[i]["updatedAt"] = ISO8601DateFormatter().string(from: Date())
        do { try persist() } catch { jobs[i] = old; throw error }; return jobs[i]
    }
    func create(workspace: String, agent: String, requestId: String, title: String, goal: String, kind: String, provider: String, budget: Double, model:String?=nil) throws -> [String: Any] {
        guard UUID(uuidString: workspace) != nil, UUID(uuidString: agent) != nil, !requestId.isEmpty, requestId.count <= 200,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 150,
              !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, goal.count <= 30000,
              ["research", "applications", "email", "general", "coding"].contains(kind), ["chatgpt", "claude"].contains(provider), (kind != "coding" || provider=="claude"), budget.isFinite, budget >= 0, budget <= 10 else { throw BuddyWorkerFailure(message: "Add a short task title, a clear brief, and a supported provider.") }
        if let old = jobs.first(where: { $0["workspace"] as? String == workspace && $0["agentId"] as? String == agent && $0["requestId"] as? String == requestId }) { return old }
        let journalSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if jobs.count >= Self.archiveTrigger || journalSize > Self.archiveSizeTrigger { try? archiveFinished(keeping: journalSize > Self.archiveSizeTrigger ? 200 : Self.archiveKeep) }
        guard jobs.count < 1000, jobs.filter({ !Self.terminal.contains($0["status"] as? String ?? "") }).count < 30 else { throw BuddyWorkerFailure(message: "Finish or cancel some background tasks before adding more.") }
        let now = ISO8601DateFormatter().string(from: Date())
        var job: [String: Any] = ["id": UUID().uuidString, "workspace": workspace, "agentId": agent, "requestId": requestId, "title": title, "goal": goal, "kind": kind, "provider": provider, "budgetUSD": budget, "status": "queued", "progress": "Queued", "createdAt": now, "updatedAt": now, "attempt": 0, "events": [[String: Any]](), "result": "", "files": [[String: Any]]()]
        if let model,!model.isEmpty {guard model.range(of:#"^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$"#,options:.regularExpression) != nil else{throw BuddyWorkerFailure(message:"Invalid task model.")};job["model"]=model}
        jobs.append(job); do { try persist() } catch { jobs.removeLast(); throw error }; return job
    }
    func setPaused(_ value: Bool) throws { let old = paused; paused = value; do { try persist() } catch { paused = old; throw error } }
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
        return try update(id,fields)
    }
}

/// Durable local schedules. One overdue occurrence runs after wake, never a burst of catch-up sends.
@MainActor final class BuddyRoutineStore {
    private let url:URL
    private(set) var routines:[[String:Any]]
    init(directory:URL) throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        url=directory.appendingPathComponent("routines.json")
        if FileManager.default.fileExists(atPath:url.path) {
            let data=try Data(contentsOf:url)
            guard data.count<8*1024*1024,let saved=try JSONSerialization.jsonObject(with:data) as? [String:Any],saved["version"] as? Int==1,let values=saved["routines"] as? [[String:Any]],values.count<=100,Set(values.compactMap{$0["id"] as? String}).count==values.count else { throw BuddyWorkerFailure(message:"Buddy couldn't verify saved routines. Restore routines.json before starting the worker.") }
            for value in values { try Self.validate(value);guard let id=value["id"] as? String,UUID(uuidString:id) != nil,let next=value["nextRun"] as? String,ISO8601DateFormatter().date(from:next) != nil else { throw BuddyWorkerFailure(message:"A saved routine has invalid timing. Repair routines.json before starting.") } }
            routines=values
        } else { routines=[] }
    }
    private func persist() throws {
        try JSONSerialization.data(withJSONObject:["version":1,"routines":routines],options:[.sortedKeys]).write(to:url,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
    private static func validate(_ r:[String:Any]) throws {
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
