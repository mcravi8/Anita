import Darwin
import Foundation

/// Leases: cleanup that can't be forgotten. Something an agent creates on a connected service that bills over time (a machine, a pod) is
/// recorded the moment its create request is approved (Worker/Leases/leases.json: the service, what was created, the request that deletes
/// it, its deadline, its task and the agent's cost estimate), and Buddy runs that teardown itself: when the agent releases it, when its task
/// ends, is cancelled or fails, and when its approved hours pass. A worker restart (an update) keeps a live lease and watches its command
/// again. A teardown that fails is tried again with backoff, and the person is told plainly if it keeps failing.
///
/// Remote machines (`buddy_remote_machine`): a leased machine is reached over SSH by Buddy alone, with its own key pair (the agent only ever
/// gets the public key, for the create request), its own known_hosts, and only to a host the service itself named for that lease. The agent
/// uploads project paths, runs a command in the background, looks at it, and brings results back into the project, never overwriting a file
/// that differs; a command still running when its task's attempt ends is watched by Buddy, which continues the task when it ends.

/// What remote work talks to and runs, and how often it looks. Tests pass a stand-in ssh and their own clock.
struct BuddyRemoteEnvironment {
    /// ssh as a command (a test's stand-in may be a script run by an interpreter), tar and ssh-keygen on this Mac.
    var ssh = ["/usr/bin/ssh"], tar = "/usr/bin/tar", keygen = "/usr/bin/ssh-keygen"
    var now: () -> Date = Date.init
    /// How often a command Buddy watches is looked at.
    var poll: TimeInterval = 30
    /// How long a stopped command gets to finish writing before its results are fetched.
    var settle: Int = 5
    /// The first pause before a failed teardown is tried again (it doubles, up to ten minutes).
    var backoff: TimeInterval = 15
}

/// What a program Buddy ran said and how it ended.
struct BuddyProcessResult { let status: Int32, out: String, err: String, timedOut: Bool; var ok: Bool { status == 0 && !timedOut } }

/// Runs ssh, tar and ssh-keygen off the main thread, with a time limit. Their arguments never hold a secret.
enum BuddyProcessRunner {
    private final class Flag: @unchecked Sendable { private let lock = NSLock(); private var value = false; func set() { lock.lock(); value = true; lock.unlock() }; var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value } }
    private final class Box: @unchecked Sendable { var out = Data(), err = Data() }
    static func run(_ argv: [String], env: [String: String], input: URL? = nil, output: URL? = nil, timeout: TimeInterval) async -> BuddyProcessResult {
        await withCheckedContinuation { (done: CheckedContinuation<BuddyProcessResult, Never>) in
            DispatchQueue.global(qos: .utility).async {
                let p = Process(); p.executableURL = URL(fileURLWithPath: argv[0]); p.arguments = Array(argv.dropFirst()); p.environment = env
                let outPipe = Pipe(), errPipe = Pipe(), box = Box()
                var outFile: FileHandle?, inFile: FileHandle?
                if let output { FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]); outFile = try? FileHandle(forWritingTo: output) }
                p.standardOutput = outFile ?? outPipe; p.standardError = errPipe
                if let input { inFile = try? FileHandle(forReadingFrom: input) }
                p.standardInput = inFile ?? FileHandle.nullDevice
                do { try p.run() } catch { done.resume(returning: BuddyProcessResult(status: -1, out: "", err: error.localizedDescription, timedOut: false)); return }
                let reading = DispatchGroup()
                if outFile == nil { reading.enter(); DispatchQueue.global().async { box.out = outPipe.fileHandleForReading.readDataToEndOfFile(); reading.leave() } }
                reading.enter(); DispatchQueue.global().async { box.err = errPipe.fileHandleForReading.readDataToEndOfFile(); reading.leave() }
                let late = Flag(), pid = p.processIdentifier
                let limit = DispatchWorkItem { if p.isRunning { late.set(); p.terminate(); DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if p.isRunning { kill(pid, SIGKILL) } } } }
                DispatchQueue.global().asyncAfter(deadline: .now() + max(1, timeout), execute: limit)
                p.waitUntilExit(); limit.cancel()
                _ = reading.wait(timeout: .now() + 10)
                try? outFile?.close(); try? inFile?.close()
                func text(_ d: Data) -> String { String(decoding: d.prefix(256 * 1024), as: UTF8.self) }
                done.resume(returning: BuddyProcessResult(status: p.terminationStatus, out: text(box.out), err: text(box.err), timedOut: late.isSet))
            }
        }
    }
}

/// Buddy's SSH to one machine: Buddy's own key, a known_hosts file of the lease's own (the machine's host key is trusted the first time, then
/// held to), no agent, no user ssh configuration, nothing interactive. The known_hosts path is quoted: ssh reads that option as a list of
/// files split at spaces, and Buddy's folder is under "Application Support" (unquoted, the key went to a file named ~/Library/Application).
struct BuddyRemoteShell {
    let ssh: [String], identity: URL, knownHosts: URL, home: URL, host: String, port: Int, user: String
    var env: [String: String] { ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": home.path, "LC_ALL": "C"] }
    func args(_ remote: String) -> [String] {
        ssh + ["-F", "/dev/null", "-i", identity.path, "-o", "IdentitiesOnly=yes", "-o", "IdentityAgent=none", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new",
               "-o", "UserKnownHostsFile=\"" + knownHosts.path + "\"", "-o", "GlobalKnownHostsFile=/dev/null", "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=4",
               "-o", "LogLevel=ERROR", "-p", String(port), user + "@" + host, remote]
    }
    func run(_ remote: String, input: URL? = nil, output: URL? = nil, timeout: TimeInterval) async -> BuddyProcessResult {
        await BuddyProcessRunner.run(args(remote), env: env, input: input, output: output, timeout: timeout)
    }
}

/// `buddy_remote_machine`: the tool, its words, and moving files.
enum BuddyRemoteMachine {
    static let toolName = "buddy_remote_machine"
    static var tool: [String: Any] {
        let paths: [String: Any] = ["type": "array", "items": ["type": "string"], "maxItems": 20]
        return ["type": "function", "name": toolName,
                "description": "Work on a machine this task leased through buddy_service_api (for example a RunPod pod), over SSH that only Buddy runs: you never get Buddy's private key or a shell there. operation publicKey: Buddy's public SSH key, to put in the machine's create request (RunPod: env PUBLIC_KEY). Every other operation names lease (its id) and the machine's host and port as the service reported them (read them with a GET of what the lease created; Buddy accepts only an address the service itself gave for it), and user (default root). upload: project paths into the machine's work folder, at the same relative paths (paths listed on the lease's approval card go ahead; anything else is sending data out and waits for the user's approval). run: start command in the background in cwd (a project folder you uploaded, default the work folder), its output in a log; results lists the project paths Buddy brings back into this project by itself when the command ends. Save each result as soon as it is done (write a temporary file, then rename it) and skip results that already exist, so a stopped run keeps what it finished. One command at a time per lease. status: whether it runs, for how long, the last lines of its log, and which results exist on the machine. download: bring paths back into this project, adding new files; a file here that differs is kept and the machine's copy saved beside it as name (remote).ext. stop: stop the command (the lease stays). After run, end this attempt with one short sentence: Buddy watches the command, brings its results back and resumes this task with a note when it ends; then release the lease with buddy_service_api (action release) once you have what you need.",
                "inputSchema": ["type": "object", "additionalProperties": false, "required": ["operation"], "properties": [
                    "operation": ["type": "string", "enum": ["publicKey", "upload", "run", "status", "download", "stop"]],
                    "lease": ["type": "string", "description": "The lease id buddy_service_api returned for the machine."],
                    "host": ["type": "string", "description": "The machine's address as the service reported it."],
                    "port": ["type": "integer", "minimum": 1, "maximum": 65535, "description": "Its SSH port as the service reported it."],
                    "user": ["type": "string", "description": "The SSH user (default root)."],
                    "paths": paths.merging(["description": "upload, download: project paths, relative to the project root."]) { $1 },
                    "command": ["type": "string", "maxLength": 4000, "description": "run: the shell command to run on the machine."],
                    "cwd": ["type": "string", "description": "run: the project folder (uploaded) to run it in; default the work folder."],
                    "results": paths.merging(["description": "run: project paths Buddy brings back by itself when the command ends."]) { $1 }]]]
    }

    // MARK: words

    static func duration(_ seconds: TimeInterval) -> String {
        let m = Int((max(0, seconds) / 60).rounded())
        return m < 1 ? "under a minute" : m < 60 ? "\(m) min" : "\(m / 60) h \(m % 60) min"
    }
    static func size(_ bytes: Int) -> String {
        let units = ["bytes", "KB", "MB", "GB"]; var value = Double(bytes), unit = 0
        while value >= 1000, unit < units.count - 1 { value /= 1000; unit += 1 }
        return unit == 0 ? "\(bytes) bytes" : String(format: value < 10 ? "%.1f %@" : "%.0f %@", value, units[unit])
    }
    /// A path as a shell word, for the machine's shell.
    static func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    // MARK: project paths

    /// A project path an agent names: relative, inside the project, no `..`, no leading dash. "." is the whole project.
    static func relative(_ raw: Any?) -> String? {
        guard var path = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty, path.count <= 500, !path.contains("\0"), !path.hasPrefix("/"), !path.hasPrefix("~") else { return nil }
        while path.hasSuffix("/") && path.count > 1 { path.removeLast() }
        if path.hasPrefix("./") { path.removeFirst(2) }
        if path == "." { return path }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.contains(where: { $0.isEmpty || $0 == ".." || $0 == "." || $0.hasPrefix("-") }) else { return nil }
        return path
    }
    /// Whether `path` (relative) stays inside `project` once links are followed.
    static func inside(_ project: URL, _ path: String) -> Bool {
        let root = project.resolvingSymlinksInPath().standardizedFileURL.path
        let resolved = (path == "." ? project : project.appendingPathComponent(path)).resolvingSymlinksInPath().standardizedFileURL.path
        return resolved == root || resolved.hasPrefix(root + "/")
    }
    /// Whether the folder `path` (relative) may be made in `project`: the deepest part of it that exists already stays inside once links are
    /// followed, so making the rest can't land elsewhere.
    static func makeable(_ project: URL, _ path: String) -> Bool {
        var parts = path.split(separator: "/").map(String.init)
        while !parts.isEmpty, !FileManager.default.fileExists(atPath: project.appendingPathComponent(parts.joined(separator: "/")).path) { parts.removeLast() }
        return inside(project, parts.isEmpty ? "." : parts.joined(separator: "/"))
    }
    /// Checked project paths (each relative and inside the project; `existing`: each must be there).
    static func paths(_ raw: Any?, project: URL, existing: Bool, what: String) throws -> [String] {
        let list = raw as? [Any] ?? []
        guard !list.isEmpty, list.count <= 20 else { throw BuddyServiceAPI.Failure(message: "Give \(what) as 1 to 20 project paths.") }
        var out: [String] = []
        for item in list {
            guard let path = relative(item), inside(project, path), !existing || FileManager.default.fileExists(atPath: (path == "." ? project : project.appendingPathComponent(path)).path) else {
                throw BuddyServiceAPI.Failure(message: "Each of \(what) must be a path in this project, relative to its root\(existing ? ", that exists" : ""): \(item) isn't.")
            }
            if !out.contains(path) { out.append(path) }
        }
        return out
    }
    /// What a list of project paths holds: each with its files and bytes (links are not followed).
    static func measure(_ project: URL, paths: [String]) -> [[String: Any]] {
        paths.map { path in
            let url = path == "." ? project : project.appendingPathComponent(path)
            var files = 0, bytes = 0
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true { files = 1; bytes = values?.fileSize ?? 0 }
            else if let walk = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) {
                for case let item as URL in walk {
                    guard let v = try? item.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), v.isRegularFile == true, item.lastPathComponent != ".DS_Store" else { continue }
                    files += 1; bytes += v.fileSize ?? 0
                }
            }
            return ["path": path, "files": files, "bytes": bytes]
        }
    }
    /// Whether every path is one of `approved` or inside one.
    static func covered(_ paths: [String], by approved: [String]) -> Bool {
        paths.allSatisfy { p in approved.contains { $0 == "." || p == $0 || p.hasPrefix($0 + "/") } }
    }

    /// Moves what came back (`source`: the machine's paths under its work folder) into the project, only under `wanted`: a file that isn't
    /// here is added; one that is here and the same is left; one that is here and differs is kept, and the machine's copy goes beside it as
    /// "name (remote).ext". Links, devices and anything outside the project are skipped.
    static func merge(from source: URL, into project: URL, wanted: [String]) -> [String: Any] {
        let base = source.standardizedFileURL.path, fm = FileManager.default
        var added = 0, unchanged = 0, skipped = 0, conflicts: [[String: Any]] = []
        guard let walk = fm.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return ["added": 0, "unchanged": 0, "conflicts": [Any](), "skipped": 0] }
        for case let item as URL in walk {
            guard let v = try? item.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { skipped += 1; continue }
            if v.isSymbolicLink == true { skipped += 1; continue }
            guard v.isRegularFile == true else { continue }
            let path = item.standardizedFileURL.path
            guard path.hasPrefix(base + "/") else { skipped += 1; continue }
            let rel = String(path.dropFirst(base.count + 1))
            guard relative(rel) == rel, covered([rel], by: wanted), item.lastPathComponent != ".DS_Store" else { skipped += 1; continue }
            let parent = (rel as NSString).deletingLastPathComponent
            guard parent.isEmpty || (makeable(project, parent) && (try? fm.createDirectory(at: project.appendingPathComponent(parent), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])) != nil),
                  inside(project, parent.isEmpty ? "." : parent) else { skipped += 1; continue }
            let target = project.appendingPathComponent(rel)
            var folder: ObjCBool = false
            let link = (try? target.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
            if link || fm.fileExists(atPath: target.path, isDirectory: &folder) {
                if !link, !folder.boolValue, fm.contentsEqual(atPath: target.path, andPath: item.path) { unchanged += 1; continue }
                let ext = (rel as NSString).pathExtension, stem = ext.isEmpty ? rel : String(rel.dropLast(ext.count + 1))
                var n = 1, beside = ""
                repeat { beside = stem + (n == 1 ? " (remote)" : " (remote \(n))") + (ext.isEmpty ? "" : "." + ext); n += 1 }
                while fm.fileExists(atPath: project.appendingPathComponent(beside).path) && !fm.contentsEqual(atPath: project.appendingPathComponent(beside).path, andPath: item.path) && n < 100
                if fm.fileExists(atPath: project.appendingPathComponent(beside).path) { unchanged += 1; continue }
                guard (try? fm.moveItem(at: item, to: project.appendingPathComponent(beside))) != nil else { skipped += 1; continue }
                conflicts.append(["path": rel, "savedAs": beside]); continue
            }
            guard (try? fm.moveItem(at: item, to: target)) != nil else { skipped += 1; continue }
            added += 1
        }
        return ["added": added, "unchanged": unchanged, "conflicts": conflicts, "skipped": skipped]
    }
    /// What came back, in a sentence.
    static func brought(_ b: [String: Any]?, paths: [String]) -> String {
        guard let b else { return "" }
        let where_ = paths.joined(separator: ", ")
        if let failed = b["error"] as? String { return "Bringing back \(where_) failed: \(failed)." }
        let added = b["added"] as? Int ?? 0, same = b["unchanged"] as? Int ?? 0, conflicts = b["conflicts"] as? [[String: Any]] ?? []
        if added + same + conflicts.count == 0 { return "Nothing was at \(where_) on the machine, so nothing came back." }
        var out = "Buddy brought \(where_) back into your project: \(added) new file\(added == 1 ? "" : "s") added" + (same > 0 ? ", \(same) already here and the same" : "")
        if conflicts.isEmpty { return out + "; nothing here was overwritten." }
        let shown = conflicts.prefix(10).map { "\($0["path"] as? String ?? "") (the machine’s copy is \($0["savedAs"] as? String ?? ""))" }.joined(separator: ", ")
        out += ". \(conflicts.count) file\(conflicts.count == 1 ? "" : "s") here differed from the machine’s copy; yours \(conflicts.count == 1 ? "was" : "were") kept and the machine’s saved beside: \(shown)\(conflicts.count > 10 ? ", …" : "")."
        return out
    }
}

/// Buddy's leases and the machines they hold. Main-actor state; the waiting (the service's API, ssh, tar) happens off it.
@MainActor final class BuddyLeases {
    struct Hooks {
        /// The task's connected service with the person's key (nil when it or its key is gone).
        var client: (_ workspace: String, _ service: String) -> BuddyServiceClient?
        /// A lease's record changed: its task's summary follows.
        var changed: ([String: Any]) -> Void
        /// A command Buddy watched ended (and what it asked for came back), or a lease ended while its command ran: the task hears of it.
        var runEnded: ([String: Any]) -> Void
        /// A lease ended (torn down), or its teardown keeps failing, or Buddy can't tell what was created: the person is told plainly.
        var released: ([String: Any]) -> Void
    }
    let folder: URL, env: BuddyRemoteEnvironment
    var hooks: Hooks
    private(set) var records: [[String: Any]] = []
    private var closing: Set<String> = [], watching: Set<String> = [], tearing: Set<String> = []
    private var closed = false
    init(folder: URL, env: BuddyRemoteEnvironment, hooks: Hooks) { self.folder = folder; self.env = env; self.hooks = hooks }

    private var file: URL { folder.appendingPathComponent("leases.json") }
    private var sshFolder: URL { folder.appendingPathComponent("ssh", isDirectory: true) }
    private func leaseFolder(_ id: String) -> URL { folder.appendingPathComponent("Leases/" + id, isDirectory: true) }
    private func stamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    private func date(_ value: Any?) -> Date? { (value as? String).flatMap { ISO8601DateFormatter().date(from: $0) } }
    static let live: Set<String> = ["creating", "active", "releasing"]

    func load() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        records = ((try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?["leases"] as? [[String: Any]] ?? []
    }
    private func save() {
        // Ended leases are kept for a while as the record of what was created and deleted; the oldest go once there are many.
        if records.count > 300, let cut = records.firstIndex(where: { !Self.live.contains($0["state"] as? String ?? "") }) { records.remove(at: cut) }
        guard let data = try? JSONSerialization.data(withJSONObject: ["leases": records], options: [.sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? data.write(to: file, options: .atomic); try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    func lease(_ id: String) -> [String: Any]? { records.first { $0["id"] as? String == id } }
    func leases(task: String) -> [[String: Any]] { records.filter { $0["taskId"] as? String == task } }
    /// Whether a command Buddy watches runs on any of the task's leases (its task waits for it).
    func running(task: String) -> [String: Any]? { records.last { $0["taskId"] as? String == task && $0["state"] as? String == "active" && ($0["run"] as? [String: Any])?["state"] as? String == "running" } }
    /// A command that ended and whose task has not heard of it.
    func undelivered(task: String) -> [String: Any]? { records.last { $0["taskId"] as? String == task && ($0["run"] as? [String: Any])?["delivered"] as? Bool == false && ($0["run"] as? [String: Any])?["state"] as? String != "running" } }
    func markDelivered(_ id: String) { if var run = lease(id)?["run"] as? [String: Any] { run["delivered"] = true; update(id, ["run": run], tell: false) } }
    /// Whether anything is under way on a machine now (the Mac stays awake for it).
    var busy: Bool { records.contains { $0["state"] as? String == "active" && ($0["run"] as? [String: Any])?["state"] as? String == "running" } }
    private func update(_ id: String, _ values: [String: Any], tell: Bool = true) {
        guard let i = records.firstIndex(where: { $0["id"] as? String == id }) else { return }
        records[i].merge(values) { _, new in new }; records[i]["updatedAt"] = stamp(env.now())
        records[i]["estimatedCostUSD"] = estimate(records[i])
        save()
        if tell, !closed { hooks.changed(records[i]) }
    }
    /// The agent's estimate of what a lease has cost so far: its price per hour for the time it existed, or its total.
    private func estimate(_ r: [String: Any]) -> Double {
        let cost = r["cost"] as? [String: Any] ?? [:]
        if let total = cost["total"] as? Double, cost["perHour"] == nil { return total }
        guard let start = date(r["createdAt"]), let perHour = cost["perHour"] as? Double else { return 0 }
        let end = date(r["releasedAt"]) ?? env.now()
        return ((perHour * max(0, end.timeIntervalSince(start)) / 3600 + (cost["total"] as? Double ?? 0)) * 100).rounded() / 100
    }

    // MARK: a lease's life

    /// Records a lease before its create request is sent, so a create whose answer never comes is still known.
    func prepare(workspace: String, task: String, agent: String, project: URL, service: BuddyConnectedService, declared: [String: Any], cost: [String: Any]?, request: [String: Any], review: String, approvedBy: String, uploads: [[String: Any]]) -> String {
        let id = UUID().uuidString.lowercased()
        var record: [String: Any] = ["id": id, "short": String(id.replacingOccurrences(of: "-", with: "").prefix(12)), "workspace": workspace, "taskId": task, "agentId": agent, "projectPath": project.path,
                                     "service": service.id, "serviceName": service.name, "declared": declared, "teardown": declared["teardown"] ?? [:], "maxHours": declared["maxHours"] ?? 1,
                                     "create": request, "reviewId": review, "approvedBy": approvedBy, "uploads": uploads, "state": "creating", "preparedAt": stamp(env.now()), "observed": [String]()]
        if let cost { record["cost"] = cost }
        records.append(record); save()
        return id
    }
    /// The create request succeeded: what it created, from the declared id or the response, and the lease's clock starts. Nil when the
    /// response doesn't say what was created (the person is told: Buddy can't delete what it can't name).
    @discardableResult func activate(_ id: String, response: Any?) -> [String: Any]? {
        guard let r = lease(id), let declared = r["declared"] as? [String: Any], let named = declared["resource"] as? String else { return nil }
        let resource = named.hasPrefix("/") ? BuddyServiceAPI.pointer(named, in: response) : named
        guard let resource, !resource.isEmpty else {
            update(id, ["state": "unknown", "endedAt": stamp(env.now()), "problem": "The answer to the create request didn’t say what was created (\(named) wasn’t in it), so Buddy can’t delete it by itself."])
            if let r = lease(id) { hooks.released(r) }
            return nil
        }
        let now = env.now(), hours = r["maxHours"] as? Double ?? 1
        update(id, ["state": "active", "resource": resource, "createdAt": stamp(now), "deadline": stamp(now.addingTimeInterval(hours * 3600)), "observed": Array(BuddyServiceAPI.scalars(response).prefix(400))])
        return lease(id)
    }
    /// The create request was refused: nothing was created.
    func void(_ id: String, why: String) { update(id, ["state": "void", "endedAt": stamp(env.now()), "problem": String(why.prefix(300))]) }
    /// The create request may or may not have created something (no answer): the person is told to check, since Buddy can't name it.
    func unknown(_ id: String, why: String) {
        update(id, ["state": "unknown", "endedAt": stamp(env.now()), "problem": String(why.prefix(300))])
        if let r = lease(id) { hooks.released(r) }
    }
    /// What the service said about a leased thing (a GET of it, say): the addresses it names are the only ones Buddy's SSH will go to.
    func observe(task: String, service: String, path: String, value: Any?) {
        for r in records where r["taskId"] as? String == task && r["service"] as? String == service && r["state"] as? String == "active" {
            guard let id = r["id"] as? String, let resource = r["resource"] as? String, path.contains(resource) || path.contains(resource.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? resource) else { continue }
            var seen = r["observed"] as? [String] ?? []
            for value in BuddyServiceAPI.scalars(value) where !seen.contains(value) { seen.append(value) }
            update(id, ["observed": Array(seen.suffix(400))], tell: false)
        }
    }
    /// The request that deletes a lease's thing.
    func teardownRequest(_ r: [String: Any]) -> (method: String, path: String)? {
        guard let teardown = r["teardown"] as? [String: Any], let method = teardown["method"] as? String, let template = teardown["path"] as? String, let resource = r["resource"] as? String else { return nil }
        var allowed = CharacterSet.urlPathAllowed; allowed.remove(charactersIn: "/")
        return (method, template.replacingOccurrences(of: "{id}", with: resource.addingPercentEncoding(withAllowedCharacters: allowed) ?? resource))
    }

    // MARK: ending a lease

    /// Ends a lease: a command still running there is stopped and its results brought back, then the teardown runs (tried again with
    /// backoff until it works). `why`: done (the agent released it), completed, cancelled, failed, paused, time, restart.
    func close(_ id: String, why: String) async {
        guard let r = lease(id), ["active", "releasing"].contains(r["state"] as? String ?? ""), !closing.contains(id) else { return }
        closing.insert(id); defer { closing.remove(id) }
        var ran = false
        if r["state"] as? String == "active", var run = r["run"] as? [String: Any], run["state"] as? String == "running" {
            ran = true
            if let shell = shell(r), let short = r["short"] as? String {
                _ = await stopCommand(shell, short: short)
                let deadline = date(r["deadline"]) ?? env.now()
                let window = max(180, deadline.timeIntervalSince(env.now()))
                let results = run["results"] as? [String] ?? []
                if !results.isEmpty { run["broughtBack"] = await bringBack(id, shell: shell, paths: results, timeout: window) }
                let log = await shell.run("tail -n 30 \"$HOME/buddy/\(short)/output.log\" 2>/dev/null", timeout: 60)
                if log.ok, !log.out.isEmpty { run["lastLog"] = String(log.out.suffix(4000)) }
            }
            if let began = date(run["startedAt"]) { run["seconds"] = env.now().timeIntervalSince(began) }
            run["state"] = "stopped"; run["why"] = why; run["endedAt"] = stamp(env.now()); run["delivered"] = false
            update(id, ["run": run])
        }
        update(id, ["state": "releasing", "why": lease(id)?["why"] ?? why, "releaseRequestedAt": lease(id)?["releaseRequestedAt"] ?? stamp(env.now())])
        await teardown(id)
        if ran, !closed, let done = lease(id) { hooks.runEnded(done) }
    }
    /// One try at the teardown request. 2xx, or a 404 or 410 (it is gone already), ends the lease; anything else is tried again later, and
    /// after three failed tries the person is told.
    private func teardown(_ id: String) async {
        guard let r = lease(id), r["state"] as? String == "releasing", !tearing.contains(id), let workspace = r["workspace"] as? String, let service = r["service"] as? String else { return }
        tearing.insert(id); defer { tearing.remove(id) }
        var error = ""
        if let request = teardownRequest(r), let client = hooks.client(workspace, service) {
            do {
                let response = try await client.send(request.method, path: request.path, timeout: 60)
                if (200..<300).contains(response.status) || [404, 410].contains(response.status) {
                    update(id, ["state": "released", "releasedAt": stamp(env.now()), "teardownStatus": response.status, "lastError": NSNull()])
                    if !closed, let done = lease(id) { hooks.released(done) }
                    return
                }
                error = "\(r["serviceName"] as? String ?? "The service") answered HTTP \(response.status)"
            } catch let failure { error = failure.localizedDescription }
        } else { error = "\(r["serviceName"] as? String ?? "The service") isn’t connected any more (or its key is gone), so Buddy can’t reach it" }
        let tries = (r["attempts"] as? Int ?? 0) + 1
        let wait = min(600, env.backoff * pow(2, Double(min(tries - 1, 10))))
        update(id, ["attempts": tries, "lastError": String(error.prefix(300)), "nextTryAt": stamp(env.now().addingTimeInterval(wait))])
        if tries >= 3, r["alerted"] as? Bool != true, !closed {
            update(id, ["alerted": true], tell: false)
            if let now = lease(id) { hooks.released(now) }
        }
    }
    /// An agent releasing its lease: the teardown now, and the lease as it ended (or as it waits for another try).
    func release(_ id: String) async -> [String: Any]? { await close(id, why: "done"); return lease(id) }

    /// Once a tick: deadlines, leases whose task ended, and teardowns due another try. `task` gives a task's record (nil when it is gone).
    func tick(task: (String) -> [String: Any]?, live: Set<String>) {
        guard !closed else { return }
        let now = env.now()
        for r in records {
            guard let id = r["id"] as? String, !closing.contains(id) else { continue }
            let state = r["state"] as? String ?? ""
            if state == "releasing", !tearing.contains(id), (date(r["nextTryAt"]) ?? .distantPast) <= now { Task { await self.teardown(id) }; continue }
            guard state == "active" else { continue }
            // The approved hours: a command still running is stopped a little before them, so its results can come back in time.
            if let deadline = date(r["deadline"]) {
                let total = (r["maxHours"] as? Double ?? 1) * 3600, reserve = min(total / 2, min(15 * 60, max(2 * 60, total * 0.05)))
                let running = (r["run"] as? [String: Any])?["state"] as? String == "running"
                if now >= deadline || (running && now >= deadline.addingTimeInterval(-reserve)) { Task { await self.close(id, why: "time") }; continue }
            }
            guard let taskID = r["taskId"] as? String, !live.contains(taskID) else { continue }
            if let why = Self.ended(task(taskID)) { Task { await self.close(id, why: why) } }
        }
    }
    /// Whether a task has ended in a way that ends its leases, and how: done, cancelled, failed for good, or paused by the person. A task that
    /// waits for its command, for the person's answer, or for an automatic retry keeps them.
    static func ended(_ job: [String: Any]?) -> String? {
        guard let job else { return "gone" }
        let status = job["status"] as? String ?? "", cause = job["stopCause"] as? String ?? "", retrying = ["pending", "queued"].contains((job["recovery"] as? [String: Any])?["state"] as? String ?? "")
        switch status {
        case "completed": return "completed"
        case "cancelled": return "cancelled"
        case "failed", "interrupted": return retrying ? nil : "failed"
        case "paused": return cause.hasPrefix("user.") && cause != "user.pauseAll" ? "paused" : nil
        default: return nil
        }
    }
    /// After the worker starts (an update, a crash, the Mac restarting): a live lease carries on as recorded. A command still running on its
    /// machine is watched again, and the lease still ends when its task ends and at its approved hours (tick), so an update no longer stops
    /// work on a rented machine. A teardown under way is tried again; a create request that never answered can't be named, and the person
    /// is told.
    func start() {
        load()
        for r in records { guard let id = r["id"] as? String else { continue }
            switch r["state"] as? String ?? "" {
            case "creating": unknown(id, why: "Buddy restarted while the create request was under way, so it can’t tell whether something was created.")
            case "active": if (r["run"] as? [String: Any])?["state"] as? String == "running" { watch(id) }
            case "releasing": Task { await self.teardown(id) }
            default: break
            }
        }
    }
    /// The worker is closing: leases stay as recorded for the next worker to end.
    func shutdown() { closed = true }

    // MARK: Buddy's SSH key

    /// Buddy's own ed25519 key pair for machines it leases (made once; private key 0600 in a 0700 folder). Returns the public key.
    func publicKey() async throws -> String {
        let fm = FileManager.default, key = sshFolder.appendingPathComponent("id_ed25519"), pub = sshFolder.appendingPathComponent("id_ed25519.pub")
        try fm.createDirectory(at: sshFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sshFolder.path)
        if !fm.fileExists(atPath: key.path) || !fm.fileExists(atPath: pub.path) {
            try? fm.removeItem(at: key); try? fm.removeItem(at: pub)
            let made = await BuddyProcessRunner.run([env.keygen, "-q", "-t", "ed25519", "-N", "", "-C", "buddy-remote-machine", "-f", key.path], env: ["PATH": "/usr/bin:/bin", "HOME": folder.path], timeout: 30)
            guard made.ok else { throw BuddyServiceAPI.Failure(message: "Buddy couldn’t make its SSH key (\(made.err.prefix(200))).") }
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key.path)
        let text = (try String(contentsOf: pub, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("ssh-ed25519 ") else { throw BuddyServiceAPI.Failure(message: "Buddy’s SSH key is unreadable.") }
        return text
    }
    private func shell(_ r: [String: Any]) -> BuddyRemoteShell? {
        guard let m = r["machine"] as? [String: Any], let host = m["host"] as? String, let port = m["port"] as? Int, let user = m["user"] as? String, let id = r["id"] as? String else { return nil }
        try? FileManager.default.createDirectory(at: leaseFolder(id), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return BuddyRemoteShell(ssh: env.ssh, identity: sshFolder.appendingPathComponent("id_ed25519"), knownHosts: leaseFolder(id).appendingPathComponent("known_hosts"), home: folder, host: host, port: port, user: user)
    }

    // MARK: the machine

    /// The machine an agent names for a lease of its task: the lease must be active and the address one the service itself reported for
    /// what the lease created. Returns the lease with its machine bound.
    func machine(_ id: String, task: String, host rawHost: Any?, port rawPort: Any?, user rawUser: Any?) throws -> [String: Any] {
        guard let r = lease(id), r["taskId"] as? String == task else { throw BuddyServiceAPI.Failure(message: "That isn’t a lease of this task. List them with buddy_service_api (action leases).") }
        guard r["state"] as? String == "active" else { throw BuddyServiceAPI.Failure(message: "That lease has ended (\(r["state"] as? String ?? "")), so its machine is gone.") }
        let bound = r["machine"] as? [String: Any]
        let host = (rawHost as? String)?.trimmingCharacters(in: .whitespaces) ?? bound?["host"] as? String ?? ""
        let port = (rawPort as? NSNumber)?.intValue ?? bound?["port"] as? Int ?? 0
        let user = ((rawUser as? String)?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 } ?? bound?["user"] as? String ?? "root"
        guard host.range(of: #"^[A-Za-z0-9][A-Za-z0-9.:-]{0,252}$"#, options: .regularExpression) != nil, (1...65535).contains(port), user.range(of: #"^[a-z_][a-z0-9_-]{0,31}$"#, options: .regularExpression) != nil else {
            throw BuddyServiceAPI.Failure(message: "Give host and port as the service reported them for the machine (and user, default root).")
        }
        let seen = Set(r["observed"] as? [String] ?? [])
        guard seen.contains(host), seen.contains(String(port)) else {
            throw BuddyServiceAPI.Failure(message: "\(r["serviceName"] as? String ?? "The service") hasn’t reported \(host):\(port) for this lease. Read what the lease created with a GET first (Buddy accepts only an address the service itself gave for it).")
        }
        if bound?["host"] as? String != host || bound?["port"] as? Int != port || bound?["user"] as? String != user { update(id, ["machine": ["host": host, "port": port, "user": user]], tell: false) }
        return lease(id) ?? r
    }
    /// Sends project paths into the machine's work folder, at the same relative paths.
    func upload(_ id: String, paths: [String]) async throws -> [String: Any] {
        guard let r = lease(id), let shell = shell(r), let short = r["short"] as? String else { throw BuddyServiceAPI.Failure(message: "Name the machine first (host and port).") }
        let project = URL(fileURLWithPath: r["projectPath"] as? String ?? ""), staging = leaseFolder(id), archive = staging.appendingPathComponent("upload.tar")
        defer { try? FileManager.default.removeItem(at: archive) }
        let packed = await BuddyProcessRunner.run([env.tar, "-cf", archive.path, "--exclude", ".DS_Store", "-C", project.path] + paths, env: ["PATH": "/usr/bin:/bin", "COPYFILE_DISABLE": "1", "LC_ALL": "C"], timeout: 1800)
        guard packed.ok else { throw BuddyServiceAPI.Failure(message: "Buddy couldn’t pack them: " + packed.err.prefix(300)) }
        let base = "\"$HOME/buddy/\(short)/work\""
        let ready = await shell.run("mkdir -p \(base) && command -v tar >/dev/null && echo buddy-ok", timeout: 120)
        guard ready.ok, ready.out.contains("buddy-ok") else { throw BuddyServiceAPI.Failure(message: "The machine didn’t answer over SSH (\(ready.err.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))). It may still be starting: check it with a GET, then try again.") }
        let sent = await shell.run("tar -xf - -C \(base) && echo buddy-ok", input: archive, timeout: 3 * 3600)
        guard sent.ok, sent.out.contains("buddy-ok") else { throw BuddyServiceAPI.Failure(message: "The upload failed: " + sent.err.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)) }
        let measured = BuddyRemoteMachine.measure(project, paths: paths)
        var sentList = r["sent"] as? [[String: Any]] ?? []; sentList.append(contentsOf: measured)
        update(id, ["sent": Array(sentList.suffix(50))])
        return ["uploaded": measured, "to": "the machine’s work folder, at the same paths"]
    }
    /// Starts a command in the background in its own process group, its output in a log, and watches it.
    func run(_ id: String, command: String, cwd: String, results: [String]) async throws -> [String: Any] {
        guard let r = lease(id), let shell = shell(r), let short = r["short"] as? String else { throw BuddyServiceAPI.Failure(message: "Name the machine first (host and port).") }
        if (r["run"] as? [String: Any])?["state"] as? String == "running" { throw BuddyServiceAPI.Failure(message: "A command already runs on this lease's machine. Check it with status, or stop it first.") }
        let script = leaseFolder(id).appendingPathComponent("job.sh"), base = "\"$HOME/buddy/\(short)\""
        try Data(command.utf8).write(to: script, options: .atomic); defer { try? FileManager.default.removeItem(at: script) }
        let job = await shell.run("mkdir -p \(base)/work && rm -f \(base)/exit \(base)/pid && cat > \(base)/job.sh && echo buddy-ok", input: script, timeout: 120)
        guard job.ok, job.out.contains("buddy-ok") else { throw BuddyServiceAPI.Failure(message: "The machine didn’t take the command (\(job.err.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))).") }
        let started = await shell.run("""
        cd \(base)/work/\(BuddyRemoteMachine.quoted(cwd)) || { echo no folder \(BuddyRemoteMachine.quoted(cwd)) on the machine >&2; exit 3; }
        set -m
        nohup bash -c 'bash "$HOME/buddy/\(short)/job.sh"; echo $? > "$HOME/buddy/\(short)/exit"' > \(base)/output.log 2>&1 < /dev/null &
        echo $! > \(base)/pid
        echo buddy-started
        """, timeout: 120)
        guard started.ok, started.out.contains("buddy-started") else { throw BuddyServiceAPI.Failure(message: "The command didn’t start: " + started.err.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)) }
        let run: [String: Any] = ["id": UUID().uuidString.lowercased(), "command": command, "cwd": cwd, "results": results, "startedAt": stamp(env.now()), "state": "running", "resultFiles": 0]
        update(id, ["run": run])
        watch(id)
        return run
    }
    /// How the command is doing, from the machine itself.
    func status(_ id: String) async -> [String: Any] {
        guard let r = lease(id), var run = r["run"] as? [String: Any] else { return ["state": "none"] }
        if run["state"] as? String == "running", let shell = shell(r), let short = r["short"] as? String, let seen = await look(shell, short: short, results: run["results"] as? [String] ?? []) {
            run["resultFiles"] = seen.files; run["lastLog"] = seen.log; run["lastSeenAt"] = stamp(env.now())
            update(id, ["run": run], tell: false)
        }
        return lease(id)?["run"] as? [String: Any] ?? run
    }
    /// Brings project paths back from the machine into the project.
    func download(_ id: String, paths: [String]) async throws -> [String: Any] {
        guard let r = lease(id), let shell = shell(r) else { throw BuddyServiceAPI.Failure(message: "Name the machine first (host and port).") }
        return await bringBack(id, shell: shell, paths: paths, timeout: 3 * 3600)
    }
    /// Stops the command (the lease stays).
    func stop(_ id: String) async -> [String: Any] {
        guard let r = lease(id), var run = r["run"] as? [String: Any], run["state"] as? String == "running", let shell = shell(r), let short = r["short"] as? String else { return lease(id)?["run"] as? [String: Any] ?? ["state": "none"] }
        _ = await stopCommand(shell, short: short)
        if let began = date(run["startedAt"]) { run["seconds"] = env.now().timeIntervalSince(began) }
        run["state"] = "stopped"; run["why"] = "stopped"; run["endedAt"] = stamp(env.now()); run["delivered"] = true
        update(id, ["run": run])
        return run
    }

    private func look(_ shell: BuddyRemoteShell, short: String, results: [String]) async -> (state: String, exit: Int?, files: Int, log: String)? {
        let paths = results.map(BuddyRemoteMachine.quoted).joined(separator: " ")
        let seen = await shell.run("""
        B="$HOME/buddy/\(short)"
        if [ -f "$B/exit" ]; then echo "BUDDY-STATE exited $(cat "$B/exit")"; elif [ -f "$B/pid" ] && kill -0 "$(cat "$B/pid")" 2>/dev/null; then echo "BUDDY-STATE running"; else echo "BUDDY-STATE lost"; fi
        n=0; if cd "$B/work" 2>/dev/null; then for p in \(paths.isEmpty ? "''" : paths); do if [ -n "$p" ] && [ -e "$p" ]; then c=$(find "$p" -type f | wc -l); n=$((n + c)); fi; done; fi; echo "BUDDY-FILES $n"
        echo BUDDY-LOG
        tail -n 30 "$B/output.log" 2>/dev/null
        """, timeout: 120)
        let lines = seen.out.split(separator: "\n", omittingEmptySubsequences: false)
        guard seen.ok, let state = lines.first(where: { $0.hasPrefix("BUDDY-STATE ") })?.split(separator: " ") else { return nil }
        let files = lines.first { $0.hasPrefix("BUDDY-FILES ") }.flatMap { Int($0.dropFirst(12).trimmingCharacters(in: .whitespaces)) } ?? 0
        let log = seen.out.components(separatedBy: "BUDDY-LOG\n").dropFirst().joined(separator: "BUDDY-LOG\n")
        return (String(state.count > 1 ? state[1] : "lost"), state.count > 2 ? Int(state[2]) : nil, files, String(log.suffix(4000)))
    }
    /// The command's whole process group is stopped, given a moment to finish its writes, then killed.
    private func stopCommand(_ shell: BuddyRemoteShell, short: String) async -> BuddyProcessResult {
        await shell.run("""
        B="$HOME/buddy/\(short)"
        if [ -f "$B/pid" ] && [ ! -f "$B/exit" ]; then p=$(cat "$B/pid"); kill -TERM -- "-$p" 2>/dev/null || kill -TERM "$p" 2>/dev/null; sleep \(env.settle); kill -KILL -- "-$p" 2>/dev/null; fi
        echo buddy-stopped
        """, timeout: TimeInterval(env.settle + 60))
    }
    /// The paths that exist on the machine, as one tar stream into the lease's own folder, then merged into the project.
    private func bringBack(_ id: String, shell: BuddyRemoteShell, paths: [String], timeout: TimeInterval) async -> [String: Any] {
        guard let r = lease(id), let short = r["short"] as? String else { return ["error": "the lease's record is gone"] }
        let staging = leaseFolder(id).appendingPathComponent("download-" + UUID().uuidString, isDirectory: true), out = staging.appendingPathComponent("out", isDirectory: true), archive = staging.appendingPathComponent("results.tar")
        let fm = FileManager.default
        try? fm.createDirectory(at: out, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        let fetched = await shell.run("""
        cd "$HOME/buddy/\(short)/work" || exit 3
        set --
        for p in \(paths.map(BuddyRemoteMachine.quoted).joined(separator: " ")); do if [ -e "$p" ]; then set -- "$@" "$p"; fi; done
        if [ $# -gt 0 ]; then tar -cf - "$@"; fi
        """, output: archive, timeout: timeout)
        let bytes = ((try? fm.attributesOfItem(atPath: archive.path))?[.size] as? NSNumber)?.intValue ?? 0
        if fetched.timedOut { return ["error": "it took longer than the time left", "added": 0, "unchanged": 0, "conflicts": [Any]()] }
        guard bytes > 0 else {
            return fetched.status == 0 || fetched.status == 1 ? ["added": 0, "unchanged": 0, "conflicts": [Any]()] : ["error": String(fetched.err.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)), "added": 0, "unchanged": 0, "conflicts": [Any]()]
        }
        let unpacked = await BuddyProcessRunner.run([env.tar, "-xf", archive.path, "-C", out.path], env: ["PATH": "/usr/bin:/bin", "LC_ALL": "C"], timeout: max(60, timeout))
        var merged = BuddyRemoteMachine.merge(from: out, into: URL(fileURLWithPath: r["projectPath"] as? String ?? ""), wanted: paths)
        if !unpacked.ok { merged["unpackError"] = String(unpacked.err.prefix(200)) }
        return merged
    }
    /// Watches a command until it ends (or its lease is being closed): then what it asked for comes back, and its task hears of it.
    private func watch(_ id: String) {
        guard !watching.contains(id), !closed else { return }
        watching.insert(id)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.watching.remove(id) }
            var silent: Date?
            while !self.closed {
                try? await Task.sleep(nanoseconds: UInt64(max(0.05, self.env.poll) * 1e9))
                guard !self.closed, !self.closing.contains(id), let r = self.lease(id), r["state"] as? String == "active", var run = r["run"] as? [String: Any], run["state"] as? String == "running",
                      let shell = self.shell(r), let short = r["short"] as? String else { return }
                guard let seen = await self.look(shell, short: short, results: run["results"] as? [String] ?? []) else {
                    // No answer for ten minutes: the machine is gone or unreachable; the command is lost, and its task hears of it.
                    let since = silent ?? Date(); silent = since
                    if Date().timeIntervalSince(since) >= max(600, self.env.poll * 3) { run["state"] = "lost"; run["why"] = "unreachable"; run["endedAt"] = self.stamp(self.env.now()); run["delivered"] = false; self.update(id, ["run": run]); self.hooks.runEnded(self.lease(id) ?? r); return }
                    continue
                }
                silent = nil
                if self.closing.contains(id) { return }
                run = self.lease(id)?["run"] as? [String: Any] ?? run
                run["resultFiles"] = seen.files; run["lastLog"] = seen.log; run["lastSeenAt"] = self.stamp(self.env.now())
                guard seen.state != "running" else { self.update(id, ["run": run]); continue }
                if let began = self.date(run["startedAt"]) { run["seconds"] = self.env.now().timeIntervalSince(began) }
                run["state"] = seen.state == "exited" ? "exited" : "lost"; run["exitCode"] = seen.exit ?? NSNull(); run["endedAt"] = self.stamp(self.env.now())
                let results = run["results"] as? [String] ?? []
                if !results.isEmpty { run["broughtBack"] = await self.bringBack(id, shell: shell, paths: results, timeout: 3 * 3600) }
                run["delivered"] = false
                self.update(id, ["run": run])
                if !self.closed, let done = self.lease(id) { self.hooks.runEnded(done) }
                return
            }
        }
    }

    // MARK: what the agent and the person hear

    static func describe(_ r: [String: Any]) -> String {
        "\(r["serviceName"] as? String ?? "the service") \(r["resource"] as? String ?? "(unknown)")"
    }
    /// A command's outcome, for its task: why it ended, what came back, and whether the lease is still held.
    static func runNote(_ r: [String: Any]) -> String {
        let run = r["run"] as? [String: Any] ?? [:], took = (run["seconds"] as? Double).map(BuddyRemoteMachine.duration)
        let host = (r["machine"] as? [String: Any])?["host"] as? String ?? "the machine"
        var text: String
        switch run["state"] as? String ?? "" {
        case "exited": let code = run["exitCode"] as? Int ?? -1; text = code == 0 ? "it finished (exit code 0)" : "it stopped with exit code \(code)"
        case "lost": text = run["why"] as? String == "unreachable" ? "Buddy lost contact with the machine" : "it ended without an exit code (it may have been killed, for example for running out of memory)"
        default:
            switch run["why"] as? String ?? "" {
            case "time": text = "Buddy stopped it at the lease's approved hours (\(BuddyServiceAPI.hours(r["maxHours"] as? Double ?? 0)))"
            case "cancelled": text = "its task was cancelled"
            case "paused": text = "the user paused its task"
            case "restart": text = "Buddy restarted while it ran, so Buddy brought back what it had saved"
            case "failed": text = "its task stopped with an error"
            case "completed": text = "its task finished"
            case "done": text = "its lease was released"
            default: text = "it was stopped"
            }
        }
        var out = "Your command on \(host) ended: \(text)" + (took.map { " after \($0)" } ?? "") + "."
        let results = run["results"] as? [String] ?? []
        if !results.isEmpty { out += " " + BuddyRemoteMachine.brought(run["broughtBack"] as? [String: Any], paths: results) }
        out += " " + leaseLine(r)
        if let log = (run["lastLog"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !log.isEmpty { out += "\nLast lines of its output:\n```\n" + String(log.suffix(1500)) + "\n```" }
        return out
    }
    /// Where a lease stands, in a sentence.
    static func leaseLine(_ r: [String: Any]) -> String {
        let what = describe(r), cost = BuddyServiceAPI.money(r["estimatedCostUSD"] as? Double ?? 0)
        switch r["state"] as? String ?? "" {
        case "active": return "The lease on \(what) is still held (lease \(r["id"] as? String ?? ""), ending by \(r["deadline"] as? String ?? "its deadline") at the latest): download anything else you need with buddy_remote_machine, then release it with buddy_service_api (action release)."
        case "released": return "Buddy tore down \(what) (about \(cost) by your estimate)."
        case "releasing": return "Buddy hasn’t managed to tear down \(what) yet (\(r["lastError"] as? String ?? "no answer")); it keeps trying, and the user can check \(r["serviceName"] as? String ?? "the service") to be sure."
        default: return ""
        }
    }
    /// What the person is told when a lease can't be ended by Buddy (a teardown that keeps failing, or a create Buddy can't name).
    static func problem(_ r: [String: Any]) -> String {
        let service = r["serviceName"] as? String ?? "the service"
        if r["state"] as? String == "unknown" { return "Buddy can’t tell what \(service) created for this task, so it can’t delete it by itself: \(r["problem"] as? String ?? ""). Check \(service) and delete anything you don’t need." }
        return "Buddy couldn’t tear down \(describe(r)) (\(r["lastError"] as? String ?? "no answer")). It keeps trying every few minutes; check \(service) to be sure it is gone."
    }
    /// A lease as the agent sees it: never the key.
    static func view(_ r: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for key in ["id", "service", "serviceName", "resource", "state", "createdAt", "deadline", "maxHours", "estimatedCostUSD", "machine", "attempts", "lastError", "releasedAt", "problem"] { if let v = r[key] { out[key] = v } }
        if let request = (r["teardown"] as? [String: Any]) { out["teardown"] = "\(request["method"] as? String ?? "") \(request["path"] as? String ?? "")" }
        out["approvedUploads"] = (r["uploads"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
        if let run = r["run"] as? [String: Any] { out["run"] = run.filter { ["state", "command", "cwd", "results", "startedAt", "endedAt", "exitCode", "resultFiles", "why"].contains($0.key) } }
        return out
    }
}
