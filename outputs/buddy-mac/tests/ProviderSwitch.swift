// run-tests: BuddyWorkerClient.swift BuddyAISettings.swift BuddyAIRouter.swift BuddyClaudeConversations.swift BuddyWorkerProcess.swift BuddyWorkerCore.swift BuddyOperationsDB.swift ConversationService.swift BuddyInboxReview.swift BuddyMailVerification.swift BuddyComputer.swift BuddyTransport.swift BuddyToolInput.swift BuddyConnections.swift BuddyTeam.swift BuddyProjectFiles.swift BuddyDocuments.swift BuddyAgentProposals.swift -- src:tests/provider-switch-server.py
import Foundation

/// "Switch all agents to Claude / ChatGPT" in Settings → AI provider. Every agent moves to the same size of model on the other provider (or back to
/// the model it had there), the whole team is saved in one write, new agents start on the new provider, and scheduled routines move with their
/// agent. Coding sessions and the supervisor's background lane stay on Claude.
@main struct ProviderSwitchTests {
    @MainActor static func require(_ ok: Bool, _ label: String) { if !ok { fputs("FAILED: \(label)\n", stderr); exit(1) } }
    static func claude(_ id: String, _ name: String = "", line: String? = nil, isDefault: Bool = false, current: Bool = true) -> [String: Any] {
        var row: [String: Any] = ["provider": "claude", "id": id, "name": name.isEmpty ? id : name, "isDefault": isDefault, "current": current]
        if let line { row["line"] = line }
        return row
    }
    static func gpt(_ id: String, _ name: String = "", isDefault: Bool = false) -> [String: Any] {
        let row: [String: Any] = ["provider": "chatgpt", "id": id, "name": name.isEmpty ? id : name, "isDefault": isDefault]
        return row
    }
    static func size(_ row: [String: Any]) -> String { BuddyProviderSwitch.tier(row).rawValue }
    static func pick(_ size: BuddyProviderSwitch.Tier, _ provider: String, _ rows: [[String: Any]]) -> String { BuddyProviderSwitch.equivalent(size, provider: provider, in: rows) ?? "none" }
    struct Row { let from: String; let to: String; let name: String; let how: String }
    static func text(_ value: Any?) -> String { value as? String ?? "" }
    static func rows(_ result: [String: Any]) -> [String: Row] {
        var out: [String: Row] = [:]
        for row in result["agents"] as? [[String: Any]] ?? [] {
            let from = row["from"] as? [String: Any] ?? [:], to = row["to"] as? [String: Any] ?? [:]
            let fromText: String = text(from["provider"]) + "/" + text(from["model"]), toText: String = text(to["provider"]) + "/" + text(to["model"])
            out[text(row["agentId"])] = Row(from: fromText, to: toText, name: text(to["name"]), how: text(row["how"]))
        }
        return out
    }

    @MainActor static func main() async throws {
        // 1. The size of a model on each side.
        require(size(claude("claude-a", line: "opus")) == "large", "opus is large")
        require(size(claude("claude-b", line: "sonnet")) == "standard", "sonnet is standard")
        require(size(claude("claude-c", line: "haiku")) == "small", "haiku is small")
        require(size(claude("claude-opus-4-1")) == "large", "without the family field, the id says it")
        require(size(claude("claude-new", "Claude Haiku 5.5")) == "small", "or the name says it")
        require(size(claude("claude-sonnet-4-6")) == "standard", "sonnet by id")
        require(size(claude("claude-other")) == "standard", "an unknown Claude model counts as standard")
        for small in ["gpt-5.5-mini", "gpt-5-nano", "gpt-small", "o4-mini-high", "gpt-lite"] { require(size(gpt(small)) == "small", "\(small) is a small model") }
        require(size(gpt("fast-1", "Flash 2")) == "small", "the display name can say small")
        for large in ["gpt-5.1-codex-max", "gpt-5-pro", "gpt-ultra"] { require(size(gpt(large)) == "large", "\(large) is a large model") }
        require(size(gpt("x-1", "GPT-5 Pro")) == "large", "the display name can say large")
        for standard in ["gpt-5.5", "o3", "gpt-5.1-codex", "prompt-helper", "fixture", ""] { require(size(gpt(standard)) == "standard", "\(standard.isEmpty ? "the account default" : standard) is standard") }
        print("PASS: model sizes: Claude by family (opus, sonnet, haiku), ChatGPT by the words in its name (mini/nano/small/lite/flash, max/pro/ultra), anything else standard")

        // 2. The equivalent on the other side, and what happens when that size is missing.
        let gpts: [[String: Any]] = [gpt("gpt-5.5-pro"), gpt("gpt-5.5", isDefault: true), gpt("gpt-5.4"), gpt("gpt-5.5-mini"), gpt("gpt-5.4-mini")]
        require(pick(.large, "chatgpt", gpts) == "gpt-5.5-pro", "large maps to large")
        require(pick(.standard, "chatgpt", gpts) == "gpt-5.5", "standard maps to the default standard model")
        require(pick(.small, "chatgpt", gpts) == "gpt-5.5-mini", "small maps to the newest small model (the default is not small)")
        require(pick(.standard, "chatgpt", [gpt("gpt-5.5"), gpt("gpt-5.4", isDefault: true)]) == "gpt-5.4", "within a size the provider's default wins over a newer model")
        require(pick(.large, "chatgpt", [gpt("gpt-5.5-mini", isDefault: true), gpt("gpt-5.4"), gpt("gpt-5.5")]) == "gpt-5.4", "no large model: the first standard one, before the default")
        require(pick(.standard, "chatgpt", [gpt("gpt-pro"), gpt("gpt-mini", isDefault: true)]) == "gpt-mini", "no standard model either: the provider's default")
        require(pick(.standard, "chatgpt", [gpt("gpt-pro"), gpt("gpt-mini")]) == "gpt-pro", "no default: the first model listed")
        let claudes: [[String: Any]] = [claude("claude-opus-5", line: "opus"), claude("claude-opus-4-1", line: "opus", current: false), claude("claude-sonnet-5", line: "sonnet", isDefault: true), claude("claude-haiku-5", line: "haiku")]
        require(pick(.large, "claude", claudes) == "claude-opus-5", "Claude large is opus")
        require(pick(.small, "claude", claudes) == "claude-haiku-5", "Claude small is haiku")
        require(pick(.large, "claude", [claude("claude-opus-4-1", line: "opus", current: false), claude("claude-sonnet-5", line: "sonnet", isDefault: true)]) == "claude-sonnet-5", "an older release the picker no longer offers is never chosen")
        require(pick(.standard, "claude", gpts) == "none", "no Claude models: no equivalent")
        require(pick(.standard, "chatgpt", []) == "none", "nothing listed: no equivalent")
        let fromDefault = BuddyProviderSwitch.plan(agents: ["a"], selections: ["a": BuddyAgentModelSelection(provider: "chatgpt", model: "")], target: "claude", catalog: claudes)
        require(fromDefault?.first?.to.model == "claude-sonnet-5", "the ChatGPT account default counts as standard")
        require(fromDefault?.first?.to.alternates == nil, "and is not remembered: there is no model to go back to")
        let nothing = BuddyProviderSwitch.plan(agents: ["a"], selections: ["a": BuddyAgentModelSelection(provider: "chatgpt", model: "gpt-5.5")], target: "claude", catalog: gpts)
        require(nothing == nil, "no models on the target side: no plan")
        print("PASS: equivalents: same size, the default within it else the newest; fallback to standard, then the default, then the first; older releases skipped; no models, no plan")

        // 3. Selections remember the other side; old files still load; one write for the team.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("buddy-provider-switch-" + UUID().uuidString + ".noindex")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = UUID().uuidString, chief = UUID().uuidString, forge = UUID().uuidString, lyra = UUID().uuidString, vera = UUID().uuidString, inbox = UUID().uuidString, nova = UUID().uuidString
        let old = root.appendingPathComponent("old", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        let oldFile = old.appendingPathComponent("agent-models.json")
        let legacyJSON: String = "{\"version\":1,\"workspaces\":{\"" + workspace + "\":{\"" + chief + "\":{\"provider\":\"chatgpt\",\"model\":\"gpt-5.5\"}}}}"
        try Data(legacyJSON.utf8).write(to: oldFile)
        let legacy = try BuddyAgentModels(support: old).selection(workspace: workspace, agent: chief)
        require(legacy?.model == "gpt-5.5", "an agent-models.json from before the switch existed still loads")
        require(legacy?.alternates == nil, "with nothing remembered")
        let both: [String: BuddyAgentModelSelection] = [chief: BuddyAgentModelSelection(provider: "claude", model: "claude-opus-5", alternates: ["chatgpt": "gpt-5.5"]), forge: BuddyAgentModelSelection(provider: "chatgpt", model: "gpt-5.4")]
        try BuddyAgentModels(support: old).setAll(workspace: workspace, selections: both)
        struct OlderSelection: Decodable { let provider: String; let model: String }
        struct OlderFile: Decodable { let version: Int; let workspaces: [String: [String: OlderSelection]] }
        let older = try JSONDecoder().decode(OlderFile.self, from: Data(contentsOf: oldFile))
        require(older.workspaces[workspace]?[chief]?.model == "claude-opus-5", "a file with remembered models still reads the way older Buddy reads it")
        require(older.workspaces[workspace]?[forge]?.provider == "chatgpt", "every agent of the one write is there")
        var refused = false
        let bad: [String: BuddyAgentModelSelection] = [chief: BuddyAgentModelSelection(provider: "chatgpt", model: "gpt-5.5"), forge: BuddyAgentModelSelection(provider: "claude", model: "not a model!")]
        do { try BuddyAgentModels(support: old).setAll(workspace: workspace, selections: bad) } catch { refused = true }
        let afterBad = try BuddyAgentModels(support: old).selection(workspace: workspace, agent: chief)
        require(refused, "an invalid selection is refused")
        require(afterBad?.provider == "claude", "the team is saved in one write: one bad selection and nobody changes")
        let unknownJSON: String = "{\"version\":1,\"workspaces\":{\"" + workspace + "\":{\"" + chief + "\":{\"provider\":\"chatgpt\",\"model\":\"gpt-5.5\",\"alternates\":{\"gemini\":\"x\"}}}}}"
        try Data(unknownJSON.utf8).write(to: oldFile)
        refused = false
        do { _ = try BuddyAgentModels(support: old).selection(workspace: workspace, agent: chief) } catch { refused = true }
        require(refused, "a remembered model for an unknown provider fails closed like any other bad entry")
        print("PASS: remembered models are an optional field: old files load, older readers ignore it, bad entries fail closed, and the team is saved in one all-or-nothing write")

        // 4. The switch itself, through the router, with both catalogs.
        let team = [chief, forge, lyra, vera, inbox], everyone = team + [nova]
        let agentList: [[String: String]] = team.map { ["id": $0] }
        try JSONSerialization.data(withJSONObject: ["conversationWorkspace": workspace, "agents": agentList] as [String: Any]).write(to: root.appendingPathComponent("workspace.json"))
        let primary = ConversationService(support: root, executable: URL(fileURLWithPath: CommandLine.arguments[1]))
        let permitted = Set(everyone.map { workspace + ":" + $0 })
        primary.agentPermission = { w, keys in w == workspace && keys.allSatisfy { permitted.contains($0) } }
        primary.filePermission = { _, _ in false }
        primary.computerPermission = { _, _ in false }
        func api(_ id: String, _ name: String, _ line: String) -> [String: Any] { ["id": id, "display_name": name, "lifecycle": "active", "line": line] }
        let fullClaude = BuddyModelCatalog.claude([api("claude-opus-5", "Claude Opus 5", "opus"), api("claude-sonnet-5", "Claude Sonnet 5", "sonnet"), api("claude-haiku-5", "Claude Haiku 5", "haiku"), api("claude-sonnet-4-6", "Claude Sonnet 4.6", "sonnet")])
        require(text(fullClaude.first?["line"]) == "opus", "the Claude catalog keeps each model's family")
        var claudeRows = fullClaude
        var keys: [String: String] = [workspace: "fixture-key"]
        let router = BuddyAIRouter(support: root, chatgpt: primary, keyReader: { keys[$0] }, keyRemover: { _ in }, claudeModelReader: { _ in claudeRows })
        defer { router.shutdown() }
        func set(_ agent: String, _ provider: String, _ model: String) async throws {
            let payload: [String: Any] = ["operation": "set", "agentId": agent, "provider": provider, "model": model]
            _ = try await router.modelSettings(workspace: workspace, agents: team, payload: payload)
        }
        func saved(_ agent: String) throws -> String { guard let s = try BuddyAgentModels(support: root).selection(workspace: workspace, agent: agent) else { return "none" }; return s.provider + "/" + s.model }
        func remembered(_ agent: String) throws -> [String: String] { try BuddyAgentModels(support: root).selection(workspace: workspace, agent: agent)?.alternates ?? [:] }
        func file(_ name: String) -> Data? { try? Data(contentsOf: root.appendingPathComponent(name)) }
        func switchTo(_ target: String, _ agents: [String], apply: Bool, lead: String? = nil) async throws -> [String: Any] {
            try await router.switchProvider(workspace: workspace, to: target, agents: agents, dryRun: !apply, supervisor: lead)
        }
        try await set(chief, "chatgpt", "gpt-5.5-pro")
        try await set(forge, "chatgpt", "gpt-5.5")
        try await set(lyra, "chatgpt", "gpt-5.5-mini")
        try await set(vera, "chatgpt", "gpt-5.4")
        try await set(inbox, "claude", "claude-haiku-5")

        // Preview: nothing is saved.
        let modelsBefore = file("agent-models.json"), settingsBefore = file("ai-providers.json")
        let preview = try await switchTo("claude", team, apply: false, lead: "Chief")
        let planned = rows(preview)
        require(planned[chief]?.to == "claude/claude-opus-5", "a large ChatGPT model moves to a large Claude model: \(planned)")
        require(planned[chief]?.name == "Claude Opus 5", "the preview names the model")
        require(planned[chief]?.how == "equivalent", "and says it is the equivalent size")
        require(planned[forge]?.to == "claude/claude-sonnet-5", "standard moves to Claude's default standard model")
        require(planned[vera]?.to == "claude/claude-sonnet-5", "an older standard model also moves to the standard default")
        require(planned[lyra]?.to == "claude/claude-haiku-5", "small moves to small")
        require(planned[inbox]?.from == "claude/claude-haiku-5", "the preview shows the current model")
        require(planned[inbox]?.to == "claude/claude-haiku-5", "an agent already on Claude stays exactly where it is")
        require(planned[inbox]?.how == "unchanged", "and is marked unchanged")
        require(text(preview["note"]) == "Coding sessions and Chief's background supervision run on Claude. They keep using Claude while it stays connected.", "the preview says plainly what stays on Claude: \(text(preview["note"]))")
        require(preview["applied"] as? Bool == false, "a preview is not applied")
        require(file("agent-models.json") == modelsBefore, "a preview saves no model")
        require(file("ai-providers.json") == settingsBefore, "a preview leaves the starting provider")
        let noLead = try await switchTo("claude", team, apply: false)
        require(text(noLead["note"]) == "Coding sessions run on Claude. They keep using Claude while it stays connected.", "without a supervisor only coding sessions are named")

        // Apply: every agent saved, the default provider follows, and the switch is stamped for scheduled routines.
        let applied = try await switchTo("claude", team, apply: true, lead: "Chief")
        require(applied["applied"] as? Bool == true, "the switch is applied")
        let done = rows(applied)
        for agent in team {
            require(done[agent]?.to == planned[agent]?.to, "the switch applies exactly what the preview showed")
            require(try saved(agent) == planned[agent]?.to, "every agent is saved on Claude")
        }
        let toClaude = try router.settings.current(workspace)
        require(toClaude.provider == "claude", "the workspace's starting provider is now Claude")
        require(toClaude.teamSwitch != nil, "and the switch is stamped")
        require(try remembered(chief) == ["chatgpt": "gpt-5.5-pro"], "Chief remembers its ChatGPT model")
        require(try remembered(vera) == ["chatgpt": "gpt-5.4"], "Vera remembers its older ChatGPT model")
        require(try remembered(inbox).isEmpty, "an agent that did not move has nothing new to remember")
        try router.ensureAgentDefaults(workspace: workspace, agents: everyone)
        require(try saved(nova).hasPrefix("claude/"), "a new agent starts on the new provider")
        print("PASS: preview changes nothing; the switch moves every agent to its equivalent, leaves agents already there alone, sets the starting provider and remembers each agent's old model")

        // A model chosen afterwards on Claude keeps the ChatGPT memory; switching back restores exactly what each agent had.
        try await set(forge, "claude", "claude-opus-5")
        require(try remembered(forge) == ["chatgpt": "gpt-5.5"], "choosing another Claude model keeps what the agent had on ChatGPT")
        let back = rows(try await switchTo("chatgpt", everyone, apply: true, lead: "Chief"))
        require(back[chief]?.to == "chatgpt/gpt-5.5-pro", "Chief gets its own ChatGPT model back: \(back)")
        require(back[forge]?.to == "chatgpt/gpt-5.5", "Forge too, although its Claude model changed in between")
        require(back[lyra]?.to == "chatgpt/gpt-5.5-mini", "Lyra too")
        require(back[vera]?.to == "chatgpt/gpt-5.4", "Vera gets its older model back, not the default")
        for agent in [chief, forge, lyra, vera] { require(back[agent]?.how == "remembered", "and the preview says it is the model it had before") }
        require(back[inbox]?.to == "chatgpt/gpt-5.5-mini", "an agent never on ChatGPT gets the equivalent size")
        require(back[inbox]?.how == "equivalent", "marked as the equivalent")
        require(back[nova]?.to == "chatgpt/gpt-5.5", "a new agent on the Claude default gets ChatGPT's standard default")
        let toChatGPT = try router.settings.current(workspace)
        require(toChatGPT.provider == "chatgpt", "the starting provider follows the switch back")
        require(toChatGPT.teamSwitch != nil && toChatGPT.teamSwitch != toClaude.teamSwitch, "with a new stamp")
        require(try remembered(chief) == ["claude": "claude-opus-5"], "Chief now remembers its Claude model")
        require(try remembered(forge) == ["claude": "claude-opus-5"], "Forge remembers the Claude model it chose")
        require(try remembered(inbox) == ["claude": "claude-haiku-5"], "Inbox remembers its Claude model")
        print("PASS: switching back restores each agent's remembered model exactly; agents with no memory get the equivalent size")

        // 5. Coding sessions and the supervisor's lane stay on Claude: an agent on ChatGPT still has its Claude model for them.
        let chiefNow = try BuddyAgentModels(support: root).selection(workspace: workspace, agent: chief)
        require(chiefNow?.model(on: "claude") == "claude-opus-5", "after the switch to ChatGPT, Chief's coding sessions and supervision keep the Claude model it had")
        require(chiefNow?.model(on: "chatgpt") == "gpt-5.5-pro", "on its own provider an agent uses its own model")
        let neverClaude = BuddyAgentModelSelection(provider: "chatgpt", model: "gpt-5.5")
        require(neverClaude.model(on: "claude") == BuddyAgentModelSelection.initial("claude").model, "an agent that never had a Claude model still codes on Claude, on the default")
        let neverChatGPT = BuddyAgentModelSelection(provider: "claude", model: "claude-haiku-5")
        require(neverChatGPT.model(on: "chatgpt") == "", "the ChatGPT fallback is the account default")
        print("PASS: coding sessions and the supervisor lane keep Claude and the agent's remembered Claude model after a switch to ChatGPT")

        // 6. A remembered model that is gone falls back to the equivalent.
        let retired: [String: BuddyAgentModelSelection] = [chief: BuddyAgentModelSelection(provider: "chatgpt", model: "gpt-5.5-pro", alternates: ["claude": "claude-retired-1"])]
        try router.agentModels.setAll(workspace: workspace, selections: retired)
        let gone = rows(try await switchTo("claude", team, apply: false))
        require(gone[chief]?.to == "claude/claude-opus-5", "a remembered model no longer listed is replaced by the equivalent size: \(gone)")
        require(gone[chief]?.how == "equivalent", "and is marked as the equivalent")
        print("PASS: a remembered model that left the catalog falls back to the equivalent size")

        // 7. Refusals: the target is not connected, or it has no models. Nothing is written.
        let modelsSnapshot = file("agent-models.json")
        func refusal(_ target: String, apply: Bool = false) async -> String {
            do { _ = try await switchTo(target, team, apply: apply); return "" } catch { return error.localizedDescription }
        }
        let claudeRefusal = "Connect Claude in Settings → AI provider first."
        keys[workspace] = nil
        let noKeyPreview = await refusal("claude"), noKeyApply = await refusal("claude", apply: true)
        require(noKeyPreview == claudeRefusal, "no Claude key: the preview is refused in plain words: \(noKeyPreview)")
        require(noKeyApply == claudeRefusal, "and so is the switch")
        keys[workspace] = "fixture-key"
        _ = try router.settings.update(workspace, enabled: ("claude", false))
        let turnedOff = await refusal("claude", apply: true)
        require(turnedOff == claudeRefusal, "Claude turned off in Buddy: refused")
        claudeRows = []
        _ = try router.settings.update(workspace, enabled: ("claude", true))
        let empty = await refusal("claude", apply: true)
        require(empty == claudeRefusal, "Claude connected but listing no models: refused")
        _ = try router.settings.update(workspace, enabled: ("chatgpt", false))
        let gptOff = await refusal("chatgpt", apply: true)
        require(gptOff == "Connect ChatGPT in Settings → AI provider first.", "ChatGPT turned off in Buddy: refused: \(gptOff)")
        require(file("agent-models.json") == modelsSnapshot, "a refused switch saves no model")
        require(try router.settings.current(workspace).provider == "chatgpt", "nor the starting provider")
        let unknown = await refusal("gemini")
        require(unknown == "Choose ChatGPT or Claude.", "only the two providers")
        print("PASS: a switch to a provider that is not connected, or that lists no models, is refused in plain words and saves nothing")

        // 8. Scheduled routines move with their agent after a switch, and only then.
        let worker = root.appendingPathComponent("Worker", isDirectory: true)
        let rules = try BuddyRoutineStore(directory: worker), queue = try BuddyWorkerStore(directory: worker)
        let brief: [String: Any] = ["action": "create", "title": "Morning research", "goal": "Research the requested topic", "kind": "research"]
        let created = try rules.manage(brief, workspace: workspace, agent: forge, requestID: "forge-morning", provider: "chatgpt", budget: 0, model: "gpt-5.5")
        let routineID = text((created["routine"] as? [String: Any])?["id"])
        func routine() -> [String: Any] { rules.routines.first { text($0["id"]) == routineID } ?? [:] }
        let agentModel: (String) throws -> (provider: String, model: String)? = { agent in try BuddyAgentModels(support: root).selection(workspace: workspace, agent: agent).map { ($0.provider, $0.model) } }
        claudeRows = fullClaude
        _ = try router.settings.update(workspace, enabled: ("chatgpt", true))
        _ = try router.settings.update(workspace, enabled: ("claude", true))   // a new Claude revision: the empty list is not reused
        _ = try await switchTo("claude", team, apply: true)
        let stampA = try router.settings.current(workspace).teamSwitch ?? ""
        let followedA = try rules.follow(workspace: workspace, switchID: stampA, agentModel: agentModel)
        require(followedA, "the worker follows a new switch")
        require(text(routine()["provider"]) == "claude", "after the switch the routine runs on Claude: \(routine())")
        require(text(routine()["model"]) == "claude-opus-5", "on its agent's Claude model")
        require(BuddyRunLimit.isNone(routine()["budgetUSD"] as? Double ?? 0), "with no per-run limit, like any Claude routine")
        let againA = try rules.follow(workspace: workspace, switchID: stampA, agentModel: agentModel)
        require(!againA, "the same switch is followed once")
        try await set(forge, "chatgpt", "gpt-5.4")
        let afterOwnChange = try rules.follow(workspace: workspace, switchID: stampA, agentModel: agentModel)
        require(!afterOwnChange && text(routine()["provider"]) == "claude", "changing one agent's model never moves its routine to another provider on its own")
        _ = try await switchTo("chatgpt", team, apply: true)
        let stampB = try router.settings.current(workspace).teamSwitch ?? ""
        let followedB = try rules.follow(workspace: workspace, switchID: stampB, agentModel: agentModel)
        require(followedB && text(routine()["provider"]) == "chatgpt", "the next switch moves it again: \(routine())")
        require(text(routine()["model"]) == "gpt-5.4", "to the agent's current ChatGPT model")
        require(routine()["budgetUSD"] as? Double == 0, "with a ChatGPT routine's budget")
        let restarted = try BuddyRoutineStore(directory: worker)
        let restartFollow = try restarted.follow(workspace: workspace, switchID: stampB, agentModel: agentModel)
        require(!restartFollow && text(restarted.routines.first?["provider"]) == "chatgpt", "a restarted worker remembers which switch it followed")
        let run = try rules.runNow(routineID, workspace: workspace, agent: forge, requestID: UUID().uuidString, store: queue)
        require(text(run["provider"]) == "chatgpt" && text(run["model"]) == "gpt-5.4", "the routine's next run uses the agent's current provider and model: \(run)")
        print("PASS: after a switch each routine runs on its agent's new provider and model; one agent's model change never moves a routine; a restart does not repeat it")
    }
}
