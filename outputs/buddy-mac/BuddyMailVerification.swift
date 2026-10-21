import Foundation

// Deterministic mail parsing: bodies and codes never enter a model request or a saved journal.
enum BuddyMailVerification {
    struct Match { let messageID: String; let code: String }
    static func object(_ result: [String: Any]) throws -> [String: Any] {
        guard result["isError"] as? Bool != true else { throw BuddyFailure(message: "Gmail could not complete the verification lookup.") }
        if let value = result["structuredContent"] as? [String: Any] { return value }
        for item in result["content"] as? [[String: Any]] ?? [] {
            if let text = item["text"] as? String, text.utf8.count <= 256*1024, let data = text.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return value }
        }
        throw BuddyFailure(message: "Gmail returned an unsupported verification response. Continue in private Chrome.")
    }
    static func email(_ value: String) -> Bool { value.range(of: #"^[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}$"#, options: [.regularExpression,.caseInsensitive]) != nil && value.count < 255 }
    static func match(_ messages: [[String: Any]], origin: String, recipient: String, since: Date, excluding: Set<String>, now: Date = Date(), length: Int = 6) throws -> Match {
        guard let url=URL(string:origin),url.scheme=="https",let host=url.host?.lowercased(),email(recipient),(4...8).contains(length),now.timeIntervalSince(since)<600 else { throw BuddyFailure(message:"This email verification permission expired.") }
        var found: [Match] = []
        for message in messages {
            guard let id=message["id"] as? String,!excluding.contains(id),let stamp=message["internalDate"] as? String,let milliseconds=Double(stamp),let payload=message["payload"] as? [String:Any],let headers=payload["headers"] as? [[String:Any]] else { continue }
            let date=Date(timeIntervalSince1970:milliseconds/1000)
            guard date>=since.addingTimeInterval(-60),now.timeIntervalSince(date)<600,date<=now.addingTimeInterval(60) else { continue }
            let header=Dictionary(headers.compactMap { h -> (String,String)? in guard let n=h["name"] as? String,let v=h["value"] as? String else{return nil};return(n.lowercased(),v) },uniquingKeysWith:{$0+" "+$1})
            let from=addresses(header["from"] ?? "")
            guard from.count==1,let sender=from.first,let domain=sender.split(separator:"@").last.map(String.init),domain==host||domain.hasSuffix("."+host),addresses((header["to"] ?? "")+" "+(header["delivered-to"] ?? "")).contains(recipient.lowercased()),!header.keys.contains(where:{$0.hasPrefix("resent-")}) else{continue}
            let auth=headers.first{($0["name"] as? String)?.lowercased()=="authentication-results" && ($0["value"] as? String ?? "").lowercased().hasPrefix("mx.google.com;") }?["value"] as? String ?? ""
            let dmarc=#"(?:^|;)\s*dmarc=pass\b[^;]*\bheader\.from="#+NSRegularExpression.escapedPattern(for:domain)+#"(?:\s|;|$)"#
            guard auth.range(of:dmarc,options:[.regularExpression,.caseInsensitive]) != nil,!(header["subject"] ?? "").lowercased().hasPrefix("fwd:") else{continue}
            let body=plain(payload),text=(header["subject"] ?? "")+"\n"+body
            guard !body.isEmpty,text.count<40000,text.range(of:#"reset|recover|change.{0,20}password|payment|bank transfer|wire transfer|purchase|withdraw"#,options:[.regularExpression,.caseInsensitive])==nil,text.range(of:#"verif|confirm|sign.?in|log.?in|one.?time|security code"#,options:[.regularExpression,.caseInsensitive]) != nil else{continue}
            let pattern="(?<![0-9])[0-9]{\(length)}(?![0-9])"
            let regex=try NSRegularExpression(pattern:pattern),range=NSRange(text.startIndex...,in:text)
            let codes=Set(regex.matches(in:text,range:range).compactMap{Range($0.range,in:text).map{String(text[$0])}})
            if codes.count==1,let code=codes.first{found.append(Match(messageID:id,code:code))}
        }
        guard found.count==1,let result=found.first else{throw BuddyFailure(message:"No single fresh, matching verification email was found. Continue in private Chrome or try after the email arrives.")}
        return result
    }
    private static func addresses(_ text:String)->Set<String>{let regex=try! NSRegularExpression(pattern:#"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#,options:.caseInsensitive);return Set(regex.matches(in:text,range:NSRange(text.startIndex...,in:text)).compactMap{Range($0.range,in:text).map{String(text[$0]).lowercased()}})}
    private static func plain(_ part:[String:Any],depth:Int=0)->String {
        guard depth<8 else{return ""}
        if part["mimeType"] as? String == "text/plain",let data=(part["body"] as? [String:Any])?["data"] as? String,data.count<=50000 {
            var encoded=data.replacingOccurrences(of:"-",with:"+").replacingOccurrences(of:"_",with:"/");encoded+=String(repeating:"=",count:(4-encoded.count%4)%4)
            return Data(base64Encoded:encoded).flatMap{String(data:$0,encoding:.utf8)} ?? ""
        }
        return (part["parts"] as? [[String:Any]] ?? []).prefix(20).map{plain($0,depth:depth+1)}.joined(separator:"\n")
    }
}
