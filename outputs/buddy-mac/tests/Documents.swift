import Foundation
import AppKit
import PDFKit
@main struct DocumentChecks {
    @MainActor static func main() throws {
        func check(_ condition: @autoclosure () throws -> Bool,_ label:String) rethrows { if try !condition(){fatalError(label)} }
        func reject(_ body:()throws->Void){do{try body();fatalError("Expected rejection")}catch{}}
        _ = NSApplication.shared
        let fm=FileManager.default,base=URL(fileURLWithPath:CommandLine.arguments.count>1 ? CommandLine.arguments[1]:NSTemporaryDirectory()+"buddy-documents-"+UUID().uuidString)
        try fm.createDirectory(at:base,withIntermediateDirectories:true)
        let workspace=UUID().uuidString,files=BuddyProjectFiles(support:base),scope=try files.scope(workspace),root=try files.location(scope)
        func create(_ name:String,_ spec:[String:Any])throws{_ = try files.document(scope,path:name,expectedVersion:"",specification:spec,operations:nil,actor:"test",actorName:"Check")}
        func edit(_ name:String,_ ops:[[String:Any]])throws{let read=try files.read(scope,path:name);_ = try files.document(scope,path:name,expectedVersion:read["version"] as! String,specification:nil,operations:ops,actor:"test",actorName:"Check")}
        try create("brief.docx",["paragraphs":["Buddy document check","First paragraph","Keep this unchanged."]])
        let oldWord=try files.readBytes(scope,path:"brief.docx"),oldRead=try files.read(scope,path:"brief.docx")
        var zip=try BuddyOfficeZip(oldWord);zip.set("word/styles.xml",Data("<styles xmlns=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><style styleId=\"Original\"/></styles>".utf8));zip.set("word/media/image1.png",Data([1,2,3,4]));try zip.encoded().write(to:root.appendingPathComponent("brief.docx"))
        let originalMedia=try zip.part("word/media/image1.png"),originalStyles=try zip.part("word/styles.xml")
        try edit("brief.docx",[["op":"replace_paragraph","paragraph":1,"text":"Updated paragraph & preserved parts."],["op":"append_paragraph","text":"Added by Buddy."]])
        let after=try files.readBytes(scope,path:"brief.docx"),savedZip=try BuddyOfficeZip(after)
        try check(savedZip.part("word/media/image1.png")==originalMedia,"Word media preserved");try check(savedZip.part("word/styles.xml")==originalStyles,"Word styles preserved")
        try check((files.read(scope,path:"brief.docx")["content"] as! String).contains("Updated paragraph & preserved parts."),"Word edit roundtrip")
        reject{_ = try files.document(scope,path:"brief.docx",expectedVersion:oldRead["version"] as! String,specification:nil,operations:[["op":"replace_paragraph","paragraph":1,"text":"Stale overwrite"]],actor:"other",actorName:"Other")}
        let revisions=try files.versions(scope,path:"brief.docx"),revision=revisions[0]["id"] as! String
        _ = try files.restore(scope,path:"brief.docx",receiptId:revision,expectedVersion:BuddyProjectFiles.hash(after))
        try check(files.readBytes(scope,path:"brief.docx")==zip.encoded(),"Word binary restore exact")
        try edit("brief.docx",[["op":"replace_paragraph","paragraph":1,"text":"Updated paragraph & preserved parts."]])
        var protected=try BuddyOfficeZip(files.readBytes(scope,path:"brief.docx"));protected.set("word/settings.xml",Data("<w:settings xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:documentProtection w:enforcement=\"1\"/></w:settings>".utf8));try protected.encoded().write(to:root.appendingPathComponent("protected.docx"));reject{try edit("protected.docx",[["op":"replace_paragraph","paragraph":0,"text":"No"]])}
        print("PASS: Word creation, targeted edits, media/style preservation, conflict checks, protection, exact binary restoration")
        try create("budget.xlsx",["sheets":[["name":"Budget","cells":["A1":"Item","B1":"Amount","A2":"Hosting","B2":25,"A3":"Design","B3":75,"A4":"Total","B4":"=SUM(B2:B3)"]],["name":"Notes","cells":["A1":"Other sheet retained"]]]])
        var excel=try BuddyOfficeZip(files.readBytes(scope,path:"budget.xlsx"));let sheet=try BuddyDocuments.xml(excel.part("xl/worksheets/sheet1.xml"));let cell=try BuddyDocuments.nodes(sheet,"c").first{BuddyDocuments.attr($0,"r")=="B2"}!;cell.addAttribute(XMLNode.attribute(withName:"s",stringValue:"0") as! XMLNode);excel.set("xl/worksheets/sheet1.xml",sheet.xmlData);excel.set("xl/styles.xml",Data("<styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><fonts count=\"1\"><font/></fonts><fills count=\"1\"><fill><patternFill patternType=\"none\"/></fill></fills><borders count=\"1\"><border/></borders><cellXfs count=\"1\"><xf/></cellXfs></styleSheet>".utf8));try excel.encoded().write(to:root.appendingPathComponent("budget.xlsx"))
        try edit("budget.xlsx",[["op":"set_cell","sheet":"Budget","cell":"B2","value":50],["op":"set_cell","sheet":"Budget","cell":"C2","value":true],["op":"set_cell","sheet":"Budget","cell":"B4","value":"=SUM(B2:B3)"]])
        let readExcel=try files.read(scope,path:"budget.xlsx"),sheetList=readExcel["sheets"] as! [[String:Any]],cells=sheetList[0]["cells"] as! [[String:Any]]
        try check(cells.first{$0["cell"] as? String=="B2"}?["value"] as? String=="50","Excel number roundtrip");try check(cells.first{$0["cell"] as? String=="C2"}?["value"] as? String=="TRUE","Excel boolean roundtrip")
        try check(cells.first{$0["cell"] as? String=="B4"}?["formula"] as? String=="SUM(B2:B3)","Formula saved")
        let resultExcel=try BuddyOfficeZip(files.readBytes(scope,path:"budget.xlsx"));try check(resultExcel.part("xl/styles.xml")==excel.part("xl/styles.xml"),"Excel styles unchanged");try check(resultExcel.part("xl/worksheets/sheet2.xml")==excel.part("xl/worksheets/sheet2.xml"),"Other sheet retained")
        reject{try edit("budget.xlsx",[["op":"set_cell","sheet":"Budget","cell":"ZZZ9999999","value":1]])}
        print("PASS: Excel creation, text/number/boolean/formula edits, untouched styles/sheets, bounded addresses")
        try create("brief.pdf",["pages":["Buddy PDF check\n\nThis page was created by Buddy.\nOriginal text remains searchable."]])
        try check((files.read(scope,path:"brief.pdf")["pages"] as! [[String:Any]])[0]["text"] as? String != "","PDF has actual selectable text")
        let pdf=try BuddyDocuments.pdf(files.readBytes(scope,path:"brief.pdf")),page=pdf.page(at:0)!,field=PDFAnnotation(bounds:CGRect(x:54,y:600,width:250,height:30),forType:.widget,withProperties:nil);field.widgetFieldType = .text;field.fieldName="Name";field.widgetStringValue="Before";page.addAnnotation(field);try pdf.dataRepresentation()!.write(to:root.appendingPathComponent("brief.pdf"))
        try edit("brief.pdf",[["op":"set_field","page":1,"field":"Name","text":"Buddy"],["op":"add_text","page":1,"text":"Reviewed by Buddy","x":54,"y":210,"width":300,"height":60],["op":"append_page","text":"Second page"],["op":"rotate_page","page":2,"degrees":90]])
        let pdfRead=try files.preview(scope,path:"brief.pdf",page:2);try check(pdfRead["pageCount"] as? Int==2,"PDF append");try check(pdfRead["image"] is String,"PDF rendered preview");try check((pdfRead["fields"] as! [[String:Any]])[0]["value"] as? String=="Buddy","PDF form field roundtrip")
        let finalPDF=try BuddyDocuments.pdf(files.readBytes(scope,path:"brief.pdf"));try check(finalPDF.page(at:0)?.annotations.contains{$0.contents=="Reviewed by Buddy"}==true,"PDF annotation retained")
        let protectedPDF=try BuddyDocuments.pdf(files.readBytes(scope,path:"brief.pdf"));protectedPDF.page(at:0)!.annotations.first{$0.fieldName=="Name"}!.isReadOnly=true
        try protectedPDF.dataRepresentation()!.write(to:root.appendingPathComponent("protected-form.pdf"))
        let beforeProtected=try files.readBytes(scope,path:"protected-form.pdf")
        reject{try edit("protected-form.pdf",[["op":"set_field","page":1,"field":"Name","text":"Blocked"]])}
        try check(files.readBytes(scope,path:"protected-form.pdf")==beforeProtected,"Read-only form field is preserved")
        reject{try edit("brief.pdf",[["op":"add_text","page":1,"text":"Bad bounds","x":-10,"y":0]])}
        let signed=try files.readBytes(scope,path:"brief.pdf")+Data("\n% /ByteRange test signature marker".utf8);try signed.write(to:root.appendingPathComponent("signed.pdf"));reject{try edit("signed.pdf",[["op":"append_page","text":"Do not change"]])}
        print("PASS: PDF creation, actual text, form edits, annotations, page append/rotation, image previews, signed-file protection")
        _ = try files.call(scope,tool:"buddy_write_binary_file",arguments:["path":"custom.bin","expectedVersion":"","base64":Data([0,255,1,2]).base64EncodedString()],actor:"test",actorName:"Check")
        let binary=try files.call(scope,tool:"buddy_read_binary_file",arguments:["path":"custom.bin"],actor:"test",actorName:"Check");try check(binary["base64"] as? String==Data([0,255,1,2]).base64EncodedString(),"Arbitrary bytes preserved")
        reject{_ = try files.write(scope,path:"fake.docx",content:"Not an Office document",expectedVersion:"",actor:"test",actorName:"Check")}
        reject{_ = try BuddyDocuments.xml(Data("<!DOCTYPE a [<!ENTITY b SYSTEM 'file:///etc/passwd'>]><a>&b;</a>".utf8))}
        let table=try BuddyDocuments.create(path:"table.docx",specification:["paragraphs":["Header"],"tables":[[["Task","Owner"],["Review","Chief"]]]])
        let tableEdited=try BuddyDocuments.edit(table,path:"table.docx",operations:[["op":"replace_paragraph","paragraph":2,"text":"Assigned"]])
        let tableRead=try BuddyDocuments.word(tableEdited),texts=(tableRead["paragraphs"] as! [[String:Any]]).map{$0["text"] as! String}
        check(texts==["Header","Task","Assigned","Review","Chief"],"Editing one table cell never alters siblings or other rows")
        check((tableRead["blocks"] as! [[String:Any]]).count==2,"Word preview table topology")
        print("PASS: table paragraph boundaries and preview row/column structure")
        print("Fixtures: \(root.path)")
    }
}
