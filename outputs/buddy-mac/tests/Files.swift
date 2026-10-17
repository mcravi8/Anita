import Foundation
import Darwin

@main struct FileTests {
    static func require(_ value: Bool, _ message: String) { if !value { fputs("FAILED: \(message)\n", stderr); exit(1) } }
    static func rejects(_ code: String? = nil, _ block: () throws -> Void) { do { try block(); require(false, "unsafe operation accepted") } catch { if let code { require((error as? BuddyFileFailure)?.code == code, "wrong failure: \(error)") } } }
    @MainActor static func main() throws {
        let fm = FileManager.default, support = fm.temporaryDirectory.appendingPathComponent("buddy-files-test-" + UUID().uuidString)
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: support) }
        let files = BuddyProjectFiles(support: support), workspace = UUID().uuidString, scope = try files.scope(workspace), root = try files.location(scope)
        let first = try files.write(scope, path: "notes/plan.md", content: "Original\n", expectedVersion: "", actor: "writer", actorName: "Writer")
        let initial = try files.read(scope, path: "notes/plan.md"), version = initial["version"] as! String
        require(first["saved"] as? Bool == true && initial["content"] as? String == "Original\n", "real file creation and read")
        _ = try files.write(scope, path: "notes/plan.md", content: "Original\nWriter added\n", expectedVersion: version, actor: "writer", actorName: "Writer")
        rejects("file_changed") { _ = try files.write(scope, path: "notes/plan.md", content: "Reviewer overwrote", expectedVersion: version, actor: "reviewer", actorName: "Reviewer") }
        let latest = try files.read(scope, path: "notes/plan.md")
        let merged = try files.write(scope, path: "notes/plan.md", content: (latest["content"] as! String) + "Reviewer added\n", expectedVersion: latest["version"] as! String, actor: "reviewer", actorName: "Reviewer")
        let mergedRead = try files.read(scope, path: "notes/plan.md")
        require((mergedRead["content"] as! String).contains("Writer added") && (mergedRead["content"] as! String).contains("Reviewer added"), "both agents' changes survive reread and merge")
        let versions = try files.versions(scope, path: "notes/plan.md")
        require(versions.count == 3 && versions[0]["actor"] as? String == "reviewer", "durable version receipts with real authors")
        let receipt = (merged["file"] as! [String: Any])["id"] as! String
        _ = try files.restore(scope, path: "notes/plan.md", receiptId: receipt, expectedVersion: mergedRead["version"] as! String)
        require(try files.read(scope, path: "notes/plan.md")["content"] as? String == latest["content"] as? String, "restore earlier actual contents")
        rejects("file_changed") { _ = try files.restore(scope, path: "notes/plan.md", receiptId: receipt, expectedVersion: mergedRead["version"] as! String) }
        try "External edit".write(to: root.appendingPathComponent("notes/plan.md"), atomically: true, encoding: .utf8)
        rejects("file_changed") { _ = try files.write(scope, path: "notes/plan.md", content: "stale", expectedVersion: latest["version"] as! String, actor: "a", actorName: "A") }
        require(try String(contentsOf: root.appendingPathComponent("notes/plan.md"), encoding: .utf8) == "External edit", "external edits retained")
        print("PASS: real files, competing edits, merge, external changes, durable versions, and restore conflict checks")
        let privateFile = root.appendingPathComponent("private.txt"); try "Private".write(to: privateFile, atomically: true, encoding: .utf8); chmod(privateFile.path, 0o600)
        let privateRead = try files.read(scope, path: "private.txt")
        _ = try files.write(scope, path: "private.txt", content: "Still private", expectedVersion: privateRead["version"] as! String, actor: "a", actorName: "A")
        var meta = stat(); _ = lstat(privateFile.path, &meta); require(meta.st_mode & 0o777 == 0o600, "existing permission mode preserved")
        let outside = support.appendingPathComponent("outside.txt"); try "UNTOUCHED".write(to: outside, atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: root.appendingPathComponent("link.txt"), withDestinationURL: outside)
        try fm.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: support)
        link(outside.path, root.appendingPathComponent("hard.txt").path); mkfifo(root.appendingPathComponent("pipe.txt").path, 0o600)
        for path in ["../outside.txt", "/outside.txt", ".hidden", "notes/../plan.md", "link.txt", "linked/outside.txt", "hard.txt", "pipe.txt", "notes"] { rejects { _ = try files.read(scope, path: path) }; rejects { _ = try files.write(scope, path: path, content: "BAD", expectedVersion: "", actor: "a", actorName: "A") } }
        require(try String(contentsOf: outside, encoding: .utf8) == "UNTOUCHED", "outside file unchanged")
        rejects("file_too_large") { _ = try files.write(scope, path: "big.txt", content: String(repeating: "x", count: 1_048_577), expectedVersion: "", actor: "a", actorName: "A") }
        try Data([0, 255, 1]).write(to: root.appendingPathComponent("binary.bin")); require(try files.read(scope, path: "binary.bin")["format"] as? String == "binary", "binary files return metadata")
        require((try files.list(scope)["files"] as! [[String: Any]]).allSatisfy { !["link.txt", "hard.txt", "pipe.txt"].contains($0["path"] as! String) }, "unsafe entries excluded from listing")
        print("PASS: folder boundaries, symlinks, hard links, devices, hidden paths, file limits, and permission preservation")
        let vault=support.appendingPathComponent("Worker/Browsers/fixture/Default")
        try fm.createDirectory(at:vault,withIntermediateDirectories:true);try "synthetic private data".write(to:vault.appendingPathComponent("Login Data"),atomically:true,encoding:.utf8)
        let broad=try files.addFolder(workspace,to:support),broadScope=BuddyFileScope(workspace:workspace,folderId:broad["folderId"] as! String)
        rejects("private_credentials"){_ = try files.read(broadScope,path:"Worker/Browsers/fixture/Default/Login Data")}
        require(!(try files.list(broadScope)["files"] as! [[String:Any]]).contains{$0["path"] as? String=="Worker/Browsers/fixture/Default/Login Data"},"private browser/password databases are excluded even under a broad connected parent")
        try files.removeFolder(workspace,folderId:broadScope.folderId)
        let desktop = support.appendingPathComponent("Local desktop")
        try fm.createDirectory(at: desktop, withIntermediateDirectories: true)
        let connected = try files.addFolder(workspace, to: desktop), connectedID = connected["folderId"] as! String
        require(try files.addFolder(workspace, to: desktop)["folderId"] as? String == connectedID, "reconnecting same folder preserves identity and drafts")
        require(try files.scope(workspace) == scope, "adding local folders does not replace the shared folder")
        let arguments: [String: Any] = ["folderId": connectedID, "path": "plans/note.md", "content": "First draft", "expectedVersion": ""]
        _ = try files.call(scope, tool: "buddy_write_file", arguments: arguments, actor: "writer", actorName: "Writer")
        let localRead = try files.call(scope, tool: "buddy_read_file", arguments: ["folderId": connectedID, "path": "plans/note.md"], actor: "writer", actorName: "Writer")
        require(localRead["content"] as? String == "First draft" && fm.fileExists(atPath: desktop.appendingPathComponent("plans/note.md").path), "real creation and read in an additional Mac folder")
        let localScope = BuddyFileScope(workspace: workspace, folderId: connectedID)
        _ = try files.write(localScope, path: "plans/note.md", content: "Writer changed", expectedVersion: localRead["version"] as! String, actor: "writer", actorName: "Writer")
        rejects("file_changed") { _ = try files.write(localScope, path: "plans/note.md", content: "Stale reviewer", expectedVersion: localRead["version"] as! String, actor: "reviewer", actorName: "Reviewer") }
        require(try files.versions(localScope, path: "plans/note.md").count == 2, "local folder edits have durable restore receipts")
        require(try BuddyProjectFiles(support: support).read(localScope, path: "plans/note.md")["content"] as? String == "Writer changed", "connected folders survive restart")
        let otherWorkspace = UUID().uuidString, otherScope = try files.scope(otherWorkspace)
        rejects("folder_changed") { _ = try files.call(otherScope, tool: "buddy_read_file", arguments: ["folderId": connectedID, "path": "plans/note.md"], actor: "a", actorName: "A") }
        rejects("primary_folder") { try files.removeFolder(workspace, folderId: scope.folderId) }
        try files.removeFolder(workspace, folderId: connectedID)
        rejects("folder_changed") { _ = try files.read(localScope, path: "plans/note.md") }
        rejects("folder_changed") { _ = try files.call(scope, tool: "buddy_write_file", arguments: arguments, actor: "a", actorName: "A") }
        require(try String(contentsOf: desktop.appendingPathComponent("plans/note.md"), encoding: .utf8) == "Writer changed", "disconnect retains files and rejects stale writes")
        try Data("broken".utf8).write(to: support.appendingPathComponent("connected-folders.json"))
        rejects("folder_settings") { _ = try files.locations(workspace) }
        rejects("folder_settings") { _ = try files.addFolder(workspace, to: desktop) }
        try fm.removeItem(at: support.appendingPathComponent("connected-folders.json"))
        print("PASS: connected Mac folders, real local writes, conflict backups, restart, workspace isolation, disconnection, and corrupt-settings handling")
        let other = support.appendingPathComponent("other"); try fm.createDirectory(at: other, withIntermediateDirectories: true); _ = try files.connect(workspace, to: other)
        rejects("folder_changed") { _ = try files.read(scope, path: "private.txt") }; rejects("folder_changed") { _ = try files.versions(scope, path: "private.txt") }
        try Data("broken".utf8).write(to: support.appendingPathComponent("project-folders.json")); rejects("folder_settings") { _ = try files.scope(workspace) }
        print("PASS: changing folders invalidates old requests; malformed folder settings fail closed")
    }
}
