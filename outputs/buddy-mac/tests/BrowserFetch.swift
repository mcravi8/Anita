// run-tests: BuddyWorkerCore.swift BuddyOperationsDB.swift BuddyWorkerProcess.swift BuddyWorkerHost.swift BuddyCodexCoding.swift BuddyPlan.swift BuddySupervisor.swift BuddyMigrations.swift BuddyWorkerClient.swift BuddyAgentMemory.swift BuddyTeamMonitorStore.swift BuddyTeamMonitor.swift BuddyAISettings.swift ConversationService.swift BuddyInboxReview.swift BuddyMailVerification.swift BuddyComputer.swift BuddyTransport.swift BuddyToolInput.swift BuddyConnections.swift BuddyTeam.swift BuddyProjectFiles.swift BuddyDocuments.swift BuddyAgentProposals.swift BuddyCredentials.swift BuddyCommandReview.swift -- src:tests/browser-fetch-server.py src:tests/web-step-coding.py src:tests/browser-fetch-browser.py which:python3
import AppKit
import CryptoKit
import Darwin

/// "Can't use the logins in Buddy's Chrome — that's the whole point." Chief's S01 coding task needed the published PDF behind the
/// publisher's CAPTCHA, and nothing in Buddy could fetch it. Now any task, a coding session too, asks Buddy's Chrome to fetch a file with
/// buddy_browser_fetch: it is saved into the task's own project (or a folder the task may write to), the model hears only what was saved,
/// and a CAPTCHA or sign-in becomes a step for the person whose Done fetches the file again and resumes the task. Also: a password typed in
/// the chat can be remembered in the Keychain and filled next time, and while the person's Chrome window is open for one task, the others
/// keep browsing. End to end through the real worker with a stand-in ChatGPT and Codex (tests/browser-fetch-server.py), a stand-in Claude
/// coding bridge (tests/web-step-coding.py) and a stand-in shared browser (tests/browser-fetch-browser.py) that logs every command.
@main struct BrowserFetchChecks {
    struct Failed: Error { let message: String }
    static func require(_ value: Bool, _ message: @autoclosure () -> String) throws { if !value { throw Failed(message: message()) } }
    @MainActor static var failures: [String] = []
    @MainActor static func section(_ name: String, _ body: () async throws -> Void) async {
        do { try await body(); print("PASS: " + name) }
        catch let failed as Failed { failures.append(name); fputs("FAILED: \(name): \(failed.message)\n", stderr) }
        catch { failures.append(name); fputs("FAILED: \(name): \(error.localizedDescription)\n", stderr) }
    }
    /// The Keychain in memory: service sign-ins and remembered website passwords.
    final class Saved: BuddySignInStore, BuddyWebsiteSignInStore {
        var items: [String: BuddySignIn] = [:], sitePasswords: [String: String] = [:]
        func read(workspace: String, profile: String) -> BuddySignIn? { items[workspace + ":" + profile] }
        func save(workspace: String, profile: String, username: String, password: String) throws { items[workspace + ":" + profile] = BuddySignIn(username: username, password: password) }
        func remove(workspace: String, profile: String) throws { items.removeValue(forKey: workspace + ":" + profile) }
        func has(workspace: String, profile: String) -> Bool { items[workspace + ":" + profile] != nil }
        static func key(_ workspace: String, _ origin: String, _ username: String) -> String { workspace + "|" + origin + "|" + username }
        func sitePassword(workspace: String, origin: String, username: String) -> String? { sitePasswords[Self.key(workspace, origin, username)] }
        func saveSite(workspace: String, origin: String, username: String, password: String) throws { sitePasswords[Self.key(workspace, origin, username)] = password }
        func removeSite(workspace: String, origin: String, username: String) throws { sitePasswords.removeValue(forKey: Self.key(workspace, origin, username)) }
        func sites(workspace: String) -> [BuddyWebsiteSignIn] {
            sitePasswords.keys.compactMap { key in
                let parts = key.components(separatedBy: "|"); guard parts.count == 3, parts[0] == workspace else { return nil }
                return BuddyWebsiteSignIn(origin: parts[1], username: parts[2])
            }.sorted { $0.origin < $1.origin }
        }
    }
    static let personal = "me.personal@gmail.com", usc = "craviott@usc.edu"
    static let article = "https://iopscience.iop.org/article/10.1088/1742-5468/ac498c"
    static let pdf = "%PDF-1.7\n% fixture: the published article ac498c\n%%EOF\n"
    static func chrome(_ profile: URL, accounts: [String]) throws {
        try FileManager.default.createDirectory(at: profile.appendingPathComponent("Default"), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["profile": ["info_cache": ["Default": ["user_name": accounts.first ?? "", "name": "Person 1"]]]]).write(to: profile.appendingPathComponent("Local State"))
        try JSONSerialization.data(withJSONObject: ["account_info": accounts.map { ["email": $0, "full_name": "Fixture", "gaia": UUID().uuidString] }, "profile": ["name": "Person 1"]]).write(to: profile.appendingPathComponent("Default/Preferences"))
    }
    static func json(_ value: Any) -> String { (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "" }
    static func sha(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    static func quarantine(_ url: URL) -> String {
        var buffer = [CChar](repeating: 0, count: 512)
        let count = getxattr(url.path, "com.apple.quarantine", &buffer, buffer.count - 1, 0, 0)
        return count > 0 ? String(cString: buffer) : ""
    }

    @MainActor static func main() async throws {
        let arguments = CommandLine.arguments   // [1] the ChatGPT/Codex stand-in, [2] the Claude coding stand-in, [3] the shared browser stand-in, [4] python3
        // A stand-in that can't be run is passed over for the Codex installed on this Mac, signed in to the person's ChatGPT: never that.
        guard FileManager.default.isExecutableFile(atPath: arguments[1]) else { fputs("FAILED: the ChatGPT stand-in \(arguments[1]) is not executable\n", stderr); exit(1) }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("buddy-browser-fetch-" + UUID().uuidString + ".noindex")
        let support = base.appendingPathComponent("Support", isDirectory: true), logs = base.appendingPathComponent("Fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true); try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let serverLog = logs.appendingPathComponent("server.jsonl"), codingLog = logs.appendingPathComponent("coding.jsonl"), browserLog = logs.appendingPathComponent("browser.jsonl")
        let secret = "Shop!pw-41Kx-not-real", wrong = "remembered-wrong-88Qz"
        setenv("BUDDY_FETCH_SERVER_LOG", serverLog.path, 1); setenv("BUDDY_STEP_CODING_LOG", codingLog.path, 1); setenv("BUDDY_FETCH_BROWSER_LOG", browserLog.path, 1); setenv("BUDDY_FETCH_RIGHT_SHA256", sha(secret), 1)
        let workspace = UUID().uuidString, chief = UUID().uuidString, clara = UUID().uuidString, bea = UUID().uuidString, ada = UUID().uuidString
        try JSONSerialization.data(withJSONObject: ["conversationWorkspace": workspace, "agents": [
            ["id": chief, "name": "Chief", "role": "Chief of staff", "description": "Codes on ChatGPT", "tools": ["web": true, "desktop": true, "projectFiles": true]],
            ["id": clara, "name": "Clara", "role": "Engineer", "description": "Codes on Claude", "tools": ["web": true, "desktop": true, "projectFiles": true]],
            ["id": bea, "name": "Bea", "role": "Analyst", "description": "Codes offline", "tools": ["web": false, "desktop": true, "projectFiles": true]],
            ["id": ada, "name": "Ada", "role": "Assistant", "description": "Website tasks", "tools": ["web": true, "desktop": true, "projectFiles": true]]]]).write(to: support.appendingPathComponent("workspace.json"))
        let models = BuddyAgentModels(support: support)
        try models.set(workspace: workspace, agent: chief, selection: .init(provider: "chatgpt", model: "fixture"))
        try models.set(workspace: workspace, agent: clara, selection: .init(provider: "claude", model: "claude-fixture"))
        try models.set(workspace: workspace, agent: bea, selection: .init(provider: "claude", model: "claude-fixture"))
        try chrome(support.appendingPathComponent("Worker/Browsers/Shared", isDirectory: true), accounts: [personal, usc])
        let research = base.appendingPathComponent("Directed Research", isDirectory: true)
        try FileManager.default.createDirectory(at: research, withIntermediateDirectories: true)
        let folder = try BuddyProjectFiles(support: support).addFolder(workspace, to: research)["folderId"] as? String ?? ""
        let saved = Saved()
        // Long enough that a task waiting for the person's window would plainly miss its deadline below.
        BuddyWorkerHost.sharedChromeWait = 120
        let host = BuddyWorkerHost(support: support, executable: URL(fileURLWithPath: arguments[1]),
                                   makeBrowser: { BuddyWorkerProcess(resource: URL(fileURLWithPath: arguments[3]), runtime: URL(fileURLWithPath: arguments[4])) },
                                   makeCoding: { BuddyWorkerProcess(resource: URL(fileURLWithPath: arguments[2]), runtime: URL(fileURLWithPath: arguments[4])) },
                                   makeClaude: { BuddyWorkerProcess(resource: URL(fileURLWithPath: arguments[2]), runtime: URL(fileURLWithPath: arguments[4])) },
                                   keyReader: { _ in "inert-fixture-key" }, credentials: saved)
        host.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer { host.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)) }

        func worker(_ payload: [String: Any]) async throws -> [String: Any] { try await BuddyWorkerClient.call(support: support, payload: payload.merging(["workspace": workspace]) { old, _ in old }) }
        func page(_ payload: [String: Any]) async throws -> [String: Any] { try await BuddySignInBox.handle(payload, workspace: workspace, support: support, store: saved) }
        func coding(_ calls: [[Any]], as agent: String, request: String) async throws -> String {
            let reply = try await worker(["operation": "coding", "agentId": agent, "requestId": request, "arguments": ["action": "start", "title": "Get the Sethna article", "goal": "Download the article PDF into the project. CALLS:" + json(calls)]])
            return (reply["task"] as? [String: Any])?["id"] as? String ?? ""
        }
        func website(_ calls: [[Any]], said: String = "Get me the Sethna article", request: String) async throws -> [String: Any] {
            (try await worker(["operation": "computer", "agentId": ada, "actorId": ada, "requestId": request, "authorizedText": said, "arguments": ["action": "start", "title": "Get the article", "goal": "Get the article. CALLS:" + json(calls)]]))["task"] as? [String: Any] ?? [:]
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
        func commands(_ name: String) -> [[String: Any]] { lines(browserLog).filter { $0["command"] as? String == name } }
        func server(_ kind: String) -> [[String: Any]] { lines(serverLog).filter { $0["kind"] as? String == kind }.compactMap { $0["value"] as? [String: Any] } }
        func codingResults() -> [[String: Any]] { lines(codingLog).filter { $0["kind"] as? String == "result" }.compactMap { ($0["value"] as? [String: Any])?["result"] as? [String: Any] } }
        func project(_ id: String) -> URL { support.appendingPathComponent("Worker/Tasks/\(id)/Files", isDirectory: true) }
        func settled(_ job: [String: Any]) -> Bool { ["completed", "failed", "waiting_user", "waiting_review", "cancelled", "interrupted"].contains(job["status"] as? String ?? "") }
        /// The thread a coding task's Codex turns ran on: the one whose turn names its brief's file.
        func threadReads(_ path: String) -> [String] { server("read").filter { $0["path"] as? String == path }.compactMap { $0["content"] as? String } }
        let leaks = ["SECRET-COOKIE", "SECRET-HEADER", "cookie", "set-cookie", "headers"]

        // MARK: a coding session fetches with Buddy's Chrome

        var codexFetch = ""
        await section("a Codex coding session fetches the published PDF with Buddy's Chrome into its own project and reads it there; it hears only the receipt, and nobody is asked to approve it") {
            let url = article + "/pdf"
            codexFetch = try await coding([["buddy_browser_fetch", ["url": url, "saveAs": "sources/ac498c.pdf", "reason": "The S01 protocol cites this paper."]]], as: chief, request: "codex-fetch")
            let done = try await poll(codexFetch, "the Codex task finishes") { settled($0) }
            try require(done["status"] as? String == "completed" && done["provider"] as? String == "chatgpt", "it completes on Codex: \(done["status"] ?? "") \(done["progress"] ?? "")")
            let fetched = browser(codexFetch + ":fetch").filter { $0["command"] as? String == "fetch" }
            try require(fetched.count == 1 && fetched[0]["url"] as? String == url && fetched[0]["saveAs"] as? String == "ac498c.pdf" && (fetched[0]["dir"] as? String ?? "").hasPrefix(support.appendingPathComponent("Worker/Tasks/\(codexFetch)/Downloads").path),
                        "fetched once in the task's own session of Buddy's Chrome, staged in the task's own folder: \(fetched)")
            try require(browser(codexFetch + ":fetch").contains { $0["command"] as? String == "closeSession" }, "the fetch's page is closed afterwards")
            let file = project(codexFetch).appendingPathComponent("sources/ac498c.pdf")
            try require((try? String(contentsOf: file, encoding: .utf8)) == pdf, "the PDF is in the project, where the session's own tools see it")
            try require(quarantine(file).contains("Buddy"), "it keeps macOS quarantine: \(quarantine(file))")
            let staged = (try? FileManager.default.contentsOfDirectory(atPath: support.appendingPathComponent("Worker/Tasks/\(codexFetch)/Downloads").path)) ?? []
            try require(staged.isEmpty, "nothing is left in the staging folder: \(staged)")
            try require(threadReads("sources/ac498c.pdf").first == pdf, "the session read the file from its project: \(server("read"))")
            let told = server("result").first { $0["tool"] as? String == "buddy_browser_fetch" } ?? [:], text = told["text"] as? String ?? ""
            let value = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
            try require(told["success"] as? Bool == true && value["saved"] as? Bool == true && value["path"] as? String == "sources/ac498c.pdf" && value["bytes"] as? Int == pdf.utf8.count
                        && value["sha256"] as? String == sha(pdf) && value["contentType"] as? String == "application/pdf", "the receipt: path, size, type, sha256: \(text)")
            try require(!leaks.contains { text.contains($0) }, "never a cookie or a header: \(text)")
            let receipt = (done["fetches"] as? [[String: Any]] ?? []).last ?? [:]
            try require(receipt["url"] as? String == url && receipt["path"] as? String == "sources/ac498c.pdf" && receipt["folderId"] as? String == codexFetch && receipt["sha256"] as? String == sha(pdf)
                        && receipt["bytes"] as? Int == pdf.utf8.count && (receipt["finalUrl"] as? String ?? "").contains("[private]"), "the task keeps the receipt: \(receipt)")
            try require((done["reviews"] as? [[String: Any]] ?? []).isEmpty, "a fetch into the project is routine: no approval card")
            let start = server("start").first { $0["coding"] as? Bool == true } ?? [:]
            try require((start["tools"] as? [String] ?? []).contains("buddy_browser_fetch"), "the Codex thread has the tool: \(start["tools"] ?? "-")")
            let brief = start["instructions"] as? String ?? ""
            try require(brief.contains("buddy_browser_fetch") && !brief.contains("never ask them to sign in or solve a CAPTCHA"), "the coding brief says to fetch with Buddy's Chrome: \(brief.suffix(1500))")
        }
        await section("a CAPTCHA becomes the person's step: Open the page, Done; Buddy fetches again in the same Chrome, saves the file and resumes the session with a note naming it") {
            let blocked = "https://iopscience.iop.org/captcha/article/10.1088/1742-5468/ac498c/pdf"
            let id = try await coding([["buddy_browser_fetch", ["url": blocked, "saveAs": "sources/sethna-2022.pdf", "reason": "The S01 protocol cites this paper."]]], as: chief, request: "codex-captcha")
            let waiting = try await poll(id, "the task waits for the person") { $0["status"] as? String == "waiting_user" }
            let point = waiting["checkpoint"] as? [String: Any] ?? [:], fetch = point["fetch"] as? [String: Any] ?? [:]
            try require(point["need"] as? String == "captcha" && point["url"] as? String == blocked && point["origin"] as? String == "https://iopscience.iop.org" && point["routedTo"] as? String == "user"
                        && fetch["url"] as? String == blocked && fetch["path"] as? String == "sources/sethna-2022.pdf" && fetch["folderId"] as? String == id, "a web step for the exact page, with the fetch to do again: \(point)")
            let instruction = point["instruction"] as? String ?? ""
            try require(instruction.contains("CAPTCHA") && instruction.contains("iopscience.iop.org") && instruction.contains("Buddy will save") && instruction.contains("Done"), "the person is told what to do and what Buddy does next: \(instruction)")
            try require(!FileManager.default.fileExists(atPath: project(id).appendingPathComponent("sources/sethna-2022.pdf").path), "nothing is saved yet")
            let asked = try await requests(id)
            try require(asked.count == 1 && asked[0]["kind"] as? String == "step" && asked[0]["need"] as? String == "captcha" && asked[0]["url"] as? String == blocked && asked[0]["fetch"] as? Bool == true
                        && (asked[0]["target"] as? String ?? "").hasSuffix("sources/sethna-2022.pdf"), "the chat card: the page, Open the page and Done, and where the file goes: \(asked)")
            let cards = try await decisions(id)
            try require(cards.count == 1 && cards[0]["title"] as? String == "Finish the CAPTCHA on iopscience.iop.org", "one Needs item that says the site: \(cards)")
            let told = server("result").last { $0["tool"] as? String == "buddy_browser_fetch" } ?? [:], text = told["text"] as? String ?? ""
            try require(text.contains("paused") && !leaks.contains { text.contains($0) }, "the session is told to end the attempt: \(text)")
            // Done before the person did anything: Buddy fetches again, it is still the CAPTCHA, and the step stays with Chrome open at the page.
            let early = try await page(["action": "done", "taskId": id])
            try require(early["done"] as? Bool == false && early["reopened"] as? Bool == true && (early["note"] as? String ?? "").contains("still"), "it says it isn't finished yet: \(early)")
            try require(browser(id).filter { $0["command"] as? String == "manual" }.last?["page"] as? String == blocked, "Chrome opens at that page: \(browser(id))")
            let stays = try await detail(id), still = try await requests(id)
            try require(stays["status"] as? String == "waiting_user" && still.count == 1, "the card stays")
            // Meanwhile another task browses: it does not wait for the person's window.
            let other = try await website([["buddy_browser", ["operation": "open", "url": "https://shop.example/orders"]]], request: "browse-meanwhile")
            let otherID = other["id"] as? String ?? ""
            let began = Date()
            _ = try await poll(otherID, "another task's browsing goes on while the person's window is open", seconds: 20) { settled($0) }
            try require(Date().timeIntervalSince(began) < 20 && browser(otherID).contains { $0["command"] as? String == "open" }, "it opened its page without waiting: \(browser(otherID))")
            try require(((try await status())["privateBrowser"] as? [String: Any])?["taskId"] as? String == id, "the person's window is still open for the CAPTCHA task")
            // The person solves it in the window and presses Done: the window closes, Buddy fetches again and saves the file.
            let done = try await page(["action": "done", "taskId": id])
            try require(done["done"] as? Bool == true && done["fetched"] as? Bool == true, "Done fetches and continues: \(done)")
            let order = browser(id).compactMap { $0["command"] as? String } + []
            try require((commands("finishManual").count >= 1), "the person's window was closed first: \(order)")
            let file = project(id).appendingPathComponent("sources/sethna-2022.pdf")
            try require((try? String(contentsOf: file, encoding: .utf8)) == pdf && quarantine(file).contains("Buddy"), "the PDF is in the project, quarantined")
            _ = try await poll(id, "the session continues") { $0["status"] as? String == "completed" }
            let resumed = server("turn").last?["text"] as? String ?? ""
            try require(resumed.contains("[Buddy]") && resumed.contains("in your project at sources/sethna-2022.pdf") && resumed.contains("iopscience.iop.org"), "the session is told where the file is: \(resumed.suffix(700))")
            try require(threadReads("sources/sethna-2022.pdf").first == pdf, "and reads it: \(server("read"))")
            try require((try await status())["privateBrowser"] is NSNull, "Chrome is closed")
        }
        await section("a Claude coding session fetches into its project too; an agent without internet access is refused plainly and nothing is fetched") {
            let id = try await coding([["buddy_browser_fetch", ["url": article + "/pdf", "saveAs": "data/ac498c.pdf", "reason": "Needed for the replication."]]], as: clara, request: "claude-fetch")
            _ = try await poll(id, "the Claude task finishes") { settled($0) }
            try require((try? String(contentsOf: project(id).appendingPathComponent("data/ac498c.pdf"), encoding: .utf8)) == pdf, "saved into the Claude session's project")
            let start = lines(codingLog).first { $0["kind"] as? String == "start" }?["value"] as? [String: Any] ?? [:]
            try require((start["tools"] as? [String] ?? []).contains("buddy_browser_fetch") && (start["instructions"] as? String ?? "").contains("buddy_browser_fetch"), "Claude's coding session has the tool and is told to use it")
            try require((start["instructions"] as? String ?? "").contains("End with your result. " + BuddyVoice.plain + " " + BuddyVoice.result) && !(start["instructions"] as? String ?? "").contains("list those choices in your final summary"), "Claude's coding session ends with a plain message to the person, then the details for the team")
            let offline = try await coding([["buddy_browser_fetch", ["url": article + "/pdf", "saveAs": "ac498c.pdf", "reason": "Needed."]]], as: bea, request: "offline-fetch")
            _ = try await poll(offline, "the offline task goes on after the refusal") { settled($0) }
            let refused = codingResults().last?["error"] as? String ?? ""
            try require(refused.contains("internet") && refused.contains("Nothing was fetched"), "refused plainly: \(refused)")
            try require(browser(offline + ":fetch").isEmpty && !FileManager.default.fileExists(atPath: project(offline).appendingPathComponent("ac498c.pdf").path), "nothing is fetched")
        }

        // MARK: a website task

        await section("a website task's fetch keeps its account and its folder: another account and a path outside the folder are refused; it saves into a connected folder it names, or its own") {
            let task = try await website([
                ["buddy_browser_fetch", ["url": "https://files.example.org/report.pdf", "saveAs": "report.pdf", "reason": "The report.", "account": personal]],
                ["buddy_browser_fetch", ["url": "https://files.example.org/report.pdf", "saveAs": "../outside.pdf", "reason": "The report."]],
                ["buddy_browser_fetch", ["url": "file:///etc/passwd", "saveAs": "passwd.txt", "reason": "The report."]],
                ["buddy_browser_fetch", ["url": "https://files.example.org/report.pdf", "saveAs": "reports/q3.pdf", "reason": "The report.", "folderId": folder]]],
                said: "Use my USC account to get the quarterly report", request: "website-fetch")
            let id = task["id"] as? String ?? ""
            try require(task["account"] as? String == usc, "the task uses the account the person named: \(task["account"] ?? "-")")
            _ = try await poll(id, "the website task finishes") { settled($0) }
            let results = server("result").filter { ($0["tool"] as? String) == "buddy_browser_fetch" }.suffix(4).map { $0["text"] as? String ?? "" }
            try require(results.count == 4 && results[0].contains(usc) && results[1].contains("saveAs") && results[2].contains("http"), "another account, a path outside, and a non-web address are refused: \(results)")
            let fetched = browser(id + ":fetch").filter { $0["command"] as? String == "fetch" }
            try require(fetched.count == 1 && fetched[0]["account"] as? String == usc, "only the last is fetched, as the task's account: \(fetched)")
            try require((try? String(contentsOf: research.appendingPathComponent("reports/q3.pdf"), encoding: .utf8)) == pdf, "saved into the connected folder it named")
            let versions = try BuddyProjectFiles(support: support).versions(BuddyFileScope(workspace: workspace, folderId: folder), path: "reports/q3.pdf")
            try require(versions.count == 1, "with a file receipt like any file Buddy writes: \(versions)")
            let own = try await website([["buddy_browser_fetch", ["url": "https://files.example.org/report.pdf", "saveAs": "q3.pdf", "reason": "The report."]]], request: "website-own")
            let ownID = own["id"] as? String ?? ""
            _ = try await poll(ownID, "the second website task finishes") { settled($0) }
            try require((try? String(contentsOf: project(ownID).appendingPathComponent("q3.pdf"), encoding: .utf8)) == pdf, "without a folder, into the task's own folder")
            // The same name again in the same folder: a new file, never over the first.
            let again = try await website([["buddy_browser_fetch", ["url": "https://files.example.org/report.pdf", "saveAs": "reports/q3.pdf", "reason": "Again.", "folderId": folder]]], request: "website-again")
            _ = try await poll(again["id"] as? String ?? "", "the third website task finishes") { settled($0) }
            try require(FileManager.default.fileExists(atPath: research.appendingPathComponent("reports/q3 (2).pdf").path), "a number is added instead of replacing: \((try? FileManager.default.contentsOfDirectory(atPath: research.appendingPathComponent("reports").path)) ?? [])")
        }
        await section("a sign-in form on the way to a file is the person's step too, for a website task; Done fetches and resumes it") {
            let url = "https://data.example.org/members/data.csv"
            let task = try await website([["buddy_browser_fetch", ["url": url, "saveAs": "data.csv", "reason": "The members' dataset."]]], request: "website-signin")
            let id = task["id"] as? String ?? ""
            let waiting = try await poll(id, "the task waits for the person") { $0["status"] as? String == "waiting_user" }
            let point = waiting["checkpoint"] as? [String: Any] ?? [:]
            try require(point["need"] as? String == "signin" && point["url"] as? String == url && (point["instruction"] as? String ?? "").contains("Sign in"), "a sign-in step at that page: \(point)")
            _ = try await worker(["operation": "browser", "taskId": id, "url": url])
            let done = try await page(["action": "done", "taskId": id])
            try require(done["done"] as? Bool == true && done["fetched"] as? Bool == true, "Done fetches: \(done)")
            _ = try await poll(id, "the task continues") { $0["status"] as? String == "completed" }
            try require(FileManager.default.fileExists(atPath: project(id).appendingPathComponent("data.csv").path), "saved into its folder")
            let resumed = server("turn").last?["text"] as? String ?? ""
            try require(resumed.contains("[Buddy]") && resumed.contains("data.csv"), "resumed with a note naming the file: \(resumed.suffix(500))")
        }

        // MARK: a password typed in the chat, remembered

        await section("a password typed in the chat with Remember on is kept in the Keychain for that site and account, and filled by Buddy next time with no card") {
            let first = try await website([["buddy_browser_signin", ["mode": "signin", "reason": "Read my last order"]]], request: "remember-1")
            let id = first["id"] as? String ?? ""
            _ = try await poll(id, "the sign-in asks the person") { $0["status"] as? String == "waiting_review" }
            var asked: [[String: Any]] = []
            for _ in 0..<100 { asked = try await requests(id).filter { $0["kind"] as? String == "signin" && $0["field"] as? String == "password" }; if !asked.isEmpty { break }; try await Task.sleep(nanoseconds: 50_000_000) }
            try require(asked.count == 1 && asked[0]["account"] as? String == "ada@example.com" && asked[0]["origin"] as? String == "https://shop.example", "the private field, for that site and account: \(asked)")
            let sent = try await page(["action": "secret", "taskId": id, "reviewId": asked[0]["reviewId"] ?? "", "value": secret, "remember": true])
            try require(sent["signedIn"] as? Bool == true && sent["remembered"] as? Bool == true, "signed in, and remembered: \(sent)")
            try require(saved.sitePassword(workspace: workspace, origin: "https://shop.example", username: "ada@example.com") == secret, "kept in the Keychain store for that site and account")
            _ = try await poll(id, "the first task finishes") { settled($0) }
            // Next time: Buddy fills it itself, no card.
            let second = try await website([["buddy_browser_signin", ["mode": "signin", "reason": "Read my last order again"]]], request: "remember-2")
            let secondID = second["id"] as? String ?? ""
            let done = try await poll(secondID, "the second task signs in by itself") { settled($0) }
            let cards = try await requests(secondID)
            try require(done["status"] as? String == "completed" && cards.isEmpty, "no card: \(done["status"] ?? "") \(done["progress"] ?? "")")
            let filled = browser(secondID).filter { $0["command"] as? String == "fillSecret" }
            try require(filled.count == 1 && filled[0]["valueSHA256"] as? String == sha(secret), "the remembered password went into that page: \(filled)")
            let told = server("result").last { $0["tool"] as? String == "buddy_browser_signin" }?["text"] as? String ?? ""
            try require(told.contains("signedIn") && !told.contains(secret), "the agent hears only that it is signed in: \(told)")
            // A remembered password that no longer works: the person is asked, and what they send replaces it.
            try saved.saveSite(workspace: workspace, origin: "https://shop.example", username: "ada@example.com", password: wrong)
            let third = try await website([["buddy_browser_signin", ["mode": "signin", "reason": "Read my orders"]]], request: "remember-3")
            let thirdID = third["id"] as? String ?? ""
            var again: [[String: Any]] = []
            for _ in 0..<200 { again = try await requests(thirdID).filter { $0["kind"] as? String == "signin" && $0["field"] as? String == "password" }; if !again.isEmpty { break }; try await Task.sleep(nanoseconds: 50_000_000) }
            try require(again.count == 1 && (again[0]["note"] as? String ?? "").contains("remembered"), "the card says the remembered password didn't work: \(again)")
            let fixed = try await page(["action": "secret", "taskId": thirdID, "reviewId": again[0]["reviewId"] ?? "", "value": secret, "remember": true])
            try require(fixed["signedIn"] as? Bool == true && saved.sitePassword(workspace: workspace, origin: "https://shop.example", username: "ada@example.com") == secret, "replaced: \(fixed)")
            _ = try await poll(thirdID, "the third task finishes") { settled($0) }
            // Remember off: nothing is kept.
            try saved.removeSite(workspace: workspace, origin: "https://shop.example", username: "ada@example.com")
            let fourth = try await website([["buddy_browser_signin", ["mode": "signin", "reason": "Read my orders"]]], request: "remember-4")
            let fourthID = fourth["id"] as? String ?? ""
            var plain: [[String: Any]] = []
            for _ in 0..<200 { plain = try await requests(fourthID).filter { $0["kind"] as? String == "signin" && $0["field"] as? String == "password" }; if !plain.isEmpty { break }; try await Task.sleep(nanoseconds: 50_000_000) }
            let unsaved = try await page(["action": "secret", "taskId": fourthID, "reviewId": plain.first?["reviewId"] ?? "", "value": secret, "remember": false])
            try require(unsaved["signedIn"] as? Bool == true && unsaved["remembered"] as? Bool != true && saved.sites(workspace: workspace).isEmpty, "Remember off keeps nothing: \(unsaved)")
            _ = try await poll(fourthID, "the fourth task finishes") { settled($0) }
            // Never in a file Buddy wrote.
            let found = FileManager.default.enumerator(at: support, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }.filter { url in (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self).contains(secret) } ?? false } ?? []
            try require(found.isEmpty, "the password is in no file Buddy wrote: \(found.map(\.path))")
        }
        await section("remembered website sign-ins are listed (site and account, never the password), replaced and removed in Buddy's own sign-in box") {
            try saved.saveSite(workspace: workspace, origin: "https://shop.example", username: "ada@example.com", password: secret)
            let listed = try await page(["action": "sites"])
            let sites = listed["sites"] as? [[String: Any]] ?? []
            try require(sites.count == 1 && sites[0]["origin"] as? String == "https://shop.example" && sites[0]["username"] as? String == "ada@example.com" && !json(listed).contains(secret), "listed without the password: \(listed)")
            _ = try await page(["action": "replaceSite", "origin": "https://shop.example", "username": "ada@example.com", "password": "new-" + secret])
            try require(saved.sitePassword(workspace: workspace, origin: "https://shop.example", username: "ada@example.com") == "new-" + secret, "replaced")
            let refused = await { do { _ = try await page(["action": "replaceSite", "origin": "https://never-remembered.example", "username": "x@example.com", "password": "x"]); return "" } catch { return error.localizedDescription } }()
            try require(!refused.isEmpty, "only a remembered sign-in can be replaced here: \(refused)")
            _ = try await page(["action": "removeSite", "origin": "https://shop.example", "username": "ada@example.com"])
            let left = try await page(["action": "sites"])
            try require(saved.sites(workspace: workspace).isEmpty && (left["sites"] as? [Any] ?? [1]).isEmpty, "removed")
        }

        if !failures.isEmpty { fputs("FAILED: \(failures.count) browser fetch check(s) failed\n", stderr); exit(1) }
    }
}
