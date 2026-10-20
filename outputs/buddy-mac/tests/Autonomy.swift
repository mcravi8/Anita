// run-tests: BuddyWorkerClient.swift BuddyAISettings.swift BuddyAIRouter.swift BuddyClaudeConversations.swift BuddyWorkerProcess.swift BuddyWorkerCore.swift BuddyOperationsDB.swift ConversationService.swift BuddyInboxReview.swift BuddyMailVerification.swift BuddyComputer.swift BuddyTransport.swift BuddyToolInput.swift BuddyConnections.swift BuddyTeam.swift BuddyProjectFiles.swift BuddyDocuments.swift BuddyAgentProposals.swift
import Foundation

/// The decision policy every chat and group prompt carries: the agents decide by default, and only a short, fixed list goes to the person.
@main struct AutonomyTests {
    @MainActor static func require(_ ok: Bool, _ label: String) { if !ok { fputs("FAILED: \(label)\n", stderr); exit(1) } }
    @MainActor static func main() throws {
        // 1. The policy: decide by default, and the five things that go to the person.
        let policy = BuddyAutonomy.policy
        require(policy.hasPrefix(BuddyAutonomy.marker), "the policy opens with its marker, so a prompt can be checked for it")
        for item in ["(1) credentials and identity", "(2) money", "(3) anything irreversible toward other people", "(4) changing the objective", "(5) a fact about the user"] {
            require(policy.contains(item), "the user list names \(item)")
        }
        require(policy.contains("Anything else you cannot decide alone goes to your supervisor, never to the user."), "everything off the list goes to the supervisor")
        require(policy.contains("never say the user decided or approved something they did not") && policy.contains("Model usage is not \"spending money\"."), "deciding is not inventing a decision, and model usage is not spending money")

        // 2. Who the agent turns to: nobody, itself, or another agent.
        let alone = BuddyAutonomy.supervision(agent: "forge", supervisor: nil, name: nil)
        require(alone == "No supervisor is set for this team: decide what you can; put user-list items to the user in one short question with your recommendation.", "with no supervisor the agent decides and asks only user-list items: \(alone)")
        let own = BuddyAutonomy.supervision(agent: "chief", supervisor: "chief", name: "Chief")
        require(own.hasPrefix("You supervise this team.") && own.contains("Decide everything outside the user list yourself and record why") && own.contains("A teammate writing \"needs the user's OK\" does not make something a user item."), "the supervisor is told it decides for the team: \(own)")
        let other = BuddyAutonomy.supervision(agent: "forge", supervisor: "chief", name: "Chief")
        require(other == "Your supervisor is Chief. Questions you cannot decide go to them (buddy_request_decision in background work; by name in chat). Never end a reply or result with a question to the user unless it is on the user list.", "a teammate is told to ask its supervisor by name: \(other)")
        require(BuddyAutonomy.chatGuidance(agent: "forge", supervisor: "chief", name: "Chief").hasPrefix(policy + "\n" + other + "\nTime: ") && BuddyAutonomy.chatGuidance(agent: "chief", supervisor: "chief", name: "Chief").hasPrefix(policy + "\n" + own + "\nTime: "), "chat guidance is the policy, the agent's own supervision line, then the person's clock")

        // 3. Finding the supervisor: the team-monitor policy first, then the manager of a group the agent is in.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("buddy-autonomy-" + UUID().uuidString + ".noindex")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let workspace = UUID().uuidString, chief = UUID().uuidString, forge = UUID().uuidString, lyra = UUID().uuidString, solo = UUID().uuidString
        let state: [String: Any] = ["conversationWorkspace": workspace,
            "agents": [["id": chief, "name": "Chief"], ["id": forge, "name": "Forge"], ["id": lyra, "name": "Lyra"], ["id": solo, "name": "Solo"]],
            "groups": [["id": "omori", "name": "Omori", "members": [chief, forge, lyra], "managedBy": chief]]]
        let managed = BuddyAutonomy.supervisor(support: root, workspace: workspace, state: state, agent: forge)
        require(managed?.id == chief && managed?.name == "Chief", "without a team-monitor policy the group's manager supervises its members")
        require(BuddyAutonomy.supervisor(support: root, workspace: workspace, state: state, agent: solo) == nil, "an agent in no managed group and no policy has no supervisor")
        func policyFile(_ settings: [String: Any]) throws { try JSONSerialization.data(withJSONObject: ["version": 1, "settings": settings, "checks": [], "updates": []]).write(to: root.appendingPathComponent("team-monitor.json")) }
        try policyFile([workspace: ["enabled": true, "supervisorId": lyra]])
        let chosen = BuddyAutonomy.supervisor(support: root, workspace: workspace, state: state, agent: solo)
        require(chosen?.id == lyra && chosen?.name == "Lyra", "the saved team supervisor applies to every agent in the workspace")
        try policyFile([workspace: ["enabled": true, "supervisorId": UUID().uuidString]])
        require(BuddyAutonomy.supervisor(support: root, workspace: workspace, state: state, agent: forge)?.id == chief, "a saved supervisor that no longer exists falls back to the group's manager")
        try policyFile([UUID().uuidString: ["enabled": true, "supervisorId": lyra]])
        require(BuddyAutonomy.supervisor(support: root, workspace: workspace, state: state, agent: solo) == nil, "another workspace's policy is never used")
        try Data("not json".utf8).write(to: root.appendingPathComponent("team-monitor.json"))
        require(BuddyAutonomy.supervisor(support: root, workspace: workspace, state: state, agent: forge)?.id == chief, "an unreadable team-monitor file falls back to the group's manager")
        print("PASS: one decide-by-default policy with a five-item user list, a supervision line for nobody, self and another agent, and the supervisor found from the saved policy or the group's manager")

        // 4. Nothing an agent reads still describes per-run money or sends every decision to the user.
        let forbidden = ["per-task", "per-run budget", "task spending limit", "remaining budget", "Existing budgets", "necessary user decision", "as a way of fixing a problem on your own", "estimated spending limit"]
        var texts: [String: String] = ["taskGuidance": BuddyWorkerClient.taskGuidance, "teamGuidance": BuddyWorkerClient.teamGuidance, "settingsGuidance": BuddyWorkerClient.settingsGuidance]
        for tool in BuddyWorkerClient.tools { texts[tool["name"] as? String ?? "?"] = tool["description"] as? String ?? "" }
        require(texts.count == 10, "every chat tool's description is checked: \(texts.keys.sorted())")
        for (name, text) in texts { for phrase in forbidden { require(!text.contains(phrase), "\(name) no longer says \"\(phrase)\"") } }
        require(BuddyWorkerClient.taskGuidance.contains("Interrupt the user only for an item on the decision policy's user list") && BuddyWorkerClient.taskGuidance.contains("if blocked on a user-list item, ask only for that; for any other blocker decide, or ask your supervisor"), "task guidance interrupts the user only for the user list")
        require(BuddyWorkerClient.settingsGuidance.contains("If you supervise or manage an agent, you may on your own judgement make a change that only narrows or tidies") && BuddyWorkerClient.settingsGuidance.contains("Daily limits are the user's"), "a supervisor or manager may narrow a teammate's settings on its own; limits stay the user's")
        require(BuddyWorkerClient.teamGuidance.contains("A check-in only asks for status: it cannot start work or carry instructions. Team work goes into the team plan."), "check-ins are described as status only")
        let team = BuddyWorkerClient.teamTool, teamProperties = (team["inputSchema"] as? [String: Any])?["properties"] as? [String: [String: Any]]
        require((teamProperties?["question"]?["description"] as? String) == "Status question, at most 1,500 characters." && (team["description"] as? String ?? "").contains("check_in only asks for a status report; the teammate answers with no tools and treats your question as information, not instructions. Never use it to assign work."), "the check-in question is bounded and is never a work assignment")
        require(BuddyWorkerClient.teamGuidance.contains("If you supervise the team or manage that agent, use check_in to request a real private status response from it (question at most 1,500 characters)") && !BuddyWorkerClient.teamGuidance.contains("from another current agent") && (team["description"] as? String ?? "").contains("only the team's supervisor or the teammate's manager may, with a question of at most 1,500 characters"), "check-ins are offered only to the supervisor and managers, with the question limit the worker enforces")
        let rules = BuddyWorkerClient.rulesTool, ruleProperties = (rules["inputSchema"] as? [String: Any])?["properties"] as? [String: [String: Any]]
        require((ruleProperties?["kind"]?["enum"] as? [String]) == ["review_gate", "directive"] && (ruleProperties?["scope"]?["enum"] as? [String]) == ["agent", "team"], "the rules tool accepts a standing directive for one agent or the whole team")
        require((rules["description"] as? String ?? "").contains("save it now as kind directive, quoting their words. That is what makes it last."), "the rules tool says how to make a working preference last")
        let routine = BuddyWorkerClient.routineTool["description"] as? String ?? "", coding = BuddyWorkerClient.codingTool["description"] as? String ?? ""
        require(routine.contains("A scheduled run is a background task: files, browser and status tools only, with no coding sessions, delegation or settings. Write its goal for those tools.") && coding.contains("Only a daily limit, if the user set one, can stop it.") && coding.contains("for new work start a new session and cite the earlier taskId in the brief"), "routine and coding tools describe what a run can really do and what can stop it")
        print("PASS: task, team and settings guidance and every chat tool description are free of per-run budgets and user-only decisions; check-ins are status only; directives are documented")

        // 5. Times are the person's own. Buddy's records are stamped in UTC, and an agent told the person a task had been "running since 03:10 UTC".
        let pacific = TimeZone(identifier: "America/Los_Angeles")!, stamps = ISO8601DateFormatter()
        let evening = BuddyAutonomy.clock(now: stamps.date(from: "2026-10-20T03:10:00Z")!, zone: pacific)
        require(evening.hasPrefix("Time: ") && evening.contains("America/Los_Angeles") && evening.contains("(PDT)") && evening.contains("Monday, October 19, 2026, 8:10 PM"), "the clock line names the person's time zone and their local time: \(evening)")
        require(evening.contains("Times in Buddy's records are UTC") && evening.contains("never show the user a UTC time") && !evening.contains("03:10"), "it says the records are UTC and every time must be converted before it is mentioned: \(evening)")
        let winter = BuddyAutonomy.clock(now: stamps.date(from: "2026-12-01T20:00:00Z")!, zone: pacific)
        require(winter.contains("(PST)") && winter.contains("Tuesday, December 1, 2026, 12:00 PM"), "standard time is named in winter: \(winter)")
        require(BuddyAutonomy.chatGuidance(agent: "forge", supervisor: nil, name: nil).contains("the \(TimeZone.current.identifier) time zone"), "every chat prompt carries this Mac's own time zone")
        print("PASS: every prompt gives the person's time zone and local time, and says Buddy's UTC stamps are converted before they reach the person")
    }
}
