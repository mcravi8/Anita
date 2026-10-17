import Foundation
@main struct ActionTests {
    @MainActor static func require(_ value: Bool, _ message: String) { if !value { fputs("FAILED: \(message)\n", stderr); exit(1) } }
    @MainActor static func wait(_ predicate: () -> Bool) async {
        for _ in 0..<600 { if predicate() { return }; try? await Task.sleep(nanoseconds: 10_000_000) }
        require(false, "action protocol fixture timed out")
    }
    @MainActor static func main() async throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("buddy-actions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let workspace = UUID().uuidString, agent = UUID().uuidString, key = workspace + ":" + agent
        try JSONSerialization.data(withJSONObject: ["conversationWorkspace": workspace, "agents": [["id": agent, "name": "Test", "role": "Mail", "description": "Reply when asked", "avatarShape": "cube", "avatarColor": "gold"]], "groups": [], "proposals": []]).write(to: support.appendingPathComponent("workspace.json"))
        let service = ConversationService(support: support, executable: URL(fileURLWithPath: CommandLine.arguments[1]))
        var registered = true
        service.agentPermission = { w, keys in registered && w == workspace && keys == [key] }
        var events: [[String: Any]] = []
        service.onEvent = { events.append($0) }
        func send(_ text: String) throws -> String {
            let run = UUID().uuidString
            var options = BuddyTurnOptions(); options.actorId = agent
            options.proposalScope = BuddyProposalScope(workspace: workspace, chat: agent, actorId: agent, replyRunId: run)
            _ = try service.send(["runId": run, "key": key, "agent": ["name": "Test", "role": "Mail", "description": "Reply when asked"], "text": text], options: options)
            return run
        }
        func pending(_ run: String) -> [String: Any]? { service.pendingInputs(workspace: workspace).first { $0["runId"] as? String == run && $0["status"] as? String == "pending" } }
        func terminal(_ run: String) -> Bool { service.snapshots().contains { $0["runId"] as? String == run && ["completed", "failed", "stopped"].contains($0["status"] as? String ?? "") } }
        func effects() -> Int { ((try? String(contentsOf: support.appendingPathComponent("Conversations/fixture-effects.jsonl"), encoding: .utf8)) ?? "").split(separator: "\n").count }
        func answer(_ record: [String: Any], _ choice: String) throws -> [String: Any] { try service.answerInput(workspace: workspace, payload: ["id": record["id"]!, "answers": ["approve": [choice]]]) }
        let accepted = try send("accept")
        await wait { pending(accepted) != nil }
        let request = pending(accepted)!
        require(effects() == 0, "no effect before actual human choice")
        require((request["tool"] as? [String: Any])?["service"] as? String == "Gmail", "review preview comes from matching real tool item")
        var rejected = false
        do { _ = try service.answerInput(workspace: UUID().uuidString, payload: ["id": request["id"]!, "answers": ["approve": ["Accept"]]]) } catch { rejected = true }
        require(rejected && effects() == 0, "wrong workspace cannot approve")
        rejected = false; do { _ = try answer(request, "invented") } catch { rejected = true }
        require(rejected && pending(accepted) != nil, "invalid choices preserve pending review")
        _ = try answer(request, "Accept")
        rejected = false; do { _ = try answer(request, "Accept") } catch { rejected = true }
        require(rejected, "duplicate click cannot approve twice")
        await wait { terminal(accepted) }
        require(effects() == 1, "exactly one local fixture effect after acceptance")
        require(service.pendingInputs(workspace: workspace).contains { $0["id"] as? String == request["id"] as? String && $0["status"] as? String == "completed" }, "completion requires actual successful tool event")
        print("PASS: real RPC routing, early requests, scoped native review, preview, validation, single approval, and confirmed receipt")
        let declined = try send("decline"); await wait { pending(declined) != nil }; _ = try answer(pending(declined)!, "Decline"); await wait { terminal(declined) }
        require(effects() == 1, "decline causes no effect")
        require(service.pendingInputs(workspace: workspace).contains { $0["runId"] as? String == declined && $0["status"] as? String == "declined" }, "user decline remains distinct from a service failure")
        let stopped = try send("stop"); await wait { pending(stopped) != nil }; let stopRecord = pending(stopped)!; _ = try await service.stop(stopped); await wait { terminal(stopped) }
        require(effects() == 1 && pending(stopped) == nil, "Stop cancels waiting review")
        rejected = false; do { _ = try answer(stopRecord, "Accept") } catch { rejected = true }; require(rejected, "late click after Stop cannot approve")
        let removed = try send("remove"); await wait { pending(removed) != nil }; let removedRecord = pending(removed)!
        _ = try await service.setConnectionAccess(key: key, connection: "mail", allowed: false); await wait { terminal(removed) }
        rejected = false; do { _ = try answer(removedRecord, "Accept") } catch { rejected = true }; require(rejected && effects() == 1, "revocation cancels approval before next effect")
        let denied = try send("denied"); await wait { terminal(denied) }; require(pending(denied) == nil && effects() == 1, "new turn cannot use removed connection")
        _ = try await service.setConnectionAccess(key: key, connection: "mail", allowed: true)
        for mode in ["stale", "secret"] { let run = try send(mode); await wait { terminal(run) }; require(pending(run) == nil && effects() == 1, "stale or secret request never reaches approvable UI") }
        let disappeared = try send("removed-agent"); await wait { pending(disappeared) != nil }; let disappearRecord = pending(disappeared)!
        registered = false; rejected = false; do { _ = try answer(disappearRecord, "Accept") } catch { rejected = true }; require(rejected && effects() == 1, "removed agent cannot approve old request"); registered = true; _ = try await service.stop(disappeared)
        print("PASS: decline, Stop, durable access removal, stopped/retried turns, removed agents, stale requests, and secret rejection")
        func formAnswer(_ record: [String: Any], _ choice: String) throws {
            _ = try service.answerInput(workspace: workspace, payload: ["id": record["id"]!, "answers": ["operation": [choice]]])
        }
        let formAccepted = try send("form-accept")
        await wait { pending(formAccepted) != nil }
        let formRecord = pending(formAccepted)!, beforeForm = effects()
        require((formRecord["tool"] as? [String: Any])?["service"] as? String == "Gmail" && effects() == beforeForm, "actual provider format displays a review without performing the action")
        try formAnswer(formRecord, "Accept")
        await wait { terminal(formAccepted) }
        require(effects() == beforeForm + 1, "form acceptance produces exactly one local fixture effect")
        require(service.pendingInputs(workspace: workspace).contains { $0["id"] as? String == formRecord["id"] as? String && $0["status"] as? String == "completed" }, "flat connector metadata and normalized envelope fields match the actual receipt")
        rejected = false; do { try formAnswer(formRecord, "Accept") } catch { rejected = true }
        require(rejected && effects() == beforeForm + 1, "form review cannot be accepted twice")
        let formDeclined = try send("form-decline"); await wait { pending(formDeclined) != nil }
        try formAnswer(pending(formDeclined)!, "Decline"); await wait { terminal(formDeclined) }
        require(effects() == beforeForm + 1, "form decline performs no action")
        let formStopped = try send("form-stop"); await wait { pending(formStopped) != nil }
        let oldForm = pending(formStopped)!; _ = try await service.stop(formStopped); await wait { terminal(formStopped) }
        rejected = false; do { try formAnswer(oldForm, "Accept") } catch { rejected = true }
        require(rejected && effects() == beforeForm + 1, "Stop cancels the actual provider form")
        for mode in ["form-stale", "form-secret", "form-url", "form-wrong-connection", "form-disabled-tool", "form-duplicate", "form-expired"] {
            let run = try send(mode); await wait { terminal(run) }
            require(pending(run) == nil && effects() == beforeForm + 1, "unsupported or unscoped provider forms never become approvable")
        }
        let formRevoked = try send("form-revoke"); await wait { pending(formRevoked) != nil }
        let formRevokedRecord = pending(formRevoked)!; _ = try await service.setConnectionAccess(key: key, connection: "mail", allowed: false); await wait { terminal(formRevoked) }
        rejected = false; do { try formAnswer(formRevokedRecord, "Accept") } catch { rejected = true }
        require(rejected && effects() == beforeForm + 1, "removing connection access cancels the provider form")
        _ = try await service.setConnectionAccess(key: key, connection: "mail", allowed: true)
        let mismatch = try send("form-mismatch"); await wait { pending(mismatch) != nil }
        let mismatchRecord = pending(mismatch)!; try formAnswer(mismatchRecord, "Accept"); await wait { terminal(mismatch) }
        require(service.pendingInputs(workspace: workspace).contains { $0["id"] as? String == mismatchRecord["id"] as? String && $0["status"] as? String == "uncertain" }, "a different recipient cannot be treated as the reviewed action's receipt")
        print("PASS: observed connector elicitation format, exact response shape, scoped review, early delivery, completion identity, decline, Stop, revocation, unsupported prompts and mismatched receipts")
        let baselineEffects = effects()
        let uncertain = try send("uncertain"); await wait { pending(uncertain) != nil }; let uncertainRecord = pending(uncertain)!
        _ = try answer(uncertainRecord, "Accept"); await wait { effects() == baselineEffects + 1 }
        service.shutdown()
        let reopened = ConversationService(support: support, executable: URL(fileURLWithPath: CommandLine.arguments[1]))
        require(reopened.pendingInputs(workspace: workspace).contains { $0["id"] as? String == uncertainRecord["id"] as? String && $0["status"] as? String == "uncertain" }, "missing external receipt survives restart as uncertain")
        rejected = false; do { _ = try reopened.answerInput(workspace: workspace, payload: ["id": uncertainRecord["id"]!, "answers": ["approve": ["Accept"]]]) } catch { rejected = true }; require(rejected && effects() == baselineEffects + 1, "restart cannot replay a committed approval")
        reopened.shutdown()
        let preview = BuddyToolInput.preview(["tool": "test", "arguments": ["to": "a@example.invalid", "nested": ["api_key": "SECRET"]]])
        require(!String(data: try JSONSerialization.data(withJSONObject: preview), encoding: .utf8)!.contains("SECRET"), "secrets are redacted before preview or persistence")
        print("PASS: durable action journal, uncertainty after missing receipt, restart prevents reapproval, and secret redaction")
    }
}
