// run-tests: BuddyWorkerCore.swift BuddyOperationsDB.swift BuddyWorkerProcess.swift BuddyWorkerHost.swift BuddyPlan.swift BuddySupervisor.swift BuddyMigrations.swift BuddyWorkerClient.swift BuddyAgentMemory.swift BuddyTeamMonitorStore.swift BuddyTeamMonitor.swift BuddyAISettings.swift ConversationService.swift BuddyInboxReview.swift BuddyMailVerification.swift BuddyComputer.swift BuddyTransport.swift BuddyToolInput.swift BuddyConnections.swift BuddyTeam.swift BuddyProjectFiles.swift BuddyDocuments.swift BuddyAgentProposals.swift -- src:tests/supervisor-claude.py which:python3 src:tests/supervisor-gpt.py
import Foundation

/// The supervisor lane, end to end at the store level: a real worker store, a real plan store, a stand-in dispatcher (what the worker's stage loop
/// does) and the lane running a fixture Claude process, or a fixture ChatGPT app-server when the supervisor is on ChatGPT. Between the user's
/// messages the lane accepts results, answers teammates' questions and checks the finished stage; the stage boundary holds, user-list items reach
/// the user once, nonsense is ignored, and a lane that gets nowhere stops.
@main struct SupervisorChecks {
    @MainActor static func require(_ value: Bool, _ message: String) { if !value { fputs("FAILED: \(message)\n", stderr); exit(1) } }

    static let w = "11111111-1111-4111-8111-111111111111", group = "22222222-2222-4222-8222-222222222222"
    static let chief = "33333333-3333-4333-8333-333333333333", forge = "44444444-4444-4444-8444-444444444444", vera = "55555555-5555-4555-8555-555555555555"
    static let names = [chief: "Chief", forge: "Forge", vera: "Vera"]
    static let members = [forge, vera]
    static let state: [String: Any] = [
        "conversationWorkspace": w,
        "agents": [["id": chief, "name": "Chief", "role": "Chief of staff"], ["id": forge, "name": "Forge", "role": "Engineer"], ["id": vera, "name": "Vera", "role": "Methods reviewer"]],
        "groups": [["id": group, "name": "Omori", "members": [chief, forge, vera], "managedBy": chief]],
    ]
    static let stages: [[String: Any]] = [
        ["title": "Reproduce", "goal": "Reproduce the baseline results", "acceptance": ["The baseline table matches the paper", "Vera signed off the method"]],
        ["title": "Extend", "goal": "Add the robustness checks", "acceptance": ["Three robustness tables exist"]],
    ]
    static let tasks: [[String: Any]] = [
        ["stage": 1, "key": "t1", "title": "Rerun the pipeline", "assignee": forge, "kind": "coding", "brief": "Rerun the pipeline on a copy of the data.", "deliverable": "baseline.csv"],
        ["stage": 1, "key": "t2", "title": "Check the method", "assignee": vera, "kind": "research", "brief": "Check Forge's rerun against the paper.", "deliverable": "A short sign-off note", "dependsOn": ["t1"]],
        ["stage": 2, "key": "t3", "title": "Robustness checks", "assignee": forge, "kind": "coding", "brief": "Add three robustness checks.", "deliverable": "robustness.csv"],
    ]

    final class World {
        let root: URL, store: BuddyWorkerStore, plans: BuddyPlanStore, lane: BuddySupervisorLane
        // Noon today, not the moment the test starts: every tick moves the clock two minutes on, and a run started just before midnight
        // crossed into the next day, where a once-a-day notice rightly appears a second time.
        var now = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!, stopped: [(String, String)] = []
        var planID = "", keys: [String: String] = [:]
        /// The Claude key the lane can read; nil is a key that cannot be read.
        var key: String? = "fixture-key"
        init(root: URL, store: BuddyWorkerStore, plans: BuddyPlanStore, lane: BuddySupervisorLane) { self.root = root; self.store = store; self.plans = plans; self.lane = lane }
        var worker: URL { root.appendingPathComponent("Worker") }
        var supervisorFolder: URL { worker.appendingPathComponent("Supervisor") }
    }

    @MainActor static func world(_ base: URL, _ name: String) throws -> World {
        let root = base.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let monitor: [String: Any] = ["version": 1, "settings": [w: ["enabled": true, "supervisorId": chief, "supervisorChosen": true, "agents": [String: Any](), "intervalMinutes": 15, "dailyLimitUSD": 2.0, "revision": 1]], "checks": [], "updates": []]
        try JSONSerialization.data(withJSONObject: monitor).write(to: root.appendingPathComponent("team-monitor.json"))
        try BuddyAgentModels(support: root).set(workspace: w, agent: chief, selection: .init(provider: "claude", model: "fixture-chief-model"))
        let store = try BuddyWorkerStore(directory: root.appendingPathComponent("Worker"))
        let plans = try BuddyPlanStore(directory: root.appendingPathComponent("Worker"))
        var holder: World?
        let hooks = BuddySupervisorLane.Hooks(stopTask: { id, cause in holder?.stopped.append((id, cause)); _ = try? holder?.store.update(id, ["status": "cancelled", "stopCause": cause]) },
                                              taskFiles: { id in ["/fixture/\(id)/baseline.csv"] })
        let lane = BuddySupervisorLane(support: root, store: store, plans: plans,
                                       makeClaude: { BuddyWorkerProcess(resource: URL(fileURLWithPath: CommandLine.arguments[1]), runtime: URL(fileURLWithPath: CommandLine.arguments[2])) },
                                       makeGPT: { ConversationService(support: root, executable: URL(fileURLWithPath: CommandLine.arguments[3])) },
                                       keyReader: { _ in holder?.key }, hooks: hooks)
        let made = World(root: root, store: store, plans: plans, lane: lane)
        holder = made
        return made
    }
    @MainActor static func mode(_ world: World, _ value: String) throws {
        try FileManager.default.createDirectory(at: world.supervisorFolder, withIntermediateDirectories: true)
        try value.write(to: world.supervisorFolder.appendingPathComponent("fixture-mode.txt"), atomically: true, encoding: .utf8)
    }
    @MainActor static func calls(_ world: World) -> [[String: Any]] {
        guard let text = try? String(contentsOf: world.supervisorFolder.appendingPathComponent("fixture-calls.jsonl"), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }
    /// One pass of the lane, waited out: the run it starts (if any) finishes and its actions are applied.
    @MainActor static func tick(_ world: World, state: [String: Any] = state) async {
        world.now = world.now.addingTimeInterval(120)
        await world.lane.tick(state: state, now: world.now)
        for _ in 0..<600 {
            if world.lane.status["busy"] as? Bool != true { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        require(false, "the lane finished its run within 12 s: \(world.lane.status)")
    }
    /// The worker's stage loop, with a dispatcher that does what the worker's does: create the task, then mark it as plan work for the supervisor.
    @MainActor static func step(_ world: World) throws -> [String] {
        try BuddyStageLoop.step(plans: world.plans, workspace: w, jobs: world.store.jobs, names: names) { ref, brief, requestId in
            let job = try world.store.create(workspace: w, agent: ref.assignee, requestId: requestId, title: ref.title, goal: brief, kind: ref.kind, provider: "claude", budget: BuddyRunLimit.none)
            return try world.store.update(job["id"] as? String ?? "", ["planId": ref.planId, "planTaskId": ref.taskId, "stageId": ref.stageId, "reportsTo": chief, "supervisorId": chief])
        }
    }
    @MainActor static func propose(_ world: World) throws {
        let proposed = try world.plans.propose(workspace: w, groupId: group, supervisorId: chief, objective: "Reproduce and extend the Omori results", stages: stages, tasks: tasks, members: members, by: chief)
        world.planID = proposed["id"] as? String ?? ""; world.keys = proposed["keys"] as? [String: String] ?? [:]
        _ = try world.plans.authorize(planId: world.planID, through: 1, quote: "get stage 1 done", messageId: "m1", viaButton: false, now: Date())
    }
    @MainActor static func jobs(_ world: World, _ key: String) -> [[String: Any]] {
        let ptid = world.keys[key] ?? "?"
        return world.store.jobs.filter { ($0["requestId"] as? String ?? "").hasPrefix("plan:\(ptid):") }
    }
    @MainActor static func planTask(_ world: World, _ key: String) throws -> [String: Any] {
        let plan = try world.plans.plan(id: world.planID) ?? [:]
        for stage in plan["stages"] as? [[String: Any]] ?? [] { for task in stage["tasks"] as? [[String: Any]] ?? [] where task["id"] as? String == world.keys[key] { return task } }
        return [:]
    }
    @MainActor static func notices(_ world: World, _ kind: String) throws -> [[String: Any]] {
        ((try world.plans.plan(id: world.planID))?["notices"] as? [[String: Any]] ?? []).filter { $0["kind"] as? String == kind }
    }
    @MainActor static func finish(_ store: BuddyWorkerStore, _ job: String, result: String) throws {
        let attempt = (try store.job(job)["attempt"] as? Int ?? 0) + 1
        try store.update(job, ["status": "running", "attempt": attempt, "executionRunID": UUID().uuidString])
        try store.update(job, ["status": "completed", "result": result, "progress": "Done"])
    }
    @MainActor static func ask(_ store: BuddyWorkerStore, _ job: String, question: String) throws {
        let attempt = (try store.job(job)["attempt"] as? Int ?? 0) + 1
        try store.update(job, ["status": "running", "attempt": attempt, "executionRunID": UUID().uuidString])
        try store.update(job, ["status": "waiting_user", "stopCause": "checkpoint.supervisor", "progress": "Waiting for Chief: \(question)",
                               "checkpoint": ["id": UUID().uuidString, "category": "approach", "question": question, "options": ["Table 2", "Table 3"], "recommendation": "Table 2", "routedTo": "supervisor", "at": "2026-10-19T08:00:00Z"]])
    }
    /// The user's case: Stage 1 done, then Stage 2 authorized while it has no tasks yet. Returns Stage 2's id.
    @MainActor static func emptyStageTwo(_ world: World) throws -> String {
        let proposed = try world.plans.propose(workspace: w, groupId: group, supervisorId: chief, objective: "Reproduce and extend the Omori results", stages: stages, tasks: [tasks[0]], members: members, by: chief)
        world.planID = proposed["id"] as? String ?? ""; world.keys = proposed["keys"] as? [String: String] ?? [:]
        let stageIDs = (proposed["stages"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        _ = try world.plans.authorize(planId: world.planID, through: 1, quote: "get stage 1 done", messageId: "m1", viaButton: false, now: Date())
        _ = try step(world)
        try finish(world.store, jobs(world, "t1").first?["id"] as? String ?? "", result: "R1: the baseline reproduces.")
        _ = try step(world)
        try world.plans.accept(taskId: world.keys["t1"] ?? "", attempt: 1, by: chief, reason: "Matches the paper.")
        _ = try step(world)
        _ = try world.plans.stageDone(stageId: stageIDs.first ?? "", evidence: ["task:\(world.keys["t1"] ?? "")"], report: "Stage 1 is done.", by: chief, attemptOutcome: { _, _ in nil })
        _ = try world.plans.authorize(planId: world.planID, through: 2, quote: "get stage 2 done", messageId: "m2", viaButton: false, now: Date())
        _ = try step(world)
        return stageIDs.last ?? ""
    }
    @MainActor static func stageTasks(_ world: World, _ stageId: String) throws -> [[String: Any]] {
        ((try world.plans.plan(id: world.planID))?["stages"] as? [[String: Any]] ?? []).first { $0["id"] as? String == stageId }?["tasks"] as? [[String: Any]] ?? []
    }
    @MainActor static func itemState(_ world: World, _ key: String) throws -> (state: String, presented: Int, refusal: String) {
        let row = ((try? rows(world, "SELECT state, presented, refusal FROM supervisor_items WHERE key = ?", [.text(key)]))
                   ?? (try? rows(world, "SELECT state, presented, '(no refusal column)' FROM supervisor_items WHERE key = ?", [.text(key)])))?.first
        return (row?[0].string ?? "", Int(row?[1].int ?? -1), row?[2].string ?? "")
    }
    @MainActor static func rows(_ world: World, _ sql: String, _ binds: [BuddyOperationsDB.Bind] = []) throws -> [[BuddyOperationsDB.Column]] {
        try BuddyOperationsDB(directory: world.worker, existing: true).rows(sql, binds)
    }
    @MainActor static func count(_ world: World, _ sql: String, _ binds: [BuddyOperationsDB.Bind] = []) throws -> Int { Int(try rows(world, sql, binds).first?.first?.int ?? -1) }

    @MainActor static func main() async throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("buddy-supervisor-\(UUID().uuidString).noindex", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        require(CommandLine.arguments.count >= 4, "the Claude fixture, python3 and the ChatGPT fixture are passed in")

        // 1. A stage, start to finish, with nobody typing.
        let main = try world(base, "main")
        require(main.lane.status["online"] as? Bool == false && main.lane.status["busy"] as? Bool == false, "a lane that has not run yet reports itself offline: \(main.lane.status)")
        try mode(main, "auto")
        try propose(main)
        require(try step(main).count == 1 && jobs(main, "t1").count == 1, "authorizing stage 1 starts t1")
        let t1Job = jobs(main, "t1")[0]["id"] as? String ?? ""
        await tick(main)
        require(calls(main).isEmpty, "with nothing waiting, the lane runs nothing")
        require(main.lane.status["online"] as? Bool == true, "a lane with a Claude supervisor is online: \(main.lane.status)")
        try finish(main.store, t1Job, result: "R1: the baseline reproduces to the third decimal.")
        _ = try step(main)
        require(try planTask(main, "t1")["status"] as? String == "review", "a finished t1 waits for review")
        await tick(main)
        let first = calls(main)
        require(first.count == 1 && (first[0]["items"] as? [String]) == ["result:\(main.keys["t1"] ?? ""):1"] && (first[0]["kinds"] as? [String]) == ["result"], "the lane presents t1's result: \(first)")
        let call = first[0]
        require(call["model"] as? String == "fixture-chief-model" && (call["tools"] as? [Any])?.isEmpty == true && call["budget"] is NSNull, "the run uses the supervisor's model, no tools and no budget: \(call)")
        require(call["policy"] as? Bool == true && call["supervises"] as? Bool == true && call["text"] as? Bool == true, "the instructions are the decision policy, the supervision line and the supervisor text")
        require((call["you"] as? [String: Any])?["name"] as? String == "Chief" && (call["authorization"] as? [String: Any])?["quote"] as? String == "get stage 1 done" && call["notices"] as? Bool == false, "the briefing names the supervisor, carries the user's authorization and leaves out the notices: \(call)")
        require((call["results"] as? [String])?.first?.contains("R1: the baseline reproduces") == true && (call["files"] as? [String]) == ["/fixture/\(t1Job)/baseline.csv"], "the briefing carries the attempt's result and the task's files: \(call)")
        require((call["cwd"] as? String ?? "").hasPrefix(main.supervisorFolder.path + "/") && (call["outcomes"] as? Int ?? 0) >= 1, "the run works in its own folder under Worker/Supervisor and sees the record of what finished: \(call)")
        require(try planTask(main, "t1")["status"] as? String == "done", "the fixture's accept is applied: t1 is done")
        require(!((try main.store.job(t1Job))["acceptedAt"] as? String ?? "").isEmpty, "the worker task records when its result was accepted")
        require(try count(main, "SELECT COUNT(*) FROM plan_decisions WHERE kind = 'accept' AND decided_by = ? AND task_id = ?", [.text(chief), .text(main.keys["t1"] ?? "")]) == 1, "the acceptance is recorded as the supervisor's decision")
        require(!(try main.store.openDecisions(workspace: w)).contains { $0["kind"] as? String == "result" }, "nothing is left waiting on that result")
        require(try step(main).count == 1 && jobs(main, "t2").count == 1, "accepting t1 starts t2")
        let t2Job = jobs(main, "t2")[0]["id"] as? String ?? ""
        try ask(main.store, t2Job, question: "Which table should I check the rerun against?")
        let waiting = (try main.store.openDecisions(workspace: w)).first { $0["kind"] as? String == "waiting" && $0["taskId"] as? String == t2Job } ?? [:]
        require(waiting["audience"] as? String == "supervisor", "a question for the supervisor is the supervisor's: \(waiting)")
        _ = try step(main)
        await tick(main)
        require((calls(main).last?["kinds"] as? [String]) == ["question"] && (calls(main).last?["questions"] as? [String]) == ["Which table should I check the rerun against?"], "the lane presents t2's question: \(calls(main).last ?? [:])")
        let answered = try main.store.job(t2Job)
        require((answered["updates"] as? [String] ?? []).contains("[Answer from Chief, your supervisor] Use Table 2 of the paper; it is the published baseline.") && answered["status"] as? String == "queued" && answered["checkpoint"] as? [String: Any] == nil,
                "the answer is added for t2 and t2 is queued again: \(answered["updates"] ?? "") \(answered["status"] ?? "")")
        require(try rows(main, "SELECT resolved_by, status FROM decisions WHERE id = ?", [.text(waiting["id"] as? String ?? "")]).first.map { $0[0].string == "supervisor:\(chief)" && $0[1].string == "resolved" } == true, "the question is recorded as settled by the supervisor")
        require(try count(main, "SELECT COUNT(*) FROM plan_decisions WHERE kind = 'answer' AND decided_by = ?", [.text(chief)]) == 1, "the answer is a plan decision")
        _ = try step(main)
        require(try planTask(main, "t2")["status"] as? String == "dispatched", "the answered task is working again")
        try finish(main.store, t2Job, result: "Signed off: Table 2 matches.")
        _ = try step(main)
        await tick(main)
        require(try planTask(main, "t2")["status"] as? String == "done", "t2's result is accepted")
        require(try step(main).isEmpty, "nothing more starts in stage 1")
        let stageOne = ((try main.plans.plan(id: main.planID))?["stages"] as? [[String: Any]] ?? [])[0]
        require(stageOne["status"] as? String == "review", "stage 1 waits for its check: \(stageOne["status"] ?? "")")
        await tick(main)
        require((calls(main).last?["kinds"] as? [String]) == ["stage_check"], "the lane presents the stage check")
        let holding = try main.plans.plan(id: main.planID) ?? [:]
        require(holding["status"] as? String == "holding" && (holding["scope"] as? [String: Any])?["status"] as? String == "achieved", "the stage check finishes the authorization: the scope is achieved and the plan holds: \(holding["status"] ?? "") \(holding["scope"] ?? "")")
        let report = try notices(main, "stage_report")
        require(report.count == 1 && (report[0]["text"] as? String ?? "").hasPrefix("Stage 1 is done: the baseline reproduces and Vera signed off.") && (report[0]["text"] as? String ?? "").contains("Next is Stage 2 — Extend"), "the user gets one stage report: \(report)")
        require(try rows(main, "SELECT rationale FROM plan_decisions WHERE kind = 'stage_done'").first?[0].string?.contains("task:\(main.keys["t1"] ?? "")") == true, "the stage check cites task evidence")
        for _ in 0..<3 { require(try step(main).isEmpty, "nothing starts after the authorized stage") }
        let before = calls(main).count
        await tick(main)
        require(calls(main).count == before, "a finished stage leaves the lane nothing to do")
        require(jobs(main, "t3").isEmpty && !main.store.jobs.contains { ($0["requestId"] as? String ?? "").hasPrefix("plan:\(main.keys["t3"] ?? "")") }, "no stage-2 task is ever created")
        require(try count(main, "SELECT COUNT(*) FROM supervisor_runs WHERE status = 'applied'") == 4 && (try count(main, "SELECT COUNT(*) FROM supervisor_runs")) == 4, "four runs, each applied")

        // 5. Spend: each run's cost is recorded for the supervisor, under its own run id.
        let month = { () -> String in let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current; f.dateFormat = "yyyy-MM"; return f.string(from: Date()) }()
        let spendText = (try? String(contentsOf: main.root.appendingPathComponent("Claude/spend-\(month).jsonl"), encoding: .utf8)) ?? ""
        let spends = spendText.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        let runIDs = Set(calls(main).compactMap { $0["runId"] as? String }.map { "supervisor:" + $0 })
        require(spends.count == 4 && spends.allSatisfy { $0["kind"] as? String == "spend" && $0["agent"] as? String == chief && $0["workspace"] as? String == w && abs(($0["usd"] as? Double ?? 0) - 0.07) < 1e-9 } && Set(spends.compactMap { $0["run"] as? String }) == runIDs,
                "each run's cost is recorded with recordChat as the supervisor's spend: \(spends)")
        let cost = Double(try rows(main, "SELECT SUM(cost) FROM supervisor_runs").first?[0].string ?? "") ?? 0
        require(abs(cost - 0.28) < 1e-6, "the runs keep their cost: \(cost)")
        print("PASS: the supervisor lane accepts results, answers a teammate's question and checks the finished stage between the user's messages; the stage boundary holds and every run's cost is recorded for the supervisor")

        // 2. A user-list item is forwarded once, and the user's answer resumes the work.
        let forward = try world(base, "forward")
        try propose(forward)
        _ = try step(forward)
        let f1 = jobs(forward, "t1")[0]["id"] as? String ?? ""
        try ask(forward.store, f1, question: "The data portal wants a sign-in. Can you sign in?")
        _ = try step(forward)
        try mode(forward, "forward")
        await tick(forward)
        let escalation = (try forward.store.openDecisions(workspace: w)).filter { $0["kind"] as? String == "escalation" }
        require(escalation.count == 1 && escalation[0]["audience"] as? String == "user", "a forward_to_user makes one escalation for the user: \(escalation)")
        let forwardedKey = (calls(forward).last?["items"] as? [String])?.first ?? ""
        require((escalation[0]["payload"] as? [String: Any])?["itemKey"] as? String == forwardedKey && !forwardedKey.isEmpty, "the escalation names the item it forwards")
        let escalationNotices = try notices(forward, "escalation")
        require(escalationNotices.count == 1 && escalationNotices[0]["chat"] as? Bool == true && escalationNotices[0]["text"] as? String == "Forge needs you to sign in to the data portal. My recommendation: Sign in with your university account. The team keeps working on the rest meanwhile.",
                "the plan says it in chat, with the recommendation: \(escalationNotices)")
        let escalationRefs = escalationNotices[0]["refs"] as? [String: Any] ?? [:]
        require(escalationRefs["question"] as? String == "Forge needs you to sign in to the data portal." && escalationRefs["recommendation"] as? String == "Sign in with your university account" && escalationRefs["itemKey"] as? String == forwardedKey && escalationRefs["category"] as? String == "credential",
                "the notice carries the question and the recommendation for the chat, and its own id is what the answer names: \(escalationRefs)")
        require(!(try forward.store.openDecisions(workspace: w)).contains { $0["audience"] as? String == "supervisor" }, "nothing is left waiting on the supervisor")
        require(try forward.store.job(f1)["status"] as? String == "waiting_user", "the task waits for the user's answer")
        let forwardedRuns = calls(forward).count
        try mode(forward, "auto")
        await tick(forward); await tick(forward)
        require(calls(forward).count == forwardedRuns, "a forwarded item is not presented again")
        _ = try forward.plans.answerEscalation(planId: forward.planID, escalationId: escalationNotices[0]["id"] as? String ?? "", answer: "Use my work account; I signed in just now.", quote: "Use my work account; I signed in just now.", store: forward.store)
        let resumed = try forward.store.job(f1)
        require(resumed["status"] as? String == "queued" && (resumed["updates"] as? [String] ?? []).contains("[Answer from the user] Use my work account; I signed in just now.") && resumed["checkpoint"] as? [String: Any] == nil, "the user's answer is added and the task resumes: \(resumed["status"] ?? "")")
        require(!(try forward.store.openDecisions(workspace: w)).contains { $0["kind"] as? String == "escalation" }, "the escalation is settled")
        require(try notices(forward, "escalation").first?["status"] as? String == "answered", "the notice is closed as answered")
        require(try count(forward, "SELECT COUNT(*) FROM plan_decisions WHERE kind = 'user_answer' AND decided_by = 'user'") == 1, "the answer is recorded as the user's")
        print("PASS: a forward_to_user with a category reaches the user once as an escalation, with the supervisor's recommendation, is not presented again, and the user's answer resumes the task")

        // 3. Unknown items and actions whose state no longer holds are ignored, with no effect.
        let ignored = try world(base, "ignored")
        try propose(ignored)
        _ = try step(ignored)
        let i1 = jobs(ignored, "t1")[0]["id"] as? String ?? ""
        try ask(ignored.store, i1, question: "Which table?")
        _ = try step(ignored)
        let decisionsBefore = try count(ignored, "SELECT COUNT(*) FROM plan_decisions"), bodyBefore = try BuddyOperationsDB.encode(try ignored.store.job(i1))
        try mode(ignored, "bogus")
        await tick(ignored)
        require(calls(ignored).count == 1, "the lane ran once")
        require(try BuddyOperationsDB.encode(try ignored.store.job(i1)) == bodyBefore, "accepting a question, finishing a stage from it or naming an unknown item changes nothing about the task")
        require(try count(ignored, "SELECT COUNT(*) FROM plan_decisions") == decisionsBefore && (try planTask(ignored, "t1"))["status"] as? String == "blocked", "and nothing in the plan")
        require((try ignored.store.openDecisions(workspace: w)).contains { $0["kind"] as? String == "waiting" && $0["audience"] as? String == "supervisor" }, "the question still waits for the supervisor")
        require(try rows(ignored, "SELECT status FROM supervisor_runs").first?[0].string == "applied", "the run itself is applied")
        print("PASS: an output naming an unknown item, or an action whose state no longer holds, is ignored with no effect")

        // Online means able to answer now: ticked recently, and the last run did not fail.
        require(ignored.lane.status["online"] as? Bool == true, "after an applied run the lane is online")
        BuddySupervisorLane.staleAfter = 0.3
        try await Task.sleep(nanoseconds: 700_000_000)
        require(ignored.lane.status["online"] as? Bool == false, "a lane the worker has not ticked lately is not online")
        BuddySupervisorLane.staleAfter = 30
        try mode(ignored, "fail")
        await tick(ignored)
        require(calls(ignored).count == 2 && ignored.lane.status["online"] as? Bool == false && ignored.lane.status["lastError"] as? String == "Claude hit an error while working.", "a lane whose run failed is not online: \(ignored.lane.status)")
        try mode(ignored, "hold")
        await tick(ignored)
        require(calls(ignored).count == 3 && ignored.lane.status["online"] as? Bool == true && (ignored.lane.status["lastError"] as? String ?? "x").isEmpty, "the next run that is applied brings it back online: \(ignored.lane.status)")
        print("PASS: the lane is online only while it was ticked in the last 30 seconds, has a Claude supervisor able to run, and its last run did not fail")

        // After "Switch all agents to ChatGPT" the supervisor supervises on ChatGPT. While ChatGPT is disconnected it keeps supervising on Claude, on
        // the Claude model it had; once ChatGPT is back it supervises there again, on its ChatGPT model.
        let switched = try world(base, "switched")
        // agent-models.json as the switch leaves it: Chief on ChatGPT, remembering its Claude model.
        try Data("{\"version\":1,\"workspaces\":{\"\(w)\":{\"\(chief)\":{\"provider\":\"chatgpt\",\"model\":\"gpt-5\",\"alternates\":{\"claude\":\"fixture-switched-model\"}}}}}".utf8).write(to: switched.root.appendingPathComponent("agent-models.json"))
        _ = try BuddyAISettings(support: switched.root).update(w, enabled: ("chatgpt", false))
        try mode(switched, "auto"); try propose(switched); _ = try step(switched)
        try finish(switched.store, jobs(switched, "t1")[0]["id"] as? String ?? "", result: "R1: the baseline reproduces.")
        _ = try step(switched); await tick(switched)
        let switchedCalls = calls(switched)
        require(switched.lane.status["online"] as? Bool == true && switchedCalls.count == 1, "a supervisor switched to ChatGPT, with ChatGPT disconnected, keeps supervising: \(switched.lane.status)")
        require(switchedCalls.first?["model"] as? String == "fixture-switched-model" && switchedCalls.first?["transport"] == nil, "on Claude, on the Claude model it had before the switch: \(switchedCalls)")
        _ = try BuddyAISettings(support: switched.root).update(w, enabled: ("chatgpt", true))
        require(try step(switched).count == 1, "accepting t1 starts t2")
        try finish(switched.store, jobs(switched, "t2").first?["id"] as? String ?? "", result: "Signed off: Table 2 matches.")
        _ = try step(switched); await tick(switched)
        let backCall = calls(switched).last ?? [:]
        require(try calls(switched).count == 2 && backCall["transport"] as? String == "chatgpt" && backCall["model"] as? String == "gpt-5" && (try planTask(switched, "t2"))["status"] as? String == "done",
                "with ChatGPT connected again it supervises on ChatGPT, on its own ChatGPT model: \(backCall)")
        print("PASS: after a switch to ChatGPT the supervisor's background lane runs on ChatGPT; while ChatGPT is disconnected it falls back to Claude, on the supervisor's remembered Claude model")

        // 4. Gates, then the no-progress breaker.
        let hold = try world(base, "hold")
        try propose(hold)
        _ = try step(hold)
        try finish(hold.store, jobs(hold, "t1")[0]["id"] as? String ?? "", result: "R1")
        _ = try step(hold)
        try mode(hold, "hold")
        var noSupervisor = state; noSupervisor["agents"] = (state["agents"] as? [[String: Any]] ?? []).filter { $0["id"] as? String != chief }
        await tick(hold, state: noSupervisor)
        require(calls(hold).isEmpty && hold.lane.status["online"] as? Bool == false, "without its supervisor the lane does nothing and is offline")
        // A supervisor on ChatGPT with neither ChatGPT nor Claude connected: nothing runs, and the lane says what to connect.
        try BuddyAgentModels(support: hold.root).set(workspace: w, agent: chief, selection: .init(provider: "chatgpt", model: "gpt-5"))
        _ = try BuddyAISettings(support: hold.root).update(w, enabled: ("chatgpt", false)); _ = try BuddyAISettings(support: hold.root).update(w, enabled: ("claude", false))
        await tick(hold)
        require(calls(hold).isEmpty && hold.lane.status["online"] as? Bool == false && hold.lane.status["lastError"] as? String == "Connect ChatGPT or Claude in AI provider settings so Chief can supervise the team in the background.",
                "with neither ChatGPT nor Claude connected the lane runs nothing and says what to connect: \(hold.lane.status)")
        _ = try BuddyAISettings(support: hold.root).update(w, enabled: ("chatgpt", true)); _ = try BuddyAISettings(support: hold.root).update(w, enabled: ("claude", true))
        try BuddyAgentModels(support: hold.root).set(workspace: w, agent: chief, selection: .init(provider: "claude", model: "fixture-chief-model"))
        try hold.store.setPaused(true)
        await tick(hold)
        require(calls(hold).isEmpty, "Pause all stops the lane too")
        try hold.store.setPaused(false)
        try hold.store.setLimit(workspace: w, scope: "agent", id: chief, amount: 0.0, setBy: "user", quote: "no spending today")
        await tick(hold); await tick(hold)
        let limitNotices = (try hold.store.openDecisions(workspace: w)).filter { $0["kind"] as? String == "notice" && ($0["question"] as? String ?? "") == "Chief's daily limit is used up; supervision continues tomorrow or when the limit is raised." }
        require(calls(hold).isEmpty && limitNotices.count == 1 && limitNotices[0]["audience"] as? String == "user", "a used-up daily limit stops the lane with one notice for the user that day: \(limitNotices.count)")
        try hold.store.setLimit(workspace: w, scope: "agent", id: chief, amount: nil, setBy: "user")
        await tick(hold); await tick(hold)
        let notYet = try notices(hold, "stuck")
        require(calls(hold).count == 2 && notYet.isEmpty, "two runs that only hold are not yet stuck")
        await tick(hold)
        let stuck = try notices(hold, "stuck")
        require(calls(hold).count == 3 && stuck.count == 1 && stuck[0]["text"] as? String == "The team is stuck on Rerun the pipeline: Waiting to see more. Tell me how to proceed." && stuck[0]["chat"] as? Bool == true, "after three presentations with no effect, one stuck notice: \(stuck)")
        await tick(hold); await tick(hold)
        let still = try notices(hold, "stuck")
        require(calls(hold).count == 3 && still.count == 1, "a stuck item is not presented again and the notice is not repeated")
        require(try rows(hold, "SELECT state, presented FROM supervisor_items").first.map { $0[0].string == "stuck" && $0[1].int == 3 } == true, "the item is recorded as stuck after three presentations")
        print("PASS: the lane does nothing without a supervisor, with no provider connected, while paused or past a Claude supervisor's daily limit (one notice a day); an item that gets no effective action three times becomes one stuck notice and is not presented again")

        // 6. The user's case, replayed: Stage 2 is authorized with no tasks. Chief is asked to plan it, answers add_tasks with no keys and the second
        // task naming the first by its title, and the tasks are added on the first run; nothing goes stuck and the user gets no stuck notice.
        let planning = try world(base, "planning")
        try mode(planning, "auto")
        let s2 = try emptyStageTwo(planning)
        let before2 = ((try planning.plans.plan(id: planning.planID))?["stages"] as? [[String: Any]] ?? []).last?["status"] as? String ?? ""
        require(before2 == "working", "Stage 2, authorized with no tasks, is working, not being checked: \(before2)")
        await tick(planning)
        let planCall = calls(planning).last ?? [:]
        require((planCall["kinds"] as? [String]) == ["stage_plan"] && (planCall["items"] as? [String]) == ["stage_plan:\(s2)"], "the lane asks Chief to plan Stage 2, not to check that it is done: \(planCall["kinds"] ?? "") \(planCall["items"] ?? "")")
        let planStage = (planCall["stages"] as? [Any])?.first as? [String: Any] ?? [:]
        require(planStage["goal"] as? String == "Add the robustness checks" && (planStage["acceptance"] as? [String]) == ["Three robustness tables exist"] && (planCall["expected"] as? [String]) == ["add_tasks"], "with the stage's goal and acceptance, expecting add_tasks: \(planCall)")
        require(planCall["addTasks"] as? Bool == true && planCall["taskKey"] as? Bool == true, "the instructions describe each task of add_tasks and say to plan an authorized stage with no tasks at once, and the schema lets each task carry a key: \(planCall)")
        let planned = try stageTasks(planning, s2)
        require(planned.count == 2 && (planned.last?["dependsOn"] as? [String]) == [planned.first?["id"] as? String ?? "?"] && planned.first?["assignee"] as? String == forge && planned.last?["assignee"] as? String == vera,
                "Chief's add_tasks is applied on the first run, the dependency named by title included: \(planned.map { [$0["title"] ?? "", $0["dependsOn"] ?? ""] })")
        require(try count(planning, "SELECT effective FROM supervisor_runs ORDER BY started_at DESC, rowid DESC LIMIT 1") == 1 && (try itemState(planning, "stage_plan:\(s2)")).state == "handled", "the run had its effect and the planning item is handled")
        require(try notices(planning, "stuck").isEmpty, "the user gets no stuck notice")
        let stage2Now = ((try planning.plans.plan(id: planning.planID))?["stages"] as? [[String: Any]] ?? []).last?["status"] as? String ?? ""
        let started2 = try step(planning)
        require(stage2Now == "working" && started2.count == 1 && planning.store.jobs.first { $0["id"] as? String == started2.first }?["agentId"] as? String == forge, "Stage 2 runs: Forge's task starts, Vera's waits for it: \(stage2Now) \(started2)")
        let planCalls = calls(planning).count
        await tick(planning)
        require(calls(planning).count == planCalls, "a planned stage leaves the lane nothing to do")
        print("PASS: an authorized stage with no tasks is presented to the supervisor as a stage to plan; add_tasks with dependencies named by title is applied on the first run and the stage runs, with nothing stuck")

        // 7. A refused action is never silent: the reason is kept on the item, survives a restart and is in the next briefing; an effective action clears it.
        let refusing = try world(base, "refusing")
        try propose(refusing); _ = try step(refusing)
        try finish(refusing.store, jobs(refusing, "t1").first?["id"] as? String ?? "", result: "R1")
        _ = try step(refusing)
        let refusedKey = "result:\(refusing.keys["t1"] ?? ""):1"
        try mode(refusing, "refuse")
        await tick(refusing)
        require(try (calls(refusing).last?["refused"] as? [String]) == [""] && (try planTask(refusing, "t1"))["status"] as? String == "review", "the first briefing has no refusal and the rework without an instruction changes nothing")
        let kept = try itemState(refusing, refusedKey)
        require(kept.refusal.contains("Give the rework a precise instruction"), "the refusal is recorded on the item: \(kept)")
        // A restart: a new lane on the same database.
        let restarted = try world(base, "refusing")
        restarted.planID = refusing.planID; restarted.keys = refusing.keys
        try mode(restarted, "auto")
        await tick(restarted)
        require((calls(restarted).last?["refused"] as? [String]) == ["Your last action on this item was refused: Give the rework a precise instruction. Correct it and try again."], "the next briefing for the item says why its last action was refused: \(calls(restarted).last?["refused"] ?? "")")
        require(try planTask(restarted, "t1")["status"] as? String == "done" && (try itemState(restarted, refusedKey)).refusal.isEmpty, "the corrected action is applied and the refusal is cleared")
        let thrice = try world(base, "refused-thrice")
        try propose(thrice); _ = try step(thrice)
        try finish(thrice.store, jobs(thrice, "t1").first?["id"] as? String ?? "", result: "R1")
        _ = try step(thrice)
        try mode(thrice, "refuse")
        await tick(thrice); await tick(thrice); await tick(thrice)
        let refusedStuck = try notices(thrice, "stuck")
        require(refusedStuck.count == 1 && refusedStuck.first?["text"] as? String == "The team is stuck on Rerun the pipeline: Buddy could not apply Chief's rework: Give the rework a precise instruction. Tell me how to proceed.", "a stuck notice after refusals says what was refused: \(refusedStuck)")
        print("PASS: a refused action is recorded on its item with the reason, kept across a restart and shown in the next briefing until an action takes effect; a stuck notice after refusals names the refusal")

        // 8. A run that never starts (the user's 17:25 failure) is not a presentation: nothing goes stuck, the lane keeps retrying, and after 30 minutes of
        // failures the user gets one plain notice that background supervision can't start, settled once a run is applied again.
        let offline = try world(base, "nostart")
        try propose(offline); _ = try step(offline)
        try finish(offline.store, jobs(offline, "t1").first?["id"] as? String ?? "", result: "R1")
        _ = try step(offline)
        let offlineKey = "result:\(offline.keys["t1"] ?? ""):1"
        try mode(offline, "nostart")
        for _ in 0..<5 { await tick(offline) }
        let offlineState = try itemState(offline, offlineKey)
        require(try calls(offline).count == 5 && offlineState.state == "open" && offlineState.presented == 0 && (try notices(offline, "stuck")).isEmpty, "five runs that never started make nothing stuck and count no presentation: \(calls(offline).count) \(offlineState)")
        require(offline.lane.status["lastError"] as? String == "Subprocess initialization did not complete within 30000ms — check authentication and network connectivity" && offline.lane.status["online"] as? Bool == false, "the lane reports why it is not running: \(offline.lane.status)")
        func cantStart() throws -> [[String: Any]] { (try offline.store.openDecisions(workspace: w)).filter { $0["title"] as? String == "Background supervision can't start" } }
        require(try cantStart().isEmpty, "ten minutes of failures do not bother the user yet")
        for _ in 0..<11 { await tick(offline) }
        let cant = try cantStart()
        require(calls(offline).count == 16 && cant.count == 1 && cant.first?["audience"] as? String == "user" && cant.first?["kind"] as? String == "notice"
                && cant.first?["question"] as? String == "Chief can't supervise the team in the background: Subprocess initialization did not complete within 30000ms — check authentication and network connectivity. Buddy keeps trying every minute; results and questions wait for Chief meanwhile.",
                "after 30 minutes of failures the user gets one plain notice with the reason: \(cant)")
        for _ in 0..<3 { await tick(offline) }
        require(try cantStart().count == 1 && (try notices(offline, "stuck")).isEmpty && (try itemState(offline, offlineKey)).state == "open", "the notice is not repeated and still nothing is stuck")
        try mode(offline, "auto")
        await tick(offline)
        require(try planTask(offline, "t1")["status"] as? String == "done" && (try cantStart()).isEmpty && offline.lane.status["online"] as? Bool == true, "the next run that starts reviews the result and settles the notice")
        print("PASS: a supervisor run that never starts counts for no breaker and makes nothing stuck; the lane retries, and only after 30 minutes of failures the user gets one notice that supervision can't start, settled when it runs again")

        // 9. The plan-level breaker counts only applied runs, and only an item presented in each of them can be stuck by it.
        let breaker = try world(base, "breaker")
        try propose(breaker); _ = try step(breaker)
        try finish(breaker.store, jobs(breaker, "t1").first?["id"] as? String ?? "", result: "R1")
        _ = try step(breaker)
        try mode(breaker, "hold")
        await tick(breaker); await tick(breaker)
        let stageOneID = ((try breaker.plans.plan(id: breaker.planID))?["stages"] as? [[String: Any]] ?? []).first?["id"] as? String ?? ""
        let extra = try breaker.plans.addTasks(stageId: stageOneID, tasks: [["key": "x", "title": "Collect the appendix", "assignee": vera, "kind": "research", "brief": "Collect it.", "deliverable": "appendix.pdf"]], by: chief, members: members).first ?? ""
        _ = try step(breaker)
        try finish(breaker.store, breaker.store.jobs.first { ($0["requestId"] as? String ?? "").hasPrefix("plan:\(extra):") }?["id"] as? String ?? "", result: "The appendix")
        _ = try step(breaker)
        await tick(breaker)
        let firstKey = "result:\(breaker.keys["t1"] ?? ""):1", newKey = "result:\(extra):1"
        require(Set(calls(breaker).last?["items"] as? [String] ?? []) == Set([firstKey, newKey]), "the third run presents both results: \(calls(breaker).last?["items"] ?? "")")
        let firstItem = try itemState(breaker, firstKey), newItem = try itemState(breaker, newKey)
        require(firstItem.state == "stuck" && newItem.state == "open" && newItem.presented == 1, "the result held three times is stuck, the one seen once is not: \(firstItem) \(newItem)")
        require(((try notices(breaker, "stuck")).first?["refs"] as? [String: Any])?["itemKeys"] as? [String] == [firstKey], "the stuck notice names only the item that was held three times")
        print("PASS: the plan-level breaker counts only applied runs and never makes an item stuck for other items' history")

        // 10. After the update: the database as the user's Buddy left it (the lane's tables without the refusal column; a result marked stuck by the run
        // that never started, with its stuck notice). The lane adds the column, reopens that item and closes the notice once; an item stuck by an
        // applied run stays stuck.
        let repairWorker = base.appendingPathComponent("repair/Worker", isDirectory: true)
        try FileManager.default.createDirectory(at: repairWorker, withIntermediateDirectories: true)
        do {
            let old = try BuddyOperationsDB(directory: repairWorker)
            try old.run("""
                CREATE TABLE supervisor_runs(id TEXT PRIMARY KEY, workspace TEXT NOT NULL, plan_id TEXT NOT NULL DEFAULT '', items TEXT NOT NULL,
                  status TEXT NOT NULL CHECK(status IN ('running','applying','applied','failed')), output TEXT NOT NULL DEFAULT '', error TEXT NOT NULL DEFAULT '',
                  cost REAL NOT NULL DEFAULT 0, started_at TEXT NOT NULL, finished_at TEXT, effective INTEGER NOT NULL DEFAULT 0)
                """)
            try old.run("""
                CREATE TABLE supervisor_items(key TEXT PRIMARY KEY, workspace TEXT NOT NULL, presented INTEGER NOT NULL DEFAULT 0,
                  state TEXT NOT NULL CHECK(state IN ('open','handled','forwarded','stuck')), last_run TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL)
                """)
        }
        let repair = try world(base, "repair")
        try propose(repair); _ = try step(repair)
        try finish(repair.store, jobs(repair, "t1").first?["id"] as? String ?? "", result: "R1: the first Stage 2 table.")
        _ = try step(repair)
        let repairKey = "result:\(repair.keys["t1"] ?? ""):1", failedRun = "86804BCA-0000-4000-8000-000000000001", appliedRun = "6A1D0000-0000-4000-8000-000000000002"
        let raw = try BuddyOperationsDB(directory: repair.worker, existing: true)
        try raw.run("INSERT INTO supervisor_runs(id, workspace, plan_id, items, status, error, started_at, finished_at, effective) VALUES(?, ?, ?, ?, 'failed', 'Subprocess initialization did not complete within 30000ms — check authentication and network connectivity', '2026-10-20T17:25:40Z', '2026-10-20T17:26:10Z', 0)",
                    [.text(failedRun), .text(w), .text(repair.planID), .text("[{\"key\":\"\(repairKey)\",\"kind\":\"result\"}]")])
        try raw.run("INSERT INTO supervisor_runs(id, workspace, plan_id, items, status, output, started_at, finished_at, effective) VALUES(?, ?, ?, '[{\"key\":\"stage:old:0\",\"kind\":\"stage_check\"}]', 'applied', '{\"actions\":[]}', '2026-10-20T16:45:41Z', '2026-10-20T16:46:00Z', 0)",
                    [.text(appliedRun), .text(w), .text(repair.planID)])
        try raw.run("INSERT INTO supervisor_items(key, workspace, presented, state, last_run, updated_at) VALUES(?, ?, 1, 'stuck', ?, '2026-10-20T17:26:10Z')", [.text(repairKey), .text(w), .text(failedRun)])
        try raw.run("INSERT INTO supervisor_items(key, workspace, presented, state, last_run, updated_at) VALUES('stage:old:0', ?, 3, 'stuck', ?, '2026-10-20T16:46:00Z')", [.text(w), .text(appliedRun)])
        _ = try repair.plans.addNotice(planId: repair.planID, kind: "stuck", text: "The team is stuck on Stage 1 — Reproduce: Chief chose add_tasks. Tell me how to proceed.", chat: true, refs: ["itemKeys": ["stage:old:0"], "runId": appliedRun])
        _ = try repair.plans.addNotice(planId: repair.planID, kind: "stuck", text: "The team is stuck on Rerun the pipeline: Subprocess initialization did not complete within 30000ms — check authentication and network connectivity. Tell me how to proceed.", chat: true, refs: ["itemKeys": [repairKey], "runId": failedRun])
        try raw.setMeta("supervisor.reopened.codex-saves-v2", "2026-10-20T00:00:00Z")   // that one-time repair is tested on its own below
        try mode(repair, "auto")
        await tick(repair)
        require(try (calls(repair).last?["items"] as? [String]) == [repairKey] && (try planTask(repair, "t1"))["status"] as? String == "done", "after the update the result a run that never started marked stuck is reviewed: \(calls(repair).last?["items"] ?? "")")
        let repairedNotices = try notices(repair, "stuck")
        require(repairedNotices.map { $0["status"] as? String ?? "" } == ["open", "closed"], "its stuck notice is closed; the one about an item stuck after applied runs is not: \(repairedNotices)")
        require(try itemState(repair, "stage:old:0").state == "stuck" && (try itemState(repair, repairKey)).state == "handled", "an item stuck by an applied run stays stuck")
        require(try rows(repair, "PRAGMA table_info(supervisor_items)").contains { $0[1].string == "refusal" }, "the lane adds its refusal column to an older database, without a new version")
        let repairCalls = calls(repair).count
        let again = try world(base, "repair")
        again.planID = repair.planID; again.keys = repair.keys
        await tick(again)
        require(try calls(again).count == repairCalls && (try itemState(again, "stage:old:0")).state == "stuck" && (try notices(again, "stuck")).map { $0["status"] as? String ?? "" } == ["open", "closed"], "a second start repairs nothing more")
        print("PASS: at its start the lane reopens, once, the items an earlier Buddy marked stuck after a run that never started, and closes their stuck notice")

        // 10b. Once after the update that let Codex coding sessions save into connected folders: plan items stuck before it (a Stage 3 check whose
        // artifacts stayed in a private copy) are reviewed again and their stuck notice is closed; other stuck entries are left alone.
        let saves = try world(base, "saves")
        try propose(saves); _ = try step(saves)
        try finish(saves.store, jobs(saves, "t1").first?["id"] as? String ?? "", result: "R1: tables left in the private copy.")
        _ = try step(saves)
        let savedKey = "result:\(saves.keys["t1"] ?? ""):1", idleRun = "6F80FC78-0000-4000-8000-000000000003"
        let db = try BuddyOperationsDB(directory: saves.worker, existing: true)
        await tick(saves, state: [:])   // the lane's own tables exist before the old records are written
        try db.run("INSERT INTO supervisor_runs(id, workspace, plan_id, items, status, output, started_at, finished_at, effective) VALUES(?, ?, ?, ?, 'applied', '{\"actions\":[]}', '2026-10-20T20:57:08Z', '2026-10-20T20:57:15Z', 0)",
                   [.text(idleRun), .text(w), .text(saves.planID), .text("[{\"key\":\"\(savedKey)\",\"kind\":\"result\"}]")])
        try db.run("INSERT OR REPLACE INTO supervisor_items(key, workspace, presented, state, last_run, updated_at) VALUES(?, ?, 3, 'stuck', ?, '2026-10-20T20:57:15Z')", [.text(savedKey), .text(w), .text(idleRun)])
        try db.run("INSERT OR REPLACE INTO supervisor_items(key, workspace, presented, state, last_run, updated_at) VALUES('stopped:legacy:1:failed', ?, 3, 'stuck', ?, '2026-10-20T20:57:15Z')", [.text(w), .text(idleRun)])
        _ = try saves.plans.addNotice(planId: saves.planID, kind: "stuck", text: "The team is stuck on Stage 1: the handoff repair confirmed a technical access blocker. Tell me how to proceed.", chat: true, refs: ["itemKeys": [savedKey], "runId": idleRun])
        try db.run("DELETE FROM meta WHERE key = 'supervisor.reopened.codex-saves-v2'")
        // Two earlier runs that also held it: with them the plan's no-progress rule would re-mark it stuck at the first new look.
        for (n, at) in [("6F80FC78-0000-4000-8000-000000000004", "2026-10-20T20:56:51Z"), ("6F80FC78-0000-4000-8000-000000000005", "2026-10-20T20:57:00Z")] {
            try db.run("INSERT INTO supervisor_runs(id, workspace, plan_id, items, status, output, started_at, finished_at, effective) VALUES(?, ?, ?, ?, 'applied', '{\"actions\":[]}', ?, ?, 0)",
                       [.text(n), .text(w), .text(saves.planID), .text("[{\"key\":\"\(savedKey)\",\"kind\":\"result\"}]"), .text(at), .text(at)])
        }
        try mode(saves, "hold")
        let fresh = try world(base, "saves")
        fresh.planID = saves.planID; fresh.keys = saves.keys
        await tick(fresh)
        require(try (calls(fresh).last?["items"] as? [String]) == [savedKey], "after the update the stuck plan result is reviewed again: \(calls(fresh).last?["items"] ?? "")")
        require(try ((calls(fresh).last?["notes"] as? [String])?.first ?? "").contains("buddy_copy_out_of_project"), "the supervisor is told what changed: \(calls(fresh).last?["notes"] ?? "")")
        require(try calls(fresh).last?["askNotHold"] as? Bool == true, "and is told to ask the user for data or access only they can provide instead of holding")
        require(try itemState(fresh, savedKey).state == "open", "a reopened item starts clean: holding it once more does not make it stuck because of runs before it was reopened: \(try itemState(fresh, savedKey))")
        require(try notices(fresh, "stuck").map { $0["status"] as? String ?? "" } == ["closed"], "its stuck notice is closed")
        require(try itemState(fresh, "stopped:legacy:1:failed").state == "stuck", "a stuck entry outside the plan is left alone")
        let savesCalls = try calls(fresh).count
        let later = try world(base, "saves")
        later.planID = saves.planID; later.keys = saves.keys
        try db.run("UPDATE supervisor_items SET state = 'stuck' WHERE key = ?", [.text(savedKey)])
        await tick(later)
        require(try calls(later).count == savesCalls && (try itemState(later, savedKey)).state == "stuck", "the repair runs once: a later stuck item stays stuck")
        print("PASS: once after Codex could save results, plan items stuck before it are reviewed again and their stuck notice closed; other stuck entries stay")

        // 11. Supervision on ChatGPT. A supervisor whose selection is ChatGPT supervises over the ChatGPT subscription (the app-server), in a run with no
        // tool surface, with the lane's own output schema, instructions and briefing; its actions are applied exactly as on Claude, it records no
        // Claude spend, and a daily limit the person set for it (a limit on Claude spending) does not stop it.
        let gpt = try world(base, "gpt")
        try BuddyAgentModels(support: gpt.root).set(workspace: w, agent: chief, selection: .init(provider: "chatgpt", model: "fixture-gpt-chief"))
        try mode(gpt, "auto"); try propose(gpt); _ = try step(gpt)
        let g1 = jobs(gpt, "t1").first?["id"] as? String ?? ""
        try finish(gpt.store, g1, result: "R1: the baseline reproduces to the third decimal.")
        _ = try step(gpt)
        try gpt.store.setLimit(workspace: w, scope: "agent", id: chief, amount: 0.0, setBy: "user", quote: "no spending today")
        await tick(gpt)
        let gptCalls = calls(gpt), gptCall = gptCalls.first ?? [:]
        require(gptCalls.count == 1 && gptCall["transport"] as? String == "chatgpt" && (gptCall["items"] as? [String]) == ["result:\(gpt.keys["t1"] ?? ""):1"], "a supervisor on ChatGPT reviews the result over the ChatGPT transport: \(gptCalls) \(gpt.lane.status)")
        require(gptCall["model"] as? String == "fixture-gpt-chief", "on the supervisor's own ChatGPT model: \(gptCall["model"] ?? "")")
        require((gptCall["dynamicTools"] as? [Any])?.isEmpty == true && gptCall["apps"] as? Bool == false && gptCall["sandbox"] as? String == "read-only" && gptCall["approvalPolicy"] as? String == "never"
                && gptCall["ephemeral"] as? Bool == true && (gptCall["mentions"] as? [Any])?.isEmpty == true, "in a run with no tool surface: \(gptCall)")
        require(NSDictionary(dictionary: gptCall["outputSchema"] as? [String: Any] ?? [:]).isEqual(to: BuddyStrictSchema.openAI(BuddySupervisorLane.schema)), "with the lane's own output schema, in the strict form ChatGPT requires: \(gptCall["outputSchema"] ?? "")")
        require(gptCall["policy"] as? Bool == true && gptCall["supervises"] as? Bool == true && gptCall["text"] as? Bool == true && gptCall["addTasks"] as? Bool == true, "with the same instructions as on Claude: \(gptCall)")
        require((gptCall["you"] as? [String: Any])?["name"] as? String == "Chief" && (gptCall["authorization"] as? [String: Any])?["quote"] as? String == "get stage 1 done"
                && (gptCall["results"] as? [String])?.first?.contains("R1: the baseline reproduces") == true, "and the same briefing: \(gptCall)")
        require(try planTask(gpt, "t1")["status"] as? String == "done" && !((try gpt.store.job(g1))["acceptedAt"] as? String ?? "").isEmpty
                && (try count(gpt, "SELECT COUNT(*) FROM plan_decisions WHERE kind = 'accept' AND decided_by = ? AND task_id = ?", [.text(chief), .text(gpt.keys["t1"] ?? "")])) == 1,
                "its accept is applied as on Claude: t1 is done and the acceptance is the supervisor's decision")
        require(gpt.lane.status["online"] as? Bool == true && (gpt.lane.status["lastError"] as? String ?? "x").isEmpty, "the lane is online: \(gpt.lane.status)")
        let gptSpend = (try? String(contentsOf: gpt.root.appendingPathComponent("Claude/spend-\(month).jsonl"), encoding: .utf8)) ?? ""
        require(try gptSpend.isEmpty && (try count(gpt, "SELECT COUNT(*) FROM supervisor_runs WHERE status = 'applied' AND cost = 0")) == 1, "a ChatGPT run records no Claude spend: \(gptSpend)")
        require(!(try gpt.store.openDecisions(workspace: w)).contains { $0["title"] as? String == "Supervision waits for tomorrow" }, "and the Claude daily limit neither stops it nor sends a notice")
        print("PASS: a supervisor on ChatGPT runs the lane over the ChatGPT transport, with no tools and the lane's own schema, instructions and briefing; its accept is applied as on Claude, no Claude spend is recorded, the Claude daily limit does not stop it, and the lane is online")

        // 12. On ChatGPT an authorized stage with no tasks is planned on the first run, exactly as on Claude; with no ChatGPT model chosen, on the account's default.
        let gptPlanning = try world(base, "gpt-planning")
        try BuddyAgentModels(support: gptPlanning.root).set(workspace: w, agent: chief, selection: .init(provider: "chatgpt", model: ""))
        try mode(gptPlanning, "auto")
        let gs2 = try emptyStageTwo(gptPlanning)
        await tick(gptPlanning)
        let gPlanCall = calls(gptPlanning).last ?? [:]
        require(gPlanCall["transport"] as? String == "chatgpt" && (gPlanCall["kinds"] as? [String]) == ["stage_plan"] && gPlanCall["model"] as? String == "fixture-gpt", "the lane asks Chief to plan Stage 2 over ChatGPT, on the account's default model: \(gPlanCall) \(gptPlanning.lane.status)")
        let gPlanned = try stageTasks(gptPlanning, gs2)
        require(gPlanned.count == 2 && (gPlanned.last?["dependsOn"] as? [String]) == [gPlanned.first?["id"] as? String ?? "?"] && gPlanned.first?["assignee"] as? String == forge && gPlanned.last?["assignee"] as? String == vera,
                "Chief's add_tasks is applied on the first run, the dependency named by title included: \(gPlanned.map { [$0["title"] ?? "", $0["dependsOn"] ?? ""] })")
        require(try (try itemState(gptPlanning, "stage_plan:\(gs2)")).state == "handled" && (try notices(gptPlanning, "stuck")).isEmpty, "the planning item is handled and nothing is stuck")
        print("PASS: on ChatGPT an authorized stage with no tasks is planned on the first run with add_tasks, as on Claude, on the account's default model when the supervisor chose none")

        // 13. Supervision does not stop while the supervisor's own provider is unusable and the other one is usable: a supervisor on Claude with Claude
        // disconnected supervises on ChatGPT; a supervisor on ChatGPT whose app-server is not signed in supervises on Claude (on Claude's default model,
        // having had none there). With neither usable the lane is offline and says what to connect.
        let claudeOff = try world(base, "claude-off")
        _ = try BuddyAISettings(support: claudeOff.root).update(w, enabled: ("claude", false))
        try mode(claudeOff, "auto"); try propose(claudeOff); _ = try step(claudeOff)
        try finish(claudeOff.store, jobs(claudeOff, "t1").first?["id"] as? String ?? "", result: "R1")
        _ = try step(claudeOff)
        await tick(claudeOff)
        let offCall = calls(claudeOff).last ?? [:]
        require(try calls(claudeOff).count == 1 && offCall["transport"] as? String == "chatgpt" && offCall["model"] as? String == "fixture-gpt" && (try planTask(claudeOff, "t1"))["status"] as? String == "done" && claudeOff.lane.status["online"] as? Bool == true,
                "a supervisor on Claude, with Claude disconnected and ChatGPT connected, supervises on ChatGPT: \(calls(claudeOff)) \(claudeOff.lane.status)")
        let signedOut = try world(base, "signed-out")
        try BuddyAgentModels(support: signedOut.root).set(workspace: w, agent: chief, selection: .init(provider: "chatgpt", model: "fixture-gpt-chief"))
        try mode(signedOut, "signedout"); try propose(signedOut); _ = try step(signedOut)
        try finish(signedOut.store, jobs(signedOut, "t1").first?["id"] as? String ?? "", result: "R1")
        _ = try step(signedOut)
        await tick(signedOut)
        let outCall = calls(signedOut).last ?? [:]
        require(try calls(signedOut).count == 1 && outCall["transport"] == nil && outCall["model"] as? String == "claude-sonnet-4-6" && (try planTask(signedOut, "t1"))["status"] as? String == "done" && signedOut.lane.status["online"] as? Bool == true,
                "a supervisor on ChatGPT, with the app-server not signed in and Claude connected, supervises on Claude: \(calls(signedOut)) \(signedOut.lane.status)")
        signedOut.key = nil
        await tick(signedOut)
        require(calls(signedOut).count == 1 && signedOut.lane.status["online"] as? Bool == false && signedOut.lane.status["lastError"] as? String == "Connect ChatGPT or Claude in AI provider settings so Chief can supervise the team in the background.",
                "with ChatGPT not signed in and no Claude key to read, the lane is offline and says what to connect: \(signedOut.lane.status)")
        print("PASS: when the supervisor's own provider is unusable the lane runs on the other one (ChatGPT for a Claude supervisor with Claude disconnected, Claude for a ChatGPT supervisor not signed in); with neither usable it is offline and says what to connect")

        // 14. A ChatGPT run that fails before answering, ends with an empty answer, or loses the app-server half way is a technical failure, exactly as on
        // Claude: it counts for no breaker and makes nothing stuck, the lane retries, and after 30 minutes of failures the user gets one notice, settled
        // when a run is applied again.
        let gptFail = try world(base, "gpt-fail")
        try BuddyAgentModels(support: gptFail.root).set(workspace: w, agent: chief, selection: .init(provider: "chatgpt", model: "fixture-gpt-chief"))
        try propose(gptFail); _ = try step(gptFail)
        try finish(gptFail.store, jobs(gptFail, "t1").first?["id"] as? String ?? "", result: "R1")
        _ = try step(gptFail)
        let failKey = "result:\(gptFail.keys["t1"] ?? ""):1"
        try mode(gptFail, "fail")
        for _ in 0..<5 { await tick(gptFail) }
        let failState = try itemState(gptFail, failKey)
        require(try calls(gptFail).count == 5 && calls(gptFail).allSatisfy { $0["transport"] as? String == "chatgpt" } && failState.state == "open" && failState.presented == 0 && (try notices(gptFail, "stuck")).isEmpty,
                "five ChatGPT runs that failed before answering make nothing stuck and count no presentation: \(calls(gptFail).count) \(failState)")
        require(gptFail.lane.status["lastError"] as? String == "ChatGPT hit an error before answering." && gptFail.lane.status["online"] as? Bool == false, "the lane says why and is not online: \(gptFail.lane.status)")
        try mode(gptFail, "empty")
        await tick(gptFail)
        require(try calls(gptFail).count == 6 && gptFail.lane.status["lastError"] as? String == "The supervisor's run ended without an answer." && (try itemState(gptFail, failKey)).presented == 0, "an empty answer is a technical failure too: \(gptFail.lane.status)")
        try mode(gptFail, "crash")
        await tick(gptFail)
        require(try calls(gptFail).count == 7 && gptFail.lane.status["lastError"] as? String == "The ChatGPT connection closed. Try again to reconnect." && gptFail.lane.status["online"] as? Bool == false && (try itemState(gptFail, failKey)).presented == 0,
                "so is the app-server going away half way through the run: \(gptFail.lane.status)")
        func gptCantStart() throws -> [[String: Any]] { (try gptFail.store.openDecisions(workspace: w)).filter { $0["title"] as? String == "Background supervision can't start" } }
        require(try gptCantStart().isEmpty, "fourteen minutes of failures do not bother the user yet")
        try mode(gptFail, "fail")
        for _ in 0..<9 { await tick(gptFail) }
        let gptCant = try gptCantStart()
        require(calls(gptFail).count == 16 && gptCant.count == 1 && gptCant.first?["audience"] as? String == "user"
                && gptCant.first?["question"] as? String == "Chief can't supervise the team in the background: ChatGPT hit an error before answering. Buddy keeps trying every minute; results and questions wait for Chief meanwhile.",
                "after 30 minutes of failures the user gets one plain notice with the reason: \(calls(gptFail).count) \(gptCant)")
        require(try notices(gptFail, "stuck").isEmpty && (try itemState(gptFail, failKey)).state == "open", "and still nothing is stuck")
        try mode(gptFail, "auto")
        await tick(gptFail)
        require(try planTask(gptFail, "t1")["status"] as? String == "done" && (try gptCantStart()).isEmpty && gptFail.lane.status["online"] as? Bool == true && calls(gptFail).last?["transport"] as? String == "chatgpt",
                "the next ChatGPT run that answers reviews the result and settles the notice: \(gptFail.lane.status)")
        print("PASS: a ChatGPT run that fails before answering, answers nothing or loses the app-server is a technical failure: nothing goes stuck, the lane retries, one notice after 30 minutes, settled when it runs again")
    }
}
