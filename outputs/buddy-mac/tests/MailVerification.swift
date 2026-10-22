import Foundation
@main struct MailVerificationTests {
    static func require(_ value:Bool,_ why:String){if !value{fputs("FAILED: \(why)\n",stderr);exit(1)}}
    static func message(_ body:String="Your verification code is 410239",sender:String="signin@example.com",age:Double=0)->[String:Any]{["id":UUID().uuidString,"internalDate":String(Int(Date().addingTimeInterval(-age).timeIntervalSince1970*1000)),"payload":["mimeType":"text/plain","body":["data":Data(body.utf8).base64EncodedString()],"headers":[["name":"From","value":sender],["name":"To","value":"fixture@example.com"],["name":"Authentication-Results","value":"mx.google.com; dmarc=pass header.from=example.com"],["name":"Subject","value":"Verify email"]]] ]}
    @MainActor static func main() async throws {
        let since=Date().addingTimeInterval(-30),good=message()
        let match=try BuddyMailVerification.match([good],origin:"https://example.com",recipient:"fixture@example.com",since:since,excluding:[])
        require(match.code=="410239","fresh matching code is parsed natively")
        for (items,origin,recipient,used) in [([good,good],"https://example.com","fixture@example.com",Set<String>()),([message(sender:"attacker@other.com")],"https://example.com","fixture@example.com",[]),([message(age:1000)],"https://example.com","fixture@example.com",[]),([message("Reset your password with verification code 410239")],"https://example.com","fixture@example.com",[]),([good],"https://evil-example.com","fixture@example.com",[]),([good],"https://example.com","someone@example.com",[]),([good],"https://example.com","fixture@example.com",[match.messageID])] {
            var denied=false;do{_ = try BuddyMailVerification.match(items,origin:origin,recipient:recipient,since:since,excluding:used)}catch{denied=true};require(denied,"mismatch, ambiguity, old mail, recovery and replay are rejected")
        }
        // The link that confirms an account Buddy created (or resets its password): from that site, to that address, back to that site.
        func mail(_ body:String,sender:String="no-reply@ubs.com",to:String="matteo.craviotto@gmail.com",subject:String="Confirm your email",html:String?=nil,age:Double=0)->[String:Any]{
            var parts:[[String:Any]]=[["mimeType":"text/plain","body":["data":Data(body.utf8).base64EncodedString()]]]
            if let html{parts.append(["mimeType":"text/html","body":["data":Data(html.utf8).base64EncodedString()]])}
            return ["id":UUID().uuidString,"internalDate":String(Int(Date().addingTimeInterval(-age).timeIntervalSince1970*1000)),"payload":["mimeType":"multipart/alternative","parts":parts,"headers":[["name":"From","value":"UBS Careers <\(sender)>"],["name":"To","value":to],["name":"Subject","value":subject],["name":"Authentication-Results","value":"mx.google.com; dmarc=pass header.from=\(sender.split(separator:"@").last ?? "")"]]]]
        }
        let confirm=mail("Welcome! Confirm your email: https://jobs.ubs.com/account/confirm?token=c0nf1rm&amp;lang=en\nHelp: https://www.ubs.com/help")
        let found=BuddyMailVerification.link([confirm],origin:"https://jobs.ubs.com",recipient:"matteo.craviotto@gmail.com",since:since,excluding:[],purpose:"confirm")
        require(found?.link=="https://jobs.ubs.com/account/confirm?token=c0nf1rm&lang=en","the confirmation link from the site's own domain is found, its other links are not: \(found?.link ?? "none")")
        require(BuddyMailVerification.link([mail("",html:"<p>Please <a href=\"https://jobs.ubs.com/verify?code=91\">verify your email</a></p>")],origin:"https://jobs.ubs.com",recipient:"matteo.craviotto@gmail.com",since:since,excluding:[],purpose:"confirm")?.link=="https://jobs.ubs.com/verify?code=91","a link in the HTML part")
        let reset=mail("Reset your password: https://jobs.ubs.com/reset?token=r3set",subject:"Reset your password")
        require(BuddyMailVerification.link([reset],origin:"https://jobs.ubs.com",recipient:"matteo.craviotto@gmail.com",since:since,excluding:[],purpose:"reset")?.link=="https://jobs.ubs.com/reset?token=r3set","a reset link, for a reset")
        for (items,purpose,why) in [([reset],"confirm","a reset email is not a confirmation"),([mail("Confirm: https://evil.example/confirm?token=x")],"confirm","a link to another site"),([mail("Confirm: https://jobs.ubs.com/confirm?token=x",sender:"news@other.example")],"confirm","another sender"),
                                    ([mail("Confirm: https://jobs.ubs.com/confirm?token=x",to:"someone@example.com")],"confirm","another recipient"),([mail("Confirm: https://jobs.ubs.com/confirm?token=a or https://jobs.ubs.com/confirm?token=b")],"confirm","two different links"),
                                    ([mail("Confirm: https://jobs.ubs.com/confirm?token=x",age:3600)],"confirm","an old email"),([mail("Confirm: http://jobs.ubs.com/confirm?token=x")],"confirm","a link that isn't https")] as [([[String:Any]],String,String)] {
            require(BuddyMailVerification.link(items,origin:"https://jobs.ubs.com",recipient:"matteo.craviotto@gmail.com",since:since,excluding:[],purpose:purpose)==nil,"refused: \(why)")
        }
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("buddy-mail-tests-"+UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let service=ConversationService(support:root,executable:URL(fileURLWithPath:CommandLine.arguments[1]));defer{service.shutdown()}
        let workspace=UUID().uuidString,agent=UUID().uuidString;var allowed=true
        service.agentPermission={_,_ in allowed};var events:[[String:Any]]=[];service.onEvent={events.append($0)}
        let result=try await service.emailVerification(workspace:workspace,agent:agent,origin:"https://example.com",recipient:"fixture@example.com",since:since,excluding:[],length:6)
        require(result.code=="410239","restricted native Gmail RPC reads profile, searches only matching mail and parses code")
        require(!String(describing:events).contains("410239"),"code and mail bodies never enter frontend/model events")
        allowed=false;var denied=false;do{_ = try await service.emailVerification(workspace:workspace,agent:agent,origin:"https://example.com",recipient:"fixture@example.com",since:since,excluding:[],length:6)}catch{denied=true};require(denied,"removed agent access blocks native mailbox reads")
        print("PASS: confirmation and reset links only from the site, to the address, back to the site, one at a time; native scoped Gmail verification, fresh authenticated sender and matching recipient, ambiguity/recovery/replay rejection, no code in model events, access revocation")
    }
}
