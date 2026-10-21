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
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("buddy-mail-tests-"+UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let service=ConversationService(support:root,executable:URL(fileURLWithPath:CommandLine.arguments[1]));defer{service.shutdown()}
        let workspace=UUID().uuidString,agent=UUID().uuidString;var allowed=true
        service.agentPermission={_,_ in allowed};var events:[[String:Any]]=[];service.onEvent={events.append($0)}
        let result=try await service.emailVerification(workspace:workspace,agent:agent,origin:"https://example.com",recipient:"fixture@example.com",since:since,excluding:[],length:6)
        require(result.code=="410239","restricted native Gmail RPC reads profile, searches only matching mail and parses code")
        require(!String(describing:events).contains("410239"),"code and mail bodies never enter frontend/model events")
        allowed=false;var denied=false;do{_ = try await service.emailVerification(workspace:workspace,agent:agent,origin:"https://example.com",recipient:"fixture@example.com",since:since,excluding:[],length:6)}catch{denied=true};require(denied,"removed agent access blocks native mailbox reads")
        print("PASS: native scoped Gmail verification, fresh authenticated sender and matching recipient, ambiguity/recovery/replay rejection, no code in model events, access revocation")
    }
}
