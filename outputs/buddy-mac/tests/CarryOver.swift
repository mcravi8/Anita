// run-tests: BuddyWorkerCore.swift BuddyOperationsDB.swift BuddyWorkerProcess.swift BuddyWorkerHost.swift BuddyCodexCoding.swift BuddyPlan.swift BuddySupervisor.swift BuddyMigrations.swift BuddyWorkerClient.swift BuddyAgentMemory.swift BuddyTeamMonitorStore.swift BuddyTeamMonitor.swift BuddyAISettings.swift ConversationService.swift BuddyInboxReview.swift BuddyMailVerification.swift BuddyComputer.swift BuddyTransport.swift BuddyToolInput.swift BuddyConnections.swift BuddyTeam.swift BuddyProjectFiles.swift BuddyDocuments.swift BuddyAgentProposals.swift BuddyCredentials.swift BuddyCommandReview.swift
import AppKit

/// A re-dispatch keeps the work (21 Oct, 20:21–20:30): Stage 2's plan task ran as Codex session A9D7C09E, which started
/// `python3 -u …/Tasks/A9D7C09E…/Files/stages/S02a_pooled/scripts/pipeline.py pilot OU`. Its rework started a new worker task, B4E3A695, with
/// a blank project: the 661 files of the first run and the pipeline still running in its folder were invisible to it, and it asked the user
/// whether "the original S02a task session can be restored". Now a re-dispatch of the same plan task works in the previous attempt's project;
/// at the worker's start a program still running from a coding session is reported to the task that continues it; and a worker that closes
/// while such a program runs records it on the task. End to end through the real worker; nothing runs a model (the queue is paused).
@main struct CarryOverChecks {
    struct Failed: Error { let message: String }
    static func require(_ value: Bool, _ message: @autoclosure () -> String) throws { if !value { throw Failed(message: message()) } }

    @MainActor static func main() async {
        var programs: [Process] = []
        defer { for p in programs where p.isRunning { p.terminate() } }
        do { try await run(&programs) } catch let failed as Failed { fputs("FAILED: \(failed.message)\n", stderr); exit(1) } catch { fputs("FAILED: \(error.localizedDescription)\n", stderr); exit(1) }
    }

    @MainActor static func sleeper(in folder: URL) throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep"); p.arguments = ["300"]; p.currentDirectoryURL = folder
        try p.run()
        return p
    }

    @MainActor static func run(_ programs: inout [Process]) async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("buddy-carry-over-" + UUID().uuidString + ".noindex")
        let support = base.appendingPathComponent("Support", isDirectory: true), worker = support.appendingPathComponent("Worker", isDirectory: true)
        try FileManager.default.createDirectory(at: worker, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let workspace = UUID().uuidString, chief = UUID().uuidString, forge = UUID().uuidString, omori = UUID().uuidString
        let tools: [String: Bool] = ["web": true, "desktop": true, "projectFiles": true]
        try JSONSerialization.data(withJSONObject: ["conversationWorkspace": workspace, "agents": [
            ["id": chief, "name": "Chief", "role": "Chief of staff", "description": "Supervises", "tools": tools],
            ["id": forge, "name": "Forge", "role": "Quant Engineer", "description": "Codes", "tools": tools, "managedBy": chief]],
            "groups": [["id": omori, "name": "Omori", "objective": "Omori", "members": [chief, forge], "managedBy": chief]]]).write(to: support.appendingPathComponent("workspace.json"))
        _ = try BuddyAISettings(support: support).update(workspace, enabled: ("chatgpt", false))
        _ = try BuddyAISettings(support: support).update(workspace, enabled: ("claude", false))

        // Stage 2's task ran once (A): its scripts and outputs are in its project, and its pipeline is still running there.
        var first = "", second = "", other = "", previousID = "", planTask = ""
        var fields: [String: Any] = [:], note = ""
        do {
            let store = try BuddyWorkerStore(directory: worker), plans = try BuddyPlanStore(directory: worker)
            let proposed = try plans.propose(workspace: workspace, groupId: omori, supervisorId: chief, objective: "Stage 2", stages: [["title": "S02a", "goal": "Pooled diagnostics", "acceptance": ["report.md"]], ["title": "S02b", "goal": "Next", "acceptance": ["next.md"]]],
                                             tasks: [["stage": 1, "key": "s02a", "title": "S02a pooled diagnostics and benchmark allocation", "assignee": forge, "kind": "coding", "brief": "Run the pooled pipeline.", "deliverable": "report.md"]], members: [chief, forge], by: chief)
            let planID = proposed["id"] as? String ?? ""
            planTask = (proposed["keys"] as? [String: String])?["s02a"] ?? ""
            _ = try plans.authorize(planId: planID, through: 1, quote: "get stage 2 done", messageId: "m1", viaButton: false, now: Date())
            func dispatch() throws -> String {
                try BuddyStageLoop.step(plans: plans, workspace: workspace, jobs: store.jobs, names: [chief: "Chief", forge: "Forge"]) { ref, brief, requestId in
                    // What the worker's stage loop does: the new task carries the previous attempt's project.
                    let job = try store.create(workspace: workspace, agent: ref.assignee, requestId: requestId, title: ref.title, goal: brief, kind: ref.kind, provider: "claude", budget: BuddyRunLimit.none)
                    let carried = BuddyWorkerHost.carryOver(previous: ref.previousWorkerTaskId, store: store, root: worker)
                    previousID = ref.previousWorkerTaskId; fields = carried?.fields ?? [:]; note = carried?.note ?? ""
                    var values: [String: Any] = ["planId": ref.planId, "planTaskId": ref.taskId, "stageId": ref.stageId, "supervisorId": chief]
                    values.merge(fields) { $1 }
                    if let carried { values["updates"] = [carried.note] }
                    return try store.update(job["id"] as? String ?? "", values)
                }.first ?? ""
            }
            first = try dispatch()
            try require(fields.isEmpty, "a first dispatch carries nothing over: \(fields)")
            let project = worker.appendingPathComponent("Tasks/\(first)/Files/stages/S02a_pooled", isDirectory: true)
            try FileManager.default.createDirectory(at: project.appendingPathComponent("scripts"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: project.appendingPathComponent("outputs"), withIntermediateDirectories: true)
            try Data("print('pilot')\n".utf8).write(to: project.appendingPathComponent("scripts/pipeline.py"))
            for n in 0..<5 { try Data("row \(n)\n".utf8).write(to: project.appendingPathComponent("outputs/pilot_OU_\(n).csv")) }
            try store.update(first, ["status": "running", "attempt": 1, "executionRunID": UUID().uuidString])
            try store.update(first, ["status": "completed", "result": "PARTIAL: the OU pilot is still running in the background.", "progress": "Done"])
            _ = try plans.reconcile(jobs: store.jobs)
            try plans.rework(taskId: planTask, instruction: "Finish S02a from the pilot's saved outputs.", by: chief)
            second = try dispatch()
            // Another task, still running when the worker closes, with a program of its own.
            other = try store.create(workspace: workspace, agent: forge, requestId: "other", title: "Fit the v3 model", goal: "Fit it.", kind: "coding", provider: "claude", budget: BuddyRunLimit.none)["id"] as? String ?? ""
            try store.update(other, ["status": "running", "attempt": 1, "executionRunID": UUID().uuidString])
            try store.update(second, ["status": "running", "attempt": 1, "executionRunID": UUID().uuidString])
            try store.update(second, ["status": "interrupted", "stopCause": "worker.restart", "progress": "Buddy restarted."])
            try store.setPaused(true)
        }

        // 1. The re-dispatch works in the first attempt's project: its scripts and outputs are there, and it is told so.
        try require(previousID == first && fields["projectOf"] as? String == first, "the re-dispatch names the first attempt and works in its project: \(previousID) \(fields)")
        let job2: [String: Any] = ["id": second, "projectOf": first]
        let folder2 = BuddyWorkerHost.projectFolder(job2, root: worker)
        try require(FileManager.default.fileExists(atPath: folder2.appendingPathComponent("stages/S02a_pooled/scripts/pipeline.py").path) && FileManager.default.fileExists(atPath: folder2.appendingPathComponent("stages/S02a_pooled/outputs/pilot_OU_4.csv").path),
                    "the recovered plan task sees the previous attempt's files: \(folder2.path)")
        try require(note.contains("[Buddy]") && note.contains("6 files") && note.contains("stages/S02a_pooled/scripts/pipeline.py") && note.contains("do not redo"), "and its brief says so: \(note)")
        let listed = try BuddyProjectFiles(support: support, privateRoot: folder2, privateFolderID: second).list(BuddyFileScope(workspace: workspace, folderId: second))
        try require((listed["files"] as? [[String: Any]] ?? []).contains { $0["path"] as? String == "stages/S02a_pooled/outputs/pilot_OU_0.csv" }, "its file tools list them: \(listed)")

        // 2. The first attempt's pipeline is still running in that project when the worker starts: the task that continues it is told.
        let pipeline = try sleeper(in: worker.appendingPathComponent("Tasks/\(first)/Files/stages/S02a_pooled", isDirectory: true)); programs.append(pipeline)
        let otherFolder = worker.appendingPathComponent("Tasks/\(other)/Files", isDirectory: true)
        try FileManager.default.createDirectory(at: otherFolder, withIntermediateDirectories: true)
        let host = BuddyWorkerHost(support: support, keyReader: { _ in nil })
        host.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        func detail(_ id: String) async throws -> [String: Any] { (try await host.handle(["operation": "detail", "workspace": workspace, "taskId": id]))["task"] as? [String: Any] ?? [:] }
        let resumed = try await detail(second)
        let told = (resumed["updates"] as? [String] ?? []).last ?? ""
        try require(told.contains("still running") && told.contains("pid \(pipeline.processIdentifier)") && told.contains("sleep 300"), "the leftover program is reported to the task that continues the work: \(told)")
        try require((resumed["leftovers"] as? [[String: Any]] ?? []).contains { $0["pid"] as? Int == Int(pipeline.processIdentifier) }, "and recorded on it: \(resumed["leftovers"] ?? "")")
        try require(((try await detail(first))["updates"] as? [String] ?? []).isEmpty, "not on the finished attempt whose folder it runs in")

        // 3. The worker closes while another task's program runs: that task records it, so its next attempt knows.
        let fit = try sleeper(in: otherFolder); programs.append(fit)
        host.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        let after = try BuddyWorkerStore(directory: worker).job(other)
        let recorded = (after["updates"] as? [String] ?? []).last ?? ""
        try require(recorded.contains("Buddy was closing") && recorded.contains("pid \(fit.processIdentifier)") && (after["leftovers"] as? [[String: Any]] ?? []).contains { $0["pid"] as? Int == Int(fit.processIdentifier) },
                    "a program still running when the worker closes is recorded on its task: \(recorded)")
        let againSecond = try BuddyWorkerStore(directory: worker).job(second)
        try require((againSecond["updates"] as? [String] ?? []).filter { $0.contains("pid \(pipeline.processIdentifier)") }.count == 1, "a program already reported is not reported twice")
        print("PASS: a re-dispatched plan task works in its previous attempt's project and is told what is there; a program still running from a coding session is reported to the task that continues the work when the worker starts, and recorded on its task when the worker closes, once")
    }
}
