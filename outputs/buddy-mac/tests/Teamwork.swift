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
    static func request(members: [BuddyTeamAgent] = members, group: String = "group") -> BuddyTeamRequest {
        let workspace = UUID().uuidString
        return BuddyTeamRequest(runId: UUID().uuidString, key: workspace + ":" + group, workspace: workspace, groupId: group, name: "Launch", objective: "Clear and accurate", text: "@Review Bot work together on an announcement", members: members, history: "You: Our event is Sunday.")
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
        var r = request(); r.fileScope = BuddyFileScope(workspace: r.workspace, folderId: r.workspace)
        require(r.mentionedIds == ["reviewer"], "actual mentions resolve by full agent name")
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
    }
}
