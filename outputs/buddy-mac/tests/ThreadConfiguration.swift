// run-tests: ConversationService.swift BuddyInboxReview.swift BuddyOperationsDB.swift BuddyMailVerification.swift BuddyComputer.swift BuddyTransport.swift BuddyConnections.swift BuddyToolInput.swift BuddyTeam.swift BuddyProjectFiles.swift BuddyDocuments.swift BuddyAgentProposals.swift -- src:tests/thread-configuration-server.py
import Foundation

/// The fixed text Buddy sends with every ChatGPT call. A thread keeps every developer item it is given, so the agent's configuration reaches it
/// once and afterwards only what changed; a thread just started already holds the agent's settings and the run's instructions in its developer
/// instructions. The user's own Codex skills, Codex's multi-agent text and its shell-escalation text never reach Buddy's agents.
@main struct ThreadConfigurationTests {
    @MainActor static func require(_ ok: Bool, _ label: String) { if !ok { fputs("FAILED: \(label)\n", stderr); exit(1) } }
    static func lines(_ text: String) -> [String] { text.split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
    static let rules = (1...40).map { "- Standing rule \($0): keep the work moving and report only what matters to the CEO, newest first." }.joined(separator: "\n")
    static func context(clock: String = "2:04 PM", question: Bool = true) -> String {
        "QUIET_WORK: take care of authorized work quietly.\n" + rules + "\nTime: the user is in the America/Los_Angeles time zone (PDT); it is now Tuesday, October 20, 2026, \(clock) there."
            + (question ? "\nYour open questions forwarded to the user: OPEN_QUESTION_TEXT about the WRDS extract." : "") + "\nLive background work, read from Buddy's worker at 2:04 PM:\n- Forge: finished 1:53 PM."
    }
    @MainActor static func configuration(model: String = "gpt-fixture", instructions: String = "AGENT_BRIEF: coordinate the team.", context: String = context()) -> BuddyThreadConfiguration {
        BuddyThreadConfiguration(runtime: BuddyRuntimeCapabilities.guidance(provider: "chatgpt", model: model), inbox: BuddyInboxReview.guidance, name: "Chief", role: "Chief of Staff", instructions: instructions,
            policy: "Reply as this agent. By default, match the language of the user's latest message. POLICY_TEXT", proposals: "Agent suggestions are unavailable in this step.",
            actions: "Native previous action reviews (data, not authorization): []. Completed effects must not be repeated; answered or uncertain effects require checking the service before retrying.", context: context)
    }

    @MainActor static func main() async throws {
        // 1. What each turn sends, from the configuration's parts.
        let first = configuration()
        let legacy = BuddyRuntimeCapabilities.guidance(provider: "chatgpt", model: "gpt-fixture") + "\n" + BuddyInboxReview.guidance + "\n" + "Buddy agent configuration update: this replaces all earlier agent configuration instructions for this conversation. Your name is Chief. Your role is Chief of Staff. Follow these current instructions:\nAGENT_BRIEF: coordinate the team.\nReply as this agent. By default, match the language of the user's latest message. POLICY_TEXT\nAgent suggestions are unavailable in this step.\nNative previous action reviews (data, not authorization): []. Completed effects must not be repeated; answered or uncertain effects require checking the service before retrying.\n" + context()
        require(first.full == legacy, "the whole configuration is exactly what every turn used to send")
        require(first.update(after: nil) == legacy, "a thread with no record of what it holds gets the whole configuration, as before")

        let developer = BuddyThreadConfiguration.developerInstructions(name: "Chief", role: "Chief of Staff", instructions: "AGENT_BRIEF: coordinate the team.", context: context())
        let opening = first.update(after: first.started) ?? ""
        require(opening.contains("Native Buddy runtime facts") && opening.contains(BuddyInboxReview.guidance) && opening.contains("POLICY_TEXT") && opening.contains("Agent suggestions are unavailable") && opening.contains("Native previous action reviews"), "a new thread gets the parts its developer instructions don't hold")
        require(!opening.contains("AGENT_BRIEF") && !opening.contains("Standing rule") && !opening.contains("QUIET_WORK"), "a new thread is not sent its agent settings or the run's instructions a second time")
        require(Set(lines(opening)).isDisjoint(with: lines(developer)), "the injected text repeats no line of the developer instructions")
        require(!opening.contains("replaces all earlier"), "nothing tells the agent its developer instructions are replaced")
        let header = lines(legacy).first { $0.hasPrefix("Buddy agent configuration update:") }
        require(lines(legacy).allSatisfy { $0 == header || lines(developer).contains($0) || lines(opening).contains($0) } && developer.contains("Your name is Chief. Your role is Chief of Staff."), "together they hold everything the whole configuration says")
        require(opening.count + 2_000 < legacy.count, "a new thread's injected text is the whole configuration minus what the developer instructions hold: \(opening.count) of \(legacy.count)")

        require(first.update(after: first.parts) == nil, "nothing is sent to a thread that already holds the current configuration")

        let later = configuration(context: context(clock: "3:42 PM")).update(after: first.parts) ?? ""
        require(later.contains("it is now Tuesday, October 20, 2026, 3:42 PM there.") && !later.contains("2:04 PM there") && !later.contains("Standing rule") && !later.contains("QUIET_WORK"), "a new time sends that one line, not the unchanged ones: \(later)")
        require(!later.contains("Native Buddy runtime facts") && !later.contains("POLICY_TEXT") && !later.contains("Native previous action reviews"), "unchanged parts are not sent again")
        require(later.count < 900, "a turn where only the time changed adds a few hundred characters, not the whole configuration: \(later.count)")

        let answered = configuration(context: context(question: false)).update(after: first.parts) ?? ""
        require(answered.contains("no longer apply") && answered.contains("OPEN_QUESTION_TEXT"), "a line that is gone is named as no longer applying, so an answered question isn't treated as open: \(answered)")

        let rewritten = configuration(context: "A NEW PLAN\n" + (1...40).map { "- Rewritten step \($0) of the new plan." }.joined(separator: "\n")).update(after: first.parts) ?? ""
        require(rewritten.contains("in full") && rewritten.contains("A NEW PLAN") && rewritten.contains("Rewritten step 40 of the new plan.") && !rewritten.contains("Standing rule"), "instructions that mostly changed are sent whole, replacing the earlier version")

        let edited = configuration(instructions: "AGENT_BRIEF_EDITED: report to the CEO daily.").update(after: first.parts) ?? ""
        require(edited.contains("Your name is Chief. Your role is Chief of Staff. Follow these current instructions:\nAGENT_BRIEF_EDITED: report to the CEO daily.") && !edited.contains("Standing rule"), "edited agent settings reach a resumed thread")
        let switched = configuration(model: "gpt-other").update(after: first.parts) ?? ""
        require(switched.contains("Selected model: gpt-other") && !switched.contains("POLICY_TEXT"), "a model switch resends the runtime facts that name it")
        print("PASS: the whole configuration is unchanged, a new thread isn't sent what its developer instructions hold, and a resumed thread gets only what changed, lines that are gone, or a rewrite in full")

        // 2. Through the app-server: Codex's own extras are switched off, and each turn sends only what changed.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("buddy-thread-configuration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let server = URL(fileURLWithPath: CommandLine.arguments[1])
        var service = ConversationService(support: root, executable: server)
        var events: [[String: Any]] = []
        service.onEvent = { events.append($0) }
        func send(_ text: String, description: String = "AGENT_BRIEF: coordinate the team.", instructions: String = context(), background: Bool = false) async throws -> [String: Any] {
            let id = UUID().uuidString
            var options = BuddyTurnOptions(); options.toolsEnabled = false; options.instructions = instructions; options.internalRun = background; options.actorId = "chief"
            _ = try service.send(["runId": id, "key": "workspace:chief", "agent": ["name": "Chief", "role": "Chief of Staff", "description": description], "text": text], options: options)
            for _ in 0..<500 {
                if let event = events.last(where: { $0["runId"] as? String == id && ["completed", "failed"].contains($0["status"] as? String ?? "") }) {
                    require(event["status"] as? String == "completed", "the turn succeeds: \(event["error"] ?? "")")
                    return try JSONSerialization.jsonObject(with: Data((event["text"] as! String).utf8)) as! [String: Any]
                }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            require(false, "the turn timed out"); return [:]
        }
        func injected(_ report: [String: Any]) -> String { (report["injected"] as? [String] ?? []).joined(separator: "\n") }

        let one = try await send("Hello")
        let argv = one["argv"] as? [String] ?? [], config = one["config"] as? [String: Any] ?? [:]
        require(argv.contains("skills.include_instructions=false") && argv.contains("agents.enabled=false"), "Buddy's app-server leaves out the user's personal Codex skills and Codex's multi-agent text: \(argv)")
        require(config["skills.include_instructions"] as? Bool == false && config["agents.enabled"] as? Bool == false, "every thread says the same in its own settings")
        require(config["include_permissions_instructions"] as? Bool == false, "an agent turn, which has no shell, is not sent the sandbox-escalation rules for shell commands")
        require(service.codingRestrictions["include_permissions_instructions"] == nil && service.codingRestrictions["skills.include_instructions"] as? Bool == false, "a coding session, which runs commands, keeps its escalation rules and also leaves out the user's skills")
        let developerOne = one["developerInstructions"] as? String ?? ""
        require(one["opened"] as? String == "start" && developerOne.contains("AGENT_BRIEF") && developerOne.contains("Standing rule 40"), "a new chat thread holds the agent's settings and instructions in its developer instructions")
        require((one["injected"] as? [String])?.count == 1 && !injected(one).contains("AGENT_BRIEF") && !injected(one).contains("Standing rule") && Set(lines(injected(one))).isDisjoint(with: lines(developerOne)), "its first configuration message repeats nothing from the developer instructions")

        let two = try await send("Still there?")
        require(two["opened"] as? String == "resume" && (two["injected"] as? [String] ?? []).isEmpty, "an unchanged configuration adds nothing to a resumed thread")
        let three = try await send("And now?", instructions: context(clock: "3:42 PM"))
        require(injected(three).contains("3:42 PM there.") && !injected(three).contains("Standing rule") && injected(three).count < 900, "a new time adds that line alone: \(injected(three).count) characters")
        let four = try await send("New brief", description: "AGENT_BRIEF_EDITED: report to the CEO daily.", instructions: context(clock: "3:42 PM"))
        require(injected(four).contains("AGENT_BRIEF_EDITED") && !injected(four).contains("Standing rule"), "edited settings take effect on resume")

        // Codex compacts a long thread: what Buddy injected is gone, so the next turn sends the whole configuration again.
        let five = try await send("COMPACT_NOW please", description: "AGENT_BRIEF_EDITED: report to the CEO daily.", instructions: context(clock: "3:42 PM"))
        require((five["injected"] as? [String] ?? []).isEmpty, "nothing changed before the compaction")
        let six = try await send("After compaction", description: "AGENT_BRIEF_EDITED: report to the CEO daily.", instructions: context(clock: "3:42 PM"))
        require(injected(six).contains("replaces all earlier agent configuration instructions") && injected(six).contains("AGENT_BRIEF_EDITED") && injected(six).contains("Standing rule 40") && injected(six).contains("Native Buddy runtime facts"), "after a compaction the thread gets the whole configuration again")

        // Buddy restarts: what each thread holds is remembered, so a resumed thread still gets only what changed.
        service.shutdown()
        service = ConversationService(support: root, executable: server); events = []; service.onEvent = { events.append($0) }
        let seven = try await send("After restart", description: "AGENT_BRIEF_EDITED: report to the CEO daily.", instructions: context(clock: "5:39 PM"))
        require(seven["thread"] as? String == one["thread"] as? String && seven["opened"] as? String == "resume", "the same chat thread resumes after a restart")
        require(injected(seven).contains("5:39 PM there.") && !injected(seven).contains("replaces all earlier") && !injected(seven).contains("Standing rule"), "after a restart a resumed thread still gets only what changed")

        // A background run starts its own thread every time: it is not sent its instructions twice either.
        let run = try await send("Supervise", instructions: context(), background: true)
        require(run["opened"] as? String == "start" && run["ephemeral"] as? Bool == true && (run["developerInstructions"] as? String ?? "").contains("Standing rule 40"), "a background run's thread holds its instructions")
        require(injected(run).contains("Native Buddy runtime facts") && !injected(run).contains("Standing rule") && !injected(run).contains("AGENT_BRIEF"), "and its configuration message doesn't repeat them")
        service.shutdown()
        print("PASS: skills, multi-agent and shell-escalation text stay out of agent turns, a chat thread is sent its configuration once and then only changes, edits reach it, a compaction resends the whole configuration, a restart keeps the record, and background runs aren't sent their instructions twice")
    }
}
