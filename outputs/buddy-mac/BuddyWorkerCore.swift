import Foundation
import CryptoKit
import Darwin

struct BuddyWorkerFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum BuddyWorkerLiveness {
    static func stalled(status:String,lastActivity:Date,now:Date=Date(),timeout:TimeInterval=180)->Bool {
        // Waiting for an actual human review or private sign-in is not a stalled model.
        ["starting","running"].contains(status) && now.timeIntervalSince(lastActivity)>timeout
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
        for i in jobs.indices where Self.interrupted.contains(jobs[i]["status"] as? String ?? "") {
            var reviews = jobs[i]["reviews"] as? [[String: Any]] ?? []
            for r in reviews.indices { if reviews[r]["status"] as? String == "pending" { reviews[r]["status"] = "expired" } else if reviews[r]["status"] as? String == "answered" { reviews[r]["status"] = "uncertain" } }
            jobs[i]["reviews"] = reviews
            jobs[i]["status"] = "interrupted"; jobs[i]["progress"] = "The worker restarted. Review the last result and any external action before continuing. Nothing was automatically retried."
        }
        try persist()
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
        guard jobs.count < 1000, jobs.filter({ !Self.terminal.contains($0["status"] as? String ?? "") }).count < 30 else { throw BuddyWorkerFailure(message: "Finish or cancel some background tasks before adding more.") }
        let now = ISO8601DateFormatter().string(from: Date())
        var job: [String: Any] = ["id": UUID().uuidString, "workspace": workspace, "agentId": agent, "requestId": requestId, "title": title, "goal": goal, "kind": kind, "provider": provider, "budgetUSD": budget, "status": "queued", "progress": "Queued", "createdAt": now, "updatedAt": now, "attempt": 0, "events": [[String: Any]](), "result": "", "files": [[String: Any]]()]
        if let model,!model.isEmpty {guard model.range(of:#"^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$"#,options:.regularExpression) != nil else{throw BuddyWorkerFailure(message:"Invalid task model.")};job["model"]=model}
        jobs.append(job); do { try persist() } catch { jobs.removeLast(); throw error }; return job
    }
    func setPaused(_ value: Bool) throws { let old = paused; paused = value; do { try persist() } catch { paused = old; throw error } }
    func resume(_ id: String, continuingCoding:Bool=false) throws -> [String: Any] {
        let job = try self.job(id)
        guard ["paused", "failed", "interrupted", "waiting_user"].contains(job["status"] as? String ?? "") || (continuingCoding && job["kind"] as? String=="coding" && job["status"] as? String=="completed") else { throw BuddyWorkerFailure(message: "This task can’t be resumed in its current state.") }
        return try update(id, ["status": "queued", "progress": "Queued to continue from saved progress. Check existing external state before any send or submission."])
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
            if action=="create" || action=="update" {
                if action=="create",let existing=routines.first(where:{$0["workspace"] as? String==workspace && $0["requestID"] as? String==requestID}) { return ["saved":true,"routine":existing] }
                let index=routines.firstIndex{$0["id"] as? String==args["routineID"] as? String && $0["workspace"] as? String==workspace && $0["agentId"] as? String==agent}
                guard action=="create" || index != nil else { throw BuddyWorkerFailure(message:"This routine is no longer available.") }
                guard action != "create" || routines.count<100 else { throw BuddyWorkerFailure(message:"Pause or remove old routines before adding more.") }
                var value=index.map{routines[$0]} ?? ["id":UUID().uuidString,"workspace":workspace,"agentId":agent,"requestID":requestID,"provider":provider,"budgetUSD":budget,"hour":9,"minute":0,"weekdays":[1,2,3,4,5,6,7],"timeZone":TimeZone.current.identifier,"query":"","kind":"general"]
                if index==nil,let model,!model.isEmpty {value["model"]=model}
                for field in ["title","goal","hour","minute","weekdays","timeZone","query","kind"] { if let v=args[field],!(v is NSNull) { value[field]=v } }
                try Self.validate(value)
                value["nextRun"]=ISO8601DateFormatter().string(from:try Self.next(after:now,rule:value));value["status"]="active";value["lastError"]=""
                // Repeated tool calls cannot create duplicate copies of the exact same routine.
                if action=="create",let existing=routines.first(where:{r in ["workspace","agentId","title","goal","query","timeZone"].allSatisfy{r[$0] as? String==value[$0] as? String} && r["hour"] as? Int==value["hour"] as? Int && r["minute"] as? Int==value["minute"] as? Int && r["weekdays"] as? [Int]==value["weekdays"] as? [Int]}) { return ["saved":true,"routine":existing] }
                if let index { routines[index]=value } else { routines.append(value) }
                try persist();return ["saved":true,"routine":value,"requiresMacAwake":true]
            }
            guard let i=routines.firstIndex(where:{$0["id"] as? String==args["routineID"] as? String && $0["workspace"] as? String==workspace && $0["agentId"] as? String==agent}) else { throw BuddyWorkerFailure(message:"This routine is no longer available.") }
            if action=="delete" { routines.remove(at:i);try persist();return ["deleted":true] }
            guard ["pause","resume"].contains(action) else { throw BuddyWorkerFailure(message:"Choose create, update, pause, resume, delete or list.") }
            routines[i]["status"]=action=="pause" ? "paused":"active";routines[i]["lastError"]=""
            if action=="resume" { routines[i]["nextRun"]=ISO8601DateFormatter().string(from:try Self.next(after:now,rule:routines[i])) }
            try persist();return ["saved":true,"routine":routines[i]]
        } catch { routines=old;throw error }
    }
    func enqueueDue(store:BuddyWorkerStore,workspace:String,now:Date=Date()) throws {
        let original=routines
        do {
            for i in routines.indices where routines[i]["workspace"] as? String==workspace && routines[i]["status"] as? String=="active" {
                let r=routines[i],id=r["id"] as! String
                let prior=store.jobs.last{$0["routineID"] as? String==id}
                if let prior {
                    let status=prior["status"] as? String ?? ""
                    if ["failed","interrupted","waiting_user","paused"].contains(status) { routines[i]["status"]="needs_attention";routines[i]["lastError"]="The previous run needs attention. Review it before resuming this routine.";continue }
                    if !BuddyWorkerStore.terminal.contains(status) { continue }
                }
                guard let due=r["nextRun"] as? String,let date=ISO8601DateFormatter().date(from:due),date<=now else { continue }
                let job=try store.create(workspace:workspace,agent:r["agentId"] as! String,requestId:"routine:"+id+":"+due,title:r["title"] as! String,goal:r["goal"] as! String,kind:r["kind"] as! String,provider:r["provider"] as! String,budget:r["budgetUSD"] as! Double,model:r["model"] as? String)
                // Queue creation is idempotent if the process dies before saving nextRun.
                try store.update(job["id"] as! String,["routineID":id,"inboxQuery":r["query"] as! String,"previousRoutineResult":prior?["result"] ?? "","scheduledFor":due])
                routines[i]["lastTaskID"]=job["id"];routines[i]["lastScheduledFor"]=due
                routines[i]["nextRun"]=ISO8601DateFormatter().string(from:try Self.next(after:now,rule:r))
            }
            if !NSArray(array:original).isEqual(to:routines) { try persist() }
        } catch { routines=original;throw error }
    }
}
