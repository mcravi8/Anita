// run-tests: BuddyWorkerCore.swift BuddyOperationsDB.swift BuddyWorkerProcess.swift BuddyWorkerHost.swift BuddyPlan.swift BuddySupervisor.swift BuddyMigrations.swift BuddyWorkerClient.swift BuddyAgentMemory.swift BuddyTeamMonitorStore.swift BuddyTeamMonitor.swift BuddyAISettings.swift ConversationService.swift BuddyInboxReview.swift BuddyMailVerification.swift BuddyComputer.swift BuddyTransport.swift BuddyToolInput.swift BuddyConnections.swift BuddyTeam.swift BuddyProjectFiles.swift BuddyDocuments.swift BuddyAgentProposals.swift
import Foundation

/// The answer formats Buddy sends to ChatGPT. Real ChatGPT (codex app-server, 20 Oct 2026) refused the supervisor's and the check-in's formats
/// with "'required' is required to include every key in properties", because they leave some fields optional; it accepted the group plan's.
/// Every object must list all its properties as required, so optional fields are sent as nullable and the nulls are dropped from the answer.
@main struct StrictSchemaTests {
    @MainActor static func require(_ ok: Bool, _ label: String) { if !ok { fputs("FAILED: \(label)\n", stderr); exit(1) } }
    /// Every object node lists all its properties as required and allows no others: what OpenAI's strict structured output demands.
    static func strict(_ value: Any, _ path: String = "$") -> [String] {
        var problems: [String] = []
        if let o = value as? [String: Any] {
            if let properties = o["properties"] as? [String: Any] {
                if Set(o["required"] as? [String] ?? []) != Set(properties.keys) { problems.append(path + " required") }
                if o["additionalProperties"] as? Bool != false { problems.append(path + " additionalProperties") }
            }
            for (k, v) in o { problems += strict(v, path + "." + k) }
        } else if let list = value as? [Any] { for (i, v) in list.enumerated() { problems += strict(v, path + "[\(i)]") } }
        return problems
    }
    @MainActor static func main() throws {
        let formats: [(String, [String: Any])] = [("supervisor", BuddySupervisorLane.schema), ("check-in", BuddyTeamMonitor.schema), ("group plan", BuddyTeamPlan.schema(memberIds: ["a", "b"]))]
        require(!strict(BuddySupervisorLane.schema).isEmpty && !strict(BuddyTeamMonitor.schema).isEmpty, "the formats as written leave fields optional, which ChatGPT refuses")
        for (name, schema) in formats {
            let sent = BuddyStrictSchema.openAI(schema)
            require(strict(sent).isEmpty, "the \(name) format is strict when sent to ChatGPT: \(strict(sent))")
        }
        // Optional fields become nullable; required ones stay as they were; enums gain null so a nullable enum can be left out.
        let action = ((BuddyStrictSchema.openAI(BuddySupervisorLane.schema)["properties"] as? [String: Any])?["actions"] as? [String: Any])?["items"] as? [String: Any] ?? [:]
        let fields = action["properties"] as? [String: Any] ?? [:]
        require((fields["assignee"] as? [String: Any])?["type"] as? [String] == ["string", "null"], "an optional field is nullable: \(String(describing: fields["assignee"]))")
        require((fields["do"] as? [String: Any])?["type"] as? String == "string", "a required field is not")
        let nullableEnum = BuddyStrictSchema.nullable(["type": "string", "enum": ["a", "b"]])
        require(nullableEnum["type"] as? [String] == ["string", "null"] && (nullableEnum["enum"] as? [Any])?.count == 3, "a nullable enum also allows null")
        // The nulls ChatGPT fills in are dropped, so callers see the shape they asked for (this answer came from real ChatGPT).
        let answer = #"{"actions":[{"assignee":null,"category":null,"do":"add_tasks","evidence":null,"item":"stage_plan:s2","reason":"Plan it.","recommendation":null,"tasks":[{"assignee":"forge-id","brief":"Build it.","deliverable":"The table.","dependsOn":[],"key":"t1","kind":"coding","title":"Build the table"}],"text":null}]}"#
        let cleaned = try JSONSerialization.jsonObject(with: Data(BuddyStrictSchema.cleanedAnswer(answer).utf8)) as? [String: Any] ?? [:]
        let first = (cleaned["actions"] as? [[String: Any]])?.first ?? [:]
        require(first["assignee"] == nil && first["text"] == nil && first["do"] as? String == "add_tasks" && (first["tasks"] as? [[String: Any]])?.first?["key"] as? String == "t1", "nulls are dropped and everything else is kept: \(first)")
        require(BuddyStrictSchema.cleanedAnswer("not json") == "not json", "an answer that is not JSON is left exactly as it was")
        print("PASS: every answer format Buddy sends to ChatGPT is strict (all fields required, optional ones nullable), and the nulls are dropped from the answer")
    }
}
