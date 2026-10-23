// run-tests: BuddyWorkerCore.swift BuddyOperationsDB.swift BuddyWorkerProcess.swift BuddyWorkerHost.swift BuddyCodexCoding.swift BuddyPlan.swift BuddySupervisor.swift BuddyMigrations.swift BuddyWorkerClient.swift BuddyAgentMemory.swift BuddyTeamMonitorStore.swift BuddyTeamMonitor.swift BuddyAISettings.swift ConversationService.swift BuddyInboxReview.swift BuddyMailVerification.swift BuddyComputer.swift BuddyTransport.swift BuddyToolInput.swift BuddyConnections.swift BuddyTeam.swift BuddyProjectFiles.swift BuddyDocuments.swift BuddyAgentProposals.swift -- src:tests/codex-coding-server.py src:tests/coding-claude.py which:python3
import AppKit

/// Coding sessions on ChatGPT through Codex, end to end through the real worker: its socket, queue and recovery, ConversationService's
/// app-server connection, and a stand-in app-server (tests/codex-coding-server.py) that logs what it is asked. An agent on Claude still codes on
/// Claude (tests/coding-claude.py). Each section reports on its own, so a run shows every check that fails, not only the first.
@main struct CodexCodingChecks {
    struct Failed: Error { let message: String }
    static func require(_ value: Bool, _ message: @autoclosure () -> String) throws { if !value { throw Failed(message: message()) } }
    @MainActor static var failures: [String] = []
    @MainActor static func section(_ name: String, _ body: () async throws -> Void) async {
        do { try await body(); print("PASS: " + name) }
        catch let failed as Failed { failures.append(name); fputs("FAILED: \(name): \(failed.message)\n", stderr) }
        catch { failures.append(name); fputs("FAILED: \(name): \(error.localizedDescription)\n", stderr) }
    }

    @MainActor static func main() async throws {
        let arguments = CommandLine.arguments   // [1] the app-server stand-in, [2] the Claude coding stand-in, [3] python3
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("buddy-codex-coding-" + UUID().uuidString + ".noindex")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let workspace = UUID().uuidString, coder = UUID().uuidString, clara = UUID().uuidString
        try JSONSerialization.data(withJSONObject: ["conversationWorkspace": workspace, "agents": [
            ["id": coder, "name": "Codey", "role": "Engineer", "description": "Builds fixtures on ChatGPT", "tools": [String: Bool]()],
            ["id": clara, "name": "Clara", "role": "Engineer", "description": "Builds fixtures on Claude", "tools": [String: Bool]()]]]).write(to: support.appendingPathComponent("workspace.json"))
        let models = BuddyAgentModels(support: support)
        try models.set(workspace: workspace, agent: coder, selection: .init(provider: "chatgpt", model: "gpt-fixture-coder"))
        try models.set(workspace: workspace, agent: clara, selection: .init(provider: "claude", model: "claude-fixture"))
        let host = BuddyWorkerHost(support: support, executable: URL(fileURLWithPath: arguments[1]),
                                   makeCoding: { BuddyWorkerProcess(resource: URL(fileURLWithPath: arguments[2]), runtime: URL(fileURLWithPath: arguments[3])) },
                                   keyReader: { _ in "inert-fixture-key" })
        host.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer { host.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)) }

        func worker(_ payload: [String: Any]) async throws -> [String: Any] { try await BuddyWorkerClient.call(support: support, payload: payload.merging(["workspace": workspace]) { old, _ in old }) }
        func coding(_ arguments: [String: Any], as agent: String, request: String) async throws -> [String: Any] {
            try await worker(["operation": "coding", "agentId": agent, "requestId": request, "arguments": arguments])
        }
        func start(_ goal: String, as agent: String = coder, request: String) async throws -> [String: Any] {
            (try await coding(["action": "start", "title": "Codex fixture", "goal": goal], as: agent, request: request))["task"] as? [String: Any] ?? [:]
        }
        func detail(_ id: String) async throws -> [String: Any] { (try await worker(["operation": "detail", "taskId": id]))["task"] as? [String: Any] ?? [:] }
        func poll(_ id: String, _ label: String, seconds: Double = 20, _ done: ([String: Any]) -> Bool) async throws -> [String: Any] {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline { let value = try await detail(id); if done(value) { return value }; try await Task.sleep(nanoseconds: 50_000_000) }
            let last = try await detail(id)
            throw Failed(message: "\(label) (last seen: \(last["status"] ?? "") / \(last["stopCause"] ?? "-") / \(last["progress"] ?? ""))")
        }
        func settled(_ job: [String: Any]) -> Bool { ["completed", "failed", "paused", "interrupted", "waiting_user", "waiting_review", "cancelled"].contains(job["status"] as? String ?? "") }
        func project(_ id: String) -> URL { support.appendingPathComponent("Worker/Tasks/\(id)/Files", isDirectory: true) }
        func fixtureLog(_ id: String) -> [[String: Any]] {
            let url = support.appendingPathComponent("Worker/Tasks/\(id)/Conversation/Conversations/codex-fixture.jsonl")
            return ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        }
        func requests(_ id: String, _ method: String) -> [[String: Any]] {
            fixtureLog(id).compactMap { $0["kind"] as? String == "request" ? $0["value"] as? [String: Any] : nil }.filter { $0["method"] as? String == method }.compactMap { $0["params"] as? [String: Any] }
        }
        func logged(_ id: String, _ kind: String) -> [Any] { fixtureLog(id).filter { $0["kind"] as? String == kind }.compactMap { $0["value"] } }
        func review(_ job: [String: Any]) -> [String: Any] { (job["reviews"] as? [[String: Any]] ?? []).last ?? [:] }
        func answer(_ task: String, _ job: [String: Any], accept: Bool) async throws { _ = try await worker(["operation": "review", "taskId": task, "id": review(job)["id"] ?? "", "accept": accept]) }
        func text(_ value: Any?) -> String { value as? String ?? "" }

        // 1. An agent on ChatGPT codes on Codex: the thread works in the task's project copy, can write only there, has no network, uses the
        // agent's model and Buddy's coding brief, and has no connector or write tools. Every command becomes a receipt; the answer is the result.
        var buildID = ""
        await section("an agent on ChatGPT codes on Codex: thread/start with the project copy as cwd, workspace-write sandbox, network off, the agent's model and Buddy's coding brief") {
            let job = try await start("CODEX_BUILD: build the fixture and check it.", request: "build")
            buildID = job["id"] as? String ?? ""
            try require(job["provider"] as? String == "chatgpt" && job["model"] as? String == "gpt-fixture-coder" && job["kind"] as? String == "coding", "the task runs on the agent's own provider and model: \(job["provider"] ?? "-") \(job["model"] ?? "-") \(job["kind"] ?? "-")")
            let done = try await poll(buildID, "the Codex coding task finishes") { settled($0) }
            try require(done["status"] as? String == "completed", "it completes: \(done["status"] ?? "") \(done["progress"] ?? "")")
            let thread = requests(buildID, "thread/start").first ?? [:], config = thread["config"] as? [String: Any] ?? [:]
            try require(thread["cwd"] as? String == project(buildID).path, "cwd is the task's own project copy: \(thread["cwd"] ?? "-")")
            try require(thread["sandbox"] as? String == "workspace-write" && thread["approvalPolicy"] as? String == "on-request" && thread["approvalsReviewer"] as? String == "user", "workspace-write, approvals asked of Buddy: \(thread["sandbox"] ?? "-") \(thread["approvalPolicy"] ?? "-")")
            try require(config["sandbox_workspace_write.network_access"] as? Bool == false && config["sandbox_workspace_write.exclude_slash_tmp"] as? Bool == true && config["sandbox_workspace_write.exclude_tmpdir_env_var"] as? Bool == true, "network off and writes only in the project: \(config)")
            try require(config["features.apps"] as? Bool == false && thread["model"] as? String == "gpt-fixture-coder", "no connectors, the agent's model: \(config["features.apps"] ?? "-") \(thread["model"] ?? "-")")
            let tools = Set((thread["dynamicTools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String })
            let claudeCoding = Set(BuddyProjectFiles.tools.compactMap { $0["name"] as? String }).union(["buddy_copy_into_project", "buddy_copy_out_of_project", "buddy_checkpoint", "buddy_request_decision", "buddy_request_signin", "buddy_coding_command", "buddy_browser_fetch", "buddy_service_api", "buddy_remote_machine"])
            // Buddy's command tool is there only for a command that signs in (credential is required); Codex runs every other command in its own shell.
            let command = (thread["dynamicTools"] as? [[String: Any]] ?? []).first { $0["name"] as? String == "buddy_coding_command" }?["inputSchema"] as? [String: Any] ?? [:]
            try require(tools == claudeCoding && (command["required"] as? [String] ?? []).contains("credential"), "the same Buddy file, copy, save, fetch, decision and sign-in tools as a Claude coding session, with Buddy's command tool only for signed-in commands: \(tools.sorted())")
            let brief = thread["developerInstructions"] as? String ?? ""
            try require(brief.contains("Decisions: decide by default.") && brief.contains("Use buddy_checkpoint only when the user must act in person") && brief.contains("No supervisor is set for this team") && brief.contains("Time: the user is in the")
                        && brief.contains(project(buildID).path) && brief.contains("You are Codey") && !brief.contains("Claude"), "Buddy's coding brief with the decision policy, supervision line and clock, adapted for Codex: \(brief.prefix(300))")
            let turn = requests(buildID, "turn/start").first ?? [:], policy = turn["sandboxPolicy"] as? [String: Any] ?? [:]
            try require(policy["type"] as? String == "workspaceWrite" && policy["networkAccess"] as? Bool == false && turn["cwd"] as? String == project(buildID).path && turn["model"] as? String == "gpt-fixture-coder" && turn["effort"] as? String == "high",
                        "the turn keeps the sandbox, cwd, model and its effort: \(turn.filter { $0.key != "input" })")
            try require(((turn["input"] as? [[String: Any]])?.first?["text"] as? String ?? "").hasPrefix("CODEX_BUILD"), "the brief is the turn's input")
            let commands = done["commands"] as? [[String: Any]] ?? []
            try require(commands.count == 2 && commands[0]["id"] as? String == "cmd-build" && commands[0]["code"] as? String == "node --check index.js" && commands[0]["status"] as? String == "completed" && commands[0]["exitCode"] as? Int == 0
                        && commands[0]["durationMs"] as? Int == 42 && commands[0]["network"] as? Bool == false && !(commands[0]["at"] as? String ?? "").isEmpty, "each command Codex ran is a receipt: \(commands)")
            try require(commands[1]["exitCode"] as? Int == 1 && commands[1]["status"] as? String == "completed" && commands[1]["output"] as? String == "boom\n", "a failing command keeps its exit code and output: \(commands.last ?? [:])")
            let result = text(done["result"])
            try require(result.hasPrefix("Built the fixture: node --check passed") && result.contains("Command receipts: 2 finished, 1 exited successfully") && !result.contains("Checking the build."), "the last answer is the result, with the receipts line: \(result)")
            try require((try? String(contentsOf: project(buildID).appendingPathComponent("index.js"), encoding: .utf8)) == "console.log(\"codex fixture\");\n", "Codex's edit is in the project copy")
            try require(UUID(uuidString: text(done["codingSessionID"])) != nil, "the Codex thread is saved for continuing: \(done["codingSessionID"] ?? "-")")
            try require(text(done["codingSessionTools"]) == BuddyCodexCoding.toolsFingerprint, "with the tools it was started with: \(done["codingSessionTools"] ?? "-")")
        }

        // A resumed Codex thread keeps the tools it was started with. Chief's S01 thread started before buddy_checkpoint gained need file; on
        // resume Buddy told it to use need file, its own tool refused it, and it asked its supervisor (itself) to route the download instead.
        await section("a Codex thread started with other tools isn't resumed: the task starts a new thread with today's tools") {
            let saved: [String: Any] = ["codingSessionID": "01a15d8a-de36-7db1-b82e-ce2dcccc3cb5", "codingSessionTools": BuddyCodexCoding.toolsFingerprint]
            try require(BuddyCodexCoding.resumable(saved) == "01a15d8a-de36-7db1-b82e-ce2dcccc3cb5", "a thread with today's tools is resumed")
            try require(BuddyCodexCoding.resumable(saved.merging(["codingSessionTools": "older-tools"]) { $1 }) == nil, "a thread started with other tools is not")
            try require(BuddyCodexCoding.resumable(["codingSessionID": "01a15d8a-de36-7db1-b82e-ce2dcccc3cb5"]) == nil, "nor one saved before Buddy recorded its tools")
            try require(BuddyCodexCoding.resumable(["codingSessionTools": BuddyCodexCoding.toolsFingerprint]) == nil, "and a task with no thread starts one")
            let checkpoint = BuddyCodexCoding.tools.first { $0["name"] as? String == "buddy_checkpoint" }
            let needs = ((checkpoint?["inputSchema"] as? [String: Any])?["properties"] as? [String: Any])?["need"] as? [String: Any]
            try require((needs?["enum"] as? [String])?.contains("file") == true, "today's tools let a coding session ask for a file")
            var changed = BuddyCodexCoding.tools; changed[0]["description"] = "changed"
            try require(BuddyCodexCoding.fingerprint(changed) != BuddyCodexCoding.toolsFingerprint && BuddyCodexCoding.fingerprint(BuddyCodexCoding.tools) == BuddyCodexCoding.toolsFingerprint, "any change to a tool's description or schema counts, and the same tools always read the same")
        }

        // 2. Continue works as on Claude: the same task, the same thread, a second attempt.
        await section("continue resumes the same Codex thread for an explicit follow-up") {
            let before = try await detail(buildID)
            _ = try await coding(["action": "continue", "taskId": buildID, "goal": "Run the check once more."], as: coder, request: "build-follow-up")
            let again = try await poll(buildID, "the continued task finishes") { $0["attempt"] as? Int == 2 && settled($0) }
            try require(again["status"] as? String == "completed" && text(again["result"]).hasPrefix("Continued on the same thread"), "the follow-up finished: \(again["status"] ?? "") \(again["result"] ?? "")")
            try require(requests(buildID, "thread/resume").last?["threadId"] as? String == text(before["codingSessionID"]) && !text(before["codingSessionID"]).isEmpty, "it resumed the saved thread")
            try require(requests(buildID, "thread/start").count == 1, "and started no new one, since its tools are today's")
            try require((again["commands"] as? [[String: Any]])?.count == 3, "the earlier receipts stay and the new one is added")
        }

        // 3. A connected folder's file is copied into the project by Buddy; Codex edits the copy and the original stays as it was.
        await section("Codex brings a connected folder's file into its project with Buddy's copy tool; only the copy changes") {
            let original = support.appendingPathComponent("Original project", isDirectory: true)
            try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
            try Data("original notes".utf8).write(to: original.appendingPathComponent("notes.txt"))
            let folder = try BuddyProjectFiles(support: support).addFolder(workspace, to: original)["folderId"] as? String ?? ""
            let id = (try await start("CODEX_COPY \(folder)", request: "copy"))["id"] as? String ?? ""
            let done = try await poll(id, "the copy task finishes") { settled($0) }
            try require(done["status"] as? String == "completed", "it completes: \(done["status"] ?? "") \(done["progress"] ?? "")")
            let call = logged(id, "tool-result").first as? [String: Any] ?? [:]
            try require(call["success"] as? Bool == true && ((call["value"] as? [String: Any])?["copied"] as? [[String: Any]])?.first?["path"] as? String == "notes.txt", "the tool result reached Codex: \(call)")
            try require((try? String(contentsOf: project(id).appendingPathComponent("notes.txt"), encoding: .utf8)) == "original notes edited in the copy", "the copy in the project was edited")
            try require((try? String(contentsOf: original.appendingPathComponent("notes.txt"), encoding: .utf8)) == "original notes", "the user's original is unchanged")
        }

        // 4. A command that asks to leave the sandbox (for the network) is a native review, and runs only once it is approved.
        await section("a Codex network request becomes a native coding review and does not run until approved") {
            let id = (try await start("CODEX_NETWORK: fetch the dependency.", request: "network"))["id"] as? String ?? ""
            let waiting = try await poll(id, "the request waits for review") { settled($0) }
            let card = review(waiting), shown = (card["tool"] as? [String: Any])?["arguments"] as? [String: Any] ?? [:]
            try require(waiting["status"] as? String == "waiting_review" && card["kind"] as? String == "coding" && card["status"] as? String == "pending", "it waits for a coding review: \(waiting["status"] ?? "") \(card)")
            try require(shown["command"] as? String == "curl -fsS https://example.com/dependency.tgz -o fetched.txt" && shown["reason"] as? String == "Download the dependency the build needs." && shown["project"] as? String == project(id).path, "the card shows the exact command, why, and the project: \(shown)")
            try require(!FileManager.default.fileExists(atPath: project(id).appendingPathComponent("fetched.txt").path) && logged(id, "decision").isEmpty, "nothing ran and nothing was answered before the review")
            try await Task.sleep(nanoseconds: 1_200_000_000)
            let still = try await detail(id)
            try require(logged(id, "decision").isEmpty && still["status"] as? String == "waiting_review", "it is never approved by itself")
            try await answer(id, waiting, accept: true)
            let done = try await poll(id, "the approved command runs and the task finishes") { $0["status"] as? String == "completed" }
            try require(logged(id, "decision").first as? String == "accept" && (try? String(contentsOf: project(id).appendingPathComponent("fetched.txt"), encoding: .utf8)) == "approved", "the approval reached Codex and the command ran")
            let receipt = (done["commands"] as? [[String: Any]] ?? []).last ?? [:]
            try require(receipt["id"] as? String == "cmd-net" && receipt["network"] as? Bool == true && receipt["exitCode"] as? Int == 0, "its receipt says it ran with network: \(receipt)")
            try require(review(done)["status"] as? String == "completed" && (review(done)["receipt"] as? [String: Any])?["exitCode"] as? Int == 0, "the review is completed with the command's receipt: \(review(done))")
        }

        // 5. Declined: the request is answered as declined, Codex is told, nothing ran. Also for a command announced before it asks, and for
        // writing outside the project.
        await section("a declined Codex request is reported back as declined and never runs (network, and writing outside the project)") {
            let id = (try await start("CODEX_NETWORK_DECLINE: install the package.", request: "decline"))["id"] as? String ?? ""
            let waiting = try await poll(id, "the install waits for review") { settled($0) }
            let shown = (review(waiting)["tool"] as? [String: Any])?["arguments"] as? [String: Any] ?? [:]
            try require(waiting["status"] as? String == "waiting_review" && shown["command"] as? String == "npm install left-pad", "the card shows the command Codex announced: \(shown)")
            try await answer(id, waiting, accept: false)
            let done = try await poll(id, "the declined task finishes") { $0["status"] as? String == "completed" }
            let receipts = done["commands"] as? [[String: Any]] ?? []
            try require(logged(id, "decision").first as? String == "decline" && text(done["result"]).hasPrefix("The install was declined") && !FileManager.default.fileExists(atPath: project(id).appendingPathComponent("installed.txt").path), "Codex was told it was declined and nothing ran: \(done["result"] ?? "")")
            try require(!receipts.contains { $0["id"] as? String == "cmd-net-2" } && review(done)["status"] as? String == "cancelled" && text(done["result"]).contains("Command receipts: 0 finished, 0 exited successfully."),
                        "as on Claude, a declined command leaves no receipt, and the review says declined: \(receipts) \(review(done)["status"] ?? "-")")
            let outside = (try await start("CODEX_OUTSIDE: put the output next to the project.", request: "outside"))["id"] as? String ?? ""
            let asks = try await poll(outside, "writing outside the project waits for review") { settled($0) }
            let card = (review(asks)["tool"] as? [String: Any]) ?? [:]
            try require(asks["status"] as? String == "waiting_review" && card["name"] as? String == "Write files outside the project" && ((card["arguments"] as? [String: Any])?["paths"] as? [String])?.contains("/tmp/buddy-outside-fixture-never-written.txt") == true, "the card names the files: \(card)")
            try await answer(outside, asks, accept: false)
            let refused = try await poll(outside, "the declined write finishes") { $0["status"] as? String == "completed" }
            try require(logged(outside, "decision").first as? String == "decline" && text(refused["result"]).hasPrefix("Writing outside the project was declined"), "declined and reported: \(refused["result"] ?? "")")
        }

        // 6. Results leave the private copy: Codex saves them into a connected folder, where teammates and the supervisor can check them. A Stage 3
        //    run on Codex once left its tables in the task's own copy, so the validator could not audit them and the stage stuck.
        await section("Codex saves its results into a connected folder with buddy_copy_out_of_project, never overwriting") {
            let shared = support.appendingPathComponent("Shared research", isDirectory: true)
            try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
            let folder = try BuddyProjectFiles(support: support).addFolder(workspace, to: shared)["folderId"] as? String ?? ""
            let id = (try await start("CODEX_SAVE_RESULTS \(folder)", request: "copy-out"))["id"] as? String ?? ""
            let done = try await poll(id, "the save task finishes") { settled($0) }
            let call = logged(id, "tool-result").first as? [String: Any] ?? [:]
            try require(done["status"] as? String == "completed" && call["success"] as? Bool == true, "the save succeeded and its result reached Codex: \(call) \(done["progress"] ?? "")")
            try require((try? String(contentsOf: shared.appendingPathComponent("stage3/results/table.csv"), encoding: .utf8)) == "event,mae\nGFC,0.29\n", "the file is in the connected folder, in its new subfolder")
        }

        // 7. A decision the agent may not make ends the attempt and waits, as on Claude.
        await section("buddy_request_decision from Codex saves the question and the task waits for the answer") {
            let id = (try await start("CODEX_DECISION: build the report.", request: "decision"))["id"] as? String ?? ""
            let asked = try await poll(id, "the question ends the attempt") { settled($0) }
            let question = asked["checkpoint"] as? [String: Any] ?? [:]
            try require(asked["status"] as? String == "waiting_user" && asked["stopCause"] as? String == "checkpoint.user" && question["question"] as? String == "Which data year should the report use?" && question["recommendation"] as? String == "Use the 2015 data.",
                        "it waits with the question: \(asked["status"] ?? "") \(asked["stopCause"] ?? "-") \(question)")
            let call = logged(id, "tool-result").first as? [String: Any] ?? [:]
            try require(call["success"] as? Bool == true && text((call["value"] as? [String: Any])?["instruction"]).contains("resumed with the answer"), "Codex was told to end the attempt: \(call)")
        }

        // 8. The ChatGPT plan's usage limit is a pause that ends by itself when the limit resets, never a failure.
        await section("the ChatGPT usage limit pauses with stopCause limit, is never a failure, and resumes by itself after the reset") {
            BuddyRecovery.limitPassInterval = 0.5
            defer { BuddyRecovery.limitPassInterval = 60 }
            let id = (try await start("CODEX_LIMIT: build until the limit.", request: "limit"))["id"] as? String ?? ""
            var seen = Set<String>()
            let paused = try await poll(id, "the limit pauses the task") { seen.insert($0["status"] as? String ?? ""); return settled($0) }
            let until = ISO8601DateFormatter().date(from: text(paused["blockedUntil"]))
            try require(paused["status"] as? String == "paused" && paused["stopCause"] as? String == "limit" && paused["blockedBy"] as? String == "limit", "a pause for the limit: \(paused["status"] ?? "") \(paused["stopCause"] ?? "-") \(paused["blockedBy"] ?? "-")")
            try require(text(paused["progress"]).contains("ChatGPT") && text(paused["progress"]).contains("usage limit") && text(paused["progress"]).contains("continues by itself"), "it says so plainly: \(paused["progress"] ?? "")")
            try require(until.map { $0 > Date().addingTimeInterval(-30) && $0 < Date().addingTimeInterval(30) } == true, "it waits until the reset the plan reported: \(paused["blockedUntil"] ?? "-")")
            let decisions = ((try await worker(["operation": "status"]))["decisions"] as? [[String: Any]] ?? []).filter { $0["taskId"] as? String == id }
            try require(!decisions.contains { ["stopped", "paused"].contains($0["kind"] as? String ?? "") }, "no failure or stop is reported: \(decisions)")
            let resumed = try await poll(id, "after the reset it continues by itself", seconds: 30) { seen.insert($0["status"] as? String ?? ""); return $0["status"] as? String == "completed" }
            try require(resumed["attempt"] as? Int == 2 && text(resumed["result"]).hasPrefix("Recovered") && !seen.contains("failed"), "a second attempt finished it, and it never failed: \(resumed["attempt"] ?? "") \(seen.sorted())")
        }

        // 9-11. Technical stops map to the causes BuddyRecovery already handles.
        await section("silence is a stall, a failed turn is provider.error, a closed connection is bridge.closed, and each continues by itself") {
            defer { BuddyRecovery.delayScale = 1 }
            let stall = (try await start("CODEX_STALL: keep going.", request: "stall"))["id"] as? String ?? ""
            _ = try await poll(stall, "the silent attempt starts") { $0["status"] as? String == "running" && $0["codingSessionID"] != nil }
            host.testingAgeActivity(by: 181)
            let stalled = try await poll(stall, "the silent attempt is stopped") { settled($0) }
            try require(stalled["status"] as? String == "interrupted" && stalled["stopCause"] as? String == "stall" && (stalled["recovery"] as? [String: Any])?["state"] as? String == "pending", "a stall: \(stalled["status"] ?? "") \(stalled["stopCause"] ?? "-")")
            BuddyRecovery.delayScale = 0.001
            let recovered = try await poll(stall, "the stalled task continues by itself") { $0["status"] as? String == "completed" }
            try require(recovered["attempt"] as? Int == 2 && text(recovered["result"]).hasPrefix("Recovered"), "it continued: \(recovered["attempt"] ?? "")")
            BuddyRecovery.delayScale = 1
            let error = (try await start("CODEX_ERROR: keep going.", request: "error"))["id"] as? String ?? ""
            let failed = try await poll(error, "a failed turn stops the attempt") { settled($0) }
            try require(failed["status"] as? String == "failed" && failed["stopCause"] as? String == "provider.error" && (failed["recovery"] as? [String: Any])?["state"] as? String == "pending" && text(failed["progress"]).hasPrefix("ChatGPT hit an error while working"),
                        "provider.error: \(failed["status"] ?? "") \(failed["stopCause"] ?? "-") \(failed["progress"] ?? "")")
            BuddyRecovery.delayScale = 0.001
            _ = try await poll(error, "it continues by itself") { $0["status"] as? String == "completed" && $0["attempt"] as? Int == 2 }
            BuddyRecovery.delayScale = 1
            let crash = (try await start("CODEX_CRASH: keep going.", request: "crash"))["id"] as? String ?? ""
            let closed = try await poll(crash, "a closed connection stops the attempt") { settled($0) }
            try require(closed["status"] as? String == "failed" && closed["stopCause"] as? String == "bridge.closed" && (closed["recovery"] as? [String: Any])?["state"] as? String == "pending", "bridge.closed: \(closed["status"] ?? "") \(closed["stopCause"] ?? "-") \(closed["progress"] ?? "")")
            BuddyRecovery.delayScale = 0.001
            _ = try await poll(crash, "it continues by itself") { $0["status"] as? String == "completed" && $0["attempt"] as? Int == 2 }
        }

        // 12. Cancel works as on Claude.
        await section("cancel stops a running Codex coding session") {
            let id = (try await start("CODEX_STALL: cancel me.", request: "cancel"))["id"] as? String ?? ""
            _ = try await poll(id, "it runs") { $0["status"] as? String == "running" && $0["codingSessionID"] != nil }
            let cancelled = (try await coding(["action": "cancel", "taskId": id], as: coder, request: "cancel-it"))["task"] as? [String: Any] ?? [:]
            try require(cancelled["status"] as? String == "cancelled", "cancelled: \(cancelled["status"] ?? "")")
            try await Task.sleep(nanoseconds: 1_500_000_000)
            let later = try await detail(id)
            try require(later["status"] as? String == "cancelled", "and it stays cancelled")
        }

        // 13. An agent on Claude still codes through Claude Code, untouched.
        await section("an agent on Claude still codes on the Claude path, with its Claude model") {
            let job = try await start("LOST_SUMMARY_FIXTURE: a Claude coding task.", as: clara, request: "claude")
            let id = job["id"] as? String ?? ""
            try require(job["provider"] as? String == "claude" && job["model"] as? String == "claude-fixture", "Claude and its model: \(job["provider"] ?? "-") \(job["model"] ?? "-")")
            let done = try await poll(id, "the Claude task finishes") { settled($0) }
            try require(done["status"] as? String == "completed" && text(done["result"]).hasPrefix("First attempt verified result.") && fixtureLog(id).isEmpty, "it ran through the Claude coding bridge, not the app-server: \(done["status"] ?? "") \(done["result"] ?? "")")
        }

        // 14. A coding task runs on the agent's provider; if that one is not connected but the other is, on the other; with neither, it is refused.
        await section("when the agent's provider is not connected the other one is used, and with neither the start is refused") {
            let settings = BuddyAISettings(support: support)
            _ = try settings.update(workspace, enabled: ("chatgpt", false))
            let toClaude = try await start("LOST_SUMMARY_FIXTURE: ChatGPT is off.", request: "fallback-claude")
            try require(toClaude["provider"] as? String == "claude" && toClaude["model"] as? String == "claude-sonnet-4-6", "a ChatGPT agent codes on Claude while ChatGPT is off: \(toClaude["provider"] ?? "-") \(toClaude["model"] ?? "-")")
            _ = try await poll(toClaude["id"] as? String ?? "", "it finishes on Claude") { $0["status"] as? String == "completed" }
            _ = try settings.update(workspace, enabled: ("chatgpt", true)); _ = try settings.update(workspace, enabled: ("claude", false))
            let toCodex = try await start("CODEX_BUILD: Claude is off.", as: clara, request: "fallback-codex")
            let id = toCodex["id"] as? String ?? ""
            try require(toCodex["provider"] as? String == "chatgpt" && toCodex["model"] == nil, "a Claude agent codes on ChatGPT while Claude is off, on the account default: \(toCodex["provider"] ?? "-") \(toCodex["model"] ?? "-")")
            let done = try await poll(id, "it finishes on Codex") { settled($0) }
            try require(done["status"] as? String == "completed" && requests(id, "thread/start").first?["model"] as? String == "gpt-fixture-default", "on the account's default model: \(done["status"] ?? "") \(requests(id, "thread/start").first?["model"] ?? "-")")
            _ = try settings.update(workspace, enabled: ("chatgpt", false))
            var refused = false
            do { _ = try await start("CODEX_BUILD: nothing is connected.", request: "nothing") } catch { refused = true }
            _ = try settings.update(workspace, enabled: ("chatgpt", true)); _ = try settings.update(workspace, enabled: ("claude", true))
            try require(refused, "with neither provider connected the start is refused")
        }

        if !failures.isEmpty { fputs("FAILED: \(failures.count) Codex coding check(s)\n", stderr); exit(1) }
        print("PASS: coding on ChatGPT through Codex keeps the coding task contract: provider choice, sandboxed project copy, receipts, reviews, results and stops")
    }
}
