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
    /// The site a host belongs to (jobs.ubs.com and mail.ubs.com are both ubs.com).
    static func siteOf(_ host: String) -> String {
        let parts = host.lowercased().split(separator: ".").map(String.init)
        guard parts.count > 2 else { return host.lowercased() }
        let two = parts.suffix(2).joined(separator: ".")
        return two.range(of: #"^(co|com|org|net|ac|gov|edu|ne|or)\.[a-z]{2}$"#, options: .regularExpression) != nil ? parts.suffix(3).joined(separator: ".") : two
    }
    /// The one link in the newest fresh email from `origin`'s site to `recipient` that confirms the new account ("confirm") or resets its
    /// password ("reset"): sent by that site (DMARC passed for the sender's domain), to that address, since the request, and pointing back to
    /// the same site over https. Several different links that fit, or none, is no answer. Bodies never leave this function.
    struct LinkMatch { let messageID: String; let link: String }
    static func link(_ messages: [[String: Any]], origin: String, recipient: String, since: Date, excluding: Set<String>, purpose: String, now: Date = Date()) -> LinkMatch? {
        guard let url = URL(string: origin), let host = url.host?.lowercased(), email(recipient), now.timeIntervalSince(since) < 1800 else { return nil }
        let site = siteOf(host)
        var newest: (date: Date, match: LinkMatch)?
        for message in messages {
            guard let id = message["id"] as? String, !excluding.contains(id), let stamp = message["internalDate"] as? String, let milliseconds = Double(stamp),
                  let payload = message["payload"] as? [String: Any], let headers = payload["headers"] as? [[String: Any]] else { continue }
            let date = Date(timeIntervalSince1970: milliseconds / 1000)
            guard date >= since.addingTimeInterval(-60), date <= now.addingTimeInterval(60) else { continue }
            let header = Dictionary(headers.compactMap { h -> (String, String)? in guard let n = h["name"] as? String, let v = h["value"] as? String else { return nil }; return (n.lowercased(), v) }, uniquingKeysWith: { $0 + " " + $1 })
            let from = addresses(header["from"] ?? "")
            guard from.count == 1, let sender = from.first, let domain = sender.split(separator: "@").last.map(String.init), siteOf(domain) == site,
                  addresses((header["to"] ?? "") + " " + (header["delivered-to"] ?? "")).contains(recipient.lowercased()), !header.keys.contains(where: { $0.hasPrefix("resent-") }),
                  !(header["subject"] ?? "").lowercased().hasPrefix("fwd:") else { continue }
            let auth = headers.first { ($0["name"] as? String)?.lowercased() == "authentication-results" && ($0["value"] as? String ?? "").lowercased().hasPrefix("mx.google.com;") }?["value"] as? String ?? ""
            guard auth.range(of: #"(?:^|;)\s*dmarc=pass\b[^;]*\bheader\.from="# + NSRegularExpression.escapedPattern(for: domain) + #"(?:\s|;|$)"#, options: [.regularExpression, .caseInsensitive]) != nil else { continue }
            let body = plain(payload) + "\n" + markup(payload), text = (header["subject"] ?? "") + "\n" + body
            guard !body.isEmpty, text.count < 200000 else { continue }
            let reset = text.range(of: #"reset|recover|new password|forgot"#, options: [.regularExpression, .caseInsensitive]) != nil
            let confirm = text.range(of: #"verif|confirm|activat|welcome|complete (your )?(registration|sign.?up)"#, options: [.regularExpression, .caseInsensitive]) != nil
            guard purpose == "reset" ? reset : confirm && !reset else { continue }
            guard let finder = try? NSRegularExpression(pattern: #"https?://[^\s"'<>()\[\]]+"#, options: .caseInsensitive) else { continue }
            var links: [String] = []
            for m in finder.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
                guard let r = Range(m.range, in: body) else { continue }
                var candidate = String(body[r]).replacingOccurrences(of: "&amp;", with: "&")
                while let last = candidate.last, ".,;:!?".contains(last) { candidate.removeLast() }
                guard let u = URL(string: candidate), let h = u.host?.lowercased(), u.user == nil, u.password == nil, siteOf(h) == site, u.scheme == "https" else { continue }
                if !links.contains(candidate) { links.append(candidate) }
            }
            // The link that does it says so (confirm, verify, activate, reset, a token); the site's other links (its home, its help) don't count.
            let doing = links.filter { $0.range(of: purpose == "reset" ? #"reset|recover|password|token|code|key"# : #"confirm|verif|activat|token|code|key|welcome"#, options: [.regularExpression, .caseInsensitive]) != nil }
            guard doing.count == 1, let found = doing.first else { continue }
            if newest == nil || date > newest!.date { newest = (date, LinkMatch(messageID: id, link: found)) }
        }
        return newest?.match
    }
    private static func markup(_ part: [String: Any], depth: Int = 0) -> String {
        guard depth < 8 else { return "" }
        if part["mimeType"] as? String == "text/html", let data = (part["body"] as? [String: Any])?["data"] as? String, data.count <= 400000 {
            var encoded = data.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/"); encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
            return Data(base64Encoded: encoded).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
        return (part["parts"] as? [[String: Any]] ?? []).prefix(20).map { markup($0, depth: depth + 1) }.joined(separator: "\n")
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

/// What Buddy looks for in the person's connected Gmail for an account it is creating or a password it is resetting: the newest email from
/// that site to that address since `since` — a confirmation link ("confirm"), a reset link ("reset") or a code ("code").
struct BuddyAccountMailRequest { let workspace: String, agent: String, origin: String, recipient: String, since: Date, purpose: String, excluding: Set<String> }
struct BuddyAccountMailFound { let messageID: String; let link: String?; let code: String? }
/// The connected Gmail as the worker reads it (a test passes its own). nil: nothing yet. Throws when there is no mailbox to read.
typealias BuddyAccountMailbox = @MainActor (BuddyAccountMailRequest) async throws -> BuddyAccountMailFound?
