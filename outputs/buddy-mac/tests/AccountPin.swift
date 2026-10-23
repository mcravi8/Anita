// run-tests: BuddyWorkerCore.swift BuddyOperationsDB.swift BuddyWorkerProcess.swift BuddyWorkerHost.swift BuddyCodexCoding.swift BuddyPlan.swift BuddySupervisor.swift BuddyMigrations.swift BuddyWorkerClient.swift BuddyAgentMemory.swift BuddyTeamMonitorStore.swift BuddyTeamMonitor.swift BuddyAISettings.swift ConversationService.swift BuddyInboxReview.swift BuddyMailVerification.swift BuddyComputer.swift BuddyTransport.swift BuddyToolInput.swift BuddyConnections.swift BuddyTeam.swift BuddyProjectFiles.swift BuddyDocuments.swift BuddyAgentProposals.swift BuddyCredentials.swift BuddyCommandReview.swift -- src:tests/account-pin-server.py src:tests/account-pin-browser.py which:python3
import AppKit
import Darwin

/// "If I tell it in chat use this account for this task, it should not use another." A task carries the Google account the person named
/// (`account`), set by Buddy from the person's own words or checked against the accounts signed in to the shared Chrome, never changed by an
/// agent, kept across restarts, and sent with every page request so the browser holds the task to it. End to end through the real worker
/// with a stand-in ChatGPT (tests/account-pin-server.py) and a stand-in shared browser (tests/account-pin-browser.py) that logs the account
/// each page command names. The shared Chrome's account list is a fixture of Chrome's own settings files; no real profile or Keychain is read.
@main struct AccountPinChecks {
    struct Failed: Error { let message: String }
    static func require(_ value: Bool, _ message: @autoclosure () -> String) throws { if !value { throw Failed(message: message()) } }
    @MainActor static var failures: [String] = []
    @MainActor static func section(_ name: String, _ body: () async throws -> Void) async {
        do { try await body(); print("PASS: " + name) }
        catch let failed as Failed { failures.append(name); fputs("FAILED: \(name): \(failed.message)\n", stderr) }
        catch { failures.append(name); fputs("FAILED: \(name): \(error.localizedDescription)\n", stderr) }
    }
    static let personal = "me.personal@gmail.com", usc = "craviott@usc.edu"
    /// Chrome's own settings files, as Chrome writes them: the account Chrome itself is signed in to, and every Google account it knows.
    static func chrome(_ profile: URL, chrome: String?, accounts: [String]) throws {
        try FileManager.default.createDirectory(at: profile.appendingPathComponent("Default"), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["profile": ["info_cache": ["Default": ["user_name": chrome ?? "", "name": "Person 1"]]]]).write(to: profile.appendingPathComponent("Local State"))
        try JSONSerialization.data(withJSONObject: ["account_info": accounts.map { ["email": $0, "full_name": "Fixture", "gaia": UUID().uuidString] }, "profile": ["name": "Person 1"]]).write(to: profile.appendingPathComponent("Default/Preferences"))
    }

    @MainActor static func main() async throws {
        let arguments = CommandLine.arguments   // [1] the ChatGPT stand-in, [2] the shared browser stand-in, [3] python3
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("buddy-account-pin-" + UUID().uuidString + ".noindex")
        let support = base.appendingPathComponent("Support", isDirectory: true), logs = base.appendingPathComponent("Fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true); try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let serverLog = logs.appendingPathComponent("server.jsonl"), browserLog = logs.appendingPathComponent("browser.jsonl")
        setenv("BUDDY_PIN_SERVER_LOG", serverLog.path, 1); setenv("BUDDY_PIN_BROWSER_LOG", browserLog.path, 1)
        let workspace = UUID().uuidString, ada = UUID().uuidString, bo = UUID().uuidString
        try JSONSerialization.data(withJSONObject: ["conversationWorkspace": workspace, "agents": [
            ["id": ada, "name": "Ada", "role": "Assistant", "description": "Website tasks", "tools": ["web": true, "desktop": true]],
            ["id": bo, "name": "Bo", "role": "Chief", "description": "Supervises", "tools": ["web": true, "desktop": true]]]]).write(to: support.appendingPathComponent("workspace.json"))
        let profile = support.appendingPathComponent("Worker/Browsers/Shared", isDirectory: true)
        try chrome(profile, chrome: personal, accounts: [personal, usc])

        func launch() -> BuddyWorkerHost {
            let host = BuddyWorkerHost(support: support, executable: URL(fileURLWithPath: arguments[1]),
                                       makeBrowser: { BuddyWorkerProcess(resource: URL(fileURLWithPath: arguments[2]), runtime: URL(fileURLWithPath: arguments[3])) },
                                       keyReader: { _ in nil })
            host.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification)); return host
        }
        var host = launch()
        defer { host.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)) }

        func worker(_ payload: [String: Any]) async throws -> [String: Any] { try await BuddyWorkerClient.call(support: support, payload: payload.merging(["workspace": workspace]) { old, _ in old }) }
        /// What an agent's buddy_computer_task start sends: the app adds the person's current message (`authorizedText`); the model adds the rest.
        func start(_ said: String, goal: String = "Check my calendar for tomorrow.", account: String? = nil, as agent: String? = nil, request: String) async throws -> [String: Any] {
            var args: [String: Any] = ["action": "start", "title": "Check my calendar", "goal": goal]; if let account { args["account"] = account }
            let who = agent ?? ada
            return (try await worker(["operation": "computer", "agentId": who, "actorId": who, "requestId": request, "authorizedText": said, "arguments": args]))["task"] as? [String: Any] ?? [:]
        }
        func detail(_ id: String) async throws -> [String: Any] { (try await worker(["operation": "detail", "taskId": id]))["task"] as? [String: Any] ?? [:] }
        func poll(_ id: String, _ label: String, seconds: Double = 30, _ done: ([String: Any]) -> Bool) async throws -> [String: Any] {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline { let value = try await detail(id); if done(value) { return value }; try await Task.sleep(nanoseconds: 50_000_000) }
            let last = try await detail(id)
            throw Failed(message: "\(label) (last seen: \(last["status"] ?? "") / \(last["stopCause"] ?? "-") / \(last["progress"] ?? ""))")
        }
        func refusal(_ work: () async throws -> Any) async -> String { do { _ = try await work(); return "" } catch { return error.localizedDescription } }
        func lines(_ url: URL) -> [[String: Any]] { ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } }
        func pageCommands(_ session: String) -> [[String: Any]] { lines(browserLog).filter { $0["session"] as? String == session && !["closeSession", "manual", "manualGoogle"].contains($0["command"] as? String ?? "") } }

        // MARK: the person's words

        await section("the person's words pin the account: an exact address, “my USC account” by its domain, and nothing when they could mean two") {
            let both = [personal, usc]
            func pin(_ text: String, _ accounts: [String] = both) -> BuddyAccountPin.Named { BuddyAccountPin.named(in: text, accounts: accounts) }
            try require(pin("Use craviott@usc.edu for this").account == usc, "an exact address")
            try require(pin("please check my calendar with CRAVIOTT@usc.edu").account == usc, "an address in any case")
            try require(pin("i'm gonna add my usc gmail account, use it to check my calendar").account == usc, "“my usc gmail account” is the USC one, not Gmail")
            try require(pin("Use my USC account to reply to the advisor").account == usc, "by the word for its domain")
            try require(pin("do it from my usc email").account == usc, "“usc email”")
            try require(pin("use my personal account").account == personal && pin("check my gmail account").account == personal, "“personal” or “gmail account” is the one Gmail address")
            try require(pin("Find USC course listings for spring").account == nil && pin("Find USC course listings for spring").candidates.isEmpty, "a word that is not about an account names none")
            try require(pin("Send the summary to craviott@usc.edu").account == nil, "an address the message goes to is not the account to use")
            try require(pin("Email the report to me.personal@gmail.com from my USC account").account == usc, "the account to use, not the recipient")
            try require(pin("use the usc one", [usc, "other.person@usc.edu"]).account == nil && pin("use my usc account", [usc, "other.person@usc.edu"]).candidates == [usc, "other.person@usc.edu"].sorted(), "two USC accounts: ambiguous, so none")
            try require(pin("compare my usc account with my personal account").account == nil && pin("compare my usc account with my personal account").candidates.count == 2, "two accounts named: ambiguous, so none")
            try require(pin("Sign in as new.person@usc.edu and check the mail").account == "new.person@usc.edu", "an account the person names to use, even one not signed in yet")
            try require(pin("Check the calendar.").account == nil && pin("").candidates.isEmpty, "nothing named, nothing pinned")
        }
        await section("Buddy reads which Google accounts the shared Chrome is signed in to from Chrome's settings files, names only") {
            let accounts = BuddyAccountPin.signedIn(profile: profile)
            try require(accounts == [personal, usc], "Chrome's account first, then the others: \(accounts)")
            try require(BuddyAccountPin.signedIn(profile: base.appendingPathComponent("nowhere")).isEmpty, "no profile, no accounts")
        }
        await section("an agent's choice is checked: only a signed-in account, never one other than the person named, and only the person changes it") {
            let both = [personal, usc]
            func decide(_ current: String?, _ requested: String?, _ said: String, strict: Bool = true) -> (String?, String) {
                do { return (try BuddyAccountPin.decide(current: current, requested: requested, userText: said, accounts: both, strictAmbiguity: strict), "") } catch { return (nil, error.localizedDescription) }
            }
            try require(decide(nil, usc, "check my calendar").0 == usc, "a signed-in account the agent passes")
            let stranger = decide(nil, "stranger@example.com", "check my calendar")
            try require(stranger.0 == nil && stranger.1.contains("stranger@example.com") && stranger.1.contains(personal) && stranger.1.contains(usc), "an account that is not signed in is refused, naming those that are: \(stranger.1)")
            try require(!decide(nil, personal, "use my usc account").1.isEmpty, "not one other than the person named")
            try require(decide(nil, nil, "use my usc account").0 == usc && decide(nil, usc, "use my usc account").0 == usc, "the person's words, with or without the agent passing it")
            let unsure = decide(nil, nil, "compare my usc account with my personal account")
            try require(unsure.0 == nil && unsure.1.contains(usc) && unsure.1.contains(personal), "ambiguous words and no choice: the agent is told to ask which: \(unsure.1)")
            try require(decide(nil, usc, "compare my usc account with my personal account").0 == usc, "after asking, the agent passes the one the person chose")
            let changing = decide(usc, personal, "keep going")
            try require(changing.0 == nil && changing.1.contains("only the user"), "an agent cannot change it: \(changing.1)")
            try require(decide(usc, nil, "keep going").0 == usc && decide(usc, usc, "keep going").0 == usc, "it stays as it was")
            try require(decide(usc, nil, "actually use my personal account for this").0 == personal, "the person's later message changes it")
            try require(decide(usc, nil, "compare my usc account with my personal account", strict: false).0 == usc, "a later message that could mean either leaves it as it was")
        }

        // MARK: through the worker

        _ = try await worker(["operation": "pauseAll", "paused": true])
        var pinned = ""
        await section("a task started from the person's message carries the account they named, whoever wrote the brief") {
            let task = try await start("Use my USC account to check my calendar for tomorrow", request: "run-1:computer")
            pinned = task["id"] as? String ?? ""
            try require(task["account"] as? String == usc, "the task carries the account: \(task)")
            let exact = try await worker(["operation": "create", "agentId": ada, "actorId": ada, "requestId": "run-2:call", "authorizedText": "please do this with craviott@usc.edu", "title": "Draft a note", "goal": "Draft a note.", "kind": "general"])
            try require((exact["task"] as? [String: Any])?["account"] as? String == usc, "a background task too: \(exact)")
            let page = try await worker(["operation": "create", "agentId": ada, "requestId": "page-1", "title": "Mail", "goal": "Check my personal gmail for the receipt.", "kind": "general", "provider": "chatgpt"])
            try require((page["task"] as? [String: Any])?["account"] as? String == personal, "a task the person writes in Background work: \(page)")
            let none = try await start("Check my calendar for tomorrow", request: "run-3:computer")
            try require(none["account"] == nil, "no account named, none pinned: \(none)")
            try require((try await detail(pinned))["account"] as? String == usc, "the task's details show it")
        }
        await section("an agent's account must be signed in to Buddy's Chrome and cannot differ from the person's; ambiguous words make it ask") {
            func count() async throws -> Int { ((try await worker(["operation": "computer", "agentId": ada, "actorId": ada, "arguments": ["action": "status"]]))["tasks"] as? [Any] ?? []).count }
            let before = try await count()
            let stranger = await refusal { try await start("Check my calendar for tomorrow", account: "stranger@example.com", request: "run-4:computer") }
            try require(stranger.contains("stranger@example.com") && stranger.contains(usc) && stranger.contains(personal), "refused, naming the signed-in accounts: \(stranger)")
            let other = await refusal { try await start("Use my USC account to check my calendar", account: personal, request: "run-5:computer") }
            try require(other.contains(usc), "not another account than the person named: \(other)")
            let chosen = try await start("Check my calendar for tomorrow", account: usc, request: "run-6:computer")
            try require(chosen["account"] as? String == usc, "a signed-in account the agent passes is pinned: \(chosen)")
            let unsure = await refusal { try await start("Compare my usc account with my personal account", request: "run-7:computer") }
            try require(unsure.contains("could mean") && unsure.contains(usc) && unsure.contains(personal), "ambiguous: the agent must ask which: \(unsure)")
            try require(try await count() == before + 1, "a refused start makes no task; only the accepted one was added")
        }
        await section("only the person changes a task's account: an agent cannot, the person's later words can") {
            _ = try await worker(["operation": "pause", "taskId": pinned])
            let changed = await refusal { try await worker(["operation": "computer", "agentId": ada, "actorId": ada, "authorizedText": "keep going", "arguments": ["action": "continue", "taskId": pinned, "goal": "Use the other account.", "account": personal]]) }
            try require(changed.contains("only the user"), "the agent cannot change it: \(changed)")
            try require((try await detail(pinned))["account"] as? String == usc, "it still uses the account the person named")
            _ = try await worker(["operation": "computer", "agentId": ada, "actorId": ada, "authorizedText": "Actually use my personal account for that one", "arguments": ["action": "continue", "taskId": pinned, "goal": "The user switched to their personal account."]])
            try require((try await detail(pinned))["account"] as? String == personal, "the person's own later message changes it")
            _ = try await worker(["operation": "pause", "taskId": pinned])
        }
        await section("the account survives a restart and a resume, and every page request of the task names it") {
            host.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
            host = launch()
            try require((try await detail(pinned))["account"] as? String == personal, "saved with the task")
            // The person resumes it from Background work with their own words: their words set the account, and the task runs on it.
            let browse = try await worker(["operation": "create", "agentId": ada, "actorId": ada, "requestId": "run-8:call", "authorizedText": "Use my usc account", "title": "Open mail", "goal": "BROWSE:https://mail.google.com/mail/", "kind": "general"])
            let browsing = (browse["task"] as? [String: Any])?["id"] as? String ?? ""
            _ = try await worker(["operation": "resume", "taskId": pinned, "message": "Use craviott@usc.edu after all."])
            try require((try await detail(pinned))["account"] as? String == usc, "the person's resume message set it back")
            _ = try await poll(browsing, "the browsing task finishes") { $0["status"] as? String == "completed" }
            let used = pageCommands(browsing)
            try require(!used.isEmpty && used.allSatisfy { $0["account"] as? String == usc }, "every page command named the task's account: \(used)")
            let told = lines(serverLog).filter { $0["kind"] as? String == "turn" }.compactMap { ($0["value"] as? [String: Any])?["text"] as? String }.first { $0.contains("BROWSE:") } ?? ""
            try require(told.contains("must use the Google account craviott@usc.edu"), "the agent is told which account its task uses: \(told.suffix(600))")
        }
        await section("a pinned account that is not signed in to Buddy's Chrome asks the person to sign in to it, with Done, before anything runs") {
            let task = try await start("Sign in as new.person@usc.edu and check the mail", goal: "BROWSE:https://mail.google.com/mail/", request: "run-9:computer")
            let id = task["id"] as? String ?? ""
            try require(task["account"] as? String == "new.person@usc.edu", "pinned from the person's words: \(task)")
            let waiting = try await poll(id, "the task waits for the person") { $0["status"] as? String == "waiting_user" }
            let point = waiting["checkpoint"] as? [String: Any] ?? [:]
            try require(point["need"] as? String == "signin" && point["question"] as? String == "Sign in to new.person@usc.edu in Buddy’s Chrome, then press Done." && point["account"] as? String == "new.person@usc.edu",
                        "the step says which account to sign in to: \(point)")
            try require(pageCommands(id).isEmpty, "no page was opened as another account meanwhile: \(pageCommands(id))")
            try chrome(profile, chrome: personal, accounts: [personal, usc, "new.person@usc.edu"])
            let done = try await worker(["operation": "signin", "arguments": ["action": "done", "taskId": id]])
            try require(done["done"] as? Bool == true, "Done: \(done)")
            _ = try await poll(id, "the task continues once the person has signed in") { $0["status"] as? String == "completed" }
            let used = pageCommands(id)
            try require(!used.isEmpty && used.allSatisfy { $0["account"] as? String == "new.person@usc.edu" }, "it then used that account: \(used)")
        }
        await section("a page that finds the account isn't signed in turns into the same Done step") {
            // (Two USC accounts are signed in by now, so the person names the address.)
            let task = try await start("Use craviott@usc.edu", goal: "BROWSE:https://mail.google.com/NOT_SIGNED_IN", request: "run-10:computer")
            let id = task["id"] as? String ?? ""
            let waiting = try await poll(id, "the task waits for the person") { $0["status"] as? String == "waiting_user" }
            let point = waiting["checkpoint"] as? [String: Any] ?? [:]
            try require(point["need"] as? String == "signin" && point["question"] as? String == "Sign in to craviott@usc.edu in Buddy’s Chrome, then press Done.", "the step: \(point)")
            _ = try await worker(["operation": "cancel", "taskId": id])
        }

        await section("the account the person named for a task, signed in to Buddy's Chrome, signs in with Google by itself where the site offers Google") {
            // RunPod, 23 Oct: the user named matteo.craviotto@gmail.com, which was signed in to Buddy's Chrome, and still had to sign in by hand.
            let plan: [String: Any] = ["mode": "signin", "googleAvailable": true, "origin": "https://console.runpod.io"]
            let pinned: [String: Any] = ["id": "t", "workspace": "w", "agentId": "chief", "account": personal]
            try require(BuddyWorkerSignInPolicy.pinnedGoogle(job: pinned, plan: plan, signedIn: [usc, personal]), "the named account is signed in: Buddy uses Google itself")
            try require(!BuddyWorkerSignInPolicy.pinnedGoogle(job: pinned, plan: plan, signedIn: [usc]), "not when the named account is not signed in to Buddy's Chrome")
            try require(!BuddyWorkerSignInPolicy.pinnedGoogle(job: ["id": "t", "workspace": "w", "agentId": "chief"], plan: plan, signedIn: [usc, personal]), "not without an account the person named")
            var noGoogle = plan; noGoogle["googleAvailable"] = false
            try require(!BuddyWorkerSignInPolicy.pinnedGoogle(job: pinned, plan: noGoogle, signedIn: [personal]), "not where the site offers no Google")
            var signup = plan; signup["mode"] = "signup"
            try require(!BuddyWorkerSignInPolicy.pinnedGoogle(job: pinned, plan: signup, signedIn: [personal]), "never to create an account")
            var plain = plan; plain["origin"] = "http://console.runpod.io"
            try require(!BuddyWorkerSignInPolicy.pinnedGoogle(job: pinned, plan: plain, signedIn: [personal]), "only over HTTPS")
        }

        if !failures.isEmpty { fputs("FAILED: \(failures.count) account pin check(s) failed\n", stderr); exit(1) }
    }
}
