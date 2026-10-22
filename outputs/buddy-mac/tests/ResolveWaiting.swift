// run-tests: BuddyWorkerCore.swift BuddyOperationsDB.swift BuddyWorkerProcess.swift BuddyWorkerHost.swift BuddyCodexCoding.swift BuddyPlan.swift BuddySupervisor.swift BuddyMigrations.swift BuddyWorkerClient.swift BuddyAgentMemory.swift BuddyTeamMonitorStore.swift BuddyTeamMonitor.swift BuddyAISettings.swift ConversationService.swift BuddyInboxReview.swift BuddyMailVerification.swift BuddyComputer.swift BuddyTransport.swift BuddyToolInput.swift BuddyConnections.swift BuddyTeam.swift BuddyProjectFiles.swift BuddyDocuments.swift BuddyAgentProposals.swift BuddyCredentials.swift BuddyCommandReview.swift
import AppKit

/// "If things are solved it continues working if I already approved that task." The user uploaded the published PDF in Chief's chat and Chief
/// confirmed it was the right one, but S01 stayed PARTIAL until someone said “Resume S01”. Now the chat agent hands what the user supplied to
/// the task that waited for it (buddy_resolve_waiting), from its direct chat or from the group chat, and the work continues; a file step whose
/// file the user saved in Finder continues on the worker's next pass. End to end through the real worker, with Pause all on so nothing runs.
@main struct ResolveWaitingChecks {
    struct Failed: Error { let message: String }
    static func require(_ value: Bool, _ message: @autoclosure () -> String) throws { if !value { throw Failed(message: message()) } }

    @MainActor static func main() async {
        do { try await run() } catch let failed as Failed { fputs("FAILED: \(failed.message)\n", stderr); exit(1) } catch { fputs("FAILED: \(error.localizedDescription)\n", stderr); exit(1) }
    }

    @MainActor static func run() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("buddy-resolve-waiting-" + UUID().uuidString + ".noindex")
        let support = base.appendingPathComponent("Support", isDirectory: true), research = base.appendingPathComponent("Research", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: research.appendingPathComponent("stages/S01_protocol/source_retry"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let workspace = UUID().uuidString, chief = UUID().uuidString, forge = UUID().uuidString, vera = UUID().uuidString, omori = UUID().uuidString
        let tools: [String: Bool] = ["web": true, "desktop": true, "projectFiles": true]
        try JSONSerialization.data(withJSONObject: ["conversationWorkspace": workspace, "agents": [
            ["id": chief, "name": "Chief", "role": "Chief of staff", "description": "Supervises", "tools": tools],
            ["id": forge, "name": "Forge", "role": "Engineer", "description": "Codes", "tools": tools, "managedBy": chief],
            ["id": vera, "name": "Vera", "role": "Validator", "description": "Checks", "tools": tools]],
            "groups": [["id": omori, "name": "Omori", "objective": "Omori volatility research", "members": [chief, forge, vera], "managedBy": chief]]]).write(to: support.appendingPathComponent("workspace.json"))
        // No model runs in this test: both providers are off and the queue is paused.
        _ = try BuddyAISettings(support: support).update(workspace, enabled: ("chatgpt", false))
        _ = try BuddyAISettings(support: support).update(workspace, enabled: ("claude", false))
        let folder = try BuddyProjectFiles(support: support).addFolder(workspace, to: research)["folderId"] as? String ?? ""
        try Data("%PDF-1.7 published J. Stat. Mech. 023403".utf8).write(to: research.appendingPathComponent("paper_published.pdf"))

        // The plan as the worker left it: S01 (Chief) ended PARTIAL and was forwarded to the user for the published PDF; Forge asks the user for the
        // PDF; Vera's task waits for a file the user saves into the connected folder (a file step).
        let worker = support.appendingPathComponent("Worker", isDirectory: true)
        var s01 = "", s01Run = "", pdfRun = "", fileRun = "", planID = "", notice = ""
        do {
            let store = try BuddyWorkerStore(directory: worker), plans = try BuddyPlanStore(directory: worker)
            let stage: [String: Any] = ["title": "S01 Protocol and literature freeze", "goal": "Freeze the protocol", "acceptance": ["stages/S01_protocol/acceptance.md saved"]]
            let proposed = try plans.propose(workspace: workspace, groupId: omori, supervisorId: chief, objective: "Freeze the S01 protocol, then extend", stages: [stage, ["title": "Extend", "goal": "Extend it", "acceptance": ["robustness.csv"]]],
                                             tasks: [["stage": 1, "key": "s01", "title": "S01 caption verification", "assignee": chief, "kind": "coding", "brief": "Verify Figure 1 against the published PDF.", "deliverable": "acceptance.md"],
                                                     ["stage": 1, "key": "pdf", "title": "Fetch the published PDF", "assignee": forge, "kind": "research", "brief": "Get the published PDF.", "deliverable": "paper.pdf"],
                                                     ["stage": 1, "key": "appendix", "title": "Save the appendix", "assignee": vera, "kind": "research", "brief": "Get the appendix.", "deliverable": "appendix.pdf"]],
                                             members: [chief, forge, vera], by: chief)
            planID = proposed["id"] as? String ?? ""
            let keys = proposed["keys"] as? [String: String] ?? [:]
            s01 = keys["s01"] ?? ""
            _ = try plans.authorize(planId: planID, through: 1, quote: "Get stage 1 done", messageId: "m1", viaButton: false, now: Date())
            let started = try BuddyStageLoop.step(plans: plans, workspace: workspace, jobs: store.jobs, names: [chief: "Chief", forge: "Forge", vera: "Vera"]) { ref, brief, requestId in
                let job = try store.create(workspace: workspace, agent: ref.assignee, requestId: requestId, title: ref.title, goal: brief, kind: ref.kind, provider: "claude", budget: BuddyRunLimit.none)
                return try store.update(job["id"] as? String ?? "", ["planId": ref.planId, "planTaskId": ref.taskId, "stageId": ref.stageId, "reportsTo": chief, "supervisorId": chief])
            }
            try require(started.count == 3, "the three stage 1 tasks start: \(started)")
            func run(_ key: String) -> String { store.jobs.first { ($0["requestId"] as? String ?? "").hasPrefix("plan:\(keys[key] ?? "?"):") }?["id"] as? String ?? "" }
            s01Run = run("s01"); pdfRun = run("pdf"); fileRun = run("appendix")
            for id in [s01Run, pdfRun, fileRun] { try store.update(id, ["status": "running", "attempt": 1, "executionRunID": UUID().uuidString]) }
            try store.update(s01Run, ["status": "completed", "result": "S01 PARTIAL: the published PDF is behind the publisher's sign-in; Figure 1 is unverified.", "progress": "Done"])
            try store.update(pdfRun, ["status": "waiting_user", "stopCause": "checkpoint.user", "progress": "Waiting for you: upload the published PDF.",
                                      "checkpoint": ["id": UUID().uuidString, "category": "personal_fact", "question": "Upload the published PDF; it is behind the publisher's sign-in.", "routedTo": "user", "at": "2026-10-22T02:00:00Z"]])
            try store.update(fileRun, ["status": "waiting_user", "stopCause": "checkpoint.user", "progress": "Save the PDF from example.org into Research/stages",
                                       "checkpoint": ["id": UUID().uuidString, "need": "file", "url": "https://example.org/appendix.pdf", "folderId": folder, "path": "stages/appendix.pdf", "target": "Research/stages/appendix.pdf",
                                                      "question": "Save the PDF from example.org into Research/stages. Open the page, save it there, then press Done.", "routedTo": "user", "at": ISO8601DateFormatter().string(from: Date())]])
            _ = try plans.reconcile(jobs: store.jobs)
            let itemKey = "result:\(s01):1", decision = "escalation:run-1:\(itemKey)"
            try store.openDecision(workspace: workspace, id: decision, agent: chief, kind: "escalation", title: "Chief needs your decision", question: "Save the published PDF in Research/stages/S01_protocol/source_retry/. Then say “Resume S01.”", label: "Answer", payload: ["itemKey": itemKey], audience: "user")
            notice = try plans.addNotice(planId: planID, kind: "escalation", text: "Save the published PDF in Research/stages/S01_protocol/source_retry/. Then say “Resume S01.”", chat: true,
                                         refs: ["itemKey": itemKey, "itemKind": "result", "decisionId": decision, "taskId": s01, "workerTaskId": s01Run, "category": "credential", "question": "Save the published PDF."])
            try store.setPaused(true)
        }

        let host = BuddyWorkerHost(support: support, keyReader: { _ in nil })
        host.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer { host.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)) }
        func detail(_ id: String) async throws -> [String: Any] { (try await host.handle(["operation": "detail", "workspace": workspace, "taskId": id]))["task"] as? [String: Any] ?? [:] }

        // 1. The tool is offered in every chat, and says when to use it.
        let tool = BuddyWorkerClient.resolveWaitingTool, described = tool["description"] as? String ?? ""
        try require(BuddyWorkerClient.chatTools.contains { $0["name"] as? String == "buddy_resolve_waiting" } && !BuddyWorkerClient.tools.contains { $0["name"] as? String == "buddy_resolve_waiting" },
                    "chat turns, direct and group, are offered buddy_resolve_waiting; background tasks are not")
        try require(described.contains("never ask the user to say") && described.contains("right away"), "the tool says to hand it over right away and never to ask for “resume”: \(described)")

        // 2. In Chief's direct chat the user uploads the PDF Forge's task waits for; Chief hands it over and the task continues.
        let directContext: [String: Any] = ["agentId": chief, "key": workspace + ":" + chief, "authorizedUserText": "uploaded correct copy of the file, let me know if that is the right one", "runId": UUID().uuidString, "callId": "call-1"]
        let direct = BuddyWorkerClient.resolveWaitingRequest(arguments: ["taskId": pdfRun, "note": "The user uploaded the published PDF (J. Stat. Mech. 2022, 023403).", "files": ["Research/paper_published.pdf"]], context: directContext, workspace: workspace)
        try require(direct["operation"] as? String == "resolve_waiting" && direct["actorId"] as? String == chief && direct["authorizedText"] as? String == "uploaded correct copy of the file, let me know if that is the right one",
                    "the chat's call goes to the worker as the agent, with the user's own message: \(direct)")
        let handed = try await host.handle(direct)
        let pdf = try await detail(pdfRun)
        try require(handed["resumed"] as? Bool == true && pdf["status"] as? String == "queued" && (pdf["checkpoint"] == nil || pdf["checkpoint"] is NSNull), "Forge's waiting task continues: \(handed) \(pdf["status"] ?? "")")
        let pdfLine = (pdf["updates"] as? [String] ?? []).last ?? ""
        try require(pdfLine.hasPrefix("[From the user, passed on by Chief] The user uploaded the published PDF (J. Stat. Mech. 2022, 023403).") && pdfLine.contains("Research/paper_published.pdf"),
                    "with the user's input and the file they added: \(pdfLine)")

        // 3. In the Omori group the user says the published PDF is there; Chief, answering in the group, hands it to its own PARTIAL S01 result,
        // which starts again with it. The escalation that asked for “Resume S01” is answered.
        let groupContext: [String: Any] = ["agentId": chief, "key": workspace + ":group:" + omori + ":member-" + chief, "authorizedUserText": "Working? The published PDF is in the folder now.", "runId": UUID().uuidString, "callId": "call-2"]
        let group = BuddyWorkerClient.resolveWaitingRequest(arguments: ["itemId": "result:\(s01):1", "note": "The user put the published PDF in the folder.", "files": ["Research/paper_published.pdf"]], context: groupContext, workspace: workspace)
        let groupHanded = try await host.handle(group)
        try require(groupHanded["resumed"] as? Bool == true, "the group's call is applied: \(groupHanded)")
        let plans = try BuddyPlanStore(directory: worker)
        let s01Row = ((try plans.plan(id: planID))?["stages"] as? [[String: Any]] ?? []).flatMap { $0["tasks"] as? [[String: Any]] ?? [] }.first { $0["id"] as? String == s01 } ?? [:]
        try require(s01Row["status"] as? String == "pending", "the PARTIAL S01 task is sent back to work: \(s01Row["status"] ?? "")")
        let noticeNow = ((try plans.plan(id: planID))?["notices"] as? [[String: Any]] ?? []).first { $0["id"] as? String == notice } ?? [:]
        try require(noticeNow["status"] as? String == "answered", "the question that asked for “Resume S01” is answered: \(noticeNow["status"] ?? "")")
        let brief = try plans.composeBrief(taskId: s01, jobs: [], names: [chief: "Chief"])
        try require(brief.contains("The user put the published PDF in the folder.") && brief.contains("Research/paper_published.pdf"), "the restarted brief carries what the user supplied:\n\(brief)")
        let open = (try await host.handle(["operation": "status", "workspace": workspace]))["decisions"] as? [[String: Any]] ?? []
        try require(!open.contains { ["escalation:run-1:result:\(s01):1", "result:\(s01Run):1"].contains($0["id"] as? String ?? "") }, "nothing about it is left open: \(open.map { $0["id"] ?? "" })")

        // 4. What the tool refuses: a turn with no message from the user, an agent that neither owns the task nor supervises or manages its
        // owner, and a file that is not in a connected folder.
        for (label, request, wanted) in [
            ("no user message", BuddyWorkerClient.resolveWaitingRequest(arguments: ["taskId": fileRun, "note": "Here it is."], context: ["agentId": chief, "key": workspace + ":" + chief, "authorizedUserText": ""], workspace: workspace), "current message"),
            ("not Vera's to hand over", BuddyWorkerClient.resolveWaitingRequest(arguments: ["taskId": pdfRun, "note": "Here it is."], context: ["agentId": vera, "key": workspace + ":" + vera, "authorizedUserText": "here it is"], workspace: workspace), "another agent"),
            ("a missing file", BuddyWorkerClient.resolveWaitingRequest(arguments: ["taskId": pdfRun, "note": "Here it is.", "files": ["Research/nowhere.pdf"]], context: ["agentId": chief, "key": workspace + ":" + chief, "authorizedUserText": "here it is"], workspace: workspace), "nowhere.pdf"),
        ] as [(String, [String: Any], String)] {
            do { _ = try await host.handle(request); try require(false, "\(label) is refused") }
            catch let failed as Failed { throw failed }
            catch { try require(error.localizedDescription.contains(wanted), "\(label) is refused with the reason: \(error.localizedDescription)") }
        }
        try require(try await detail(fileRun)["status"] as? String == "waiting_user", "after the refusals the file step still waits")

        // 5. The user saves the appendix in Finder where Vera's file step asked for it: on its next pass the worker hands it over, nobody presses Done.
        try FileManager.default.createDirectory(at: research.appendingPathComponent("stages"), withIntermediateDirectories: true)
        try Data("%PDF-1.4 appendix".utf8).write(to: research.appendingPathComponent("stages/appendix.pdf"))
        var appendix: [String: Any] = [:]
        for _ in 0..<100 {
            appendix = try await detail(fileRun)
            if appendix["status"] as? String == "queued" { break }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        let appendixLine = (appendix["updates"] as? [String] ?? []).last ?? ""
        try require(appendix["status"] as? String == "queued" && appendixLine.contains("Research/stages/appendix.pdf") && appendixLine.contains("nobody pressed Done"),
                    "the file step continues once its file is there, with a note naming it: \(appendix["status"] ?? "") \(appendixLine)")
        print("PASS: buddy_resolve_waiting, from an agent's direct chat or from the group chat, hands the user's message and the file they added to the waiting task (a question, or a PARTIAL plan result, whose escalation is answered) and the work continues; it is refused without the user's message, for another agent's task or for a missing file; a file step continues on the worker's next pass once the user saved the file where it was asked for")
    }
}
