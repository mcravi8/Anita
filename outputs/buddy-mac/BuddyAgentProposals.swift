import Foundation

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

// Model tools can only create pending records. Human decisions are invoked by
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
    private func configuration(_ value: [String: Any], state: [String: Any], human: Bool) throws -> BuddyProposedConfiguration {
        func text(_ key: String, _ limit: Int) throws -> String {
            guard let raw = value[key] as? String else { throw failure("Add a name, role, and instructions.") }
            let result = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !result.isEmpty, result.count <= limit else { throw failure("Keep the name under 40 characters, role under 55, and instructions under 1,500.") }
            return result
        }
        let name = try text("name", 40), role = try text("role", 55), description = try text("description", 1500)
        guard !(state["agents"] as? [[String: Any]] ?? []).contains(where: { ($0["name"] as? String)?.lowercased() == name.lowercased() }) else { throw failure("An agent already has this name. Choose a different name.") }
        let shape = value["avatarShape"] as? String ?? "star", color = value["avatarColor"] as? String ?? "lilac"
        guard ["star", "pebble", "cube", "clover"].contains(shape), ["lilac", "blue", "peach", "mint", "red", "gold", "cobalt"].contains(color) else { throw failure("Choose an available shape and color.") }
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
    static let tools: [[String: Any]] = [["type": "function", "name": "buddy_propose_agent", "description": "Suggest a new specialist agent for the user to review. This saves a pending suggestion, NEVER creates, approves, delegates to, or grants access to an agent. Use for an explicit request to add a teammate, or a clear missing specialist. Prefer existing registered agents. Suggest at most three per request. Names, roles, instructions and appearance are editable before human approval. Available access defaults on only when the human approves.", "inputSchema": ["type": "object", "properties": ["name": ["type": "string", "maxLength": 40], "role": ["type": "string", "maxLength": 55], "description": ["type": "string", "maxLength": 1500], "reason": ["type": "string", "maxLength": 800], "avatarShape": ["type": "string", "enum": ["star", "pebble", "cube", "clover"]], "avatarColor": ["type": "string", "enum": ["lilac", "blue", "peach", "mint", "red", "gold", "cobalt"]]], "required": ["name", "role", "description", "reason", "avatarShape", "avatarColor"], "additionalProperties": false]]]
}
