// run-tests: ConversationService.swift BuddyInboxReview.swift BuddyOperationsDB.swift BuddyMailVerification.swift BuddyComputer.swift BuddyTransport.swift BuddyConnections.swift BuddyToolInput.swift BuddyTeam.swift BuddyProjectFiles.swift BuddyDocuments.swift BuddyAgentProposals.swift -- src:tests/thread-archive-server.py
import Foundation

/// Buddy's ChatGPT work stays out of the person's own ChatGPT/Codex chat list. A background run's thread is ephemeral and never saved; a chat
/// or task thread, which Buddy continues later, is saved, archived as soon as its turn is over, and unarchived only to be continued. The
/// stand-in (tests/thread-archive-server.py) keeps threads as Codex does: an archived thread can't be resumed or forked until it is unarchived.
@main struct ThreadArchiveTests {
    @MainActor static func require(_ ok: Bool, _ label: String) { if !ok { fputs("FAILED: \(label)\n", stderr); exit(1) } }

    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("buddy-thread-archive-" + UUID().uuidString + ".noindex")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let server = URL(fileURLWithPath: CommandLine.arguments[1])
        var service = ConversationService(support: root, executable: server)
        var events: [[String: Any]] = []
        service.onEvent = { events.append($0) }
        func restart() { service.shutdown(); service = ConversationService(support: root, executable: server); events = []; service.onEvent = { events.append($0) } }
        func json(_ name: String) -> Any? { (try? Data(contentsOf: root.appendingPathComponent(name))).flatMap { try? JSONSerialization.jsonObject(with: $0) } }
        func write(_ value: Any, _ name: String) throws { try JSONSerialization.data(withJSONObject: value).write(to: root.appendingPathComponent(name)) }
        func home() -> [String: [String: Any]] { json("codex-home.json") as? [String: [String: Any]] ?? [:] }
        /// What the person's ChatGPT/Codex apps list: every saved thread that isn't archived.
        func listed() -> [String] { home().filter { $0.value["archived"] as? Bool == false }.map(\.key).sorted() }
        func record() -> [String] { json("codex-threads-to-archive.json") as? [String] ?? [] }
        func requests(_ thread: String) -> [String] {
            ((try? String(contentsOf: root.appendingPathComponent("codex-requests.jsonl"), encoding: .utf8)) ?? "").split(separator: "\n")
                .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                .filter { ($0["params"] as? [String: Any])?["threadId"] as? String == thread }.compactMap { $0["method"] as? String }
        }
        func settle(_ label: String, _ done: () -> Bool) async { for _ in 0..<250 where !done() { try? await Task.sleep(nanoseconds: 20_000_000) }; require(done(), label) }
        func start(_ text: String, key: String, background: Bool) throws -> String {
            let id = UUID().uuidString
            var options = BuddyTurnOptions(); options.toolsEnabled = false; options.internalRun = background; options.actorId = "chief"
            _ = try service.send(["runId": id, "key": key, "agent": ["name": "Chief", "role": "Chief of Staff", "description": "Coordinates the team."], "text": text], options: options)
            return id
        }
        func ended(_ id: String) -> [String: Any]? { events.last { $0["runId"] as? String == id && ["completed", "failed", "stopped"].contains($0["status"] as? String ?? "") } }
        /// One reply; returns the thread it ran in.
        func send(_ text: String, key: String = "workspace:chief", background: Bool = false) async throws -> String {
            let id = try start(text, key: key, background: background)
            await settle("the reply to \"\(text)\" ends") { ended(id) != nil }
            require(ended(id)?["status"] as? String == "completed", "the reply to \"\(text)\" succeeds: \(ended(id)?["error"] ?? "")")
            let answer = (try? JSONSerialization.jsonObject(with: Data((ended(id)?["text"] as? String ?? "").utf8))) as? [String: Any] ?? [:]
            return answer["thread"] as? String ?? ""
        }

        // 1. A chat reply runs in a saved thread (Buddy continues the chat in it), which leaves the person's list as soon as the reply is done.
        let chat = try await send("Hello")
        require(home()[chat]?["opened"] as? String == "start", "a chat reply runs in a saved thread: \(home())")
        await settle("once the reply is done the chat's thread is archived, so the person's ChatGPT/Codex list doesn't show it: \(listed())") { listed().isEmpty && record().isEmpty }

        // 2. The next reply in that chat unarchives the thread and continues it: the same thread, its history kept.
        let again = try await send("Still there?")
        require(again == chat && home()[chat]?["turns"] as? Int == 2, "the chat continues in the same thread, which Codex resumes only once it is unarchived: \(again) \(home())")
        let methods = requests(chat)
        require((methods.firstIndex(of: "thread/unarchive") ?? .max) < (methods.firstIndex(of: "thread/resume") ?? -1), "it was unarchived before it was resumed: \(methods)")
        await settle("and archived again once that reply is done: \(listed())") { listed().isEmpty && record().isEmpty }

        // 3. A background run (supervisor, check-in, memory) uses an ephemeral thread: never saved, so there is nothing to archive.
        let background = try await send("Supervise the team", background: true)
        require(!background.isEmpty && home()[background] == nil && requests(background).allSatisfy { !["thread/archive", "thread/unarchive"].contains($0) } && !record().contains(background),
                "a background run's thread is ephemeral and never saved: \(requests(background))")

        // 4. After a restart the chat still continues in its thread.
        restart()
        let afterRestart = try await send("Back again")
        require(afterRestart == chat, "after a restart the chat continues in its archived thread: \(afterRestart)")
        await settle("and it is archived again: \(listed())") { listed().isEmpty && record().isEmpty }

        // 5. Changed connections fork the chat into a new thread; the one it was copied from goes back to the archive, and the new one follows.
        let policy = (json("conversation-policies.json") as? [String: String])?["workspace:chief"] ?? ""
        service.shutdown()
        try write(["workspace:chief": "an-older-connection-policy"], "conversation-policies.json")
        restart()
        let forked = try await send("New connections")
        require(forked != chat && home()[forked]?["opened"] as? String == "fork" && home()[forked]?["from"] as? String == chat, "changed connections fork the chat into a new thread: \(home())")
        await settle("both the fork and the thread it copied are archived: \(listed())") { listed().isEmpty && record().isEmpty }

        // 6. A thread saved before Buddy archived its threads isn't archived: unarchiving it is refused, and it is continued as it is, then archived.
        // 7. A thread a quit or crash left open is on Buddy's record and is archived on the next connection.
        service.shutdown()
        var stored = home()
        stored["thread-from-before"] = ["archived": false, "opened": "start", "turns": 3]
        stored["left-open-by-a-crash"] = ["archived": false, "opened": "start", "turns": 1]
        try write(stored, "codex-home.json")
        var sessions = json("conversations.json") as? [String: String] ?? [:]; sessions["workspace:vera"] = "thread-from-before"; try write(sessions, "conversations.json")
        try write(["workspace:chief": policy, "workspace:vera": policy], "conversation-policies.json")
        try write(["left-open-by-a-crash"], "codex-threads-to-archive.json")
        restart()
        let older = try await send("Hi Vera", key: "workspace:vera")
        require(older == "thread-from-before" && home()["thread-from-before"]?["turns"] as? Int == 4, "a thread from before continues as it is: \(older)")
        await settle("the thread from before is archived after its reply, and the one left open is archived on connecting: \(listed()) \(record())") { listed().isEmpty && record().isEmpty }

        // 8. A task stopped in the middle of a turn: closing its connection archives the thread first, then ends the connection.
        let held = try start("HOLD: a long task", key: "workspace:forge", background: false)
        await settle("the long task's turn has started") { home().values.contains { $0["turns"] as? Int == 1 && $0["archived"] as? Bool == false } && listed().count == 1 }
        let open = listed()
        service.close()
        await settle("closing archives the stopped task's thread before the connection ends: \(listed())") { listed().isEmpty && record().isEmpty }
        await settle("then the connection ends, ending the turn") { ended(held) != nil }
        require(requests(open[0]).last == "thread/archive", "the last thing asked of that thread was to archive it: \(requests(open[0]))")
        print("PASS: background runs are ephemeral; chat and task threads are archived once their turn is over or their connection closes, unarchived to continue (after a restart and through a fork too), and threads left open are archived on the next connection")
    }
}
