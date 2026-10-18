import Foundation
@main struct AgentSetupTests {
    @MainActor static func require(_ value:Bool,_ label:String){if !value{fputs("FAILED: \(label)\n",stderr);exit(1)}}
    @MainActor static func main() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("buddy-agent-interview-"+UUID().uuidString+".noindex")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let workspace=UUID().uuidString,a=UUID().uuidString,b=UUID().uuidString,c=UUID().uuidString,d=UUID().uuidString
        let initial:[String:Any]=["version":1,"conversationWorkspace":workspace,"agents":[a,b,c,d].map{["id":$0,"name":$0==a ? "Research Buddy":"Other Buddy","role":"Getting started","description":"Setup bootstrap","setupSeed":"","setupStatus":"pending","tools":["projectFiles":true]]},"groups":[],"messages":[String:Any](),"drafts":[a:"Unsent"]]
        let stateFile=root.appendingPathComponent("workspace.json");try JSONSerialization.data(withJSONObject:initial).write(to:stateFile)
        let make={BuddyWorkerProcess(resource:URL(fileURLWithPath:CommandLine.arguments[1]),runtime:URL(fileURLWithPath:CommandLine.arguments[2]))}
        let service=BuddyAgentSetup(support:root,makeProcess:make,keyReader:{_ in "fixture-key"})
        func call(_ id:String,_ action:String,_ args:[String:Any]=[:])throws->[String:Any]{try service.request(workspace:workspace,payload:args.merging(["agentId":id,"action":action]){_,new in new})["interview"] as! [String:Any]}
        func wait(_ id:String,_ status:String) async throws -> [String:Any] {for _ in 0..<100{let r=try call(id,"status");if r["status"] as? String==status{return r};if r["status"] as? String=="failed"&&status != "failed" {fputs("\(r["error"] ?? "failed")\n",stderr);break};try await Task.sleep(nanoseconds:50_000_000)};require(false,"interview reaches \(status)");return [:]}
        let first=try call(a,"begin")
        require((first["messages"] as? [[String:Any]])?.count==1,"opening the chat asks the first question without an API call")
        let answer:[String:Any]=["requestId":"answer-one","revision":first["revision"]!,"text":"NEED_MORE: help research a topic."]
        _ = try call(a,"answer",answer);let follow=try await wait(a,"interview")
        require((follow["messages"] as? [[String:Any]])?.count==3,"Claude asks a relevant follow-up when more job context is needed")
        let provisional=try JSONSerialization.jsonObject(with:Data(contentsOf:stateFile)) as! [String:Any]
        require((follow["instructions"] as? String)?.isEmpty==false && (provisional["agents"] as! [[String:Any]])[0]["description"] as? String==follow["instructions"] as? String,"working instructions are visible before the interview finishes")
        _ = try call(a,"answer",answer)
        require((try call(a,"status")["messages"] as? [[String:Any]])?.count==3,"retrying an accepted request does not duplicate the answer or model call")
        _ = try call(a,"answer",["requestId":"answer-two","revision":follow["revision"]!,"text":"Use primary public sources, give concise sourced comparisons, no external actions."])
        let ready=try await wait(a,"ready")
        require(try call(a,"stop")["status"] as? String=="ready","late Stop cannot reopen a completed setup")
        require((ready["instructions"] as? String)?.contains("expert research partner")==true,"separate background Claude call generates job-specific instructions")
        let saved=try JSONSerialization.jsonObject(with:Data(contentsOf:stateFile)) as! [String:Any]
        require((saved["agents"] as! [[String:Any]]).first?["description"] as? String==ready["instructions"] as? String,"generated instructions are committed to the real saved agent")
        var stale=initial;var staleAgents=stale["agents"] as! [[String:Any]];staleAgents[0]["avatarColor"]="red";stale["agents"]=staleAgents
        let protected=try service.protect(stale),protectedAgent=(protected["agents"] as! [[String:Any]])[0]
        require(protectedAgent["description"] as? String==ready["instructions"] as? String && protectedAgent["avatarColor"] as? String=="red","late workspace saves preserve native instructions and independent appearance edits")
        let failedFirst=try call(b,"begin");_ = try call(b,"answer",["requestId":"fail","revision":failedFirst["revision"]!,"text":"FAIL_ONCE: research primary sources and return a sourced comparison."])
        let failed=try await wait(b,"failed");let count=(failed["messages"] as! [[String:Any]]).count
        require(failed["phase"] as? String=="instructions","generation failure retains the completed interview phase")
        _ = try call(b,"retry",["requestId":"retry-profile"]);let retried=try await wait(b,"ready")
        require((retried["messages"] as! [[String:Any]]).count==count+1,"retry regenerates instructions without repeating the questionnaire or user answers")
        let slow=try call(c,"begin");_ = try call(c,"answer",["requestId":"slow","revision":slow["revision"]!,"text":"SLOW_PROFILE: research public evidence for a concise report."])
        _ = try await wait(c,"generating")
        let edited=try call(c,"edit",["role":"My chosen role","instructions":"My manual instructions win."])
        try await Task.sleep(nanoseconds:200_000_000)
        require(try call(c,"status")["instructions"] as? String=="My manual instructions win.","manual edits cancel generation and cannot be overwritten by its late result")
        require(edited["source"] as? String=="manual","manual instruction provenance is retained")
        let long=try call(d,"begin");_ = try call(d,"answer",["requestId":"long","revision":long["revision"]!,"text":"LONG_PROFILE: research public evidence and keep the user's boundaries."])
        let shortened=try await wait(d,"ready")
        require(((shortened["instructions"] as? String)?.count ?? 1600)<=1500,"overlong generated instructions are rewritten, never silently truncated")
        let calls=try String(contentsOf:root.appendingPathComponent("AgentSetup/fixture-calls.jsonl"),encoding:.utf8).split(separator:"\n").suffix(3).map{try JSONSerialization.jsonObject(with:Data($0.utf8)) as! [String:Any]}
        require(calls.map{$0["phase"] as! String}==["questions","instructions","instructions"] && calls.last?["repair"] as? Bool==true,"overlong profile gets one separate, tool-free shortening call")
        require((calls.last?["budget"] as? Double ?? 1)<(calls.first?["budget"] as? Double ?? 0),"shortening shares the original turn budget")
        let restored=BuddyAgentSetup(support:root,makeProcess:make,keyReader:{_ in "fixture-key"})
        require((try restored.request(workspace:workspace,payload:["action":"status","agentId":a])["interview"] as? [String:Any])?["status"] as? String=="ready","completed setup survives app restart")
        do{_ = try restored.request(workspace:UUID().uuidString,payload:["action":"begin","agentId":a]);require(false,"cross-workspace setup rejected")}catch{}
        service.shutdown();restored.shutdown()
        print("PASS: immediate first question, adaptive follow-up count, Claude-only tool-free interview, separate instruction generation, exact saved profile, idempotency, stale saves, retry, manual-edit precedence and restart isolation")
    }
}
