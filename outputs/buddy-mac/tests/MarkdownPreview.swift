import Foundation
@main struct MarkdownPreviewTests {
    static func require(_ value:Bool,_ message:String){if !value{fputs("FAILED: \(message)\n",stderr);exit(1)}}
    @MainActor static func main() throws {
        let fm=FileManager.default,base=fm.temporaryDirectory.appendingPathComponent("buddy-markdown-"+UUID().uuidString+".noindex")
        try fm.createDirectory(at:base,withIntermediateDirectories:true);defer{try? fm.removeItem(at:base)}
        let files=BuddyProjectFiles(support:base.appendingPathComponent("support")),workspace=UUID().uuidString,original=base.appendingPathComponent("Originals")
        try fm.createDirectory(at:original,withIntermediateDirectories:true)
        let connected=try files.addFolder(workspace,to:original),scope=BuddyFileScope(workspace:workspace,folderId:connected["folderId"] as! String)
        let source="# Research brief\n\nAn **original** document.\n\n## Evidence\n\n| Source | Status |\n| --- | --- |\n| Primary | Checked |\n\n$x^2 + y^2$\n\n```python\nprint(42)\n```\n\n![Sample](assets/sample.png)\n"
        _ = try files.write(scope,path:"notes/README.md",content:source,expectedVersion:"",actor:"you",actorName:"You")
        let image=Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aZZkAAAAASUVORK5CYII=")!
        _ = try files.writeBytes(scope,path:"notes/assets/sample.png",data:image,expectedVersion:"",actor:"you",actorName:"You")
        try fm.createDirectory(at:original.appendingPathComponent("empty"),withIntermediateDirectories:true)
        try fm.createDirectory(at:original.appendingPathComponent("venv/lib"),withIntermediateDirectories:true)
        try "dependency".write(to:original.appendingPathComponent("venv/lib/dependency.py"),atomically:true,encoding:.utf8)
        let preview=BuddyMarkdownPreview.enrich(try files.preview(scope,path:"notes/README.md"),assetReader:{try? files.readBytes(scope,path:$0)}),viewer=preview["markdownViewer"] as! [String:Any],html=viewer["html"] as! String
        require(html.contains("<table")&&html.contains("<strong>original</strong>")&&html.contains("katex")&&html.contains("class=\"tk-")&&html.contains("data:image/png;base64,"),"Markdown Viewer tables, formatting, offline math, syntax colors and bounded local images are reused")
        require((viewer["headings"] as? [[String:Any]])?.count==2,"native outline has real document headings")
        require(try String(contentsOf:original.appendingPathComponent("notes/README.md"),encoding:.utf8)==source,"preview never modifies the original")
        let listed=try files.list(scope),directories=listed["directories"] as! [[String:Any]]
        require(directories.contains{$0["path"] as? String=="empty"}&&directories.contains{$0["path"] as? String=="venv"&&$0["omitted"] as? Bool==true},"folder tree retains empty and collapsed dependency directories")
        require(!(listed["files"] as! [[String:Any]]).contains{($0["path"] as? String)?.hasPrefix("venv/")==true},"dependency contents cannot consume the project listing")
        let version=preview["version"] as! String
        _ = try files.write(scope,path:"notes/README.md",content:source+"\nSaved in Buddy.\n",expectedVersion:version,actor:"you",actorName:"You")
        require(try String(contentsOf:original.appendingPathComponent("notes/README.md"),encoding:.utf8).contains("Saved in Buddy."),"editing saves directly to the connected original")
        do{_ = try files.write(scope,path:"notes/README.md",content:"Stale draft",expectedVersion:version,actor:"you",actorName:"You");require(false,"stale edit rejected")}catch let e as BuddyFileFailure{require(e.code=="file_changed","stale save keeps current original")}
        require(try files.versions(scope,path:"notes/README.md").count==2,"real original saves retain recoverable history")
        if CommandLine.arguments.count>1 {try JSONSerialization.data(withJSONObject:preview).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))}
        print("PASS: embedded Markdown Viewer, offline math, local images, nested folders, direct original saves, version conflicts and history")
    }
}
