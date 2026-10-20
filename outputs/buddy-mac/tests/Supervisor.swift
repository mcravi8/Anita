// run-tests: BuddyWorkerCore.swift BuddyOperationsDB.swift BuddyWorkerProcess.swift BuddyWorkerHost.swift BuddyPlan.swift BuddySupervisor.swift BuddyMigrations.swift BuddyWorkerClient.swift BuddyAgentMemory.swift BuddyTeamMonitorStore.swift BuddyTeamMonitor.swift BuddyAISettings.swift ConversationService.swift BuddyInboxReview.swift BuddyMailVerification.swift BuddyComputer.swift BuddyTransport.swift BuddyToolInput.swift BuddyConnections.swift BuddyTeam.swift BuddyProjectFiles.swift BuddyDocuments.swift BuddyAgentProposals.swift -- src:tests/supervisor-claude.py which:python3
import Foundation

/// The supervisor lane, end to end at the store level: a real worker store, a real plan store, a stand-in dispatcher (what the worker's stage loop
/// does) and the lane running a fixture Claude process. Between the user's messages the lane accepts results, answers teammates' questions and
/// checks the finished stage; the stage boundary holds, user-list items reach the user once, nonsense is ignored, and a lane that gets nowhere stops.
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
                                       keyReader: { _ in "fixture-key" }, hooks: hooks)
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
    @MainActor static func rows(_ world: World, _ sql: String, _ binds: [BuddyOperationsDB.Bind] = []) throws -> [[BuddyOperationsDB.Column]] {
        try BuddyOperationsDB(directory: world.worker, existing: true).rows(sql, binds)
    }
    @MainActor static func count(_ world: World, _ sql: String, _ binds: [BuddyOperationsDB.Bind] = []) throws -> Int { Int(try rows(world, sql, binds).first?.first?.int ?? -1) }

    @MainActor static func main() async throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("buddy-supervisor-\(UUID().uuidString).noindex", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        require(CommandLine.arguments.count >= 3, "the fixture and python3 are passed in")

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
        try BuddyAgentModels(support: hold.root).set(workspace: w, agent: chief, selection: .init(provider: "chatgpt", model: "gpt-5"))
        await tick(hold)
        require(calls(hold).isEmpty && hold.lane.status["lastError"] as? String == "The supervisor runs on Claude; connect Claude or choose a Claude model for Chief.", "a supervisor on ChatGPT is reported, not run: \(hold.lane.status)")
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
        print("PASS: the lane does nothing without a Claude supervisor, while paused or past the supervisor's daily limit (one notice a day); an item that gets no effective action three times becomes one stuck notice and is not presented again")
    }
}
