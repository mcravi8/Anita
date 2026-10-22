// run-tests: BuddyProjectFiles.swift BuddyDocuments.swift
import Foundation
import Darwin

/// Agents name places on the Mac by their path. Inside a connected folder that just works; anywhere else in the home folder Buddy asks the
/// person once, in the chat, for the top folder that holds it (Desktop, Documents, a project folder, iCloud Drive, or the whole home folder),
/// and remembers the answer. Keys, passwords, browser data, system and app files stay out of reach whatever was allowed. Files can also be
/// moved and renamed, never over another file, and a move can be undone. Everything runs in a temporary fake home folder, never the real one.
@main struct FolderAccessTests {
    static func require(_ value: Bool, _ message: String) { if !value { fputs("FAILED: \(message)\n", stderr); exit(1) } }
    @discardableResult static func rejects(_ code: String, _ label: String, _ block: () throws -> Void) -> BuddyFileFailure? {
        do { try block(); require(false, "\(label): accepted") } catch {
            let failure = error as? BuddyFileFailure
            require(failure?.code == code, "\(label): wrong failure \(failure?.code ?? "-"): \(error.localizedDescription)")
            return failure
        }
        return nil
    }
    @MainActor static func main() throws {
        let fm = FileManager.default, base = fm.temporaryDirectory.appendingPathComponent("buddy-folder-access-" + UUID().uuidString)
        defer { try? fm.removeItem(at: base) }
        let home = base.appendingPathComponent("home/fixture"), support = home.appendingPathComponent("Library/Application Support/Buddy")
        func put(_ path: String, _ text: String = "x") throws { let url = home.appendingPathComponent(path); try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true); try Data(text.utf8).write(to: url) }
        func exists(_ path: String) -> Bool { fm.fileExists(atPath: home.appendingPathComponent(path).path) }
        try put("Directed Research/notes.md", "research notes"); try put("Desktop/notes.txt", "desktop notes"); try put("Desktop/sub/other.txt", "deeper")
        try put("Downloads/report.txt", "report"); try put("Downloads/second.txt", "second"); try put("Pictures/a.txt", "picture list"); try put("Music/b.txt", "music list"); try put("top.txt", "in home")
        try put(".ssh/id_rsa", "PRIVATE KEY"); try put("Library/Preferences/app.plist", "prefs"); try put("Library/Mobile Documents/com~apple~CloudDocs/cloud.txt", "in iCloud")
        try put("Projects/.env", "SECRET=1"); try put("Projects/server.pem", "PEM"); try put("Projects/id_rsa_backup", "KEY"); try put("Projects/readme.txt", "project")
        try put("Library/Keychains/login.keychain-db", "keychain"); try put("Library/Application Support/Google/Chrome/Default/Login Data", "logins")
        try fm.createDirectory(at: support, withIntermediateDirectories: true); try Data("{}".utf8).write(to: support.appendingPathComponent("secret-settings.json"))

        let files = BuddyProjectFiles(support: support); files.home = home
        let workspace = UUID().uuidString, shared = try files.scope(workspace)
        let research = try files.addFolder(workspace, to: home.appendingPathComponent("Directed Research"))["folderId"] as! String
        let chief = BuddyAccessAsker(agentId: "chief", agentName: "Chief", chat: "chief", runId: "run-1")
        func read(_ path: String, as asker: BuddyAccessAsker = chief) throws -> [String: Any] { try files.call(shared, tool: "buddy_read_file", arguments: ["path": path], actor: asker.agentId, actorName: asker.agentName, asker: asker) }
        func pending() throws -> [[String: Any]] { (try files.accessOverview(workspace)["requests"] as? [[String: Any]] ?? []).filter { $0["status"] as? String == "pending" } }

        // 1. A path inside a connected folder is that folder's file, written either way.
        require(try read(home.appendingPathComponent("Directed Research/notes.md").path)["content"] as? String == "research notes", "an absolute path inside a connected folder reads it")
        let tilde = try read("~/Directed Research/notes.md")
        require(tilde["content"] as? String == "research notes" && tilde["folderId"] as? String == research && tilde["path"] as? String == "notes.md", "~/ works too, and the reply names the connected folder and the path in it: \(tilde["folderId"] ?? "-") \(tilde["path"] ?? "-")")
        require(try pending().isEmpty, "nothing is asked for a connected folder")
        print("PASS: a path the user gave, inside a connected folder, is read without asking")

        // 2. A place that isn't connected yet: one request for its top folder, with who asks and why.
        let asked = rejects("access_requested", "a Desktop file before access") { _ = try read("~/Desktop/notes.txt") }
        require(asked?.message.contains("Desktop") == true && asked?.message.contains("End your reply") == true && !(asked?.message.contains("move") ?? true), "the agent is told Buddy asked, to end its reply, and nothing about moving files: \(asked?.message ?? "")")
        var open = try pending()
        require(open.count == 1, "one pending request: \(open)")
        let request = open[0], requestID = request["id"] as! String
        require(request["name"] as? String == "Desktop" && request["label"] as? String == "your Desktop" && request["reason"] as? String == "to read notes.txt" && request["agentName"] as? String == "Chief", "the request names the place, the reason and who asks: \(request)")
        require(request["location"] as? String == home.appendingPathComponent("Desktop").resolvingSymlinksInPath().path && asked?.request == requestID, "the place asked for is the top folder under home, and the failure carries the request: \(request["location"] ?? "-")")
        let lyra = BuddyAccessAsker(agentId: "lyra", agentName: "Lyra", chat: "team", runId: "run-2")
        rejects("access_requested", "another agent, same place") { _ = try read("~/Desktop/sub/other.txt", as: lyra) }
        rejects("access_requested", "the same agent again") { _ = try read("~/Desktop/notes.txt") }
        open = try pending()
        require(open.count == 1 && (open[0]["waiting"] as? [[String: Any]])?.compactMap { $0["agentId"] as? String } == ["chief", "lyra"], "asking again adds who waits to the same request instead of a second card: \(open)")
        require(try BuddyProjectFiles(support: support).accessOverview(workspace)["requests"] as? [[String: Any]] != nil, "the request is saved with the folder records, for every process")
        print("PASS: an unconnected Desktop gives one pending request naming Desktop, the reason and who waits")

        // 3. Only the person answers; an agent or the supervisor can't, and no tool or argument grants anything.
        for actor in ["chief", "supervisor", "lyra", ""] {
            rejects("not_authorized", "\(actor) answering") { _ = try files.answerAccess(workspace, id: requestID, choice: "allow", actor: actor) }
            rejects("not_authorized", "\(actor) changing settings") { _ = try files.changeAccess(workspace, action: "allowHome", path: nil, actor: actor) }
        }
        rejects("unknown_tool", "an agent tool that answers") { _ = try files.call(shared, tool: "buddy_answer_folder_access", arguments: ["id": requestID, "choice": "allow"], actor: "chief", actorName: "Chief", asker: chief) }
        rejects("access_requested", "an argument claiming a grant") { _ = try files.call(shared, tool: "buddy_read_file", arguments: ["path": "~/Desktop/notes.txt", "granted": true, "allow": true], actor: "chief", actorName: "Chief", asker: chief) }
        require(try pending().count == 1 && (try files.locations(workspace)).count == 2, "still pending, nothing connected")
        print("PASS: neither an agent nor the supervisor can answer or change access")

        // 4. Allow connects the Desktop like Settings does; what waited is returned so it can go on, and nothing under it is asked again.
        let allowed = try files.answerAccess(workspace, id: requestID, choice: "allow", actor: "you")
        let waiting = allowed["waiting"] as? [[String: Any]] ?? []
        require(waiting.compactMap { $0["agentId"] as? String } == ["chief", "lyra"] && waiting.first?["chat"] as? String == "chief" && waiting.last?["chat"] as? String == "team", "the answer says who waited and in which chat: \(waiting)")
        require((allowed["request"] as? [String: Any])?["status"] as? String == "allowed", "the request is allowed")
        let desktopFolder = try files.locations(workspace).first { $0["name"] as? String == "Desktop" }
        require(desktopFolder?["location"] as? String == home.appendingPathComponent("Desktop").resolvingSymlinksInPath().path, "the Desktop is a connected folder, as if connected in Settings: \(try files.locations(workspace))")
        require(try read("~/Desktop/notes.txt")["content"] as? String == "desktop notes" && (try read("~/Desktop/sub/other.txt"))["content"] as? String == "deeper", "every path under it reads with no new request")
        let saved = try files.call(shared, tool: "buddy_write_file", arguments: ["path": "~/Desktop/sub/new.md", "content": "written", "expectedVersion": ""], actor: "chief", actorName: "Chief", asker: chief)
        require(saved["saved"] as? Bool == true && exists("Desktop/sub/new.md"), "and writes, with the usual receipts (read + write)")
        require(try pending().isEmpty, "nothing more was asked")
        let again = try files.answerAccess(workspace, id: requestID, choice: "allow", actor: "you")
        require((again["waiting"] as? [Any])?.isEmpty == true, "answering the same card twice (its group copy) continues nothing a second time")
        print("PASS: Allow connects Desktop permanently, read and write, and nothing under it is asked again")

        // 5. Don't allow is remembered: never asked again, the agent is told plainly, and Settings can still allow it.
        rejects("access_requested", "Downloads") { _ = try read("~/Downloads/report.txt") }
        let downloads = try pending().first!["id"] as! String
        let declined = try files.answerAccess(workspace, id: downloads, choice: "deny", actor: "you")
        require((declined["request"] as? [String: Any])?["status"] as? String == "declined" && (declined["waiting"] as? [Any])?.count == 1, "declined, and the waiter is returned so a task can be told")
        let told = rejects("access_declined", "Downloads after no") { _ = try read("~/Downloads/second.txt") }
        require(told?.message.contains("declined") == true && told?.message.contains("Downloads") == true, "the agent is told plainly the user declined: \(told?.message ?? "")")
        require(try pending().isEmpty, "no new card after a no")
        let overview = try files.accessOverview(workspace)
        require((overview["declined"] as? [[String: Any]])?.compactMap { $0["name"] as? String } == ["Downloads"] && (overview["granted"] as? [[String: Any]])?.compactMap { $0["name"] as? String }.sorted() == ["Desktop", "Directed Research"] && overview["wholeHome"] as? Bool == false, "Settings shows allowed and not-allowed places and the home folder: \(overview)")
        _ = try files.changeAccess(workspace, action: "allow", path: (overview["declined"] as! [[String: Any]])[0]["path"] as? String, actor: "you")
        require(try read("~/Downloads/second.txt")["content"] as? String == "second" && ((try files.accessOverview(workspace))["declined"] as? [Any])?.isEmpty == true, "Allow in Settings connects a place that was declined")
        print("PASS: Don't allow is remembered without asking again, and can be changed in Settings")

        // 6. The whole home folder: one grant for every folder in it, never the never-list.
        rejects("access_requested", "Pictures") { _ = try read("~/Pictures/a.txt") }
        let pictures = try pending().first!["id"] as! String
        let home1 = try files.answerAccess(workspace, id: pictures, choice: "home", actor: "you")
        require(home1["wholeHome"] as? Bool == true && (home1["waiting"] as? [Any])?.count == 1, "Allow my whole home folder answers the card")
        require(try read("~/Pictures/a.txt")["content"] as? String == "picture list" && (try read("~/Music/b.txt"))["content"] as? String == "music list" && (try read("~/top.txt"))["content"] as? String == "in home", "sibling folders and files directly in home need no new card")
        require(try read("~/Library/Mobile Documents/com~apple~CloudDocs/cloud.txt")["content"] as? String == "in iCloud", "iCloud Drive is in reach")
        for path in ["~/.ssh/id_rsa", "~/Library/Preferences/app.plist", "~/Projects/.env", "~/Projects/server.pem", "~/Projects/id_rsa_backup", "~/Library/Keychains/login.keychain-db", support.appendingPathComponent("secret-settings.json").path] {
            do { _ = try read(path); require(false, "never-list path read: \(path)") } catch { require(["private_location", "private_credentials"].contains((error as? BuddyFileFailure)?.code ?? ""), "\(path) is refused as private: \(error)") }
        }
        rejects("private_credentials", "a browser profile") { _ = try read("~/Library/Application Support/Google/Chrome/Default/Login Data") }
        rejects("outside_home", "outside home") { _ = try read("/etc/hosts") }
        require(try pending().isEmpty, "the never-list never makes a card")
        let homeID = (try files.accessOverview(workspace))["homeFolderId"] as! String
        let homeScope = BuddyFileScope(workspace: workspace, folderId: homeID)
        rejects("private_location", "a relative path into Library") { _ = try files.call(homeScope, tool: "buddy_read_file", arguments: ["path": "Library/Preferences/app.plist", "folderId": homeID], actor: "chief", actorName: "Chief", asker: chief) }
        let listed = try files.call(shared, tool: "buddy_list_files", arguments: ["path": "~", "depth": 1], actor: "chief", actorName: "Chief", asker: chief)
        let names = (listed["subfolders"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String } + (listed["files"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
        require(names.contains("Desktop") && names.contains("top.txt") && !names.contains("Library") && !names.contains(".ssh"), "listing the home folder leaves Library and hidden folders out: \(names)")
        require((try files.locations(workspace)).contains { $0["folderId"] as? String == homeID }, "the home folder is listed with the connected folders")
        _ = try files.changeAccess(workspace, action: "removeHome", path: nil, actor: "you")
        rejects("access_requested", "Music after the home grant is removed") { _ = try read("~/Music/b.txt") }
        print("PASS: the whole home folder covers sibling folders, never keys, passwords, browser data, Library or Buddy's own files")

        // 7. macOS's own privacy refusal becomes a plain message, not a crash or silence.
        let blocked = BuddyFolderAccess.permissionFailure(errno: EPERM, path: home.appendingPathComponent("Desktop").path, home: home.path)
        require(blocked?.code == "macos_blocked" && blocked?.message == "macOS blocked access to Desktop; allow Buddy in System Settings → Privacy & Security → Files and Folders.", "EPERM from macOS: \(blocked?.message ?? "-")")
        require(BuddyFolderAccess.permissionFailure(errno: ENOENT, path: "/x", home: home.path) == nil, "other errors keep their own message")
        let locked = home.appendingPathComponent("Locked"); try fm.createDirectory(at: locked, withIntermediateDirectories: true); try Data("x".utf8).write(to: locked.appendingPathComponent("a.txt"))
        let lockedID = try files.addFolder(workspace, to: locked)["folderId"] as! String
        chmod(locked.path, 0o000); defer { chmod(locked.path, 0o755) }
        let denied = rejects("folder_permission", "a folder Buddy may not open") { _ = try files.call(shared, tool: "buddy_read_file", arguments: ["folderId": lockedID, "path": "a.txt"], actor: "chief", actorName: "Chief", asker: chief) }
        require(denied?.message.contains("Locked") == true, "a permission refusal names the folder: \(denied?.message ?? "")")
        chmod(locked.path, 0o755)
        print("PASS: a macOS privacy refusal becomes the plain System Settings message")

        // 8. Moving and renaming: in place, into new subfolders, across folders, never over a file, never into or out of the never-list, undoable.
        try put("Directed Research/paper.pdf", "%PDF-fixture")
        func move(_ arguments: [String: Any], as asker: BuddyAccessAsker = chief) throws -> [String: Any] { try files.call(shared, tool: "buddy_move_file", arguments: arguments, actor: asker.agentId, actorName: asker.agentName, asker: asker) }
        let renamed = try move(["folderId": research, "from": "paper.pdf", "to": "sethna-2022.pdf"])
        require(renamed["moved"] as? Bool == true && exists("Directed Research/sethna-2022.pdf") && !exists("Directed Research/paper.pdf"), "rename in place: \(renamed)")
        let receipt = renamed["file"] as? [String: Any] ?? [:]
        require(receipt["kind"] as? String == "moved" && receipt["movedFrom"] as? String == "paper.pdf" && receipt["path"] as? String == "sethna-2022.pdf" && receipt["folderId"] as? String == research, "the move has a receipt like a saved file, with where it was: \(receipt)")
        let nested = try move(["folderId": research, "from": "sethna-2022.pdf", "to": "stages/S01_protocol/source_retry/"])
        require(exists("Directed Research/stages/S01_protocol/source_retry/sethna-2022.pdf") && nested["to"] as? String == "stages/S01_protocol/source_retry/sethna-2022.pdf", "into a new subfolder, made as needed; a folder target keeps the name: \(nested)")
        try put("Desktop/paper2.pdf", "%PDF-two")
        let across = try move(["from": "~/Desktop/paper2.pdf", "to": "~/Directed Research/stages/S01_protocol/paper2.pdf"])
        require(!exists("Desktop/paper2.pdf") && (try? String(contentsOf: home.appendingPathComponent("Directed Research/stages/S01_protocol/paper2.pdf"), encoding: .utf8)) == "%PDF-two" && (across["file"] as? [String: Any])?["movedFromFolder"] as? String != research, "across connected folders, byte for byte: \(across)")
        try put("Directed Research/a.txt", "A"); try put("Directed Research/b.txt", "B")
        let clash = rejects("file_exists", "a move over a file") { _ = try move(["folderId": research, "from": "a.txt", "to": "b.txt"]) }
        let keptA = try String(contentsOf: home.appendingPathComponent("Directed Research/a.txt"), encoding: .utf8), keptB = try String(contentsOf: home.appendingPathComponent("Directed Research/b.txt"), encoding: .utf8)
        require(clash?.message.contains("never") == true && keptA == "A" && keptB == "B", "never over another file; both stay as they were")
        try put("Directed Research/server.pem", "PEM")
        rejects("private_location", "moving a key file") { _ = try move(["folderId": research, "from": "server.pem", "to": "keys/server.pem"]) }
        rejects("private_location", "moving into ~/.ssh") { _ = try move(["folderId": research, "from": "a.txt", "to": "~/.ssh/a.txt"]) }
        _ = try files.changeAccess(workspace, action: "allowHome", path: nil, actor: "you")
        rejects("private_location", "moving out of Library") { _ = try move(["from": "~/Library/Preferences/app.plist", "to": "~/Directed Research/app.plist"]) }
        _ = try files.changeAccess(workspace, action: "removeHome", path: nil, actor: "you")
        require(exists("Directed Research/a.txt") && exists("Library/Preferences/app.plist") && !exists(".ssh/a.txt"), "nothing moved")
        let card = rejects("access_requested", "moving into an unconnected Documents") { _ = try move(["folderId": research, "from": "a.txt", "to": "~/Documents/a.txt"]) }
        let docs = try pending().first { $0["id"] as? String == card?.request }
        require(docs?["name"] as? String == "Documents" && docs?["reason"] as? String == "to move a.txt there" && exists("Directed Research/a.txt"), "an unconnected target gets the same one-time card, and nothing moves meanwhile: \(docs ?? [:])")
        let folderMove = try move(["folderId": research, "from": "stages/", "to": "archive/stages"])
        require(exists("Directed Research/archive/stages/S01_protocol/paper2.pdf") && !exists("Directed Research/stages"), "a whole folder moves under the same rules: \(folderMove)")
        let history = try files.versions(BuddyFileScope(workspace: workspace, folderId: research), path: "sethna-2022.pdf")
        require(history.first?["kind"] as? String == "moved" && history.first?["movedFrom"] as? String == "paper.pdf", "the file's history says where it came from: \(history)")
        let undone = try files.restore(BuddyFileScope(workspace: workspace, folderId: research), path: "renamed-b.txt", receiptId: (try move(["folderId": research, "from": "b.txt", "to": "renamed-b.txt"])["file"] as! [String: Any])["id"] as! String, expectedVersion: "")
        require(undone["moved"] as? Bool == true && exists("Directed Research/b.txt") && !exists("Directed Research/renamed-b.txt"), "a move is undone from its receipt: \(undone)")
        rejects("invalid_path", "moving a connected folder itself") { _ = try move(["from": "~/Directed Research", "to": "~/Desktop/Directed Research"]) }
        let schema = BuddyProjectFiles.tools.first { $0["name"] as? String == "buddy_move_file" }?["inputSchema"] as? [String: Any]
        require(Set((schema?["properties"] as? [String: Any] ?? [:]).keys) == ["from", "to", "folderId", "toFolderId"] && schema?["required"] as? [String] == ["from", "to"], "every agent gets buddy_move_file {from, to}: \(schema ?? [:])")
        print("PASS: move and rename in place, into new subfolders, across folders, never over a file, never the never-list, undoable, with the access card for an unconnected target")
    }
}
