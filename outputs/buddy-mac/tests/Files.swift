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
        // A coding project gets a connected folder's files natively. 3 MB is more than the model can read (1 MB), and sending it through the conversation costs more than a coding budget.
        do {
            let base = fm.temporaryDirectory.appendingPathComponent("buddy-copy-test-" + UUID().uuidString), sourceRoot = base.appendingPathComponent("Source"), projectRoot = base.appendingPathComponent("Project"), outside = base.appendingPathComponent("Outside"), copySupport = base.appendingPathComponent("Support")
            for directory in [sourceRoot.appendingPathComponent("data"), projectRoot, outside, copySupport] { try fm.createDirectory(at: directory, withIntermediateDirectories: true) }
            defer { try? fm.removeItem(at: base) }
            let big = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ ($0 >> 8)) })
            try big.write(to: sourceRoot.appendingPathComponent("data/prices.csv")); try Data("print('run')\n".utf8).write(to: sourceRoot.appendingPathComponent("run.py"))
            try Data("secret".utf8).write(to: sourceRoot.appendingPathComponent(".env")); try fm.createSymbolicLink(at: sourceRoot.appendingPathComponent("link.csv"), withDestinationURL: sourceRoot.appendingPathComponent("run.py"))
            let copyWorkspace = UUID().uuidString, connectedFolder = try BuddyProjectFiles(support: copySupport).addFolder(copyWorkspace, to: sourceRoot)
            try JSONSerialization.data(withJSONObject: ["conversationWorkspace": copyWorkspace]).write(to: copySupport.appendingPathComponent("workspace.json"))
            let project = BuddyProjectFiles(support: copySupport, privateRoot: projectRoot, privateFolderID: "task-1"), projectScope = try project.scope(copyWorkspace), sourceScope = BuddyFileScope(workspace: copyWorkspace, folderId: connectedFolder["folderId"] as! String)
            let result = try project.copy(from: sourceScope, to: projectScope, paths: ["data/prices.csv", "run.py", "absent.csv", "../escape.txt", ".env", "link.csv"], actor: "coder", actorName: "Coder")
            let copiedPaths = (result["copied"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }, failedPaths = (result["failed"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
            require(copiedPaths == ["data/prices.csv", "run.py"] && Set(failedPaths) == ["absent.csv", "../escape.txt", ".env", "link.csv"], "the copy brings in regular visible files and reports the rest as failed without stopping")
            require(try Data(contentsOf: projectRoot.appendingPathComponent("data/prices.csv")) == big && result["totalBytes"] as? Int == big.count + 13, "a file larger than the model can read arrives byte for byte")
            require(try Data(contentsOf: sourceRoot.appendingPathComponent("data/prices.csv")) == big && !fm.fileExists(atPath: sourceRoot.appendingPathComponent("escape.txt").path), "the originals are only read")
            let again = try project.copy(from: sourceScope, to: projectScope, paths: ["data/prices.csv", "run.py"], actor: "coder", actorName: "Coder")
            require((again["failed"] as? [Any])?.isEmpty == true && (again["copied"] as? [[String: Any]])?.allSatisfy { $0["replaced"] as? Bool == true } == true, "copying again replaces the earlier copy instead of conflicting")
            try Data("print('changed')\n".utf8).write(to: sourceRoot.appendingPathComponent("run.py"))
            _ = try project.copy(from: sourceScope, to: projectScope, paths: ["run.py"], actor: "coder", actorName: "Coder")
            require(try String(contentsOf: projectRoot.appendingPathComponent("run.py"), encoding: .utf8) == "print('changed')\n", "a changed original is copied again")
            rejects("invalid_arguments") { _ = try project.copy(from: sourceScope, to: projectScope, paths: [], actor: "coder", actorName: "Coder") }
            rejects("invalid_arguments") { _ = try project.copy(from: sourceScope, to: projectScope, paths: ["run.py", "run.py"], actor: "coder", actorName: "Coder") }
            rejects("invalid_arguments") { _ = try project.copy(from: sourceScope, to: projectScope, paths: (0..<201).map { "f\($0).csv" }, actor: "coder", actorName: "Coder") }
            rejects("invalid_arguments") { _ = try project.copy(from: projectScope, to: projectScope, paths: ["run.py"], actor: "coder", actorName: "Coder") }
            // A folder path brings everything under it, hidden files, links and unlisted dependency folders excluded.
            try fm.createDirectory(at: sourceRoot.appendingPathComponent("lib/node_modules/dep"), withIntermediateDirectories: true); try Data("dep".utf8).write(to: sourceRoot.appendingPathComponent("lib/node_modules/dep/index.js"))
            try Data("a".utf8).write(to: sourceRoot.appendingPathComponent("lib/a.py")); try Data("b".utf8).write(to: sourceRoot.appendingPathComponent("lib/b.py")); try Data("h".utf8).write(to: sourceRoot.appendingPathComponent("lib/.hidden"))
            let folderCopy = try project.copy(from: sourceScope, to: projectScope, paths: ["lib/", "nothing/"], actor: "coder", actorName: "Coder")
            require((folderCopy["copied"] as? [[String: Any]])?.compactMap { $0["path"] as? String } == ["lib/a.py", "lib/b.py"] && (folderCopy["failed"] as? [[String: Any]])?.compactMap { $0["path"] as? String } == ["nothing/"], "a folder path copies the files under it and skips hidden files and dependency folders")
            let everything = try project.copy(from: sourceScope, to: projectScope, paths: ["/"], actor: "coder", actorName: "Coder")
            require(Set((everything["copied"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }) == ["data/prices.csv", "run.py", "lib/a.py", "lib/b.py"], "a lone / copies the whole connected folder")
            // A folder plus named files can add up to more than one call copies; the extras are reported, not dropped silently.
            try fm.createDirectory(at: sourceRoot.appendingPathComponent("many"), withIntermediateDirectories: true); try fm.createDirectory(at: sourceRoot.appendingPathComponent("venv"), withIntermediateDirectories: true)
            for n in 0..<100 { try Data("x".utf8).write(to: sourceRoot.appendingPathComponent("many/f\(n).txt")) }
            for n in 0..<101 { try Data("y".utf8).write(to: sourceRoot.appendingPathComponent("venv/g\(n).txt")) }
            let crowded = try project.copy(from: sourceScope, to: projectScope, paths: ["many/"] + (0..<101).map { "venv/g\($0).txt" }, actor: "coder", actorName: "Coder")
            require((crowded["copied"] as? [Any])?.count == 200 && (crowded["failed"] as? [[String: Any]])?.count == 1 && ((crowded["failed"] as? [[String: Any]])?.first?["error"] as? String)?.contains("up to 200 files") == true, "files beyond one call's limit are reported as not copied")
            // A folder bigger than one listing is explored a subfolder at a time, and a folder deep inside it is still reachable.
            try fm.createDirectory(at: sourceRoot.appendingPathComponent("lots"), withIntermediateDirectories: true); try fm.createDirectory(at: sourceRoot.appendingPathComponent("deep/inner"), withIntermediateDirectories: true)
            for n in 0..<210 { try Data("z".utf8).write(to: sourceRoot.appendingPathComponent("lots/n\(n).txt")) }
            try Data("target".utf8).write(to: sourceRoot.appendingPathComponent("deep/inner/target.txt"))
            let inner = try project.list(sourceScope, under: "deep/inner")
            require((inner["files"] as? [[String: Any]])?.compactMap { $0["path"] as? String } == ["deep/inner/target.txt"], "a subfolder can be listed by itself")
            let deepCopy = try project.copy(from: sourceScope, to: projectScope, paths: ["deep/inner/"], actor: "coder", actorName: "Coder")
            require((deepCopy["copied"] as? [[String: Any]])?.compactMap { $0["path"] as? String } == ["deep/inner/target.txt"], "a folder path reaches a subfolder however crowded the rest of the folder is")
            let lotsCopy = try project.copy(from: sourceScope, to: projectScope, paths: ["lots/"], actor: "coder", actorName: "Coder")
            require((lotsCopy["copied"] as? [Any])?.count == 200 && (lotsCopy["note"] as? String)?.contains("more files") == true, "a folder with more files than one listing says so instead of pretending it copied everything")
            rejects("invalid_path") { _ = try project.list(sourceScope, under: "nowhere") }
            rejects("invalid_path") { _ = try project.list(sourceScope, under: "../Outside") }
            // Results go back out as new files only: never over one of the person's, and never outside the folder.
            try fm.createDirectory(at: projectRoot.appendingPathComponent("out"), withIntermediateDirectories: true); try big.write(to: projectRoot.appendingPathComponent("out/result.csv")); try Data("note".utf8).write(to: projectRoot.appendingPathComponent("report.md"))
            let saved = try project.copy(from: projectScope, to: sourceScope, paths: ["out/", "report.md"], into: "results-1", replacing: false, actor: "coder", actorName: "Coder")
            require((saved["failed"] as? [Any])?.isEmpty == true && (saved["copied"] as? [[String: Any]])?.compactMap { $0["to"] as? String } == ["results-1/out/result.csv", "results-1/report.md"], "results are saved under a new subfolder")
            require(try Data(contentsOf: sourceRoot.appendingPathComponent("results-1/out/result.csv")) == big, "a large result reaches the person's folder byte for byte")
            let again2 = try project.copy(from: projectScope, to: sourceScope, paths: ["report.md"], into: "results-1", replacing: false, actor: "coder", actorName: "Coder")
            let kept = try String(contentsOf: sourceRoot.appendingPathComponent("results-1/report.md"), encoding: .utf8)
            require((again2["copied"] as? [Any])?.isEmpty == true && ((again2["failed"] as? [[String: Any]])?.first?["error"] as? String)?.contains("never overwrites") == true && kept == "note", "saving results never overwrites a file in the person's folder")
            let outside2 = try project.copy(from: projectScope, to: sourceScope, paths: ["report.md"], into: "../elsewhere", replacing: false, actor: "coder", actorName: "Coder")
            require((outside2["copied"] as? [Any])?.isEmpty == true && !fm.fileExists(atPath: base.appendingPathComponent("elsewhere").path), "a subfolder cannot climb out of the connected folder")
            // A command in the project could have made a link that points outside it; a copy must not follow it.
            try fm.removeItem(at: projectRoot.appendingPathComponent("data")); try fm.createSymbolicLink(at: projectRoot.appendingPathComponent("data"), withDestinationURL: outside)
            let escaped = try project.copy(from: sourceScope, to: projectScope, paths: ["data/prices.csv"], actor: "coder", actorName: "Coder")
            let leaked = try fm.contentsOfDirectory(atPath: outside.path)
            require((escaped["copied"] as? [Any])?.isEmpty == true && (escaped["failed"] as? [Any])?.count == 1 && leaked.isEmpty, "a copy never follows a link out of the project")
        }
        print("PASS: native copy of connected-folder files into a project: large files, partial failure, repeat, originals untouched, and no link escape")
    }
}
