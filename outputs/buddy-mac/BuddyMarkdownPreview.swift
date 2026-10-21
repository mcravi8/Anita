import Foundation

/// Markdown Viewer's renderer and offline math, embedded in Buddy's file preview.
/// This only renders bytes already read through the connected-folder boundary.
enum BuddyMarkdownPreview {
    static var resourceRoot: URL? { Bundle.main.resourceURL?.appendingPathComponent("MarkdownViewer", isDirectory:true) }
    static let extensions: Set<String> = ["md","markdown","mdown","mkd","mkdn","mdx"]
    static func enrich(_ file:[String:Any], assetReader:((String)->Data?)?=nil) -> [String:Any] {
        guard let path=file["path"] as? String,extensions.contains(URL(fileURLWithPath:path).pathExtension.lowercased()),file["format"] as? String=="text",let source=file["content"] as? String else{return file}
        guard source.utf8.count<=256*1024 else{var result=file;result["markdownPlain"]=true;result["notice"]="This large Markdown file uses the plain reading preview. Editing still saves to the original.";return result}
        let rendered=BuddyViewerMarkdownRenderer.render(source)
        guard rendered.html.utf8.count<=4*1024*1024 else{var result=file;result["markdownPlain"]=true;result["notice"]="This document uses the plain reading preview because its rendered contents are large.";return result}
        let css=resourceRoot.flatMap{try? String(contentsOf:$0.appendingPathComponent("style.css"),encoding:.utf8)} ?? "body{font:15px/1.7 -apple-system,sans-serif;margin:28px}"
        let mathCSS=resourceRoot.flatMap{try? String(contentsOf:$0.appendingPathComponent("Math/katex.css"),encoding:.utf8)} ?? ""
        var html=rendered.html
        // Only bounded, explicitly referenced raster images from the same
        // connected folder are embedded. No disk access is given to the frame.
        let pattern=try! NSRegularExpression(pattern:#"(<img\b[^>]*\bsrc=["'])([^"']+)(["'])"#,options:.caseInsensitive)
        var remaining=2*1024*1024,count=0
        let mime=["png":"image/png","jpg":"image/jpeg","jpeg":"image/jpeg","gif":"image/gif","webp":"image/webp"]
        for match in pattern.matches(in:html,range:NSRange(html.startIndex...,in:html)).reversed() {
            guard count<24,let range=Range(match.range(at:2),in:html),let raw=String(html[range]).removingPercentEncoding,!raw.hasPrefix("/"),!raw.contains(":"),!raw.contains("?"),!raw.contains("#"),let type=mime[URL(fileURLWithPath:raw).pathExtension.lowercased()] else{continue}
            var pieces=path.split(separator:"/").dropLast().map(String.init),valid=true
            for p in raw.split(separator:"/") {if p==".." {if pieces.isEmpty{valid=false;break};pieces.removeLast()}else if p != "." {pieces.append(String(p))}}
            guard valid,let data=assetReader?(pieces.joined(separator:"/")),data.count<=1024*1024,data.count<=remaining else{continue}
            html.replaceSubrange(range,with:"data:"+type+";base64,"+data.base64EncodedString());remaining-=data.count;count+=1
        }
        var result=file
        result["markdownViewer"]=["html":html,"style":mathCSS+"\n"+css,"caption":rendered.caption,"headings":rendered.headings.map{["id":$0.id,"level":$0.level,"title":$0.title]}] as [String:Any]
        return result
    }
}
