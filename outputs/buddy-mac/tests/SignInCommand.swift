import AppKit
import CryptoKit
import Security

/// The secure sign-in handoff for commands, and the supervisor answering routine coding command reviews, end to end through the real worker:
/// its socket, queue and decisions, the coding bridge, Buddy's sandboxed command runner (coding-shell.mjs, so commands really run), a stand-in
/// Claude coding session, background bridge and supervisor (tests/signin-command-claude.py) and a stand-in Codex app-server
/// (tests/codex-coding-server.py). Sign-ins live in an in-memory store here, with a fake account; the one section that checks the Keychain
/// store itself uses a test-only service name, so the person's own Keychain items are never read or written. Each section reports on its own.
@main struct SignInCommandChecks {
    struct Failed: Error { let message: String }
    static func require(_ value: Bool, _ message: @autoclosure () -> String) throws { if !value { throw Failed(message: message()) } }
    @MainActor static var failures: [String] = []
    @MainActor static func section(_ name: String, _ body: () async throws -> Void) async {
        do { try await body(); print("PASS: " + name) }
        catch let failed as Failed { failures.append(name); fputs("FAILED: \(name): \(failed.message)\n", stderr) }
        catch { failures.append(name); fputs("FAILED: \(name): \(error.localizedDescription)\n", stderr) }
    }
    /// Saved sign-ins in memory, counting every time one is read.
    final class Saved: BuddySignInStore {
        var items: [String: BuddySignIn] = [:], reads = 0
        func read(workspace: String, profile: String) -> BuddySignIn? { reads += 1; return items[workspace + ":" + profile] }
        func save(workspace: String, profile: String, username: String, password: String) throws { items[workspace + ":" + profile] = BuddySignIn(username: username, password: password) }
        func remove(workspace: String, profile: String) throws { items.removeValue(forKey: workspace + ":" + profile) }
        func has(workspace: String, profile: String) -> Bool { items[workspace + ":" + profile] != nil }
    }

    @MainActor static func main() async throws {
        let arguments = CommandLine.arguments   // [1] the Claude stand-in, [2] python3, [3] coding-shell.mjs, [4] node, [5] the Codex app-server stand-in
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("buddy-signin-command-" + UUID().uuidString + ".noindex")
        let support = base.appendingPathComponent("Support", isDirectory: true), logs = base.appendingPathComponent("Fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true); try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let fixtureLog = logs.appendingPathComponent("claude-fixture.jsonl")
        setenv("BUDDY_SIGNIN_FIXTURE_LOG", fixtureLog.path, 1)
        // A fake account. Neither value may appear in anything Buddy stores, logs or hands to a model.
        let username = "fixture-user-7Q2Z", password = "Fx!pw-93ZK-not-a-real-secret"
        let workspace = UUID().uuidString, chief = UUID().uuidString, forge = UUID().uuidString, clara = UUID().uuidString, bea = UUID().uuidString
        try JSONSerialization.data(withJSONObject: ["conversationWorkspace": workspace, "agents": [
            ["id": chief, "name": "Chief", "role": "Chief of staff", "description": "Supervises the fixture team", "tools": [String: Bool]()],
            ["id": forge, "name": "Forge", "role": "Engineer", "description": "Codes on ChatGPT", "tools": [String: Bool]()],
            ["id": clara, "name": "Clara", "role": "Engineer", "description": "Codes on Claude", "tools": [String: Bool]()],
            ["id": bea, "name": "Bea", "role": "Researcher", "description": "Background work on Claude", "tools": [String: Bool]()]]]).write(to: support.appendingPathComponent("workspace.json"))
        // Chief supervises the team, so anything that may go to a supervisor could go to Chief. Check-ins are off: only the supervisor lane runs.
        let policy: [String: Any] = ["enabled": false, "supervisorId": chief, "supervisorChosen": true, "agents": [String: Any](), "intervalMinutes": 15, "dailyLimitUSD": 2.0, "revision": 1]
        try JSONSerialization.data(withJSONObject: ["version": 1, "settings": [workspace: policy], "checks": [Any](), "updates": [Any]()]).write(to: support.appendingPathComponent("team-monitor.json"))
        let models = BuddyAgentModels(support: support)
        try models.set(workspace: workspace, agent: chief, selection: .init(provider: "claude", model: "claude-fixture"))
        try models.set(workspace: workspace, agent: forge, selection: .init(provider: "chatgpt", model: "gpt-fixture-coder"))
        try models.set(workspace: workspace, agent: clara, selection: .init(provider: "claude", model: "claude-fixture"))
        try models.set(workspace: workspace, agent: bea, selection: .init(provider: "claude", model: "claude-fixture"))
        let saved = Saved()
        let host = BuddyWorkerHost(support: support, executable: URL(fileURLWithPath: arguments[5]),
                                   makeCoding: { BuddyWorkerProcess(resource: URL(fileURLWithPath: arguments[1]), runtime: URL(fileURLWithPath: arguments[2])) },
                                   makeCodingShell: { BuddyWorkerProcess(resource: URL(fileURLWithPath: arguments[3]), runtime: URL(fileURLWithPath: arguments[4])) },
                                   makeClaude: { BuddyWorkerProcess(resource: URL(fileURLWithPath: arguments[1]), runtime: URL(fileURLWithPath: arguments[2])) },
                                   keyReader: { _ in "inert-fixture-key" }, credentials: saved)
        host.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer { host.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)) }

        func worker(_ payload: [String: Any]) async throws -> [String: Any] { try await BuddyWorkerClient.call(support: support, payload: payload.merging(["workspace": workspace]) { old, _ in old }) }
        func start(_ goal: String, as agent: String, request: String, kind: String = "coding") async throws -> String {
            let reply = kind == "coding" ? try await worker(["operation": "coding", "agentId": agent, "requestId": request, "arguments": ["action": "start", "title": "Sign-in fixture", "goal": goal]])
                : try await worker(["operation": "create", "agentId": agent, "requestId": request, "title": "Sign-in fixture", "goal": goal, "kind": kind])
            return (reply["task"] as? [String: Any])?["id"] as? String ?? ""
        }
        func detail(_ id: String) async throws -> [String: Any] { (try await worker(["operation": "detail", "taskId": id]))["task"] as? [String: Any] ?? [:] }
        func poll(_ id: String, _ label: String, seconds: Double = 30, _ done: ([String: Any]) -> Bool) async throws -> [String: Any] {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline { let value = try await detail(id); if done(value) { return value }; try await Task.sleep(nanoseconds: 50_000_000) }
            let last = try await detail(id)
            throw Failed(message: "\(label) (last seen: \(last["status"] ?? "") / \(last["stopCause"] ?? "-") / \(last["progress"] ?? ""))")
        }
        func status() async throws -> [String: Any] { try await worker(["operation": "status"]) }
        func decisions(_ id: String) async throws -> [[String: Any]] { ((try await status())["decisions"] as? [[String: Any]] ?? []).filter { $0["taskId"] as? String == id } }
        func laneOnline() async throws -> Bool { ((try await status())["supervisorLane"] as? [String: Any])?["online"] as? Bool == true }
        func waitForLane(_ online: Bool) async throws {
            for _ in 0..<300 { if try await laneOnline() == online { return }; try await Task.sleep(nanoseconds: 100_000_000) }
            throw Failed(message: "the supervisor lane did not become \(online ? "online" : "offline")")
        }
        func reviews(_ job: [String: Any]) -> [[String: Any]] { job["reviews"] as? [[String: Any]] ?? [] }
        func pending(_ job: [String: Any]) -> [String: Any]? { reviews(job).last { $0["status"] as? String == "pending" } }
        func answer(_ id: String, _ review: [String: Any], accept: Bool) async throws {
            _ = try await worker(["operation": "review", "taskId": id, "id": review["id"] ?? "", "answers": ["command": [accept ? "Accept" : "Decline"]], "accept": accept])
        }
        func text(_ value: Any?) -> String { value as? String ?? "" }
        func json(_ value: Any) -> String { (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "" }
        func lines(_ url: URL) -> [[String: Any]] { ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } }
        func fixture(_ kind: String) -> [[String: Any]] { lines(fixtureLog).filter { $0["kind"] as? String == kind }.compactMap { $0["value"] as? [String: Any] } }
        func toolResult(_ call: String) -> [String: Any]? { fixture("result").last { $0["id"] as? String == call }?["result"] as? [String: Any] }
        func waitFor(_ label: String, seconds: Double = 30, _ ok: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline { if ok() { return }; try await Task.sleep(nanoseconds: 50_000_000) }
            throw Failed(message: label)
        }
        func codexLog(_ id: String) -> [[String: Any]] { lines(support.appendingPathComponent("Worker/Tasks/\(id)/Conversation/Conversations/codex-fixture.jsonl")) }
        func project(_ id: String) -> URL { support.appendingPathComponent("Worker/Tasks/\(id)/Files", isDirectory: true) }
        /// Every decision ever opened for a task, open or settled, from the worker's own records.
        func everyDecision(_ id: String) throws -> [(kind: String, audience: String)] {
            let db = try BuddyOperationsDB(directory: support.appendingPathComponent("Worker"), existing: true)
            return try db.rows("SELECT kind, audience FROM decisions WHERE task_id = ?", [.text(id)]).map { ($0[0].string ?? "", $0[1].string ?? "") }
        }
        /// Work an earlier section left unfinished (only when that section failed) is cancelled, so it cannot hold the queue for the next one.
        func clearQueue() async throws {
            for task in (try await status())["tasks"] as? [[String: Any]] ?? [] where ["queued", "running", "waiting_review", "waiting_user", "starting"].contains(task["status"] as? String ?? "") {
                _ = try? await worker(["operation": "cancel", "taskId": task["id"] ?? ""])
            }
        }
        let envCommand = "node -e 'const c=require(\"crypto\");const u=process.env.PGUSER||\"\",p=process.env.PGPASSWORD||\"\";setTimeout(()=>{console.log(\"user=\"+u+\" pass=\"+p);console.log(\"digest=\"+c.createHash(\"sha256\").update(u+\":\"+p).digest(\"hex\"))},3000)'"
        let digest = SHA256.hash(data: Data((username + ":" + password).utf8)).map { String(format: "%02x", $0) }.joined()
        let note = "[Buddy] Your WRDS sign-in is saved. Run the command with credential \"wrds\"; Buddy fills it in and the user approves the Duo push."

        // MARK: the sign-in handoff

        var signinID = ""
        await section("buddy_request_signin with nothing saved parks the coding task for the USER, never the supervisor, with need credential") {
            signinID = try await start("SIGNIN_FIXTURE: run the OptionMetrics SPX skew extract.", as: clara, request: "signin")
            let waiting = try await poll(signinID, "the task waits for the user once the attempt has ended") { $0["status"] as? String == "waiting_user" && ($0["remainingBudgetUSD"] as? Double ?? 0) > 0 }
            let point = waiting["checkpoint"] as? [String: Any] ?? [:]
            try require(waiting["supervisorId"] as? String == chief, "the task has a supervisor, so a question could have gone to Chief: \(waiting["supervisorId"] ?? "-")")
            try require(point["need"] as? String == "credential" && point["profile"] as? String == "wrds" && point["routedTo"] as? String == "user" && waiting["stopCause"] as? String == "checkpoint.user",
                        "need credential for wrds, routed to the user: \(point) \(waiting["stopCause"] ?? "-")")
            try require(text(waiting["progress"]).contains("WRDS needs your sign-in"), "the task says what it waits for: \(waiting["progress"] ?? "")")
            let asked = toolResult("ask") ?? [:]
            try require(asked["status"] as? String == "needs_user" && asked["paused"] as? Bool == true, "the agent is told to stop and wait: \(asked)")
            let start = fixture("start").first ?? [:]
            try require((start["tools"] as? [String] ?? []).contains("buddy_request_signin") && (start["tools"] as? [String] ?? []).contains("buddy_coding_command"), "a Claude coding session has the sign-in and command tools: \(start["tools"] ?? [])")
            let brief = text(start["instructions"])
            try require(brief.contains("buddy_request_signin") && brief.contains("credential") && brief.contains("Never ask the user for a username, password or code in chat"), "the coding brief says to use buddy_request_signin, never chat: \(brief.suffix(900))")
        }
        await section("its Needs card says “WRDS needs your sign-in” with a Sign in action for the user, and nothing goes to the supervisor") {
            let open = try await decisions(signinID)
            try require(open.count == 1, "one card for the task: \(open)")
            let card = open.first ?? [:], payload = card["payload"] as? [String: Any] ?? [:]
            try require(card["kind"] as? String == "credential" && card["audience"] as? String == "user" && card["title"] as? String == "WRDS needs your sign-in" && card["actionLabel"] as? String == "Sign in"
                        && payload["profile"] as? String == "wrds" && payload["taskId"] as? String == signinID, "the sign-in card: \(card)")
            let every = try everyDecision(signinID)
            try require(every.allSatisfy { $0.audience == "user" }, "no decision for this task ever went to the supervisor: \(every)")
        }
        await section("the chat's sign-in field saves into the store, its reply never carries the sign-in, and saving resumes the task with the plain update") {
            // The person types the username and password into the request in the agent's chat; the page hands both to the app's sign-in
            // bridge, which keeps them in the store. There is no other way in: without typed values nothing is saved and no box opens.
            var refusedEmpty = false
            do { _ = try await BuddySignInBox.handle(["action": "provide", "profile": "wrds", "taskId": signinID], workspace: workspace, support: support, store: saved) } catch { refusedEmpty = true }
            try require(refusedEmpty && saved.items.isEmpty, "nothing typed, nothing saved")
            try require((try await detail(signinID))["status"] as? String == "waiting_user", "and the task keeps waiting")
            let reply = try await BuddySignInBox.handle(["action": "provide", "profile": "wrds", "taskId": signinID, "username": username, "password": password], workspace: workspace, support: support, store: saved)
            let said = json(reply)
            try require(!said.contains(username) && !said.contains(password), "the reply to the page carries no sign-in: \(said)")
            try require(reply["saved"] as? Bool == true && reply["resumed"] as? Bool == true, "saved, and the waiting task resumed: \(said)")
            try require(saved.items[workspace + ":wrds"]?.username == username && saved.items[workspace + ":wrds"]?.password == password && saved.reads == 0, "the store has it, and nothing read it yet")
            let listed = try await BuddySignInBox.handle(["action": "status"], workspace: workspace, support: support, store: saved)
            try require(!json(listed).contains(username) && !json(listed).contains(password) && ((listed["profiles"] as? [[String: Any]])?.first?["saved"] as? Bool) == true, "the status reply says saved, nothing more: \(json(listed))")
            let resumed = try await detail(signinID)
            try require((resumed["updates"] as? [String])?.last == note, "the plain update the model can read: \(resumed["updates"] ?? [])")
            var refused = false
            do { _ = try await worker(["operation": "signin", "actorId": clara, "arguments": ["action": "saved", "profile": "wrds", "taskId": signinID]]) } catch { refused = true }
            try require(refused, "an agent cannot use the person's sign-in step to resume a task")
            for action in ["secret", "check", "done"] {
                var refusedAgent = false
                do { _ = try await worker(["operation": "signin", "actorId": clara, "arguments": ["action": action, "taskId": signinID, "reviewId": "any", "value": password]]) } catch { refusedAgent = true }
                try require(refusedAgent, "an agent cannot send a typed sign-in or press Done (\(action))")
            }
            try require(BuddySignInBox.workerRefuses(["operation": "signin", "arguments": ["action": "provide", "username": username, "password": password]]), "the page's general worker bridge never carries a typed sign-in")
        }
        await section("with a saved sign-in buddy_request_signin returns available at once, without the sign-in; the resumed brief labels the note as Buddy's") {
            try await waitFor("the resumed attempt asked again") { toolResult("ask2") != nil }
            let again = toolResult("ask2") ?? [:]
            try require(again["status"] as? String == "available" && !json(again).contains(username) && !json(again).contains(password), "available, nothing secret: \(again)")
            let prompt = text(fixture("start").last?["prompt"])
            try require(prompt.contains("Note from Buddy (not from the user):\n" + note), "Buddy's note is not presented as the user's words: \(prompt.suffix(500))")
        }
        await section("a credentialed command waits for the native review, which says in plain words that it signs in to WRDS; a declined review never reads the Keychain") {
            let first = try await poll(signinID, "the credentialed command waits for review") { pending($0) != nil }
            let review = pending(first) ?? [:], tool = review["tool"] as? [String: Any] ?? [:], args = tool["arguments"] as? [String: Any] ?? [:]
            try require(review["kind"] as? String == "coding" && text(args["sign_in"]).hasPrefix("This command signs in to WRDS with your saved sign-in") && text(args["command"]) == envCommand,
                        "the review card: \(tool)")
            try require(review["route"] as? String == "user", "a command with a sign-in is never the supervisor's: \(review["route"] ?? "-")")
            try require(saved.reads == 0 && !FileManager.default.fileExists(atPath: project(signinID).appendingPathComponent("never.txt").path), "nothing was read before the review: \(saved.reads)")
            try await answer(signinID, review, accept: false)
            let second = try await poll(signinID, "the agent asks once more after the decline") { job in reviews(job).count == 2 && pending(job) != nil }
            try require(saved.reads == 0, "a declined review never reads the Keychain: \(saved.reads) reads")
            let declined = reviews(second).first ?? [:]
            try require(declined["status"] as? String == "cancelled" && declined["answeredBy"] as? String == "user" && !text(declined["answeredAt"]).isEmpty, "the declined review records who answered: \(declined)")
            try require(((second["commands"] as? [[String: Any]]) ?? []).isEmpty, "the declined command left no receipt: \(second["commands"] ?? [])")
            try await answer(signinID, pending(second) ?? [:], accept: true)
        }
        await section("while the WRDS command runs the task says “Waiting for your Duo approval” and a Needs item asks to approve the push; both clear when it ends, with no stall stop") {
            let waiting = try await poll(signinID, "the Duo wait shows while the command runs") { $0["progress"] as? String == "Waiting for your Duo approval" }
            try require(waiting["status"] as? String == "running", "it is running: \(waiting["status"] ?? "")")
            let duo = try await decisions(signinID).first { $0["kind"] as? String == "mfa" } ?? [:]
            try require(duo["title"] as? String == "Approve the WRDS Duo push on your phone" && duo["audience"] as? String == "user", "the Duo item: \(duo)")
            // Three minutes of silence while the push waits is not a stalled connection.
            host.testingAgeActivity(by: 400)
            let done = try await poll(signinID, "the task finishes", seconds: 40) { ["completed", "failed", "interrupted", "paused"].contains($0["status"] as? String ?? "") }
            try require(done["status"] as? String == "completed" && done["stopCause"] as? String ?? "" == "", "it completed, not stopped as a stall: \(done["status"] ?? "") \(done["stopCause"] ?? "") \(done["progress"] ?? "")")
            let after = try await decisions(signinID), every = try everyDecision(signinID)
            try require(after.isEmpty && (done["mfaWait"] == nil || done["mfaWait"] is NSNull), "the Duo item cleared itself: \(after) \(done["mfaWait"] ?? "-")")
            try require(every.contains { $0.kind == "mfa" && $0.audience == "user" }, "it was there while the command ran: \(every)")
        }
        await section("after approval the sign-in reaches only that command's environment; its output is hidden in the receipt and in the tool result") {
            let job = try await detail(signinID), commands = job["commands"] as? [[String: Any]] ?? []
            try require(saved.reads == 1, "the Keychain was read once, for the approved command: \(saved.reads)")
            let signed = commands.first { $0["credential"] as? String == "wrds" } ?? [:], plain = commands.first { $0["credential"] == nil } ?? [:]
            try require(text(signed["output"]).contains("user=[hidden] pass=[hidden]") && text(signed["output"]).contains("digest=" + digest), "the exact sign-in reached the command and is hidden in its receipt: \(signed["output"] ?? "")")
            try require(text(signed["code"]) == envCommand && signed["network"] as? Bool == true && signed["exitCode"] as? Int == 0 && signed["timeoutSeconds"] as? Int == 300, "the receipt keeps the command, not the sign-in: \(signed.filter { $0.key != "output" })")
            try require(text(plain["output"]) == "plain user=undefined pass=undefined\n", "a later command has none of it: \(plain["output"] ?? "")")
            let result = toolResult("cred2") ?? [:]
            try require(text(result["output"]).contains("user=[hidden] pass=[hidden]") && !json(result).contains(username) && !json(result).contains(password), "the model sees it hidden: \(result)")
            try require(text(job["result"]).hasPrefix("Ran the extract with the saved sign-in"), "the task's result: \(job["result"] ?? "")")
            let approved = reviews(job).last ?? [:]
            try require(approved["status"] as? String == "completed" && approved["answeredBy"] as? String == "user" && approved["answeredByName"] as? String == "you", "the approved review: \(approved)")
        }
        await section("a background task asks with buddy_request_signin too, and waits for the user") {
            try await clearQueue()
            saved.items.removeAll()
            let id = try await start("Look up the WRDS data dictionary.", as: bea, request: "background", kind: "research")
            let waiting = try await poll(id, "the background task waits for the user") { $0["status"] as? String == "waiting_user" && ($0["remainingBudgetUSD"] as? Double ?? 0) > 0 }
            let point = waiting["checkpoint"] as? [String: Any] ?? [:]
            let cards = try await decisions(id)
            try require(point["need"] as? String == "credential" && point["routedTo"] as? String == "user" && cards.first?["kind"] as? String == "credential", "need credential for the user: \(point) \(cards)")
            try require(BuddyWorkerHost.tools.contains { $0["name"] as? String == "buddy_request_signin" }, "background tasks are offered the tool")
            _ = try await worker(["operation": "cancel", "taskId": id])
            try saved.save(workspace: workspace, profile: "wrds", username: username, password: password)
        }
        await section("a Codex coding thread gets buddy_coding_command with credential, runs the signed-in command through Buddy's shell after review, and keeps its own shell for the rest") {
            try await clearQueue()
            let id = try await start("CODEX_SIGNIN: run the WRDS extract.", as: forge, request: "codex-signin")
            let waiting = try await poll(id, "the Codex credentialed command waits for review") { pending($0) != nil }
            let thread = codexLog(id).filter { $0["kind"] as? String == "request" }.compactMap { $0["value"] as? [String: Any] }.first { $0["method"] as? String == "thread/start" }?["params"] as? [String: Any] ?? [:]
            let tools = thread["dynamicTools"] as? [[String: Any]] ?? []
            let command = tools.first { $0["name"] as? String == "buddy_coding_command" } ?? [:], schema = command["inputSchema"] as? [String: Any] ?? [:]
            try require(((schema["properties"] as? [String: Any])?["credential"]) != nil && (schema["required"] as? [String] ?? []).contains("credential") && tools.contains { $0["name"] as? String == "buddy_request_signin" },
                        "the thread's tools: \(tools.compactMap { $0["name"] as? String })")
            try require(text(thread["developerInstructions"]).contains("buddy_request_signin") && !text(thread["developerInstructions"]).contains("Claude"), "Codex's brief says how to sign in")
            let refusedPlain = codexLog(id).filter { $0["kind"] as? String == "tool-result" }.compactMap { $0["value"] as? [String: Any] }.first { $0["call"] as? String == "plain" } ?? [:]
            try require(refusedPlain["success"] as? Bool == false, "a command without a sign-in is refused there (Codex uses its own shell): \(refusedPlain)")
            let reads = saved.reads
            try await answer(id, pending(waiting) ?? [:], accept: true)
            let done = try await poll(id, "the Codex task finishes") { ["completed", "failed", "interrupted", "paused", "waiting_user"].contains($0["status"] as? String ?? "") }
            try require(done["status"] as? String == "completed" && saved.reads == reads + 1, "it completed after one read: \(done["status"] ?? "") \(done["progress"] ?? "") reads \(saved.reads - reads)")
            let commands = done["commands"] as? [[String: Any]] ?? []
            let signed = commands.first { $0["credential"] as? String == "wrds" } ?? [:]
            try require(text(signed["output"]) == "codex user=[hidden] pass=[hidden]\n" && commands.contains { $0["id"] as? String == "cmd-after" }, "Buddy's receipt survives beside Codex's own: \(commands)")
            let result = codexLog(id).filter { $0["kind"] as? String == "tool-result" }.compactMap { $0["value"] as? [String: Any] }.first { $0["call"] as? String == "credential" } ?? [:]
            try require(result["success"] as? Bool == true && text((result["value"] as? [String: Any])?["output"]).contains("[hidden]") && !json(result).contains(username) && !json(result).contains(password), "the model sees it hidden: \(result)")
        }

        // MARK: supervisor approval of routine coding commands

        await section("Forge's real CBOE download (a Codex escalation) is routine: Chief approves it, it runs, the user never gets a needs-you item, and the review says who approved it") {
            try await clearQueue()
            try await waitForLane(true)
            let id = try await start("CODEX_CBOE: get the public SPX history for stage 3.", as: forge, request: "cboe")
            let done = try await poll(id, "the routine download finishes after the supervisor's answer", seconds: 60) { ["completed", "failed", "interrupted", "paused", "waiting_user"].contains($0["status"] as? String ?? "") }
            try require(done["status"] as? String == "completed", "completed: \(done["status"] ?? "") \(done["progress"] ?? "")")
            let review = reviews(done).first ?? [:]
            try require(review["route"] as? String == "supervisor" && review["status"] as? String == "completed" && review["answeredBy"] as? String == "supervisor" && review["answeredByName"] as? String == "Chief"
                        && !text(review["answerReason"]).isEmpty && !text(review["answeredAt"]).isEmpty, "Chief's answer is on the review: \(review)")
            try require(FileManager.default.fileExists(atPath: project(id).appendingPathComponent("verification/stage3_public_inputs/raw/SPX_CBOE.csv").path), "the approved command ran")
            let every = try everyDecision(id)
            try require(every.contains { $0.kind == "command_review" && $0.audience == "supervisor" } && !every.contains { $0.audience == "user" }, "it went to the supervisor and never to the user: \(every)")
            let shown = fixture("supervisor").flatMap { $0["items"] as? [[String: Any]] ?? [] }.first { $0["kind"] as? String == "command_review" } ?? [:], what = shown["command"] as? [String: Any] ?? [:]
            try require(text(what["command"]).contains("https://cdn.cboe.com/api/global/us_indices/daily_prices/SPX_History.csv") && (what["hosts"] as? [String]) == ["cdn.cboe.com"]
                        && (what["writes"] as? [String]) == ["verification/stage3_public_inputs/raw/SPX_CBOE.csv"] && text(what["reason"]).contains("SPX history"), "Chief saw the exact command, host, where it writes and why: \(shown)")
            let enumerated = fixture("supervisor").first?["enum"] as? [String] ?? []
            try require(enumerated.contains("approve_command") && enumerated.contains("decline_command"), "the lane has the two verbs: \(enumerated)")
        }
        await section("an upload is sensitive: it stays with the user, and the supervisor never sees it") {
            try await clearQueue()
            let id = try await start("CODEX_UPLOAD: share the results.", as: forge, request: "upload")
            let waiting = try await poll(id, "the upload waits for the user") { pending($0) != nil }
            let review = pending(waiting) ?? [:]
            let open = try await decisions(id)
            try require(review["route"] as? String == "user" && open.contains { $0["kind"] as? String == "review" && $0["audience"] as? String == "user" }, "the user's review: \(review["route"] ?? "-") \(open)")
            try await answer(id, review, accept: false)
            let done = try await poll(id, "the declined upload ends") { ["completed", "failed"].contains($0["status"] as? String ?? "") }
            try require(!FileManager.default.fileExists(atPath: project(id).appendingPathComponent("uploaded.txt").path) && reviews(done).first?["answeredBy"] as? String == "user", "it did not run; the user answered")
            try require(!fixture("supervisor").flatMap { $0["items"] as? [[String: Any]] ?? [] }.contains { $0["workerTaskId"] as? String == id || json($0).contains("upload.example.org") }, "Chief never saw it")
        }
        await section("a Claude coding command with network that is routine goes to the supervisor too, who can decline it; it does not run") {
            try await clearQueue()
            let id = try await start("NETWORK_ROUTINE_FIXTURE: fetch the VIX history.", as: clara, request: "routine-claude")
            let done = try await poll(id, "the declined routine command ends", seconds: 60) { ["completed", "failed", "interrupted", "paused", "waiting_user"].contains($0["status"] as? String ?? "") }
            let review = reviews(done).first ?? [:]
            try require(review["route"] as? String == "supervisor" && review["status"] as? String == "cancelled" && review["answeredBy"] as? String == "supervisor" && review["answeredByName"] as? String == "Chief", "Chief declined it: \(review)")
            try require(!FileManager.default.fileExists(atPath: project(id).appendingPathComponent("data/vix.csv").path) && ((done["commands"] as? [[String: Any]]) ?? []).isEmpty && text(done["result"]).contains("declined"), "it did not run: \(done["result"] ?? "")")
            try require(!(try everyDecision(id)).contains { $0.audience == "user" }, "the user was never asked")
        }
        await section("with the supervisor lane offline (its daily limit used up), a routine command review falls back to the user") {
            try await clearQueue()
            _ = try await worker(["operation": "limit", "scope": "agent", "agentId": chief, "amountUSD": 0.01])
            try await waitForLane(false)
            let id = try await start("CODEX_CBOE: get the public SPX history again.", as: forge, request: "cboe-offline")
            let waiting = try await poll(id, "the review waits") { pending($0) != nil }
            let review = pending(waiting) ?? [:]
            let open = try await decisions(id)
            try require(review["route"] as? String == "user" && open.contains { $0["kind"] as? String == "review" && $0["audience"] as? String == "user" }, "it is the user's: \(review["route"] ?? "-") \(open)")
            try await answer(id, review, accept: true)
            let done = try await poll(id, "it runs after the user's answer") { ["completed", "failed"].contains($0["status"] as? String ?? "") }
            try require(done["status"] as? String == "completed" && reviews(done).first?["answeredBy"] as? String == "user", "the user approved it: \(reviews(done).first ?? [:])")
            _ = try await worker(["operation": "limit", "scope": "agent", "agentId": chief, "amountUSD": NSNull()])
        }

        // MARK: nothing secret anywhere

        await section("the sign-in appears nowhere: not in any file under the support folder (tasks, events, receipts, logs), nor in anything the model side received") {
            var found: [String] = []
            let needles = [username, password].flatMap { [$0, $0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0] }.map { Data($0.utf8) }
            var checked = 0
            for root in [support, logs] {
                guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
                for case let url as URL in walk {
                    guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true, let data = try? Data(contentsOf: url) else { continue }
                    checked += 1
                    if needles.contains(where: { data.range(of: $0) != nil }) { found.append(url.path.replacingOccurrences(of: base.path, with: "")) }
                }
            }
            try require(checked > 10 && found.isEmpty, "checked \(checked) files; the sign-in was found in: \(found)")
            let page = json(try await detail(signinID))
            try require(!page.contains(password) && !page.contains(username), "nor in the task as the page reads it")
        }

        // MARK: the Keychain store itself

        await section("the Keychain store keeps one generic password per workspace:profile with {username, password}; has() reads no secret (test-only service)") {
            let store = BuddyCredentials(service: "app.buddy.signin.test-" + UUID().uuidString), space = UUID().uuidString
            defer { try? store.remove(workspace: space, profile: "wrds") }
            try require(!store.has(workspace: space, profile: "wrds") && store.read(workspace: space, profile: "wrds") == nil, "nothing saved yet")
            try store.save(workspace: space, profile: "wrds", username: "kc-fixture", password: "kc-fixture-pw-1")
            try require(store.has(workspace: space, profile: "wrds") && store.read(workspace: space, profile: "wrds")?.password == "kc-fixture-pw-1", "saved and read back")
            var found: CFTypeRef?
            let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: store.service, kSecAttrAccount: space + ":wrds", kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
            let code = SecItemCopyMatching(query as CFDictionary, &found)
            let item = (found as? Data).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] } ?? [:]
            try require(code == errSecSuccess && item == ["username": "kc-fixture", "password": "kc-fixture-pw-1"], "one item, account <workspace>:wrds, JSON {username, password}: \(code) \(item)")
            try store.save(workspace: space, profile: "wrds", username: "kc-fixture", password: "kc-fixture-pw-2")
            try require(store.read(workspace: space, profile: "wrds")?.password == "kc-fixture-pw-2", "saving again replaces it")
            try store.remove(workspace: space, profile: "wrds")
            try require(!store.has(workspace: space, profile: "wrds") && store.read(workspace: space, profile: "wrds") == nil, "removed")
            try require(BuddyCredentials().service == "app.buddy.signin" && BuddyCredentials.profile("wrds")?.name == "WRDS" && BuddyCredentials.profile("wrds")?.mfa == "duo-push"
                        && BuddyCredentials.profile("wrds")?.env == ["username": "PGUSER", "password": "PGPASSWORD"] && BuddyCredentials.profile("nope") == nil, "the built-in WRDS profile")
        }

        if !failures.isEmpty { fputs("FAILED: \(failures.count) sign-in and command review check(s) failed\n", stderr); exit(1) }
    }
}
