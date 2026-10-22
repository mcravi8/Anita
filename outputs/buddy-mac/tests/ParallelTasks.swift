import AppKit
import Darwin

/// Several background tasks at once, end to end through the real worker: its socket, queue, dispatcher, recovery and plan loop, the Claude
/// coding bridge protocol (tests/coding-claude.py, which can hold an attempt open until this test releases it) and Buddy's sandboxed command
/// runner (coding-shell.mjs, so commands really run). Every agent codes on Claude here. Each section reports on its own, so a run shows every
/// check that fails, not only the first. Run by run-tests.py with: the Claude stand-in, python3, coding-shell.mjs, node.
@main struct ParallelTaskChecks {
    struct Failed: Error { let message: String }
    static func require(_ value: Bool, _ message: @autoclosure () -> String) throws { if !value { throw Failed(message: message()) } }
    @MainActor static var failures: [String] = []
    @MainActor static func section(_ name: String, _ body: () async throws -> Void) async {
        do { try await body(); print("PASS: " + name) }
        catch let failed as Failed { failures.append(name); fputs("FAILED: \(name): \(failed.message)\n", stderr) }
        catch { failures.append(name); fputs("FAILED: \(name): \(error.localizedDescription)\n", stderr) }
    }

    @MainActor static func main() async throws {
        let arguments = CommandLine.arguments   // [1] the Claude coding stand-in, [2] python3, [3] coding-shell.mjs, [4] node
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("buddy-parallel-" + UUID().uuidString + ".noindex")
        let support = base.appendingPathComponent("Support", isDirectory: true), holds = base.appendingPathComponent("Holds", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true); try FileManager.default.createDirectory(at: holds, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        setenv("BUDDY_HOLD_FIXTURE_DIR", holds.path, 1)
        let workspace = UUID().uuidString, forge = UUID().uuidString, vera = UUID().uuidString, ada = UUID().uuidString, lead = UUID().uuidString, team = UUID().uuidString
        try JSONSerialization.data(withJSONObject: ["conversationWorkspace": workspace, "agents": [
            ["id": lead, "name": "Lead", "role": "Supervisor", "description": "Looks after the fixture team", "tools": [String: Bool]()],
            ["id": forge, "name": "Forge", "role": "Engineer", "description": "Builds fixtures", "tools": [String: Bool]()],
            ["id": vera, "name": "Vera", "role": "Researcher", "description": "Checks fixtures", "tools": [String: Bool]()],
            ["id": ada, "name": "Ada", "role": "Engineer", "description": "Builds more fixtures", "tools": [String: Bool]()]],
            "groups": [["id": team, "name": "Fixture team", "members": [lead, forge, vera, ada], "managedBy": lead]]]).write(to: support.appendingPathComponent("workspace.json"))
        let models = BuddyAgentModels(support: support)
        for agent in [lead, forge, vera, ada] { try models.set(workspace: workspace, agent: agent, selection: .init(provider: "claude", model: "claude-fixture")) }
        func makeHost() -> BuddyWorkerHost {
            BuddyWorkerHost(support: support,
                            makeCoding: { BuddyWorkerProcess(resource: URL(fileURLWithPath: arguments[1]), runtime: URL(fileURLWithPath: arguments[2])) },
                            makeCodingShell: { BuddyWorkerProcess(resource: URL(fileURLWithPath: arguments[3]), runtime: URL(fileURLWithPath: arguments[4])) },
                            makeClaude: { BuddyWorkerProcess(resource: URL(fileURLWithPath: arguments[1]), runtime: URL(fileURLWithPath: arguments[2])) },
                            keyReader: { _ in "inert-fixture-key" })
        }
        var host = makeHost()
        host.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer { host.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)) }

        func worker(_ payload: [String: Any]) async throws -> [String: Any] { try await BuddyWorkerClient.call(support: support, payload: payload.merging(["workspace": workspace]) { old, _ in old }) }
        func refused(_ payload: [String: Any]) async -> Bool { do { _ = try await worker(payload); return false } catch { return true } }
        func start(_ goal: String, as agent: String, request: String) async throws -> String {
            let reply = try await worker(["operation": "coding", "agentId": agent, "requestId": request, "arguments": ["action": "start", "title": "Parallel fixture", "goal": goal]])
            guard let id = (reply["task"] as? [String: Any])?["id"] as? String else { throw Failed(message: "the task was not created: \(reply)") }
            return id
        }
        func detail(_ id: String) async throws -> [String: Any] { (try await worker(["operation": "detail", "taskId": id]))["task"] as? [String: Any] ?? [:] }
        func status() async throws -> [String: Any] { try await worker(["operation": "status"]) }
        func text(_ value: Any?) -> String { value as? String ?? "" }
        func poll(_ id: String, _ label: String, seconds: Double = 30, _ done: ([String: Any]) -> Bool) async throws -> [String: Any] {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline { let value = try await detail(id); if done(value) { return value }; try await Task.sleep(nanoseconds: 50_000_000) }
            let last = try await detail(id)
            throw Failed(message: "\(label) (last seen: \(last["status"] ?? "") / \(last["stopCause"] ?? "-") / \(last["progress"] ?? ""))")
        }
        func waitFor(_ label: String, seconds: Double = 30, _ ok: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline { if ok() { return }; try await Task.sleep(nanoseconds: 50_000_000) }
            throw Failed(message: label)
        }
        /// What the stand-in wrote when an attempt started (`start`) or finished (`end`): when, its process, the budget it was given.
        func mark(_ name: String, _ kind: String = "start") -> [String: Any]? {
            (try? Data(contentsOf: holds.appendingPathComponent(name + "." + kind))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
        func at(_ name: String, _ kind: String) -> Double { (mark(name, kind)?["at"] as? NSNumber)?.doubleValue ?? -1 }
        func release(_ name: String) { FileManager.default.createFile(atPath: holds.appendingPathComponent(name + ".release").path, contents: Data()) }
        func pid(_ name: String) -> Int32 { (mark(name)?["pid"] as? NSNumber).map { Int32(truncating: $0) } ?? 0 }
        func alive(_ pid: Int32) -> Bool { pid > 0 && kill(pid, 0) == 0 }
        func project(_ id: String) -> URL { support.appendingPathComponent("Worker/Tasks/\(id)/Files", isDirectory: true) }
        func settled(_ job: [String: Any]) -> Bool { ["completed", "failed", "paused", "interrupted", "waiting_user", "waiting_review", "cancelled"].contains(text(job["status"])) }
        func cancel(_ id: String, as agent: String) async throws { _ = try await worker(["operation": "coding", "agentId": agent, "requestId": "cancel-" + id, "arguments": ["action": "cancel", "taskId": id]]) }
        func pulse() async throws -> [String: String] { (((try await status())["pulse"] as? [String: Any])?["agents"] as? [String: Any] ?? [:]).compactMapValues { ($0 as? [String: Any])?["state"] as? String } }
        /// Work an earlier section left unfinished (only when that section failed) is cancelled, so it cannot hold a slot in the next one.
        func clearQueue() async throws {
            for task in (try await status())["tasks"] as? [[String: Any]] ?? [] where ["queued", "running", "waiting_review", "waiting_user", "starting", "paused", "failed", "interrupted"].contains(text(task["status"])) {
                _ = try? await worker(["operation": "cancel", "taskId": task["id"] ?? ""])
            }
            for _ in 0..<100 { if ((try await status())["running"] as? [String] ?? ["?"]).isEmpty { return }; try await Task.sleep(nanoseconds: 50_000_000) }
        }
        func runLimit(_ value: Any) async throws -> [String: Any] { try await worker(["operation": "maxRunning", "value": value]) }

        // 1. How many tasks may run at once is the person's setting (Background work), from 1 to 6, and 3 until they choose.
        await section("Run at once is the person's setting from 1 to 6, 3 until they choose; an agent cannot change it") {
            let first = try await status()
            try require(first["maxRunning"] as? Int == 3 && (first["running"] as? [String])?.isEmpty == true, "three at once by default, nothing running yet: \(first["maxRunning"] ?? "-") \(first["running"] ?? "-")")
            for bad: Any in [0, 7, "two", 2.5, -1] { try require(await refused(["operation": "maxRunning", "value": bad]), "\(bad) is refused") }
            try require(await refused(["operation": "maxRunning", "value": 2, "actorId": forge, "authorizedText": "run two at once"]), "an agent's request is refused, whatever the person said")
            let two = try await runLimit(2)
            let shown = try await status()
            try require(two["maxRunning"] as? Int == 2 && shown["maxRunning"] as? Int == 2, "the person sets two: \(two)")
            let saved = try BuddyOperationsDB(directory: support.appendingPathComponent("Worker"), existing: true).meta("maxRunning")
            try require(saved == "2", "it is saved with the queue, so a restart keeps it: \(saved ?? "-")")
            _ = try await runLimit(3)
        }

        // 2. Two agents' tasks run side by side: both running at once, each its own attempt, project and bridge.
        await section("two tasks for two different agents run at the same time") {
            let a = try await start("HOLD_FIXTURE:two-a build the left half", as: forge, request: "two-a")
            let b = try await start("HOLD_FIXTURE:two-b build the right half", as: vera, request: "two-b")
            try await waitFor("both attempts start without waiting for each other") { mark("two-a") != nil && mark("two-b") != nil }
            let da = try await detail(a), db = try await detail(b)
            try require(text(da["status"]) == "running" && text(db["status"]) == "running", "both are running at once: \(da["status"] ?? "") \(db["status"] ?? "")")
            try require(!text(da["executionRunID"]).isEmpty && text(da["executionRunID"]) != text(db["executionRunID"]) && text(da["codingProject"]) != text(db["codingProject"]),
                        "each has its own attempt and project: \(da["executionRunID"] ?? "") \(db["executionRunID"] ?? "")")
            try require(pid("two-a") != pid("two-b") && alive(pid("two-a")) && alive(pid("two-b")), "and its own bridge process")
            let snap = try await status(), agents = (snap["pulse"] as? [String: Any])?["agents"] as? [String: Any] ?? [:]
            try require(Set(snap["running"] as? [String] ?? []) == Set([a, b]), "the status lists both as running: \(snap["running"] ?? "-")")
            try require((agents[forge] as? [String: Any])?["state"] as? String == "working" && (agents[vera] as? [String: Any])?["state"] as? String == "working"
                        && (agents[forge] as? [String: Any])?["taskId"] as? String == a && (agents[vera] as? [String: Any])?["taskId"] as? String == b, "the pulse shows both agents working on their own task: \(agents)")
            try require((snap["pulse"] as? [String: Any])?["idleSince"] is NSNull && (snap["pulse"] as? [String: Any])?["running"] as? Int == 2, "the team is busy, with two running")
            release("two-a"); release("two-b")
            _ = try await poll(a, "the first finishes") { text($0["status"]) == "completed" }
            _ = try await poll(b, "the second finishes") { text($0["status"]) == "completed" }
            try require(at("two-a", "start") < at("two-b", "end") && at("two-b", "start") < at("two-a", "end"), "their attempts overlapped in time: \(at("two-a", "start"))–\(at("two-a", "end")) and \(at("two-b", "start"))–\(at("two-b", "end"))")
        }
        try? await clearQueue()

        // 3. With room for two, the third waits; when a slot frees up the oldest queued task whose agent is free goes first.
        await section("with the limit at 2 a third task waits, and the oldest queued task whose agent is free goes next") {
            _ = try await runLimit(2)
            let a1 = try await start("HOLD_FIXTURE:lim-a1 first for Forge", as: forge, request: "lim-a1")
            let a2 = try await start("HOLD_FIXTURE:lim-a2 second for Forge", as: forge, request: "lim-a2")
            let b = try await start("HOLD_FIXTURE:lim-b for Vera", as: vera, request: "lim-b")
            let c = try await start("HOLD_FIXTURE:lim-c for Ada", as: ada, request: "lim-c")
            try await waitFor("Forge's first and Vera's start") { mark("lim-a1") != nil && mark("lim-b") != nil }
            try await Task.sleep(nanoseconds: 1_500_000_000)
            try require(mark("lim-a2") == nil && mark("lim-c") == nil, "nothing else starts while two run")
            let waitingA2 = try await detail(a2), waitingC = try await detail(c), states = try await pulse()
            try require(text(waitingA2["status"]) == "queued" && text(waitingC["status"]) == "queued", "the other two wait in the queue")
            try require(states[ada] == "queued", "Ada is shown queued: \(states)")
            release("lim-a1")
            try await waitFor("Forge's second, the oldest queued, starts once Forge is free") { mark("lim-a2") != nil }
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let stillC = try await detail(c)
            try require(mark("lim-c") == nil && text(stillC["status"]) == "queued", "Ada's still waits: two are running again")
            release("lim-b")
            try await waitFor("Ada's starts when Vera's slot frees up") { mark("lim-c") != nil }
            try require(at("lim-a2", "start") >= at("lim-a1", "end") && at("lim-c", "start") >= at("lim-b", "end"), "each started only after a slot freed up")
            release("lim-a2"); release("lim-c")
            for id in [a1, a2, b, c] { _ = try await poll(id, "every task finishes") { text($0["status"]) == "completed" } }
        }
        try? await clearQueue()
        _ = try? await runLimit(3)

        // 4. One agent is one worker: its second task waits for its first, even with free slots.
        await section("two tasks for the same agent never overlap, even with free slots") {
            let x = try await start("HOLD_FIXTURE:same-x first", as: forge, request: "same-x")
            let y = try await start("HOLD_FIXTURE:same-y second", as: forge, request: "same-y")
            try await waitFor("the first starts") { mark("same-x") != nil }
            try await Task.sleep(nanoseconds: 1_500_000_000)
            let second = try await detail(y)
            try require(mark("same-y") == nil && text(second["status"]) == "queued", "the second waits for its agent")
            release("same-x")
            try await waitFor("the second starts after the first") { mark("same-y") != nil }
            try require(at("same-y", "start") >= at("same-x", "end"), "they never overlapped: \(at("same-x", "end")) then \(at("same-y", "start"))")
            release("same-y")
            _ = try await poll(x, "the first finishes") { text($0["status"]) == "completed" }
            _ = try await poll(y, "the second finishes") { text($0["status"]) == "completed" }
        }
        try? await clearQueue()

        // 5. Stopping, pausing or stalling one run touches nothing of the other's.
        await section("cancelling one running task, or one going silent, leaves the other running") {
            let a = try await start("HOLD_FIXTURE:stop-a cancel me", as: forge, request: "stop-a")
            let b = try await start("HOLD_FIXTURE:stop-b keep me", as: vera, request: "stop-b")
            try await waitFor("both start") { mark("stop-a") != nil && mark("stop-b") != nil }
            try await cancel(a, as: forge)
            _ = try await poll(a, "the first is cancelled") { text($0["status"]) == "cancelled" }
            try await waitFor("the cancelled attempt's bridge closes") { !alive(pid("stop-a")) }
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let still = try await detail(b)
            try require(text(still["status"]) == "running" && alive(pid("stop-b")) && mark("stop-b", "end") == nil, "the other is still running on its own bridge: \(still["status"] ?? "") \(still["progress"] ?? "")")
            let c = try await start("HOLD_FIXTURE:stop-c go quiet", as: ada, request: "stop-c")
            try await waitFor("a third starts") { mark("stop-c") != nil }
            host.testingAgeActivity(by: 181, task: c)
            let stalled = try await poll(c, "the silent one is stopped as a stall") { settled($0) }
            try require(text(stalled["status"]) == "interrupted" && text(stalled["stopCause"]) == "stall", "a stall: \(stalled["status"] ?? "") \(stalled["stopCause"] ?? "-")")
            let after = try await detail(b)
            try require(text(after["status"]) == "running" && alive(pid("stop-b")), "the other is not a stall and keeps running: \(after["status"] ?? "") \(after["stopCause"] ?? "-")")
            let paused = try await worker(["operation": "pause", "taskId": b])
            try require((paused["task"] as? [String: Any])?["status"] as? String == "paused", "pausing works on that one task: \(paused)")
            try await cancel(c, as: ada)
        }
        try? await clearQueue()

        // 6. Two runs wait for a review at the same time; each answer reaches its own task only.
        await section("each review answer reaches the task it belongs to, and only that one") {
            let a = try await start("NETWORK_REVIEW_FIXTURE for Forge", as: forge, request: "review-a")
            let b = try await start("NETWORK_REVIEW_FIXTURE for Vera", as: vera, request: "review-b")
            let ra = try await poll(a, "Forge's command waits for review") { text($0["status"]) == "waiting_review" }
            let rb = try await poll(b, "Vera's command waits for review") { text($0["status"]) == "waiting_review" }
            let forgeReview = (ra["reviews"] as? [[String: Any]])?.last?["id"] as? String ?? "", veraReview = (rb["reviews"] as? [[String: Any]])?.last?["id"] as? String ?? ""
            try require(!forgeReview.isEmpty && !veraReview.isEmpty && forgeReview != veraReview, "two reviews wait at once")
            try require(await refused(["operation": "review", "taskId": b, "id": forgeReview, "accept": true]), "Forge's review cannot be answered through Vera's task")
            _ = try await worker(["operation": "review", "taskId": b, "id": veraReview, "accept": true])
            let vDone = try await poll(b, "Vera's approved command runs and the task finishes") { text($0["status"]) == "completed" }
            try require((try? String(contentsOf: project(b).appendingPathComponent("reviewed.txt"), encoding: .utf8)) == "approved" && ((vDone["reviews"] as? [[String: Any]])?.last?["status"] as? String) == "completed", "Vera's command ran in Vera's project")
            let fStill = try await detail(a)
            try require(text(fStill["status"]) == "waiting_review" && !FileManager.default.fileExists(atPath: project(a).appendingPathComponent("reviewed.txt").path)
                        && ((fStill["reviews"] as? [[String: Any]])?.last?["status"] as? String) == "pending", "Forge's review still waits and nothing ran for it: \(fStill["status"] ?? "")")
            _ = try await worker(["operation": "review", "taskId": a, "id": forgeReview, "accept": false])
            let fDone = try await poll(a, "Forge's declined command ends its task") { text($0["status"]) == "completed" }
            try require(!FileManager.default.fileExists(atPath: project(a).appendingPathComponent("reviewed.txt").path) && text(fDone["result"]).contains("declined"), "declined, it never ran: \(fDone["result"] ?? "")")
        }
        try? await clearQueue()

        // 7. A crash in one run (its command runner, or its model bridge) ends that run only.
        await section("a crash of one run's command runner or bridge fails only that run") {
            let a = try await start("SHELL_HOLD_FIXTURE:crash-a", as: forge, request: "crash-a")
            let b = try await start("SHELL_HOLD_FIXTURE:crash-b", as: vera, request: "crash-b")
            let pidFile = { (id: String) -> Int32 in Int32((try? String(contentsOf: project(id).appendingPathComponent("shell.pid"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0 }
            try await waitFor("both commands run at once, each in its own runner") { pidFile(a) > 0 && pidFile(b) > 0 }
            try require(pidFile(a) != pidFile(b) && alive(pidFile(a)) && alive(pidFile(b)), "two runners: \(pidFile(a)) \(pidFile(b))")
            kill(pidFile(a), SIGKILL)
            let failed = try await poll(a, "the run whose runner crashed fails") { settled($0) }
            try require(text(failed["status"]) == "failed" && text(failed["stopCause"]) == "provider.error", "it fails with a cause Buddy retries: \(failed["status"] ?? "") \(failed["stopCause"] ?? "-")")
            let done = try await poll(b, "the other run's command finishes and so does its task") { settled($0) }
            let receipt = (done["commands"] as? [[String: Any]] ?? []).last ?? [:]
            try require(text(done["status"]) == "completed" && receipt["exitCode"] as? Int == 0 && text(receipt["output"]).contains("held-crash-b"), "untouched: \(done["status"] ?? "") \(receipt)")
            try await cancel(a, as: forge)
            let c = try await start("HOLD_FIXTURE:crash-c", as: forge, request: "crash-c")
            let d = try await start("HOLD_FIXTURE:crash-d", as: vera, request: "crash-d")
            try await waitFor("both bridges start") { mark("crash-c") != nil && mark("crash-d") != nil }
            kill(pid("crash-c"), SIGKILL)
            let closed = try await poll(c, "the run whose bridge crashed fails") { settled($0) }
            try require(text(closed["status"]) == "failed" && text(closed["stopCause"]) == "bridge.closed", "bridge.closed: \(closed["status"] ?? "") \(closed["stopCause"] ?? "-")")
            try await Task.sleep(nanoseconds: 500_000_000)
            let other = try await detail(d)
            try require(text(other["status"]) == "running" && alive(pid("crash-d")), "the other bridge keeps running")
            release("crash-d")
            _ = try await poll(d, "and finishes") { text($0["status"]) == "completed" }
            try await cancel(c, as: forge)
        }
        try? await clearQueue()

        // 8. Money: each run is held to what its own agent's daily limit leaves; a limit the whole workspace shares is never passed by runs at once.
        await section("daily limits: each run gets its own agent's room; runs under a shared workspace limit never add up past it") {
            func limit(_ scope: String, _ agent: String, _ amount: Any) async throws { _ = try await worker(["operation": "limit", "scope": scope, "agentId": agent, "amountUSD": amount]) }
            @MainActor func budget(_ name: String) -> Double { (mark(name)?["budget"] as? NSNumber)?.doubleValue ?? -1 }
            try await limit("agent", forge, 3.0); try await limit("agent", vera, 4.0)
            let a = try await start("HOLD_FIXTURE:money-a", as: forge, request: "money-a")
            let b = try await start("HOLD_FIXTURE:money-b", as: vera, request: "money-b")
            try await waitFor("both start at once") { mark("money-a") != nil && mark("money-b") != nil }
            try require(budget("money-a") > 2.5 && budget("money-a") <= 3.0 && budget("money-b") > 3.5 && budget("money-b") <= 4.0, "each run's ceiling is its own agent's room: \(budget("money-a")) \(budget("money-b"))")
            let da = try await detail(a), db = try await detail(b)
            try require((da["reservedBudgetUSD"] as? Double ?? 0) > 0 && (db["reservedBudgetUSD"] as? Double ?? 0) > 0, "each run holds its own reservation while it works")
            release("money-a")
            let aDone = try await poll(a, "the first finishes") { text($0["status"]) == "completed" }
            let bNow = try await detail(b)
            try require(aDone["reservedBudgetUSD"] as? Double == 0 && (aDone["spentUSD"] as? Double ?? 0) > 0 && (bNow["reservedBudgetUSD"] as? Double ?? 0) > 0, "the first's reservation is released, the other's is still held")
            release("money-b")
            _ = try await poll(b, "the second finishes") { text($0["status"]) == "completed" }
            try await limit("agent", forge, NSNull()); try await limit("agent", vera, NSNull())
            try await limit("workspace", "", 5.0)
            _ = try await start("HOLD_FIXTURE:money-c", as: forge, request: "money-c")
            try await waitFor("the first under the shared limit starts") { mark("money-c") != nil }
            let d = try await start("HOLD_FIXTURE:money-d", as: vera, request: "money-d")
            try require(budget("money-c") > 4.0 && budget("money-c") <= 5.0, "it may spend what the workspace limit leaves: \(budget("money-c"))")
            try await Task.sleep(nanoseconds: 1_500_000_000)
            let waiting = try await detail(d)
            try require(mark("money-d") == nil && text(waiting["status"]) == "queued" && text(waiting["blockedBy"]).isEmpty, "the second waits its turn instead of passing the shared limit (not refused): \(waiting["status"] ?? "") \(waiting["progress"] ?? "")")
            release("money-c")
            try await waitFor("it starts once the first has finished") { mark("money-d") != nil }
            try require(budget("money-d") > 4.0 && budget("money-d") <= 5.0 - 0.01 + 1e-9, "with what is left: \(budget("money-d"))")
            release("money-d")
            _ = try await poll(d, "the second finishes") { text($0["status"]) == "completed" }
            try await limit("workspace", "", NSNull())
        }
        try? await clearQueue()

        // 9. The stage loop: an authorized stage with two independent tasks starts both, and they run at once.
        await section("an authorized stage with two independent tasks dispatches both, and they run at once") {
            let proposal: [String: Any] = ["action": "propose", "groupId": team, "objective": "Build both halves",
                                           "stages": [["title": "Build", "goal": "Build both halves", "acceptance": ["both halves exist"]], ["title": "Notes", "goal": "Write the notes", "acceptance": ["notes.md is written"]]],
                                           "tasks": [["stage": 1, "key": "p1", "title": "Left half", "assignee": forge, "kind": "coding", "brief": "HOLD_FIXTURE:plan-left build the left half", "deliverable": "left.txt"],
                                                     ["stage": 1, "key": "p2", "title": "Right half", "assignee": vera, "kind": "coding", "brief": "HOLD_FIXTURE:plan-right build the right half", "deliverable": "right.txt"],
                                                     ["stage": 2, "key": "p3", "title": "Notes", "assignee": ada, "kind": "coding", "brief": "Write the notes", "deliverable": "notes.md", "dependsOn": ["p1", "p2"]]]]
            let drafted = try await worker(["operation": "plan", "arguments": proposal])
            let planID = (drafted["plan"] as? [String: Any])?["id"] as? String ?? ""
            try require(!planID.isEmpty, "the plan is drafted: \(drafted)")
            _ = try await worker(["operation": "plan", "arguments": ["action": "authorize", "planId": planID, "through": 1, "viaButton": true]])
            try await waitFor("both tasks of the stage start", seconds: 40) { mark("plan-left") != nil && mark("plan-right") != nil }
            let jobs = ((try await status())["tasks"] as? [[String: Any]] ?? []).filter { $0["planId"] as? String == planID }
            try require(jobs.count == 2 && jobs.allSatisfy { text($0["status"]) == "running" }, "two worker tasks, both running: \(jobs.map { text($0["status"]) })")
            release("plan-left"); release("plan-right")
            for job in jobs { _ = try await poll(text(job["id"]), "each finishes") { text($0["status"]) == "completed" } }
            _ = try? await worker(["operation": "plan", "arguments": ["action": "stop", "planId": planID]])
        }
        try? await clearQueue()

        // 10. A restart stops both runs; the next worker resumes each of them, again at the same time.
        await section("after a restart both interrupted runs resume by themselves, side by side") {
            let a = try await start("HOLD_FIXTURE:restart-a", as: forge, request: "restart-a")
            let b = try await start("HOLD_FIXTURE:restart-b", as: vera, request: "restart-b")
            try await waitFor("both start") { mark("restart-a") != nil && mark("restart-b") != nil }
            host.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
            try await waitFor("the old worker's bridges close") { !alive(pid("restart-a")) && !alive(pid("restart-b")) }
            host = makeHost()
            host.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
            try await waitFor("both continue in a new attempt, at the same time", seconds: 40) { mark("restart-a-again") != nil && mark("restart-b-again") != nil }
            let da = try await detail(a), db = try await detail(b)
            try require(text(da["status"]) == "running" && text(db["status"]) == "running" && da["attempt"] as? Int == 2 && db["attempt"] as? Int == 2, "both run their second attempt at once: \(da["status"] ?? "") \(db["status"] ?? "")")
            try require((da["recovery"] as? [String: Any])?["cause"] as? String == "worker.restart" && (db["recovery"] as? [String: Any])?["cause"] as? String == "worker.restart", "each resumed after the restart")
            release("restart-a-again"); release("restart-b-again")
            _ = try await poll(a, "the first finishes") { text($0["status"]) == "completed" }
            _ = try await poll(b, "the second finishes") { text($0["status"]) == "completed" }
        }

        if !failures.isEmpty { fputs("FAILED: \(failures.count) parallel task check(s)\n", stderr); exit(1) }
        print("PASS: several background tasks run at once, one per agent, within the person's limit; each run keeps its own attempt, reviews, stops, crashes, money and recovery")
    }
}
