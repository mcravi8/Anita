import Foundation
@main struct TeamBuilderRoutingTests {
    @MainActor static func require(_ ok:Bool,_ label:String){if !ok{fputs("FAILED: \(label)\n",stderr);exit(1)}}
    @MainActor static func main() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("buddy-team-routing-"+UUID().uuidString+".noindex");try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let w=UUID().uuidString,chief=UUID().uuidString,file=root.appendingPathComponent("workspace.json")
        let agent:[String:Any] = ["id":chief,"name":"Chief","role":"Team manager","description":"Coordinate the team and preserve current work.","setupStatus":"ready"]
        try JSONSerialization.data(withJSONObject:["version":1,"conversationWorkspace":w,"agents":[agent],"groups":[[String:Any]](),"messages":[chief:[[String:Any]]()],"runs":[String:Any]()]).write(to:file)
        let primary=ConversationService(support:root,executable:URL(fileURLWithPath:CommandLine.arguments[1]));primary.agentPermission={_,_ in true}
        let settings=BuddyAISettings(support:root);_ = try settings.update(w,enabled:("claude",true))
        let claude=BuddyClaudeConversations(support:root,primary:primary,settings:settings,makeProcess:{BuddyWorkerProcess(resource:URL(fileURLWithPath:CommandLine.arguments[2]),runtime:URL(fileURLWithPath:CommandLine.arguments[3]))},keyReader:{_ in "fixture-key"})
        defer{primary.shutdown();claude.shutdown()};var events=[[String:Any]]();primary.onEvent={events.append($0)};claude.onEvent={events.append($0)}
        for provider in ["CLAUDE","GPT"] {
            let id=UUID().uuidString,user=UUID().uuidString,text="Create a research team. BUILD_TEAM_"+provider
            var s=try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [String:Any],messages=s["messages"] as! [String:[[String:Any]]];messages[chief,default:[]].append(["id":user,"who":"you","body":text,"live":true]);s["messages"]=messages;s["runs"]=[id:["target":chief,"userId":user,"status":"answering"]];try JSONSerialization.data(withJSONObject:s).write(to:file,options:.atomic)
            var options=BuddyTurnOptions();options.actorId=chief;options.authorizedUserText=text;options.proposalScope=BuddyProposalScope(workspace:w,chat:chief,actorId:chief,replyRunId:id)
            let payload:[String:Any] = ["runId":id,"key":w+":"+chief,"text":text,"agent":agent]
            if provider=="CLAUDE"{_ = try claude.send(payload,options:options)}else{_ = try primary.send(payload,options:options)}
            var finished=false
            for _ in 0..<200 {if events.contains(where:{$0["runId"] as? String==id && $0["type"] as? String=="run" && ["completed","failed","stopped"].contains($0["status"] as? String ?? "")}) {finished=true;break};try await Task.sleep(nanoseconds:30_000_000)}
            require(finished && events.contains{$0["runId"] as? String==id && $0["type"] as? String=="run" && $0["status"] as? String=="completed"},provider+" tool turn completes")
            require(events.contains{$0["runId"] as? String==id && $0["type"] as? String=="team-plan" && ($0["plan"] as? [String:Any])?["status"] as? String=="created"},provider+" delivers the actual saved team receipt in the owning DM")
        }
        let saved=try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [String:Any]
        require((saved["groups"] as! [Any]).count==2 && (saved["agents"] as! [Any]).count==3,"both transports actually commit their new group and teammate")
        print("PASS: Claude and ChatGPT creation tool routing, actual-human request binding, native team/agent commits and source-DM receipt events")
    }
}
