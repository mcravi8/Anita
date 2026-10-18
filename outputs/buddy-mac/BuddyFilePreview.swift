import Foundation
import AppKit
import Quartz

// Quick Look receives a read-only snapshot, never the connected original.
// HTML uses Buddy's opaque sandbox instead of a native Web preview provider.
@MainActor final class BuddyFilePreview: NSObject, NSWindowDelegate {
    static let extensions: Set<String> = ["docx","pdf","doc","rtf","odt","pages","png","jpg","jpeg","gif","heic","webp","tiff","bmp","mp4","mov","m4v","mp3","m4a","wav","aiff","zip"]
    private var previews: [ObjectIdentifier: (NSWindow, NSView, URL)] = [:]
    func open(data: Data, name: String) throws {
        guard Self.extensions.contains(URL(fileURLWithPath:name).pathExtension.lowercased()), data.count <= BuddyProjectFiles.maximumBytes else { throw BuddyFileFailure(code:"preview_unavailable",message:"Use Buddy’s reading preview for this format.") }
        guard previews.count < 8 else { throw BuddyFileFailure(code:"preview_limit",message:"Close one of the open previews before opening another.") }
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("buddy-file-preview-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        do {
            let url=directory.appendingPathComponent(URL(fileURLWithPath:name).lastPathComponent)
            try data.write(to:url,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o400],ofItemAtPath:url.path)
            let window=NSWindow(contentRect:NSRect(x:0,y:0,width:760,height:720),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
            let view: NSView
            let ext=URL(fileURLWithPath:name).pathExtension.lowercased()
            if ["docx","doc","rtf"].contains(ext) {
                if ext=="docx" { _ = try BuddyOfficeZip(data) }
                let type:NSAttributedString.DocumentType=ext=="docx" ? .officeOpenXML:ext=="rtf" ? .rtf:.docFormat
                let rich=try NSAttributedString(data:data,options:[.documentType:type],documentAttributes:nil)
                let scroll=NSScrollView(frame:NSRect(x:0,y:0,width:760,height:720));scroll.hasVerticalScroller=true;scroll.autoresizingMask=[.width,.height]
                let text=NSTextView(frame:NSRect(x:0,y:0,width:740,height:720));text.isEditable=false;text.isRichText=true;text.usesAdaptiveColorMappingForDarkAppearance=true;text.isVerticallyResizable=true;text.isHorizontallyResizable=false;text.autoresizingMask=[.width];text.textContainerInset=NSSize(width:36,height:36);text.textContainer?.widthTracksTextView=true;text.textContainer?.containerSize=NSSize(width:668,height:CGFloat.greatestFiniteMagnitude);text.textStorage?.setAttributedString(rich);scroll.documentView=text;view=scroll
            } else {
                guard let preview=QLPreviewView(frame:NSRect(x:0,y:0,width:760,height:720),style:.normal) else { throw BuddyFileFailure(code:"preview_unavailable",message:"macOS couldn’t open a full preview for this file.") }
                preview.shouldCloseWithWindow=false;preview.autostarts=false;preview.autoresizingMask=[.width,.height];preview.previewItem=url as NSURL;view=preview
            }
            window.title=URL(fileURLWithPath:name).lastPathComponent+" · Buddy preview";window.contentView=view;window.isReleasedWhenClosed=false;window.delegate=self
            previews[ObjectIdentifier(window)]=(window,view,directory);window.center();window.makeKeyAndOrderFront(nil)
        } catch { try? FileManager.default.removeItem(at:directory);throw error }
    }
    func windowWillClose(_ notification: Notification) {
        guard let window=notification.object as? NSWindow,let entry=previews.removeValue(forKey:ObjectIdentifier(window)) else {return}
        if let preview=entry.1 as? QLPreviewView { preview.previewItem=nil;preview.close() };try? FileManager.default.removeItem(at:entry.2)
    }
}
