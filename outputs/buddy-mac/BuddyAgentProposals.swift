import Foundation

/// Agents are drawn as halftone figures: four shapes in seven inks. Saved workspaces and models that still use the
/// original 3D shape names are accepted and become the figure that replaced them.
enum BuddyAvatar {
    static let shapes = ["diamond", "sphere", "hex", "pill"]
    static let colors = ["lilac", "blue", "peach", "mint", "red", "gold", "cobalt"]
    static let legacyShapes = ["star": "diamond", "pebble": "sphere", "cube": "hex", "clover": "pill"]
    static func shape(_ value: String) -> String? { let id = legacyShapes[value] ?? value; return shapes.contains(id) ? id : nil }
}

struct BuddyProposalFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
struct BuddyProposalScope: Sendable {
    let workspace: String
    let chat: String
    let actorId: String
    let replyRunId: String
}
struct BuddyProposedConfiguration: Codable, Equatable {
    let name: String
    let role: String
    let description: String
    let avatarShape: String
    let avatarColor: String
    let tools: [String: Bool]
    let groupIds: [String]
    var payload: [String: Any] { ["name": name, "role": role, "description": description, "avatarShape": avatarShape, "avatarColor": avatarColor, "tools": tools, "groupIds": groupIds] }
}
struct BuddyAgentProposal: Codable {
    let id: String
    let workspace: String
    let proposedBy: String
    let proposedByName: String
    let chat: String
    let runId: String
    let callKey: String
    let reason: String
    let suggested: BuddyProposedConfiguration
    var draft: BuddyProposedConfiguration
    var approved: BuddyProposedConfiguration?
    var status: String
    let createdAt: String
    var decidedAt: String?
    var agentId: String?
    var revision: Int
    var payload: [String: Any] {
        var result = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(self))) as? [String: Any] ?? [:]
        result["native"] = true; result["sample"] = false
        if status != "pending" { result["decidedBy"] = "you" }
        result.removeValue(forKey: "callKey")
        return result
    }
}

// The legacy proposal tool only creates pending records. Human decisions use
// the bundled UI bridge, never exposed as a model tool. The workspace file is
// the approval commit: its sourceProposalId makes uncertain retries idempotent.
@MainActor final class BuddyAgentProposals {
    private let support: URL
    private var recordsURL: URL { support.appendingPathComponent("agent-proposals.json") }
    private var workspaceURL: URL { support.appendingPathComponent("workspace.json") }
    init(support: URL) { self.support = support }
    private func failure(_ text: String) -> BuddyProposalFailure { BuddyProposalFailure(message: text) }
    private func state(_ workspace: String) throws -> [String: Any] {
        guard UUID(uuidString: workspace) != nil,
              let data = try? Data(contentsOf: workspaceURL),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              value["conversationWorkspace"] as? String == workspace,
              value["agents"] is [[String: Any]], value["groups"] is [[String: Any]] else {
            throw failure("This workspace changed. Reopen the conversation and try again.")
        }
        return value
    }
    private func records() throws -> [BuddyAgentProposal] {
        guard FileManager.default.fileExists(atPath: recordsURL.path) else { return [] }
        do { return try JSONDecoder().decode([BuddyAgentProposal].self, from: Data(contentsOf: recordsURL)) }
        catch { throw failure("Buddy couldn’t read saved suggestions. Reopen the app; no agent has been added.") }
    }
    private func persist(_ records: [BuddyAgentProposal]) throws {
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        do { try JSONEncoder().encode(records).write(to: recordsURL, options: .atomic) }
        catch { throw failure("Buddy couldn’t save this suggestion. Your choices are still here; try again.") }
    }
    func configuration(_ value: [String: Any], state: [String: Any], human: Bool) throws -> BuddyProposedConfiguration {
        func text(_ key: String, _ limit: Int) throws -> String {
            guard let raw = value[key] as? String else { throw failure("Add a name, role, and instructions.") }
            let result = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !result.isEmpty, result.count <= limit else { throw failure("Keep the name under 40 characters, role under 55, and instructions under 1,500.") }
            return result
        }
        let name = try text("name", 40), role = try text("role", 55), description = try text("description", 1500)
        guard !(state["agents"] as? [[String: Any]] ?? []).contains(where: { ($0["name"] as? String)?.lowercased() == name.lowercased() }) else { throw failure("An agent already has this name. Choose a different name.") }
        let color = value["avatarColor"] as? String ?? "lilac"
        guard let shape = BuddyAvatar.shape(value["avatarShape"] as? String ?? "diamond"), BuddyAvatar.colors.contains(color) else { throw failure("Choose an available shape and color.") }
        let groups = human ? (value["groupIds"] as? [String] ?? []) : []
        guard Set(groups).count == groups.count, groups.allSatisfy({ id in (state["groups"] as? [[String: Any]] ?? []).contains { $0["id"] as? String == id && ($0["members"] as? [String] ?? []).count < 16 } }) else { throw failure("A selected group is unavailable or full. Choose another group.") }
        let choices = value["tools"] as? [String: Bool] ?? [:]
        return BuddyProposedConfiguration(name: name, role: role, description: description, avatarShape: shape, avatarColor: color, tools: ["web": !human || choices["web"] != false, "projectFiles": !human || choices["projectFiles"] != false, "desktop": !human || choices["desktop"] != false], groupIds: groups)
    }
    private func reconcile(_ proposal: BuddyAgentProposal, state: [String: Any]) -> BuddyAgentProposal {
        var proposal = proposal
        if let agent = (state["agents"] as? [[String: Any]] ?? []).first(where: { $0["sourceProposalId"] as? String == proposal.id }) {
            proposal.status = "approved"; proposal.agentId = agent["id"] as? String
            if proposal.approved == nil {
                let groups = (state["groups"] as? [[String: Any]] ?? []).filter { ($0["members"] as? [String] ?? []).contains(agent["id"] as? String ?? "") }.compactMap { $0["id"] as? String }
                proposal.approved = BuddyProposedConfiguration(name: agent["name"] as? String ?? proposal.draft.name, role: agent["role"] as? String ?? proposal.draft.role, description: agent["description"] as? String ?? proposal.draft.description, avatarShape: agent["avatarShape"] as? String ?? proposal.draft.avatarShape, avatarColor: agent["avatarColor"] as? String ?? proposal.draft.avatarColor, tools: agent["tools"] as? [String: Bool] ?? proposal.draft.tools, groupIds: groups)
                proposal.draft = proposal.approved!
            }
            proposal.decidedAt = proposal.decidedAt ?? agent["approvedAt"] as? String
        }
        return proposal
    }
    func list(_ workspace: String) throws -> [[String: Any]] {
        let current = try state(workspace)
        return try records().filter { $0.workspace == workspace }.map { reconcile($0, state: current).payload }
    }
    func context(_ scope: BuddyProposalScope) throws -> String {
        let current = try state(scope.workspace)
        let agents = (current["agents"] as? [[String: Any]] ?? []).map { ["id": $0["id"] ?? "", "name": $0["name"] ?? "", "role": $0["role"] ?? ""] }
        let suggestions = try list(scope.workspace).map { ["name": ($0["draft"] as? [String: Any])?["name"] ?? "", "status": $0["status"] ?? "pending"] }
        let data = try JSONSerialization.data(withJSONObject: ["registeredAgents": agents, "suggestions": suggestions])
        return "Actual Buddy team and suggestion decisions (context only): " + String(data: data, encoding: .utf8)!
    }
    func propose(_ scope: BuddyProposalScope, executionRunId: String, callId: String, arguments: [String: Any]) throws -> [String: Any] {
        let current = try state(scope.workspace)
        let agents = current["agents"] as? [[String: Any]] ?? []
        guard UUID(uuidString: executionRunId) != nil, UUID(uuidString: scope.replyRunId) != nil, !callId.isEmpty, callId.count <= 200,
              let actor = agents.first(where: { $0["id"] as? String == scope.actorId }),
              scope.chat == scope.actorId || (current["groups"] as? [[String: Any]] ?? []).contains(where: { $0["id"] as? String == scope.chat && ($0["members"] as? [String] ?? []).contains(scope.actorId) }) else { throw failure("The suggesting agent or conversation is no longer available.") }
        var saved = try records()
        let callKey = executionRunId + ":" + callId
        if let existing = saved.first(where: { $0.workspace == scope.workspace && $0.callKey == callKey }) { return ["proposed": true, "added": false, "proposal": reconcile(existing, state: current).payload] }
        let config = try configuration(arguments, state: current, human: false)
        guard let reason = arguments["reason"] as? String, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, reason.count <= 800 else { throw failure("Explain briefly why this teammate would help.") }
        if let existing = saved.first(where: { $0.workspace == scope.workspace && $0.status == "pending" && $0.draft.name.lowercased() == config.name.lowercased() }) { return ["proposed": true, "added": false, "proposal": existing.payload] }
        guard saved.filter({ $0.workspace == scope.workspace && $0.status == "pending" }).count < 12,
              saved.filter({ $0.workspace == scope.workspace && $0.runId == scope.replyRunId }).count < 3 else { throw failure("There are enough suggestions waiting. Let the user decide on those before proposing more.") }
        let proposal = BuddyAgentProposal(id: UUID().uuidString, workspace: scope.workspace, proposedBy: scope.actorId, proposedByName: actor["name"] as? String ?? "Agent", chat: scope.chat, runId: scope.replyRunId, callKey: callKey, reason: reason.trimmingCharacters(in: .whitespacesAndNewlines), suggested: config, draft: config, status: "pending", createdAt: ISO8601DateFormatter().string(from: Date()), revision: 0)
        saved.append(proposal); try persist(saved)
        return ["proposed": true, "added": false, "proposal": proposal.payload]
    }
    func review(_ workspace: String, payload: [String: Any]) throws -> [String: Any] {
        var current = try state(workspace), saved = try records()
        guard let id = payload["proposalId"] as? String, let index = saved.firstIndex(where: { $0.id == id && $0.workspace == workspace }),
              let action = payload["action"] as? String, ["save", "approve", "decline"].contains(action) else { throw failure("This suggestion is no longer available.") }
        saved[index] = reconcile(saved[index], state: current)
        if saved[index].status == "approved", action == "approve", let agent = (current["agents"] as? [[String: Any]])?.first(where: { $0["sourceProposalId"] as? String == id }) { return ["proposal": saved[index].payload, "agent": agent, "saved": true] }
        guard saved[index].status == "pending" else { throw failure("This suggestion has already been decided.") }
        guard payload["revision"] as? Int == saved[index].revision else { throw failure("This suggestion changed. Reopen it before deciding.") }
        let now = ISO8601DateFormatter().string(from: Date())
        if action == "decline" {
            saved[index].status = "declined"; saved[index].decidedAt = now; saved[index].revision += 1
            try persist(saved); return ["proposal": saved[index].payload, "saved": true]
        }
        guard let value = payload["config"] as? [String: Any] else { throw failure("Review the agent’s configuration first.") }
        let config = try configuration(value, state: current, human: true)
        saved[index].draft = config; saved[index].revision += 1
        if action == "save" { try persist(saved); return ["proposal": saved[index].payload, "saved": true] }
        var agent = config.payload; agent.removeValue(forKey: "groupIds")
        agent["id"] = id; agent["status"] = "Ready"; agent["sourceProposalId"] = id; agent["approvedAt"] = now; agent["setupStatus"] = "pending"; agent["setupSeed"] = config.description
        var agents = current["agents"] as? [[String: Any]] ?? []; agents.append(agent); current["agents"] = agents
        var messages = current["messages"] as? [String: [[String: Any]]] ?? [:]; messages[id] = []; current["messages"] = messages
        var groups = current["groups"] as? [[String: Any]] ?? []
        for index in groups.indices where config.groupIds.contains(groups[index]["id"] as? String ?? "") {
            var members = groups[index]["members"] as? [String] ?? []; if !members.contains(id) { members.append(id) }; groups[index]["members"] = members
        }
        current["groups"] = groups
        saved[index].status = "approved"; saved[index].approved = config; saved[index].agentId = id; saved[index].decidedAt = now
        do { try JSONSerialization.data(withJSONObject: current).write(to: workspaceURL, options: .atomic) }
        catch { throw failure("Buddy couldn’t save this agent. Your choices are still here; try again.") }
        // If the second file cannot save, list/retry derives approval from the
        // already committed agent rather than creating another one.
        try? persist(saved)
        return ["proposal": saved[index].payload, "agent": agent, "saved": true]
    }
    func preserveApprovals(in incoming: [String: Any], previous: [String: Any]?) throws -> [String: Any] {
        guard let previous, incoming["conversationWorkspace"] as? String == previous["conversationWorkspace"] as? String else { return incoming }
        let ids = Set(try records().map(\.id))
        var result = incoming, agents = incoming["agents"] as? [[String: Any]] ?? []
        var messages = incoming["messages"] as? [String: [[String: Any]]] ?? [:]
        var groups = incoming["groups"] as? [[String: Any]] ?? []
        for agent in previous["agents"] as? [[String: Any]] ?? [] {
            guard let source = agent["sourceProposalId"] as? String, ids.contains(source), let id = agent["id"] as? String,
                  !agents.contains(where: { $0["id"] as? String == id }) else { continue }
            agents.append(agent); messages[id] = (previous["messages"] as? [String: [[String: Any]]])?[id] ?? []
            for index in groups.indices where (previous["groups"] as? [[String: Any]] ?? []).contains(where: { $0["id"] as? String == groups[index]["id"] as? String && ($0["members"] as? [String] ?? []).contains(id) }) {
                var members = groups[index]["members"] as? [String] ?? []; if !members.contains(id) { members.append(id) }; groups[index]["members"] = members
            }
        }
        result["agents"] = agents; result["messages"] = messages; result["groups"] = groups; return result
    }
    static let tools: [[String: Any]] = [["type": "function", "name": "buddy_propose_agent", "description": "Suggest a new specialist agent for the user to review. This saves a pending suggestion, never creates or approves it. For an explicit user request to CREATE agents or teams, use buddy_build_team instead. Prefer existing registered agents. Suggest at most three per request. Names, roles, instructions and appearance remain editable before human approval.", "inputSchema": ["type": "object", "properties": ["name": ["type": "string", "maxLength": 40], "role": ["type": "string", "maxLength": 55], "description": ["type": "string", "maxLength": 1500], "reason": ["type": "string", "maxLength": 800], "avatarShape": ["type": "string", "enum": BuddyAvatar.shapes], "avatarColor": ["type": "string", "enum": ["lilac", "blue", "peach", "mint", "red", "gold", "cobalt"]]], "required": ["name", "role", "description", "reason", "avatarShape", "avatarColor"], "additionalProperties": false]], BuddyTeamBuilder.tool]
}

/// Plans are journaled before committing the whole team in one workspace write.
/// Direct creation requires the actual current human message, not a model's claim
/// of consent. Unsolicited plans remain pending until the human reviews them.
@MainActor final class BuddyTeamBuilder {
    private let support:URL
    private var file:URL {support.appendingPathComponent("team-plans.json")}
    private var workspaceFile:URL {support.appendingPathComponent("workspace.json")}
    init(support:URL){self.support=support}
    private func fail(_ message:String)->BuddyProposalFailure {BuddyProposalFailure(message:message)}
    private func state(_ workspace:String)throws->[String:Any] {
        let data=try Data(contentsOf:workspaceFile)
        guard data.count<50_000_000,UUID(uuidString:workspace) != nil,let s=try JSONSerialization.jsonObject(with:data) as? [String:Any],s["conversationWorkspace"] as? String==workspace,s["agents"] is [[String:Any]],s["groups"] is [[String:Any]] else{throw fail("This workspace changed. Reopen the conversation.")};return s
    }
    private func records()throws->[[String:Any]] {
        guard FileManager.default.fileExists(atPath:file.path) else{return []}
        let data=try Data(contentsOf:file)
        guard data.count<12*1024*1024,let rows=try JSONSerialization.jsonObject(with:data) as? [[String:Any]],rows.count<=1000,rows.allSatisfy({r in ["id","workspace","runId"].allSatisfy{(r[$0] as? String).flatMap(UUID.init(uuidString:)) != nil} && !(r["actorId"] as? String ?? "").isEmpty && (r["actorId"] as? String ?? "").count<=80 && r["chat"] is String && r["revision"] is Int && r["label"] is String && r["draft"] is [String:Any] && ["pending","created","declined"].contains(r["status"] as? String ?? "")}) else{throw fail("Buddy couldn't verify saved team plans. Existing teams were kept.")};return rows
    }
    private func save(_ rows:[[String:Any]])throws {let data=try JSONSerialization.data(withJSONObject:rows,options:.sortedKeys);guard data.count<12*1024*1024 else{throw fail("Team plan history is full.")};try data.write(to:file,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)}
    static func creationRequest(_ text:String)->Bool {
        guard text.range(of:#"(?i)\b(if|hypothetical|example|don't|do not|never|ability|able to|capability)\b|```"#,options:.regularExpression)==nil else{return false}
        if let prefix=text.range(of:#"(?is)^\s*(?:first\s+)?(?:take|remove|delete|pause|stop|cancel|archive)\b.{0,400}?[,;\n]\s*(?:(?:and|then)\s+)?"#,options:.regularExpression) {return creationRequest(String(text[prefix.upperBound...]))}
        // Creating software/plans ABOUT agents is not authorization to add them.
        if text.range(of:#"(?is)^\s*(?:(?:yes|ok|okay|please|go ahead)[,\s]*)*(?:(?:can|could|would|will) you(?: please)?\s+|i (?:want|need)(?: you)? to\s+)?(?:create|make|build|set up|setup|assemble|form|put together|add|hire)\s+(?:me\s+)?(?:(?:a|an|the|new|another)\s+)*(?:tool|app|application|website|feature|plan|proposal|design|template|no|zero|0)\b|\b(?:team|group|agent)\s+(?:plan|proposal|design|template)\b"#,options:.regularExpression) != nil{return false}
        return text.range(of:#"(?is)^\s*(?:(?:yes|ok|okay|please|go ahead)[,\s]*)*(?:(?:can|could|would|will) you(?: please)?\s+|i (?:want|need)(?: you)? to\s+)?(?:create|make|build|set up|setup|assemble|form|put together|add|hire)\b.{0,2000}\b(?:team|group|agents?|bots?|budd(?:y|ies)|teammates?|specialists?)\b"#,options:.regularExpression) != nil
    }
    private func request(_ scope:BuddyProposalScope,state:[String:Any],authorizedText:String)->(id:String,text:String)? {
        guard let run=(state["runs"] as? [String:[String:Any]])?[scope.replyRunId],run["target"] as? String==scope.chat,["starting","answering"].contains(run["status"] as? String ?? ""),let id=run["userId"] as? String,let message=((state["messages"] as? [String:[[String:Any]]])?[scope.chat] ?? []).first(where:{$0["id"] as? String==id && $0["who"] as? String=="you"}),let text=message["body"] as? String,text==authorizedText else{return nil};return(id,text)
    }
    private func draft(_ input:[String:Any],state:[String:Any])throws->[String:Any] {
        let all=state["agents"] as! [[String:Any]],groups=state["groups"] as! [[String:Any]],target=input["groupId"] as? String ?? "",name=(input["teamName"] as? String ?? "").trimmingCharacters(in:.whitespacesAndNewlines),goal=(input["objective"] as? String ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
        if !target.isEmpty {guard groups.contains(where:{$0["id"] as? String==target}) else{throw fail("Choose a current team before adding members.")}}
        else if !name.isEmpty {guard name.count<=70,!goal.isEmpty,goal.count<=1500,!groups.contains(where:{($0["name"] as? String)?.lowercased()==name.lowercased()}) else{throw fail("Use a unique team name and a goal up to 1,500 characters.")}}
        let existing=input["existingAgentIds"] as? [String] ?? [],new=input["newAgents"] as? [[String:Any]] ?? []
        guard new.count<=8,Set(existing).count==existing.count,existing.allSatisfy({id in all.contains{$0["id"] as? String==id}}),!existing.isEmpty || !new.isEmpty else{throw fail("Choose existing agents or up to eight new teammates.")}
        guard !name.isEmpty || !target.isEmpty || (new.count==1 && existing.isEmpty) else{throw fail("Add a team name and goal, or create one standalone agent.")}
        var checking=state,checked=[[String:Any]]();let validator=BuddyAgentProposals(support:support)
        for config in new {var clean=config;clean["groupIds"]=[String]();let c=try validator.configuration(clean,state:checking,human:true);checked.append(c.payload);var agents=checking["agents"] as! [[String:Any]];agents.append(c.payload);checking["agents"]=agents}
        guard let reason=input["reason"] as? String,!reason.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,reason.count<=800 else{throw fail("Explain briefly what this team or agent will do.")}
        return ["teamName":name,"objective":goal,"groupId":target,"existingAgentIds":existing,"newAgents":checked,"includeCreator":input["includeCreator"] as? Bool ?? true,"interviewNewAgents":input["interviewNewAgents"] as? Bool ?? false,"reason":reason]
    }
    private func reconcile(_ row:[String:Any],state:[String:Any])->[String:Any] {
        var r=row;let id=r["id"] as! String,agents=(state["agents"] as! [[String:Any]]).filter{$0["sourceTeamPlanId"] as? String==id},group=(state["groups"] as! [[String:Any]]).first{($0["teamPlanIds"] as? [String] ?? []).contains(id)}
        if !agents.isEmpty || group != nil {r["status"]="created";r["agents"]=agents;r["group"]=group ?? NSNull();r["created"]=true;r["initialMessages"]=Dictionary(uniqueKeysWithValues:agents.compactMap{a->(String,[[String:Any]])? in guard let id=a["id"] as? String else{return nil};return(id,((state["messages"] as? [String:[[String:Any]]])?[id] ?? []).filter{$0["teamBriefIntro"] as? Bool==true})})}
        r["native"]=true;return r
    }
    func list(_ workspace:String)throws->[[String:Any]] {let s=try state(workspace);return try records().filter{$0["workspace"] as? String==workspace}.map{reconcile($0,state:s)}}
    private func receipt(_ r:[String:Any],state:[String:Any])->[String:Any] {let r=reconcile(r,state:state);return ["saved":true,"created":r["status"] as? String=="created","proposed":r["status"] as? String=="pending","plan":r,"agents":r["agents"] ?? [],"group":r["group"] ?? NSNull()]}
    func perform(_ scope:BuddyProposalScope,executionRunId:String,callId:String,arguments:[String:Any],authorizedText:String)throws->[String:Any] {
        let s=try state(scope.workspace),agents=s["agents"] as! [[String:Any]],groups=s["groups"] as! [[String:Any]]
        guard UUID(uuidString:executionRunId) != nil,UUID(uuidString:scope.replyRunId) != nil,!callId.isEmpty,callId.count<=200,let actor=agents.first(where:{$0["id"] as? String==scope.actorId}),scope.chat==scope.actorId || groups.contains(where:{$0["id"] as? String==scope.chat && ($0["members"] as? [String] ?? []).contains(scope.actorId)}) else{throw fail("The creating agent or conversation is no longer available.")}
        let action=arguments["action"] as? String ?? "list"
        if action=="list" {let plans=try list(scope.workspace);return ["agents":agents.map{["id":$0["id"] ?? "","name":$0["name"] ?? "","role":$0["role"] ?? ""]},"teams":groups.map{$0.filter{["id","name","objective","members","managedBy"].contains($0.key)}},"plans":plans.suffix(50).map{$0.filter{["id","label","status","actorId","chat","revision"].contains($0.key)}},"olderPlans":max(0,plans.count-50)]}
        guard ["create","propose"].contains(action) else{throw fail("Choose list, create or propose.")}
        var rows=try records();let callKey=executionRunId+":"+callId
        if let prior=rows.first(where:{$0["workspace"] as? String==scope.workspace && $0["callKey"] as? String==callKey}) {return receipt(prior,state:s)}
        let source=request(scope,state:s,authorizedText:authorizedText),quote=arguments["authorizationQuote"] as? String ?? ""
        let exact=quote.count>=3 && quote.count<=1000 && source?.text.contains(quote)==true
        if let id=arguments["planId"] as? String,let i=rows.firstIndex(where:{$0["id"] as? String==id && $0["workspace"] as? String==scope.workspace && $0["chat"] as? String==scope.chat}) {
            let r=reconcile(rows[i],state:s);if r["status"] as? String=="created"{return receipt(r,state:s)}
            guard r["status"] as? String=="pending" else{throw fail("This plan has already been declined.")}
            let sole=rows.filter{$0["workspace"] as? String==scope.workspace && $0["chat"] as? String==scope.chat && reconcile($0,state:s)["status"] as? String=="pending"}.count==1
            let assent=source?.text.range(of:#"(?i)^\s*(?:yes[,\s]*)?(?:go ahead|do it|create (?:it|them|the team)|approve (?:it|this|the plan))[.!\s]*$"#,options:.regularExpression) != nil
            guard action=="create",exact,(Self.creationRequest(source?.text ?? "") || (sole && assent)) else{return receipt(r,state:s)}
            rows[i]["authorizationQuote"]=quote;return try commit(i,rows:rows,state:s,human:false)
        }
        let targetName=groups.first{$0["id"] as? String==arguments["groupId"] as? String}?["name"] as? String
        let label=(targetName ?? (arguments["teamName"] as? String).flatMap{$0.isEmpty ? nil:$0} ?? ((arguments["newAgents"] as? [[String:Any]])?.first?["name"] as? String ?? "Team")).trimmingCharacters(in:.whitespacesAndNewlines)
        if let i=rows.firstIndex(where:{$0["workspace"] as? String==scope.workspace && $0["intentId"] as? String==(source?.id ?? scope.replyRunId) && ($0["label"] as? String)?.lowercased()==label.lowercased() && $0["status"] as? String != "declined"}) {let prior=reconcile(rows[i],state:s);if prior["status"] as? String=="pending",action=="create",exact,Self.creationRequest(source?.text ?? ""){rows[i]["authorizationQuote"]=quote;return try commit(i,rows:rows,state:s,human:false)};return receipt(prior,state:s)}
        let config=try draft(arguments,state:s)
        guard rows.count<1000,rows.filter({$0["workspace"] as? String==scope.workspace && $0["status"] as? String=="pending"}).count<12 else{throw fail("Review the pending team plans before adding more.")}
        let r:[String:Any]=["id":UUID().uuidString,"workspace":scope.workspace,"actorId":scope.actorId,"actorName":actor["name"] ?? "Buddy","chat":scope.chat,"runId":scope.replyRunId,"callKey":callKey,"intentId":source?.id ?? scope.replyRunId,"label":label,"draft":config,"status":"pending","revision":0,"createdAt":ISO8601DateFormatter().string(from:Date()),"authorizationQuote":exact ? quote:""]
        rows.append(r);try save(rows)
        if action=="create",exact,Self.creationRequest(source?.text ?? "") {return try commit(rows.count-1,rows:rows,state:s,human:false)}
        return receipt(r,state:s)
    }
    private func commit(_ index:Int,rows original:[[String:Any]],state originalState:[String:Any],human:Bool)throws->[String:Any] {
        var rows=original,s=originalState,r=rows[index];let config=try draft(r["draft"] as! [String:Any],state:s),planId=r["id"] as! String,actor=r["actorId"] as! String,now=ISO8601DateFormatter().string(from:Date())
        guard (s["agents"] as! [[String:Any]]).contains(where:{$0["id"] as? String==actor}) else{throw fail("The creating agent is no longer available. Ask a current agent to prepare this team.")}
        var agents=s["agents"] as! [[String:Any]],groups=s["groups"] as! [[String:Any]],messages=s["messages"] as? [String:[[String:Any]]] ?? [:],added=[[String:Any]](),memberIds=config["existingAgentIds"] as! [String]
        for c in config["newAgents"] as! [[String:Any]] {var a=c;a.removeValue(forKey:"groupIds");let id=UUID().uuidString,interview=config["interviewNewAgents"] as? Bool==true;a["id"]=id;a["status"]="Ready";a["setupStatus"]=interview ? "pending":"ready";a["setupSeed"]=c["description"];a["profileRevision"]=1;a["profileSource"]="team-brief";a["sourceTeamPlanId"]=planId;a["managedBy"]=actor;a["createdAt"]=now;agents.append(a);added.append(a);memberIds.append(id);messages[id]=interview ? []:[["id":UUID().uuidString,"who":id,"body":"I'm \(c["name"] as? String ?? "your new Buddy"). \(r["actorName"] as? String ?? "Your teammate") set me up as your \(c["role"] as? String ?? "specialist"). My instructions are ready to review or change; I'll ask if important details are missing.","live":true,"status":"completed","setup":true,"setupComplete":true,"teamBriefIntro":true,"time":DateFormatter.localizedString(from:Date(),dateStyle:.none,timeStyle:.short),"createdAt":now]]}
        let target=config["groupId"] as! String,name=config["teamName"] as! String;var group:[String:Any]?
        if !target.isEmpty || !name.isEmpty {
            if config["includeCreator"] as? Bool != false,agents.contains(where:{$0["id"] as? String==actor}),!memberIds.contains(actor){memberIds.insert(actor,at:0)}
            let i=groups.firstIndex{$0["id"] as? String==target},prior=i.map{groups[$0]},oldMembers=prior?["members"] as? [String] ?? [];let members=oldMembers+memberIds.filter{!oldMembers.contains($0)}
            guard members.count<=16 else{throw fail("A team can have up to sixteen members. Existing teams were kept.")}
            var g=prior ?? ["id":UUID().uuidString,"name":name,"objective":config["objective"]!,"description":config["objective"]!,"managedBy":actor,"createdAt":now];g["members"]=members;var ids=g["teamPlanIds"] as? [String] ?? [];ids.append(planId);g["teamPlanIds"]=ids
            if let i{groups[i]=g}else{groups.append(g);messages[g["id"] as! String]=[]};group=g
        }
        s["agents"]=agents;s["groups"]=groups;s["messages"]=messages
        r["draft"]=config;r["status"]="created";r["agents"]=added;r["group"]=group ?? NSNull();r["memberIds"]=memberIds;r["decidedBy"]=human ? "you":"explicit-user-request";r["decidedAt"]=now;r["revision"]=(r["revision"] as? Int ?? 0)+1;rows[index]=r
        try JSONSerialization.data(withJSONObject:s).write(to:workspaceFile,options:.atomic)
        try? save(rows) // workspace provenance reconciles a missing final journal receipt
        return receipt(r,state:s)
    }
    func review(_ workspace:String,payload:[String:Any])throws->[String:Any] {
        let s=try state(workspace);var rows=try records();guard let id=payload["planId"] as? String,let i=rows.firstIndex(where:{$0["workspace"] as? String==workspace && $0["id"] as? String==id}) else{throw fail("This team plan is no longer available.")}
        let current=reconcile(rows[i],state:s);if current["status"] as? String=="created"{return receipt(current,state:s)}
        guard current["status"] as? String=="pending",payload["revision"] as? Int==current["revision"] as? Int else{throw fail("This team plan changed. Reopen it before deciding.")}
        let action=payload["action"] as? String ?? ""
        if action=="decline"{rows[i]["status"]="declined";rows[i]["revision"]=(current["revision"] as? Int ?? 0)+1;try save(rows);return receipt(rows[i],state:s)}
        guard ["approve","save"].contains(action),let config=payload["config"] as? [String:Any] else{throw fail("Review the team configuration first.")}
        rows[i]["draft"]=try draft(config,state:s);rows[i]["revision"]=(current["revision"] as? Int ?? 0)+1;try save(rows)
        return action=="approve" ? try commit(i,rows:rows,state:s,human:true):receipt(rows[i],state:s)
    }
    func preserve(in incoming:[String:Any],previous:[String:Any]?)throws->[String:Any] {
        guard let previous,let w=incoming["conversationWorkspace"] as? String,previous["conversationWorkspace"] as? String==w else{return incoming}
        let plans=try records().filter{$0["workspace"] as? String==w},ids=Set(plans.compactMap{$0["id"] as? String});var s=incoming,agents=s["agents"] as? [[String:Any]] ?? [],groups=s["groups"] as? [[String:Any]] ?? [],messages=s["messages"] as? [String:[[String:Any]]] ?? [:]
        for a in previous["agents"] as? [[String:Any]] ?? [] where ids.contains(a["sourceTeamPlanId"] as? String ?? "") && !agents.contains(where:{$0["id"] as? String==a["id"] as? String}) {agents.append(a);if let id=a["id"] as? String{messages[id]=(previous["messages"] as? [String:[[String:Any]]])?[id] ?? []}}
        for g in previous["groups"] as? [[String:Any]] ?? [] where !(Set(g["teamPlanIds"] as? [String] ?? []).intersection(ids)).isEmpty {
            guard let id=g["id"] as? String else{continue}
            if let i=groups.firstIndex(where:{$0["id"] as? String==id}) {
                let incomingPlans=Set(groups[i]["teamPlanIds"] as? [String] ?? []),missing=Set(g["teamPlanIds"] as? [String] ?? []).subtracting(incomingPlans)
                if !missing.isEmpty {
                    var members=groups[i]["members"] as? [String] ?? [],additions=[String]()
                    for p in plans where missing.contains(p["id"] as? String ?? "") {
                        if let committed=p["memberIds"] as? [String]{additions+=committed;continue}
                        let draft=p["draft"] as? [String:Any] ?? [:]
                        additions+=draft["existingAgentIds"] as? [String] ?? []
                        additions+=agents.filter{$0["sourceTeamPlanId"] as? String==p["id"] as? String}.compactMap{$0["id"] as? String}
                        if draft["includeCreator"] as? Bool != false,let actor=p["actorId"] as? String{additions.append(actor)}
                    }
                    for member in additions where (g["members"] as? [String] ?? []).contains(member) && !members.contains(member){members.append(member)}
                    groups[i]["members"]=members;groups[i]["teamPlanIds"]=Array(incomingPlans.union(missing))
                }
            }else{groups.append(g);messages[id]=(previous["messages"] as? [String:[[String:Any]]])?[id] ?? []}
        }
        s["agents"]=agents;s["groups"]=groups;s["messages"]=messages;return s
    }
    /// Human UI receipts contain editable profiles; model replies need identities
    /// and status only, never other agents' learned preferences or DM contents.
    static func modelResult(_ result:[String:Any])->[String:Any] {
        guard let p=result["plan"] as? [String:Any] else{return result}
        var out=result.filter{["saved","created","proposed"].contains($0.key)}
        out["planId"]=p["id"];out["plan"]=p.filter{["id","label","status","actorId","chat","revision"].contains($0.key)}
        out["agents"]=(result["agents"] as? [[String:Any]] ?? []).map{$0.filter{["id","name","role","setupStatus"].contains($0.key)}}
        out["group"]=(result["group"] as? [String:Any]).map{$0.filter{["id","name","objective","members","managedBy"].contains($0.key)}} ?? NSNull() as Any
        return out
    }
    static let guidance="Use buddy_build_team to create a requested team, add teammates to an existing team, or create one standalone agent. First list existing agents/teams and reuse suitable members. For action=create quote the user's exact current creation request in authorizationQuote. Native authorization decides whether it is created directly or saved as a pending suggestion. For your own unsolicited idea use action=propose; the user must approve it. A unique pending plan can be created after an explicit go-ahead using its planId. New teammates normally start with your complete job-specific role/instructions and ask only for missing details; interviewNewAgents=true instead starts the normal individual interview; use it only when the user asked for interviews or an agent has no real brief, because an agent with a complete brief is better ready at once. Give each a distinct name and suitable look. Keep saved IDs internal. Confirm only the actual created/proposed outcome in a short DM. If the user also requests recurring work, use buddy_manage_routine with the new agentId, hours and exact authorizationQuote to save it now; do not leave setup as instructions for the teammate to do later. Creating a team registers a real group chat; it does not launch work or change external permissions/reviews. Never claim another agent has worked merely because it was created."
    static let tool:[String:Any] = ["type":"function","name":"buddy_build_team","description":guidance,"inputSchema":["type":"object","additionalProperties":false,"properties":["action":["type":"string","enum":["list","create","propose"]],"planId":["type":"string"],"authorizationQuote":["type":"string"],"teamName":["type":"string","maxLength":70],"objective":["type":"string","maxLength":1500],"groupId":["type":"string","description":"Existing team ID when adding members; omit to create a new team."],"existingAgentIds":["type":"array","items":["type":"string"]],"includeCreator":["type":"boolean"],"interviewNewAgents":["type":"boolean"],"reason":["type":"string","maxLength":800],"newAgents":["type":"array","maxItems":8,"items":["type":"object","additionalProperties":false,"properties":["name":["type":"string","maxLength":40],"role":["type":"string","maxLength":55],"description":["type":"string","maxLength":1500],"avatarShape":["type":"string","enum":BuddyAvatar.shapes],"avatarColor":["type":"string","enum":["lilac","blue","peach","mint","red","gold","cobalt"]]],"required":["name","role","description","avatarShape","avatarColor"]]]],"required":["action"]]]
}
