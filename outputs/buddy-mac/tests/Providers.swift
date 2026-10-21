import Foundation
@main struct ProviderTests {
    @MainActor static func require(_ value:Bool,_ message:String){if !value{fputs("FAILED: \(message)\n",stderr);exit(1)}}
    @MainActor static func wait(_ condition:()->Bool) async {for _ in 0..<200{if condition(){return};try? await Task.sleep(nanoseconds:20_000_000)};require(false,"provider fixture timed out")}
    @MainActor static func main() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("buddy-provider-tests-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let workspace=UUID().uuidString,agent=UUID().uuidString,key=workspace+":"+agent
        let settings=BuddyAISettings(support:root)
        require(try settings.current(workspace).provider == "chatgpt","existing users retain ChatGPT default")
        _ = try settings.update(workspace,provider:"claude",budget:0.7)
        require(try BuddyAISettings(support:root).current(workspace).provider == "claude","selection persists across restart/processes")
        require(try settings.current(UUID().uuidString).provider == "chatgpt","workspace provider settings are isolated")
        var invalid=false;do{_ = try settings.update(workspace,provider:"unknown")}catch{invalid=true};require(invalid,"unknown provider rejected")
        require(BuddyRunLimit.isNone(try settings.current(workspace).claudeBudgetUSD),"a run has no limit of its own, whatever an older settings file or a caller says about one")
        let primary=ConversationService(support:root,executable:URL(fileURLWithPath:CommandLine.arguments[1]))
        primary.agentPermission={w,keys in w==workspace && keys == [key]};primary.filePermission={w,keys in w==workspace && keys == [key]};primary.computerPermission={_,_ in false}
        var processes=0
        let router=BuddyAIRouter(support:root,chatgpt:primary,makeProcess:{processes+=1;return BuddyWorkerProcess(resource:URL(fileURLWithPath:CommandLine.arguments[2]),runtime:URL(fileURLWithPath:CommandLine.arguments[3]))},keyReader:{_ in "fixture-key"},keyRemover:{_ in})
        defer{router.shutdown()}
        var events:[[String:Any]]=[];router.onEvent={events.append($0)}
        var options=BuddyTurnOptions();options.actorId=agent;options.fileScope=try primary.projectFiles.scope(workspace);options.history="Earlier ChatGPT answer"
        func send(_ text:String,_ options:BuddyTurnOptions) throws->String {let id=UUID().uuidString;_ = try router.send(["runId":id,"key":key,"agent":["name":"Check","role":"Provider fixture","description":"Inert verification"],"text":text],options:options);return id}
        func terminal(_ id:String)->Bool{events.contains{$0["type"] as? String == "run" && $0["runId"] as? String == id && ["completed","failed","stopped"].contains($0["status"] as? String ?? "")}}
        var browserOptions=options;browserOptions.extraTools=BuddyWorkerClient.tools;browserOptions.instructions=BuddyWorkerClient.taskGuidance
        browserOptions.authorizedUserText="Create an inbox in my AgentMail account."
        var computerCalls=0
        primary.extraToolHandler={tool,args,context in
            require(tool=="buddy_computer_task" && args["action"] as? String=="start" && context["agentId"] as? String==agent && context["authorizedUserText"] as? String=="Create an inbox in my AgentMail account.","ordinary action keeps its actual user brief and actor across providers")
            computerCalls += 1;return ["task":["id":"fixture-browser","status":"queued","title":"Create AgentMail inbox"]]
        }
        _ = try settings.update(workspace,enabled:("chatgpt",false))
        let browserClaude=try send("COMPUTER_TASK",browserOptions);await wait{terminal(browserClaude)}
        require(computerCalls==1 && events.contains{$0["runId"] as? String==browserClaude && $0["status"] as? String=="completed"},"Claude routes its native browser task with ChatGPT disconnected")
        _ = try settings.update(workspace,enabled:("chatgpt",true))
        let first=try send("HISTORY_CHECK",options);await wait{terminal(first)}
        require(events.contains{$0["runId"] as? String == first && $0["text"] as? String == "Claude fixture answer" && $0["status"] as? String == "completed"},"selected Claude actually answers through Claude bridge with real prior history")
        let second=try send("HISTORY_CHECK second message",options);await wait{terminal(second)}
        require(processes==1,"completed messages reuse the same authorized Claude bridge")
        var scheduleOptions=options;scheduleOptions.requiresRoutine=true
        let fakeSchedule=try send("Run this every morning CLAIM_SCHEDULE",scheduleOptions);await wait{terminal(fakeSchedule)}
        require(events.contains{$0["runId"] as? String==fakeSchedule && $0["status"] as? String=="failed" && ($0["error"] as? String)?.contains("No active routine")==true},"Claude cannot finish a schedule request without a native saved routine receipt")
        // A request that merely sounds like a schedule, answered without claiming one, is an ordinary answer and not a failure.
        let sounds=try send("Run the pipeline on the daily VIX data and report the exponents.",scheduleOptions);await wait{terminal(sounds)}
        require(events.contains{$0["runId"] as? String==sounds && $0["status"] as? String=="completed"},"an answer that claims no schedule is not failed because the question mentioned 'daily'")
        var proactiveOptions=options;proactiveOptions.requiresProactive=true
        let fakeProactive=try send("Keep me updated. CLAIM_PROACTIVE",proactiveOptions);await wait{terminal(fakeProactive)}
        require(events.contains{$0["runId"] as? String==fakeProactive && $0["status"] as? String=="failed" && ($0["error"] as? String)?.contains("setting") == true},"Claude cannot claim proactive updates were enabled without a native saved setting receipt")
        primary.extraToolHandler={tool,args,context in require(tool=="buddy_team" && context["agentId"] as? String==agent && context["authorizedUserText"] as? String=="Keep me updated.","the tool receives this actor's actual current user request");return ["saved":true,"agentId":agent,"proactive":true]}
        proactiveOptions.authorizedUserText="Keep me updated.";proactiveOptions.extraTools=[["type":"function","name":"buddy_team","description":"Fixture saved setting","inputSchema":["type":"object","properties":["action":["type":"string"]]]]]
        let savedProactive=try send("SAVE_PROACTIVE",proactiveOptions);await wait{terminal(savedProactive)}
        require(events.contains{$0["runId"] as? String==savedProactive && $0["status"] as? String=="completed"},"Claude's real native saved-setting receipt satisfies the proactive acknowledgement guard")
        let inGroup=Set(BuddyWorkerClient.groupTools.compactMap{$0["name"] as? String})
        require(inGroup==Set(BuddyWorkerClient.tools.compactMap{$0["name"] as? String}) && inGroup.isSuperset(of:["buddy_coding_session","buddy_computer_task","buddy_agent_settings","buddy_agent_rules","buddy_manage_routine","buddy_team"]),"an agent in a group chat has everything it has in a direct chat, so a request is never answered with 'ask me in my own chat': \(inGroup)")
        var ruleOptions=options;ruleOptions.requiresRule=true
        let unsavedRule=try send("Keep it in mind. CLAIM_RULE",ruleOptions);await wait{terminal(unsavedRule)}
        require(events.contains{$0["runId"] as? String==unsavedRule && $0["status"] as? String=="failed" && ($0["error"] as? String)?.contains("rule wasn’t saved")==true},"Claude cannot finish a stated rule without a native saved-rule receipt")
        primary.extraToolHandler={tool,args,context in require(tool=="buddy_agent_rules" && args["action"] as? String=="add" && args["quote"] as? String=="send me the CV" && context["authorizedUserText"] as? String=="Please send me the CV first.","the rule tool receives the person’s actual message");return ["saved":true,"ruleId":UUID().uuidString]}
        ruleOptions.authorizedUserText="Please send me the CV first.";ruleOptions.extraTools=[["type":"function","name":"buddy_agent_rules","description":"Fixture saved rule","inputSchema":["type":"object","properties":["action":["type":"string"]]]]]
        let savedRule=try send("SAVE_RULE",ruleOptions);await wait{terminal(savedRule)}
        require(events.contains{$0["runId"] as? String==savedRule && $0["status"] as? String=="completed"},"a saved rule receipt satisfies the guard")
        for stated in ["For the first three applications, send me the CV so I can check your work. If I'm fine with those three, from then on, you can apply without me having to check on the CV each time.","For the first 5 emails you draft, show me so I can review them. Once I've approved those, send the rest on your own.","For the first two reports let me look them over; after that you can go ahead without asking me."] {
            require(BuddyWorkerClient.stagedRuleRequest(stated),"a staged rule is recognised: \(stated.prefix(40))")
        }
        for ordinary in ["Apply to the first three jobs on the list, then email me the results.","Apply to the first three jobs, check each one is still open, and then you can summarize them.","From now on keep your emails short.","For the first three weeks check in daily.","If I told you to check the first three, from then on without me checking, would that be okay?","What does it mean to review the first three applications on your own?"] {
            require(!BuddyWorkerClient.stagedRuleRequest(ordinary),"an ordinary request is not mistaken for a rule: \(ordinary.prefix(40))")
        }
        let file=try send("WRITE_CLAUDE",options);await wait{terminal(file)}
        let saved=try primary.projectFiles.read(options.fileScope!,path:"claude-note.md")
        require((saved["content"] as? String)?.contains("selected Claude") == true,"Claude uses the existing scoped file engine and real saved bytes")
        var grouped=options;grouped.routingGroup=UUID().uuidString;grouped.outputSchema=["type":"object","properties":["ok":["type":"boolean"]],"required":["ok"]]
        let group1=try send("SCHEMA_CLAUDE",grouped);await wait{terminal(group1)}
        _ = try await router.select(workspace:workspace,provider:"chatgpt",budget:nil)
        let group2=try send("SCHEMA_CLAUDE",grouped);await wait{terminal(group2)}
        require(events.contains{$0["runId"] as? String == group2 && ($0["text"] as? String)?.contains("\"ok\"") == true},"in-flight group keeps its provider and structured planning output")
        primary.extraToolHandler={tool,args,context in
            require(tool=="buddy_computer_task" && context["authorizedUserText"] as? String=="Create an inbox in my AgentMail account.","ChatGPT browser tool keeps ordinary current request context")
            computerCalls += 1;return ["task":["id":"fixture-browser-gpt","status":"queued"]]
        }
        let browserGPT=try send("COMPUTER_TASK",browserOptions);await wait{terminal(browserGPT)}
        require(computerCalls==2 && events.contains{$0["runId"] as? String==browserGPT && $0["status"] as? String=="completed"},"ChatGPT routes the same native browser task")
        primary.extraToolHandler={tool,args,context in return ["saved":true,"agentId":agent,"proactive":true]}
        let gpt=try send("GPT_CHECK",options);await wait{terminal(gpt)}
        require(events.contains{$0["runId"] as? String == gpt && $0["text"] as? String == "ChatGPT fixture answer" && $0["status"] as? String == "completed"},"new turns use selected ChatGPT without changing history")
        let fakeGPTProactive=try send("Keep me updated. CLAIM_PROACTIVE",proactiveOptions);await wait{terminal(fakeGPTProactive)}
        require(events.contains{$0["runId"] as? String==fakeGPTProactive && $0["status"] as? String=="failed" && ($0["error"] as? String)?.contains("setting") == true},"ChatGPT cannot claim proactive updates were enabled without a native saved setting receipt")
        let savedGPTProactive=try send("SAVE_PROACTIVE",proactiveOptions);await wait{terminal(savedGPTProactive)}
        require(events.contains{$0["runId"] as? String==savedGPTProactive && $0["status"] as? String=="completed"},"ChatGPT's real native saved-setting receipt satisfies the proactive acknowledgement guard")
        _ = try await router.disconnect(workspace:workspace,provider:"chatgpt")
        invalid=false;do{_ = try send("DISCONNECTED",options)}catch{invalid=true};require(invalid,"disconnected ChatGPT blocks new work without falling back")
        let account=try await primary.connection();require(account["connected"] as? Bool == true,"Buddy-only disconnect preserves shared ChatGPT sign-in")
        let reconnected=try await router.connectChatGPT(workspace:workspace)
        require((reconnected["status"] as? [String:Any])?["connected"] as? Bool == true,"reconnect restores cached authorized ChatGPT access")
        _ = try await router.select(workspace:workspace,provider:"claude",budget:nil)
        let waiting=try send("WAIT_CLAUDE",options);await wait{events.contains{$0["runId"] as? String == waiting && ($0["text"] as? String)?.contains("waiting") == true}}
        _ = try await router.disconnect(workspace:workspace,provider:"claude")
        require(events.contains{$0["runId"] as? String == waiting && $0["status"] as? String == "stopped"},"disconnect stops the selected provider's active reply")
        invalid=false;do{_ = try send("NO_FALLBACK",options)}catch{invalid=true};require(invalid,"disconnected Claude cannot silently use ChatGPT")
        _ = try await router.didConnectClaude(workspace:workspace)
        let restored=try send("CLAUDE_RECONNECTED",options);await wait{terminal(restored)}
        require(events.contains{$0["runId"] as? String == restored && $0["status"] as? String == "completed"},"Claude reconnect restores the selected provider")
        // The chat prompt follows the decision policy: it never says the person decided something they did not, and claims only receipts.
        let echoed=try send("ECHO_INSTRUCTIONS",options);await wait{terminal(echoed)}
        let system=events.last{$0["runId"] as? String==echoed && $0["status"] as? String=="completed"}?["text"] as? String ?? ""
        require(system.contains("claim the user decided something they did not") && !system.contains("invent recipients, decisions or facts") && !system.contains("Ask for missing information in your reply"),"a Claude chat turn's system prompt does not send missing information or decisions to the user: \(system.suffix(500))")
        require(system.contains("When information is missing, look for it with your tools first, then follow the decision policy.") && system.contains("unless a tool in this reply returned that receipt") && !system.contains("configured spending limit"),"the prompt looks things up first and claims Buddy's state only from receipts")
        // A daily limit: the refusal says where to raise it, and a turn sets nothing aside, so a stopped one gives nothing back because it took nothing.
        let ledger=try BuddyWorkerStore(directory:root.appendingPathComponent("Worker"))
        try ledger.setLimit(workspace:workspace,scope:"agent",id:agent,amount:0,setBy:"user")
        var refusal="";do{_ = try send("DAILY_LIMIT refused",options)}catch{refusal=error.localizedDescription}
        require(refusal.contains("Raise it in this agent's settings") && !refusal.contains("Ask Chief"),"a used-up daily limit tells the person where to raise it: \(refusal)")
        try ledger.setLimit(workspace:workspace,scope:"agent",id:agent,amount:5,setBy:"user")
        func room()->Double {BuddyBudget.headroom(support:root,workspace:workspace,agent:agent)?.room ?? -1}
        let roomBefore=room()
        let held=try send("WAIT_CLAUDE DAILY_LIMIT",options);await wait{events.contains{$0["runId"] as? String==held && ($0["text"] as? String)?.contains("waiting")==true}}
        let roomDuring=room()
        _ = try await router.stop(held);await wait{terminal(held)}
        let roomAfter=room()
        require(roomBefore>4.5 && abs(roomDuring-roomBefore)<1e-9 && abs(roomAfter-roomBefore)<1e-9,"a running or stopped chat turn that never reported a cost leaves today's room unchanged (before \(roomBefore), during \(roomDuring), after \(roomAfter))")
        print("PASS: persistent provider selection, workspace isolation, budget validation, actual ChatGPT/Claude routing, shared conversation context, scoped file writes, structured group output, pinned group provider, disconnect/reconnect, stopped work and no automatic fallback")
        try Data("broken".utf8).write(to:root.appendingPathComponent("ai-providers.json"));invalid=false;do{_ = try settings.current(workspace)}catch{invalid=true};require(invalid,"corrupt provider settings fail closed")
    }
}
