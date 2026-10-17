import Foundation
@main struct ModelTests {
    @MainActor static func require(_ value:Bool,_ message:String){if !value{fputs("FAILED: \(message)\n",stderr);exit(1)}}
    @MainActor static func main() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("buddy-model-tests-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let workspace=UUID().uuidString,a=UUID().uuidString,b=UUID().uuidString,c=UUID().uuidString,key=workspace+":"+a
        var state:[String:Any]=["conversationWorkspace":workspace,"agents":[["id":a],["id":b]],"messages":[a:[["id":"older","who":"you","body":"EARLY_REAL_DETAIL","live":true]]]]
        func save() throws{try JSONSerialization.data(withJSONObject:state).write(to:root.appendingPathComponent("workspace.json"),options:.atomic)}
        try save()
        let activeModels=BuddyModelCatalog.claude([["id":"claude-current","display_name":"Current Claude","lifecycle":"active","line":"sonnet"],["id":"claude-older","lifecycle":"deprecated"],["id":"claude-retired","lifecycle":"retired"],["id":"claude-unknown"]])
        require(activeModels.count==1 && activeModels[0]["id"] as? String=="claude-current" && activeModels[0]["isDefault"] as? Bool==true,"only API-confirmed active Claude models are offered; historical and unknown availability are excluded")
        let lines=BuddyModelCatalog.claude([["id":"claude-newest","lifecycle":"active","line":"sonnet"],["id":"claude-unknown-line","lifecycle":"active","line":NSNull()],["id":"claude-earlier","lifecycle":"active","line":"sonnet"]])
        require(lines[0]["current"] as? Bool==true && lines[1]["current"] as? Bool==true && lines[2]["current"] as? Bool==false,"newest release per explicit API line is offered, older saved releases retain metadata, unclassified models are not guessed away")
        let primary=ConversationService(support:root,executable:URL(fileURLWithPath:CommandLine.arguments[1]))
        var permitted=true,claudeFails=false
        primary.agentPermission={w,keys in permitted && w==workspace && keys.allSatisfy{[key,workspace+":"+b,workspace+":"+c].contains($0)}}
        primary.filePermission={_,_ in false};primary.computerPermission={_,_ in false}
        let router=BuddyAIRouter(support:root,chatgpt:primary,makeProcess:{BuddyWorkerProcess(resource:URL(fileURLWithPath:CommandLine.arguments[2]),runtime:URL(fileURLWithPath:CommandLine.arguments[3]))},keyReader:{_ in "fixture-key"},keyRemover:{_ in},claudeModelReader:{_ in
            if claudeFails{throw BuddyFailure(message:"Fixture catalog offline")}
            return [["provider":"claude","id":"claude-sonnet-4-6","name":"Claude Sonnet","isDefault":true],["provider":"claude","id":"claude-other","name":"Claude Other"]]
        })
        defer{router.shutdown()}
        func catalog(_ payload:[String:Any]=[:]) async throws->[String:Any]{try await router.modelSettings(workspace:workspace,agents:[a,b,c],payload:payload)}
        func set(_ agent:String,_ provider:String,_ model:String) async throws{_ = try await catalog(["operation":"set","agentId":agent,"provider":provider,"model":model])}
        let first=try await router.modelSettings(workspace:workspace,agents:[a,b],payload:[:]),rows=first["models"] as! [[String:Any]]
        require(rows.count==4 && !rows.contains{$0["id"] as? String=="hidden-model"},"both connected providers, paginated OpenAI results, hidden model exclusion")
        require(try router.agentModels.selection(workspace:workspace,agent:a)?.model=="gpt-alpha","initial OpenAI account default resolves to a durable ID")
        _ = try await router.select(workspace:workspace,provider:"claude",budget:nil)
        _ = try await catalog()
        require(try router.agentModels.selection(workspace:workspace,agent:a)?.provider=="chatgpt","changing new-agent default preserves existing agents")
        require(try router.agentModels.selection(workspace:workspace,agent:c)?.provider=="claude","new agents inherit the starting provider")
        try await set(a,"chatgpt","gpt-beta")
        require(try BuddyAgentModels(support:root).selection(workspace:workspace,agent:a)?.model=="gpt-beta","agent choice persists independently across store reload")
        require(try router.agentModels.selection(workspace:workspace,agent:b)?.model=="gpt-alpha","another agent stays on its own saved choice")
        var bad=false;do{try await set(a,"claude","invented-model")}catch{bad=true};require(bad,"unlisted model cannot be saved")
        permitted=false;bad=false;do{try await set(a,"claude","claude-other")}catch{bad=true};require(bad,"agent existence/access is checked again after asynchronous discovery");permitted=true
        claudeFails=true
        let partial=try await catalog(["refresh":true])
        require((partial["models"] as! [[String:Any]]).count==2 && (partial["errors"] as? [String:String])?["claude"] != nil,"one failed catalog leaves the other provider available with explicit error")
        claudeFails=false;_ = try await catalog(["refresh":true])
        var events:[[String:Any]]=[];router.onEvent={events.append($0)}
        func send(_ text:String) async throws->[String:Any]{
            let id=UUID().uuidString
            var options=BuddyTurnOptions();options.actorId=a;options.fileScope=try primary.projectFiles.scope(workspace);options.historyScope=BuddyHistoryScope(workspace:workspace,agent:a);options.history=BuddyConversationHistory.context(state,target:a,runId:id)
            _ = try router.send(["runId":id,"key":key,"agent":["name":"Fixture","role":"Test","description":""],"text":text],options:options)
            for _ in 0..<300 {
                if let event=events.last(where:{$0["runId"] as? String==id && ["completed","failed"].contains($0["status"] as? String ?? "")}) {
                    require(event["status"] as? String=="completed","model turn succeeds: \(event["error"] ?? "")")
                    return try JSONSerialization.jsonObject(with:Data((event["text"] as! String).utf8)) as! [String:Any]
                }
                try await Task.sleep(nanoseconds:20_000_000)
            }
            require(false,"model reply timed out");return [:]
        }
        let gpt1=try await send("FIRST_GPT")
        require(gpt1["model"] as? String=="gpt-beta" && (gpt1["context"] as? String)?.contains("EARLY_REAL_DETAIL")==true,"explicit OpenAI model and default effort reach app-server with prior history")
        try await set(a,"chatgpt","gpt-alpha")
        let gpt2=try await send("SECOND_GPT")
        require(gpt2["model"] as? String=="gpt-alpha" && gpt2["thread"] as? String==gpt1["thread"] as? String,"same-provider switch keeps the existing native conversation")
        try await set(a,"claude","claude-other")
        let claude=try await send("CLAUDE_TURN")
        require(claude["model"] as? String=="claude-other" && (claude["context"] as? String)?.contains("EARLY_REAL_DETAIL")==true,"Claude receives explicit agent model and same saved conversation")
        let active=Task{try await send("PINNED_TURN")}
        for _ in 0..<100 {if events.contains(where:{$0["text"] as? String=="Fixture active"}){break};try await Task.sleep(nanoseconds:10_000_000)}
        try await set(a,"chatgpt","gpt-beta")
        var concurrent=BuddyTurnOptions();concurrent.actorId=a;concurrent.fileScope=try primary.projectFiles.scope(workspace)
        bad=false;do{_ = try router.send(["runId":UUID().uuidString,"key":key],options:concurrent)}catch{bad=error.localizedDescription.contains("already answering")}
        require(bad,"provider change cannot start an overlapping reply in the same agent chat")
        let pinned=try await active.value
        require(pinned["model"] as? String=="claude-other","active reply retains its captured model while next reply selection changes")
        var messages=(state["messages"] as! [String:[[String:Any]]])[a]!
        messages.append(["id":"claude-new","who":a,"body":"RECENT_CLAUDE_DETAIL","status":"completed","live":true])
        state["messages"]=[a:messages];try save()
        try await set(a,"chatgpt","gpt-beta")
        let gpt3=try await send("BACK_TO_GPT")
        require(gpt3["thread"] as? String != gpt1["thread"] as? String && (gpt3["context"] as? String)?.contains("RECENT_CLAUDE_DETAIL")==true,"returning to OpenAI replaces stale thread context with real intervening Claude messages")
        _ = try await router.disconnect(workspace:workspace,provider:"chatgpt")
        let disconnected=try await catalog()
        require((disconnected["models"] as! [[String:Any]]).allSatisfy{$0["provider"] as? String=="claude"},"disconnected provider disappears without overwriting saved selection")
        bad=false;do{_ = try await send("NO_FALLBACK")}catch{bad=true};require(bad,"disconnected selected provider never falls back")
        print("PASS: paginated live catalogs, independent provider errors, durable per-agent choices, new-agent defaults, explicit routed models/effort, same-provider thread reuse, cross-provider history round trip and no fallback")

        // More than twelve messages, oversized messages, retrieval paging and scope isolation.
        messages=(0..<30).map{["id":"m\($0)","who":$0%2==0 ? "you":a,"body":"REAL_\($0)","status":"completed","live":true]}
        messages.append(["id":"failed","who":a,"body":"FAILED_BODY","status":"failed","live":true])
        messages.append(["id":"current","who":"you","body":"CURRENT_DUPLICATE","runId":"current-run","live":true])
        state["messages"]=[a:messages,b:[["id":"secret","who":"you","body":"OTHER_AGENT","live":true]]];try save()
        let context=BuddyConversationHistory.context(state,target:a,runId:"current-run")
        require(context.contains("REAL_0") && context.contains("REAL_29") && !context.contains("FAILED_BODY") && !context.contains("CURRENT_DUPLICATE") && !context.contains("OTHER_AGENT"),"shared history exceeds old twelve-message limit and excludes failed, current and foreign messages")
        messages.append(["id":"long","who":a,"body":String(repeating:"x",count:190000),"status":"completed","live":true]);state["messages"]=[a:messages];try save()
        require(BuddyConversationHistory.context(state,target:a,runId:"current-run").contains("buddy_read_chat_history"),"oversized prompt omissions are explicit and retrievable")
        let archive=try BuddyConversationHistory.read(support:root,scope:BuddyHistoryScope(workspace:workspace,agent:a),runID:"current-run",args:["query":"REAL_","limit":20])
        require(archive["total"] as? Int==30 && archive["nextOffset"] as? Int==20,"archive retrieval exposes real pagination")
        let chunk=try BuddyConversationHistory.read(support:root,scope:BuddyHistoryScope(workspace:workspace,agent:a),runID:"current-run",args:["messageID":"long","characterOffset":20000])
        let row=(chunk["messages"] as! [[String:Any]])[0]
        require((row["text"] as? String)?.count==20000 && row["nextCharacterOffset"] as? Int==40000,"long history remains recoverable through bounded chunks")
        bad=false;do{_ = try BuddyConversationHistory.read(support:root,scope:BuddyHistoryScope(workspace:UUID().uuidString,agent:a),runID:"current-run",args:[:])}catch{bad=true};require(bad,"cross-workspace archive denied")
        try Data("corrupt".utf8).write(to:root.appendingPathComponent("agent-models.json"));bad=false;do{_ = try router.agentModels.selection(workspace:workspace,agent:a)}catch{bad=true};require(bad,"corrupt preferences fail closed")
        print("PASS: shared history filtering, omission notices, older-message search/paging, long-message recovery, scope isolation and corrupt preference protection")
    }
}
