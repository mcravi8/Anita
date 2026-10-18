import Foundation
@main struct TeamBuilderTests {
    @MainActor static func require(_ ok:Bool,_ label:String){if !ok{fputs("FAILED: \(label)\n",stderr);exit(1)}}
    @MainActor static func main()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("buddy-team-builder-"+UUID().uuidString+".noindex");try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let w=UUID().uuidString,chief=UUID().uuidString,run=UUID().uuidString,user=UUID().uuidString
        var s:[String:Any] = ["version":1,"conversationWorkspace":w,"agents":[["id":chief,"name":"Chief","role":"Chief of staff","description":"Keep my original instructions.","setupStatus":"ready"]],"groups":[[String:Any]](),"messages":[chief:[[String:Any]]()],"runs":[String:[String:Any]](),"drafts":[chief:"Keep my draft"],"files":[["name":"keep.md"]]]
        let file=root.appendingPathComponent("workspace.json"),builder=BuddyTeamBuilder(support:root),scope=BuddyProposalScope(workspace:w,chat:chief,actorId:chief,replyRunId:run)
        func write()throws{try JSONSerialization.data(withJSONObject:s).write(to:file,options:.atomic)}
        func read()throws->[String:Any]{try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [String:Any]}
        func question(_ text:String,id:String=user,runId:String=run)throws{var messages=s["messages"] as! [String:[[String:Any]]];messages[chief,default:[]].append(["id":id,"who":"you","body":text,"live":true]);s["messages"]=messages;s["runs"]=[runId:["target":chief,"userId":id,"status":"answering"]];try write()}
        func config(_ name:String)->[String:Any]{["name":name,"role":"Research specialist","description":"Research relevant primary sources. Save concise findings with evidence, distinguish uncertainty, and ask only for missing scope.","avatarShape":"star","avatarColor":"blue"]}
        var args:[String:Any] = ["action":"create","teamName":"Research team","objective":"Research useful tools","newAgents":[config("Scout"),config("Sage")],"reason":"Separate source gathering and review.","authorizationQuote":"Create a research team with two agents."]
        try question("What team would be useful?")
        let idea=try builder.perform(scope,executionRunId:run,callId:"idea",arguments:args,authorizedText:"What team would be useful?")
        let unchanged=try read();require(idea["created"] as? Bool==false && idea["proposed"] as? Bool==true && (unchanged["agents"] as! [Any]).count==1,"an unsolicited idea remains pending without creating any agents")
        let pending=idea["plan"] as! [String:Any];_ = try builder.review(w,payload:["planId":pending["id"]!,"revision":0,"action":"decline"])
        try question("Create a research team with two agents.",id:UUID().uuidString)
        let before=s,result=try builder.perform(scope,executionRunId:run,callId:"create",arguments:args,authorizedText:"Create a research team with two agents."),plan=result["plan"] as! [String:Any],saved=try read(),new=result["agents"] as! [[String:Any]],group=result["group"] as! [String:Any]
        require(result["created"] as? Bool==true && new.count==2 && (group["members"] as! [String]).count==3,"an actual explicit user request atomically creates a team with Chief and two teammates")
        require(new.allSatisfy{$0["setupStatus"] as? String=="ready" && $0["managedBy"] as? String==chief && ($0["tools"] as? [String:Bool])?["desktop"]==true},"delegated agents start with complete editable briefs and the user's normal access defaults")
        require((saved["agents"] as! [[String:Any]])[0]["description"] as? String=="Keep my original instructions." && (saved["drafts"] as! [String:String])[chief]=="Keep my draft","team creation preserves existing instructions and drafts")
        let preserved=try builder.preserve(in:before,previous:saved)
        require((preserved["agents"] as! [Any]).count==3 && (preserved["groups"] as! [Any]).count==1,"stale frontend saves cannot erase the newly committed team or teammates")
        let again=try builder.perform(scope,executionRunId:run,callId:"create",arguments:args,authorizedText:"Create a research team with two agents.")
        let duplicateState=try read();require((again["plan"] as! [String:Any])["id"] as? String==plan["id"] as? String && (duplicateState["agents"] as! [Any]).count==3,"duplicate tool delivery returns the original creation receipt")
        let retried=try builder.perform(scope,executionRunId:UUID().uuidString,callId:"retry",arguments:args,authorizedText:"Create a research team with two agents.")
        require((retried["plan"] as! [String:Any])["id"] as? String==plan["id"] as? String,"a new model retry of the same human request does not duplicate agents")
        s=saved;let extra=config("Writer");args=["action":"create","groupId":group["id"]!,"newAgents":[extra],"interviewNewAgents":true,"reason":"Add a writer","authorizationQuote":"Add an agent to the team."]
        try question("Add an agent to the team.",id:UUID().uuidString)
        let expanded=try builder.perform(scope,executionRunId:run,callId:"add",arguments:args,authorizedText:"Add an agent to the team.")
        require((expanded["group"] as! [String:Any])["id"] as? String==group["id"] as? String && ((expanded["agents"] as! [[String:Any]])[0]["setupStatus"] as? String)=="pending","an existing team can gain a teammate using the normal individual interview")
        s=try read();args=["action":"create","newAgents":[config("Analyst")],"reason":"A useful specialist","authorizationQuote":"Create an agent."]
        try question("Consider whether another agent would help.",id:UUID().uuidString)
        let suggested=try builder.perform(scope,executionRunId:run,callId:"suggest",arguments:args,authorizedText:"Create an agent.")
        require(suggested["created"] as? Bool==false,"a forged user prompt cannot bypass the actual saved human-message check")
        let p=suggested["plan"] as! [String:Any]
        var edit=p["draft"] as! [String:Any];edit["newAgents"]=[config("Edited analyst")]
        let reviewed=try builder.review(w,payload:["planId":p["id"]!,"revision":p["revision"]!,"action":"approve","config":edit])
        require((reviewed["agents"] as! [[String:Any]])[0]["name"] as? String=="Edited analyst","a human can edit and approve a suggested teammate")
        let repeatReview=try builder.review(w,payload:["planId":p["id"]!,"revision":p["revision"]!,"action":"approve","config":edit])
        require(repeatReview["created"] as? Bool==true,"an uncertain approval retry reconciles the already saved agent")
        s=try read();try question("A specialist may help later.",id:UUID().uuidString);args=["action":"propose","newAgents":[config("Keeper")],"reason":"Organize the evidence."]
        let optional=try builder.perform(scope,executionRunId:run,callId:"optional",arguments:args,authorizedText:"A specialist may help later.")["plan"] as! [String:Any]
        s=try read();try question("Go ahead.",id:UUID().uuidString)
        let accepted=try builder.perform(scope,executionRunId:run,callId:"go-ahead",arguments:["action":"create","planId":optional["id"]!,"authorizationQuote":"Go ahead."],authorizedText:"Go ahead.")
        require(accepted["created"] as? Bool==true,"an explicit go-ahead commits the unique pending plan in this conversation")
        s=try read();let childActor=new[0]["id"] as! String,groupId=group["id"] as! String,groupRun=UUID().uuidString,groupUser=UUID().uuidString,groupText="Create a team of agents."
        var groupMessages=s["messages"] as! [String:[[String:Any]]];groupMessages[groupId]=[["id":groupUser,"who":"you","body":groupText]];s["messages"]=groupMessages;s["runs"]=[groupRun:["target":groupId,"userId":groupUser,"status":"answering"]];try write()
        let childScope=BuddyProposalScope(workspace:w,chat:groupId,actorId:childActor,replyRunId:groupRun)
        let subteam=try builder.perform(childScope,executionRunId:UUID().uuidString,callId:"subteam",arguments:["action":"create","teamName":"Review team","objective":"Review the research","newAgents":[config("Reviewer")],"reason":"Independent review","authorizationQuote":groupText],authorizedText:groupText)
        require(subteam["created"] as? Bool==true && (subteam["group"] as! [String:Any])["managedBy"] as? String==childActor,"a registered agent in a group can create its own team and teammates")
        s=try read();var privateMessages=s["messages"] as! [String:[[String:Any]]];privateMessages[childActor,default:[]].append(["id":UUID().uuidString,"who":"you","body":"PRIVATE CONVERSATION"]);s["messages"]=privateMessages;try write()
        let listing=try builder.perform(childScope,executionRunId:UUID().uuidString,callId:"list",arguments:["action":"list"],authorizedText:"")
        require(!String(data:try JSONSerialization.data(withJSONObject:listing),encoding:.utf8)!.contains("PRIVATE CONVERSATION"),"model team discovery does not expose teammates' direct messages")
        let bounded=BuddyTeamBuilder.modelResult(result)
        require((bounded["agents"] as! [[String:Any]]).allSatisfy{$0["description"]==nil && $0["learnedRules"]==nil} && (bounded["plan"] as! [String:Any])["initialMessages"]==nil,"model receipts expose saved identities and status without private profile or chat payloads")
        s=try read();try question("Create a team using existing agents.",id:UUID().uuidString)
        let countBefore=(s["agents"] as! [Any]).count
        let reused=try builder.perform(scope,executionRunId:run,callId:"existing",arguments:["action":"create","teamName":"Existing team","objective":"Use existing expertise","existingAgentIds":[chief,childActor],"newAgents":[[String:Any]](),"reason":"Reuse existing teammates","authorizationQuote":"Create a team using existing agents."],authorizedText:"Create a team using existing agents.")
        let reusedState=try read();require((reused["agents"] as! [Any]).isEmpty && (reused["group"] as! [String:Any])["members"] as? [String]==[chief,childActor] && (reusedState["agents"] as! [Any]).count==countBefore,"teams can reuse existing agents without cloning them")
        s=reusedState;try question("Create a team with two agents.",id:UUID().uuidString)
        do{_ = try builder.perform(scope,executionRunId:run,callId:"invalid",arguments:["action":"create","teamName":"Invalid duplicate team","objective":"Test atomic validation","newAgents":[config("Same name"),config("Same name")],"reason":"Fixture","authorizationQuote":"Create a team with two agents."],authorizedText:"Create a team with two agents.");require(false,"invalid roster rejected")}catch{}
        let invalidState=try read();require((invalidState["agents"] as! [Any]).count==countBefore && (invalidState["groups"] as! [Any]).count==(reusedState["groups"] as! [Any]).count,"an invalid teammate cannot leave a partially created team")
        do{_ = try builder.list(UUID().uuidString);require(false,"cross-workspace creation history rejected")}catch{}
        require(!BuddyTeamBuilder.creationRequest("Agents should be able to create teams.") && !BuddyTeamBuilder.creationRequest("If useful, create a team.") && !BuddyTeamBuilder.creationRequest("Build a tool to manage my agents.") && !BuddyTeamBuilder.creationRequest("Create a team plan.") && !BuddyTeamBuilder.creationRequest("Create no agents.") && BuddyTeamBuilder.creationRequest("Can you create a team of agents?"),"capability, software, planning, negative and hypothetical requests do not create teams directly")
        print("PASS: actual-user authorization, direct team/agent creation, editable delegated briefs, existing membership, interview option, pending review/edit/decline, atomic preservation, retry receipts and workspace isolation")
    }
}
