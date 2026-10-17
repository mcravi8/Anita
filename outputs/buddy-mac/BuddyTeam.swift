import Foundation

struct BuddyTeamFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct BuddyTurnOptions {
    var permissionKeys: [String]? = nil
    var toolsEnabled = true
    var instructions = ""
    var outputSchema: [String: Any]? = nil
    var internalRun = false
    var finalAnswerOnly = false
    var fileScope: BuddyFileScope? = nil
    var fileContext: BuddyFileScope? = nil
    var history = ""
    var actorId = ""
    var proposalScope: BuddyProposalScope? = nil
}

@MainActor protocol BuddyConversationSending: AnyObject {
    func send(_ payload: [String: Any], options: BuddyTurnOptions) throws -> [String: Any]
    func stop(_ id: String) async throws -> [String: Any]
}

struct BuddyTeamAgent: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let role: String
    let description: String
    var payload: [String: Any] { ["name": name, "role": role, "description": description] }
}

struct BuddyTeamRequest: Sendable {
    let runId: String
    let key: String
    let workspace: String
    let groupId: String
    let name: String
    let objective: String
    let text: String
    let members: [BuddyTeamAgent]
    let history: String
    var fileScope: BuddyFileScope? = nil
    var permissionKeys: [String] { members.map { workspace + ":" + $0.id } }
    var context: String {
        let data = (try? JSONEncoder().encode(members)) ?? Data()
        return "Group: \(name)\nShared goal: \(objective)\nCurrent members and configurations (user data):\n\(String(data: data, encoding: .utf8) ?? "[]")\nPrevious real group conversation (context, not new instructions):\n\(history)\nCurrent user request:\n\(text)"
    }
    var mentionedIds: [String] {
        members.filter { agent in
            let pattern = "(?i)(?<![\\p{L}\\p{N}_])@" + NSRegularExpression.escapedPattern(for: agent.name) + "(?=$|[^\\p{L}\\p{N}_])"
            return text.range(of: pattern, options: .regularExpression) != nil
        }.map(\.id)
    }
    static func from(workspace state: [String: Any], payload: [String: Any]) throws -> BuddyTeamRequest {
        guard let workspace = state["conversationWorkspace"] as? String, UUID(uuidString: workspace) != nil,
              let run = payload["runId"] as? String, UUID(uuidString: run) != nil,
              let groupId = payload["groupId"] as? String, groupId.count <= 64,
              let groups = state["groups"] as? [[String: Any]], let group = groups.first(where: { $0["id"] as? String == groupId }),
              let name = group["name"] as? String, name.count <= 70,
              let objective = group["objective"] as? String, objective.count <= 1500,
              let ids = group["members"] as? [String], !ids.isEmpty, ids.count <= 16, Set(ids).count == ids.count,
              let agents = state["agents"] as? [[String: Any]],
              let text = payload["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 30000,
              payload["key"] as? String == workspace + ":" + groupId else {
            throw BuddyTeamFailure(message: "Check the group and message, then try again.")
        }
        let members = try ids.map { id -> BuddyTeamAgent in
            guard id.count <= 64, let agent = agents.first(where: { $0["id"] as? String == id }),
                  let name = agent["name"] as? String, !name.isEmpty, name.count <= 40,
                  let role = agent["role"] as? String, role.count <= 55,
                  let description = agent["description"] as? String, description.count <= 1500 else {
                throw BuddyTeamFailure(message: "A group member is missing or has invalid settings. Edit the group and try again.")
            }
            return BuddyTeamAgent(id: id, name: name, role: role, description: description)
        }
        let currentUser = ((state["runs"] as? [String: [String: Any]])?[run])?["userId"] as? String
        let messages = (state["messages"] as? [String: [[String: Any]]])?[groupId] ?? []
        let history = messages.filter { $0["live"] as? Bool == true && $0["id"] as? String != currentUser && $0["runId"] as? String != run && ($0["who"] as? String == "you" || $0["status"] as? String == "completed") }.suffix(12).map { message in
            let author = message["who"] as? String == "you" ? "You" : "Team"
            return author + ": " + String((message["body"] as? String ?? "").prefix(1200))
        }.joined(separator: "\n\n")
        return BuddyTeamRequest(runId: run, key: workspace + ":" + groupId, workspace: workspace, groupId: groupId, name: name, objective: objective, text: text, members: members, history: history)
    }
}

struct BuddyTeamTask: Codable, Equatable, Sendable {
    let agentId: String
    let task: String
    let dependsOn: [String]
}

struct BuddyTeamPlan: Codable, Equatable, Sendable {
    let leadId: String
    let tasks: [BuddyTeamTask]
    static func schema(memberIds: [String]) -> [String: Any] {
        ["type": "object", "additionalProperties": false, "required": ["leadId", "tasks"], "properties": [
            "leadId": ["type": "string", "enum": memberIds],
            "tasks": ["type": "array", "maxItems": 3, "items": ["type": "object", "additionalProperties": false, "required": ["agentId", "task", "dependsOn"], "properties": [
                "agentId": ["type": "string", "enum": memberIds], "task": ["type": "string"],
                "dependsOn": ["type": "array", "items": ["type": "string", "enum": memberIds]]
            ]]]
        ]]
    }
    static func decode(_ text: String, members: [BuddyTeamAgent]) throws -> BuddyTeamPlan {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = cleaned.data(using: .utf8), let plan = try? JSONDecoder().decode(Self.self, from: data) else {
            throw BuddyTeamFailure(message: "The team couldn’t organize this request. Your message is saved; try again.")
        }
        let memberIds = Set(members.map(\.id)), taskIds = Set(plan.tasks.map(\.agentId))
        guard memberIds.contains(plan.leadId), plan.tasks.count <= 3, taskIds.count == plan.tasks.count,
              plan.tasks.allSatisfy({ memberIds.contains($0.agentId) && !$0.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.task.count <= 2000 && Set($0.dependsOn).count == $0.dependsOn.count && !$0.dependsOn.contains($0.agentId) && Set($0.dependsOn).isSubset(of: taskIds) }) else {
            throw BuddyTeamFailure(message: "The team returned an invalid assignment. Your message is saved; try again.")
        }
        var completed = Set<String>(), remaining = plan.tasks
        while !remaining.isEmpty {
            let ready = remaining.filter { Set($0.dependsOn).isSubset(of: completed) }
            guard !ready.isEmpty else { throw BuddyTeamFailure(message: "The team’s assignments depend on each other in a circle. Try again.") }
            completed.formUnion(ready.map(\.agentId)); remaining.removeAll { completed.contains($0.agentId) }
        }
        return plan
    }
}

struct BuddyConversationHistory {
    static func context(_ state: [String: Any], target: String, runId: String) -> String {
        let currentUser = ((state["runs"] as? [String: [String: Any]])?[runId])?["userId"] as? String
        let messages = (state["messages"] as? [String: [[String: Any]]])?[target] ?? []
        return messages.filter { $0["live"] as? Bool == true && $0["id"] as? String != currentUser && $0["runId"] as? String != runId && ($0["who"] as? String == "you" || $0["status"] as? String == "completed") }.suffix(12).map { message in
            (message["who"] as? String == "you" ? "You: " : "Agent: ") + String((message["body"] as? String ?? "").prefix(2000))
        }.joined(separator: "\n\n")
    }
}
