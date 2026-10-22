// run-tests: BuddyWorkerClient.swift BuddyAISettings.swift BuddyAIRouter.swift BuddyClaudeConversations.swift BuddyWorkerProcess.swift BuddyWorkerCore.swift BuddyOperationsDB.swift ConversationService.swift BuddyInboxReview.swift BuddyMailVerification.swift BuddyComputer.swift BuddyTransport.swift BuddyToolInput.swift BuddyConnections.swift BuddyTeam.swift BuddyProjectFiles.swift BuddyDocuments.swift BuddyAgentProposals.swift BuddyPlan.swift
import Foundation

/// The team plan in chat: the buddy_plan tool, the app recognising "get stage N done" itself, and the plan each agent is told about.
@main struct PlanChatTests {
    @MainActor static func require(_ ok: Bool, _ label: String) { if !ok { fputs("FAILED: \(label)\n", stderr); exit(1) } }
    static func scope(_ text: String) -> (through: Int, remainder: String)? { BuddyPlanIntent.scope(text).map { ($0.through, $0.remainder) } }

    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("buddy-plan-chat-" + UUID().uuidString + ".noindex")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let workspace = UUID().uuidString, omori = UUID().uuidString, side = UUID().uuidString
        let chief = UUID().uuidString, forge = UUID().uuidString, lyra = UUID().uuidString, vera = UUID().uuidString
        let state: [String: Any] = ["conversationWorkspace": workspace,
            "agents": [["id": chief, "name": "Chief"], ["id": forge, "name": "Forge"], ["id": lyra, "name": "Lyra"], ["id": vera, "name": "Vera"]],
            "groups": [["id": omori, "name": "Omori", "members": [chief, forge, lyra], "managedBy": chief], ["id": side, "name": "Side", "members": [chief, vera], "managedBy": chief]]]

        // A real plan, kept where the worker keeps it, read the way the app reads it before a chat turn.
        let plans = try BuddyPlanStore(directory: root.appendingPathComponent("Worker"))
        let stages: [[String: Any]] = [["title": "Gather", "goal": "Collect the 2015 to 2024 data", "acceptance": ["data.csv covers every year"]],
                                       ["title": "Report", "goal": "Write the findings", "acceptance": ["report.md signed off by Chief"]]]
        let tasks: [[String: Any]] = [["stage": 1, "key": "t1", "title": "Collect the data", "assignee": forge, "kind": "research", "brief": "Download the yearly tables.", "deliverable": "data.csv"],
                                      ["stage": 1, "key": "t2", "title": "Check the data", "assignee": lyra, "kind": "general", "brief": "Check every year is present.", "deliverable": "a short check note", "dependsOn": ["t1"]]]
        let proposed = try plans.propose(workspace: workspace, groupId: omori, supervisorId: chief, objective: "Ship the Omori analysis", stages: stages, tasks: tasks, members: [chief, forge, lyra], by: chief)
        let planId = proposed["id"] as? String ?? ""
        let escalation = try plans.addNotice(planId: planId, kind: "escalation", text: "Should we buy the 2016 dataset licence for $40? My recommendation: yes, it saves two days. The team keeps working on the rest meanwhile.", chat: true, refs: ["itemKey": "result:x:1"])
        var summary = BuddyPlanStore.readOnlySummary(support: root, workspace: workspace)
        require(summary.count == 1 && summary.first?["id"] as? String == planId, "the app reads the group's draft plan: \(summary.count)")

        // 1. "get stage 1 done" in the group with a live plan is recognised natively, for that plan, with nothing left over.
        let hit = BuddyPlanChat.intercept(scope: scope("get stage 1 done"), plans: summary, chat: omori, agent: nil, isGroup: true)
        require(hit?.planId == planId && hit?.through == 1 && hit?.remainder == "", "get stage 1 done in the group authorizes stage 1 of its plan: \(String(describing: hit))")
        require(BuddyPlanChat.supervisorOnly(remainder: hit?.remainder ?? "x"), "a bare authorization is answered by the supervisor alone")

        // 2. The rest of the message is kept, so its instructions reach the plan.
        let more = BuddyPlanChat.intercept(scope: scope("get stage 1 done and use the 2015 data"), plans: summary, chat: omori, agent: nil, isGroup: true)
        require(more?.planId == planId && more?.through == 1 && more?.remainder == "and use the 2015 data", "the remainder is preserved: \(String(describing: more))")
        require(!BuddyPlanChat.supervisorOnly(remainder: more?.remainder ?? ""), "a message with more to say goes to the normal group round")
        let both = BuddyPlanChat.intercept(scope: scope("Great. Do stages 1 and 2."), plans: summary, chat: omori, agent: nil, isGroup: true)
        require(both?.through == 2, "several stages at once authorize through the last one: \(String(describing: both))")

        // 3. In a direct chat only the plan's supervisor's chat counts, and only when exactly one live plan is theirs.
        let toChief = BuddyPlanChat.intercept(scope: scope("get stage 1 done"), plans: summary, chat: chief, agent: chief, isGroup: false)
        require(toChief?.planId == planId && toChief?.through == 1, "a DM to the plan's supervisor authorizes its plan: \(String(describing: toChief))")
        require(BuddyPlanChat.intercept(scope: scope("get stage 1 done"), plans: summary, chat: forge, agent: forge, isGroup: false) == nil, "a DM to a teammate who does not supervise the plan authorizes nothing")
        require(BuddyPlanChat.intercept(scope: scope("get stage 1 done"), plans: summary, chat: side, agent: nil, isGroup: true) == nil, "another group's chat never authorizes this group's plan")

        // 4. A question about a stage, or no plan at all, is left to the conversation.
        require(scope("what is stage 1?") == nil && BuddyPlanChat.intercept(scope: scope("what is stage 1?"), plans: summary, chat: omori, agent: nil, isGroup: true) == nil, "what is stage 1? authorizes nothing")
        require(BuddyPlanChat.intercept(scope: scope("get stage 1 done"), plans: [], chat: omori, agent: nil, isGroup: true) == nil, "with no plan nothing is authorized")
        var closed = summary[0]; closed["status"] = "achieved"
        require(BuddyPlanChat.intercept(scope: scope("get stage 1 done"), plans: [closed], chat: omori, agent: nil, isGroup: true) == nil, "a finished plan is not live and authorizes nothing")
        _ = try plans.propose(workspace: workspace, groupId: side, supervisorId: chief, objective: "Tidy the side project", stages: stages, tasks: [], members: [chief, vera], by: chief)
        let two = BuddyPlanStore.readOnlySummary(support: root, workspace: workspace)
        require(two.count == 2 && BuddyPlanChat.intercept(scope: scope("get stage 1 done"), plans: two, chat: chief, agent: chief, isGroup: false) == nil, "a DM to a supervisor of two live plans does not guess which one")
        require(BuddyPlanChat.intercept(scope: scope("get stage 1 done"), plans: two, chat: omori, agent: nil, isGroup: true)?.planId == planId, "in a group the group's own plan is used even when its supervisor runs another")

        // 5. What each agent is told: the plan, their tasks, and for the supervisor the questions it forwarded to the user.
        let names = BuddyPlanChat.names(state: state), members = BuddyPlanChat.members(state: state)
        require(names[chief] == "Chief" && names[omori] == "Omori" && members[omori] == [chief, forge, lyra], "names and members come from the workspace: \(names) \(members)")
        let forChief = BuddyPlanChat.context(plans: summary, agent: chief, names: names, members: members)
        require(forChief.contains("Team plan for Omori: Ship the Omori analysis.") && forChief.contains("Stage 1 (proposed): Gather"), "the supervisor is told the plan and its stages: \(forChief)")
        require(forChief.contains("open questions forwarded to the user: [\(escalation)] Should we buy the 2016 dataset licence for $40?") && forChief.contains("My recommendation: yes"), "the context lists open escalations with their id and recommendation: \(forChief)")
        require(forChief.contains("Collect the data → Forge") && forChief.contains("Check the data → Lyra"), "the supervisor sees every task and who has it: \(forChief)")
        require(forChief.contains("No stage is authorized yet") && forChief.contains("Never say a stage is authorized or that work has started"), "a draft is described as running nothing: \(forChief)")
        require(forChief.contains(BuddyPlanChat.notRecorded) && BuddyPlanChat.notRecorded.contains("ask them to tap “Get stage N done”"), "a stage request Buddy did not record is pointed to the stage button, never claimed: \(forChief)")
        let forForge = BuddyPlanChat.context(plans: summary, agent: forge, names: names, members: members)
        require(forForge.contains("Team plan for Omori: Ship the Omori analysis.") && forForge.contains("your tasks: Collect the data (pending)") && !forForge.contains(escalation), "a teammate is told its own tasks and not the supervisor's forwarded questions: \(forForge)")
        require(BuddyPlanChat.context(plans: summary, agent: vera, names: names, members: members).isEmpty, "an agent outside the plan's group, with no tasks in it, is told nothing")
        let refsShape = try plans.addNotice(planId: planId, kind: "escalation", text: "Use the paid API?", chat: true, refs: ["question": "Use the paid API for the 2019 tables?", "recommendation": "no, the free export is enough"])
        let withRefs = BuddyPlanChat.context(plans: BuddyPlanStore.readOnlySummary(support: root, workspace: workspace), agent: chief, names: names, members: members)
        require(withRefs.contains("[\(refsShape)] Use the paid API for the 2019 tables? (your recommendation: no, the free export is enough)"), "an escalation that carries its question and recommendation is shown with both: \(withRefs)")

        // After the user authorizes, the plan reads as authorized and work is started by Buddy, not from chat.
        _ = try plans.authorize(planId: planId, through: 1, quote: "get stage 1 done", messageId: "m1", viaButton: false, now: Date())
        summary = BuddyPlanStore.readOnlySummary(support: root, workspace: workspace).filter { $0["id"] as? String == planId }
        let active = BuddyPlanChat.context(plans: summary, agent: forge, names: names, members: members)
        require(active.contains("Authorized by the user through stage 1 (“get stage 1 done”)") && active.contains(BuddyPlanChat.workFromPlan), "an authorized plan says so, and that plan work is started by Buddy: \(active)")
        require(!active.contains("No stage is authorized yet"), "an authorized plan is not described as a draft")

        // The turn's instructions after the app records the user's authorization, or fails to.
        let note = BuddyPlanChat.authorizedNote(through: 1, supervisor: true)
        require(note.hasPrefix("The user just authorized stage(s) through 1; Buddy recorded it and the team is working.") && note.contains("buddy_plan revise") && note.contains("Do not ask for confirmation."), "the supervisor acknowledges and carries the user's instructions into the plan: \(note)")
        require(!BuddyPlanChat.authorizedNote(through: 1, supervisor: false).contains("buddy_plan revise"), "a teammate is not told to revise a plan it may not revise")
        let failed = BuddyPlanChat.authorizeFailed("Stage 1 is already done.")
        require(failed.hasPrefix("Authorizing failed: Stage 1 is already done.") && failed.contains("offer the menu") && failed.contains("Never say"), "a failed authorization is explained and never claimed: \(failed)")

        // 6. The tool: one action required, the stage question always asked, offered in every chat next to the other tools.
        let tool = BuddyWorkerClient.planTool, schema = tool["inputSchema"] as? [String: Any] ?? [:]
        let description = tool["description"] as? String ?? ""
        require(tool["name"] as? String == "buddy_plan" && schema["required"] as? [String] == ["action"], "the buddy_plan schema requires only action: \(schema["required"] ?? "none")")
        require(description.contains("always ask which stage") && description.contains("Get stage N done"), "the tool says to always ask which stage to get done, and to point to the stage button: \(description)")
        let actions = ((schema["properties"] as? [String: Any])?["action"] as? [String: Any])?["enum"] as? [String]
        require(actions == ["get", "propose", "authorize", "revise", "answer"], "an agent can get, propose, authorize, revise and answer, never stop: \(actions ?? [])")
        let chatNames = BuddyWorkerClient.chatTools.compactMap { $0["name"] as? String }, toolNames = BuddyWorkerClient.tools.compactMap { $0["name"] as? String }
        require(chatNames == toolNames + ["buddy_plan", "buddy_resolve_waiting"], "chat turns, direct and group, are offered every tool plus the plan and handing the user's input to a waiting task: \(chatNames)")
        for phrase in ["per-task", "per-run budget", "task spending limit", "remaining budget", "Existing budgets", "necessary user decision"] { require(!description.contains(phrase), "the plan tool does not say \(phrase)") }

        // 7. One supervisor for a group round: the saved team supervisor (whom the prompts name), else the plan's, else the manager, whoever
        // of them is in the group.
        require(BuddyAutonomy.policySupervisor(support: root, workspace: workspace, state: state) == nil, "with no team policy there is no saved supervisor")
        try JSONSerialization.data(withJSONObject: ["version": 1, "settings": [workspace: ["enabled": true, "supervisorId": lyra]], "checks": [], "updates": []]).write(to: root.appendingPathComponent("team-monitor.json"))
        require(BuddyAutonomy.policySupervisor(support: root, workspace: workspace, state: state) == lyra, "the saved team supervisor is read from the team policy")
        require(BuddyAutonomy.supervisor(support: root, workspace: workspace, state: state, agent: forge)?.id == lyra, "the prompt's lookup still prefers the saved supervisor")
        require(BuddyAutonomy.groupSupervisor(candidates: [lyra, chief, chief], members: [chief, forge, lyra]) == lyra, "the saved supervisor answers first when in the group, as the prompts say")
        require(BuddyAutonomy.groupSupervisor(candidates: [nil, forge, chief], members: [chief, forge, lyra]) == forge, "with no saved supervisor the plan's supervisor answers first in its group")
        require(BuddyAutonomy.groupSupervisor(candidates: [vera, nil, chief], members: [chief, forge, lyra]) == chief, "a saved supervisor outside the group leaves the round to the group's manager")
        require(BuddyAutonomy.groupSupervisor(candidates: [nil, "", nil], members: [chief]) == nil, "with nobody named there is no supervisor")

        // 8. Which chat a tool call came from: a group's turns carry the group in their key.
        require(BuddyPlanChat.chat(scope: nil, key: workspace + ":group:" + omori + ":member-" + forge, workspace: workspace) == omori, "a group turn's key names its group")
        require(BuddyPlanChat.chat(scope: omori, key: "", workspace: workspace) == omori, "the proposal scope names the chat when it is there")
        require(BuddyPlanChat.chat(scope: nil, key: workspace + ":" + chief, workspace: workspace) == chief, "a DM's key names the agent")
        require(BuddyPlanChat.chat(scope: nil, key: UUID().uuidString + ":" + chief, workspace: workspace) == nil, "another workspace's key names nothing")

        // 9. The settings tool says what the settings engine accepts: a supervisor or manager may narrow a teammate without the user's words.
        let settings = BuddyWorkerClient.settingsTool["description"] as? String ?? ""
        require(!settings.contains("only when the user’s current message asks for it") && !settings.contains("you MUST include quote"), "the settings tool no longer says every change needs the user's words: \(settings)")
        require(settings.contains("only narrows") && settings.contains("no quote") && settings.contains("every daily limit still need the user’s own words"), "the settings tool describes judgement narrowing and keeps limits with the user: \(settings)")
        print("PASS: get stage N done is recognised natively for the right plan, the remainder is kept, DMs only for the plan's supervisor, and questions authorize nothing")
        print("PASS: each agent is told its plan, tasks and forwarded questions; buddy_plan is offered in every chat; one supervisor answers first; the settings tool matches the engine")
    }
}
