import Foundation

@MainActor final class FakeConversations: BuddyConversationSending {
    struct Call { let payload: [String: Any]; let options: BuddyTurnOptions }
    var calls: [Call] = [], stopped: [String] = []
    var receiver: (([String: Any]) -> Void)?
    func send(_ payload: [String: Any], options: BuddyTurnOptions) throws -> [String: Any] {
        calls.append(Call(payload: payload, options: options)); return ["accepted": true]
    }
    func stop(_ id: String) async throws -> [String: Any] { stopped.append(id); receiver?(["type": "run", "runId": id, "status": "stopped", "internal": true]); return ["stopped": true] }
    func complete(_ index: Int, text: String, status: String = "completed") {
        let call = calls[index]; receiver?(["type": "run", "runId": call.payload["runId"]!, "status": status, "text": text, "error": status == "failed" ? text : "", "internal": true])
    }
}
@main struct TeamworkTests {
    @MainActor static func require(_ condition: Bool, _ message: String) { if !condition { fputs("FAILED: \(message)\n", stderr); exit(1) } }
    @MainActor static func wait(_ predicate: () -> Bool) async {
        for _ in 0..<200 { if predicate() { return }; try? await Task.sleep(nanoseconds: 5_000_000) }
        require(false, "asynchronous teamwork fixture timed out")
    }
    static let members = [BuddyTeamAgent(id: "writer", name: "Write Bot", role: "Writer", description: "Current writing instruction"), BuddyTeamAgent(id: "reviewer", name: "Review Bot", role: "Reviewer", description: "Current review instruction"), BuddyTeamAgent(id: "researcher", name: "Search Bot", role: "Research", description: "Find evidence")]
    static func request(members: [BuddyTeamAgent] = members, group: String = "group", text: String = "work together on an announcement") -> BuddyTeamRequest {
        let workspace = UUID().uuidString
        return BuddyTeamRequest(runId: UUID().uuidString, key: workspace + ":" + group, workspace: workspace, groupId: group, name: "Launch", objective: "Clear and accurate", text: text, members: members, history: "You: Our event is Sunday.")
    }
    @MainActor static func fixture() -> (FakeConversations, BuddyTeamService) {
        let fake = FakeConversations(), team = BuddyTeamService(conversations: fake)
        fake.receiver = { _ = team.consume($0) }; return (fake, team)
    }
    @MainActor static func main() async throws {
        let combinedTools = BuddyProjectFiles.tools + BuddyAgentProposals.tools
        require(combinedTools.allSatisfy { $0["type"] as? String == "function" } && Set(combinedTools.compactMap { $0["name"] as? String }).count == combinedTools.count, "file and proposal tools use one canonical format without name collisions")
        print("PASS: files and proposals can share the same canonical tool configuration")
        let reviewFake = FakeConversations(), reviewTeam = BuddyTeamService(conversations: reviewFake, turnTimeoutNanoseconds: 100_000_000)
        reviewFake.receiver = { _ = reviewTeam.consume($0) }
        let reviewRequest = request(members: [members[0]], group: "review")
        _ = try reviewTeam.send(reviewRequest); await wait { reviewFake.calls.count == 1 }
        let reviewChild = reviewFake.calls[0].payload["runId"] as! String
        _ = reviewTeam.consume(["type": "tool-input", "runId": reviewRequest.runId, "executionRunId": reviewChild, "request": ["id": "review", "status": "pending"]])
        try await Task.sleep(nanoseconds: 250_000_000)
        require(reviewFake.stopped.isEmpty && reviewTeam.snapshots().first?["status"] as? String == "answering", "group deadline pauses for actual user review")
        _ = reviewTeam.consume(["type": "tool-input", "runId": reviewRequest.runId, "executionRunId": reviewChild, "request": ["id": "review", "status": "answered"]])
        reviewFake.complete(0, text: "Confirmed test action."); await wait { reviewTeam.snapshots().first?["status"] as? String == "completed" }
        print("PASS: group review attaches to parent reply, pauses worker timeout, and resumes after decision")
        var r = request(text: "@Review Bot work together on an announcement"); r.fileScope = BuddyFileScope(workspace: r.workspace, folderId: r.workspace)
        require(r.mentionedIds == ["reviewer"], "actual mentions resolve by full agent name")
        let ignoring = BuddyTeamPlan(leadId: "writer", tasks: [BuddyTeamTask(agentId: "writer", task: "Write", dependsOn: [])])
        let honored = BuddyTeamService.honoringMentions(ignoring, request: r)
        require(honored.tasks.map(\.agentId) == ["writer", "reviewer"], "an agent the person mentioned is not left out of the plan: \(honored.tasks.map(\.agentId))")
        let direct = BuddyTeamService.honoringMentions(BuddyTeamPlan(leadId: "writer", tasks: []), request: r)
        require(direct.leadId == "reviewer" && direct.tasks.isEmpty, "one mentioned agent answers a request nobody else was assigned")
        let plain = request(members: [members[0]])
        require(plain.mentionedIds.isEmpty && BuddyTeamService.honoringMentions(ignoring, request: plain) == ignoring, "a request that mentions nobody is left as planned")
        let plan = BuddyTeamPlan(leadId: "reviewer", tasks: [BuddyTeamTask(agentId: "writer", task: "Write a draft", dependsOn: []), BuddyTeamTask(agentId: "researcher", task: "Find evidence", dependsOn: []), BuddyTeamTask(agentId: "reviewer", task: "Review both contributions", dependsOn: ["writer", "researcher"])])
        let planText = String(data: try JSONEncoder().encode(plan), encoding: .utf8)!
        require(try BuddyTeamPlan.decode(planText, members: members) == plan, "valid dependencies are accepted")
        for bad in [BuddyTeamPlan(leadId: "outsider", tasks: []), BuddyTeamPlan(leadId: "writer", tasks: [BuddyTeamTask(agentId: "writer", task: "draft", dependsOn: ["reviewer"]), BuddyTeamTask(agentId: "reviewer", task: "review", dependsOn: ["writer"])]), BuddyTeamPlan(leadId: "writer", tasks: [BuddyTeamTask(agentId: "writer", task: "draft", dependsOn: ["missing"])])] {
            var rejected = false
            do { _ = try BuddyTeamPlan.decode(String(data: JSONEncoder().encode(bad), encoding: .utf8)!, members: members) } catch { rejected = true }
            require(rejected, "outsiders, cycles, and missing dependencies are rejected")
        }
        var state: [String: Any] = ["conversationWorkspace": r.workspace, "hiddenAgents": members.map { $0.id }, "agents": members.map { ["id": $0.id, "name": $0.name, "role": $0.role, "description": $0.description] }, "groups": [["id": r.groupId, "name": r.name, "objective": r.objective, "members": members.map(\.id)]], "runs": [r.runId: ["userId": "current"]], "messages": [r.groupId: [["id": "sample", "who": "you", "body": "EXAMPLE_NOT_REAL"], ["id": "earlier", "who": "you", "body": "GROUP_HISTORY", "live": true], ["id": "current", "who": "you", "body": "CURRENT_REQUEST_DUPLICATE", "live": true]], "writer": [["who": "you", "body": "PRIVATE_DM_HISTORY", "live": true]]]]
        let parsed = try BuddyTeamRequest.from(workspace: state, payload: ["runId": r.runId, "groupId": r.groupId, "key": r.key, "text": r.text, "members": ["outsider"]])
        require(parsed.members == members && parsed.history == "You: GROUP_HISTORY", "native registered group/settings are authoritative; samples, private DMs, and current request are excluded")
        state["groups"] = [["id": r.groupId, "name": r.name, "objective": r.objective, "members": ["writer", "writer"]]]
        var rejected = false
        do { _ = try BuddyTeamRequest.from(workspace: state, payload: ["runId": r.runId, "groupId": r.groupId, "key": r.key, "text": r.text]) } catch { rejected = true }
        require(rejected, "duplicate native group members are rejected")
        // A reply is failed for a missing receipt only when it claims the thing was done; a plain answer to a question that merely sounded like a request is left alone.
        for text in ["Yes, I will run this every morning.", "Done. I’ve scheduled it for 9:00 each day.", "Your routine is saved; next run is tomorrow at 9:00.", "I'll check your inbox daily."] { require(BuddyReplyClaims.schedule(text), "claims a schedule: \(text)") }
        for text in ["I'll run the pipeline now and report the exponents.", "Here are the daily VIX figures for COVID.", "Done. The weekly returns file is reviewed.", "I haven't scheduled anything yet.", "The schedule wasn't saved.", "I'll review the weekly returns file and tell you what changed.", "Yes: the same checks make sense, but I can't promise more.", "Both look right."] { require(!BuddyReplyClaims.schedule(text), "makes no scheduling claim: \(text)") }
        for text in ["Done. I saved that rule and will follow it from now on.", "Got it — the rule is saved.", "I’ll follow that."] { require(BuddyReplyClaims.rule(text), "claims a rule: \(text)") }
        for text in ["Here is the CV for you to check.", "I didn't save a rule because the wording was unclear.", "The first three applications are ready."] { require(!BuddyReplyClaims.rule(text), "makes no rule claim: \(text)") }
        for text in ["I'll keep you posted on what Forge finds.", "Proactive updates are on.", "I'll stop messaging you unless you ask."] { require(BuddyReplyClaims.proactive(text), "claims an update preference: \(text)") }
        for text in ["Forge is still re-running the pipeline.", "Here is the status.", "Updates are in the report."] { require(!BuddyReplyClaims.proactive(text), "makes no update claim: \(text)") }
        // What is replayed to a model each turn leaves out the agent's own status bubbles and is bounded.
        let historyState:[String:Any]=["messages":["chief":[["id":"1","who":"you","live":true,"body":"Where are we?"],["id":"2","who":"chief","live":true,"status":"completed","teamUpdate":true,"body":"STATUS BUBBLE"],["id":"3","who":"chief","live":true,"status":"completed","body":"A real answer."]] + (0..<200).map { n in ["id":"b\(n)","who":"you","live":true,"body":String(repeating:"x",count:1000)] as [String:Any] }]]
        let replay = BuddyConversationHistory.context(historyState, target: "chief", runId: UUID().uuidString)
        require(!replay.contains("STATUS BUBBLE") && replay.utf8.count < 70_000 && replay.contains("buddy_read_chat_history"), "replayed history leaves out status bubbles, stays bounded, and points to the tool for older messages")
        print("PASS: group registration, current configurations, isolated history, mentions, and bounded valid plans")

        let (fake, team) = fixture(); _ = try team.send(r); _ = try team.send(r)
        await wait { fake.calls.count == 1 }
        require(fake.calls[0].options.fileScope == nil && fake.calls[0].options.fileContext == r.fileScope, "planner knows the workers’ file access without receiving file tools")
        require(fake.calls[0].options.outputSchema != nil && !fake.calls[0].options.toolsEnabled, "coordinator uses structured planning without service tools")
        fake.complete(0, text: planText)
        await wait { fake.calls.count == 3 }
        require(Set(fake.calls[1...2].compactMap { ($0.payload["agent"] as? [String: String])?["name"] }) == ["Write Bot", "Search Bot"], "independent agents start together before either is completed")
        require(fake.calls.allSatisfy { $0.options.permissionKeys == r.permissionKeys && $0.options.internalRun && $0.options.finalAnswerOnly }, "every internal turn has common group access and private final-only work")
        // The two start together, so which of them is call 1 is not fixed: find each by name.
        func call(of name: String) -> Int { fake.calls.firstIndex { ($0.payload["agent"] as? [String: String])?["name"] == name }! }
        let writeCall = call(of: "Write Bot"), searchCall = call(of: "Search Bot")
        require((fake.calls[writeCall].payload["text"] as? String)?.contains("Current writing instruction") == true, "workers receive current configuration and group history")
        require(fake.calls[1...2].allSatisfy { $0.options.fileScope == r.fileScope }, "workers use the same trusted shared folder")
        fake.receiver?(["type": "file", "runId": fake.calls[writeCall].payload["runId"]!, "file": ["path": "actual.md", "folderId": r.workspace, "revision": "test-hash", "actorName": "Write Bot"], "internal": true])
        fake.complete(writeCall, text: "ACTUAL_FIRST_WORK"); fake.complete(searchCall, text: "ACTUAL_SECOND_WORK")
        await wait { fake.calls.count == 4 }
        let handoff = fake.calls[3].payload["text"] as? String ?? ""
        require(handoff.contains("ACTUAL_FIRST_WORK") && handoff.contains("ACTUAL_SECOND_WORK"), "reviewer receives actual completed dependency work")
        fake.complete(3, text: "ACTUAL_REVIEW")
        await wait { team.snapshots()[0]["status"] as? String == "completed" }
        require(fake.calls.count == 4, "nobody is asked to combine what the agents said: each agent's reply is its own message")
        let said = team.snapshots()[0]["text"] as? String ?? ""
        require(team.snapshots().count == 1 && said == "Write Bot: ACTUAL_FIRST_WORK\n\nSearch Bot: ACTUAL_SECOND_WORK\n\nReview Bot: ACTUAL_REVIEW", "the run keeps what each agent said, in order and under its name, for history and search: \(said)")
        require((team.snapshots()[0]["team"] as? [String: Any])?["direct"] as? Bool == false && (team.snapshots()[0]["files"] as? [[String: Any]])?.first?["path"] as? String == "actual.md", "the run says agents answered for themselves, and the saved-file receipt is kept")
        let recordedEntries=(team.snapshots()[0]["team"] as! [String:Any])["entries"] as! [[String:Any]]
        require(recordedEntries.allSatisfy { ($0["startedAt"] as? String).flatMap { ISO8601DateFormatter().date(from:$0) } != nil && ($0["finishedAt"] as? String).flatMap { ISO8601DateFormatter().date(from:$0) } != nil }, "group contributions retain actual start and finish timestamps for the chat timeline")
        require(recordedEntries.map { $0["notes"] as? String ?? "" } == ["ACTUAL_FIRST_WORK", "ACTUAL_SECOND_WORK", "ACTUAL_REVIEW"], "each agent's message is its own entry, in full")
        print("PASS: independent parallel work, dependent handoffs, private internal turns, scoped permissions, and each agent answering in its own message with nothing combined")

        let (failureFake, failureTeam) = fixture(), failureRequest = request()
        _ = try failureTeam.send(failureRequest); await wait { failureFake.calls.count == 1 }
        let failedPlan = BuddyTeamPlan(leadId: "writer", tasks: [BuddyTeamTask(agentId: "researcher", task: "Read evidence", dependsOn: []), BuddyTeamTask(agentId: "reviewer", task: "Review evidence", dependsOn: ["researcher"])])
        failureFake.complete(0, text: String(data: try JSONEncoder().encode(failedPlan), encoding: .utf8)!)
        await wait { failureFake.calls.count == 2 }; failureFake.complete(1, text: "Connection unavailable", status: "failed")
        await wait { failureTeam.snapshots()[0]["status"] as? String == "failed" }
        let failedEntries = (failureTeam.snapshots()[0]["team"] as? [String: Any])?["entries"] as? [[String: Any]] ?? []
        require(failureFake.calls.count == 2 && failedEntries.map { $0["status"] as? String ?? "" } == ["failed", "blocked"], "a review that depends on failed work is blocked, not asked for, and nothing is combined")
        require((failureTeam.snapshots()[0]["error"] as? String)?.contains("None of the teammates could finish") == true && (failedEntries[0]["error"] as? String)?.contains("Connection unavailable") == true, "when nobody could finish, the group says so and each failure stays visible")
        // One agent finishes and another does not: the finished one's message stands, and the failure stays visible and retryable.
        let (partialFake, partialTeam) = fixture(), partialRequest = request()
        _ = try partialTeam.send(partialRequest); await wait { partialFake.calls.count == 1 }
        let partialPlan = BuddyTeamPlan(leadId: "writer", tasks: [BuddyTeamTask(agentId: "writer", task: "Write", dependsOn: []), BuddyTeamTask(agentId: "researcher", task: "Search", dependsOn: [])])
        partialFake.complete(0, text: String(data: try JSONEncoder().encode(partialPlan), encoding: .utf8)!)
        await wait { partialFake.calls.count == 3 }
        let writerIndex = partialFake.calls.firstIndex { ($0.payload["agent"] as? [String: String])?["name"] == "Write Bot" }!, searchIndex = partialFake.calls.firstIndex { ($0.payload["agent"] as? [String: String])?["name"] == "Search Bot" }!
        partialFake.complete(writerIndex, text: "WRITER_SAYS"); partialFake.complete(searchIndex, text: "Search is down", status: "failed")
        await wait { partialTeam.snapshots()[0]["status"] as? String == "completed" }
        require(partialTeam.snapshots()[0]["text"] as? String == "Write Bot: WRITER_SAYS" && (partialTeam.snapshots()[0]["team"] as? [String: Any])?["partial"] as? Bool == true && partialFake.calls.count == 3, "partial failure keeps the agent that finished and stays visible and retryable")
        // Nobody needed: the spokesperson simply answers.
        let (directFake, directTeam) = fixture(), directRequest = request()
        _ = try directTeam.send(directRequest); await wait { directFake.calls.count == 1 }
        directFake.complete(0, text: String(data: try JSONEncoder().encode(BuddyTeamPlan(leadId: "reviewer", tasks: [])), encoding: .utf8)!)
        await wait { directFake.calls.count == 2 }
        require((directFake.calls[1].payload["agent"] as? [String: String])?["name"] == "Review Bot", "with no assignments the spokesperson answers")
        directFake.complete(1, text: "JUST_ONE_ANSWER"); await wait { directTeam.snapshots()[0]["status"] as? String == "completed" }
        require(directTeam.snapshots()[0]["text"] as? String == "JUST_ONE_ANSWER" && (directTeam.snapshots()[0]["team"] as? [String: Any])?["direct"] as? Bool == true, "a request nobody else needed is one agent's own answer")
        // Someone the person wrote "@" to is asked, even when the coordinator did not pick them.
        let (mentionFake, mentionTeam) = fixture(), mentionRequest = request(text: "@Review Bot are we ready to publish?")
        _ = try mentionTeam.send(mentionRequest); await wait { mentionFake.calls.count == 1 }
        mentionFake.complete(0, text: String(data: try JSONEncoder().encode(BuddyTeamPlan(leadId: "writer", tasks: [BuddyTeamTask(agentId: "writer", task: "Write", dependsOn: [])])), encoding: .utf8)!)
        await wait { mentionFake.calls.count == 3 }
        require(Set(mentionFake.calls[1...2].compactMap { ($0.payload["agent"] as? [String: String])?["name"] }) == ["Write Bot", "Review Bot"], "the mentioned agent is asked even though the coordinator left them out")
        // The chat already shows who is speaking, so a label the agent put on its own message is taken off.
        let label = BuddyTeamService.withoutSpeakerLabel
        require(label("Forge: microstage 1 is not done.", "Forge") == "microstage 1 is not done." && label("**Chief:** Start at the first microstage", "Chief") == "Start at the first microstage" && label("**Lyra: Research-track plan (draft)**\n\nBody", "Lyra") == "**Research-track plan (draft)**\n\nBody" && label("## Vera: Plan\nBody", "Vera") == "## Plan\nBody" && label("  forge : lower case works", "Forge") == "lower case works", "a leading name and colon is removed, keeping a heading's own formatting")
        require(label("Forgery: not a label", "Forge") == "Forgery: not a label" && label("Forge is blocked: no tool.", "Forge") == "Forge is blocked: no tool." && label("Forge:", "Forge") == "Forge:" && label("I asked Forge: is it done?", "Forge") == "I asked Forge: is it done?" && label("Plain text", "") == "Plain text", "a name that is part of the sentence, or a reply that is only a label, is left alone")
        print("PASS: worker failures block dependent work and stay visible, a finished agent's message survives another's failure, and an unneeded team leaves one agent answering")

        let (stopFake, stopTeam) = fixture(), stopRequest = request()
        _ = try stopTeam.send(stopRequest); await wait { stopFake.calls.count == 1 }
        stopFake.complete(0, text: planText); await wait { stopFake.calls.count == 3 }
        _ = try await stopTeam.stop(stopRequest.runId)
        await wait { stopTeam.snapshots()[0]["status"] as? String == "stopped" }
        stopFake.complete(1, text: "LATE_WORK"); stopFake.complete(2, text: "LATE_WORK")
        try? await Task.sleep(nanoseconds: 30_000_000)
        require(stopFake.stopped.count == 2 && stopFake.calls.count == 3 && stopTeam.snapshots()[0]["text"] as? String == "", "stop interrupts every running agent and prevents late replies or handoffs")
        print("PASS: Stop cancels concurrent workers and late results cannot reopen the group reply")
        let (abortFake, abortTeam) = fixture(), abortRequest = request()
        _ = try abortTeam.send(abortRequest); await wait { abortFake.calls.count == 1 }
        abortFake.complete(0, text: planText); await wait { abortFake.calls.count == 3 }
        abortFake.complete(1, text: "", status: "stopped")
        await wait { abortTeam.snapshots()[0]["status"] as? String == "stopped" }
        require(abortFake.stopped.count == 1 && abortFake.calls.count == 3, "an interrupted worker stops its remaining peer and prevents synthesis")
        print("PASS: an unexpected worker interruption cancels the remaining group work")


        let (singleFake, singleTeam) = fixture(), singleRequest = request(members: [members[0]])
        _ = try singleTeam.send(singleRequest); await wait { singleFake.calls.count == 1 }
        require(singleFake.calls[0].options.toolsEnabled && singleFake.calls[0].options.outputSchema == nil, "single-member groups answer directly with allowed reading tools")
        singleFake.complete(0, text: "Simple reply"); await wait { singleTeam.snapshots()[0]["status"] as? String == "completed" }
        print("PASS: simple one-agent group requests avoid unnecessary coordination")

        // The group's supervisor answers first; what it decides reaches the teammates it directs before they start.
        let omori = [BuddyTeamAgent(id: "chief", name: "Chief", role: "Chief of staff", description: "Supervise the study"), BuddyTeamAgent(id: "forge", name: "Forge", role: "Engineer", description: "Run the pipeline"), BuddyTeamAgent(id: "lyra", name: "Lyra", role: "Researcher", description: "Review literature")]
        var supervised = request(members: omori, text: "keep working on the study"); supervised.supervisorId = "chief"
        let (supFake, supTeam) = fixture(); _ = try supTeam.send(supervised); await wait { supFake.calls.count == 1 }
        let parallel = BuddyTeamPlan(leadId: "chief", tasks: [BuddyTeamTask(agentId: "forge", task: "Re-run the pipeline", dependsOn: []), BuddyTeamTask(agentId: "lyra", task: "Review the literature", dependsOn: []), BuddyTeamTask(agentId: "chief", task: "Decide what comes next", dependsOn: [])])
        supFake.complete(0, text: String(data: try JSONEncoder().encode(parallel), encoding: .utf8)!)
        await wait { supFake.calls.count == 2 }
        try await Task.sleep(nanoseconds: 50_000_000)
        func speaker(_ call: FakeConversations.Call) -> String { (call.payload["agent"] as? [String: String])?["name"] ?? "" }
        require(supFake.calls.count == 2 && speaker(supFake.calls[1]) == "Chief", "nothing goes to Forge or Lyra before the supervisor has answered: \(supFake.calls.map(speaker))")
        supFake.complete(1, text: "CHIEF_DECIDED: Forge re-runs v2 only")
        await wait { supFake.calls.count == 4 }
        let forgeIndex = supFake.calls.firstIndex { speaker($0) == "Forge" }!, lyraIndex = supFake.calls.firstIndex { speaker($0) == "Lyra" }!
        require((supFake.calls[forgeIndex].payload["text"] as? String)?.contains("CHIEF_DECIDED: Forge re-runs v2 only") == true && (supFake.calls[lyraIndex].payload["text"] as? String)?.contains("Chief’s completed contribution") == true, "the teammates are handed the supervisor's decision")
        supFake.complete(forgeIndex, text: "FORGE_DONE"); supFake.complete(lyraIndex, text: "LYRA_DONE")
        await wait { supTeam.snapshots()[0]["status"] as? String == "completed" }
        let supervisorPlan = BuddyTeamService.supervisorFirst(parallel, supervisor: "chief")
        require(supervisorPlan.tasks.first { $0.agentId == "chief" }?.dependsOn == [] && supervisorPlan.tasks.filter { $0.agentId != "chief" }.allSatisfy { $0.dependsOn == ["chief"] } && BuddyTeamService.supervisorFirst(parallel, supervisor: "nobody") == parallel && BuddyTeamService.supervisorFirst(parallel, supervisor: nil) == parallel, "only a supervisor who has an assignment is ordered first")
        let reviewFirst = BuddyTeamPlan(leadId: "chief", tasks: [BuddyTeamTask(agentId: "forge", task: "Draft", dependsOn: []), BuddyTeamTask(agentId: "chief", task: "Review the draft", dependsOn: ["forge"])])
        require((try? BuddyTeamPlan.decode(String(data: JSONEncoder().encode(BuddyTeamService.supervisorFirst(reviewFirst, supervisor: "chief")), encoding: .utf8)!, members: omori)) != nil, "ordering the supervisor first never makes a circle")
        var managedState: [String: Any] = ["conversationWorkspace": supervised.workspace, "agents": omori.map { ["id": $0.id, "name": $0.name, "role": $0.role, "description": $0.description] }, "groups": [["id": supervised.groupId, "name": supervised.name, "objective": supervised.objective, "members": omori.map(\.id), "managedBy": "chief"]], "runs": [String: Any](), "messages": [String: Any]()]
        require(try BuddyTeamRequest.from(workspace: managedState, payload: ["runId": supervised.runId, "groupId": supervised.groupId, "key": supervised.key, "text": "go"]).supervisorId == "chief", "the group's manager is its supervisor")
        managedState["groups"] = [["id": supervised.groupId, "name": supervised.name, "objective": supervised.objective, "members": ["forge", "lyra"], "managedBy": "chief"]]
        require(try BuddyTeamRequest.from(workspace: managedState, payload: ["runId": supervised.runId, "groupId": supervised.groupId, "key": supervised.key, "text": "go"]).supervisorId == nil, "a manager who is not in the group does not supervise its reply")
        print("PASS: the group's supervisor answers before the teammates it directs, and they receive its decision")

        // A fourth agent the person names is asked, not dropped.
        let four = members + [BuddyTeamAgent(id: "vera", name: "Vera", role: "Verifier", description: "Check the filter rules")]
        let crowded = request(members: four, text: "@Vera please sign off the filter rules")
        let full = BuddyTeamPlan(leadId: "writer", tasks: [BuddyTeamTask(agentId: "writer", task: "Write", dependsOn: []), BuddyTeamTask(agentId: "reviewer", task: "Review", dependsOn: ["writer"]), BuddyTeamTask(agentId: "researcher", task: "Search", dependsOn: [])])
        require(BuddyTeamService.honoringMentions(full, request: crowded).tasks.map(\.agentId) == ["writer", "reviewer", "researcher", "vera"], "a fourth mentioned member is added to a plan that already has three assignments")
        let fourTasks = BuddyTeamPlan(leadId: "writer", tasks: full.tasks + [BuddyTeamTask(agentId: "vera", task: "Sign off", dependsOn: ["reviewer"])])
        require((try? BuddyTeamPlan.decode(String(data: JSONEncoder().encode(fourTasks), encoding: .utf8)!, members: four)) == fourTasks, "a plan with four assignments is valid")
        require((((BuddyTeamPlan.schema(memberIds: four.map(\.id))["properties"] as? [String: Any])?["tasks"] as? [String: Any])?["maxItems"] as? Int) == 6, "the coordinator may assign up to six members")
        let (mentionFourFake, mentionFourTeam) = fixture(); _ = try mentionFourTeam.send(crowded); await wait { mentionFourFake.calls.count == 1 }
        mentionFourFake.complete(0, text: String(data: try JSONEncoder().encode(full), encoding: .utf8)!)
        await wait { mentionFourFake.calls.count >= 3 }
        require(mentionFourFake.calls.contains { speaker($0) == "Vera" }, "the named fourth member actually receives an assignment: \(mentionFourFake.calls.map(speaker))")
        _ = try await mentionFourTeam.stop(crowded.runId)
        print("PASS: a fourth @mentioned member is not dropped and plans may hold up to six assignments")

        // A teammate that keeps working is not cut off at the inactivity deadline; one that goes quiet is, and nothing runs for ever.
        BuddyTeamService.contributionTimeout = 2
        let (busyFake, busyTeam) = fixture(), busyRequest = request(members: [members[0]], group: "busy")
        _ = try busyTeam.send(busyRequest); await wait { busyFake.calls.count == 1 }
        let busyChild = busyFake.calls[0].payload["runId"] as! String
        for _ in 0..<5 { try await Task.sleep(nanoseconds: 1_000_000_000); _ = busyTeam.consume(["type": "tool", "runId": busyChild, "tool": "buddy_read_file", "status": "completed", "internal": true]) }
        require(busyFake.stopped.isEmpty && busyTeam.snapshots()[0]["status"] as? String == "answering", "a contribution emitting a tool event every second for five seconds is not timed out by a two-second deadline")
        busyFake.complete(0, text: "STILL_WORKING_DONE"); await wait { busyTeam.snapshots()[0]["status"] as? String == "completed" }
        let (quietFake, quietTeam) = fixture(), quietRequest = request(members: [members[0]], group: "quiet")
        _ = try quietTeam.send(quietRequest); await wait { quietFake.calls.count == 1 }
        try await Task.sleep(nanoseconds: 2_600_000_000)
        require(quietTeam.snapshots()[0]["status"] as? String == "failed" && (quietTeam.snapshots()[0]["error"] as? String)?.contains("took too long") == true && quietFake.stopped.count == 1, "a contribution with no activity for the deadline is stopped")
        BuddyTeamService.contributionCap = 3
        let (cappedFake, cappedTeam) = fixture(), cappedRequest = request(members: [members[0]], group: "capped")
        _ = try cappedTeam.send(cappedRequest); await wait { cappedFake.calls.count == 1 }
        let cappedChild = cappedFake.calls[0].payload["runId"] as! String
        for _ in 0..<4 { try await Task.sleep(nanoseconds: 1_000_000_000); _ = cappedTeam.consume(["type": "run", "runId": cappedChild, "status": "answering", "text": "still going", "internal": true]) }
        try await Task.sleep(nanoseconds: 300_000_000)
        require(cappedTeam.snapshots()[0]["status"] as? String == "failed" && cappedFake.stopped.count == 1, "activity cannot keep one contribution running past the absolute cap")
        BuddyTeamService.contributionTimeout = 180; BuddyTeamService.contributionCap = 30 * 60
        print("PASS: the contribution deadline re-arms on every tool or run event, a silent contribution still times out, and an absolute cap holds")

        // What the person says to an agent in a group reaches that agent's direct chat; the rest of the group's traffic does not.
        let dmState: [String: Any] = ["agents": [["id": "chief", "name": "Chief"], ["id": "forge", "name": "Forge"]],
            "groups": [["id": "omori", "name": "Omori", "members": ["chief", "forge"]], ["id": "other", "name": "Elsewhere", "members": ["forge"]]],
            "messages": ["chief": [["id": "d1", "who": "you", "live": true, "body": "DIRECT_QUESTION", "createdAt": "2026-10-18T19:00:00Z"]],
                         "omori": [["id": "g1", "who": "you", "live": true, "body": "@Chief do X", "createdAt": "2026-10-18T19:46:00Z"], ["id": "g2", "who": "you", "live": true, "body": "@Forge FORGE_ONLY", "createdAt": "2026-10-18T19:47:00Z"], ["id": "g3", "who": "you", "live": true, "body": "you guys keep working", "createdAt": "2026-10-18T19:48:00Z"], ["id": "g4", "who": "chief", "status": "completed", "live": true, "body": "AGENT_REPLY", "createdAt": "2026-10-18T19:49:00Z"], ["id": "g5", "who": "you", "body": "SAMPLE_NOT_LIVE", "createdAt": "2026-10-18T19:50:00Z"], ["id": "g6", "who": "you", "live": true, "body": "@Chief " + String(repeating: "y", count: 3000), "createdAt": "2026-10-18T19:51:00Z"]],
                         "other": [["id": "o1", "who": "you", "live": true, "body": "NOT_CHIEFS_GROUP", "createdAt": "2026-10-18T19:52:00Z"]]]]
        let dm = BuddyConversationHistory.context(dmState, target: "chief", runId: UUID().uuidString)
        require(dm.contains("You, in group Omori: @Chief do X") && dm.contains("You, in group Omori: you guys keep working") && dm.contains("DIRECT_QUESTION"), "the person's group messages to this agent or to everyone reach its direct chat: \(dm.prefix(600))")
        require(!dm.contains("FORGE_ONLY") && !dm.contains("AGENT_REPLY") && !dm.contains("SAMPLE_NOT_LIVE") && !dm.contains("NOT_CHIEFS_GROUP") && !dm.contains(String(repeating: "y", count: 1300)), "messages to someone else, agents' replies, samples, other groups and overlong text are left out")
        let many: [String: Any] = ["agents": [["id": "chief", "name": "Chief"]], "groups": [["id": "omori", "name": "Omori", "members": ["chief"]]], "messages": ["omori": (0..<15).map { ["id": "m\($0)", "who": "you", "live": true, "body": "GROUP_NOTE_\($0)_", "createdAt": String(format: "2026-10-18T19:%02d:00Z", $0)] as [String: Any] }]]
        let recent = BuddyConversationHistory.context(many, target: "chief", runId: UUID().uuidString)
        require(!recent.contains("GROUP_NOTE_4_") && recent.contains("GROUP_NOTE_5_") && recent.contains("GROUP_NOTE_14_"), "only the person's last ten group messages are carried")
        // Group history keeps more of the latest messages, where the current thread usually is.
        var longState: [String: Any] = ["conversationWorkspace": r.workspace, "agents": members.map { ["id": $0.id, "name": $0.name, "role": $0.role, "description": $0.description] }, "groups": [["id": r.groupId, "name": r.name, "objective": r.objective, "members": members.map(\.id)]], "runs": [String: Any]()]
        longState["messages"] = [r.groupId: (0..<5).map { ["id": "l\($0)", "who": "you", "live": true, "body": "L\($0)" + String(repeating: "z", count: 5000)] as [String: Any] }]
        let longHistory = try BuddyTeamRequest.from(workspace: longState, payload: ["runId": UUID().uuidString, "groupId": r.groupId, "key": r.key, "text": "next"]).history.components(separatedBy: "\n\n")
        require(longHistory.map(\.count) == [1205, 1205, 4005, 4005, 4005],"the last three group messages keep 4,000 characters and earlier ones 1,200: \(longHistory.map(\.count))")
        print("PASS: the person's group messages addressed to an agent reach its direct chat, bounded, and group history keeps more of the latest messages")
    }
}
