// run-tests: BuddyWorkerCore.swift BuddyOperationsDB.swift BuddyWorkerProcess.swift BuddyWorkerHost.swift BuddyCodexCoding.swift BuddyPlan.swift BuddySupervisor.swift BuddyMigrations.swift BuddyWorkerClient.swift BuddyAgentMemory.swift BuddyTeamMonitorStore.swift BuddyTeamMonitor.swift BuddyAISettings.swift ConversationService.swift BuddyInboxReview.swift BuddyMailVerification.swift BuddyComputer.swift BuddyTransport.swift BuddyToolInput.swift BuddyConnections.swift BuddyTeam.swift BuddyProjectFiles.swift BuddyDocuments.swift BuddyAgentProposals.swift BuddyCredentials.swift BuddyCommandReview.swift -- src:tests/accounts-server.py src:tests/accounts-browser.py which:python3
import AppKit
import CryptoKit

/// "When it needs to access something and an account is needed, ask each time is it fine to create account for … for now it's not enabled to
/// spend money or sign up for free trials which result in later payment unless asked first." An agent that needs an account calls
/// buddy_browser_signup; Buddy asks the person in the chat, every time and for each site, and only their click on that card counts. On their
/// yes Buddy makes the password itself, fills the sign-up in the task's page, keeps the password in the Keychain, confirms the email from their
/// Gmail and says so on the card. A sign-up that asks for money stops with Open the page and Skip. A remembered password that no longer works
/// is reset through the email, again only on the person's yes. End to end through the real worker with a stand-in ChatGPT
/// (tests/accounts-server.py), a stand-in shared browser (tests/accounts-browser.py), the Keychain and the mailbox in memory.
@main struct WebsiteAccountsChecks {
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
    static let email = "matteo.craviotto@gmail.com", other = "matteo@usc.example"
    static func sha(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    static func json(_ value: Any) -> String { (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "" }

    @MainActor static func main() async throws {
        let arguments = CommandLine.arguments   // [1] the ChatGPT stand-in, [2] the shared browser stand-in, [3] python3
        // A stand-in that can't be run is passed over for the Codex installed on this Mac, signed in to the person's ChatGPT: never that.
        guard FileManager.default.isExecutableFile(atPath: arguments[1]) else { fputs("FAILED: the ChatGPT stand-in \(arguments[1]) is not executable\n", stderr); exit(1) }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("buddy-website-accounts-" + UUID().uuidString + ".noindex")
        let support = base.appendingPathComponent("Support", isDirectory: true), logs = base.appendingPathComponent("Fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true); try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let serverLog = logs.appendingPathComponent("server.jsonl"), browserLog = logs.appendingPathComponent("browser.jsonl")
        let right = "Reset-site!pw-31Qz-not-real", stale = "remembered-wrong-77Kx"
        setenv("BUDDY_ACCOUNTS_SERVER_LOG", serverLog.path, 1); setenv("BUDDY_ACCOUNTS_BROWSER_LOG", browserLog.path, 1); setenv("BUDDY_ACCOUNTS_RESET_SHA256", sha(right), 1)
        let workspace = UUID().uuidString, jobApply = UUID().uuidString
        try JSONSerialization.data(withJSONObject: ["conversationWorkspace": workspace, "agents": [
            ["id": jobApply, "name": "JobApply", "role": "Applications", "description": "Applies for jobs", "tools": ["web": true, "desktop": true, "projectFiles": true]]]]).write(to: support.appendingPathComponent("workspace.json"))
        // Buddy's Chrome is signed in to two Google accounts; the person's words choose the task's.
        let profile = support.appendingPathComponent("Worker/Browsers/Shared", isDirectory: true)
        try FileManager.default.createDirectory(at: profile.appendingPathComponent("Default"), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["profile": ["info_cache": ["Default": ["user_name": email, "name": "Person 1"]]]]).write(to: profile.appendingPathComponent("Local State"))
        try JSONSerialization.data(withJSONObject: ["account_info": [email, other].map { ["email": $0, "full_name": "Fixture", "gaia": UUID().uuidString] }, "profile": ["name": "Person 1"]]).write(to: profile.appendingPathComponent("Default/Preferences"))
        // The person's mailbox: what each site sent, by purpose. nomail.example's email never arrives.
        var mailAsked: [String] = []
        let mailbox: BuddyAccountMailbox = { request in
            mailAsked.append(request.purpose + " " + request.origin + " " + request.recipient)
            switch (request.origin, request.purpose) {
            case ("https://jobs.ubs.example", "confirm"): return BuddyAccountMailFound(messageID: "m-jobs", link: "https://jobs.ubs.example/confirm?token=c0nf1rm", code: nil)
            case ("https://captcha.example", "code"): return BuddyAccountMailFound(messageID: "m-captcha", link: nil, code: "731904")
            case ("https://reset.example", "reset"): return BuddyAccountMailFound(messageID: "m-reset-\(mailAsked.count)", link: "https://reset.example/reset?token=r3set", code: nil)
            default: return nil
            }
        }
        BuddyWorkerHost.accountMailWait = 1.5; BuddyWorkerHost.accountMailEvery = 0.1
        let saved = Saved()
        let host = BuddyWorkerHost(support: support, executable: URL(fileURLWithPath: arguments[1]),
                                   makeBrowser: { BuddyWorkerProcess(resource: URL(fileURLWithPath: arguments[2]), runtime: URL(fileURLWithPath: arguments[3])) },
                                   keyReader: { _ in nil }, credentials: saved, accountMail: mailbox)
        host.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer { host.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)) }

        func worker(_ payload: [String: Any]) async throws -> [String: Any] { try await BuddyWorkerClient.call(support: support, payload: payload.merging(["workspace": workspace]) { old, _ in old }) }
        func page(_ payload: [String: Any]) async throws -> [String: Any] { try await BuddySignInBox.handle(payload, workspace: workspace, support: support, store: saved) }
        func website(_ calls: [[Any]], resume: [[Any]] = [], request: String) async throws -> String {
            let brief = "Apply for the analyst role. CALLS:" + json(calls) + (resume.isEmpty ? "" : " RESUME_CALLS:" + json(resume))
            let reply = try await worker(["operation": "computer", "agentId": jobApply, "actorId": jobApply, "requestId": request, "authorizedText": "Apply with \(email) please", "arguments": ["action": "start", "title": "Apply at the site", "goal": brief]])
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
        func commands(_ session: String, _ name: String) -> [[String: Any]] { browser(session).filter { $0["command"] as? String == name } }
        func results(_ tool: String) -> [String] { lines(serverLog).filter { $0["kind"] as? String == "result" }.compactMap { $0["value"] as? [String: Any] }.filter { $0["tool"] as? String == tool }.map { $0["text"] as? String ?? "" } }
        func settled(_ job: [String: Any]) -> Bool { ["completed", "failed", "waiting_user", "cancelled", "interrupted"].contains(job["status"] as? String ?? "") }
        func accounts(_ job: [String: Any]) -> [[String: Any]] { (job["reviews"] as? [[String: Any]] ?? []).filter { $0["kind"] as? String == "account" } }
        func waitingCard(_ id: String) async throws -> [String: Any] {
            _ = try await poll(id, "the task waits for the person's answer") { $0["status"] as? String == "waiting_review" && accounts($0).contains { $0["status"] as? String == "pending" } }
            for _ in 0..<100 { if let card = try await requests(id).first(where: { $0["kind"] as? String == "account" && $0["working"] == nil && $0["done"] == nil }) { return card }; try await Task.sleep(nanoseconds: 50_000_000) }
            throw Failed(message: "no account card in the chat")
        }
        func refused(_ work: () async throws -> Any) async -> String { do { _ = try await work(); return "" } catch { return error.localizedDescription } }

        // MARK: the ask, per site, answered only by the person's click

        var first = ""
        await section("an agent that needs an account asks the person in the chat, naming the site, the email, why and what Buddy will do; nothing is sent first") {
            first = try await website([["buddy_browser", ["operation": "open", "url": "https://jobs.ubs.example/join"]], ["buddy_browser_signup", ["reason": "To apply for the analyst role you asked about."]]], request: "jobs")
            let card = try await waitingCard(first)
            try require(card["purpose"] as? String == "signup" && card["origin"] as? String == "https://jobs.ubs.example" && card["account"] as? String == email && card["agentId"] as? String == jobApply,
                        "the card: site, the task's email, the agent: \(card)")
            try require(card["reason"] as? String == "To apply for the analyst role you asked about.", "with the agent's one line of why: \(card)")
            try require(card["what"] as? String == "Buddy makes a strong password and keeps it in your Keychain; it agrees to the site’s standard terms; it confirms the email in your Gmail.", "and what Buddy will do: \(card)")
            try require(BuddyWebsiteAccounts.ask(agent: "JobApply", site: "jobs.ubs.example", email: email, purpose: "signup") == "JobApply wants to create an account on jobs.ubs.example with matteo.craviotto@gmail.com — is that fine?", "the question in the person's words")
            let needs = try await decisions(first)
            try require(needs.count == 1 && needs[0]["title"] as? String == "Create an account on jobs.ubs.example?" && needs[0]["kind"] as? String == "signin" && needs[0]["audience"] as? String == "user", "one Needs item that opens the chat: \(needs)")
            try require(commands(first, "signup").isEmpty, "nothing was sent before the person answers: \(browser(first))")
        }
        await section("only the person's click answers it: an agent's request, the general review path and an unknown request are refused, and the card still waits") {
            let card = try await requests(first).first { $0["kind"] as? String == "account" } ?? [:]
            let review = card["reviewId"] as? String ?? ""
            let agent = await refused { try await worker(["operation": "signin", "actorId": jobApply, "arguments": ["action": "account", "taskId": first, "reviewId": review, "allow": true]]) }
            try require(!agent.isEmpty, "an agent's yes is refused")
            let general = await refused { try await worker(["operation": "review", "taskId": first, "id": review, "accept": true]) }
            try require(general.contains("Only the user"), "the general review path can't answer it: \(general)")
            let unknown = await refused { try await page(["action": "account", "taskId": first, "reviewId": "not-a-request", "allow": true]) }
            try require(!unknown.isEmpty, "an unknown request is refused")
            try require(BuddySignInBox.workerRefuses(["operation": "signin", "arguments": ["action": "account", "allow": true]]), "the page's general worker bridge never carries it; only the sign-in bridge does")
            let still = try await detail(first)
            try require(still["status"] as? String == "waiting_review" && accounts(still).first?["status"] as? String == "pending" && commands(first, "signup").isEmpty, "the card still waits and nothing was sent")
        }
        await section("on Create account Buddy fills the sign-up itself with the task's email and a password it made, keeps it in the Keychain, confirms the email from Gmail, and the card says so") {
            let card = try await requests(first).first { $0["kind"] as? String == "account" } ?? [:]
            let answer = try await page(["action": "account", "taskId": first, "reviewId": card["reviewId"] ?? "", "allow": true])
            try require(answer["answered"] as? Bool == true, "the click is taken: \(answer)")
            let done = try await poll(first, "the task finishes") { settled($0) }
            try require(done["status"] as? String == "completed", "completed: \(done["status"] ?? "") \(done["progress"] ?? "")")
            let password = saved.sitePassword(workspace: workspace, origin: "https://jobs.ubs.example", username: email) ?? ""
            try require(password.count >= 16, "a strong password is in the Keychain for that site and email: \(password.count) characters")
            let sent = commands(first, "signup")
            try require(sent.count == 1 && sent[0]["email"] as? String == email && sent[0]["passwordSHA256"] as? String == sha(password), "that very password went into the site's form, once, with the task's email: \(sent)")
            try require(commands(first, "openLink").first?["url"] as? String == "https://jobs.ubs.example/confirm?token=c0nf1rm", "the confirmation link from Gmail opened in the same page: \(commands(first, "openLink"))")
            let told = results("buddy_browser_signup").last ?? ""
            try require(told.contains("\"created\":true") && told.contains("\"confirmed\":true") && !told.contains(password), "the agent hears it was created, never the password: \(told.prefix(600))")
            let receipt = try await requests(first).first { $0["kind"] as? String == "account" } ?? [:]
            try require(receipt["done"] as? Bool == true && receipt["receipt"] as? String == "Created an account on jobs.ubs.example as matteo.craviotto@gmail.com — password saved in your Keychain." && receipt["created"] as? Bool == true,
                        "the receipt on the card: \(receipt)")
            try require((receipt["details"] as? String ?? "").contains("Chrome’s Password Manager can’t be filled in by automation") && (receipt["details"] as? String ?? "").contains("Saved sign-ins"), "it says where the password is, and why not Chrome: \(receipt)")
            let listed = try await page(["action": "sites"])
            try require((listed["sites"] as? [[String: Any]] ?? []).contains { $0["origin"] as? String == "https://jobs.ubs.example" && $0["username"] as? String == email } && !json(listed).contains(password), "it is in Saved sign-ins, without the password: \(listed)")
            let reviewed = accounts(done).first ?? [:]
            try require(reviewed["answeredBy"] as? String == "user" && reviewed["authAction"] as? String == "create", "the record says the person answered: \(reviewed)")
        }
        await section("every new site asks again; Don’t creates nothing and the agent is told plainly") {
            let id = try await website([["buddy_browser", ["operation": "open", "url": "https://second.example/join"]], ["buddy_browser_signup", ["reason": "The second application."]]], request: "second")
            let card = try await waitingCard(id)
            try require(card["origin"] as? String == "https://second.example", "a new card for the new site, although the person said yes to another: \(card)")
            _ = try await page(["action": "account", "taskId": id, "reviewId": card["reviewId"] ?? "", "allow": false])
            let done = try await poll(id, "the task goes on after Don't") { settled($0) }
            try require(done["status"] as? String == "completed" && commands(id, "signup").isEmpty && saved.sitePassword(workspace: workspace, origin: "https://second.example", username: email) == nil, "nothing created, nothing kept")
            let told = results("buddy_browser_signup").last ?? ""
            try require(told.contains("declined") && told.contains("said no"), "the agent is told the person said no: \(told)")
            try require(accounts(done).first?["status"] as? String == "cancelled", "the card's record is declined")
        }

        // MARK: money

        await section("a sign-up that starts a trial that becomes paid is never offered: the money card with Open the page and Skip, nothing sent; Skip goes on without it") {
            let id = try await website([["buddy_browser", ["operation": "open", "url": "https://trial.example/join"]], ["buddy_browser_signup", ["reason": "A tool the task uses."]]], request: "trial")
            let waiting = try await poll(id, "the task waits for the person") { $0["status"] as? String == "waiting_user" }
            let point = waiting["checkpoint"] as? [String: Any] ?? [:]
            try require(point["need"] as? String == "payment" && point["money"] as? String == "trial" && (point["instruction"] as? String ?? "").hasPrefix("This sign-up on trial.example starts a free trial that becomes paid. Buddy stopped."), "the money step: \(point)")
            try require(accounts(waiting).isEmpty && commands(id, "signup").isEmpty, "no create card, nothing sent")
            let asked = try await requests(id)
            try require(asked.count == 1 && asked[0]["kind"] as? String == "step" && asked[0]["need"] as? String == "payment" && asked[0]["money"] as? String == "trial", "the chat card: \(asked)")
            let needs = try await decisions(id)
            try require(needs.first?["title"] as? String == "This sign-up on trial.example starts a free trial that becomes paid", "the Needs item says it: \(needs)")
            let skipped = try await page(["action": "skip", "taskId": id])
            try require(skipped["skipped"] as? Bool == true, "Skip: \(skipped)")
            _ = try await poll(id, "the task goes on") { $0["status"] as? String == "completed" }
            let resumed = lines(serverLog).filter { $0["kind"] as? String == "turn" }.compactMap { ($0["value"] as? [String: Any])?["text"] as? String }.last ?? ""
            try require(resumed.contains("chose Skip") && resumed.contains("trial.example"), "the agent is told the person skipped it: \(resumed.suffix(400))")
        }
        await section("a form whose next step asks for a card stops there after the person's yes: the card says Buddy stopped, the money step opens the page for the person") {
            let id = try await website([["buddy_browser", ["operation": "open", "url": "https://payafter.example/join"]], ["buddy_browser_signup", ["reason": "Needed for the task."]]], request: "payafter")
            let card = try await waitingCard(id)
            _ = try await page(["action": "account", "taskId": id, "reviewId": card["reviewId"] ?? "", "allow": true])
            let waiting = try await poll(id, "the task waits for the person") { $0["status"] as? String == "waiting_user" }
            let point = waiting["checkpoint"] as? [String: Any] ?? [:]
            try require(point["need"] as? String == "payment" && point["money"] as? String == "payment", "the money step: \(point)")
            try require(saved.sitePassword(workspace: workspace, origin: "https://payafter.example", username: email) == nil, "nothing kept: no account was created")
            let receipt = try await requests(id).first { $0["kind"] as? String == "account" } ?? [:]
            try require(receipt["receipt"] as? String == "Buddy stopped: This sign-up on payafter.example asks for payment details. Nothing was sent.", "the create card says why it stopped: \(receipt)")
            _ = try await worker(["operation": "browser", "taskId": id, "url": point["url"] ?? ""])
            try require(commands(id, "manual").last?["page"] as? String == "https://payafter.example/billing", "Open the page opens that page for the person: \(commands(id, "manual"))")
            let done = try await page(["action": "done", "taskId": id])
            try require(done["done"] as? Bool == true, "Done after doing it themselves: \(done)")
            _ = try await poll(id, "the task goes on") { settled($0) }
            let resumed = lines(serverLog).filter { $0["kind"] as? String == "turn" }.compactMap { ($0["value"] as? [String: Any])?["text"] as? String }.last ?? ""
            try require(resumed.contains("handled the payment step") && resumed.contains("never pays"), "the agent is told the person did it: \(resumed.suffix(400))")
        }

        // MARK: the person's steps on the way

        await section("a CAPTCHA on the sign-up is the person's step (Open the page, Done); then Buddy finishes the same account without asking again, with the code from Gmail") {
            let id = try await website([["buddy_browser", ["operation": "open", "url": "https://captcha.example/join"]], ["buddy_browser_signup", ["reason": "Needed for the task."]]],
                                       resume: [["buddy_browser", ["operation": "open", "url": "https://captcha.example/join"]], ["buddy_browser_signup", ["reason": "Needed for the task."]]], request: "captcha")
            let card = try await waitingCard(id)
            _ = try await page(["action": "account", "taskId": id, "reviewId": card["reviewId"] ?? "", "allow": true])
            let waiting = try await poll(id, "the CAPTCHA step") { $0["status"] as? String == "waiting_user" }
            try require((waiting["checkpoint"] as? [String: Any])?["need"] as? String == "captcha", "the CAPTCHA step: \(waiting["checkpoint"] ?? "-")")
            _ = try await worker(["operation": "browser", "taskId": id])
            let done = try await page(["action": "done", "taskId": id])
            try require(done["done"] as? Bool == true && commands(id, "recheck").isEmpty, "Done goes on (a sign-up form is not a sign-in to look at again): \(done)")
            let finished = try await poll(id, "the sign-up is finished") { $0["status"] as? String == "completed" }
            let cards = accounts(finished)
            try require(cards.count == 2 && cards.filter { $0["answerReason"] as? String == "You said yes earlier in this task" }.count == 1, "one question for the site; the second card only carries on: \(cards.map { $0["status"] ?? "" })")
            try require(commands(id, "fillSecret").first?["valueSHA256"] as? String == sha("731904"), "the code from Gmail went into the site's code field")
            try require(saved.sitePassword(workspace: workspace, origin: "https://captcha.example", username: email) != nil, "and the password is kept")
        }
        await section("when the confirmation email doesn't arrive, a Done card asks the person to confirm it from their inbox; the account is still created and kept") {
            let id = try await website([["buddy_browser", ["operation": "open", "url": "https://nomail.example/join"]], ["buddy_browser_signup", ["reason": "Needed for the task."]]], request: "nomail")
            let card = try await waitingCard(id)
            _ = try await page(["action": "account", "taskId": id, "reviewId": card["reviewId"] ?? "", "allow": true])
            let waiting = try await poll(id, "the email step", seconds: 20) { $0["status"] as? String == "waiting_user" }
            let point = waiting["checkpoint"] as? [String: Any] ?? [:]
            try require(point["need"] as? String == "verification" && point["instruction"] as? String == "Confirm the email from nomail.example in your inbox, then press Done.", "the Done card: \(point)")
            try require(saved.sitePassword(workspace: workspace, origin: "https://nomail.example", username: email) != nil, "the account's password is kept")
            try require(mailAsked.filter { $0.hasPrefix("confirm https://nomail.example") }.count >= 2, "Buddy looked for the email more than once before asking: \(mailAsked)")
            let receipt = try await requests(id).first { $0["kind"] as? String == "account" } ?? [:]
            try require(receipt["receipt"] as? String == "Created an account on nomail.example as matteo.craviotto@gmail.com — password saved in your Keychain.", "the receipt: \(receipt)")
            let asked = try await requests(id).first { $0["kind"] as? String == "step" } ?? [:]
            try require(asked["need"] as? String == "verification" && asked["instruction"] as? String == "Confirm the email from nomail.example in your inbox, then press Done.", "the chat's Done card: \(asked)")
            _ = try await page(["action": "done", "taskId": id])
            _ = try await poll(id, "the task goes on") { settled($0) }
        }
        await section("a code the site texts to the phone is asked for in the chat's private field, and goes only into the site") {
            let id = try await website([["buddy_browser", ["operation": "open", "url": "https://sms.example/join"]], ["buddy_browser_signup", ["reason": "Needed for the task."]]], request: "sms")
            let card = try await waitingCard(id)
            _ = try await page(["action": "account", "taskId": id, "reviewId": card["reviewId"] ?? "", "allow": true])
            var field: [String: Any] = [:]
            for _ in 0..<200 { if let f = try await requests(id).first(where: { $0["kind"] as? String == "signin" && $0["field"] as? String == "code" }) { field = f; break }; try await Task.sleep(nanoseconds: 50_000_000) }
            try require(field["note"] as? String == "Enter the code sms.example texted to your phone.", "the private field says where the code came from: \(field)")
            let sent = try await page(["action": "secret", "taskId": id, "reviewId": field["reviewId"] ?? "", "value": "480213"])
            try require(sent["signedIn"] as? Bool == true, "the code was taken: \(sent)")
            _ = try await poll(id, "the task finishes") { $0["status"] as? String == "completed" }
            try require(commands(id, "fillSecret").last?["valueSHA256"] as? String == sha("480213"), "it went into the site")
        }

        // MARK: a forgotten password

        await section("a remembered password that no longer works: Don’t falls back to the private field, which asks for the email and the password") {
            try saved.saveSite(workspace: workspace, origin: "https://reset.example", username: email, password: stale)
            let id = try await website([["buddy_browser", ["operation": "open", "url": "https://reset.example/login"]], ["buddy_browser_signin", ["mode": "signin", "reason": "Check my application status."]]], request: "reset-no")
            let card = try await waitingCard(id)
            try require(card["purpose"] as? String == "reset" && card["origin"] as? String == "https://reset.example", "the reset card: \(card)")
            try require(BuddyWebsiteAccounts.ask(agent: "JobApply", site: "reset.example", email: email, purpose: "reset") == "JobApply wants to reset your password on reset.example through your email — is that fine?", "in the person's words")
            _ = try await page(["action": "account", "taskId": id, "reviewId": card["reviewId"] ?? "", "allow": false])
            var field: [String: Any] = [:]
            for _ in 0..<200 { if let f = try await requests(id).first(where: { $0["kind"] as? String == "signin" && $0["field"] as? String == "login" }) { field = f; break }; try await Task.sleep(nanoseconds: 50_000_000) }
            try require(field["account"] as? String == email && (field["note"] as? String ?? "").contains("remembered password"), "both fields, with the task's email: \(field)")
            try require(commands(id, "resetStart").isEmpty, "no reset was asked for")
            let sent = try await page(["action": "secret", "taskId": id, "reviewId": field["reviewId"] ?? "", "value": right, "username": email, "remember": true])
            try require(sent["signedIn"] as? Bool == true && sent["remembered"] as? Bool == true, "signed in, and remembered: \(sent)")
            try require(commands(id, "fillSecret").last?["username"] as? String == email, "the email went with it")
            try require(saved.sitePassword(workspace: workspace, origin: "https://reset.example", username: email) == right, "the typed password replaced the stale one")
            _ = try await poll(id, "the task finishes") { settled($0) }
        }
        await section("on Reset password Buddy asks the site for the email, opens its link, sets a new password it made, keeps it and signs in with it") {
            try saved.saveSite(workspace: workspace, origin: "https://reset.example", username: email, password: stale)
            let id = try await website([["buddy_browser", ["operation": "open", "url": "https://reset.example/login"]], ["buddy_browser_signin", ["mode": "signin", "reason": "Check my application status."]]], request: "reset-yes")
            let card = try await waitingCard(id)
            _ = try await page(["action": "account", "taskId": id, "reviewId": card["reviewId"] ?? "", "allow": true])
            let done = try await poll(id, "the task finishes") { settled($0) }
            try require(done["status"] as? String == "completed", "completed: \(done["progress"] ?? "")")
            let password = saved.sitePassword(workspace: workspace, origin: "https://reset.example", username: email) ?? ""
            try require(password != stale && password != right && password.count >= 16, "a new password Buddy made is kept")
            try require(commands(id, "resetStart").first?["email"] as? String == email && commands(id, "openLink").first?["url"] as? String == "https://reset.example/reset?token=r3set", "the reset email was asked for and its link opened")
            try require(commands(id, "resetFinish").first?["passwordSHA256"] as? String == sha(password) && commands(id, "fillSecret").last?["valueSHA256"] as? String == sha(password), "that password was set and then used to sign in")
            let told = results("buddy_browser_signin").last ?? ""
            try require(told.contains("\"signedIn\":true") && told.contains("reset") && !told.contains(password), "the agent hears it is signed in: \(told.prefix(400))")
            let receipt = try await requests(id).first { $0["kind"] as? String == "account" } ?? [:]
            try require(receipt["receipt"] as? String == "Reset your password on reset.example for matteo.craviotto@gmail.com — the new one is saved in your Keychain.", "the reset card's receipt: \(receipt)")
        }
        await section("the agent is told how to ask for an account, and no password Buddy made is in any file or log") {
            let start = lines(serverLog).first { $0["kind"] as? String == "start" }?["value"] as? [String: Any] ?? [:]
            try require((start["tools"] as? [String] ?? []).contains("buddy_browser_signup"), "the tool is offered: \(start["tools"] ?? "-")")
            let brief = start["instructions"] as? String ?? ""
            try require(brief.contains("When a site needs an account you don't have, call buddy_browser_signup") && brief.contains("Never sign up, start trials, or enter payment details yourself"), "the guidance: \(brief.suffix(2000))")
            try require(brief.contains("Work quietly. " + BuddyVoice.plain + " " + BuddyVoice.result) && !brief.contains("Finish with just the useful result"), "a background task writes its result as a plain message to the person, then the details for the team")
            let made = saved.sitePasswords.values.filter { $0 != right && $0 != stale }
            try require(made.count >= 4, "Buddy made passwords: \(made.count)")
            var found: [String] = []
            for root in [support, logs] {
                guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
                for case let url as URL in walk {
                    guard let data = try? Data(contentsOf: url) else { continue }
                    if made.contains(where: { data.range(of: Data($0.utf8)) != nil }) { found.append(url.path.replacingOccurrences(of: base.path, with: "")) }
                }
            }
            try require(found.isEmpty, "never in a file: \(found)")
        }

        if !failures.isEmpty { fputs("FAILED: \(failures.count) website account check(s) failed\n", stderr); exit(1) }
    }
}
