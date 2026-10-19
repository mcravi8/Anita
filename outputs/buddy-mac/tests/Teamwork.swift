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
        require((fake.calls[1].payload["text"] as? String)?.contains("Current writing instruction") == true, "workers receive current configuration and group history")
        require(fake.calls[1...2].allSatisfy { $0.options.fileScope == r.fileScope }, "workers use the same trusted shared folder")
        fake.receiver?(["type": "file", "runId": fake.calls[1].payload["runId"]!, "file": ["path": "actual.md", "folderId": r.workspace, "revision": "test-hash", "actorName": "Write Bot"], "internal": true])
        fake.complete(1, text: "ACTUAL_FIRST_WORK"); fake.complete(2, text: "ACTUAL_SECOND_WORK")
        await wait { fake.calls.count == 4 }
        let handoff = fake.calls[3].payload["text"] as? String ?? ""
        require(handoff.contains("ACTUAL_FIRST_WORK") && handoff.contains("ACTUAL_SECOND_WORK"), "reviewer receives actual completed dependency work")
        fake.complete(3, text: "ACTUAL_REVIEW")
        await wait { fake.calls.count == 5 }
        require(fake.calls[4].options.fileScope == nil && (fake.calls[4].payload["text"] as? String)?.contains("actual.md") == true, "synthesis receives actual save receipts without writing access")
        require(!fake.calls[4].options.toolsEnabled && (fake.calls[4].payload["text"] as? String)?.contains("ACTUAL_REVIEW") == true, "final lead synthesizes actual work without new service calls")
        fake.complete(4, text: "ONE_COMBINED_REPLY")
        await wait { team.snapshots()[0]["status"] as? String == "completed" }
        require(team.snapshots().count == 1 && team.snapshots()[0]["text"] as? String == "ONE_COMBINED_REPLY", "only one group reply is exposed")
        let recordedEntries=(team.snapshots()[0]["team"] as! [String:Any])["entries"] as! [[String:Any]]
        require(recordedEntries.allSatisfy { ($0["startedAt"] as? String).flatMap { ISO8601DateFormatter().date(from:$0) } != nil && ($0["finishedAt"] as? String).flatMap { ISO8601DateFormatter().date(from:$0) } != nil }, "group contributions retain actual start and finish timestamps for the chat timeline")
        print("PASS: independent parallel work, dependent handoffs, private internal turns, scoped permissions, and one combined reply")

        let (failureFake, failureTeam) = fixture(), failureRequest = request()
        _ = try failureTeam.send(failureRequest); await wait { failureFake.calls.count == 1 }
        let failedPlan = BuddyTeamPlan(leadId: "writer", tasks: [BuddyTeamTask(agentId: "researcher", task: "Read evidence", dependsOn: []), BuddyTeamTask(agentId: "reviewer", task: "Review evidence", dependsOn: ["researcher"])])
        failureFake.complete(0, text: String(data: try JSONEncoder().encode(failedPlan), encoding: .utf8)!)
        await wait { failureFake.calls.count == 2 }; failureFake.complete(1, text: "Connection unavailable", status: "failed")
        await wait { failureFake.calls.count == 3 }
        let failureText = failureFake.calls[2].payload["text"] as? String ?? ""
        require(failureText.contains("Connection unavailable") && failureText.contains("could not be completed"), "missing work is honestly passed to synthesis and review is blocked")
        failureFake.complete(2, text: "Missing evidence, explained")
        await wait { failureTeam.snapshots()[0]["status"] as? String == "completed" }
        require((failureTeam.snapshots()[0]["team"] as? [String: Any])?["partial"] as? Bool == true, "partial failure remains visible and retryable")
        print("PASS: worker failures block dependent work and remain visible in the combined reply")

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
