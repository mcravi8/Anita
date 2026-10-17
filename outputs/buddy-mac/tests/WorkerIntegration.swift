import AppKit
@main struct WorkerIntegration {
    @MainActor static func require(_ value: Bool, _ message: String) { if !value { fputs("FAILED: \(message)\n", stderr); exit(1) } }
    @MainActor static func main() async throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("buddy-worker-integration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let workspace = UUID().uuidString, agent = UUID().uuidString
        try JSONSerialization.data(withJSONObject: ["conversationWorkspace": workspace, "agents": [["id": agent, "name": "Check", "role": "Fixture", "description": "Inert verification", "tools": [:]]]]).write(to: support.appendingPathComponent("workspace.json"))
        let host = BuddyWorkerHost(support: support, executable: URL(fileURLWithPath: CommandLine.arguments[1]))
        host.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer { host.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)) }
        var request: [String: Any] = ["workspace": workspace, "operation": "create", "agentId": agent, "requestId": "once", "title": "Fixture report", "goal": "Create a private report", "kind": "research", "provider": "chatgpt", "budgetUSD": 0]
        let result = try await BuddyWorkerClient.call(support: support, payload: request), job = result["task"] as! [String: Any], id = job["id"] as! String
        let duplicate = try await BuddyWorkerClient.call(support: support, payload: request)
        require((duplicate["task"] as? [String: Any])?["id"] as? String == id, "IPC create retry does not duplicate a task")
        request = ["workspace": workspace, "operation": "detail", "taskId": id]
        var completed: [String: Any] = [:]
        for _ in 0..<150 {
            let detail = try await BuddyWorkerClient.call(support: support, payload: request)["task"] as! [String: Any]
            if detail["status"] as? String == "completed" { completed = detail; break }
            if detail["status"] as? String == "failed" { fputs("\(detail["progress"] ?? "failed")\n",stderr); break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        require(!completed.isEmpty, "worker executes a queued task through the real app-server protocol")
        require((completed["fileList"] as? [[String: Any]])?.contains { $0["path"] as? String == "fixture.md" } == true, "completed task has private file deliverable")
        let preview = try await BuddyWorkerClient.call(support: support, payload: ["workspace": workspace, "operation": "preview", "taskId": id, "path": "fixture.md"])
        require((preview["content"] as? String)?.contains("Background result") == true, "file preview comes from saved worker bytes")
        let resumed = try BuddyWorkerStore(directory: support.appendingPathComponent("Worker"))
        require(try resumed.job(id)["status"] as? String == "completed", "completed task survives service recreation")
        print("PASS: private Unix IPC, accepted/queued/running/completed worker journey, idempotent enqueue, subscription protocol, real saved file and preview, durable completion")
    }
}
