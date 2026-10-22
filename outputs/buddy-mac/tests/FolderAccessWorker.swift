// run-tests: BuddyWorkerCore.swift BuddyOperationsDB.swift BuddyWorkerProcess.swift BuddyWorkerHost.swift BuddyCodexCoding.swift BuddyPlan.swift BuddySupervisor.swift BuddyMigrations.swift BuddyWorkerClient.swift BuddyAgentMemory.swift BuddyTeamMonitorStore.swift BuddyTeamMonitor.swift BuddyAISettings.swift ConversationService.swift BuddyInboxReview.swift BuddyMailVerification.swift BuddyComputer.swift BuddyTransport.swift BuddyToolInput.swift BuddyConnections.swift BuddyTeam.swift BuddyProjectFiles.swift BuddyDocuments.swift BuddyAgentProposals.swift BuddyCredentials.swift BuddyCommandReview.swift -- src:tests/folder-access-server.py
import AppKit

/// A background task whose agent names a file on the Mac that isn't open to agents yet: Buddy asks the person once (a request with the
/// task's name on it), the task waits for them like a checkpoint, and their click, read from Buddy's own record, resumes it with a plain
/// note: allowed, it reads the file; declined, it is told so and finishes without it, and a later ask for that place is refused without a
/// new card. An agent can't resume or answer anything. End to end through the real worker with a stand-in ChatGPT
/// (tests/folder-access-server.py) and a fake home folder.
@main struct FolderAccessWorker {
    struct Failed: Error { let message: String }
    static func require(_ value: Bool, _ message: @autoclosure () -> String) throws { if !value { throw Failed(message: message()) } }
    @MainActor static var failures: [String] = []
    @MainActor static func section(_ name: String, _ body: () async throws -> Void) async {
        do { try await body(); print("PASS: " + name) }
        catch let failed as Failed { failures.append(name); fputs("FAILED: \(name): \(failed.message)\n", stderr) }
        catch { failures.append(name); fputs("FAILED: \(name): \(error.localizedDescription)\n", stderr) }
    }
    static func json(_ value: Any) -> String { (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "" }

    @MainActor static func main() async throws {
        let arguments = CommandLine.arguments   // [1] the ChatGPT stand-in
        // A stand-in that can't be run is passed over for the Codex installed on this Mac, signed in to the person's ChatGPT: never that.
        guard FileManager.default.isExecutableFile(atPath: arguments[1]) else { fputs("FAILED: the ChatGPT stand-in \(arguments[1]) is not executable\n", stderr); exit(1) }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("buddy-folder-access-worker-" + UUID().uuidString + ".noindex")
        let support = base.appendingPathComponent("Support", isDirectory: true), home = base.appendingPathComponent("home/fixture", isDirectory: true), log = base.appendingPathComponent("server.jsonl")
        for folder in [support, home.appendingPathComponent("Desktop"), home.appendingPathComponent("Downloads")] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: base) }
        try Data("the desktop paper".utf8).write(to: home.appendingPathComponent("Desktop/paper.txt"))
        try Data("a downloaded report".utf8).write(to: home.appendingPathComponent("Downloads/report.txt"))
        setenv("BUDDY_ACCESS_SERVER_LOG", log.path, 1)
        let workspace = UUID().uuidString, ada = UUID().uuidString
        try JSONSerialization.data(withJSONObject: ["conversationWorkspace": workspace, "agents": [["id": ada, "name": "Ada", "role": "Researcher", "description": "Reads papers", "tools": ["web": true, "desktop": true, "projectFiles": true]]]]).write(to: support.appendingPathComponent("workspace.json"))
        let host = BuddyWorkerHost(support: support, executable: URL(fileURLWithPath: arguments[1]), keyReader: { _ in "inert-fixture-key" })
        host.filesHome = home
        host.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer { host.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)) }
        // The app's side: the page's bridge records the person's click as "you".
        let app = BuddyProjectFiles(support: support); app.home = home

        func worker(_ payload: [String: Any]) async throws -> [String: Any] { try await BuddyWorkerClient.call(support: support, payload: payload.merging(["workspace": workspace]) { old, _ in old }) }
        func detail(_ id: String) async throws -> [String: Any] { (try await worker(["operation": "detail", "taskId": id]))["task"] as? [String: Any] ?? [:] }
        func poll(_ id: String, _ label: String, seconds: Double = 30, _ done: ([String: Any]) -> Bool) async throws -> [String: Any] {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline { let value = try await detail(id); if done(value) { return value }; try await Task.sleep(nanoseconds: 50_000_000) }
            let last = try await detail(id)
            throw Failed(message: "\(label) (last seen: \(last["status"] ?? "") / \(last["stopCause"] ?? "-") / \(last["progress"] ?? ""))")
        }
        func lines() -> [[String: Any]] { ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }.compactMap { $0.merging(($0["value"] as? [String: Any]) ?? [:]) { a, _ in a } } }
        func results() -> [[String: Any]] { lines().filter { $0["kind"] as? String == "result" } }
        func turns() -> [String] { lines().filter { $0["kind"] as? String == "turn" }.compactMap { $0["text"] as? String } }
        func refusal(_ work: () async throws -> Any) async -> String { do { _ = try await work(); return "" } catch { return error.localizedDescription } }
        /// A task Ada starts whose brief asks the stand-in to read `path` with buddy_read_file.
        func reading(_ path: String, request: String) async throws -> String {
            let goal = "Read the paper the user gave. TOOL:" + json(["tool": "buddy_read_file", "arguments": ["path": path]])
            let made = try await worker(["operation": "create", "agentId": ada, "actorId": ada, "requestId": request, "title": "Read the paper", "goal": goal, "kind": "general", "authorizedText": "Read " + path])
            return (made["task"] as? [String: Any])?["id"] as? String ?? ""
        }
        func pendingRequests() throws -> [[String: Any]] { (try app.accessOverview(workspace)["requests"] as? [[String: Any]] ?? []).filter { $0["status"] as? String == "pending" } }

        await section("a task that names an unconnected Desktop file waits for the person, the card names the task, and Allow resumes it to read the file") {
            let id = try await reading("~/Desktop/paper.txt", request: "desktop")
            let waiting = try await poll(id, "the task waits for the person") { $0["status"] as? String == "waiting_user" }
            let point = waiting["checkpoint"] as? [String: Any] ?? [:], request = point["accessRequest"] as? String ?? ""
            try require(point["need"] as? String == "folder" && !request.isEmpty && (waiting["progress"] as? String ?? "").contains("your Desktop"), "it waits for the folder answer: \(point) \(waiting["progress"] ?? "")")
            let open = try pendingRequests()
            try require(open.count == 1 && open[0]["id"] as? String == request && open[0]["name"] as? String == "Desktop" && open[0]["reason"] as? String == "to read paper.txt", "one request for the Desktop: \(open)")
            let waiter = (open[0]["waiting"] as? [[String: Any]])?.first ?? [:]
            try require(waiter["taskId"] as? String == id && waiter["agentId"] as? String == ada && waiter["agentName"] as? String == "Ada" && (waiter["chat"] as? String ?? "").isEmpty, "the card belongs to Ada's task: \(waiter)")
            try require(results().last?["success"] as? Bool == false && (results().last?["text"] as? String ?? "").contains("access_requested"), "the model was told Buddy asked: \(results().last ?? [:])")
            let agent = await refusal { try await worker(["operation": "folderAccess", "actorId": ada, "arguments": ["requestIds": [request]]]) }
            try require(agent.contains("Only the user"), "an agent can't resume it: \(agent)")
            let early = try await worker(["operation": "folderAccess", "arguments": ["requestIds": [request]]])
            let still = try await detail(id)
            try require((early["resumed"] as? [Any])?.isEmpty == true && still["status"] as? String == "waiting_user", "nothing resumes before the person answers")
            let answered = try app.answerAccess(workspace, id: request, choice: "allow", actor: "you")
            try require((answered["waiting"] as? [[String: Any]])?.first?["taskId"] as? String == id, "the answer names the waiting task")
            let resumed = try await worker(["operation": "folderAccess", "arguments": ["requestIds": [request]]])
            try require(resumed["resumed"] as? [String] == [id], "the task resumes: \(resumed)")
            let done = try await poll(id, "the resumed task finishes") { ["completed", "failed"].contains($0["status"] as? String ?? "") }
            try require(done["status"] as? String == "completed", "it completes: \(done["status"] ?? "") \(done["progress"] ?? "")")
            try require(turns().last?.contains("[Buddy] The user allowed access to your Desktop") == true, "it was told plainly: \(turns().last?.suffix(300) ?? "")")
            try require(results().last?["success"] as? Bool == true && (results().last?["text"] as? String ?? "").contains("the desktop paper"), "and read the file: \(results().last ?? [:])")
            let again = try await worker(["operation": "folderAccess", "arguments": ["requestIds": [request]]])
            try require((again["resumed"] as? [Any])?.isEmpty == true, "an answer resumes a task once")
        }

        await section("declined, the task is told plainly and finishes without it, and a later ask for that place is refused without a new card") {
            let id = try await reading("~/Downloads/report.txt", request: "downloads")
            let waiting = try await poll(id, "the task waits for the person") { $0["status"] as? String == "waiting_user" }
            let request = (waiting["checkpoint"] as? [String: Any])?["accessRequest"] as? String ?? ""
            _ = try app.answerAccess(workspace, id: request, choice: "deny", actor: "you")
            let resumed = try await worker(["operation": "folderAccess", "arguments": ["requestIds": [request]]])
            try require(resumed["resumed"] as? [String] == [id], "the task resumes to hear the answer: \(resumed)")
            let done = try await poll(id, "the task finishes without the file") { ["completed", "failed"].contains($0["status"] as? String ?? "") }
            try require(done["status"] as? String == "completed" && turns().last?.contains("[Buddy] The user declined access to your Downloads") == true, "told plainly: \(turns().last?.suffix(300) ?? "")")
            let later = try await reading("~/Downloads/report.txt", request: "downloads-again")
            let after = try await poll(later, "a later task asking again finishes") { ["completed", "failed", "waiting_user"].contains($0["status"] as? String ?? "") }
            try require(after["status"] as? String == "completed" && (results().last?["text"] as? String ?? "").contains("access_declined") && (try pendingRequests()).isEmpty, "refused without a new card: \(after["status"] ?? "") \(results().last ?? [:])")
        }

        if !failures.isEmpty { fputs("FAILED: \(failures.count) folder access check(s) failed\n", stderr); exit(1) }
    }
}
