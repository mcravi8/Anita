// run-tests: BuddyWorkerCore.swift BuddyOperationsDB.swift BuddyWorkerProcess.swift BuddyWorkerHost.swift BuddyPlan.swift BuddySupervisor.swift BuddyMigrations.swift BuddyWorkerClient.swift BuddyAgentMemory.swift BuddyTeamMonitorStore.swift BuddyTeamMonitor.swift BuddyAISettings.swift ConversationService.swift BuddyInboxReview.swift BuddyMailVerification.swift BuddyComputer.swift BuddyTransport.swift BuddyToolInput.swift BuddyConnections.swift BuddyTeam.swift BuddyProjectFiles.swift BuddyDocuments.swift BuddyAgentProposals.swift -- src:tests/quiet-stops-server.py
import AppKit

/// A background task that fails to start for a reason that is nobody's doing (the ChatGPT connector runtime "failed to refresh tools for MCP
/// server 'codex_apps'", exactly as Inbox's 06:00 Gmail check did) is retried by itself a bounded number of times, and then goes to the team's
/// supervisor, never to the person. A scheduled run records the supervisor like any task. Only a task that must change first stops without a
/// retry (still for the supervisor), and a provider account that needs the person still reaches the person. Through the real worker and socket.
@main struct QuietStops {
    nonisolated(unsafe) static var failures: [String] = []
    @MainActor static func expect(_ value: Bool, _ message: String) { if !value { failures.append(message); fputs("FAILED: \(message)\n", stderr) } }
    @MainActor static func main() async throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("buddy-quiet-stops-" + UUID().uuidString + ".noindex")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let w = UUID().uuidString, chief = UUID().uuidString, inbox = UUID().uuidString, vera = UUID().uuidString, wren = UUID().uuidString
        let agents: [[String: Any]] = [["id": chief, "name": "Chief", "role": "Chief of staff"], ["id": inbox, "name": "Inbox", "role": "Mail"],
                                       ["id": vera, "name": "Vera", "role": "Researcher"], ["id": wren, "name": "Wren", "role": "Researcher"]].map { $0.merging(["description": "Fixture", "tools": [String: Bool]()]) { a, _ in a } }
        try JSONSerialization.data(withJSONObject: ["conversationWorkspace": w, "agents": agents]).write(to: support.appendingPathComponent("workspace.json"))
        // Chief supervises the team; automatic check-ins stay off so none runs beside these tasks. Chief chats on ChatGPT, so the supervisor
        // lane (Claude only) stays offline and leaves the open entries as the worker made them.
        let policy: [String: Any] = ["enabled": false, "supervisorId": chief, "supervisorChosen": true, "agents": [String: Any](), "intervalMinutes": 15, "dailyLimitUSD": 2.0, "revision": 1]
        try JSONSerialization.data(withJSONObject: ["version": 1, "settings": [w: policy], "checks": [Any](), "updates": [Any]()]).write(to: support.appendingPathComponent("team-monitor.json"))
        let models = BuddyAgentModels(support: support)
        try models.set(workspace: w, agent: chief, selection: .init(provider: "chatgpt", model: "fixture"))
        try models.set(workspace: w, agent: inbox, selection: .init(provider: "claude", model: "claude-fixture"))
        try models.set(workspace: w, agent: vera, selection: .init(provider: "chatgpt", model: "fixture"))
        try models.set(workspace: w, agent: wren, selection: .init(provider: "chatgpt", model: "fixture-retired"))
        // Inbox's scheduled Gmail check, saved on Claude (its Gmail read goes through the ChatGPT connector runtime).
        let saved = try BuddyRoutineStore(directory: support.appendingPathComponent("Worker")).manage(["action": "create", "title": "Check AgentMail and Gmail (06:00)", "goal": "Check the inbox and say what needs attention.", "kind": "email", "query": "in:inbox newer_than:1d", "hour": 6, "minute": 0, "weekdays": [1, 2, 3, 4, 5, 6, 7], "timeZone": "America/Los_Angeles"],
                                                                                                    workspace: w, agent: inbox, requestID: "inbox-routine", provider: "claude", budget: BuddyRunLimit.none, model: "claude-fixture")
        let routineID = (saved["routine"] as? [String: Any])?["id"] as? String ?? ""
        BuddyRecovery.delayScale = 0.001
        let host = BuddyWorkerHost(support: support, executable: URL(fileURLWithPath: CommandLine.arguments[1]), keyReader: { _ in "inert-fixture-key" })
        host.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer { host.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)) }
        func call(_ payload: [String: Any]) async throws -> [String: Any] { try await BuddyWorkerClient.call(support: support, payload: payload.merging(["workspace": w]) { a, _ in a }) }
        func task(_ id: String) async throws -> [String: Any] { (try await call(["operation": "detail", "taskId": id]))["task"] as? [String: Any] ?? [:] }
        let db = try BuddyOperationsDB(directory: support.appendingPathComponent("Worker"), existing: true)
        /// Every entry ever opened for the task (open or resolved), with its audience.
        func entries(_ id: String) throws -> [(id: String, audience: String, status: String)] {
            try db.rows("SELECT id, audience, status FROM decisions WHERE task_id = ? ORDER BY created_at, id", [.text(id)]).map { ($0[0].string ?? "", $0[1].string ?? "", $0[2].string ?? "") }
        }
        func recovery(_ job: [String: Any]) -> [String: Any] { job["recovery"] as? [String: Any] ?? [:] }
        func describe(_ job: [String: Any]) -> String { "\(job["status"] ?? "") / attempt \(job["attempt"] ?? "-") / cause \(job["stopCause"] ?? "-") / recovery \(recovery(job)) / \(job["progress"] ?? "")" }
        /// Follows a task until `done`, noting who every entry opened meanwhile was for.
        func follow(_ id: String, seconds: Double = 25, _ done: ([String: Any]) -> Bool) async throws -> (job: [String: Any], audiences: Set<String>) {
            var audiences = Set<String>(), job: [String: Any] = [:]
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                job = try await task(id); audiences.formUnion(try entries(id).map(\.audience))
                if done(job) { return (job, audiences) }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            return (job, audiences)
        }
        func settled(_ job: [String: Any]) -> Bool { ["failed", "interrupted", "paused", "waiting_user", "completed", "cancelled"].contains(job["status"] as? String ?? "") && !["pending", "queued"].contains(recovery(job)["state"] as? String ?? "") }
        let connector = "failed to refresh installed connector runtime state: failed to refresh tools for MCP server 'codex_apps'"

        // 1. A ChatGPT task whose connector runtime fails to refresh: retried by itself three times, then the supervisor's.
        let research = try await call(["operation": "create", "agentId": vera, "requestId": "connector", "title": "Research fixture", "goal": "Research the topic.", "kind": "research", "provider": "chatgpt", "budgetUSD": 0])["task"] as? [String: Any] ?? [:]
        let researchID = research["id"] as? String ?? ""
        expect(research["supervisorId"] as? String == chief, "a created task records the team's supervisor")
        let (retried, researchAudiences) = try await follow(researchID) { settled($0) }
        expect(retried["status"] as? String == "failed" && retried["stopCause"] as? String == "provider.error" && recovery(retried)["cause"] as? String == "provider.error"
               && recovery(retried)["state"] as? String == "exhausted" && recovery(retried)["tries"] as? Int == 3 && retried["attempt"] as? Int == 4,
               "a connector failure is a provider error, retried by itself three times before it stops: \(describe(retried))")
        expect((retried["progress"] as? String)?.hasPrefix(connector) == true, "the stop keeps the real error as its reason: \(retried["progress"] ?? "")")
        let researchEntries = try entries(researchID)
        expect(!researchAudiences.contains("user") && researchEntries.count == 1 && researchEntries[0].id == "stopped:\(researchID):4:failed" && researchEntries[0].audience == "supervisor" && researchEntries[0].status == "open",
               "nobody is asked while it retries; once the tries are used up it is one entry, for the supervisor, never the person: \(researchEntries) seen \(researchAudiences)")
        print(failures.isEmpty ? "PASS: a ChatGPT task whose connector runtime fails to refresh is retried by itself three times, then goes to the supervisor, never the person" : "(continuing after failures)")

        // 2. Inbox's scheduled check: its run records the supervisor, and the same connector failure (thrown before the model starts) is retried the same way.
        let before = failures.count
        let ran = try await call(["operation": "routine", "agentId": inbox, "requestId": UUID().uuidString, "arguments": ["action": "run", "routineID": routineID]])["task"] as? [String: Any] ?? [:]
        let runID = ran["id"] as? String ?? ""
        expect(!runID.isEmpty && ran["routineID"] as? String == routineID && ran["provider"] as? String == "claude", "the routine's run is queued on Claude: \(ran)")
        expect(ran["supervisorId"] as? String == chief, "a routine's run records the team's supervisor, like a created task: \(ran["supervisorId"] ?? "none")")
        let (scheduled, scheduledAudiences) = try await follow(runID) { settled($0) }
        expect(scheduled["status"] as? String == "failed" && scheduled["stopCause"] as? String == "provider.error" && recovery(scheduled)["state"] as? String == "exhausted" && scheduled["attempt"] as? Int == 4,
               "a scheduled run whose Gmail read fails to start is retried by itself before it stops: \(describe(scheduled))")
        let scheduledEntries = try entries(runID)
        expect(!scheduledAudiences.contains("user") && scheduledEntries.map(\.audience) == ["supervisor"], "and its stop goes to the supervisor, not the person: \(scheduledEntries) seen \(scheduledAudiences)")
        if failures.count == before { print("PASS: a scheduled run records the supervisor, and a connector failure before its model starts is retried by itself, then goes to the supervisor") }

        // 3. A task that must change before it can run (its model is gone) is not retried, and is still the supervisor's.
        let mark = failures.count
        let retired = try await call(["operation": "create", "agentId": wren, "requestId": "retired", "title": "Retired model fixture", "goal": "Research the topic.", "kind": "research", "provider": "chatgpt", "budgetUSD": 0])["task"] as? [String: Any] ?? [:]
        let retiredID = retired["id"] as? String ?? ""
        let (invalid, _) = try await follow(retiredID) { settled($0) }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let invalidLater = try await task(retiredID)
        expect(invalidLater["status"] as? String == "failed" && invalidLater["stopCause"] as? String == "task.invalid" && invalidLater["attempt"] as? Int == 1 && recovery(invalidLater).isEmpty,
               "a task whose own settings must change stops once, with its cause, and is not retried: \(describe(invalid)) then \(describe(invalidLater))")
        expect(try entries(retiredID).map(\.audience) == ["supervisor"], "and it is the supervisor's: \(try entries(retiredID))")
        if failures.count == mark { print("PASS: a task that must change first stops once with its cause, for the supervisor") }

        // 4. A provider account that needs the person (signed out) still reaches the person, even with a supervisor named.
        let mark2 = failures.count
        setenv("QUIET_FIXTURE_SIGNED_OUT", "1", 1)
        let signedOut = try await call(["operation": "create", "agentId": vera, "requestId": "signed-out", "title": "Signed-out fixture", "goal": "Research the topic.", "kind": "research", "provider": "chatgpt", "budgetUSD": 0])["task"] as? [String: Any] ?? [:]
        let signedOutID = signedOut["id"] as? String ?? ""
        let (account, _) = try await follow(signedOutID) { settled($0) }
        unsetenv("QUIET_FIXTURE_SIGNED_OUT")
        expect(account["status"] as? String == "failed" && account["stopCause"] as? String == "provider.account" && account["attempt"] as? Int == 1 && recovery(account).isEmpty,
               "a signed-out account stops with its cause and is not retried: \(describe(account))")
        expect(try entries(signedOutID).map(\.audience) == ["user"], "and signing in stays the person's: \(try entries(signedOutID))")
        if failures.count == mark2 { print("PASS: a provider account that needs the person still reaches the person") }

        BuddyRecovery.delayScale = 1
        if !failures.isEmpty { fputs("\(failures.count) expectation(s) failed\n", stderr); exit(1) }
    }
}
