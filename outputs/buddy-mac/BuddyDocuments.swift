import Foundation
import AppKit
import PDFKit
import zlib

// Office packages are edited in place at the part level. Untouched ZIP entries,
// including styles, media and relationships, keep their original compressed bytes.
struct BuddyOfficeZip {
    struct Entry { var name: String; var compressed: Data; var method: UInt16; var crc: UInt32; var size: UInt32 }
    var entries: [Entry] = []
    static func fail(_ message: String) -> BuddyFileFailure { BuddyFileFailure(code: "document_format", message: message) }
    init(parts: [String: String]) { entries = parts.sorted{$0.key < $1.key}.map { Self.stored($0.key, Data($0.value.utf8)) } }
    init(_ data: Data) throws {
        func number(_ offset: Int, _ length: Int) throws -> UInt32 {
            guard offset >= 0, offset + length <= data.count else { throw Self.fail("The Office file is incomplete.") }
            return (0..<length).reduce(0) { $0 | UInt32(data[offset+$1]) << ($1*8) }
        }
        var foundEnd: Int?
        if data.count >= 22 {
            for index in stride(from:data.count-22,through:max(0,data.count-65557),by:-1) {
                if (try? number(index,4)) == 0x06054b50, (try? number(index+20,2)) == UInt32(data.count-index-22) { foundEnd=index; break }
            }
        }
        guard let end=foundEnd else { throw Self.fail("This isn’t a supported Office package.") }
        let count = Int(try number(end+10,2)), central = Int(try number(end+16,4))
        guard try number(end+4,2) == 0, try number(end+6,2) == 0, count > 0, count <= 3000, central < end else { throw Self.fail("Split or oversized Office packages aren’t supported.") }
        var offset = central, total: UInt64 = 0, names = Set<String>()
        for _ in 0..<count {
            guard try number(offset,4) == 0x02014b50 else { throw Self.fail("The Office directory is damaged.") }
            let flags = try number(offset+8,2), method = try number(offset+10,2), crc = try number(offset+16,4), packed = Int(try number(offset+20,4)), size = try number(offset+24,4)
            let nl = Int(try number(offset+28,2)), extra = Int(try number(offset+30,2)), comment = Int(try number(offset+32,2)), local = Int(try number(offset+42,4))
            guard nl > 0, offset+46+nl+extra+comment <= end, let name = String(data:data.subdata(in:offset+46..<offset+46+nl),encoding:.utf8), !name.hasPrefix("/"), !name.contains("\\"), !name.split(separator:"/").contains(".."), names.insert(name).inserted, flags & 1 == 0, [0,8].contains(method), size <= 20*1024*1024 else { throw Self.fail("This package has unsupported or unsafe entries.") }
            total += UInt64(size); guard total <= 80*1024*1024 else { throw Self.fail("The expanded Office package is too large.") }
            guard try number(local,4) == 0x04034b50 else { throw Self.fail("The Office file is damaged.") }
            let start = local+30+Int(try number(local+26,2))+Int(try number(local+28,2))
            guard start >= 0, packed >= 0, start+packed <= central else { throw Self.fail("The Office file is damaged.") }
            entries.append(Entry(name:name,compressed:data.subdata(in:start..<start+packed),method:UInt16(method),crc:crc,size:size))
            offset += 46+nl+extra+comment
        }
    }
    static func checksum(_ data: Data) -> UInt32 { data.withUnsafeBytes { UInt32(crc32(0,$0.bindMemory(to:Bytef.self).baseAddress,uInt(data.count))) } }
    static func stored(_ name: String, _ data: Data) -> Entry { Entry(name:name,compressed:data,method:0,crc:checksum(data),size:UInt32(data.count)) }
    func part(_ name: String) throws -> Data {
        guard let entry = entries.first(where:{$0.name == name}), entry.size <= 8*1024*1024 else { throw Self.fail("A required document part is missing or too large: \(name)") }
        let result: Data
        if entry.method == 0 { result = entry.compressed }
        else {
            var stream = z_stream(), output = Data(count:max(1,Int(entry.size)))
            guard inflateInit2_(&stream,-MAX_WBITS,ZLIB_VERSION,Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw Self.fail("Couldn’t read the compressed document.") }
            defer { inflateEnd(&stream) }
            let code = entry.compressed.withUnsafeBytes { input in output.withUnsafeMutableBytes { out in
                stream.next_in = UnsafeMutablePointer(mutating:input.bindMemory(to:Bytef.self).baseAddress); stream.avail_in = uInt(input.count)
                stream.next_out = out.bindMemory(to:Bytef.self).baseAddress; stream.avail_out = uInt(out.count)
                return inflate(&stream,Z_FINISH)
            } }
            guard code == Z_STREAM_END, stream.total_out == entry.size else { throw Self.fail("A document part could not be verified.") }; result = output.prefix(Int(entry.size))
        }
        guard result.count == entry.size, Self.checksum(result) == entry.crc else { throw Self.fail("A document part failed its integrity check.") }
        return result
    }
    mutating func set(_ name: String, _ data: Data) { if let i=entries.firstIndex(where:{$0.name==name}) { entries[i]=Self.stored(name,data) } else { entries.append(Self.stored(name,data)) } }
    func encoded() -> Data {
        var data=Data(), directory=Data()
        func put(_ target: inout Data, _ number: UInt32, _ width: Int) { for i in 0..<width { target.append(UInt8(truncatingIfNeeded:number >> (i*8))) } }
        for e in entries {
            let offset=UInt32(data.count), name=Data(e.name.utf8)
            for (v,w) in [(UInt32(0x04034b50),4),(20,2),(0x800,2),(UInt32(e.method),2),(0,2),(0,2),(e.crc,4),(UInt32(e.compressed.count),4),(e.size,4),(UInt32(name.count),2),(0,2)] { put(&data,v,w) }
            data.append(name); data.append(e.compressed)
            for (v,w) in [(UInt32(0x02014b50),4),(20,2),(20,2),(0x800,2),(UInt32(e.method),2),(0,2),(0,2),(e.crc,4),(UInt32(e.compressed.count),4),(e.size,4),(UInt32(name.count),2),(0,2),(0,2),(0,2),(0,2),(0,4),(offset,4)] { put(&directory,v,w) }
            directory.append(name)
        }
        let offset=UInt32(data.count); data.append(directory)
        for (v,w) in [(UInt32(0x06054b50),4),(0,2),(0,2),(UInt32(entries.count),2),(UInt32(entries.count),2),(UInt32(directory.count),4),(offset,4),(0,2)] { put(&data,v,w) }
        return data
    }
}

@MainActor enum BuddyDocuments {
    /// The largest UTF-8 text file Buddy reads or writes as text (an agent reads one a page at a time: BuddyProjectFiles.readPage).
    static let maximumTextBytes = 10 * 1024 * 1024
    static func fail(_ message: String) -> BuddyFileFailure { BuddyFileFailure(code:"document_edit",message:message) }
    static func xml(_ data: Data) throws -> XMLDocument {
        guard !String(decoding:data,as:UTF8.self).replacingOccurrences(of:"\0",with:"").uppercased().contains("<!DOCTYPE"), !String(decoding:data,as:UTF8.self).replacingOccurrences(of:"\0",with:"").uppercased().contains("<!ENTITY") else { throw fail("Documents with external XML entities aren’t supported.") }
        return try XMLDocument(data:data,options:[.nodePreserveAll,.nodeLoadExternalEntitiesNever])
    }
    static func descendants(_ node: XMLNode) -> [XMLElement] {
        var pending=Array((node.children ?? []).reversed()), result=[XMLElement]()
        while let next=pending.popLast() { if let element=next as? XMLElement { result.append(element) }; pending.append(contentsOf:(next.children ?? []).reversed()) }
        return result
    }
    static func nodes(_ node: XMLNode, _ name: String) throws -> [XMLElement] { descendants(node).filter{$0.localName==name} }
    static func attr(_ e: XMLElement, _ name: String) -> String? { e.attributes?.first{$0.localName==name}?.stringValue }
    static func escape(_ s: String) -> String { s.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"<",with:"&lt;").replacingOccurrences(of:">",with:"&gt;").replacingOccurrences(of:"\"",with:"&quot;") }
    static func office(_ data: Data) throws -> BuddyOfficeZip { let zip=try BuddyOfficeZip(data); guard !zip.entries.contains(where:{$0.name.hasPrefix("_xmlsignatures/")}) else { throw fail("Signed Office documents are preserved. Save an unsigned copy before editing.") }; return zip }
    static func wordParagraphs(_ doc: XMLDocument) throws -> [XMLElement] { guard let body=try nodes(doc,"body").first else { throw fail("Word document body is missing.") }; return try nodes(body,"p") }
    static func paragraphText(_ p: XMLElement) throws -> String { descendants(p).filter{["t","tab","br"].contains($0.localName ?? "")}.map { $0.localName=="tab" ? "\t" : $0.localName=="br" ? "\n" : $0.stringValue ?? "" }.joined() }
    static func word(_ data: Data) throws -> [String:Any] {
        let zip=try BuddyOfficeZip(data), doc=try xml(zip.part("word/document.xml")), paragraphs=try wordParagraphs(doc)
        guard paragraphs.count <= 10000 else { throw fail("This document has too many paragraphs for Buddy’s reading view.") }
        let items=try paragraphs.enumerated().map { index,p -> [String:Any] in ["id":index,"text":try paragraphText(p),"style":try nodes(p,"pStyle").first.flatMap{attr($0,"val")} ?? "Normal", "inTable":p.parent?.localName == "tc"] }
        let ids=Dictionary(uniqueKeysWithValues:paragraphs.enumerated().map{($0.element.xPath ?? "",$0.offset)})
        var blocks=[[String:Any]]()
        for child in try nodes(doc,"body").first?.children ?? [] {
            if child.localName=="p",let id=ids[child.xPath ?? ""] { blocks.append(["type":"paragraph","id":id]) }
            if child.localName=="tbl" {
                let rows=(child.children ?? []).filter{$0.localName=="tr"}.map{row in (row.children ?? []).filter{$0.localName=="tc"}.map{cell in descendants(cell).filter{$0.localName=="p"}.compactMap{ids[$0.xPath ?? ""]}}}
                blocks.append(["type":"table","rows":rows])
            }
        }
        return ["format":"docx","editable":!zip.entries.contains{$0.name.hasPrefix("_xmlsignatures/")},"paragraphs":items,"blocks":blocks,"content":items.map{$0["text"] as! String}.joined(separator:"\n"),"notice":"Reading view. Original layout, images and styles are kept in the file."]
    }
    static func sheetParts(_ zip: BuddyOfficeZip) throws -> [(String,String)] {
        let workbook=try xml(zip.part("xl/workbook.xml")), relationships=try xml(zip.part("xl/_rels/workbook.xml.rels"))
        return try nodes(workbook,"sheet").map { sheet in
            guard let id=attr(sheet,"id"), let rel=try nodes(relationships,"Relationship").first(where:{attr($0,"Id")==id}), let target=attr(rel,"Target"), attr(rel,"TargetMode") != "External" else { throw fail("A sheet relationship is unavailable.") }
            let path=target.hasPrefix("/") ? String(target.dropFirst()) : "xl/"+target
            guard !path.split(separator:"/").contains(".."), path.hasPrefix("xl/"), zip.entries.contains(where:{$0.name==path}) else { throw fail("This workbook has an unsupported sheet relationship.") }
            return (attr(sheet,"name") ?? "Sheet",path)
        }
    }
    static func excel(_ data: Data) throws -> [String:Any] {
        let zip=try BuddyOfficeZip(data), parts=try sheetParts(zip)
        let strings: [String] = zip.entries.contains{$0.name=="xl/sharedStrings.xml"} ? try nodes(xml(zip.part("xl/sharedStrings.xml")),"si").map{try nodes($0,"t").map{$0.stringValue ?? ""}.joined()} : []
        var sheets=[[String:Any]]()
        for (name,path) in parts {
            let doc=try xml(zip.part(path)), cells=try nodes(doc,"c")
            let shown=try cells.prefix(5000).map { c -> [String:Any] in
                let raw=try nodes(c,"v").first?.stringValue ?? "", type=attr(c,"t") ?? "n", formula=try nodes(c,"f").first?.stringValue
                let value=type=="s" ? Int(raw).flatMap{strings.indices.contains($0) ? strings[$0] : nil} ?? raw : type=="inlineStr" ? try nodes(c,"t").map{$0.stringValue ?? ""}.joined() : type=="b" ? (raw=="1" ? "TRUE":"FALSE") : raw
                var item:[String:Any]=["cell":attr(c,"r") ?? "","value":value,"type":type]
                if let formula { item["formula"]=formula; item["cached"] = !raw.isEmpty }
                return item
            }
            sheets.append(["name":name,"cells":shown,"limited":cells.count>5000])
        }
        return ["format":"xlsx","editable":!zip.entries.contains{$0.name.hasPrefix("_xmlsignatures/")},"sheets":sheets,"notice":"Formula results use the workbook’s saved values. Excel recalculates changed formulas when you open it."]
    }
    static func pdf(_ data: Data) throws -> PDFDocument { guard let doc=PDFDocument(data:data), !doc.isLocked else { throw fail("This PDF is locked or could not be read. Unlock a copy before editing.") }; guard doc.pageCount<=1000 else { throw fail("This PDF has too many pages.") }; return doc }
    static func signed(_ doc: PDFDocument, _ data: Data) -> Bool { data.range(of:Data("/ByteRange".utf8)) != nil || (0..<doc.pageCount).contains{doc.page(at:$0)?.annotations.contains{$0.widgetFieldType == .signature} == true} }
    static func pdfRead(_ data: Data, previewPage: Int? = nil) throws -> [String:Any] {
        let doc=try pdf(data), isSigned=signed(doc,data)
        var result:[String:Any]=["format":"pdf","editable":!isSigned && (doc.allowsCommenting || doc.allowsFormFieldEntry || doc.allowsDocumentChanges),"pageCount":doc.pageCount,"pages":(0..<min(doc.pageCount,100)).map{["page":$0+1,"text":String((doc.page(at:$0)?.string ?? "").prefix(8000))]},"fields":(0..<doc.pageCount).flatMap{index -> [[String:Any]] in (doc.page(at:index)?.annotations ?? []).filter{$0.fieldName != nil}.map{["page":index+1,"name":$0.fieldName ?? "","value":$0.widgetStringValue ?? "","type":$0.widgetFieldType.rawValue]}},"notice":isSigned ? "Signed PDF. Preview only; editing would invalidate its signature." : "Fill forms, add text or highlights, rotate pages, and append pages. Existing printed text is preserved."]
        if let selected=previewPage, let page=doc.page(at:max(0,min(doc.pageCount-1,selected-1))) {
            let thumb=page.thumbnail(of:NSSize(width:1000,height:1400),for:.mediaBox)
            if let tiff=thumb.tiffRepresentation, let bitmap=NSBitmapImageRep(data:tiff), let png=bitmap.representation(using:.png,properties:[:]) { result["image"]="data:image/png;base64,"+png.base64EncodedString() }
            result["previewPage"]=max(1,min(doc.pageCount,selected))
        }
        return result
    }
    static func read(_ data: Data, path: String, preview: Bool=false, page: Int=1) throws -> [String:Any] {
        let ext=URL(fileURLWithPath:path).pathExtension.lowercased()
        switch ext {
        case "docx": return try word(data)
        case "xlsx": return try excel(data)
        case "pdf": return try pdfRead(data,previewPage:preview ? page : nil)
        default:
            if data.count<=maximumTextBytes, !data.contains(0), let text=String(data:data,encoding:.utf8) { return ["format":"text","content":text,"editable":true] }
            var result:[String:Any]=["format":"binary","editable":false,"notice":"Ask your agent to work with this format, or open it in its usual app. Buddy preserves the original bytes."]
            // Say what the file is. A big spreadsheet export is text, not an unknown format, and a coding session can work on it.
            if !data.contains(0), data.count>maximumTextBytes, String(data:data,encoding:.utf8) != nil {
                result["notice"]=String(format:"This is a text file of %.1f MB. Buddy reads and writes text files up to 10 MB, so ask an agent to work on it in a coding session: it copies the file into its project and runs commands on it. Buddy preserves the original bytes.",Double(data.count)/1_048_576)
            } else if !data.contains(0), String(data:data,encoding:.utf8) == nil {
                result["notice"]="This looks like text in an encoding other than UTF-8. Ask an agent to read it in a coding session, which can convert it. Buddy preserves the original bytes."
            }
            if preview, ["png","jpg","jpeg","gif","webp","heic","tiff","bmp"].contains(ext), let image=NSImage(data:data) {
                let scale=min(1,1200/max(image.size.width,image.size.height)), size=NSSize(width:max(1,image.size.width*scale),height:max(1,image.size.height*scale))
                let thumb=NSImage(size:size); thumb.lockFocus(); image.draw(in:NSRect(origin:.zero,size:size)); thumb.unlockFocus()
                if let tiff=thumb.tiffRepresentation, let bitmap=NSBitmapImageRep(data:tiff), let png=bitmap.representation(using:.png,properties:[:]) { result["image"]="data:image/png;base64,"+png.base64EncodedString(); result["format"]="image" }
            }
            return result
        }
    }
    static func create(path: String, specification: [String:Any]) throws -> Data {
        let ext=URL(fileURLWithPath:path).pathExtension.lowercased()
        if ext=="docx" {
            let paragraphs=specification["paragraphs"] as? [Any] ?? (specification["text"] as? String ?? "").components(separatedBy:"\n")
            guard paragraphs.count<=5000 else { throw fail("Use at most 5,000 paragraphs.") }
            var body=""
            for value in paragraphs {
                let options=value as? [String:Any] ?? [:],style=options["style"] as? String ?? "Normal"
                guard let text=value as? String ?? options["text"] as? String else { throw fail("Each Word paragraph needs text.") }
                guard ["Normal","Title","Heading1","Heading2","Heading3"].contains(style) else { throw fail("Word paragraph styles are Normal, Title, Heading1, Heading2, or Heading3.") }
                let formatting=(options["bold"] as? Bool == true ? "<w:b/>":"")+(options["italic"] as? Bool == true ? "<w:i/>":"")
                body += "<w:p><w:pPr><w:pStyle w:val=\"\(style)\"/></w:pPr><w:r><w:rPr>\(formatting)</w:rPr><w:t xml:space=\"preserve\">\(escape(text))</w:t></w:r></w:p>"
            }
            for table in specification["tables"] as? [[[String]]] ?? [] {
                guard table.count<=500,table.allSatisfy({$0.count<=30}) else {throw fail("Use tables with up to 500 rows and 30 columns.")}
                let borders=["top","left","bottom","right","insideH","insideV"].map{"<w:\($0) w:val=\"single\" w:sz=\"4\" w:color=\"DAD6E0\"/>"}.joined()
                var rows=""
                for row in table { rows += "<w:tr>"; for text in row { rows += "<w:tc><w:p><w:r><w:t xml:space=\"preserve\">\(escape(text))</w:t></w:r></w:p></w:tc>" }; rows += "</w:tr>" }
                let columns=table.map{$0.count}.max() ?? 1
                let grid="<w:tblGrid>"+Array(repeating:"<w:gridCol w:w=\"\(9360/max(1,columns))\"/>",count:columns).joined()+"</w:tblGrid>"
                body += "<w:tbl><w:tblPr><w:tblBorders>"+borders+"</w:tblBorders></w:tblPr>"+grid+rows+"</w:tbl>"
            }
            let styles="<w:styles xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii=\"Calibri\" w:hAnsi=\"Calibri\"/><w:sz w:val=\"22\"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after=\"160\"/></w:pPr></w:pPrDefault></w:docDefaults>"+[("Normal",22),("Title",48),("Heading1",32),("Heading2",28),("Heading3",24)].map{name,size in "<w:style w:type=\"paragraph\" w:styleId=\"\(name)\"><w:name w:val=\"\(name)\"/><w:pPr>\(name=="Normal" ? "":"<w:keepNext/>")<w:spacing w:before=\"\(name=="Normal" ? 0:240)\" w:after=\"120\"/></w:pPr><w:rPr><w:sz w:val=\"\(size)\"/>\(name=="Normal" ? "":"<w:b/>")</w:rPr></w:style>"}.joined()+"</w:styles>"
            return BuddyOfficeZip(parts:["[Content_Types].xml":"<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/><Override PartName=\"/word/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml\"/></Types>","_rels/.rels":"<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>","word/_rels/document.xml.rels":"<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/></Relationships>","word/styles.xml":styles,"word/document.xml":"<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body>"+body+"<w:sectPr><w:pgSz w:w=\"12240\" w:h=\"15840\"/><w:pgMar w:top=\"1440\" w:right=\"1440\" w:bottom=\"1440\" w:left=\"1440\"/></w:sectPr></w:body></w:document>"]).encoded()
        }

        if ext=="xlsx" {
            let sheets=specification["sheets"] as? [[String:Any]] ?? [["name":"Sheet1","cells":specification["cells"] as? [String:Any] ?? [:]]]
            guard !sheets.isEmpty, sheets.count<=30 else { throw fail("Use one to thirty sheets.") }
            var names=Set<String>(), parts=[String:String](), content="", workbook="", relations=""
            for (i,sheet) in sheets.enumerated() {
                let name=sheet["name"] as? String ?? "Sheet\(i+1)"
                guard !name.isEmpty, name.count<=31, !name.contains(where:{"[]:*?/\\".contains($0)}), names.insert(name.lowercased()).inserted else { throw fail("Choose unique Excel sheet names with at most 31 characters.") }
                let cells=sheet["cells"] as? [String:Any] ?? [:]
                let doc=try xml(Data("<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData/></worksheet>".utf8))
                for (ref,value) in cells { try setCell(doc,ref:ref,value:value,clear:false) }
                let path="xl/worksheets/sheet\(i+1).xml"; parts[path]=doc.xmlString
                content += "<Override PartName=\"/\(path)\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
                workbook += "<sheet name=\"\(escape(name))\" sheetId=\"\(i+1)\" r:id=\"rId\(i+1)\"/>"
                relations += "<Relationship Id=\"rId\(i+1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\(i+1).xml\"/>"
            }
            parts["xl/styles.xml"]="<styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><fonts count=\"1\"><font><sz val=\"11\"/><name val=\"Calibri\"/></font></fonts><fills count=\"2\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill></fills><borders count=\"1\"><border/></borders><cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs><cellXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/></cellXfs><cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles></styleSheet>"
            content += "<Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>"
            relations += "<Relationship Id=\"rStyles\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>"
            parts["[Content_Types].xml"]="<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>\(content)</Types>"
            parts["_rels/.rels"]="<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>"
            parts["xl/workbook.xml"]="<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets>\(workbook)</sheets><calcPr calcId=\"0\" fullCalcOnLoad=\"1\" forceFullCalc=\"1\"/></workbook>"
            parts["xl/_rels/workbook.xml.rels"]="<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(relations)</Relationships>"
            return BuddyOfficeZip(parts:parts).encoded()
        }
        if ext=="pdf" { return try makePDF(specification["pages"] as? [String] ?? [specification["text"] as? String ?? ""]) }
        throw fail("Use buddy_write_file for text, Markdown, HTML, CSV and code, or buddy_write_binary_file for other formats.")
    }
    static func cellPosition(_ ref: String) throws -> (Int,Int) {
        guard ref.range(of:"^[A-Z]{1,3}[1-9][0-9]{0,6}$",options:.regularExpression) != nil else { throw fail("Use an Excel cell address such as A1.") }
        let letters=ref.prefix{$0.isLetter}, column=letters.utf8.reduce(0){$0*26+Int($1)-64}, row=Int(ref.dropFirst(letters.count))!
        guard column<=16384,row<=1048576 else { throw fail("The cell is outside Excel’s sheet limits.") }; return (row,column)
    }
    static func setCell(_ doc: XMLDocument, ref: String, value: Any, clear: Bool) throws {
        let (row,col)=try cellPosition(ref)
        guard let sheetData=try nodes(doc,"sheetData").first else { throw fail("This sheet cannot be edited.") }
        var rowNode=sheetData.children?.compactMap{$0 as? XMLElement}.first{attr($0,"r")==String(row)}
        if rowNode==nil { let new=XMLElement(name:"row"); new.addAttribute(XMLNode.attribute(withName:"r",stringValue:String(row)) as! XMLNode); let index=sheetData.children?.firstIndex{Int(($0 as? XMLElement).flatMap{attr($0,"r")} ?? "0") ?? 0 > row} ?? sheetData.childCount; sheetData.insertChild(new,at:index); rowNode=new }
        let existing=rowNode!.children?.compactMap{$0 as? XMLElement}.first{attr($0,"r")==ref}
        if let existing, try nodes(existing,"f").contains(where:{["shared","array","dataTable"].contains(attr($0,"t") ?? "")}) { throw fail("Shared, array and data-table formula cells must be edited in Excel.") }
        let cell=existing ?? XMLElement(name:"c")
        if existing==nil { cell.addAttribute(XMLNode.attribute(withName:"r",stringValue:ref) as! XMLNode); let index=rowNode!.children?.firstIndex{(try? cellPosition(($0 as? XMLElement).flatMap{attr($0,"r")} ?? ""))?.1 ?? 0 > col} ?? rowNode!.childCount; rowNode!.insertChild(cell,at:index) }
        for child in cell.children ?? [] where ["v","f","is"].contains(child.localName ?? "") { child.detach() }; cell.removeAttribute(forName:"t")
        if !clear {
            let node:XMLElement
            if let number=value as? NSNumber { cell.addAttribute(XMLNode.attribute(withName:"t",stringValue:CFGetTypeID(number)==CFBooleanGetTypeID() ? "b":"n") as! XMLNode); node=XMLElement(name:"v",stringValue:number.stringValue) }
            else if let text=value as? String {
                guard text.count<=32767 else { throw fail("Excel cells support at most 32,767 characters.") }
                if text.hasPrefix("=") { node=XMLElement(name:"f",stringValue:String(text.dropFirst())) }
                else { cell.addAttribute(XMLNode.attribute(withName:"t",stringValue:"inlineStr") as! XMLNode); node=XMLElement(name:"is"); let t=XMLElement(name:"t",stringValue:text); t.addAttribute(XMLNode.attribute(withName:"xml:space",stringValue:"preserve") as! XMLNode); node.addChild(t) }
            } else { throw fail("Cell values must be text, numbers, booleans, or formulas starting with =.") }
            cell.addChild(node)
        }
        for dimension in try nodes(doc,"dimension") { dimension.detach() }
    }
    static func edit(_ data: Data, path: String, operations: [[String:Any]]) throws -> Data {
        guard !operations.isEmpty, operations.count<=2000 else { throw fail("Choose one to 2,000 document changes.") }
        let ext=URL(fileURLWithPath:path).pathExtension.lowercased()
        if ext=="docx" {
            var zip=try office(data); let doc=try xml(zip.part("word/document.xml"))
            if zip.entries.contains(where:{$0.name=="word/settings.xml"}), !(try nodes(xml(zip.part("word/settings.xml")),"documentProtection")).isEmpty { throw fail("Protected Word documents must be unlocked before editing.") }
            for operation in operations {
                let paragraphs=try wordParagraphs(doc)
                guard let op=operation["op"] as? String, let text=operation["text"] as? String, text.utf8.count<=128*1024 else { throw fail("Word changes require an operation and text.") }
                if op=="append_paragraph" {
                    let p=try XMLElement(xmlString:"<w:p xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:r><w:t xml:space=\"preserve\">\(escape(text))</w:t></w:r></w:p>")
                    guard let body=try nodes(doc,"body").first else { throw fail("Word body is missing.") }; let index=body.children?.firstIndex{$0.localName=="sectPr"} ?? body.childCount; body.insertChild(p,at:index)
                } else if op=="replace_paragraph", let index=operation["paragraph"] as? Int, paragraphs.indices.contains(index) {
                    let p=paragraphs[index]
                    guard descendants(p).filter({["drawing","object","fldChar","fldSimple","ins","del","sdt","hyperlink"].contains($0.localName ?? "")}).isEmpty else { throw fail("Paragraph \(index) contains an object, field, or tracked change. Edit it in Word to keep those features.") }
                    let texts=try nodes(p,"t")
                    if let first=texts.first { first.stringValue=text; first.addAttribute(XMLNode.attribute(withName:"xml:space",stringValue:"preserve") as! XMLNode); for t in texts.dropFirst(){t.stringValue=""} }
                    else { let r=XMLElement(name:"w:r"),t=XMLElement(name:"w:t",stringValue:text);r.addChild(t);p.addChild(r) }
                    for n in descendants(p).filter{["tab","br"].contains($0.localName ?? "")} { n.detach() }
                } else { throw fail("Use replace_paragraph with the paragraph ID from the latest read, or append_paragraph.") }
            }
            zip.set("word/document.xml",doc.xmlData); return zip.encoded()
        }
        if ext=="xlsx" {
            var zip=try office(data); let parts=try sheetParts(zip), workbook=try xml(zip.part("xl/workbook.xml"))
            guard try nodes(workbook,"workbookProtection").isEmpty else { throw fail("Unlock this workbook in Excel before editing.") }
            var docs=[String:XMLDocument]()
            for operation in operations {
                guard let op=operation["op"] as? String,["set_cell","clear_cell"].contains(op), let name=operation["sheet"] as? String, let path=parts.first(where:{$0.0==name})?.1, let ref=operation["cell"] as? String else { throw fail("Excel changes require set_cell or clear_cell, the sheet name, and a cell address.") }
                let doc=try docs[path] ?? xml(zip.part(path)); docs[path]=doc
                guard try nodes(doc,"sheetProtection").isEmpty else { throw fail("Unlock this sheet in Excel before editing.") }
                // Never alter a merged follower cell, or a range owned by an array formula.
                let position=try cellPosition(ref)
                for range in try nodes(doc,"mergeCell").compactMap({attr($0,"ref")}) + nodes(doc,"f").filter({attr($0,"t")=="array"}).compactMap({attr($0,"ref")}) {
                    let refs=range.split(separator:":").map(String.init); if refs.count==2, let a=try? cellPosition(refs[0]), let b=try? cellPosition(refs[1]), position.0>=a.0,position.0<=b.0,position.1>=a.1,position.1<=b.1, ref != refs[0] { throw fail("This cell belongs to a merged or array-formula range. Edit its top-left cell or use Excel.") }
                }
                try setCell(doc,ref:ref,value:operation["value"] ?? "",clear:op=="clear_cell")
            }
            // Saved formula values become stale after any edit, including dependencies
            // on other sheets. Clear them and request full recalculation on open.
            for (_,path) in parts {
                let sheet=try docs[path] ?? xml(zip.part(path)); var changed=docs[path] != nil
                for cell in try nodes(sheet,"c") where !(try nodes(cell,"f")).isEmpty { for value in try nodes(cell,"v") { value.detach(); changed=true } }
                if changed { zip.set(path,sheet.xmlData) }
            }
            for calc in try nodes(workbook,"calcPr") { calc.detach() }
            let calc=try XMLElement(xmlString:"<calcPr calcId=\"0\" fullCalcOnLoad=\"1\" forceFullCalc=\"1\"/>");workbook.rootElement()?.addChild(calc);zip.set("xl/workbook.xml",workbook.xmlData)
            zip.entries.removeAll{$0.name=="xl/calcChain.xml"}
            if zip.entries.contains(where:{$0.name=="xl/_rels/workbook.xml.rels"}) { let rels=try xml(zip.part("xl/_rels/workbook.xml.rels"));for r in try nodes(rels,"Relationship") where (attr(r,"Type") ?? "").hasSuffix("/calcChain") {r.detach()};zip.set("xl/_rels/workbook.xml.rels",rels.xmlData) }
            let types=try xml(zip.part("[Content_Types].xml"));for n in try nodes(types,"Override") where attr(n,"PartName")=="/xl/calcChain.xml" {n.detach()};zip.set("[Content_Types].xml",types.xmlData)
            return zip.encoded()
        }
        if ext=="pdf" { return try editPDF(data,operations:operations) }
        throw fail("Use text or binary file tools for this format.")
    }
    static func makePDF(_ pages: [String]) throws -> Data {
        guard !pages.isEmpty,pages.count<=100 else { throw fail("Use one to 100 PDF text pages.") }
        let output=NSMutableData(); guard let consumer=CGDataConsumer(data:output),let context=CGContext(consumer:consumer,mediaBox:nil,nil) else {throw fail("Couldn’t create the PDF.")}
        for text in pages {
            guard text.count<=50000 else {throw fail("Split long PDF text across more pages.")}
            let attributed=NSAttributedString(string:text,attributes:[.font:NSFont.systemFont(ofSize:12),.foregroundColor:NSColor.black]),storage=NSTextStorage(attributedString:attributed),layout=NSLayoutManager();storage.addLayoutManager(layout)
            var start=0
            repeat {
                let container=NSTextContainer(containerSize:NSSize(width:504,height:684));container.lineFragmentPadding=0;layout.addTextContainer(container)
                let range=layout.glyphRange(for:container);var box=CGRect(x:0,y:0,width:612,height:792);context.beginPage(mediaBox:&box)
                context.saveGState();context.translateBy(x:54,y:738);context.scaleBy(x:1,y:-1)
                NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(cgContext:context,flipped:true);layout.drawBackground(forGlyphRange:range,at:.zero);layout.drawGlyphs(forGlyphRange:range,at:.zero);NSGraphicsContext.restoreGraphicsState();context.restoreGState();context.endPage()
                guard range.length>0 || attributed.length==0 else {throw fail("PDF text layout couldn’t fit this content.")};start=NSMaxRange(range)
            } while start<layout.numberOfGlyphs
        }
        context.closePDF();return output as Data
    }
    static func editPDF(_ data: Data, operations:[[String:Any]]) throws -> Data {
        let doc=try pdf(data);guard !signed(doc,data) else {throw fail("Signed PDFs are preserved. Edit an unsigned copy instead.")}
        for op in operations {
            guard let kind=op["op"] as? String else {throw fail("Choose a PDF operation.")}
            if kind=="append_page" {guard doc.allowsDocumentChanges,let text=op["text"] as? String else {throw fail("Appending PDF pages isn’t allowed.")};let more=try pdf(makePDF([text]));for i in 0..<more.pageCount {doc.insert(more.page(at:i)!,at:doc.pageCount)};continue}
            guard let number=op["page"] as? Int,number>=1,number<=doc.pageCount,let page=doc.page(at:number-1) else {throw fail("Choose an existing PDF page (starting at 1).")}
            if kind=="set_field" {
                guard doc.allowsFormFieldEntry,let name=op["field"] as? String,let value=op["text"] as? String,let annotation=page.annotations.first(where:{$0.fieldName==name}) else {throw fail("This editable form field wasn’t found.")}
                guard !annotation.isReadOnly else { throw fail("This PDF field is read-only. Other fields and the file are unchanged.") };guard annotation.widgetFieldType == .text || annotation.widgetFieldType == .choice else {throw fail("Buddy fills text and choice fields. Other widgets stay unchanged.")};annotation.widgetStringValue=value
            } else if kind=="rotate_page" {guard doc.allowsDocumentChanges,let degrees=op["degrees"] as? Int,[0,90,180,270].contains(degrees) else {throw fail("Use rotation 0, 90, 180 or 270.")};page.rotation=degrees}
            else if ["add_text","highlight"].contains(kind) {
                guard doc.allowsCommenting else {throw fail("Annotations are disabled for this PDF.")}
                let bounds=page.bounds(for:.mediaBox),x=(op["x"] as? NSNumber)?.doubleValue ?? 54,y=(op["y"] as? NSNumber)?.doubleValue ?? 54,w=(op["width"] as? NSNumber)?.doubleValue ?? 300,h=(op["height"] as? NSNumber)?.doubleValue ?? 60
                let rect=CGRect(x:x,y:bounds.maxY-y-h,width:w,height:h)
                guard x.isFinite,y.isFinite,w.isFinite,h.isFinite,w>0,h>0,bounds.contains(rect) else {throw fail("Annotation coordinates must fit the page. Use points measured from the top left.")}
                let annotation=PDFAnnotation(bounds:rect,forType:kind=="add_text" ? .freeText:.highlight,withProperties:nil)
                if kind=="add_text" {guard let text=op["text"] as? String,text.count<=10000 else {throw fail("Add text requires text up to 10,000 characters.")};annotation.contents=text;annotation.font=NSFont.systemFont(ofSize:12);annotation.fontColor = .black;annotation.color = .clear;let border=PDFBorder();border.lineWidth=0;annotation.border=border} else {annotation.color=NSColor.systemYellow.withAlphaComponent(0.4)}
                page.addAnnotation(annotation)
            } else {throw fail("Use set_field, add_text, highlight, rotate_page or append_page for PDFs.")}
        }
        guard let result=doc.dataRepresentation() else {throw fail("Couldn’t save the PDF.")};return result
    }
}
