// run-tests: BuddyWorkerCore.swift BuddyOperationsDB.swift BuddyWorkerProcess.swift BuddyWorkerHost.swift BuddyCodexCoding.swift BuddyPlan.swift BuddySupervisor.swift BuddyMigrations.swift BuddyWorkerClient.swift BuddyAgentMemory.swift BuddyTeamMonitorStore.swift BuddyTeamMonitor.swift BuddyAISettings.swift ConversationService.swift BuddyInboxReview.swift BuddyMailVerification.swift BuddyComputer.swift BuddyTransport.swift BuddyToolInput.swift BuddyConnections.swift BuddyTeam.swift BuddyProjectFiles.swift BuddyDocuments.swift BuddyAgentProposals.swift BuddyCredentials.swift BuddyCommandReview.swift -- src:tests/web-step-server.py src:tests/web-step-coding.py src:tests/web-step-browser.py which:python3
import AppKit
import Darwin

/// "Open Chrome opened both accounts and irrelevant tabs. It should have opened the website it needs me on, in the right account." A step
/// an agent asks the person to do on a web page always names that exact page (and the account, if any); Open the page opens exactly that
/// page for the task; a coding session, whose commands can never use Chrome's sign-ins, asks the person to save the file into a connected
/// folder instead of signing in; and a step saved before pages were named still says something useful. End to end through the real worker
/// with a stand-in ChatGPT (tests/web-step-server.py), a stand-in Claude coding bridge (tests/web-step-coding.py) and a stand-in shared
/// browser (tests/web-step-browser.py) that logs every command. The shared Chrome's account list is a fixture of Chrome's own settings files.
@main struct WebStepChecks {
    struct Failed: Error { let message: String }
    static func require(_ value: Bool, _ message: @autoclosure () -> String) throws { if !value { throw Failed(message: message()) } }
    @MainActor static var failures: [String] = []
    @MainActor static func section(_ name: String, _ body: () async throws -> Void) async {
        do { try await body(); print("PASS: " + name) }
        catch let failed as Failed { failures.append(name); fputs("FAILED: \(name): \(failed.message)\n", stderr) }
        catch { failures.append(name); fputs("FAILED: \(name): \(error.localizedDescription)\n", stderr) }
    }
    static let personal = "me.personal@gmail.com", usc = "craviott@usc.edu"
    static let article = "https://iopscience.iop.org/article/10.1088/1742-5468/ac498c"
    static func chrome(_ profile: URL, chrome: String?, accounts: [String]) throws {
        try FileManager.default.createDirectory(at: profile.appendingPathComponent("Default"), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["profile": ["info_cache": ["Default": ["user_name": chrome ?? "", "name": "Person 1"]]]]).write(to: profile.appendingPathComponent("Local State"))
        try JSONSerialization.data(withJSONObject: ["account_info": accounts.map { ["email": $0, "full_name": "Fixture", "gaia": UUID().uuidString] }, "profile": ["name": "Person 1"]]).write(to: profile.appendingPathComponent("Default/Preferences"))
    }
    static func json(_ value: Any) -> String { (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "" }

    @MainActor static func main() async throws {
        let arguments = CommandLine.arguments   // [1] the ChatGPT stand-in, [2] the Claude coding stand-in, [3] the shared browser stand-in, [4] python3
        // A stand-in that can't be run is passed over for the Codex installed on this Mac, signed in to the person's ChatGPT: never that.
        guard FileManager.default.isExecutableFile(atPath: arguments[1]) else { fputs("FAILED: the ChatGPT stand-in \(arguments[1]) is not executable\n", stderr); exit(1) }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("buddy-web-step-" + UUID().uuidString + ".noindex")
        let support = base.appendingPathComponent("Support", isDirectory: true), logs = base.appendingPathComponent("Fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true); try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let serverLog = logs.appendingPathComponent("server.jsonl"), codingLog = logs.appendingPathComponent("coding.jsonl"), browserLog = logs.appendingPathComponent("browser.jsonl")
        setenv("BUDDY_STEP_SERVER_LOG", serverLog.path, 1); setenv("BUDDY_STEP_CODING_LOG", codingLog.path, 1); setenv("BUDDY_STEP_BROWSER_LOG", browserLog.path, 1)
        let workspace = UUID().uuidString, chief = UUID().uuidString, ada = UUID().uuidString, bea = UUID().uuidString
        try JSONSerialization.data(withJSONObject: ["conversationWorkspace": workspace, "agents": [
            ["id": chief, "name": "Chief", "role": "Chief of staff", "description": "Codes and supervises", "tools": ["web": true, "desktop": true, "projectFiles": true]],
            ["id": ada, "name": "Ada", "role": "Assistant", "description": "Website tasks", "tools": ["web": true, "desktop": true, "projectFiles": true]],
            ["id": bea, "name": "Bea", "role": "Analyst", "description": "Codes offline", "tools": ["web": false, "desktop": true, "projectFiles": true]]]]).write(to: support.appendingPathComponent("workspace.json"))
        try BuddyAgentModels(support: support).set(workspace: workspace, agent: chief, selection: .init(provider: "claude", model: "claude-fixture"))
        try BuddyAgentModels(support: support).set(workspace: workspace, agent: bea, selection: .init(provider: "claude", model: "claude-fixture"))
        try chrome(support.appendingPathComponent("Worker/Browsers/Shared", isDirectory: true), chrome: personal, accounts: [personal, usc])
        // The person's connected folder, where a coding task's blocked download is saved.
        let research = base.appendingPathComponent("Directed Research", isDirectory: true)
        try FileManager.default.createDirectory(at: research.appendingPathComponent("stages/S01_protocol/sources"), withIntermediateDirectories: true)
        let folder = try BuddyProjectFiles(support: support).addFolder(workspace, to: research)["folderId"] as? String ?? ""

        // Two steps saved before steps named their page, as the live one was: a coding task's sign-in "in the Chrome window Buddy opened",
        // one whose result names the page and one that names none.
        let legacyQuestion = "Sign in to the website in the Chrome window Buddy opened. When you’re finished, press Done."
        var legacyNamed = "", legacyBlank = ""
        do {
            let worker = support.appendingPathComponent("Worker", isDirectory: true)
            try FileManager.default.createDirectory(at: worker, withIntermediateDirectories: true)
            let store = try BuddyWorkerStore(directory: worker)
            func legacy(_ request: String, result: String) throws -> String {
                let made = try store.create(workspace: workspace, agent: chief, requestId: request, title: "Get the Sethna article", goal: "Download the article PDF into the project.", kind: "coding", provider: "claude", budget: 1, model: "claude-fixture")
                let id = made["id"] as? String ?? ""
                try store.update(id, ["status": "waiting_user", "stopCause": "checkpoint.user", "progress": legacyQuestion, "result": result, "remainingBudgetUSD": 1.0,
                                      "checkpoint": ["id": UUID().uuidString, "need": "signin", "where": "chrome", "question": legacyQuestion, "options": [String](), "recommendation": "", "context": "", "routedTo": "user", "at": "2026-10-21T00:04:00Z"]], cause: "checkpoint.user")
                return id
            }
            legacyNamed = try legacy("legacy-named", result: "curl could not fetch \(article) — the publisher served a CAPTCHA. Receipts: 2 finished, 0 exited successfully.")
            legacyBlank = try legacy("legacy-blank", result: "The publisher served a CAPTCHA, so the download failed.")
        }

        let host = BuddyWorkerHost(support: support, executable: URL(fileURLWithPath: arguments[1]),
                                   makeBrowser: { BuddyWorkerProcess(resource: URL(fileURLWithPath: arguments[3]), runtime: URL(fileURLWithPath: arguments[4])) },
                                   makeCoding: { BuddyWorkerProcess(resource: URL(fileURLWithPath: arguments[2]), runtime: URL(fileURLWithPath: arguments[4])) },
                                   makeClaude: { BuddyWorkerProcess(resource: URL(fileURLWithPath: arguments[2]), runtime: URL(fileURLWithPath: arguments[4])) },
                                   keyReader: { _ in "inert-fixture-key" })
        host.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer { host.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)) }

        func worker(_ payload: [String: Any]) async throws -> [String: Any] { try await BuddyWorkerClient.call(support: support, payload: payload.merging(["workspace": workspace]) { old, _ in old }) }
        func page(_ payload: [String: Any]) async throws -> [String: Any] { try await BuddySignInBox.handle(payload, workspace: workspace, support: support) }
        /// A website task Ada starts from the person's message (`said`), its brief asking the stand-in to call buddy_checkpoint with `step`.
        func website(_ step: [String: Any], said: String = "Get me the Sethna article", request: String) async throws -> [String: Any] {
            let goal = "Get the article. CHECKPOINT:" + json(step)
            return (try await worker(["operation": "computer", "agentId": ada, "actorId": ada, "requestId": request, "authorizedText": said, "arguments": ["action": "start", "title": "Get the article", "goal": goal]]))["task"] as? [String: Any] ?? [:]
        }
        /// A coding task Chief starts, its brief asking the stand-in to make `calls` until one is not refused.
        func coding(_ calls: [[Any]], as agent: String? = nil, request: String) async throws -> String {
            let reply = try await worker(["operation": "coding", "agentId": agent ?? chief, "requestId": request, "arguments": ["action": "start", "title": "Get the Sethna article", "goal": "Download the article PDF into the project. CALLS:" + json(calls)]])
            return (reply["task"] as? [String: Any])?["id"] as? String ?? ""
        }
        func detail(_ id: String) async throws -> [String: Any] { (try await worker(["operation": "detail", "taskId": id]))["task"] as? [String: Any] ?? [:] }
        func poll(_ id: String, _ label: String, seconds: Double = 30, _ done: ([String: Any]) -> Bool) async throws -> [String: Any] {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline { let value = try await detail(id); if done(value) { return value }; try await Task.sleep(nanoseconds: 50_000_000) }
            let last = try await detail(id)
            throw Failed(message: "\(label) (last seen: \(last["status"] ?? "") / \(last["stopCause"] ?? "-") / \(last["progress"] ?? ""))")
        }
        func status() async throws -> [String: Any] { try await worker(["operation": "status"]) }
        func requests(_ id: String) async throws -> [[String: Any]] { ((try await status())["signinRequests"] as? [[String: Any]] ?? []).filter { $0["taskId"] as? String == id } }
        func decisions(_ id: String) async throws -> [[String: Any]] { ((try await status())["decisions"] as? [[String: Any]] ?? []).filter { $0["taskId"] as? String == id } }
        func lines(_ url: URL) -> [[String: Any]] { ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } }
        func browser(_ session: String) -> [[String: Any]] { lines(browserLog).filter { $0["session"] as? String == session } }
        func told() -> [String: Any] { lines(serverLog).filter { $0["kind"] as? String == "result" }.compactMap { $0["value"] as? [String: Any] }.last ?? [:] }
        func codingResults() -> [String: [String: Any]] {
            var out: [String: [String: Any]] = [:]
            for entry in lines(codingLog) where entry["kind"] as? String == "result" { if let v = entry["value"] as? [String: Any], let id = v["id"] as? String { out[id] = v["result"] as? [String: Any] ?? [:] } }
            return out
        }
        func refusal(_ work: () async throws -> Any) async -> String { do { _ = try await work(); return "" } catch { return error.localizedDescription } }
        func settled(_ job: [String: Any]) -> Bool { ["completed", "failed", "waiting_user", "cancelled", "interrupted"].contains(job["status"] as? String ?? "") }

        // MARK: an agent's step names its page

        await section("a web step must name its exact page: without one, or with one that is not a public https page, the agent is told to give it and nothing waits") {
            let bad: [[String: Any]] = [["need": "captcha", "reason": "Solve the CAPTCHA on the publisher's site."],
                                        ["need": "signin", "reason": "Sign in to the publisher.", "url": "http://iopscience.iop.org/article/x"],
                                        ["need": "verification", "reason": "Verify it's you.", "url": "https://localhost:8443/login"],
                                        ["need": "signin", "reason": "Sign in to the router.", "url": "https://192.168.1.10/"],
                                        ["need": "signin", "reason": "Sign in.", "url": "the publisher's website"]]
            for (n, step) in bad.enumerated() {
                let task = try await website(step, request: "bad-\(n)")
                let id = task["id"] as? String ?? ""
                let done = try await poll(id, "the attempt goes on after the refusal (\(step))") { settled($0) }
                let answer = told()
                let text = answer["text"] as? String ?? ""
                try require(answer["success"] as? Bool == false && text.contains("exact") && text.contains("url"), "the agent is told to give the exact page: \(answer)")
                try require(done["status"] as? String == "completed" && (done["checkpoint"] as? [String: Any] ?? [:]).isEmpty, "nothing waits for the person: \(done["status"] ?? "") \(done["checkpoint"] ?? "-")")
                try require(try await requests(id).isEmpty, "no request in the chat")
            }
        }
        var captcha = ""
        await section("a web step keeps its exact page, the task's own account and a one-line instruction, and the chat and Needs say the site") {
            let task = try await website(["need": "captcha", "reason": "The publisher shows a CAPTCHA before the PDF.", "url": article, "instruction": "Tick “I’m not a robot”, then wait for the article to load."],
                                         said: "Use my USC account to get me the Sethna article", request: "captcha")
            captcha = task["id"] as? String ?? ""
            try require(task["account"] as? String == usc, "the task carries the account the person named: \(task["account"] ?? "-")")
            let waiting = try await poll(captcha, "the task waits for the person") { $0["status"] as? String == "waiting_user" }
            let point = waiting["checkpoint"] as? [String: Any] ?? [:]
            try require(point["need"] as? String == "captcha" && point["url"] as? String == article && point["origin"] as? String == "https://iopscience.iop.org" && point["account"] as? String == usc
                        && point["instruction"] as? String == "Tick “I’m not a robot”, then wait for the article to load." && point["where"] as? String == "chrome" && point["routedTo"] as? String == "user",
                        "the step keeps its page, account and instruction: \(point)")
            let progress = waiting["progress"] as? String ?? ""
            try require(progress.contains("iopscience.iop.org") && !progress.contains("the website"), "the task says the site: \(progress)")
            let asked = try await requests(captcha)
            try require(asked.count == 1 && asked[0]["kind"] as? String == "step" && asked[0]["need"] as? String == "captcha" && asked[0]["url"] as? String == article
                        && asked[0]["origin"] as? String == "https://iopscience.iop.org" && asked[0]["account"] as? String == usc && asked[0]["instruction"] as? String == point["instruction"] as? String
                        && asked[0]["chromeOpen"] as? Bool == false && asked[0]["coding"] as? Bool != true, "the chat request names the page, the account and what to do: \(asked)")
            let cards = try await decisions(captcha)
            try require(cards.count == 1 && cards[0]["kind"] as? String == "step" && cards[0]["title"] as? String == "Finish the CAPTCHA on iopscience.iop.org" && cards[0]["audience"] as? String == "user", "one Needs item that says the site: \(cards)")
        }
        await section("the task's own account wins: a step for another account is refused, and one for no account uses the task's") {
            let other = try await website(["need": "signin", "reason": "Sign in to Gmail.", "url": "https://mail.google.com/mail/u/0/", "account": personal], said: "Use my USC account to read the advisor's email", request: "other-account")
            let id = other["id"] as? String ?? ""
            let done = try await poll(id, "the attempt goes on after the refusal") { settled($0) }
            let text = told()["text"] as? String ?? ""
            try require(text.contains(usc) && text.contains(personal), "the agent is told the task uses \(usc): \(text)")
            try require((done["checkpoint"] as? [String: Any] ?? [:]).isEmpty, "nothing waits: \(done["checkpoint"] ?? "-")")
            let invalid = try await website(["need": "signin", "reason": "Sign in.", "url": "https://accounts.example.org/login", "account": "not an email"], request: "invalid-account")
            _ = try await poll(invalid["id"] as? String ?? "", "the attempt goes on after the refusal") { settled($0) }
            try require((told()["text"] as? String ?? "").contains("email"), "an account that is not an email address is refused: \(told())")
            let named = try await website(["need": "signin", "reason": "Sign in to the journal.", "url": "https://accounts.example.org/login", "account": " Reader@Example.org "], request: "named-account")
            let waiting = try await poll(named["id"] as? String ?? "", "a step for the account the agent named waits") { $0["status"] as? String == "waiting_user" }
            let point = waiting["checkpoint"] as? [String: Any] ?? [:]
            try require(point["account"] as? String == "reader@example.org" && point["url"] as? String == "https://accounts.example.org/login", "a task with no account of its own keeps the one the agent named: \(point)")
            let asked = try await requests(named["id"] as? String ?? "")
            try require(asked.first?["account"] as? String == "reader@example.org", "and the chat says it: \(asked)")
            _ = try await worker(["operation": "cancel", "taskId": named["id"] ?? ""])
        }
        await section("Open the page opens exactly the step's page for this task, in its account; Done closes Chrome and looks at that page again in the task's own session") {
            let wrong = await refusal { try await worker(["operation": "browser", "taskId": captcha, "url": "https://evil.example/"]) }
            try require(!wrong.isEmpty && browser(captcha).filter { $0["command"] as? String == "manual" }.isEmpty, "a page other than the step's is never opened: \(wrong)")
            let opened = try await worker(["operation": "browser", "taskId": captcha, "url": article])
            try require(opened["opened"] as? Bool == true, "opened: \(opened)")
            let manual = browser(captcha).filter { $0["command"] as? String == "manual" }
            try require(manual.count == 1 && manual[0]["page"] as? String == article && manual[0]["account"] as? String == usc, "Chrome opens at the step's page, as the task's account: \(manual)")
            let point = (try await detail(captcha))["checkpoint"] as? [String: Any] ?? [:]
            try require(point["need"] as? String == "captcha" && point["url"] as? String == article, "the step stays what it was: \(point)")
            let asked = try await requests(captcha)
            try require(asked.first?["chromeOpen"] as? Bool == true && asked.first?["url"] as? String == article, "the chat knows Chrome is open: \(asked)")
            // Pressed again while Chrome is open for this task: the page is shown again, in the same Chrome.
            _ = try await worker(["operation": "browser", "taskId": captcha, "url": article])
            let again = browser(captcha).filter { $0["command"] as? String == "manual" }
            try require(again.count == 2 && again[1]["page"] as? String == article && lines(browserLog).filter { $0["command"] as? String == "finishManual" }.isEmpty, "the page opens again, Chrome is not closed: \(again)")
            let done = try await page(["action": "done", "taskId": captcha])
            try require(done["done"] as? Bool == true, "Done continues: \(done)")
            let rechecked = browser(captcha).filter { $0["command"] as? String == "recheck" }
            try require(rechecked.count == 1 && rechecked[0]["url"] as? String == article && rechecked[0]["reload"] as? Bool == true && rechecked[0]["account"] as? String == usc, "Done looks at the step's page again in the task's session: \(rechecked)")
            _ = try await poll(captcha, "the task continues after Done") { $0["status"] as? String == "completed" }
            let resumed = lines(serverLog).filter { $0["kind"] as? String == "turn" }.compactMap { ($0["value"] as? [String: Any])?["text"] as? String }.last ?? ""
            try require(resumed.contains("[Buddy]") && resumed.contains(article), "the agent is told the person finished, on which page: \(resumed.suffix(500))")
            try require((try await status())["privateBrowser"] is NSNull, "Chrome is closed")
        }

        // MARK: a coding session

        var fileTask = ""
        await section("a coding session's blocked download becomes a file step: never a sign-in, never its own private copy, never outside the folder") {
            let path = "stages/S01_protocol/sources/sethna-2022.pdf"
            fileTask = try await coding([
                ["buddy_checkpoint", ["need": "signin", "reason": "Sign in to iopscience to download the PDF.", "url": article]],
                ["buddy_checkpoint", ["need": "file", "reason": "Save the PDF.", "url": article, "folderId": "$PRIVATE", "path": "sethna-2022.pdf"]],
                ["buddy_checkpoint", ["need": "file", "reason": "Save the PDF.", "url": article, "folderId": folder, "path": "../outside.pdf"]],
                ["buddy_checkpoint", ["need": "file", "reason": "Save the PDF.", "url": article]],
                ["buddy_checkpoint", ["need": "file", "reason": "Save the article PDF from the publisher.", "url": article, "folderId": folder, "path": path, "instruction": "Use the Download PDF button on the article page."]]], request: "file-step")
            let waiting = try await poll(fileTask, "the coding task waits for the person to save the file") { $0["status"] as? String == "waiting_user" }
            let results = codingResults()
            let signin = results["c0"]?["error"] as? String ?? ""
            try require(signin.contains("need file") && signin.contains("Chrome"), "a sign-in step is refused, saying to ask for the file instead: \(signin)")
            try require((results["c1"]?["error"] as? String ?? "").contains("connected folder"), "its own private copy is not where the person saves: \(results["c1"] ?? [:])")
            try require(!(results["c2"]?["error"] as? String ?? "").isEmpty && !(results["c3"]?["error"] as? String ?? "").isEmpty, "a path outside the folder, or no folder, is refused: \(results["c2"] ?? [:]) \(results["c3"] ?? [:])")
            try require(results["c4"]?["error"] == nil && results["c4"]?["paused"] as? Bool == true, "the file step is taken: \(results["c4"] ?? [:])")
            let point = waiting["checkpoint"] as? [String: Any] ?? [:]
            try require(point["need"] as? String == "file" && point["url"] as? String == article && point["folderId"] as? String == folder && point["folderName"] as? String == "Directed Research"
                        && point["path"] as? String == path && point["target"] as? String == "Directed Research/" + path && point["instruction"] as? String == "Use the Download PDF button on the article page." && point["routedTo"] as? String == "user",
                        "the step keeps the page and where the file goes: \(point)")
            let asked = try await requests(fileTask)
            try require(asked.count == 1 && asked[0]["kind"] as? String == "step" && asked[0]["need"] as? String == "file" && asked[0]["url"] as? String == article && asked[0]["target"] as? String == "Directed Research/" + path && asked[0]["coding"] as? Bool == true,
                        "the chat asks to save the file from that page into that folder: \(asked)")
            let cards = try await decisions(fileTask)
            try require(cards.count == 1 && cards[0]["title"] as? String == "Save the PDF from iopscience.iop.org into Directed Research/stages/S01_protocol/sources" && cards[0]["audience"] as? String == "user", "the Needs item says it: \(cards)")
            let start = lines(codingLog).first { $0["kind"] as? String == "start" }?["value"] as? [String: Any] ?? [:]
            let brief = start["instructions"] as? String ?? ""
            try require(brief.contains("can't use Buddy's Chrome") && brief.contains("need file") && brief.contains("buddy_copy_into_project"), "the coding brief says a blocked download is a file step: \(brief.suffix(1200))")
        }
        await section("Open the page opens the file's page; Done tells the coding session where the file should now be, and never looks at a page for it") {
            _ = try await worker(["operation": "browser", "taskId": fileTask, "url": article])
            let manual = browser(fileTask).filter { $0["command"] as? String == "manual" }
            try require(manual.count == 1 && manual[0]["page"] as? String == article && (manual[0]["account"] as? String ?? "").isEmpty, "Chrome opens at the article: \(manual)")
            // The person saves it.
            try Data("%PDF-1.4 fixture".utf8).write(to: research.appendingPathComponent("stages/S01_protocol/sources/sethna-2022.pdf"))
            let done = try await page(["action": "done", "taskId": fileTask])
            try require(done["done"] as? Bool == true, "Done continues: \(done)")
            try require(browser(fileTask).filter { ["recheck", "open", "read"].contains($0["command"] as? String ?? "") }.isEmpty, "a coding task's Done looks at no page: \(browser(fileTask))")
            _ = try await poll(fileTask, "the coding task continues") { $0["status"] as? String == "completed" }
            let resumed = lines(codingLog).filter { $0["kind"] as? String == "start" }.compactMap { ($0["value"] as? [String: Any])?["prompt"] as? String }.last ?? ""
            try require(resumed.contains("[Buddy]") && resumed.contains("Directed Research/stages/S01_protocol/sources/sethna-2022.pdf") && resumed.contains(folder) && resumed.contains("buddy_copy_into_project") && resumed.contains("Buddy sees a file there"),
                        "the session is told where the file should be, that Buddy sees it, and to check it with its file tools: \(resumed.suffix(800))")
            try require((try await status())["privateBrowser"] is NSNull, "Chrome is closed")
        }

        // MARK: Buddy downloads the file itself

        // Chief's S01 stop (21 Oct): the person signed in on the publisher's site in Buddy's Chrome and asked the agent to download the paper,
        // but nothing could use that sign-in, so they were asked to save the PDF by hand. Now Done fetches it with their sign-in.
        func resumedPrompt() -> String { lines(codingLog).filter { $0["kind"] as? String == "start" }.compactMap { ($0["value"] as? [String: Any])?["prompt"] as? String }.last ?? "" }
        await section("Done on a file step with nothing saved yet: Buddy downloads it with the person's sign-in in its Chrome, saves it into the folder, and the session is told") {
            let path = "stages/S01_protocol/source_retry/ac498c.pdf", pdf = article + "/pdf"
            let id = try await coding([["buddy_checkpoint", ["need": "file", "reason": "Save the published PDF.", "url": pdf, "folderId": folder, "path": path]]], request: "file-download")
            let waiting = try await poll(id, "the coding task waits for the file") { $0["status"] as? String == "waiting_user" }
            let question = (waiting["checkpoint"] as? [String: Any])?["question"] as? String ?? ""
            try require(question.contains("Buddy downloads it") && question.contains("sign in"), "the step says Done downloads it with their sign-in: \(question)")
            _ = try await worker(["operation": "browser", "taskId": id, "url": pdf])   // The person opens the page and signs in there.
            let done = try await page(["action": "done", "taskId": id])
            try require(done["done"] as? Bool == true && done["downloaded"] as? Bool == true, "Done downloads it and continues: \(done)")
            let fetched = browser(id).filter { $0["command"] as? String == "download" }
            let staged = fetched.first?["to"] as? String ?? ""
            try require(fetched.count == 1 && fetched[0]["url"] as? String == pdf && fetched[0]["expect"] as? String == "pdf" && staged.hasPrefix(support.appendingPathComponent("Worker/Tasks/\(id)").path) && staged.hasSuffix(".part"),
                        "through Buddy's Chrome in the task's own session, into the task's own folder first: \(fetched)")
            let order = browser(id).compactMap { $0["command"] as? String }
            try require((order.firstIndex(of: "finishManual") ?? Int.max) < (order.firstIndex(of: "download") ?? -1) || !order.contains("finishManual"), "the person's window closes before Buddy's Chrome downloads: \(order)")
            let saved = try Data(contentsOf: research.appendingPathComponent(path))
            try require(String(decoding: saved, as: UTF8.self) == "%PDF-1.7 fixture downloaded\n", "the PDF is in the connected folder: \(saved.count) bytes")
            try require(!FileManager.default.fileExists(atPath: staged), "and nothing is left in the task's folder")
            _ = try await poll(id, "the coding task continues") { $0["status"] as? String == "completed" }
            let resumed = resumedPrompt()
            try require(resumed.contains("Buddy downloaded") && resumed.contains("Directed Research/" + path) && resumed.contains("Buddy sees a file there") && resumed.contains("buddy_copy_into_project"),
                        "the session is told Buddy downloaded it and where: \(resumed.suffix(700))")
            let versions = try BuddyProjectFiles(support: support).versions(BuddyFileScope(workspace: workspace, folderId: folder), path: path)
            try require(versions.count == 1, "it is a new file with its own receipt: \(versions)")
        }
        await section("a download that brings back a web page saves nothing, keeps the step and opens the page again; the person can still save it themselves") {
            let path = "stages/S01_protocol/source_retry/blocked.pdf", blocked = "https://iopscience.iop.org/captcha/ac498c.pdf"
            let id = try await coding([["buddy_checkpoint", ["need": "file", "reason": "Save the published PDF.", "url": blocked, "folderId": folder, "path": path]]], request: "file-blocked")
            _ = try await poll(id, "the coding task waits for the file") { $0["status"] as? String == "waiting_user" }
            let refused = try await page(["action": "done", "taskId": id])
            let note = refused["note"] as? String ?? ""
            try require(refused["done"] as? Bool == false && refused["reopened"] as? Bool == true && note.contains("web page") && note.contains("Chrome is open again"), "Done says why and keeps the step: \(refused)")
            try require(!FileManager.default.fileExists(atPath: research.appendingPathComponent(path).path), "nothing is saved")
            try require((try await detail(id))["status"] as? String == "waiting_user", "the task still waits")
            let manual = browser(id).filter { $0["command"] as? String == "manual" }
            try require(manual.last?["page"] as? String == blocked, "Chrome opens again at the page: \(manual)")
            // The person saves it by hand: Done sees it and downloads nothing.
            try Data("%PDF-1.4 saved by hand".utf8).write(to: research.appendingPathComponent(path))
            let done = try await page(["action": "done", "taskId": id])
            try require(done["done"] as? Bool == true && done["downloaded"] as? Bool != true, "Done continues with their file: \(done)")
            try require(browser(id).filter { $0["command"] as? String == "download" }.count == 1, "no second download")
            _ = try await poll(id, "the coding task continues") { $0["status"] as? String == "completed" }
            try require(String(decoding: try Data(contentsOf: research.appendingPathComponent(path)), as: UTF8.self) == "%PDF-1.4 saved by hand", "their file is kept as it is")
        }
        await section("an agent without internet access gets no download: Done continues as before and says Buddy doesn't see the file") {
            let path = "stages/S01_protocol/source_retry/offline.pdf"
            let id = try await coding([["buddy_checkpoint", ["need": "file", "reason": "Save the PDF.", "url": article + "/pdf", "folderId": folder, "path": path]]], as: bea, request: "file-offline")
            let waiting = try await poll(id, "the coding task waits for the file") { $0["status"] as? String == "waiting_user" }
            try require(!((waiting["checkpoint"] as? [String: Any])?["question"] as? String ?? "").contains("Buddy downloads it"), "its step doesn't promise a download")
            let done = try await page(["action": "done", "taskId": id])
            try require(done["done"] as? Bool == true && browser(id).filter { $0["command"] as? String == "download" }.isEmpty, "nothing is downloaded: \(done)")
            _ = try await poll(id, "the coding task continues") { $0["status"] as? String == "completed" }
            try require(resumedPrompt().contains("Buddy doesn't see a file at that exact path"), "the session is told the file isn't there")
        }

        // MARK: a step saved before steps named their page

        await section("an older step without its page uses the one page its task's result names, and says the site instead of “the website”") {
            let asked = try await requests(legacyNamed)
            try require(asked.count == 1 && asked[0]["url"] as? String == article && asked[0]["origin"] as? String == "https://iopscience.iop.org" && asked[0]["coding"] as? Bool == true,
                        "the page from the task's result: \(asked)")
            let instruction = asked[0]["instruction"] as? String ?? ""
            try require(instruction.contains("iopscience.iop.org") && !instruction.contains("the website"), "the instruction names the site: \(instruction)")
            let cards = try await decisions(legacyNamed)
            try require(cards.first?["title"] as? String == "Sign in to iopscience.iop.org", "the Needs item says the site: \(cards)")
            _ = try await worker(["operation": "browser", "taskId": legacyNamed, "url": article])
            let manual = browser(legacyNamed).filter { $0["command"] as? String == "manual" }
            try require(manual.count == 1 && manual[0]["page"] as? String == article, "Chrome opens at that page: \(manual)")
            let point = (try await detail(legacyNamed))["checkpoint"] as? [String: Any] ?? [:]
            try require(point["question"] as? String == legacyQuestion, "the stored step is kept as it was: \(point)")
            _ = try await page(["action": "done", "taskId": legacyNamed])
            _ = try await poll(legacyNamed, "the coding task continues") { $0["status"] as? String == "completed" }
            let resumed = lines(codingLog).filter { $0["kind"] as? String == "start" }.compactMap { ($0["value"] as? [String: Any])?["prompt"] as? String }.last ?? ""
            try require(resumed.contains("[Buddy]") && resumed.contains("can't use") && resumed.contains("need file"), "a coding session is told a sign-in in Chrome doesn't reach its commands, and to ask for the file: \(resumed.suffix(800))")
        }
        await section("an older step that names no page says Buddy doesn't know which page, and opens nothing") {
            let asked = try await requests(legacyBlank)
            try require(asked.count == 1 && asked[0]["url"] == nil && asked[0]["origin"] is NSNull && asked[0]["unknownPage"] as? Bool == true, "no page is made up: \(asked)")
            try require(!(asked[0]["instruction"] as? String ?? "").contains("the website"), "and it never says “the website”: \(asked)")
            let cards = try await decisions(legacyBlank)
            try require(cards.first?["title"] as? String == "Buddy doesn’t know which page this step is on", "the Needs item says so: \(cards)")
            let refused = await refusal { try await worker(["operation": "browser", "taskId": legacyBlank]) }
            try require(refused.contains("doesn’t know which page") && browser(legacyBlank).isEmpty, "Open opens nothing: \(refused)")
            _ = try await worker(["operation": "cancel", "taskId": legacyBlank])
        }

        if !failures.isEmpty { fputs("FAILED: \(failures.count) web step check(s) failed\n", stderr); exit(1) }
    }
}
