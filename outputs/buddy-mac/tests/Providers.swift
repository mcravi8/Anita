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
        invalid=false;do{_ = try settings.update(workspace,budget:Double.nan)}catch{invalid=true};require(invalid,"invalid spending limit rejected")
        let primary=ConversationService(support:root,executable:URL(fileURLWithPath:CommandLine.arguments[1]))
        primary.agentPermission={w,keys in w==workspace && keys == [key]};primary.filePermission={w,keys in w==workspace && keys == [key]};primary.computerPermission={_,_ in false}
        let router=BuddyAIRouter(support:root,chatgpt:primary,makeProcess:{BuddyWorkerProcess(resource:URL(fileURLWithPath:CommandLine.arguments[2]),runtime:URL(fileURLWithPath:CommandLine.arguments[3]))},keyReader:{_ in "fixture-key"},keyRemover:{_ in})
        defer{router.shutdown()}
        var events:[[String:Any]]=[];router.onEvent={events.append($0)}
        var options=BuddyTurnOptions();options.actorId=agent;options.fileScope=try primary.projectFiles.scope(workspace);options.history="Earlier ChatGPT answer"
        func send(_ text:String,_ options:BuddyTurnOptions) throws->String {let id=UUID().uuidString;_ = try router.send(["runId":id,"key":key,"agent":["name":"Check","role":"Provider fixture","description":"Inert verification"],"text":text],options:options);return id}
        func terminal(_ id:String)->Bool{events.contains{$0["type"] as? String == "run" && $0["runId"] as? String == id && ["completed","failed","stopped"].contains($0["status"] as? String ?? "")}}
        let first=try send("HISTORY_CHECK",options);await wait{terminal(first)}
        require(events.contains{$0["runId"] as? String == first && $0["text"] as? String == "Claude fixture answer" && $0["status"] as? String == "completed"},"selected Claude actually answers through Claude bridge with real prior history")
        let file=try send("WRITE_CLAUDE",options);await wait{terminal(file)}
        let saved=try primary.projectFiles.read(options.fileScope!,path:"claude-note.md")
        require((saved["content"] as? String)?.contains("selected Claude") == true,"Claude uses the existing scoped file engine and real saved bytes")
        var grouped=options;grouped.routingGroup=UUID().uuidString;grouped.outputSchema=["type":"object","properties":["ok":["type":"boolean"]],"required":["ok"]]
        let group1=try send("SCHEMA_CLAUDE",grouped);await wait{terminal(group1)}
        _ = try await router.select(workspace:workspace,provider:"chatgpt",budget:nil)
        let group2=try send("SCHEMA_CLAUDE",grouped);await wait{terminal(group2)}
        require(events.contains{$0["runId"] as? String == group2 && ($0["text"] as? String)?.contains("\"ok\"") == true},"in-flight group keeps its provider and structured planning output")
        let gpt=try send("GPT_CHECK",options);await wait{terminal(gpt)}
        require(events.contains{$0["runId"] as? String == gpt && $0["text"] as? String == "ChatGPT fixture answer" && $0["status"] as? String == "completed"},"new turns use selected ChatGPT without changing history")
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
        print("PASS: persistent provider selection, workspace isolation, budget validation, actual ChatGPT/Claude routing, shared conversation context, scoped file writes, structured group output, pinned group provider, disconnect/reconnect, stopped work and no automatic fallback")
        try Data("broken".utf8).write(to:root.appendingPathComponent("ai-providers.json"));invalid=false;do{_ = try settings.current(workspace)}catch{invalid=true};require(invalid,"corrupt provider settings fail closed")
    }
}
