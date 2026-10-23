// run-tests: BuddyWorkerCore.swift BuddyOperationsDB.swift BuddyWorkerProcess.swift BuddyWorkerHost.swift BuddyCodexCoding.swift BuddyPlan.swift BuddySupervisor.swift BuddyMigrations.swift BuddyWorkerClient.swift BuddyAgentMemory.swift BuddyTeamMonitorStore.swift BuddyTeamMonitor.swift BuddyAISettings.swift ConversationService.swift BuddyInboxReview.swift BuddyMailVerification.swift BuddyComputer.swift BuddyTransport.swift BuddyToolInput.swift BuddyConnections.swift BuddyTeam.swift BuddyProjectFiles.swift BuddyDocuments.swift BuddyAgentProposals.swift BuddyCredentials.swift BuddyCommandReview.swift BuddyConnectedServices.swift BuddyLeases.swift -- src:tests/service-api-server.py src:tests/service-ssh.py src:tests/service-coding.py src:tests/browser-fetch-server.py which:python3
import AppKit
import CryptoKit
import Darwin

/// "I want RunPod. Fix what's there to fix, then we'll start it again." (23 Oct: Forge stopped a ten-hour local simulation to move it to
/// RunPod and found Buddy had no way to.) Buddy now works with any web API the person connects, RunPod being the first: connected services
/// (buddy_service_api: the key in the Keychain, never seen by an agent), leases (what a request creates that bills over time, torn down by
/// Buddy itself), and remote machines (buddy_remote_machine: Buddy's own SSH). End to end through the real worker with a RunPod-shaped
/// stand-in service on 127.0.0.1 (tests/service-api-server.py), a stand-in ssh that runs the "machine" in a folder (tests/service-ssh.py),
/// a stand-in Claude coding session and supervisor (tests/service-coding.py) and a stand-in Codex app-server (tests/browser-fetch-server.py).
@main struct ServiceLeasesChecks {
    struct Failed: Error { let message: String }
    static func require(_ value: Bool, _ message: @autoclosure () -> String) throws { if !value { throw Failed(message: message()) } }
    @MainActor static var failures: [String] = []
    @MainActor static func section(_ name: String, _ body: () async throws -> Void) async {
        do { try await body(); print("PASS: " + name) }
        catch let failed as Failed { failures.append(name); fputs("FAILED: \(name): \(failed.message)\n", stderr) }
        catch { failures.append(name); fputs("FAILED: \(name): \(error.localizedDescription)\n", stderr) }
    }
    /// The Keychain in memory.
    final class Saved: BuddySignInStore {
        var items: [String: BuddySignIn] = [:]
        func read(workspace: String, profile: String) -> BuddySignIn? { items[workspace + ":" + profile] }
        func save(workspace: String, profile: String, username: String, password: String) throws { items[workspace + ":" + profile] = BuddySignIn(username: username, password: password) }
        func remove(workspace: String, profile: String) throws { items.removeValue(forKey: workspace + ":" + profile) }
        func has(workspace: String, profile: String) -> Bool { items[workspace + ":" + profile] != nil }
    }
    /// The test's clock: Buddy's leases count their hours on it, and a test moves it forward.
    final class Clock: @unchecked Sendable { var offset: TimeInterval = 0 }
    static func json(_ value: Any) -> String { (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "" }
    static func sha(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    /// A replication runner shaped like Forge's S02c C1 one: one JSON file per replication, written to a temporary file and renamed, skipping
    /// any that exist; a summary at the end. Arguments: how many replications, and (optional) after which one to fail with exit code 1.
    static let runner = """
    import json, os, sys, time
    reps = int(sys.argv[1]); fail = int(sys.argv[2]) if len(sys.argv) > 2 else -1
    os.makedirs('checkpoints/C1/t1', exist_ok=True)
    for rep in range(reps):
        path = 'checkpoints/C1/t1/%d.json' % rep
        if os.path.exists(path): continue
        time.sleep(0.3)
        with open(path + '.tmp', 'w') as f: f.write(json.dumps({'rep': rep, 'estimate': rep * 0.5}))
        os.replace(path + '.tmp', path)
        print('replication %d done' % rep, flush=True)
        if rep == fail: sys.exit(1)
    with open('checkpoints/C1/summary.json', 'w') as f: f.write(json.dumps({'done': reps, 'where': 'remote'}))
    print('all replications done', flush=True)
    """
    static func rep(_ n: Int) -> String { json(["rep": n, "estimate": Double(n) * 0.5]).replacingOccurrences(of: ",", with: ", ").replacingOccurrences(of: ":", with: ": ") }

    @MainActor static func main() async throws {
        let arguments = CommandLine.arguments   // [1] service stand-in, [2] ssh stand-in, [3] coding stand-in, [4] Codex stand-in, [5] python3
        setenv("BUDDY_TEST_LOOPBACK_ONLY", "1", 1)
        guard FileManager.default.isExecutableFile(atPath: arguments[4]) else { fputs("FAILED: the ChatGPT stand-in \(arguments[4]) is not executable\n", stderr); exit(1) }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("buddy-service-leases-" + UUID().uuidString + ".noindex")
        let support = base.appendingPathComponent("Support", isDirectory: true), logs = base.appendingPathComponent("Fixture", isDirectory: true), state = logs.appendingPathComponent("service", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true); try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        // A fake RunPod key and a fake notes key: neither may appear in anything Buddy stores, logs, sends to a model or runs.
        let key = "rpa_FIXTURE7Q2ZK93-not-a-real-key-41xv", notesKey = "notes-FIXTURE-88Lm-not-real"
        let codingLog = logs.appendingPathComponent("coding.jsonl"), sshLog = logs.appendingPathComponent("ssh.jsonl"), codexLog = logs.appendingPathComponent("codex.jsonl"), portFile = logs.appendingPathComponent("port")
        for (name, value) in ["BUDDY_SERVICE_STATE": state.path, "BUDDY_SERVICE_PORT_FILE": portFile.path, "BUDDY_SERVICE_KEY_SHA": sha(key), "BUDDY_NOTES_KEY_SHA": sha(notesKey),
                              "BUDDY_SERVICE_CODING_LOG": codingLog.path, "BUDDY_SSH_LOG": sshLog.path, "BUDDY_FETCH_SERVER_LOG": codexLog.path] { setenv(name, value, 1) }
        let server = Process(); server.executableURL = URL(fileURLWithPath: arguments[5]); server.arguments = [arguments[1]]; try server.run()
        defer { server.terminate(); server.waitUntilExit() }
        var port = ""
        for _ in 0..<200 { if let text = try? String(contentsOf: portFile, encoding: .utf8), !text.isEmpty { port = text; break }; try await Task.sleep(nanoseconds: 50_000_000) }
        guard !port.isEmpty else { fputs("FAILED: the stand-in service did not start\n", stderr); exit(1) }
        let api = "http://127.0.0.1:\(port)/v2", notesAPI = "http://127.0.0.1:\(port)/notes/v1"

        let workspace = UUID().uuidString, chief = UUID().uuidString, forge = UUID().uuidString, codey = UUID().uuidString
        try JSONSerialization.data(withJSONObject: ["conversationWorkspace": workspace, "agents": [
            ["id": chief, "name": "Chief", "role": "Chief of staff", "description": "Supervises", "tools": [String: Bool]()],
            ["id": forge, "name": "Forge", "role": "Engineer", "description": "Codes on Claude", "tools": [String: Bool]()],
            ["id": codey, "name": "Codey", "role": "Engineer", "description": "Codes on ChatGPT", "tools": [String: Bool]()]]]).write(to: support.appendingPathComponent("workspace.json"))
        let policy: [String: Any] = ["enabled": false, "supervisorId": chief, "supervisorChosen": true, "agents": [String: Any](), "intervalMinutes": 15, "dailyLimitUSD": 2.0, "revision": 1]
        try JSONSerialization.data(withJSONObject: ["version": 1, "settings": [workspace: policy], "checks": [Any](), "updates": [Any]()]).write(to: support.appendingPathComponent("team-monitor.json"))
        let models = BuddyAgentModels(support: support)
        try models.set(workspace: workspace, agent: chief, selection: .init(provider: "claude", model: "claude-fixture"))
        try models.set(workspace: workspace, agent: forge, selection: .init(provider: "claude", model: "claude-fixture"))
        try models.set(workspace: workspace, agent: codey, selection: .init(provider: "chatgpt", model: "fixture"))
        let saved = Saved(), clock = Clock()
        let env = BuddyRemoteEnvironment(ssh: [arguments[5], arguments[2], "--state", state.path, "--log", sshLog.path], tar: "/usr/bin/tar", keygen: "/usr/bin/ssh-keygen", now: { Date().addingTimeInterval(clock.offset) }, poll: 0.1, settle: 0, backoff: 0.05)
        func makeHost() -> BuddyWorkerHost {
            BuddyWorkerHost(support: support, executable: URL(fileURLWithPath: arguments[4]),
                            makeCoding: { BuddyWorkerProcess(resource: URL(fileURLWithPath: arguments[3]), runtime: URL(fileURLWithPath: arguments[5])) },
                            makeClaude: { BuddyWorkerProcess(resource: URL(fileURLWithPath: arguments[3]), runtime: URL(fileURLWithPath: arguments[5])) },
                            keyReader: { _ in "inert-fixture-key" }, credentials: saved, remote: env)
        }
        var host = makeHost()
        host.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer { host.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)) }

        func worker(_ payload: [String: Any]) async throws -> [String: Any] { try await BuddyWorkerClient.call(support: support, payload: payload.merging(["workspace": workspace]) { old, _ in old }) }
        func page(_ payload: [String: Any]) async throws -> [String: Any] { try await BuddyServiceBox.handle(payload, workspace: workspace, support: support, store: saved) }
        func coding(_ calls: [[Any]], after: [[Any]] = [], as agent: String = forge, request: String) async throws -> String {
            let goal = "Run the S02c C1 replications. CALLS:" + json(calls) + (after.isEmpty ? "" : " AFTER:" + json(after))
            let reply = try await worker(["operation": "coding", "agentId": agent, "requestId": request, "arguments": ["action": "start", "title": "C1 replications", "goal": goal]])
            return (reply["task"] as? [String: Any])?["id"] as? String ?? ""
        }
        func detail(_ id: String) async throws -> [String: Any] { (try await worker(["operation": "detail", "taskId": id]))["task"] as? [String: Any] ?? [:] }
        func poll(_ id: String, _ label: String, seconds: Double = 45, _ done: ([String: Any]) -> Bool) async throws -> [String: Any] {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline { let value = try await detail(id); if done(value) { return value }; try await Task.sleep(nanoseconds: 50_000_000) }
            let last = try await detail(id)
            throw Failed(message: "\(label) (last seen: \(last["status"] ?? "") / \(last["stopCause"] ?? "-") / \(last["progress"] ?? ""))")
        }
        func status() async throws -> [String: Any] { try await worker(["operation": "status"]) }
        func decisions(_ id: String) async throws -> [[String: Any]] { ((try await status())["decisions"] as? [[String: Any]] ?? []).filter { $0["taskId"] as? String == id } }
        func lines(_ url: URL) -> [[String: Any]] { ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } }
        func requests() -> [[String: Any]] { lines(state.appendingPathComponent("requests.jsonl")) }
        func requests(_ method: String, _ prefix: String) -> [[String: Any]] { requests().filter { $0["method"] as? String == method && ($0["path"] as? String ?? "").hasPrefix(prefix) } }
        func codingLines(_ kind: String) -> [[String: Any]] { lines(codingLog).filter { $0["kind"] as? String == kind }.compactMap { $0["value"] as? [String: Any] } }
        func results(_ tool: String) -> [[String: Any]] { codingLines("result").filter { $0["tool"] as? String == tool }.compactMap { $0["result"] as? [String: Any] } }
        func pending(_ id: String, kind: String) async throws -> [String: Any] {
            let job = try await poll(id, "the task waits for a \(kind) review") { ($0["reviews"] as? [[String: Any]] ?? []).contains { $0["status"] as? String == "pending" && $0["kind"] as? String == kind } }
            return (job["reviews"] as? [[String: Any]] ?? []).last { $0["status"] as? String == "pending" && $0["kind"] as? String == kind } ?? [:]
        }
        func answer(_ id: String, _ review: [String: Any], _ accept: Bool) async throws { _ = try await worker(["operation": "review", "taskId": id, "id": review["id"] ?? "", "accept": accept, "cancel": !accept]) }
        func project(_ id: String) -> URL { support.appendingPathComponent("Worker/Tasks/\(id)/Files", isDirectory: true) }
        func leasesFile() -> [[String: Any]] { (((try? Data(contentsOf: support.appendingPathComponent("Worker/Leases/leases.json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?["leases"] as? [[String: Any]]) ?? [] }
        func leases(_ id: String) -> [[String: Any]] { leasesFile().filter { $0["taskId"] as? String == id } }
        func pod(_ podID: String) -> [String: Any] { ((try? Data(contentsOf: state.appendingPathComponent("pods/\(podID).json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:] }
        func prompts(_ id: String) -> [String] { codingLines("start").filter { ($0["cwd"] as? String ?? "") == project(id).path }.compactMap { $0["prompt"] as? String } }
        func laneOnline() async throws -> Bool { ((try await status())["supervisorLane"] as? [String: Any])?["online"] as? Bool == true }

        // The project Forge's C1 work is in, written by the stand-in session itself: the runner, two replications already done here, and an
        // older summary that the run will rewrite.
        let setup: [[Any]] = [["$write", ["path": "stages/S02c_review/run_c1.py", "content": runner]],
                               ["$write", ["path": "stages/S02c_review/checkpoints/C1/t1/0.json", "content": rep(0)]],
                               ["$write", ["path": "stages/S02c_review/checkpoints/C1/t1/1.json", "content": rep(1)]],
                               ["$write", ["path": "stages/S02c_review/checkpoints/C1/summary.json", "content": "{\"done\": 2, \"where\": \"local\"}"]],
                               ["$write", ["path": "extra/params.json", "content": "{\"truths\": [\"t1\"]}"]]]
        // [5] Buddy's public key, [6] the pod's create request with its lease (approved on the card), [7] a GET until it runs.
        func create(maxHours: Double = 2) -> [[Any]] {
            [["buddy_remote_machine", ["operation": "publicKey"]],
             ["buddy_service_api", ["service": "RunPod", "method": "POST", "path": "/pods", "reason": "Run the 800 C1 replications on 32 vCPUs instead of this Mac.",
                                    "body": ["name": "c1-replications", "image": "runpod/base:1.4.0-ubuntu2204", "cloud": "SECURE", "cpu": ["id": "cpu3c-2-4", "vcpuCount": 32], "disk": 20, "ports": ["22/tcp"], "env": ["PUBLIC_KEY": "$R5.publicKey"], "startSsh": true],
                                    "costPerHour": 1.28, "maxHours": maxHours, "lease": ["resource": "/id", "teardown": ["method": "DELETE", "path": "/pods/{id}"]], "uploads": ["stages/S02c_review"]]],
             ["buddy_service_api", ["service": "RunPod", "method": "GET", "path": "/pods/$R6.body.id"], ["until": ["path": "body.status", "equals": "RUNNING"]]]]
        }
        let machine: [String: Any] = ["lease": "$R6.lease.id", "host": "$R7.body.ssh.direct.host", "port": "$R7.body.ssh.direct.port"]
        func machineCall(_ extra: [String: Any]) -> [Any] { ["buddy_remote_machine", machine.merging(extra) { $1 }] }
        let upload = machineCall(["operation": "upload", "paths": ["stages/S02c_review"]])
        func run(_ command: String) -> [Any] { machineCall(["operation": "run", "command": command, "cwd": "stages/S02c_review", "results": ["stages/S02c_review/checkpoints"]]) }

        // MARK: connecting a service

        var connectTask = ""
        await section("an agent asks for a service that isn't connected: the chat asks the user to connect it (address, how the key is sent, can it charge money, the key); once connected the task continues and its GET goes ahead with the key, which the agent never sees") {
            connectTask = try await coding([["buddy_service_api", ["service": "RunPod", "method": "GET", "path": "/catalog/cpus", "query": ["include": "AVAILABILITY", "product": "POD"], "baseUrl": api, "reason": "See CPU prices for the C1 run."]]],
                                           after: [["buddy_service_api", ["service": "RunPod", "method": "GET", "path": "/catalog/cpus", "query": ["include": "AVAILABILITY", "product": "POD"]]]], request: "connect")
            let waiting = try await poll(connectTask, "the task waits for the user to connect RunPod") { $0["status"] as? String == "waiting_user" }
            let point = waiting["checkpoint"] as? [String: Any] ?? [:]
            try require(point["need"] as? String == "credential" && point["profile"] as? String == "service:runpod" && point["secret"] as? String == "service" && point["service"] as? String == "RunPod" && point["routedTo"] as? String == "user"
                        && point["baseUrl"] as? String == api, "a credential step for RunPod, the address the agent suggested, for the user: \(point)")
            let asked = ((try await status())["signinRequests"] as? [[String: Any]] ?? []).filter { $0["taskId"] as? String == connectTask }
            try require(asked.count == 1 && asked[0]["kind"] as? String == "credential" && asked[0]["secret"] as? String == "service" && asked[0]["service"] as? String == "RunPod" && asked[0]["baseUrl"] as? String == api,
                        "the chat card asks to connect RunPod: \(asked)")
            let cards = try await decisions(connectTask)
            try require(cards.count == 1 && cards[0]["title"] as? String == "Connect RunPod" && cards[0]["audience"] as? String == "user", "one Needs you item, Connect RunPod: \(cards)")
            try require(requests().isEmpty, "nothing reached the service yet")
            // An address that isn't https (or this Mac's stand-in) is refused; a charge choice is required.
            let refused = await { do { _ = try await page(["action": "provideService", "name": "RunPod", "baseUrl": "http://api.example.com/v2", "charges": true, "key": key]); return "" } catch { return error.localizedDescription } }()
            try require(refused.contains("https"), "only https: \(refused)")
            let noChoice = await { do { _ = try await page(["action": "provideService", "name": "RunPod", "baseUrl": api, "key": key]); return "" } catch { return error.localizedDescription } }()
            try require(noChoice.contains("charge"), "the user says whether it can charge money: \(noChoice)")
            let connected = try await page(["action": "provideService", "name": "RunPod", "baseUrl": api, "header": "", "charges": true, "key": "  " + key + "\n", "taskId": connectTask])
            try require(connected["saved"] as? Bool == true && connected["resumed"] as? Bool == true && !json(connected).contains(key), "connected, the task resumed, and the reply never carries the key: \(connected)")
            try require(saved.read(workspace: workspace, profile: "service:runpod")?.password == key, "the key, trimmed, is in the Keychain as service:runpod")
            let registry = (try? String(contentsOf: support.appendingPathComponent("connected-services.json"), encoding: .utf8)) ?? ""
            try require(registry.contains("RunPod") && registry.contains("\"charges\":true") && !registry.contains(key), "the service's address and choices are saved without the key: \(registry)")
            let done = try await poll(connectTask, "the task finishes after the GET") { $0["status"] as? String == "completed" }
            try require(prompts(connectTask).last?.contains("[Buddy] The user connected RunPod") == true, "the resumed attempt is told RunPod is connected: \(prompts(connectTask).last?.suffix(400) ?? "")")
            let got = results("buddy_service_api").last ?? [:], cpus = ((got["body"] as? [String: Any])?["cpus"] as? [[String: Any]]) ?? []
            try require(got["status"] as? Int == 200 && cpus.count == 2 && (cpus.first?["price"] as? [String: Any])?["securePerVcpu"] as? Double == 0.04, "the agent gets the catalog: \(got)")
            let headers = got["headers"] as? [String: Any] ?? [:]
            try require(!headers.keys.contains { ["authorization", "set-cookie"].contains($0.lowercased()) }, "no auth or cookie header comes back: \(headers.keys)")
            let sent = requests("GET", "/v2/catalog/cpus")
            try require(sent.count == 1 && sent[0]["auth"] as? Bool == true && (sent[0]["query"] as? [String: Any])?["product"] as? [String] == ["POD"], "one GET, with the key in its Authorization header: \(sent)")
            try require((done["reviews"] as? [[String: Any]] ?? []).isEmpty, "reading needs nobody's approval")
            let listed = try await page(["action": "services"])
            try require((listed["services"] as? [[String: Any]] ?? []).contains { $0["id"] as? String == "runpod" && $0["saved"] as? Bool == true && $0["sends"] as? String == "Authorization: Bearer …" } && !json(listed).contains(key), "Settings lists it without the key: \(listed)")
        }

        // MARK: a write to a service that can charge money

        await section("creating a pod is the user's: one card with the exact request, the reason, the cost estimate, the cleanup and the uploads; nothing is created before the OK, and declining creates nothing") {
            let id = try await coding(setup + Array(create().prefix(2)), request: "decline")
            let review = try await pending(id, kind: "service")
            try require(review["route"] as? String == "user", "a change on a service that can charge money goes to the user, never the supervisor: \(review["route"] ?? "-")")
            let r = review["request"] as? [String: Any] ?? [:], cost = r["cost"] as? [String: Any] ?? [:], lease = r["lease"] as? [String: Any] ?? [:], uploads = r["uploads"] as? [[String: Any]] ?? []
            try require(r["method"] as? String == "POST" && r["path"] as? String == "/pods" && r["service"] as? String == "RunPod" && r["charges"] as? Bool == true && r["agent"] as? String == "Forge"
                        && (r["body"] as? String ?? "").contains("\"vcpuCount\" : 32") && (r["reason"] as? String ?? "").contains("800 C1"), "the exact request and the reason: \(r)")
            try require(cost["perHour"] as? Double == 1.28 && cost["maxHours"] as? Double == 2 && cost["maxCostUSD"] as? Double == 2.56, "the cost estimate: $1.28 an hour for 2 hours, at most $2.56: \(cost)")
            try require(lease["teardown"] as? String == "DELETE /pods/{id}" && lease["maxHours"] as? Double == 2, "the cleanup: \(lease)")
            try require(uploads.count == 1 && uploads[0]["path"] as? String == "stages/S02c_review" && uploads[0]["files"] as? Int == 4, "what will be uploaded: \(uploads)")
            let cards = try await decisions(id)
            try require(cards.contains { $0["title"] as? String == "Allow a request to RunPod? At most $2.56" && $0["audience"] as? String == "user" && ($0["question"] as? String ?? "").contains("POST /pods") }, "Needs you says it, with the most it can cost: \(cards)")
            try require(requests("POST", "/v2/pods").isEmpty, "nothing was created before the OK")
            try await answer(id, review, false)
            _ = try await poll(id, "the task carries on after the decline") { $0["status"] as? String == "completed" }
            let told = results("buddy_service_api").last?["error"] as? String ?? ""
            try require(told.contains("wasn’t approved") && told.contains("nothing was sent"), "the agent is told plainly: \(told)")
            try require(requests("POST", "/v2/pods").isEmpty && leases(id).isEmpty, "declined: nothing was created and no lease was recorded")
        }

        var mainTask = "", mainPod = ""
        await section("approved: the pod is created once, Buddy records its lease, the agent uploads (the card's paths go ahead, another path asks the user), runs the C1 command, ends its attempt; Buddy watches, brings new replication files back without overwriting, resumes the agent with what came back, and tears the pod down when the agent releases it") {
            mainTask = try await coding(setup + create() + [upload, machineCall(["operation": "upload", "paths": ["extra/params.json"], "reason": "The run's parameters."]), run("python3 run_c1.py 6"), ["$finish", "The C1 run is going on RunPod; I'll continue when it's back."]],
                                        after: [["buddy_service_api", ["action": "leases"]], ["buddy_service_api", ["action": "release", "lease_id": "$R0.leases.0.id"]], ["$finish", "C1 results are back and the pod is gone."]], request: "main")
            try await answer(mainTask, try await pending(mainTask, kind: "service"), true)
            // The second upload is not on the lease's card: files leaving the Mac, so the user is asked.
            let extra = try await pending(mainTask, kind: "upload")
            let shown = extra["upload"] as? [String: Any] ?? [:]
            try require(extra["route"] as? String == "user" && (shown["files"] as? [[String: Any]])?.first?["path"] as? String == "extra/params.json" && shown["host"] as? String == "127.0.0.1", "an upload the card didn't list asks the user: \(extra)")
            let posts = requests("POST", "/v2/pods")
            try require(posts.count == 1 && posts[0]["auth"] as? Bool == true, "the pod was created once, after the OK: \(posts.count)")
            let body = posts[0]["body"] as? [String: Any] ?? [:], pub = (try? String(contentsOf: support.appendingPathComponent("Worker/Leases/ssh/id_ed25519.pub"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "-"
            try require((body["env"] as? [String: Any])?["PUBLIC_KEY"] as? String == pub && pub.hasPrefix("ssh-ed25519 "), "the create request carries Buddy's public key, as the agent put it there: \(body)")
            let privateKey = support.appendingPathComponent("Worker/Leases/ssh/id_ed25519")
            let mode = ((try? FileManager.default.attributesOfItem(atPath: privateKey.path))?[.posixPermissions] as? NSNumber)?.intValue ?? 0
            try require(mode == 0o600, "Buddy's private key is 0600: \(String(mode, radix: 8))")
            try require(!lines(codingLog).contains { json($0).contains("PRIVATE KEY") }, "the agent never got the private key")
            let lease = leases(mainTask).first ?? [:]
            mainPod = lease["resource"] as? String ?? ""
            try require(lease["state"] as? String == "active" && mainPod.hasPrefix("pod") && lease["service"] as? String == "runpod" && lease["approvedBy"] as? String == "user" && (lease["teardown"] as? [String: Any])?["path"] as? String == "/pods/{id}"
                        && lease["deadline"] != nil && (lease["observed"] as? [String] ?? []).contains("127.0.0.1"), "the lease is recorded, with what was created, its teardown, its deadline and the address RunPod gave: \(lease)")
            try await answer(mainTask, extra, true)
            let done = try await poll(mainTask, "the task finishes after its results came back and it released the pod", seconds: 60) { $0["status"] as? String == "completed" }
            // What came back: new replications added, the ones already here left, the changed summary kept with the machine's beside it.
            let checkpoints = project(mainTask).appendingPathComponent("stages/S02c_review/checkpoints/C1")
            let files = (try? FileManager.default.contentsOfDirectory(atPath: checkpoints.appendingPathComponent("t1").path))?.sorted() ?? []
            try require(files == ["0.json", "1.json", "2.json", "3.json", "4.json", "5.json"], "replications 2 to 5 were added: \(files)")
            try require((try? String(contentsOf: checkpoints.appendingPathComponent("t1/0.json"), encoding: .utf8)) == rep(0), "a replication already here is left as it was")
            try require((try? String(contentsOf: checkpoints.appendingPathComponent("summary.json"), encoding: .utf8))?.contains("local") == true
                        && (try? String(contentsOf: checkpoints.appendingPathComponent("summary (remote).json"), encoding: .utf8))?.contains("remote") == true, "the local summary is kept and the machine's saved beside it")
            let note = prompts(mainTask).last ?? ""
            try require(note.contains("[Buddy] Your command on 127.0.0.1 ended: it finished (exit code 0)") && note.contains("4 new files added, 2 already here and the same") && note.contains("summary (remote).json")
                        && note.contains("still held") && note.contains("all replications done"), "the agent is resumed with what came back: \(note.suffix(900))")
            let released = results("buddy_service_api").last ?? [:]
            try require(released["state"] as? String == "released" && (released["note"] as? String ?? "").contains("tore down"), "release tears it down: \(released)")
            try require(requests("DELETE", "/v2/pods/\(mainPod)").count == 1 && pod(mainPod)["status"] as? String == "TERMINATED", "one DELETE, and the pod is terminated")
            try require(leases(mainTask).first?["state"] as? String == "released" && (done["leases"] as? [[String: Any]])?.first?["state"] as? String == "released", "the lease is released, on the task too: \(done["leases"] ?? "-")")
            // Only Buddy ran ssh: with its own key, a known_hosts of the lease's own, and no secret in any argument.
            let calls = lines(sshLog).compactMap { $0["argv"] as? [String] }
            try require(!calls.isEmpty && calls.allSatisfy { $0.contains(privateKey.path) && $0.contains { $0.hasPrefix("UserKnownHostsFile=") && $0.contains("Worker/Leases/Leases/") } }, "ssh ran with Buddy's key and the lease's own known_hosts")
            let environments = Set(lines(sshLog).compactMap { $0["env"] as? [String] }.flatMap { $0 }.filter { !["__CF_USER_TEXT_ENCODING", "__CFBundleIdentifier"].contains($0) })
            try require(environments.isSubset(of: ["PATH", "HOME", "LC_ALL", "LC_CTYPE"]), "ssh gets no environment of Buddy's beyond PATH and HOME: \(environments.sorted())")
            let readings = results("buddy_remote_machine")
            try require(readings.contains { ($0["uploaded"] as? [[String: Any]])?.first?["path"] as? String == "stages/S02c_review" } && readings.contains { $0["state"] as? String == "running" && $0["command"] as? String == "python3 run_c1.py 6" },
                        "the agent uploaded and started the command: \(readings.map { $0.keys.sorted() })")
        }

        // MARK: Buddy ends leases by itself

        func startLong(_ request: String, maxHours: Double = 2, after: [[Any]] = [["$finish", "Back."]]) async throws -> (task: String, pod: String) {
            let id = try await coding(setup + create(maxHours: maxHours) + [upload, run("python3 run_c1.py 100000"), ["$finish", "Started; I'll continue when it's back."]], after: after, request: request)
            try await answer(id, try await pending(id, kind: "service"), true)
            let waiting = try await poll(id, "the task waits for its command") { $0["status"] as? String == "paused" && $0["blockedBy"] as? String == "remote" }
            try require((waiting["progress"] as? String ?? "").hasPrefix("Running on 127.0.0.1"), "it says where it runs: \(waiting["progress"] ?? "")")
            let none = try await decisions(id)
            try require(none.isEmpty, "waiting for its own command needs nobody")
            let podID = leases(id).first?["resource"] as? String ?? ""
            // A few replications are done on the machine.
            for _ in 0..<100 { if ((try? FileManager.default.contentsOfDirectory(atPath: state.appendingPathComponent("pods/\(podID)/root/buddy").path)) ?? []).count > 0,
                                  ((try? FileManager.default.subpathsOfDirectory(atPath: state.appendingPathComponent("pods/\(podID)/root").path)) ?? []).filter({ $0.hasSuffix(".json") && $0.contains("/t1/") }).count >= 4 { break }
                               try await Task.sleep(nanoseconds: 100_000_000) }
            return (id, podID)
        }

        await section("the lease's approved hours: Buddy stops the command a little before them, brings back what it saved, tears the pod down, and resumes the agent saying so") {
            let (id, podID) = try await startLong("time", maxHours: 1)
            clock.offset += 3600
            let done = try await poll(id, "the task continues after the time limit", seconds: 60) { $0["status"] as? String == "completed" }
            try require(requests("DELETE", "/v2/pods/\(podID)").count == 1 && pod(podID)["status"] as? String == "TERMINATED", "the pod was torn down at its hours")
            let lease = leases(id).first ?? [:]
            try require(lease["state"] as? String == "released" && lease["why"] as? String == "time", "the lease ended for time: \(lease["state"] ?? "") \(lease["why"] ?? "")")
            let note = prompts(id).last ?? ""
            try require(note.contains("Buddy stopped it at the lease's approved hours (1 hour)") && note.contains("new files added") && note.contains("Buddy tore down RunPod \(podID)"), "the agent hears it: \(note.suffix(700))")
            let back = ((try? FileManager.default.contentsOfDirectory(atPath: project(id).appendingPathComponent("stages/S02c_review/checkpoints/C1/t1").path)) ?? []).count
            try require(back >= 4, "what the machine saved came back: \(back) files")
            try require(done["status"] as? String == "completed", "done")
            clock.offset = 0
        }
        await section("a failure: the command fails, its results still come back, and when the task fails for good the lease is torn down") {
            let id = try await coding(setup + create() + [upload, run("python3 run_c1.py 6 3"), ["$finish", "Started."]], after: [["$fail", "invalid_request_error: the C1 run stopped with an error"]], request: "failure")
            try await answer(id, try await pending(id, kind: "service"), true)
            let failed = try await poll(id, "the task fails for good", seconds: 60) { $0["status"] as? String == "failed" }
            try require(failed["stopCause"] as? String == "task.invalid", "a failure Buddy doesn't retry: \(failed["stopCause"] ?? "")")
            let note = prompts(id).last ?? ""
            try require(note.contains("it stopped with exit code 1") && note.contains("2 new files added"), "the agent heard the failure and what came back: \(note.suffix(600))")
            let lease = try await { () async throws -> [String: Any] in for _ in 0..<200 { if let l = leases(id).first, l["state"] as? String == "released" { return l }; try await Task.sleep(nanoseconds: 50_000_000) }; return leases(id).first ?? [:] }()
            let podID = lease["resource"] as? String ?? ""
            try require(lease["state"] as? String == "released" && lease["why"] as? String == "failed" && requests("DELETE", "/v2/pods/\(podID)").count == 1, "torn down because the task failed: \(lease["state"] ?? "") \(lease["why"] ?? "")")
        }
        await section("cancelling the task stops the command, brings back what exists and tears the pod down; a teardown that keeps failing is retried and the user is told plainly until it works") {
            let (id, podID) = try await startLong("cancel")
            try JSONSerialization.data(withJSONObject: ["deleteFails": 5]).write(to: state.appendingPathComponent("control.json"))
            _ = try await worker(["operation": "cancel", "taskId": id])
            var told: [[String: Any]] = []
            for _ in 0..<200 { told = try await decisions(id).filter { $0["kind"] as? String == "lease" }; if !told.isEmpty { break }; try await Task.sleep(nanoseconds: 25_000_000) }
            try require(told.count == 1 && (told[0]["title"] as? String ?? "").hasPrefix("Check RunPod") && (told[0]["question"] as? String ?? "").contains("couldn’t tear down RunPod \(podID)") && told[0]["audience"] as? String == "user",
                        "the user is told plainly while it keeps failing: \(told)")
            let lease = try await { () async throws -> [String: Any] in for _ in 0..<400 { if let l = leases(id).first, l["state"] as? String == "released" { return l }; try await Task.sleep(nanoseconds: 50_000_000) }; return leases(id).first ?? [:] }()
            try require(lease["state"] as? String == "released" && lease["why"] as? String == "cancelled" && (lease["attempts"] as? Int ?? 0) >= 5 && pod(podID)["status"] as? String == "TERMINATED", "it kept trying until the pod was gone: \(lease["attempts"] ?? 0)")
            try require(requests("DELETE", "/v2/pods/\(podID)").count == 6, "six tries, the last one worked: \(requests("DELETE", "/v2/pods/\(podID)").count)")
            for _ in 0..<100 { if try await decisions(id).filter({ $0["kind"] as? String == "lease" }).isEmpty { break }; try await Task.sleep(nanoseconds: 50_000_000) }
            let left = try await decisions(id).filter { $0["kind"] as? String == "lease" }
            try require(left.isEmpty, "the Needs you item goes away once it is gone")
            let back = ((try? FileManager.default.contentsOfDirectory(atPath: project(id).appendingPathComponent("stages/S02c_review/checkpoints/C1/t1").path)) ?? []).count
            let after = try await detail(id)
            try require(back >= 4 && after["status"] as? String == "cancelled", "what existed came back, and the task stays cancelled: \(back)")
        }
        await section("a worker restart: the next worker finds the recorded lease, brings back what the machine saved, tears the pod down and resumes the task saying so") {
            let (id, podID) = try await startLong("restart")
            host.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
            try require(pod(podID)["status"] as? String == "RUNNING", "closing Buddy leaves the pod as recorded")
            host = makeHost()
            host.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
            _ = try await poll(id, "the task continues after the restart", seconds: 60) { $0["status"] as? String == "completed" }
            try require(requests("DELETE", "/v2/pods/\(podID)").count == 1 && pod(podID)["status"] as? String == "TERMINATED", "the new worker tore the pod down")
            try require(leases(id).first?["why"] as? String == "restart", "for the restart")
            let note = prompts(id).last ?? ""
            try require(note.contains("Buddy restarted while it ran, so Buddy brought back what it had saved") && note.contains("new files added"), "the agent hears it: \(note.suffix(600))")
        }
        await section("a refusal by the service (402, not enough balance) creates nothing: the agent gets RunPod's own answer, the task says it plainly, and the lease records nothing to tear down") {
            try JSONSerialization.data(withJSONObject: ["create": 402]).write(to: state.appendingPathComponent("control.json"))
            let id = try await coding(setup + Array(create().prefix(2)), request: "balance")
            try await answer(id, try await pending(id, kind: "service"), true)
            let done = try await poll(id, "the task carries on after the refusal") { $0["status"] as? String == "completed" }
            let got = results("buddy_service_api").filter { $0["status"] as? Int == 402 }.last ?? [:]
            try require(((got["body"] as? [String: Any])?["detail"] as? String ?? "").contains("Insufficient balance"), "the agent gets the 402 and its detail: \(got)")
            let lease = leases(id).first ?? [:], shown = (done["leases"] as? [[String: Any]])?.first ?? [:]
            try require(lease["state"] as? String == "void", "nothing to tear down: \(lease["state"] ?? "-")")
            try require((shown["problem"] as? String ?? "").contains("RunPod refused it (HTTP 402: Insufficient balance to start this pod.), so nothing was created"), "the task's details say it plainly: \(shown)")
            let review = (done["reviews"] as? [[String: Any]] ?? []).last ?? [:]
            try require(review["status"] as? String == "not_sent" && (review["receipt"] as? [String: Any])?["status"] as? Int == 402, "the review's receipt says it was refused: \(review["status"] ?? "")")
        }

        // MARK: a service that can't charge money

        await section("a change on a service the user said can't charge money goes to the supervisor (Chief), who approves it; the user is never asked") {
            _ = try await page(["action": "provideService", "name": "Notes", "baseUrl": notesAPI, "header": "X-API-Key", "scheme": "", "charges": false, "key": notesKey])
            for _ in 0..<300 { if try await laneOnline() { break }; try await Task.sleep(nanoseconds: 100_000_000) }
            let online = try await laneOnline()
            try require(online, "the supervisor lane is online")
            let id = try await coding([["buddy_service_api", ["service": "Notes", "method": "POST", "path": "/items", "body": ["text": "C1 is on RunPod"], "reason": "Leave a note for the team."]]], request: "notes")
            let done = try await poll(id, "the note is posted after Chief's review", seconds: 60) { $0["status"] as? String == "completed" }
            let review = (done["reviews"] as? [[String: Any]] ?? []).last ?? [:]
            try require(review["route"] as? String == "supervisor" && review["answeredBy"] as? String == "supervisor" && review["answeredByName"] as? String == "Chief" && review["status"] as? String == "completed", "Chief approved it: \(review)")
            let posted = requests("POST", "/notes/v1/items")
            try require(posted.count == 1 && posted[0]["auth"] as? Bool == true && (posted[0]["headerNames"] as? [String] ?? []).contains { $0.lowercased() == "x-api-key" }, "sent with the key in the header the user chose: \(posted)")
            let shown = codingLines("supervisor").flatMap { $0["items"] as? [[String: Any]] ?? [] }.first { $0["serviceRequest"] != nil }?["serviceRequest"] as? [String: Any] ?? [:]
            try require(shown["method"] as? String == "POST" && shown["path"] as? String == "/items" && shown["service"] as? String == "Notes", "Chief saw the exact request: \(shown)")
            let all = try await worker(["operation": "status"])
            try require(!((all["decisions"] as? [[String: Any]] ?? []).contains { $0["taskId"] as? String == id && $0["audience"] as? String == "user" }), "nothing went to the user")
        }

        // MARK: Codex

        await section("a Codex coding session has the same tools and reads a connected service the same way") {
            let id = try await coding([["buddy_service_api", ["service": "RunPod", "method": "GET", "path": "/catalog/cpus"]]], as: codey, request: "codex")
            _ = try await poll(id, "the Codex task finishes") { ["completed", "failed"].contains($0["status"] as? String ?? "") }
            let start = lines(codexLog).first { $0["kind"] as? String == "start" && ($0["value"] as? [String: Any])?["coding"] as? Bool == true }?["value"] as? [String: Any] ?? [:]
            let tools = start["tools"] as? [String] ?? []
            try require(tools.contains("buddy_service_api") && tools.contains("buddy_remote_machine"), "the Codex thread has the tools: \(tools)")
            let got = lines(codexLog).filter { $0["kind"] as? String == "result" }.compactMap { $0["value"] as? [String: Any] }.last { $0["tool"] as? String == "buddy_service_api" } ?? [:]
            try require(got["success"] as? Bool == true && (got["text"] as? String ?? "").contains("cpu3c-2-4"), "it read the catalog: \(got)")
            try require((start["instructions"] as? String ?? "").contains("buddy_service_api"), "its brief explains it")
        }

        // MARK: the key never leaks

        await section("the keys appear in no file Buddy wrote, no task record, nothing an agent received, no ssh argument and no request the services logged") {
            let found = FileManager.default.enumerator(at: support, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }.filter { url in
                (try? Data(contentsOf: url)).map { let text = String(decoding: $0, as: UTF8.self); return text.contains(key) || text.contains(notesKey) } ?? false } ?? []
            try require(found.isEmpty, "no file Buddy wrote holds a key: \(found.map(\.path))")
            for (name, url) in [("the coding sessions and supervisor", codingLog), ("ssh", sshLog), ("Codex", codexLog), ("the services", state.appendingPathComponent("requests.jsonl"))] {
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                try require(!text.contains(key) && !text.contains(notesKey), "\(name) never saw a key")
            }
            for id in [connectTask, mainTask] { try require(!json(try await detail(id)).contains(key), "the task record holds no key") }
        }

        if !failures.isEmpty { fputs("FAILED: \(failures.count) service and lease check(s) failed\n", stderr); exit(1) }
    }
}
