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
        rejects("file_too_large") { _ = try files.write(scope, path: "big.txt", content: String(repeating: "x", count: 10 * 1_048_576 + 1), expectedVersion: "", actor: "a", actorName: "A") }
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
        // A coding project gets a connected folder's files natively: sending a 3 MB dataset through the conversation costs more than a coding budget.
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
        // What an agent sees of a folder costs its context: paths and sizes two levels down, and a folder it didn't open says what it holds so
        // the agent lists that one next. The whole tree stays one depth away, within the same 200 files and 500 folders as before.
        do {
            let base = fm.temporaryDirectory.appendingPathComponent("buddy-listing-test-" + UUID().uuidString), tree = base.appendingPathComponent("Research"), listSupport = base.appendingPathComponent("Support")
            defer { try? fm.removeItem(at: base) }
            for directory in ["notes", "data/raw/2024", "data/clean", "deep/a/b/c", "node_modules/dep"] { try fm.createDirectory(at: tree.appendingPathComponent(directory), withIntermediateDirectories: true) }
            func put(_ path: String, _ text: String = "x") throws { try Data(text.utf8).write(to: tree.appendingPathComponent(path)) }
            try put("README.md", "hello"); try put("notes/plan.md", "plan"); try put("data/clean/prices.csv", "1,2"); try put("data/raw/2024/jan.csv"); try put("deep/a/b/c/target.txt", "target"); try put("node_modules/dep/index.js"); try put(".env", "secret")
            for n in 0..<30 { try put("data/raw/f\(n).csv") }
            let listWorkspace = UUID().uuidString, lister = BuddyProjectFiles(support: listSupport), home = try lister.scope(listWorkspace)
            let treeID = try lister.addFolder(listWorkspace, to: tree)["folderId"] as! String
            func listing(_ arguments: [String: Any]) throws -> [String: Any] { try lister.call(home, tool: "buddy_list_files", arguments: arguments.merging(["folderId": treeID]) { mine, _ in mine }, actor: "a", actorName: "A") }
            func paths(_ result: [String: Any], _ key: String) -> [String] { (result[key] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String } }
            func folder(_ result: [String: Any], _ path: String) -> [String: Any] { (result["subfolders"] as? [[String: Any]])?.first { $0["path"] as? String == path } ?? [:] }
            func held(_ result: [String: Any], _ path: String) -> [Int] { let entry = folder(result, path); return [entry["moreFiles"] as? Int ?? 0, entry["moreFolders"] as? Int ?? 0] }

            let shallow = try listing([:])
            require(paths(shallow, "files") == ["notes/plan.md", "README.md"], "by default an agent sees two levels: \(paths(shallow, "files"))")
            require((shallow["files"] as? [[String: Any]])?.allSatisfy { Set($0.keys) == ["path", "bytes"] } == true && (shallow["files"] as? [[String: Any]])?.first { $0["path"] as? String == "README.md" }?["bytes"] as? Int == 5, "a file is its path and size, nothing else")
            require(paths(shallow, "subfolders") == ["data", "data/clean", "data/raw", "deep", "deep/a", "node_modules", "notes"], "every folder it reached is named: \(paths(shallow, "subfolders"))")
            require(held(shallow, "data/raw") == [30, 1] && held(shallow, "data/clean") == [1, 0] && held(shallow, "deep/a") == [0, 1] && held(shallow, "notes") == [0, 0] && held(shallow, "data") == [0, 0], "a folder below the depth says how many files and folders it holds")
            require(folder(shallow, "node_modules")["omitted"] as? Bool == true && held(shallow, "node_modules") == [0, 0], "a dependency folder is named but not opened")
            let note = shallow["note"] as? String ?? ""
            require(shallow["complete"] as? Bool == false && note.contains("31 files") && note.contains("2 folders") && note.contains("path"), "the listing says what it left out and how to list it: \(note)")
            for key in ["folders", "location", "workspace", "maximumBytes", "directories", "limited", "managed", "primary"] { require(shallow[key] == nil, "no \(key) in what the agent sees") }
            require(shallow["folderId"] as? String == treeID && shallow["name"] as? String == "Research", "the listing names its folder")

            let top = try listing(["depth": 1])
            require(paths(top, "files") == ["README.md"] && held(top, "data") == [0, 2] && held(top, "notes") == [1, 0] && held(top, "deep") == [0, 1], "depth 1 is this folder alone, with what each subfolder holds")
            let raw = try listing(["path": "data/raw", "depth": 1])
            require(paths(raw, "files").count == 30 && paths(raw, "files").first == "data/raw/f0.csv" && paths(raw, "files").last == "data/raw/f29.csv" && held(raw, "data/raw/2024") == [1, 0] && raw["path"] as? String == "data/raw", "the agent lists a folder it was pointed to with its path")
            require(try listing(["path": "data/raw"])["complete"] as? Bool == true, "a folder within the depth is listed completely")

            let whole = try listing(["depth": 8])
            require(Set(paths(whole, "files")) == Set(["README.md", "notes/plan.md", "data/clean/prices.csv", "data/raw/2024/jan.csv", "deep/a/b/c/target.txt"] + (0..<30).map { "data/raw/f\($0).csv" }) && whole["complete"] as? Bool == true && whole["note"] == nil, "depth 8 reaches the whole tree, as every listing did before")
            require(!paths(whole, "files").contains("node_modules/dep/index.js") && !paths(whole, "files").contains(".env"), "dependency folders and hidden files stay out")

            // A crowded folder stops at 200 files, top level first, and every folder past the limit says what it still holds.
            try fm.createDirectory(at: tree.appendingPathComponent("lots"), withIntermediateDirectories: true)
            for n in 0..<210 { try put("lots/n\(n).txt") }
            let crowded = try listing(["depth": 8]), listed = paths(crowded, "files")
            require(listed.count == 200 && listed.contains("README.md") && !listed.contains { $0.split(separator: "/").count > 2 } && crowded["complete"] as? Bool == false, "a listing stops at 200 files, nearest first")
            // Breadth first, by name: lots fills the listing before notes, and folders queued after that are only counted, one level in.
            require(held(crowded, "lots") == [11, 0] && held(crowded, "notes") == [1, 0] && held(crowded, "data/clean") == [1, 0] && held(crowded, "data/raw") == [30, 1] && held(crowded, "deep/a") == [0, 1], "every folder past the limit says what it still holds")
            let cutNote = crowded["note"] as? String ?? ""
            require(cutNote.contains("200 files") && cutNote.contains("43 files") && cutNote.contains("2 folders"), "the note says where it stopped and how much is left: \(cutNote)")
            let lots = try listing(["path": "lots"])
            let lotsNote = lots["note"] as? String ?? ""
            require(paths(lots, "files").count == 200 && lotsNote == "A listing stops at 200 files and 500 folders. Not listed: 10 files directly in this folder, after the ones shown by name.", "a single folder of 210 files lists 200 and says 10 more are in it: \(lotsNote)")

            for bad: Any in [0, 9, "two", 2.5] { rejects("invalid_arguments") { _ = try listing(["depth": bad]) } }
            let tool = BuddyProjectFiles.tools.first { $0["name"] as? String == "buddy_list_files" } ?? [:]
            let properties = (tool["inputSchema"] as? [String: Any])?["properties"] as? [String: Any] ?? [:], depthSchema = properties["depth"] as? [String: Any] ?? [:]
            require(depthSchema["type"] as? String == "integer" && depthSchema["minimum"] as? Int == 1 && depthSchema["maximum"] as? Int == 8 && Set(properties.keys) == ["folderId", "path", "depth"], "the schema offers depth 1–8: \(properties)")
            let description = tool["description"] as? String ?? ""
            require(description.contains("moreFiles") && description.contains("path") && description.contains("depth"), "the description tells the agent how to list deeper: \(description)")
        }
        print("PASS: an agent's folder listing is shallow paths and sizes, says what it left out, and reaches the whole tree on request")
        // Text files up to 10 MB. A 5 MB file is written in one go and read a page at a time: no single tool result holds the whole file, and the
        // pages put back together are the file exactly. Over 10 MB, writing is refused and reading says what the file is instead of its text.
        do {
            let base = fm.temporaryDirectory.appendingPathComponent("buddy-pages-test-" + UUID().uuidString)
            defer { try? fm.removeItem(at: base) }
            let files = BuddyProjectFiles(support: base), scope = try files.scope(UUID().uuidString), root = try files.location(scope)
            _ = try files.write(scope, path: "notes/plan.md", content: "External edit", expectedVersion: "", actor: "a", actorName: "A")
            let line = "2026-10-21,SPX,5832.10,é,\(String(repeating: "x", count: 60))\n"
            let count = 5 * 1_048_576 / line.utf8.count + 1, big = String(repeating: line, count: count)
            func read(_ arguments: [String: Any]) throws -> [String: Any] { try files.call(scope, tool: "buddy_read_file", arguments: arguments.merging(["path": "data/big.csv"]) { mine, _ in mine }, actor: "a", actorName: "A") }
            let saved = try files.call(scope, tool: "buddy_write_file", arguments: ["path": "data/big.csv", "content": big, "expectedVersion": ""], actor: "a", actorName: "A")
            require(saved["saved"] as? Bool == true && big.utf8.count > 5 * 1_048_576, "a 5 MB text file is written with the file tool")
            let first = try read([:]), page = first["content"] as? String ?? ""
            require(first["format"] as? String == "text" && first["editable"] as? Bool == true && first["more"] as? Bool == true && first["bytes"] as? Int == big.utf8.count && first["version"] as? String == BuddyProjectFiles.hash(Data(big.utf8)),
                    "the first page of a big file says it is text, its whole size and version, and that there is more: \(first.filter { $0.key != "content" })")
            require(page.utf8.count <= BuddyProjectFiles.readPageBytes && page.utf8.count > BuddyProjectFiles.readPageBytes - line.utf8.count && page.hasSuffix("\n") && first["nextOffset"] as? Int == page.utf8.count,
                    "a page is at most \(BuddyProjectFiles.readPageBytes) bytes and ends at a line break: \(page.utf8.count)")
            require(first["startLine"] as? Int == 1 && first["endLine"] as? Int == page.components(separatedBy: "\n").count - 1 && first["lines"] as? Int == count,
                    "a page says which lines it holds out of how many: \(first["startLine"] ?? "-")–\(first["endLine"] ?? "-") of \(first["lines"] ?? "-")")
            let note = first["note"] as? String ?? ""
            require(note.contains("offset") && note.contains("\(page.utf8.count)") && note.contains("5.0 MB"), "the page says how to read on: \(note)")
            var whole = page, offset = first["nextOffset"] as? Int, pages = 1
            while let at = offset {
                let next = try read(["offset": at]); whole += next["content"] as? String ?? ""; pages += 1
                require((next["content"] as? String ?? "").utf8.count <= BuddyProjectFiles.readPageBytes && pages < 60, "every page stays within one page: page \(pages)")
                offset = next["more"] as? Bool == true ? next["nextOffset"] as? Int : nil
                if offset == nil { require(next["nextOffset"] == nil && next["endLine"] as? Int == count, "the last page says there is no more: \(next.filter { $0.key != "content" })") }
            }
            require(whole == big && pages > 15, "the pages put together are the file, byte for byte (\(pages) pages)")
            let small = try read(["offset": line.utf8.count, "limit": line.utf8.count * 2 + 5])
            require(small["content"] as? String == line + line && small["startLine"] as? Int == 2 && small["endLine"] as? Int == 3 && small["nextOffset"] as? Int == line.utf8.count * 3, "offset and limit read a few lines from the middle: \(small)")
            let inside = try read(["offset": line.utf8.count + 24, "limit": 10])
            require((inside["content"] as? String).map { !$0.isEmpty && Data($0.utf8).count <= 10 } == true, "an offset inside a character still reads whole characters: \(inside)")
            let end = try read(["offset": big.utf8.count])
            require(end["content"] as? String == "" && end["more"] as? Bool == false, "reading at the end gives nothing more")
            for bad: [String: Any] in [["offset": -1], ["offset": big.utf8.count + 1], ["limit": 0], ["limit": BuddyProjectFiles.readPageBytes + 1], ["offset": "10"], ["offset": true]] { rejects("invalid_arguments") { _ = try read(bad) } }
            let short = try files.call(scope, tool: "buddy_read_file", arguments: ["path": "notes/plan.md"], actor: "a", actorName: "A")
            require(short["content"] as? String == "External edit" && short["more"] == nil && short["nextOffset"] == nil, "a small file is still read whole, as before")
            let edited = try files.call(scope, tool: "buddy_write_file", arguments: ["path": "data/big.csv", "content": big + "tail\n", "expectedVersion": first["version"] as! String], actor: "a", actorName: "A")
            let after = try Data(contentsOf: root.appendingPathComponent("data/big.csv"))
            require(edited["saved"] as? Bool == true && after == Data((big + "tail\n").utf8), "a page's version is the whole file's, so an edit after paging saves")
            let tooBig = String(repeating: line, count: 10 * 1_048_576 / line.utf8.count + 1)
            rejects("file_too_large") { _ = try files.call(scope, tool: "buddy_write_file", arguments: ["path": "data/huge.csv", "content": tooBig, "expectedVersion": ""], actor: "a", actorName: "A") }
            try Data(tooBig.utf8).write(to: root.appendingPathComponent("data/huge.csv"))
            let huge = try files.call(scope, tool: "buddy_read_file", arguments: ["path": "data/huge.csv"], actor: "a", actorName: "A")
            require(huge["content"] == nil && huge["format"] as? String == "binary" && (huge["notice"] as? String ?? "").contains("10 MB"), "a text file over 10 MB is not read as text, and says why: \(huge)")
            let readTool = BuddyProjectFiles.tools.first { $0["name"] as? String == "buddy_read_file" } ?? [:], writeTool = BuddyProjectFiles.tools.first { $0["name"] as? String == "buddy_write_file" } ?? [:]
            let readProperties = (readTool["inputSchema"] as? [String: Any])?["properties"] as? [String: Any] ?? [:]
            require(readProperties["offset"] != nil && readProperties["limit"] != nil && (readTool["description"] as? String ?? "").contains("10 MB") && (readTool["description"] as? String ?? "").contains("nextOffset")
                    && (writeTool["description"] as? String ?? "").contains("10 MB") && !"\(BuddyProjectFiles.tools)".contains("text/code up to 1 MB"), "the tools say 10 MB and how to read on")
        }
        print("PASS: text files up to 10 MB: written whole, read a page at a time with offset and limit, over 10 MB refused")
    }
}
