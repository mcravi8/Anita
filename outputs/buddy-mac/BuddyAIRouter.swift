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
    private var groupProviders: [String: String] = [:]
    init(support: URL, chatgpt: ConversationService, makeProcess: (() -> BuddyWorkerProcess)? = nil, keyReader: @escaping (String) -> String? = BuddyClaudeKey.read, keyRemover: @escaping (String) throws -> Void = { try BuddyClaudeKey.save(nil, workspace: $0) }) {
        self.support=support;self.chatgpt=chatgpt;self.keyReader=keyReader;self.keyRemover=keyRemover
        let settings=BuddyAISettings(support:support);self.settings=settings
        claude=BuddyClaudeConversations(support:support,primary:chatgpt,settings:settings,makeProcess:makeProcess,keyReader:keyReader)
        chatgpt.onEvent = { [weak self] event in self?.onEvent?(event) }
        claude.onEvent = { [weak self] event in self?.onEvent?(event) }
    }
    func send(_ payload:[String:Any],options:BuddyTurnOptions) throws->[String:Any] {
        let workspace=options.fileScope?.workspace ?? options.fileContext?.workspace ?? options.proposalScope?.workspace ?? String((payload["key"] as? String ?? "").prefix(36))
        let choice=try settings.current(workspace),id=payload["runId"] as? String ?? ""
        if providers[id] != nil { return ["accepted":true,"runId":id] }
        let selected=options.routingGroup.flatMap{groupProviders[$0]} ?? choice.provider
        guard choice.enabled(selected) else {throw BuddyFailure(message:"Connect \(selected == "claude" ? "Claude":"ChatGPT") in Settings → AI provider, then try again.")}
        if let group=options.routingGroup {groupProviders[group]=selected}
        providers[id]=selected
        do { return try selected == "claude" ? claude.send(payload,options:options):chatgpt.send(payload,options:options) }
        catch {providers.removeValue(forKey:id);throw error}
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
        return ["provider":choice.provider,"connected":connected,"chatgpt":gpt,"claude":["connected":claudeConnected,"enabled":choice.claudeEnabled],"claudeBudgetUSD":choice.claudeBudgetUSD,"plan":gpt["plan"] ?? NSNull(),"error":connected ? "":"Connect \(choice.provider == "claude" ? "Claude":"ChatGPT") in Settings → AI provider."]
    }
    func select(workspace:String,provider:String,budget:Double?) async throws->[String:Any] {_ = try settings.update(workspace,provider:provider,budget:budget);return try await status(workspace:workspace)}
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
    func shutdown(){claude.shutdown();chatgpt.shutdown()}
}
