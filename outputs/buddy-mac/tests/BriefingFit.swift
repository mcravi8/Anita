// run-tests: BuddyWorkerCore.swift BuddyOperationsDB.swift BuddyWorkerProcess.swift BuddyWorkerHost.swift BuddyPlan.swift BuddySupervisor.swift BuddyMigrations.swift BuddyWorkerClient.swift BuddyAgentMemory.swift BuddyTeamMonitorStore.swift BuddyTeamMonitor.swift BuddyAISettings.swift ConversationService.swift BuddyInboxReview.swift BuddyMailVerification.swift BuddyComputer.swift BuddyTransport.swift BuddyToolInput.swift BuddyConnections.swift BuddyTeam.swift BuddyProjectFiles.swift BuddyDocuments.swift BuddyAgentProposals.swift -- src:tests/supervisor-claude.py which:python3 src:tests/supervisor-gpt.py
import Foundation

// Chief's briefing always fits what a supervision run accepts (24 Oct: Stage 5's 45 tasks made it larger than a ChatGPT run takes, every
// supervision run failed before starting, and with supervision down every review went to the user).
@main struct BriefingFitTests {
    @MainActor static func require(_ value: Bool, _ message: String) { if !value { fputs("FAILED: \(message)\n", stderr); exit(1) } }
    static func size(_ value: [String: Any]) -> Int { (try? JSONSerialization.data(withJSONObject: value).count) ?? Int.max }
    @MainActor static func main() {
        let long = String(repeating: "Verified numerical provenance — paragraph 128/136/270 in /Users/x/Directed Research/stages/S04b. ", count: 60)
        func task(_ n: Int, _ status: String) -> [String: Any] { ["id": "t\(n)", "title": "Task \(n)", "assignee": "forge", "kind": "coding", "status": status, "brief": long, "resultSummary": long, "deliverable": "report.docx"] }
        let stages: [[String: Any]] = [["n": 5, "status": "working", "tasks": (1...40).map { task($0, "done") } + (41...45).map { task($0, "dispatched") }]]
        let briefing: [String: Any] = ["you": ["id": "chief", "name": "Chief"], "plan": ["id": "p", "stages": stages], "items": [["key": "stage:s:45", "kind": "stage_check", "result": String(repeating: long, count: 8)]]]
        require(size(briefing) > 300_000, "the test briefing is far over the limit: \(size(briefing))")
        let fitted = BuddySupervisorLane.fitted(briefing, limit: BuddySupervisorLane.chatgptBriefingLimit)
        require(size(fitted) <= BuddySupervisorLane.chatgptBriefingLimit, "it fits what a ChatGPT run accepts: \(size(fitted))")
        let tasks = ((fitted["plan"] as? [String: Any])?["stages"] as? [[String: Any]])?.first?["tasks"] as? [[String: Any]] ?? []
        require(tasks.count == 45 && tasks.prefix(40).allSatisfy { $0["brief"] == nil && $0["resultSummary"] == nil && $0["title"] != nil }, "finished tasks keep who did what, without their texts")
        require(tasks.suffix(5).allSatisfy { ($0["brief"] as? String ?? "").count > 300 }, "open tasks keep their briefs")
        require(((fitted["items"] as? [[String: Any]])?.first?["result"] as? String ?? "").contains("[shortened to fit the briefing]"), "the longest text is shortened, and says so")
        let small: [String: Any] = ["plan": ["stages": [["tasks": [task(1, "done")]]]]]
        require(NSDictionary(dictionary: BuddySupervisorLane.fitted(small, limit: BuddySupervisorLane.chatgptBriefingLimit)).isEqual(to: small), "a briefing that fits is left as it is")
        print("PASS: Chief's briefing always fits a supervision run: finished tasks keep only who did what, then the longest texts are halved with a note; one that fits is unchanged")
    }
}
