import Foundation

struct BuddyAIChoice: Codable, Equatable {
    var provider = "chatgpt"
    var chatgptEnabled = true
    var claudeEnabled = true
    /// Kept so older settings files still load. Runs have no limit of their own (`BuddyRunLimit.none`); whatever an old file says is ignored.
    var claudeBudgetUSD = BuddyRunLimit.none
    var chatgptRevision = "initial"
    var claudeRevision = "initial"
    /// A new value each time "Switch all agents to …" is applied. The worker follows it once: each scheduled routine then moves to its agent's
    /// provider and model (otherwise a routine keeps the provider it was saved with). Optional, so older settings files still load.
    var teamSwitch: String? = nil
    func enabled(_ provider: String) -> Bool { provider == "chatgpt" ? chatgptEnabled : provider == "claude" && claudeEnabled }
    func revision(_ provider: String) -> String { provider == "claude" ? claudeRevision : chatgptRevision }
}

@MainActor final class BuddyAISettings {
    private struct Saved: Codable { var version = 1; var workspaces: [String: BuddyAIChoice] = [:] }
    private let support: URL
    init(support: URL) { self.support = support }
    private var url: URL { support.appendingPathComponent("ai-providers.json") }
    private func saved() throws -> Saved {
        guard FileManager.default.fileExists(atPath: url.path) else { return Saved() }
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 1024*1024 else { throw BuddyFailure(message: "Provider settings are too large.") }
            let saved = try JSONDecoder().decode(Saved.self, from: data)
            guard saved.version == 1, saved.workspaces.allSatisfy({ UUID(uuidString: $0.key) != nil && ["chatgpt", "claude"].contains($0.value.provider) }) else { throw BuddyFailure(message: "Invalid provider settings.") }
            return saved
        } catch { throw BuddyFailure(message: "Buddy couldn’t verify your AI settings. Restore ai-providers.json before reconnecting or starting work.") }
    }
    func current(_ workspace: String) throws -> BuddyAIChoice {
        guard UUID(uuidString: workspace) != nil else { throw BuddyFailure(message: "This workspace is unavailable.") }
        var choice = try saved().workspaces[workspace] ?? BuddyAIChoice()
        choice.claudeBudgetUSD = BuddyRunLimit.none
        return choice
    }
    @discardableResult func update(_ workspace: String, provider: String? = nil, enabled: (String, Bool)? = nil, budget: Double? = nil, teamSwitch: Bool = false) throws -> BuddyAIChoice {
        var saved = try self.saved(); var choice = try current(workspace)
        if let provider { guard ["chatgpt", "claude"].contains(provider) else { throw BuddyFailure(message: "Choose ChatGPT or Claude.") }; choice.provider = provider }
        if teamSwitch { choice.teamSwitch = UUID().uuidString }
        _ = budget   // there is no per-run limit to set any more
        if let (provider, value) = enabled {
            guard ["chatgpt", "claude"].contains(provider) else { throw BuddyFailure(message: "Unsupported provider.") }
            if provider == "chatgpt" { choice.chatgptEnabled = value; choice.chatgptRevision = UUID().uuidString }
            else { choice.claudeEnabled = value; choice.claudeRevision = UUID().uuidString }
        }
        saved.workspaces[workspace] = choice
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try JSONEncoder().encode(saved).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return choice
    }
}

struct BuddyAgentModelSelection: Codable, Equatable {
    let provider: String
    let model: String
    /// The model the agent had on the other provider when "Switch all agents to …" moved it, by provider. Switching back restores it. Optional, so
    /// older agent-models.json files still load and older Buddy ignores it.
    var alternates: [String: String]? = nil
    static func valid(_ model:String)->Bool {model.isEmpty || model.range(of:#"^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$"#,options:.regularExpression) != nil}
    var isValid:Bool {["chatgpt","claude"].contains(provider) && Self.valid(model) && (alternates ?? [:]).allSatisfy{["chatgpt","claude"].contains($0.key) && $0.key != provider && !$0.value.isEmpty && Self.valid($0.value)}}
    var payload:[String:Any] {["provider":provider,"model":model]}
    static func initial(_ provider:String)->Self {Self(provider:provider,model:provider=="claude" ? "claude-sonnet-4-6":"")}
    /// The model this agent uses on `provider`: its own when it is on that provider, else the one it had there before a switch, else that provider's
    /// default. Coding sessions use it for Claude, so an agent switched to ChatGPT keeps coding on the Claude model it had.
    func model(on provider:String)->String {provider==self.provider ? model : alternates?[provider] ?? Self.initial(provider).model}
}

/// Native, per-agent preferences are separate from web state and account credentials.
@MainActor final class BuddyAgentModels {
    private struct Saved:Codable {var version=1;var workspaces:[String:[String:BuddyAgentModelSelection]]=[:]}
    private let file:URL
    init(support:URL){file=support.appendingPathComponent("agent-models.json")}
    private func load() throws -> Saved {
        guard FileManager.default.fileExists(atPath:file.path) else{return Saved()}
        do {
            let data=try Data(contentsOf:file)
            guard data.count<=2*1024*1024 else{throw BuddyFailure(message:"Model settings are too large.")}
            let saved=try JSONDecoder().decode(Saved.self,from:data)
            guard saved.version==1,saved.workspaces.allSatisfy({w,agents in UUID(uuidString:w) != nil && agents.count<=1000 && agents.allSatisfy({id,s in UUID(uuidString:id) != nil && s.isValid})}) else{throw BuddyFailure(message:"Invalid model settings.")};return saved
        } catch {throw BuddyFailure(message:"Buddy couldn’t verify saved agent models. Restore agent-models.json before changing models or starting work.")}
    }
    private func save(_ value:Saved) throws {
        try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
        try JSONEncoder().encode(value).write(to:file,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
    }
    func selection(workspace:String,agent:String) throws -> BuddyAgentModelSelection? {try load().workspaces[workspace]?[agent]}
    @discardableResult func ensure(workspace:String,agents:[String],provider:String) throws -> [String:BuddyAgentModelSelection] {
        guard UUID(uuidString:workspace) != nil,agents.count<=1000,agents.allSatisfy({UUID(uuidString:$0) != nil}),["chatgpt","claude"].contains(provider) else{throw BuddyFailure(message:"This agent’s model is unavailable.")}
        var value=try load(),current=value.workspaces[workspace] ?? [:],changed=false
        for id in agents where current[id]==nil {current[id] = .initial(provider);changed=true}
        if changed {value.workspaces[workspace]=current;try save(value)}
        return current.filter{agents.contains($0.key)}
    }
    func set(workspace:String,agent:String,selection:BuddyAgentModelSelection) throws {
        guard UUID(uuidString:workspace) != nil,UUID(uuidString:agent) != nil,selection.isValid else{throw BuddyFailure(message:"Choose a valid model for this agent.")}
        var saved=try load();var agents=saved.workspaces[workspace] ?? [:]
        // Choosing one agent's model keeps what a team switch remembered for the other provider, until the agent is on that provider again.
        var value=selection
        if value.alternates==nil,var kept=agents[agent]?.alternates {kept.removeValue(forKey:value.provider);value.alternates=kept.isEmpty ? nil:kept}
        agents[agent]=value;saved.workspaces[workspace]=agents;try save(saved)
    }
    /// Saves several agents' models in one write: all of them, or none if any is invalid.
    func setAll(workspace:String,selections:[String:BuddyAgentModelSelection]) throws {
        guard UUID(uuidString:workspace) != nil,selections.count<=1000,selections.allSatisfy({UUID(uuidString:$0.key) != nil && $0.value.isValid}) else{throw BuddyFailure(message:"Choose a valid model for every agent.")}
        var saved=try load();var agents=saved.workspaces[workspace] ?? [:]
        for (agent,selection) in selections {agents[agent]=selection}
        guard agents.count<=1000 else{throw BuddyFailure(message:"Choose a valid model for every agent.")}
        saved.workspaces[workspace]=agents;try save(saved)
    }
}

enum BuddyModelCatalog {
    static func claude(_ rows:[[String:Any]]) -> [[String:Any]] {
        let active=rows.filter{row in
            guard row["lifecycle"] as? String=="active",let id=row["id"] as? String,id.hasPrefix("claude-"),BuddyAgentModelSelection.valid(id) else{return false};return true
        }
        let preferred=active.first{$0["line"] as? String=="sonnet"}?["id"] as? String
        // The API orders releases newest first. Use its explicit line metadata;
        // unfamiliar/ungrouped models remain visible rather than guessing a family.
        var lines=Set<String>()
        return active.map{row in
            let id=row["id"] as! String
            let current=(row["line"] as? String).map{lines.insert($0).inserted} ?? true
            var model:[String:Any]=["provider":"claude","id":id,"name":row["display_name"] as? String ?? id,"isDefault":id==preferred,"current":current]
            if let line=row["line"] as? String {model["line"]=line}   // the family (opus, sonnet, haiku): a team switch maps sizes by it
            return model
        }
    }
}

/// "Switch all agents to Claude / ChatGPT": each agent moves to the model it had on that provider before, else to the same size of model there.
enum BuddyProviderSwitch {
    enum Tier: String { case large, standard, small }
    /// A model's size. Claude: its family (opus large, sonnet standard, haiku small), from the catalog's `line`, else its id or name. ChatGPT: the
    /// words in its id or name (mini, nano, small, lite, flash: small; max, pro, ultra: large). Anything else, an unknown model included, is standard.
    static func tier(_ row:[String:Any])->Tier {
        let id=(row["id"] as? String ?? "").lowercased(),name=(row["name"] as? String ?? "").lowercased()
        if row["provider"] as? String=="claude" {
            for text in [(row["line"] as? String ?? "").lowercased(),id,name] {
                if text.contains("opus") {return .large};if text.contains("haiku") {return .small};if text.contains("sonnet") {return .standard}
            }
            return .standard
        }
        // Whole words, so "prompt" is not "pro" and "realtime" is not "lite".
        let words=Set((id+" "+name).split{!$0.isLetter && !$0.isNumber}.map(String.init))
        if !words.isDisjoint(with:["mini","nano","small","lite","flash"]) {return .small}
        if !words.isDisjoint(with:["max","pro","ultra"]) {return .large}
        return .standard
    }
    /// The model of `tier` among `provider`'s models in `catalog` (newest first): the provider's default if it is that size, else the first listed.
    /// Without that size, the standard one, then the default, then the first. Older releases the model picker no longer offers are skipped.
    static func equivalent(_ tier:Tier,provider:String,in catalog:[[String:Any]])->String? {
        let offered=catalog.filter{$0["provider"] as? String==provider && $0["current"] as? Bool != false && !($0["id"] as? String ?? "").isEmpty}
        func pick(_ size:Tier)->[String:Any]? {let same=offered.filter{self.tier($0)==size};return same.first{$0["isDefault"] as? Bool==true} ?? same.first}
        return (pick(tier) ?? pick(.standard) ?? offered.first{$0["isDefault"] as? Bool==true} ?? offered.first)?["id"] as? String
    }
    struct Move { let agent:String; let from:BuddyAgentModelSelection; let to:BuddyAgentModelSelection; let how:String }
    /// Where each agent goes. An agent already on `target` stays as it is ("unchanged"). Otherwise it gets the model it last had there if that is
    /// still listed ("remembered"), else the equivalent size ("equivalent"), and remembers the model it is leaving. Nil when `target` lists nothing.
    static func plan(agents:[String],selections:[String:BuddyAgentModelSelection],target:String,catalog:[[String:Any]])->[Move]? {
        var moves:[Move]=[]
        for agent in agents {
            let from=selections[agent] ?? .initial(target)
            if from.provider==target {moves.append(Move(agent:agent,from:from,to:from,how:"unchanged"));continue}
            var remembered=from.alternates ?? [:]
            let back=remembered[target].flatMap{id in catalog.contains{$0["provider"] as? String==target && $0["id"] as? String==id} ? id:nil}
            let source=catalog.first{$0["provider"] as? String==from.provider && $0["id"] as? String==from.model} ?? ["provider":from.provider,"id":from.model,"name":from.model]
            guard let model=back ?? equivalent(tier(source),provider:target,in:catalog) else {return nil}
            if !from.model.isEmpty {remembered[from.provider]=from.model}
            remembered.removeValue(forKey:target)
            moves.append(Move(agent:agent,from:from,to:BuddyAgentModelSelection(provider:target,model:model,alternates:remembered.isEmpty ? nil:remembered),how:back==nil ? "equivalent":"remembered"))
        }
        return moves
    }
    /// What the preview says stays on Claude.
    static func note(supervisor:String?)->String {
        (supervisor.map{"Coding sessions and \($0)'s background supervision run on Claude."} ?? "Coding sessions run on Claude.")+" They keep using Claude while it stays connected."
    }
}

private final class BuddyModelHTTP:NSObject,URLSessionTaskDelegate {
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void){completionHandler(nil)}
    static func claude(apiKey:String) async throws -> [[String:Any]] {
        let config=URLSessionConfiguration.ephemeral;config.timeoutIntervalForRequest=20;config.timeoutIntervalForResource=30;config.httpCookieStorage=nil;config.urlCache=nil
        let session=URLSession(configuration:config,delegate:BuddyModelHTTP(),delegateQueue:nil);defer{session.invalidateAndCancel()}
        var cursor="",seen=Set<String>(),models:[[String:Any]]=[]
        for _ in 0..<10 {
            var url=URLComponents(string:"https://api.anthropic.com/v1/models")!;url.queryItems=[URLQueryItem(name:"limit",value:"100"),URLQueryItem(name:"lifecycle[]",value:"active")]
            if !cursor.isEmpty {url.queryItems?.append(URLQueryItem(name:"after_id",value:cursor))}
            var request=URLRequest(url:url.url!);request.setValue(apiKey,forHTTPHeaderField:"x-api-key");request.setValue("2023-06-01",forHTTPHeaderField:"anthropic-version")
            let (data,response)=try await session.data(for:request)
            guard let response=response as? HTTPURLResponse,response.statusCode==200,data.count<=4*1024*1024,let page=try JSONSerialization.jsonObject(with:data) as? [String:Any],let rows=page["data"] as? [[String:Any]] else{throw BuddyFailure(message:"Couldn’t load Claude models. Check the Claude connection and try Refresh.")}
            models += rows
            if page["has_more"] as? Bool != true {return BuddyModelCatalog.claude(models)}
            guard let next=page["last_id"] as? String,!next.isEmpty,seen.insert(next).inserted else{throw BuddyFailure(message:"Claude’s model list did not finish. Refresh before choosing a model.")};cursor=next
        }
        throw BuddyFailure(message:"Claude’s model list exceeded its limit. Try refreshing.")
    }
}

extension BuddyAISettings {
    static func claudeModels(apiKey:String) async throws -> [[String:Any]] {try await BuddyModelHTTP.claude(apiKey:apiKey)}
}
