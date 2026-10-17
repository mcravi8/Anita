import Foundation

// RPC identities stay native. The interface can answer only a pending, scoped request.
struct BuddyToolInput {
    let id = UUID().uuidString
    let rpcID: Any
    let executionRunId: String
    let replyRunId: String
    let workspace: String
    let chat: String
    let agentId: String
    let agentName: String
    let threadId: String
    let turnId: String
    let itemId: String
    let questions: [[String: Any]]
    let tool: [String: Any]
    let isConnectorApproval: Bool

    init(rpcID: Any, executionRunId: String, replyRunId: String, workspace: String, chat: String, agentId: String, agentName: String, params: [String: Any], tool: [String: Any], isConnectorApproval: Bool = false) throws {
        guard let thread = params["threadId"] as? String, let turn = params["turnId"] as? String, let item = params["itemId"] as? String,
              let raw = params["questions"] as? [[String: Any]], !raw.isEmpty, raw.count <= 6 else { throw BuddyFailure(message: "This action did not include a valid review request.") }
        var ids = Set<String>()
        for q in raw {
            guard let id = q["id"] as? String, !id.isEmpty, id.count <= 200, ids.insert(id).inserted,
                  let text = q["question"] as? String, !text.isEmpty, text.count <= 30000,
                  (q["header"] as? String ?? "").count <= 200,
                  q["isSecret"] as? Bool != true else { throw BuddyFailure(message: "Buddy cannot collect passwords or secret credentials in chat. Manage the connection in ChatGPT.") }
            if let options = q["options"] as? [[String: Any]] {
                var labels = Set<String>()
                guard !options.isEmpty, options.count <= 12, options.allSatisfy({ option in
                    guard let label = option["label"] as? String, !label.isEmpty, label.count <= 1000, labels.insert(label).inserted else { return false }
                    return (option["description"] as? String ?? "").count <= 5000
                }) else { throw BuddyFailure(message: "This action’s choices could not be verified.") }
            } else if q["options"] != nil && !(q["options"] is NSNull) { throw BuddyFailure(message: "This action’s choices could not be verified.") }
        }
        self.rpcID = rpcID; self.executionRunId = executionRunId; self.replyRunId = replyRunId
        self.workspace = workspace; self.chat = chat; self.agentId = agentId; self.agentName = agentName
        self.threadId = thread; self.turnId = turn; self.itemId = item; self.questions = raw; self.tool = tool
        self.isConnectorApproval = isConnectorApproval
    }
    var record: [String: Any] {
        ["id": id, "native": true, "runId": replyRunId, "executionRunId": executionRunId, "workspace": workspace,
         "chat": chat, "agentId": agentId, "agentName": agentName, "status": "pending", "questions": questions, "tool": tool,
         "reviewKind": isConnectorApproval ? "connector" : "question"]
    }
    func decisionStatus(_ answers: [String: [String]], cancel: Bool) -> String {
        if cancel { return "cancelled" }
        guard questions.count == 1, let question = questions.first, let key = question["id"] as? String,
              let value = answers[key]?.first, (question["options"] as? [[String: Any]] ?? []).contains(where: { $0["label"] as? String == value }) else { return "answered" }
        if ["decline", "deny", "reject"].contains(value.lowercased()) { return "declined" }
        if value.lowercased() == "cancel" { return "cancelled" }
        return "answered"
    }
    func response(_ answers: [String: [String]], cancel: Bool = false) throws -> [String: Any] {
        guard cancel || Set(answers.keys) == Set(questions.compactMap { $0["id"] as? String }) else { throw BuddyFailure(message: "Answer each question to continue.") }
        var result: [String: Any] = [:]
        for q in questions {
            let id = q["id"] as! String
            let labels = (q["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
            let values: [String]
            if cancel {
                // Empty answers cancel unsupported/freeform requests. Never choose acceptance.
                values = labels.first(where: { ["cancel", "decline", "deny", "reject"].contains($0.lowercased()) }).map { [$0] } ?? []
            } else {
                values = answers[id] ?? []
                guard values.count == 1, let value = values.first, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.count <= 10000,
                      labels.isEmpty || labels.contains(value) || q["isOther"] as? Bool == true else { throw BuddyFailure(message: "Choose one of the offered answers, or add an allowed custom answer.") }
            }
            result[id] = ["answers": values]
        }
        if isConnectorApproval {
            let status = decisionStatus(answers, cancel: cancel)
            let accepted = !cancel && status == "answered" && answers["operation"] == ["Accept"]
            return ["action": accepted ? "accept" : status == "declined" ? "decline" : "cancel", "content": accepted ? [String: Any]() as Any : NSNull() as Any]
        }
        return ["answers": result]
    }
    static func actionSignature(_ item: [String: Any]) -> String? {
        let context = item["appContext"] as? [String: Any] ?? [:]
        guard let connector = item["connectorId"] as? String ?? context["connectorId"] as? String,
              let rawName = item["tool"] as? String, var arguments = item["arguments"] as? [String: Any] else { return nil }
        let name = rawName.split(separator: ".").last.map(String.init) ?? rawName
        // Gmail's host fills optional envelope fields before requesting review.
        // Do not otherwise equate absent, null, empty or changed action arguments.
        if ["send_email", "send_draft", "forward_emails"].contains(name), (item["appName"] as? String ?? context["appName"] as? String) == "Gmail" {
            for key in ["cc", "bcc"] where arguments[key] == nil || arguments[key] is NSNull || arguments[key] as? String == "" { arguments.removeValue(forKey: key) }
            if arguments["reply_message_id"] is NSNull { arguments.removeValue(forKey: "reply_message_id") }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: ["connector": connector, "name": name, "arguments": arguments], options: [.sortedKeys]), data.count <= 200000 else { return nil }
        return data.base64EncodedString()
    }
    static func preview(_ item: [String: Any]) -> [String: Any] {
        // Tool arguments are data. Redact secrets before the web view or saved chat receives them.
        func scrub(_ value: Any, depth: Int = 0) -> Any {
            if depth > 12 { return "[nested content]" }
            if let dict = value as? [String: Any] {
                return dict.mapValues { $0 }.reduce(into: [String: Any]()) { result, pair in
                    let key = pair.key.lowercased()
                    result[pair.key] = ["password", "token", "authorization", "api_key", "secret", "credential"].contains(where: { key.contains($0) }) ? "[redacted]" : scrub(pair.value, depth: depth + 1)
                }
            }
            if let array = value as? [Any] { return array.prefix(200).map { scrub($0, depth: depth + 1) } }
            return value
        }
        let context = item["appContext"] as? [String: Any] ?? [:]
        let value: [String: Any] = ["name": item["tool"] as? String ?? "Connected action", "connectorId": item["connectorId"] as? String ?? context["connectorId"] as? String ?? "", "service": item["appName"] as? String ?? context["appName"] as? String ?? "", "arguments": scrub(item["arguments"] ?? [:])]
        guard let data = try? JSONSerialization.data(withJSONObject: value), data.count <= 200000 else { return ["name": value["name"] ?? "Connected action", "note": "Large action details. Review the provider’s question below before continuing."] }
        return value
    }
}
