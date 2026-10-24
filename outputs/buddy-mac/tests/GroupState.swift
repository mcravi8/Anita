// run-tests: BuddyWorkerClient.swift BuddyAISettings.swift BuddyAIRouter.swift BuddyClaudeConversations.swift BuddyWorkerProcess.swift BuddyWorkerCore.swift BuddyOperationsDB.swift ConversationService.swift BuddyInboxReview.swift BuddyMailVerification.swift BuddyComputer.swift BuddyTransport.swift BuddyToolInput.swift BuddyConnections.swift BuddyTeam.swift BuddyProjectFiles.swift BuddyDocuments.swift BuddyAgentProposals.swift BuddyPlan.swift BuddyTeamService.swift
import Foundation

@MainActor final class StateFakeConversations: BuddyConversationSending {
    struct Call { let payload: [String: Any]; let options: BuddyTurnOptions }
    var calls: [Call] = []
    var receiver: (([String: Any]) -> Void)?
    func send(_ payload: [String: Any], options: BuddyTurnOptions) throws -> [String: Any] { calls.append(Call(payload: payload, options: options)); return ["accepted": true] }
    func stop(_ id: String) async throws -> [String: Any] { receiver?(["type": "run", "runId": id, "status": "stopped", "internal": true]); return ["stopped": true] }
    func complete(_ index: Int, text: String) { receiver?(["type": "run", "runId": calls[index].payload["runId"]!, "status": "completed", "text": text, "internal": true]) }
}

/// At 19:48 Chief confirmed in its direct chat that the user's upload was the published PDF; at 19:49 the user asked the group "Working?" and
/// Chief answered there "S01 is PARTIAL and blocked; say Resume S01". The group round's coordinator wrote that state into Chief's assignment from
/// older group messages, and Chief's group turn never saw its own direct chat. Now an agent's direct chat and its turn in a group are told the
/// same current state (plans, live work, waits solved recently), the group turn also gets the agent's latest direct exchange (and the direct chat
/// the latest group exchange), and the coordinator plans from the team's current state, never restating it in assignments.
@main struct GroupStateTests {
    @MainActor static func require(_ ok: Bool, _ label: String) { if !ok { fputs("FAILED: \(label)\n", stderr); exit(1) } }
    @MainActor static func wait(_ predicate: () -> Bool) async {
        for _ in 0..<400 { if predicate() { return }; try? await Task.sleep(nanoseconds: 5_000_000) }
        require(false, "the group round did not get there in time")
    }

    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("buddy-group-state-" + UUID().uuidString + ".noindex")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let w = UUID().uuidString, omori = UUID().uuidString, chief = UUID().uuidString, forge = UUID().uuidString
        let names = [chief: "Chief", forge: "Forge"], pacific = TimeZone(identifier: "America/Los_Angeles")!

        // S01 ended PARTIAL; the supervisor forwarded it to the user for the published PDF; Chief handed the user's upload to it from its chat.
        let worker = root.appendingPathComponent("Worker")
        let store = try BuddyWorkerStore(directory: worker), plans = try BuddyPlanStore(directory: worker)
        let proposed = try plans.propose(workspace: w, groupId: omori, supervisorId: chief, objective: "Freeze the S01 protocol, then extend",
                                         stages: [["title": "S01 Protocol", "goal": "Freeze the protocol", "acceptance": ["acceptance.md saved"]], ["title": "Extend", "goal": "Extend it", "acceptance": ["robustness.csv"]]],
                                         tasks: [["stage": 1, "key": "s01", "title": "S01 caption verification", "assignee": chief, "kind": "coding", "brief": "Verify Figure 1 against the published PDF.", "deliverable": "acceptance.md"],
                                                 ["stage": 1, "key": "fit", "title": "Fit the v3 model", "assignee": forge, "kind": "coding", "brief": "Run the v3 fits.", "deliverable": "v3.csv"]],
                                         members: [chief, forge], by: chief)
        let planID = proposed["id"] as? String ?? "", keys = proposed["keys"] as? [String: String] ?? [:], s01 = keys["s01"] ?? ""
        _ = try plans.authorize(planId: planID, through: 1, quote: "Get stage 1 done", messageId: "m1", viaButton: false, now: Date())
        _ = try BuddyStageLoop.step(plans: plans, workspace: w, jobs: store.jobs, names: names) { ref, brief, requestId in
            let job = try store.create(workspace: w, agent: ref.assignee, requestId: requestId, title: ref.title, goal: brief, kind: ref.kind, provider: "claude", budget: BuddyRunLimit.none)
            return try store.update(job["id"] as? String ?? "", ["planId": ref.planId, "planTaskId": ref.taskId, "stageId": ref.stageId, "reportsTo": chief, "supervisorId": chief])
        }
        let s01Run = store.jobs.first { ($0["requestId"] as? String ?? "").hasPrefix("plan:\(s01):") }?["id"] as? String ?? ""
        try store.update(s01Run, ["status": "running", "attempt": 1, "executionRunID": UUID().uuidString])
        try store.update(s01Run, ["status": "completed", "result": "S01 PARTIAL: the published PDF is behind the publisher's sign-in.", "progress": "Done"])
        _ = try plans.reconcile(jobs: store.jobs)
        let notice = try plans.addNotice(planId: planID, kind: "escalation", text: "Save the published PDF in Research/stages/S01_protocol/source_retry/. Then say “Resume S01.”", chat: true,
                                         refs: ["itemKey": "result:\(s01):1", "itemKind": "result", "taskId": s01, "workerTaskId": s01Run, "category": "credential", "question": "Save the published PDF in source_retry/. Then say “Resume S01.”"])
        _ = try BuddyWaits.resolve(store: store, plans: plans, job: try store.job(s01Run), input: "The user uploaded the published PDF (J. Stat. Mech. 2022, 023403).", quote: "uploaded correct copy of the file", via: "Chief")

        let now = Date(), stamp = ISO8601DateFormatter()
        func at(_ seconds: TimeInterval) -> String { stamp.string(from: now.addingTimeInterval(-seconds)) }
        let state: [String: Any] = ["conversationWorkspace": w, "agents": [["id": chief, "name": "Chief", "role": "Chief of staff"], ["id": forge, "name": "Forge", "role": "Engineer"]],
            "groups": [["id": omori, "name": "Omori", "objective": "Omori volatility research", "members": [chief, forge], "managedBy": chief]],
            "messages": [chief: [["id": "d1", "who": "you", "live": true, "createdAt": at(70), "body": "uploaded correct copy of the file, let me know if that is the right one"],
                                 ["id": "d2", "who": chief, "live": true, "status": "completed", "createdAt": at(60), "body": "Yes, this is the correct published version. Figure 1's caption is on page 5."]],
                         omori: [["id": "g1", "who": "you", "live": true, "createdAt": at(3600), "body": "How is S01 going?"],
                                 ["id": "g2", "who": omori, "live": true, "status": "completed", "createdAt": at(3590), "body": "Chief: S01 is PARTIAL; the published PDF is missing."]]]]
        let summary = BuddyPlanStore.readOnlySummary(support: root, workspace: w)
        let jobs = ((try? BuddyOperationsDB.snapshot(directory: worker)) ?? nil)?.tasks ?? []

        // 1. The state block: the same for every chat of the agent, with the solved wait and the answered question, and no stale blocker.
        let block = BuddyLiveState.block(plans: summary, jobs: jobs, state: state, agent: chief, supervises: true, now: now, zone: pacific)
        require(block.contains("Team plan for Omori") && block.contains("S01 caption verification"), "the plan is in the state: \(block)")
        require(block.contains("Solved recently (do not bring these up as blockers again):") && block.contains("“S01 caption verification” got what it waited for") && block.contains("passed on by Chief")
                && block.contains("The user uploaded the published PDF"), "the solved wait is in the state: \(block)")
        require(block.contains("Questions the user answered recently (settled; never ask again):") && block.contains("[\(notice)]") && !block.contains("Your open questions forwarded to the user"),
                "the question that asked for “Resume S01” is listed as answered, not open: \(block)")
        require(!block.contains("waiting on the user"), "no task reads as waiting on the user: \(block)")
        require(!block.contains("STUCK:"), "a plan that is not stuck says nothing about it: \(block)")
        // 1b. The supervisor's lane stopped on the plan (an open stuck notice): its chats are told plainly, so it says the work is stuck and why
        // instead of promising to resolve it (23 Oct: Chief said resolving Stage 5's blocker was its job while nothing ran).
        _ = try plans.addNotice(planId: planID, kind: "stuck", text: "The team is stuck on Stage 1 — S01: Buddy could not apply Chief's add_tasks: At most 12 tasks can be added to one stage; stage 1 has 12. Tell me how to proceed.", chat: true, refs: ["runId": "stuck-run"])
        let stuckBlock = BuddyLiveState.block(plans: BuddyPlanStore.readOnlySummary(support: root, workspace: w), jobs: jobs, state: state, agent: chief, supervises: true, now: now, zone: pacific)
        require(stuckBlock.contains("STUCK: your background supervision has stopped on this plan") && stuckBlock.contains("could not apply Chief's add_tasks") && stuckBlock.contains("Never say you are resolving it")
                && !stuckBlock.contains("Tell me how to proceed"), "the supervisor's state says the plan is stuck, why, and not to promise it: \(stuckBlock)")
        try plans.closeStuckNotices(runIds: ["stuck-run"])
        require(!BuddyLiveState.block(plans: BuddyPlanStore.readOnlySummary(support: root, workspace: w), jobs: jobs, state: state, agent: chief, supervises: true, now: now, zone: pacific).contains("STUCK:"), "once it moves again the line is gone")

        // 2. A direct chat and a group turn carry that same block, and each the agent's latest exchange in the other chat.
        let inGroup = BuddyLiveState.elsewhere(state: state, agent: chief, chat: omori, now: now, zone: pacific)
        let inDirect = BuddyLiveState.elsewhere(state: state, agent: chief, chat: chief, now: now, zone: pacific)
        require(inGroup.contains("Your latest direct chat with the user") && inGroup.contains("Yes, this is the correct published version.") && inGroup.contains("uploaded correct copy of the file"),
                "a group turn sees what the agent and the user said in its direct chat: \(inGroup)")
        require(inDirect.contains("Latest in the Omori group chat") && inDirect.contains("How is S01 going?"), "a direct chat sees the latest group exchange: \(inDirect)")
        require(!inGroup.contains("How is S01 going?") && !inDirect.contains("Yes, this is the correct published version."), "each shows only the other chat")

        // 3. The group round: the coordinator plans from the team's current state and never restates it; each member is told the same block as
        // its direct chat, plus its latest direct exchange, and that this state is newer than the group's messages and its assignment.
        let fake = StateFakeConversations(), team = BuddyTeamService(conversations: fake)
        fake.receiver = { _ = team.consume($0) }
        team.agentInstructions = { _, id in BuddyLiveState.block(plans: summary, jobs: jobs, state: state, agent: id, supervises: id == chief, now: now, zone: pacific) }
        team.groupContext = { _, group, agent in
            agent.map { BuddyLiveState.elsewhere(state: state, agent: $0, chat: group, now: now, zone: pacific) } ?? BuddyLiveState.coordinator(plans: summary, jobs: jobs, state: state, group: group, now: now, zone: pacific)
        }
        let request = BuddyTeamRequest(runId: UUID().uuidString, key: w + ":" + omori, workspace: w, groupId: omori, name: "Omori", objective: "Omori volatility research", text: "Working?",
                                       members: [BuddyTeamAgent(id: chief, name: "Chief", role: "Chief of staff", description: "Supervises"), BuddyTeamAgent(id: forge, name: "Forge", role: "Engineer", description: "Codes")],
                                       history: "You: How is S01 going?\nChief: S01 is PARTIAL; the published PDF is missing.", supervisorId: chief)
        _ = try team.send(request)
        await wait { fake.calls.count == 1 }
        let coordinator = fake.calls[0].options.instructions
        require(coordinator.contains("never as the state of the work") && coordinator.contains("Solved recently (do not bring these up as blockers again):") && coordinator.contains("“S01 caption verification” got what it waited for"),
                "the coordinator plans from the team's current state and does not restate it: \(coordinator)")
        let plan = BuddyTeamPlan(leadId: chief, tasks: [BuddyTeamTask(agentId: chief, task: "Answer whether the team is working.", dependsOn: [])])
        fake.complete(0, text: String(data: try JSONEncoder().encode(plan), encoding: .utf8)!)
        await wait { fake.calls.count == 2 }
        let member = fake.calls[1].options.instructions
        require(member.contains(block) && member.contains(inGroup), "Chief's group turn carries the same state block as its direct chat, and its latest direct exchange")
        require(member.contains("newer than earlier group messages and than your assignment"), "and is told that state wins over older messages: \(member)")
        fake.complete(1, text: "Yes: S01 is running again with the published PDF.")
        await wait { team.snapshots().first?["status"] as? String == "completed" }
        print("PASS: an agent's direct chat and its turn in a group carry the same current state, with waits solved recently and questions the user answered; each sees its latest exchange in the other chat; the group's coordinator plans from that state and never restates it")
    }
}
