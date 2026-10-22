// run-tests: BuddyWorkerClient.swift BuddyAISettings.swift BuddyAIRouter.swift BuddyClaudeConversations.swift BuddyWorkerProcess.swift BuddyWorkerCore.swift BuddyOperationsDB.swift ConversationService.swift BuddyInboxReview.swift BuddyMailVerification.swift BuddyComputer.swift BuddyTransport.swift BuddyToolInput.swift BuddyConnections.swift BuddyTeam.swift BuddyProjectFiles.swift BuddyDocuments.swift BuddyAgentProposals.swift
import Foundation

/// What a chat agent is told about background work that is running right now. Asked "how much longer?", Forge answered from the plan
/// alone ("a few hours") because nothing in its chat showed the session that was actually running.
@main struct LiveWorkTests {
    @MainActor static func require(_ ok: Bool, _ label: String) { if !ok { fputs("FAILED: \(label)\n", stderr); exit(1) } }
    @MainActor static func main() throws {
        let pacific = TimeZone(identifier: "America/Los_Angeles")!, stamps = ISO8601DateFormatter()
        let now = stamps.date(from: "2026-10-20T03:54:00Z")!   // 8:54 PM in Los Angeles
        func at(_ s: String) -> String { "2026-10-20T" + s + "Z" }
        let fit = "export OMP_NUM_THREADS=1\ntimeout 290 python3 -I v3_analysis/fit_v3.py --ts omori_pipeline/data/vix_term_structure.csv --out v3_out_oos --jobs 10 > v3_oos.log 2>&1"
        let forgeRun: [String: Any] = ["id": "t-forge", "workspace": "w", "agentId": "forge", "kind": "coding", "title": "Run v3 fits and write SUMMARY_v3",
            "status": "running", "createdAt": at("02:06:21"), "updatedAt": at("03:49:56"), "progress": "Running project command",
            "commands": [["at": at("03:35:14"), "code": fit, "durationMs": 288205, "status": "completed"], ["at": at("03:40:07"), "code": fit, "durationMs": 290197, "status": "completed"],
                         ["at": at("03:45:02"), "code": fit, "durationMs": 290194, "status": "completed"], ["at": at("03:49:56"), "code": fit, "status": "running"]]]
        let vera: [String: Any] = ["id": "t-vera", "workspace": "w", "agentId": "vera", "title": "Sign off or object to v2 and v3 rules", "status": "queued", "createdAt": at("02:06:21"), "updatedAt": at("02:06:21"), "progress": "Queued"]
        let done: [String: Any] = ["id": "t-done", "workspace": "w", "agentId": "forge", "title": "Draft and freeze v3 filter rules", "status": "completed", "createdAt": at("02:00:00"), "updatedAt": at("02:05:32"), "result": "Rules frozen in verification/filter_rules_v3.md, hash 010df754.\nMore detail follows."]
        let old: [String: Any] = ["id": "t-old", "workspace": "w", "agentId": "forge", "title": "Last week's export", "status": "completed", "createdAt": "2026-10-19T10:00:00Z", "updatedAt": "2026-10-19T10:05:00Z", "result": "Old."]
        let elsewhere: [String: Any] = ["id": "t-else", "workspace": "other", "agentId": "forge", "title": "Another workspace", "status": "running", "createdAt": at("03:00:00"), "updatedAt": at("03:50:00")]
        let jobs = [forgeRun, vera, done, old, elsewhere], names = ["forge": "Forge", "vera": "Vera", "chief": "Chief"]

        // 1. The agent doing the work sees it live, in the person's time, with the pace of its commands.
        let forge = BuddyLiveWork.context(jobs: jobs, workspace: "w", agent: "forge", supervises: false, names: names, now: now, zone: pacific)
        require(forge.contains("Run v3 fits and write SUMMARY_v3") && forge.contains("running since 7:06 PM (1 h 48 min)"), "the running task, when it started and how long it has run: \(forge)")
        require(forge.contains("command running for 4 min") && forge.contains("timeout 290 python3 -I v3_analysis/fit_v3.py"), "the command running now and for how long: \(forge)")
        require(forge.contains("last 3 commands took 4 min 48 s, 4 min 50 s, 4 min 50 s"), "how long recent commands took, so time left can be estimated: \(forge)")
        require(forge.contains("Draft and freeze v3 filter rules") && forge.contains("finished 7:05 PM") && forge.contains("Rules frozen in verification/filter_rules_v3.md"), "a task finished in the last hours shows with its result: \(forge)")
        require(!forge.contains("Last week's export") && !forge.contains("Another workspace"), "old results and other workspaces stay out")
        require(!forge.contains("Sign off or object"), "another agent's work stays private to it")
        require(!forge.contains("03:") && !forge.contains("Z ") && !forge.contains("Z)"), "no UTC stamp reaches the agent: \(forge)")
        require(forge.contains("estimate"), "the agent is told to give an estimate from the pace, and to say it is one")

        // 2. The supervisor sees everyone's work; a teammate sees only its own; nothing live, nothing said.
        let chief = BuddyLiveWork.context(jobs: jobs, workspace: "w", agent: "chief", supervises: true, names: names, now: now, zone: pacific)
        require(chief.contains("Forge: “Run v3 fits and write SUMMARY_v3”") && chief.contains("Vera: “Sign off or object to v2 and v3 rules” — queued"), "the supervisor sees each teammate's work by name: \(chief)")
        require(BuddyLiveWork.context(jobs: jobs, workspace: "w", agent: "lyra", supervises: false, names: names, now: now, zone: pacific).isEmpty, "an agent with no work of its own gets no section")
        // Several tasks run at once, one per agent: a queued task waits for its own agent's running task, or else for a free slot.
        require(chief.contains("Vera: “Sign off or object to v2 and v3 rules” — queued since 7:06 PM, waiting for a free slot while other tasks run"), "Vera's task waits for a slot, not for Forge: \(chief)")
        var next = vera; next["id"] = "t-forge-next"; next["agentId"] = "forge"; next["title"] = "Write the appendix"
        let behind = BuddyLiveWork.context(jobs: jobs + [next], workspace: "w", agent: "forge", supervises: false, names: names, now: now, zone: pacific)
        require(behind.contains("“Write the appendix” — queued since 7:06 PM, waiting for Forge’s running task “Run v3 fits and write SUMMARY_v3” to finish (an agent works on one task at a time)"), "Forge's next task waits for Forge's own: \(behind)")

        // 3. It stays a short section even when a lot is going on.
        let many = (0..<40).map { n -> [String: Any] in var j = forgeRun; j["id"] = "t\(n)"; j["title"] = String(repeating: "Long title \(n) ", count: 20); return j }
        let crowded = BuddyLiveWork.context(jobs: many, workspace: "w", agent: "forge", supervises: false, names: names, now: now, zone: pacific)
        require(crowded.count <= 6000 && crowded.contains("more not shown"), "a crowded workspace is trimmed and says so: \(crowded.count)")
        print("PASS: a chat agent sees its running work live (start, the command running now, the pace of recent commands, recent results) in the person's time; the supervisor sees everyone's")
    }
}
