// run-tests: BuddyWorkerClient.swift BuddyAISettings.swift BuddyAIRouter.swift BuddyClaudeConversations.swift BuddyWorkerProcess.swift BuddyWorkerCore.swift BuddyOperationsDB.swift ConversationService.swift BuddyInboxReview.swift BuddyMailVerification.swift BuddyComputer.swift BuddyTransport.swift BuddyToolInput.swift BuddyConnections.swift BuddyTeam.swift BuddyProjectFiles.swift BuddyDocuments.swift BuddyAgentProposals.swift
import Foundation

/// The worker's launch settings. Buddy started its worker as a launchd "Background" job, and every program an agent runs inherits that: the
/// user's S02a computation (48 panels of about 3,000 model fits each) ran on the efficiency cores at background priority while a third of the
/// processor sat idle, and macOS offers no way to lift it from a program once it runs. Without a ProcessType the worker is a "Standard" job,
/// which on this Mac still runs it and its programs at utility priority (20); an "Interactive" job runs like an app, at normal priority (31).
@main struct WorkerPriorityTests {
    @MainActor static func require(_ ok: Bool, _ label: String) { if !ok { fputs("FAILED: \(label)\n", stderr); exit(1) } }
    @MainActor static func main() {
        let agent = BuddyWorkerClient.launchAgent(executable: URL(fileURLWithPath: "/Applications/Buddy.app/Contents/Helpers/Buddy Worker.app/Contents/MacOS/BuddyWorker"),
                                                  logs: URL(fileURLWithPath: "/fixture/Worker", isDirectory: true))
        require(agent["ProcessType"] as? String == "Interactive", "the worker runs like an app, so what agents run gets the whole Mac: \(agent["ProcessType"] ?? "none")")
        require(agent["Label"] as? String == "app.buddy.worker" && (agent["ProgramArguments"] as? [String]) == ["/Applications/Buddy.app/Contents/Helpers/Buddy Worker.app/Contents/MacOS/BuddyWorker", "--worker"]
                && agent["LimitLoadToSessionType"] as? String == "Aqua" && agent["StandardErrorPath"] as? String == "/fixture/Worker/service-error.log" && agent["Umask"] as? Int == 0o077,
                "the rest of the launch settings are as they were: \(agent)")
        print("PASS: Buddy's worker runs at normal priority, so the programs agents start (a long computation) use the whole Mac instead of its efficiency cores at background priority")
    }
}
