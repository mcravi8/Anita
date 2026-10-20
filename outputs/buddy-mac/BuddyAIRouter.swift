import Foundation

@MainActor final class BuddyAIRouter: BuddyConversationSending {
    var onEvent: (([String: Any]) -> Void)?
    let settings: BuddyAISettings
    private let support: URL
    private let keyRemover: (String) throws -> Void
    private let keyReader: (String) -> String?
    private let chatgpt: ConversationService
    let claude: BuddyClaudeConversations
    private var providers: [String: String] = [:]
    let agentModels:BuddyAgentModels
    private var groupModels:[String:BuddyAgentModelSelection]=[:]
    private var historyProviders:[String:String]=[:]
    private var invalidHistoryProviders=false
    private let claudeModelReader:(String) async throws -> [[String:Any]]
    private var claudeCatalog:[String:(revision:String,at:Date,models:[[String:Any]])]=[:]

    init(support: URL, chatgpt: ConversationService, makeProcess: (() -> BuddyWorkerProcess)? = nil, keyReader: @escaping (String) -> String? = BuddyClaudeKey.read, keyRemover: @escaping (String) throws -> Void = { try BuddyClaudeKey.save(nil, workspace: $0) }, claudeModelReader: @escaping (String) async throws -> [[String:Any]] = {try await BuddyAISettings.claudeModels(apiKey:$0)}) {
        self.support=support;self.chatgpt=chatgpt;self.keyReader=keyReader;self.keyRemover=keyRemover;self.agentModels=BuddyAgentModels(support:support);self.claudeModelReader=claudeModelReader
        let history=support.appendingPathComponent("conversation-providers.json")
        if FileManager.default.fileExists(atPath:history.path) {
            if let data=try? Data(contentsOf:history),data.count<=2*1024*1024,let saved=try? JSONDecoder().decode([String:String].self,from:data),saved.allSatisfy({$0.key.count<=200 && ["chatgpt","claude"].contains($0.value)}) {historyProviders=saved}
            else {invalidHistoryProviders=true}
        }
        let settings=BuddyAISettings(support:support);self.settings=settings
        claude=BuddyClaudeConversations(support:support,primary:chatgpt,settings:settings,makeProcess:makeProcess,keyReader:keyReader)
        chatgpt.onEvent = { [weak self] event in self?.onEvent?(event) }
        claude.onEvent = { [weak self] event in self?.onEvent?(event) }
    }
    func send(_ payload:[String:Any],options:BuddyTurnOptions) throws->[String:Any] {
        let workspace=options.fileScope?.workspace ?? options.fileContext?.workspace ?? options.proposalScope?.workspace ?? String((payload["key"] as? String ?? "").prefix(36))
        let choice=try settings.current(workspace),id=payload["runId"] as? String ?? ""
        if providers[id] != nil { return ["accepted":true,"runId":id] }
        guard !snapshots().contains(where:{$0["key"] as? String==payload["key"] as? String && ["starting","answering","stopping"].contains($0["status"] as? String ?? "")}) else{throw BuddyFailure(message:"This agent is already answering. Your new model applies to its next reply.")}
        var options=options
        let agentChoice=try agentModels.selection(workspace:workspace,agent:options.actorId) ?? .initial(choice.provider)
        let groupKey=options.routingGroup.map{$0+":"+options.actorId}
        let pinned=groupKey.flatMap{groupModels[$0]} ?? agentChoice
        let selected=pinned.provider
        if options.selectedModel==nil,!pinned.model.isEmpty {options.selectedModel=pinned.model}
        guard choice.enabled(selected) else {throw BuddyFailure(message:"Connect \(selected == "claude" ? "Claude":"ChatGPT") in Settings → AI provider, then try again.")}
        if let groupKey {groupModels[groupKey]=pinned}
        let conversationKey=payload["key"] as? String ?? ""
        let track=options.historyScope != nil && !options.internalRun
        let previous=historyProviders
        if track {
            guard !invalidHistoryProviders else{throw BuddyFailure(message:"Saved conversation routing could not be verified. Restore conversation-providers.json before switching models.")}
            options.resetConversation=historyProviders[conversationKey] != selected
            historyProviders[conversationKey]=selected
            do {try FileManager.default.createDirectory(at:support,withIntermediateDirectories:true);try JSONEncoder().encode(historyProviders).write(to:support.appendingPathComponent("conversation-providers.json"),options:.atomic)}
            catch {historyProviders=previous;throw error}
        }
        providers[id]=selected
        do { return try selected == "claude" ? claude.send(payload,options:options):chatgpt.send(payload,options:options) }
        catch {providers.removeValue(forKey:id);if track {historyProviders=previous;try? JSONEncoder().encode(previous).write(to:support.appendingPathComponent("conversation-providers.json"),options:.atomic)};throw error}
    }
    func stop(_ id:String) async throws->[String:Any] {try await providers[id] == "claude" ? claude.stop(id):chatgpt.stop(id)}
    func snapshots()->[[String:Any]] {chatgpt.snapshots()+claude.snapshots()}
    func pendingInputs(workspace:String)->[[String:Any]] {chatgpt.pendingInputs(workspace:workspace)+claude.pendingInputs(workspace:workspace)}
    func answerInput(workspace:String,payload:[String:Any]) throws->[String:Any] {
        if let id=payload["id"] as? String,claude.pendingInputs(workspace:workspace).contains(where:{$0["id"] as? String == id}) {return try claude.answerInput(workspace:workspace,payload:payload)}
        guard try settings.current(workspace).chatgptEnabled else {throw BuddyFailure(message:"ChatGPT is disconnected in Buddy. This action was not approved.")}
        return try chatgpt.answerInput(workspace:workspace,payload:payload)
    }
    func status(workspace:String,refresh:Bool=false) async throws->[String:Any] {
        var choice=try settings.current(workspace)
        var gpt:[String:Any] = ["connected":false,"enabled":choice.chatgptEnabled]
        if choice.chatgptEnabled {do {gpt.merge(try await chatgpt.connection(refresh:refresh)){_,new in new}}catch{gpt["error"]=error.localizedDescription}}
        choice=try settings.current(workspace)
        if !choice.chatgptEnabled { gpt=["connected":false,"enabled":false] }
        let claudeConnected=choice.claudeEnabled && keyReader(workspace) != nil
        let connected=choice.provider == "claude" ? claudeConnected:gpt["connected"] as? Bool == true
        return ["provider":choice.provider,"connected":connected,"chatgpt":gpt,"claude":["connected":claudeConnected,"enabled":choice.claudeEnabled],"plan":gpt["plan"] ?? NSNull(),"error":connected ? "":"Connect \(choice.provider == "claude" ? "Claude":"ChatGPT") in Settings → AI provider."]
    }
    func select(workspace:String,provider:String,budget:Double?) async throws->[String:Any] {try ensureAgentDefaults(workspace:workspace);_ = try settings.update(workspace,provider:provider,budget:budget);return try await status(workspace:workspace)}
    func disconnect(workspace:String,provider:String) async throws->[String:Any] {
        _ = try settings.update(workspace,enabled:(provider,false))
        if provider == "claude" {claude.stopAll();try keyRemover(workspace)}
        else {
            for (id, provider) in providers where provider == "chatgpt" { _ = try? await chatgpt.stop(id) }
            claude.stopConnected()
        }
        return try await status(workspace:workspace)
    }
    func connectChatGPT(workspace:String) async throws->[String:Any] {
        let connection=try await chatgpt.connection(refresh:true)
        _ = try settings.update(workspace,enabled:("chatgpt",true))
        if connection["connected"] as? Bool == true {return ["status":try await status(workspace:workspace)]}
        return ["login":try await chatgpt.signIn(),"status":try await status(workspace:workspace)]
    }
    func didConnectClaude(workspace:String) async throws->[String:Any] {claude.stopAll();_ = try settings.update(workspace,enabled:("claude",true));return try await status(workspace:workspace)}
    func stopForAgent(_ key:String) async {await chatgpt.stopForAgent(key);claude.stopForAgent(key)}
    func stopFiles(workspace:String) async {await chatgpt.stopFiles(workspace:workspace);claude.stopFiles(workspace:workspace)}
    func ensureAgentDefaults(workspace:String,agents:[String]?=nil) throws {
        let ids:[String]
        if let agents {ids=agents}
        else if let data=try? Data(contentsOf:support.appendingPathComponent("workspace.json")),let state=try? JSONSerialization.jsonObject(with:data) as? [String:Any],state["conversationWorkspace"] as? String==workspace {ids=(state["agents"] as? [[String:Any]] ?? []).compactMap{$0["id"] as? String}}
        else {return}
        _ = try agentModels.ensure(workspace:workspace,agents:ids,provider:settings.current(workspace).provider)
    }
    private func modelCatalog(workspace:String,refresh:Bool) async -> (models:[[String:Any]],errors:[String:String]) {
        guard let choice=try? settings.current(workspace) else{return ([],["settings":"AI settings are unavailable."])}
        let gpt=Task { () -> ([[String:Any]],String?) in
            guard choice.chatgptEnabled else{return ([],nil)}
            do{return (try await self.chatgpt.availableModels(refresh:refresh),nil)}catch{return ([],error.localizedDescription)}
        }
        let claude=Task { () -> ([[String:Any]],String?) in
            guard choice.claudeEnabled,let key=self.keyReader(workspace) else{return ([],nil)}
            if !refresh,let cached=self.claudeCatalog[workspace],cached.revision==choice.claudeRevision,Date().timeIntervalSince(cached.at)<300{return (cached.models,nil)}
            do {
                let models=try await self.claudeModelReader(key)
                let clean=models.filter{v in guard v["provider"] as? String=="claude",let id=v["id"] as? String,!id.isEmpty,BuddyAgentModelSelection.valid(id) else{return false};return true}
                self.claudeCatalog[workspace]=(choice.claudeRevision,Date(),clean);return (clean,nil)
            }catch{return ([],error.localizedDescription)}
        }
        let a=await gpt.value,b=await claude.value
        guard let current=try? settings.current(workspace) else{return ([],["settings":"AI settings are unavailable."])}
        var errors:[String:String]=[:];if current.chatgptEnabled,let error=a.1{errors["chatgpt"]=error};if current.claudeEnabled,let error=b.1{errors["claude"]=error}
        return ((current.chatgptEnabled && current.chatgptRevision==choice.chatgptRevision ? a.0:[])+(current.claudeEnabled && current.claudeRevision==choice.claudeRevision && keyReader(workspace) != nil ? b.0:[]),errors)
    }
    func modelSettings(workspace:String,agents:[String],payload:[String:Any]) async throws -> [String:Any] {
        try ensureAgentDefaults(workspace:workspace,agents:agents)
        let catalog=await modelCatalog(workspace:workspace,refresh:payload["refresh"] as? Bool ?? false)
        var selections=try agentModels.ensure(workspace:workspace,agents:agents,provider:settings.current(workspace).provider)
        for (agent,selection) in selections where selection.model.isEmpty {
            if let model=(catalog.models.first{$0["provider"] as? String==selection.provider && $0["isDefault"] as? Bool==true} ?? catalog.models.first{$0["provider"] as? String==selection.provider})?["id"] as? String {let value=BuddyAgentModelSelection(provider:selection.provider,model:model);try agentModels.set(workspace:workspace,agent:agent,selection:value);selections[agent]=value}
        }
        if payload["operation"] as? String=="set" {
            guard let agent=payload["agentId"] as? String,agents.contains(agent),chatgpt.agentPermission?(workspace,[workspace+":"+agent])==true,let provider=payload["provider"] as? String,let model=payload["model"] as? String,catalog.models.contains(where:{$0["provider"] as? String==provider && $0["id"] as? String==model && $0["current"] as? Bool != false}),try settings.current(workspace).enabled(provider),provider != "claude" || keyReader(workspace) != nil else{throw BuddyFailure(message:"This model is unavailable or its connection is off. Refresh models or reconnect in Settings.")}
            let value=BuddyAgentModelSelection(provider:provider,model:model);try agentModels.set(workspace:workspace,agent:agent,selection:value);selections[agent]=value
        }
        return ["models":catalog.models,"agents":selections.mapValues(\.payload),"errors":catalog.errors,"defaultProvider":try settings.current(workspace).provider,"saved":payload["operation"] as? String=="set"]
    }
    /// "Switch all agents to Claude / ChatGPT". A preview (`dryRun`) saves nothing; the switch saves every agent's new model in one write, makes
    /// `target` the starting provider for new agents and stamps the switch so scheduled routines follow it. Nothing running is stopped: a reply
    /// under way keeps its model, and each agent's next reply and next task use the new one. Coding sessions and the supervisor's lane stay on Claude.
    func switchProvider(workspace:String,to target:String,agents:[String],dryRun:Bool,supervisor:String?=nil) async throws -> [String:Any] {
        guard ["chatgpt","claude"].contains(target) else{throw BuddyFailure(message:"Choose ChatGPT or Claude.")}
        let refusal=BuddyFailure(message:"Connect \(target=="claude" ? "Claude":"ChatGPT") in Settings → AI provider first.")
        func connected() throws -> Bool {try settings.current(workspace).enabled(target) && (target != "claude" || keyReader(workspace) != nil)}
        guard try connected() else{throw refusal}
        try ensureAgentDefaults(workspace:workspace,agents:agents)
        let catalog=await modelCatalog(workspace:workspace,refresh:false)
        // Checked again after the catalogs load: a disconnect or a removed agent in the meantime wins.
        guard try connected(),catalog.models.contains(where:{$0["provider"] as? String==target}) else{throw refusal}
        let team=agents.filter{chatgpt.agentPermission?(workspace,[workspace+":"+$0])==true}
        let selections=try agentModels.ensure(workspace:workspace,agents:team,provider:settings.current(workspace).provider)
        guard let moves=BuddyProviderSwitch.plan(agents:team,selections:selections,target:target,catalog:catalog.models) else{throw refusal}
        if !dryRun {
            try agentModels.setAll(workspace:workspace,selections:Dictionary(uniqueKeysWithValues:moves.filter{$0.how != "unchanged"}.map{($0.agent,$0.to)}))
            _ = try settings.update(workspace,provider:target,teamSwitch:true)
        }
        func describe(_ s:BuddyAgentModelSelection)->[String:Any] {
            let name=catalog.models.first{$0["provider"] as? String==s.provider && $0["id"] as? String==s.model}?["name"] as? String
            return ["provider":s.provider,"model":s.model,"name":name ?? (s.model.isEmpty ? "Account default":s.model)]
        }
        return ["provider":target,"dryRun":dryRun,"applied":!dryRun,"agents":moves.map{["agentId":$0.agent,"from":describe($0.from),"to":describe($0.to),"how":$0.how]},"note":BuddyProviderSwitch.note(supervisor:supervisor)]
    }
    func shutdown(){claude.shutdown();chatgpt.shutdown()}
}
