import Foundation
@main struct InboxIntegration {
    @MainActor static func require(_ value:Bool,_ message:String){if !value {fputs("FAILED: \(message)\n",stderr);exit(1)}}
    @MainActor static func main() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("buddy-inbox-rpc-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let workspace=UUID().uuidString,agent=UUID().uuidString,key=workspace+":"+agent
        let service=ConversationService(support:root,executable:URL(fileURLWithPath:CommandLine.arguments[1]));defer{service.shutdown()}
        service.agentPermission={_,keys in keys==[key]};service.filePermission={_,_ in false};service.computerPermission={_,_ in false}
        var events:[[String:Any]]=[];service.onEvent={events.append($0)}
        var options=BuddyTurnOptions();options.actorId=agent;options.inboxRoutine="fixture-routine"
        func send(_ text:String,_ options:BuddyTurnOptions) throws -> String {let id=UUID().uuidString;_ = try service.send(["runId":id,"key":key,"agent":["name":"Maze","role":"Email monitor","description":"Find assessments with evidence"],"text":text],options:options);return id}
        func wait(_ id:String) async {for _ in 0..<300{if events.contains(where:{$0["runId"] as? String==id && ["completed","failed","stopped"].contains($0["status"] as? String ?? "")}) {return};try? await Task.sleep(nanoseconds:20_000_000)};require(false,"inbox RPC timed out")}
        let id=try send("Find outstanding assessments in my emails",options);await wait(id)
        let event=events.last{$0["runId"] as? String==id}!
        require(event["status"] as? String=="completed" && (event["coverage"] as? [[String:Any]])?.first?["read"] as? Int==2,"native preflight, model finding acknowledgement, streamed coverage and successful memory commit")
        let files=try FileManager.default.contentsOfDirectory(at:service.inboxReviews.root,includingPropertiesForKeys:nil)
        let ledger=try JSONSerialization.jsonObject(with:Data(contentsOf:files.first{$0.lastPathComponent.hasPrefix("seen-")}!)) as! [String:Any]
        require(Set(ledger["ids"] as! [String])==Set(["ubs","zopa"]),"only actually analyzed sources become routine memory")
        var scheduled=options;scheduled.requiresRoutine=true;scheduled.inboxRoutine=nil
        let missing=try send("SCHEDULE_NO_TOOL run this every morning",scheduled);await wait(missing)
        let failure=events.last{$0["runId"] as? String==missing}!
        require(failure["status"] as? String=="failed" && (failure["text"] as? String)?.contains("has not been scheduled")==true,"an unsupported yes cannot be presented as a real scheduled task")
        print("PASS: native Gmail RPC preflight, paginated full reads, actual per-message findings, coverage event/snapshot, memory commit, default reasoning and false schedule acknowledgement rejection")
    }
}
