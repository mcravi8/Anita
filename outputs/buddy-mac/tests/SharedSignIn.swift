// run-tests: BuddyWorkerCore.swift BuddyOperationsDB.swift BuddyWorkerProcess.swift BuddyWorkerHost.swift BuddyCodexCoding.swift BuddyPlan.swift BuddySupervisor.swift BuddyMigrations.swift BuddyWorkerClient.swift BuddyAgentMemory.swift BuddyTeamMonitorStore.swift BuddyTeamMonitor.swift BuddyAISettings.swift ConversationService.swift BuddyInboxReview.swift BuddyMailVerification.swift BuddyComputer.swift BuddyTransport.swift BuddyToolInput.swift BuddyConnections.swift BuddyTeam.swift BuddyProjectFiles.swift BuddyDocuments.swift BuddyAgentProposals.swift BuddyCredentials.swift BuddyCommandReview.swift -- src:tests/shared-signin-server.py src:tests/shared-signin-browser.py which:python3
import AppKit
import CryptoKit
import Darwin

/// One Chrome for every agent, and the person's sign-in typed in chat, end to end through the real worker (its socket, queue, decisions and
/// reviews) with a stand-in ChatGPT (tests/shared-signin-server.py) and a stand-in shared browser (tests/shared-signin-browser.py) that logs
/// every command it gets, a typed value only as its hash. The typed password is a fake one; the test then looks for it in every file the
/// worker wrote and in every reply. Each section reports on its own.
@main struct SharedSignInChecks {
    struct Failed: Error { let message: String }
    static func require(_ value: Bool, _ message: @autoclosure () -> String) throws { if !value { throw Failed(message: message()) } }
    @MainActor static var failures: [String] = []
    @MainActor static func section(_ name: String, _ body: () async throws -> Void) async {
        do { try await body(); print("PASS: " + name) }
        catch let failed as Failed { failures.append(name); fputs("FAILED: \(name): \(failed.message)\n", stderr) }
        catch { failures.append(name); fputs("FAILED: \(name): \(error.localizedDescription)\n", stderr) }
    }
    static func sha(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    static func hostName() -> String { var name = [CChar](repeating: 0, count: 256); gethostname(&name, name.count); return String(cString: name) }

    @MainActor static func main() async throws {
        let arguments = CommandLine.arguments   // [1] the ChatGPT stand-in, [2] the shared browser stand-in, [3] python3
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("buddy-shared-signin-" + UUID().uuidString + ".noindex")
        let support = base.appendingPathComponent("Support", isDirectory: true), logs = base.appendingPathComponent("Fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true); try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let serverLog = logs.appendingPathComponent("server.jsonl"), browserLog = logs.appendingPathComponent("browser.jsonl")
        // A fake password, and a wrong one. Neither may appear in anything Buddy stores, logs, or hands to a model or the page.
        let secret = "Shop!pw-41Kx-not-real", wrong = "wrong-pw-88Qz"
        setenv("BUDDY_SHARED_SERVER_LOG", serverLog.path, 1); setenv("BUDDY_SHARED_BROWSER_LOG", browserLog.path, 1); setenv("BUDDY_SHARED_RIGHT_SHA256", sha(secret), 1)
        let workspace = UUID().uuidString, ada = UUID().uuidString, bo = UUID().uuidString, cy = UUID().uuidString
        try JSONSerialization.data(withJSONObject: ["conversationWorkspace": workspace, "agents": [
            ["id": ada, "name": "Ada", "role": "Shopper", "description": "Website tasks", "tools": ["web": true, "desktop": true]],
            // Bo has Mac apps off: internet access (Web research) alone gives an agent Buddy's Chrome.
            ["id": bo, "name": "Bo", "role": "Shopper", "description": "Website tasks", "tools": ["web": true, "desktop": false]],
            ["id": cy, "name": "Cy", "role": "Writer", "description": "No internet", "tools": ["web": false, "desktop": true]]]]).write(to: support.appendingPathComponent("workspace.json"))
        let host = BuddyWorkerHost(support: support, executable: URL(fileURLWithPath: arguments[1]),
                                   makeBrowser: { BuddyWorkerProcess(resource: URL(fileURLWithPath: arguments[2]), runtime: URL(fileURLWithPath: arguments[3])) })
        host.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer { host.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)) }

        func worker(_ payload: [String: Any]) async throws -> [String: Any] { try await BuddyWorkerClient.call(support: support, payload: payload.merging(["workspace": workspace]) { old, _ in old }) }
        func page(_ payload: [String: Any]) async throws -> [String: Any] { try await BuddySignInBox.handle(payload, workspace: workspace, support: support) }
        func create(_ goal: String, as agent: String, request: String) async throws -> String {
            let reply = try await worker(["operation": "create", "agentId": agent, "requestId": request, "title": "Read my last order", "goal": goal, "kind": "general", "provider": "chatgpt", "budgetUSD": 0])
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
        func commands(_ name: String) -> [[String: Any]] { lines(browserLog).filter { $0["command"] as? String == name } }
        func json(_ value: Any) -> String { (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "" }
        func pending(_ job: [String: Any]) -> [String: Any]? { (job["reviews"] as? [[String: Any]] ?? []).last { $0["status"] as? String == "pending" } }
        func refused(_ work: () async throws -> Any) async -> Bool { do { _ = try await work(); return false } catch { return true } }

        var typed = "", typedReview = ""
        await section("agents with internet access share one Chrome profile, and each task drives only its own session in it") {
            typed = try await create("TYPED_SIGNIN: read my last order at the fixture shop.", as: ada, request: "typed")
            let waiting = try await poll(typed, "the task asks how to sign in") { $0["status"] as? String == "waiting_review" && pending($0) != nil }
            typedReview = pending(waiting)?["id"] as? String ?? ""
            let argv = (commands("argv").first?["argv"] as? [String]) ?? []
            try require(argv.first?.hasSuffix("/Worker/Browsers/Shared") == true, "the browser opens the one shared profile: \(argv)")
            let used = lines(browserLog).filter { $0["command"] as? String != "argv" }
            let paged = used.filter { !["sessions", "close"].contains($0["command"] as? String ?? "") }
            try require(!paged.isEmpty && paged.allSatisfy { $0["session"] as? String == typed && $0["scope"] as? String == "" }, "every page command names this task's session: \(used)")
            try require(!FileManager.default.fileExists(atPath: support.appendingPathComponent("Worker/Browsers/\(ada)").path), "no per-agent profile is made any more")
        }
        await section("the chat is told what to ask for: the site, the account and a password field, never a token") {
            let asked = try await requests(typed)
            try require(asked.count == 1, "one request for the task: \(asked)")
            let request = asked[0]
            try require(request["kind"] as? String == "signin" && request["agentId"] as? String == ada && request["origin"] as? String == "https://shop.example"
                        && request["account"] as? String == "ada@example.com" && request["field"] as? String == "password" && request["reviewId"] as? String == typedReview,
                        "the request: \(request)")
            let said = json(try await status())
            try require(!said.contains("secret-") && !said.contains("auth-"), "no browser token reaches the page")
            let cards = try await decisions(typed)
            try require(cards.count == 1 && cards[0]["kind"] as? String == "signin" && cards[0]["audience"] as? String == "user", "one Needs item for the person: \(cards)")
        }
        await section("only the person's page can send a typed password: an agent's request, an unknown or ended request reach no page") {
            try require(await refused { try await worker(["operation": "signin", "actorId": ada, "arguments": ["action": "secret", "taskId": typed, "reviewId": typedReview, "value": secret]]) }, "an agent cannot send one")
            try require(await refused { try await page(["action": "secret", "taskId": typed, "reviewId": "not-a-request", "value": secret]) }, "an unknown request is refused")
            try require(await refused { try await page(["action": "secret", "taskId": typed, "reviewId": typedReview, "value": "two\nlines"]) }, "a value on two lines is refused")
            try require(commands("fillSecret").isEmpty, "nothing reached the browser: \(commands("fillSecret"))")
            try require(BuddySignInBox.workerRefuses(["operation": "signin", "arguments": ["action": "secret", "value": secret]]) && BuddySignInBox.workerRefuses(["operation": "signin", "arguments": ["action": "provide"]])
                        && !BuddySignInBox.workerRefuses(["operation": "status"]), "the page's general worker bridge never carries a typed sign-in; only the sign-in bridge does")
        }
        await section("a wrong password keeps the chat request open with a fresh token; the right one signs in, and the agent learns only that") {
            let key = (try await requests(typed)).first?["key"] as? String ?? ""
            let first = try await page(["action": "secret", "taskId": typed, "reviewId": typedReview, "value": wrong])
            let next = first["reviewId"] as? String ?? ""
            try require(first["sent"] as? Bool == true && first["signedIn"] as? Bool == false && first["retry"] as? Bool == true && first["field"] as? String == "password" && !next.isEmpty && next != typedReview && !json(first).contains(wrong),
                        "the site said no, and the page may send again to the next try: \(first)")
            let still = try await detail(typed), asked = try await requests(typed)
            try require(still["status"] as? String == "waiting_review" && pending(still)?["id"] as? String == next, "the task still waits, on the next try")
            try require(asked.count == 1 && asked[0]["key"] as? String == key && asked[0]["reviewId"] as? String == next && (asked[0]["note"] as? String ?? "").contains("didn’t work"),
                        "it is the same request in the chat, saying it did not work: \(asked)")
            try require(await refused { try await page(["action": "secret", "taskId": typed, "reviewId": typedReview, "value": secret]) }, "the used try cannot be sent to again")
            let second = try await page(["action": "secret", "taskId": typed, "reviewId": next, "value": secret])
            try require(second["sent"] as? Bool == true && second["signedIn"] as? Bool == true && !json(second).contains(secret), "signed in: \(second)")
            let fills = commands("fillSecret")
            try require(fills.count == 2 && fills.allSatisfy { $0["session"] as? String == typed } && fills[0]["valueSHA256"] as? String == sha(wrong) && fills[1]["valueSHA256"] as? String == sha(secret),
                        "each value went to this task's page, once: \(fills)")
            try require(fills[0]["token"] as? String != fills[1]["token"] as? String, "the second try used the fresh token the site's answer gave: \(fills)")
            let done = try await poll(typed, "the task finishes after signing in") { $0["status"] as? String == "completed" }
            let tries = (done["reviews"] as? [[String: Any]] ?? []).filter { $0["kind"] as? String == "authentication" }
            try require(tries.count == 2 && tries.allSatisfy { $0["status"] as? String == "completed" && $0["authAction"] as? String == "secret" && $0["answeredBy"] as? String == "user" }
                        && (tries[1]["receipt"] as? [String: Any])?["signedIn"] as? Bool == true && (tries[0]["receipt"] as? [String: Any])?["signedIn"] as? Bool == false,
                        "each try is on the record, who answered it and how it went, without what was typed: \(tries)")
            let told = lines(serverLog).filter { $0["kind"] as? String == "result" }.compactMap { $0["value"] as? [String: Any] }.last ?? [:]
            let text = told["text"] as? String ?? ""
            try require(told["success"] as? Bool == true && text.contains("\"signedIn\":true") && !text.contains(secret) && !text.contains(wrong), "the agent is told it is signed in, nothing more: \(text.prefix(400))")
            let leftRequests = try await requests(typed), leftCards = try await decisions(typed)
            try require(leftRequests.isEmpty && leftCards.isEmpty, "the chat request and the Needs item are gone: \(leftRequests) \(leftCards)")
        }
        var stepTask = ""
        await section("Open Chrome, then Done (Bo, with Mac apps off, uses the browser): Done closes Chrome, looks again, says so while it is not finished, and continues once it is") {
            stepTask = try await create("CHROME_STEP: read my last order at the fixture shop.", as: bo, request: "step")
            let waiting = try await poll(stepTask, "the task asks how to sign in") { $0["status"] as? String == "waiting_review" && pending($0) != nil }
            _ = try await worker(["operation": "review", "taskId": stepTask, "id": pending(waiting)?["id"] ?? "", "accept": true, "authAction": "private"])
            _ = try await poll(stepTask, "the task waits for the person in Chrome") { $0["status"] as? String == "waiting_user" }
            let opened = commands("manual").last ?? [:]
            try require(opened["session"] as? String == stepTask, "Chrome opens at this task's page: \(opened)")
            let state = try await status(), open = state["privateBrowser"] as? [String: Any] ?? [:]
            try require(open["taskId"] as? String == stepTask && open["shared"] as? Bool == true, "the shared Chrome window is open for this task: \(open)")
            let asked = try await requests(stepTask)
            try require(asked.count == 1 && asked[0]["kind"] as? String == "step" && asked[0]["chromeOpen"] as? Bool == true && asked[0]["origin"] as? String == "https://shop.example"
                        && (asked[0]["instruction"] as? String ?? "").contains("press Done"), "a Done request in the chat: \(asked)")
            try require((try await decisions(stepTask)).contains { $0["kind"] as? String == "step" && $0["audience"] as? String == "user" }, "and a Needs item")
            // Work that does not need the browser goes ahead while the person has Chrome open.
            let plain = try await create("PLAIN: summarise my notes.", as: ada, request: "plain")
            _ = try await poll(plain, "other work runs while Chrome is open for the person") { $0["status"] as? String == "completed" }
            let first = try await page(["action": "done", "taskId": stepTask])
            try require(first["done"] as? Bool == false && first["reopened"] as? Bool == true && (first["note"] as? String ?? "").contains("isn’t finished"), "the first Done finds it unfinished and says so: \(first)")
            let rechecked = commands("recheck")
            try require(rechecked.count == 1 && rechecked[0]["session"] as? String == stepTask && rechecked[0]["reload"] as? Bool == true && commands("finishManual").count == 1 && commands("manual").count == 2,
                        "Chrome closed, the page was looked at again in this task's session, and Chrome opened again: \(lines(browserLog).suffix(6))")
            let stillWaiting = try await detail(stepTask), stillAsked = try await requests(stepTask)
            try require(stillWaiting["status"] as? String == "waiting_user" && stillAsked.first?["kind"] as? String == "step", "the Done button stays: \(stillAsked)")
            let second = try await page(["action": "done", "taskId": stepTask])
            try require(second["done"] as? Bool == true, "the second Done finds it signed in: \(second)")
            _ = try await poll(stepTask, "the task continues after Done") { $0["status"] as? String == "completed" }
            let resumed = lines(serverLog).filter { $0["kind"] as? String == "turn" }.compactMap { ($0["value"] as? [String: Any])?["text"] as? String }.last ?? ""
            try require(resumed.contains("finished the sign-in step"), "the agent is told the person finished, in Buddy's words: \(resumed.suffix(400))")
            let closed = try await status(), gone = try await requests(stepTask)
            try require(closed["privateBrowser"] is NSNull && gone.isEmpty, "Chrome is closed and the request is gone: \(closed["privateBrowser"] ?? "-") \(gone)")
        }
        await section("Set up once: one Chrome window for everyone, opened with no agent, closed with Done") {
            let opened = try await worker(["operation": "openGoogle"])
            try require(opened["opened"] as? Bool == true, "opened: \(opened)")
            let call = commands("manualGoogle").last ?? [:]
            try require(call["session"] == nil || call["session"] is NSNull, "no agent's session is involved: \(call)")
            let open = (try await status())["privateBrowser"] as? [String: Any] ?? [:]
            try require(open["shared"] as? Bool == true && open["taskId"] is NSNull, "the shared window is open for setup: \(open)")
            let agents = (try await status())["browserAgents"] as? [String] ?? []
            try require(Set(agents) == [ada, bo], "every agent with internet access uses it (Bo too, with Mac apps off), the one without does not: \(agents)")
            _ = try await worker(["operation": "finishSignIn"])
            try require((try await status())["privateBrowser"] is NSNull, "Done closes it")
        }
        await section("an older per-agent Chrome window that is still open is never closed by Buddy: the person is asked, and its profile is left as it was") {
            let old = support.appendingPathComponent("Worker/Browsers/\(cy)", isDirectory: true)
            try FileManager.default.createDirectory(at: old.appendingPathComponent("Default"), withIntermediateDirectories: true)
            try Data("old-cookie-database-fixture".utf8).write(to: old.appendingPathComponent("Default/Cookies"))
            let sleeper = Process(); sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep"); sleeper.arguments = ["60"]; try sleeper.run()
            defer { if sleeper.isRunning { sleeper.terminate() } }
            try FileManager.default.createSymbolicLink(atPath: old.appendingPathComponent("SingletonLock").path, withDestinationPath: "\(hostName())-\(sleeper.processIdentifier)")
            func listing() -> [String] { (FileManager.default.subpaths(atPath: old.path) ?? []).sorted().map { path in
                let url = old.appendingPathComponent(path); let link = (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) ?? ""
                return path + "|" + link + "|" + ((try? Data(contentsOf: url)).map { sha(String(decoding: $0, as: UTF8.self)) } ?? "") } }
            let before = listing()
            var message = ""
            do { _ = try await worker(["operation": "openGoogle"]) } catch { message = error.localizedDescription }
            try require(message.contains("Cy") && message.contains("close"), "the person is asked to close the older window: \(message)")
            try require(sleeper.isRunning, "Buddy never closed it")
            try require(((try await status())["legacyChrome"] as? [String]) == [cy], "status says which older window is open")
            sleeper.terminate(); sleeper.waitUntilExit()
            _ = try await worker(["operation": "openGoogle"]); _ = try await worker(["operation": "finishSignIn"])
            try require(listing() == before, "the older profile folder is untouched, its lock included: \(before) → \(listing())")
        }
        await section("the typed passwords appear nowhere: no file under the support folder or the fixture logs, no status or task reply") {
            var found: [String] = [], checked = 0
            let needles = [secret, wrong].flatMap { [$0, $0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0] }.map { Data($0.utf8) }
            for root in [support, logs] {
                guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
                for case let url as URL in walk {
                    guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true, let data = try? Data(contentsOf: url) else { continue }
                    checked += 1
                    if needles.contains(where: { data.range(of: $0) != nil }) { found.append(url.path.replacingOccurrences(of: base.path, with: "")) }
                }
            }
            try require(checked > 10 && found.isEmpty, "checked \(checked) files; found in: \(found)")
            let replies = json(try await status()) + json(try await detail(typed)) + json(try await detail(stepTask))
            try require(!replies.contains(secret) && !replies.contains(wrong), "nor in what the page reads")
        }

        // MARK: the older private sign-in, across an update

        await section("a private sign-in left open by the previous version is finished by the person, never by Buddy closing that Chrome") {
            let again = base.appendingPathComponent("Again", isDirectory: true), agent = UUID().uuidString, space = UUID().uuidString
            let old = again.appendingPathComponent("Worker/Browsers/\(agent)", isDirectory: true)
            try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["conversationWorkspace": space, "agents": [["id": agent, "name": "Vera", "role": "Researcher", "description": "Fixture", "tools": [String: Bool]()]]]).write(to: again.appendingPathComponent("workspace.json"))
            try JSONSerialization.data(withJSONObject: ["agentId": agent, "taskId": NSNull()]).write(to: again.appendingPathComponent("Worker/PrivateSignIn.json"))
            let sleeper = Process(); sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep"); sleeper.arguments = ["60"]; try sleeper.run()
            defer { if sleeper.isRunning { sleeper.terminate() } }
            try FileManager.default.createSymbolicLink(atPath: old.appendingPathComponent("SingletonLock").path, withDestinationPath: "\(hostName())-\(sleeper.processIdentifier)")
            let second = BuddyWorkerHost(support: again, executable: URL(fileURLWithPath: arguments[1]),
                                         makeBrowser: { BuddyWorkerProcess(resource: URL(fileURLWithPath: arguments[2]), runtime: URL(fileURLWithPath: arguments[3])) })
            second.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
            defer { second.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)) }
            func call(_ payload: [String: Any]) async throws -> [String: Any] { try await BuddyWorkerClient.call(support: again, payload: payload.merging(["workspace": space]) { old, _ in old }) }
            let open = (try await call(["operation": "status"]))["privateBrowser"] as? [String: Any] ?? [:]
            try require(open["legacy"] as? Bool == true && open["agentId"] as? String == agent, "the older window is shown as such: \(open)")
            var message = ""
            do { _ = try await call(["operation": "finishSignIn"]) } catch { message = error.localizedDescription }
            try require(message.contains("Vera") && message.contains("close"), "Done asks the person to close it: \(message)")
            try require(sleeper.isRunning, "Buddy did not close it")
            sleeper.terminate(); sleeper.waitUntilExit()
            let finished = try await call(["operation": "finishSignIn"])
            try require(finished["finished"] as? Bool == true && !FileManager.default.fileExists(atPath: again.appendingPathComponent("Worker/PrivateSignIn.json").path), "once closed, Done clears it: \(finished)")
            try require((try? FileManager.default.destinationOfSymbolicLink(atPath: old.appendingPathComponent("SingletonLock").path)) != nil, "the old profile's lock is left where Chrome put it")
        }

        if !failures.isEmpty { fputs("FAILED: \(failures.count) shared sign-in check(s) failed\n", stderr); exit(1) }
    }
}
