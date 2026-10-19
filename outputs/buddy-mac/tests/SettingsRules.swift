import Foundation

/// Settings changed on the person's word, and standing rules that earn their freedom from the person's own approvals.
@main struct SettingsRulesChecks {
    @MainActor static func require(_ value: Bool, _ message: String) { if !value { fputs("FAILED: \(message)\n", stderr); exit(1) } }
    static func refuses(_ message: String, _ body: () throws -> Void) -> Bool {
        do { try body(); fputs("FAILED: \(message) (nothing was refused)\n", stderr); return false } catch { return true }
    }

    /// A small world: three agents, a supervisor, and a place for each kind of setting to live.
    @MainActor final class World {
        let w = UUID().uuidString, chief = UUID().uuidString, sage = UUID().uuidString, mia = UUID().uuidString, rex = UUID().uuidString
        var names: [String: String] = [:]
        var page: [String: [String: Any]] = [:]       // what the page and the profile hold per agent
        var native: [String: Any] = [:]               // what the app itself holds: "agent:field" or "workspace:field"
        var writes: [String] = []
        var failWrites = false
        let store: BuddyWorkerStore
        let engine: BuddyAgentSettings
        let support: URL
        init(support: URL) throws {
            self.support = support
            store = try BuddyWorkerStore(directory: support.appendingPathComponent("Worker"))
            engine = BuddyAgentSettings(store: store, workspace: w)
            for (id, name) in [(chief, "Chief"), (sage, "Sage"), (mia, "Mia"), (rex, "Rex")] {
                page[id] = ["id": id, "name": name, "role": "Helper", "description": "Help.", "avatarShape": "sphere", "avatarColor": "blue", "tools": ["web": true, "projectFiles": true, "desktop": false]]
            }
            page[mia]?["managedBy"] = chief; page[rex]?["managedBy"] = sage
            native["workspace:teamCheckInsEnabled"] = true; native["workspace:teamCheckInIntervalMinutes"] = 15; native["workspace:teamDailyLimitUSD"] = 2.0
            engine.agents = { [unowned self] in [self.chief, self.sage, self.mia, self.rex].compactMap { self.page[$0] } }
            engine.supervisor = { [unowned self] in self.chief }
            engine.read = { [unowned self] scope, agent, field in
                if scope == "workspace" { return self.native["workspace:" + field] }
                if BuddyAgentChanges.pageFields.contains(field) || BuddyAgentChanges.appFields.contains(field) {
                    let state = BuddyAgentChanges.overlay(["agents": [self.chief, self.sage, self.mia, self.rex].compactMap { self.page[$0] }, "hiddenAgents": [String]()], BuddyAgentChanges.unadopted(support: self.support, workspace: self.w))
                    let a = (state["agents"] as? [[String: Any]])?.first { $0["id"] as? String == agent }
                    if field == "hidden" { return (state["hiddenAgents"] as? [String] ?? []).contains(agent) }
                    if field == "instructions" { return a?["description"] }
                    if field.hasPrefix("tools.") { return (a?["tools"] as? [String: Bool])?[String(field.dropFirst(6))] != false }
                    return a?[field]
                }
                return self.native["agent:\(agent):\(field)"] ?? (field == "proactive" ? false : nil)
            }
            engine.write = { [unowned self] scope, agent, field, value in
                if self.failWrites { throw BuddyWorkerFailure(message: "The write failed.") }
                self.writes.append("\(scope):\(agent.prefix(4)):\(field)")
                self.native[scope == "workspace" ? "workspace:" + field : "agent:\(agent):\(field)"] = value
            }
        }
        func say(_ actor: String?, _ message: String, _ args: [String: Any]) throws -> [String: Any] { try engine.change(actor: actor, text: message, args: args) }
    }

    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("buddy-settings-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let world = try World(support: root.appendingPathComponent("a"))
        let w = world.w, sage = world.sage, mia = world.mia, rex = world.rex, chief = world.chief, store = world.store
        let said = "Please rename Sage to Scout and turn her blue — thanks"

        // 1. The person's own words are required, and only a genuine quote counts.
        require(refuses("no quote") { _ = try world.say(sage, said, ["field": "name", "value": "Scout"]) }, "a change with no quote is refused")
        require(refuses("a made-up quote") { _ = try world.say(sage, said, ["field": "name", "value": "Scout", "quote": "rename sage to scout please now"]) }, "a quote that is not in the message is refused")
        require(refuses("a very short quote") { _ = try world.say(sage, "ok then", ["field": "name", "value": "Scout", "quote": "ok"]) }, "a few letters are not a quote")
        require(try store.changes(workspace: w).isEmpty, "nothing was recorded for refused changes")
        let first = try world.say(sage, said, ["field": "name", "value": "Scout", "quote": "RENAME  Sage to   Scout"])
        require(first["saved"] as? Bool == true && (first["message"] as? String)?.contains("Sage’s name") == true, "a quote differing only in capitals and spacing is accepted: \(first)")
        let curly = try world.say(sage, "Make the role “Hiring helper” please", ["field": "role", "value": "Hiring helper", "quote": "Make the role \"Hiring helper\" please"])
        require(curly["saved"] as? Bool == true, "straight and curly quotation marks are the same to a quote")

        // 2. Who may change what.
        require(refuses("another agent") { _ = try world.say(sage, said, ["agentId": mia, "field": "role", "value": "Boss", "quote": "rename Sage to Scout"]) }, "an agent cannot change a teammate it does not manage")
        let byBoss = try world.say(chief, "Chief, set Sage’s role to Recruiter", ["agentId": sage, "field": "role", "value": "Recruiter", "quote": "set Sage’s role to Recruiter"])
        require(byBoss["saved"] as? Bool == true, "the supervisor may change any agent")
        let byManager = try world.say(sage, "Change Rex’s colour to mint", ["agentId": rex, "field": "avatarColor", "value": "mint", "quote": "Change Rex’s colour to mint"])
        require(byManager["saved"] as? Bool == true, "an agent’s manager may change it")
        require(refuses("a stranger changing a managed agent") { _ = try world.say(mia, "Change Rex’s colour to red", ["agentId": rex, "field": "avatarColor", "value": "red", "quote": "Change Rex’s colour to red"]) }, "someone who neither manages nor supervises cannot")
        require(refuses("workspace by a non-supervisor") { _ = try world.say(sage, "Set the daily limit for everyone to $9", ["scope": "workspace", "field": "dailyLimitUSD", "value": "9", "quote": "Set the daily limit for everyone to $9"]) }, "only the supervisor changes workspace settings")
        let onScreen = try world.say(nil, "", ["agentId": sage, "field": "avatarColor", "value": "gold"])
        require(onScreen["saved"] as? Bool == true, "the person on screen needs no quote")

        // 3. What each setting may hold.
        let longName = String(repeating: "n", count: 41)
        for (field, value) in [("name", longName), ("name", "chief"), ("role", String(repeating: "r", count: 56)), ("instructions", String(repeating: "i", count: 1501)), ("instructions", "  "), ("avatarShape", "triangle"), ("avatarColor", "teal"), ("hidden", "maybe"), ("model", "{\"provider\":\"x\",\"model\":\"y\"}"), ("model", "not json"), ("dailyLimitUSD", "-1"), ("dailyLimitUSD", "nan"), ("dailyLimitUSD", "1000000"), ("tools.web", "2"), ("unknown", "1")] {
            require(refuses("\(field)=\(value.prefix(12))") { _ = try world.say(sage, said, ["field": field, "value": value, "quote": "rename Sage to Scout"]) }, "\(field) = \(value.prefix(12)) is refused")
        }
        let shape = try world.say(sage, said, ["field": "avatarShape", "value": "star", "quote": "rename Sage to Scout"])
        require(shape["saved"] as? Bool == true && (shape["message"] as? String)?.contains("diamond") == true, "an old figure name means its current one: \(shape)")
        for (scope, field, value) in [("workspace", "teamCheckInIntervalMinutes", "7"), ("workspace", "teamDailyLimitUSD", "0.01"), ("workspace", "teamCheckInsEnabled", "perhaps")] {
            require(refuses("workspace \(field)") { _ = try world.say(chief, said, ["scope": scope, "field": field, "value": value, "quote": "rename Sage to Scout"]) }, "workspace \(field) = \(value) is refused")
        }
        let noLimit = try BuddyAgentChanges.normalize(scope: "agent", field: "dailyLimitUSD", value: "none")
        require(noLimit == nil, "\"none\" means no limit")
        require(BuddyAgentChanges.avatarShapes == BuddyAvatar.shapes && BuddyAgentChanges.avatarColors == BuddyAvatar.colors && BuddyAgentChanges.legacyShapes == BuddyAvatar.legacyShapes, "the figure and colour lists match the app’s")

        // 4. The journal: old and new values, who, and where the change has to be carried.
        let journal = try store.changes(workspace: w, limit: 50)
        let nameChange = journal.first { $0.field == "name" }!
        require(nameChange.old as? String == "Sage" && nameChange.new as? String == "Scout" && nameChange.actor == "chat" && nameChange.adopter == "page" && nameChange.quote == "RENAME  Sage to   Scout" && nameChange.status == "applied", "a rename keeps old and new, who and what was said")
        require(journal.first { $0.field == "role" }!.adopter == "app" && journal.first { $0.field == "avatarColor" && $0.actor == "user" }!.adopter == "page", "the profile fields are carried by the app and the look by the page")
        let before = journal.count
        let same = try world.say(sage, said, ["field": "name", "value": "Scout", "quote": "rename Sage to Scout"])
        require(try same["unchanged"] as? Bool == true && (store.changes(workspace: w, limit: 50)).count == before, "asking for what is already so records nothing")
        require(refuses("a name taken by someone else") { _ = try world.say(sage, said, ["field": "name", "value": "mia", "quote": "rename Sage to Scout"]) }, "an agent cannot take a teammate’s name")

        // 5. Readers see a change at once, before anyone has carried it home; carrying it home twice changes nothing more.
        let raw: [String: Any] = ["conversationWorkspace": w, "agents": [world.sage, world.mia, world.chief].compactMap { world.page[$0] }, "hiddenAgents": [String]()]
        let seen = BuddyAgentChanges.overlay(raw, BuddyAgentChanges.unadopted(support: world.support, workspace: w))
        let seenSage = (seen["agents"] as? [[String: Any]])!.first { $0["id"] as? String == sage }!
        require(seenSage["name"] as? String == "Scout" && seenSage["role"] as? String == "Recruiter" && seenSage["avatarColor"] as? String == "gold" && seenSage["avatarShape"] as? String == "diamond", "everything that reads the workspace sees the changes: \(seenSage)")
        let seenAgain = BuddyAgentChanges.overlay(seen, BuddyAgentChanges.unadopted(support: world.support, workspace: w))
        require(NSDictionary(dictionary: seen).isEqual(to: seenAgain), "applying the same changes twice gives the same result")
        let unfinished = ["pending", "declined", "failed", "undone", "applying"].map { status in BuddySettingChange(id: status, workspace: w, scope: "agent", agentID: sage, field: "name", old: "Sage", new: "Hacked-" + status, actor: "chat", source: "chat", quote: "q", status: status, risk: "low", adopter: "page", adopted: false, seq: 999, createdAt: "") }
        require(NSDictionary(dictionary: BuddyAgentChanges.overlay(raw, unfinished)).isEqual(to: raw), "only a change that took effect shows anywhere")
        let pageChanges = try store.unadoptedChanges(workspace: w, adopter: "page"), appChanges = try store.unadoptedChanges(workspace: w, adopter: "app")
        require(pageChanges.contains { $0.field == "name" } && !pageChanges.contains { $0.field == "role" } && appChanges.contains { $0.field == "role" } && !appChanges.contains { $0.field == "name" }, "each carrier sees only its own")
        require(BuddyAgentChanges.unadopted(support: root.appendingPathComponent("nothing"), workspace: w).isEmpty, "no database, no changes")
        let other = try World(support: root.appendingPathComponent("b"))
        _ = try other.say(other.sage, "Rename Sage to Scout please", ["field": "name", "value": "Scout", "quote": "Rename Sage to Scout"])
        _ = try other.say(other.sage, "Rename Sage to Scout please", ["field": "instructions", "value": "Find roles.", "quote": "Rename Sage to Scout"])
        let owed = try other.store.unadoptedChanges(workspace: other.w, adopter: "page")
        try other.store.adoptChanges(workspace: other.w, adopter: "app", ids: owed.map(\.id))
        require(try other.store.unadoptedChanges(workspace: other.w, adopter: "page").count == owed.count, "the wrong carrier cannot say a change was carried home")
        try other.store.adoptChanges(workspace: other.w, adopter: "page", ids: owed.map(\.id))
        require(try other.store.unadoptedChanges(workspace: other.w, adopter: "page").isEmpty && other.store.unadoptedChanges(workspace: other.w, adopter: "app").count == 1, "carried-home changes stop being listed")
        require(BuddyAgentChanges.unadopted(support: other.support, workspace: other.w).allSatisfy { $0.adopter == "app" }, "the read-only reader lists only what is left")

        // 6. Only settings the app holds are written by the engine; the rest live in the journal until carried home.
        require(world.writes.isEmpty, "page and profile settings were never written by the engine: \(world.writes)")
        let model = try world.say(sage, "Switch Sage to claude-sonnet-4-6 on Claude", ["field": "model", "value": "{\"provider\":\"claude\",\"model\":\"claude-sonnet-4-6\"}", "quote": "Switch Sage to claude-sonnet-4-6 on Claude"])
        require(model["saved"] as? Bool == true && world.writes == ["agent:\(sage.prefix(4)):model"] && (world.native["agent:\(sage):model"] as? [String: Any])?["model"] as? String == "claude-sonnet-4-6", "a model change is written where models live: \(model)")
        let proactive = try world.say(sage, "Keep me posted proactively", ["field": "proactive", "value": "true", "quote": "Keep me posted proactively"])
        require(proactive["saved"] as? Bool == true && world.native["agent:\(sage):proactive"] as? Bool == true, "proactive updates are written where they live")
        let limitSet = try world.say(chief, "Cap Sage at $4 a day", ["agentId": sage, "field": "dailyLimitUSD", "value": "4", "quote": "Cap Sage at $4 a day"])
        require(limitSet["saved"] as? Bool == true, "adding a cap applies at once: \(limitSet)")
        require((try store.limits(workspace: w)).contains { $0["scope"] as? String == "agent" && $0["id"] as? String == sage && ($0["amountUSD"] as? Double) == 4.0 && $0["setBy"] as? String == "chat" && ($0["quote"] as? String)?.contains("$4") == true }, "the cap is in the ledger’s limits with the words that set it")
        let lowered = try world.say(chief, "Make Sage’s cap $2 a day", ["agentId": sage, "field": "dailyLimitUSD", "value": "2", "quote": "Make Sage’s cap $2 a day"])
        require(lowered["saved"] as? Bool == true, "lowering a cap applies at once")

        // 7. What raises spending or access waits for one tap, and nothing changes meanwhile.
        let writesBefore = world.writes.count
        let raised = try world.say(chief, "Raise Sage’s cap to $9 a day", ["agentId": sage, "field": "dailyLimitUSD", "value": "9", "quote": "Raise Sage’s cap to $9 a day"])
        require(raised["saved"] as? Bool == false && raised["needsConfirmation"] as? Bool == true, "raising a cap waits: \(raised)")
        require((try store.limits(workspace: w)).first { $0["id"] as? String == sage }?["amountUSD"] as? Double == 2.0, "the cap is unchanged until the person says so")
        let removed = try world.say(chief, "Remove Sage’s cap", ["agentId": sage, "field": "dailyLimitUSD", "value": "none", "quote": "Remove Sage’s cap"])
        require(removed["needsConfirmation"] as? Bool == true, "removing a cap waits")
        let toolOn = try world.say(sage, "Let Sage use the browser", ["field": "tools.desktop", "value": "true", "quote": "Let Sage use the browser"])
        require(toolOn["needsConfirmation"] as? Bool == true, "turning on a tool waits")
        let toolOff = try world.say(sage, "Stop Sage using the web", ["field": "tools.web", "value": "false", "quote": "Stop Sage using the web"])
        require(toolOff["saved"] as? Bool == true, "turning a tool off applies at once")
        let checkIns = try world.say(chief, "Turn the team check-ins back on", ["scope": "workspace", "field": "teamCheckInsEnabled", "value": "false", "quote": "Turn the team check-ins back on"])
        require(checkIns["saved"] as? Bool == true, "switching check-ins off applies at once")
        let checkInsOn = try world.say(chief, "Turn the team check-ins back on", ["scope": "workspace", "field": "teamCheckInsEnabled", "value": "true", "quote": "Turn the team check-ins back on"])
        require(checkInsOn["needsConfirmation"] as? Bool == true, "switching check-ins on waits")
        let faster = try world.say(chief, "Check in every 5 minutes", ["scope": "workspace", "field": "teamCheckInIntervalMinutes", "value": "5", "quote": "Check in every 5 minutes"])
        require(faster["needsConfirmation"] as? Bool == true, "checking in more often waits")
        let slower = try world.say(chief, "Check in every hour", ["scope": "workspace", "field": "teamCheckInIntervalMinutes", "value": "60", "quote": "Check in every hour"])
        require(slower["saved"] as? Bool == true, "checking in less often applies at once")
        require(world.writes.count == writesBefore + 2, "only the two applied workspace changes were written: \(world.writes.dropFirst(writesBefore))")
        let waiting = try store.openDecisions(workspace: w).filter { $0["kind"] as? String == "confirm" }
        require(waiting.count == 5, "each change that waits is one card: \(waiting.count)")
        let card = waiting.first { ($0["payload"] as? [String: Any])?["changeId"] as? String == raised["changeId"] as? String }!
        require((card["question"] as? String)?.contains("$2.00 a day → $9.00 a day") == true && card["actionLabel"] as? String == "Allow" && card["agentId"] as? String == sage, "the card says exactly what would change")
        require(try store.unadoptedChanges(workspace: w, adopter: "page").allSatisfy { $0.status != "pending" }, "a change that is waiting is not carried into anything")
        require(BuddyAgentChanges.unadopted(support: world.support, workspace: w).allSatisfy { $0.status == "applied" } && !BuddyAgentChanges.unadopted(support: world.support, workspace: w).isEmpty, "the read-only reader lists only changes that took effect, though others are waiting")
        require(refuses("the model answering its own card") { _ = try world.engine.answer(changeID: "nope", allow: true) }, "an unknown request cannot be answered")

        // 8. Only the person answers the card, and answering again does nothing.
        _ = try world.say(nil, "", ["agentId": sage, "field": "dailyLimitUSD", "value": "3"])
        let allowed = try world.engine.answer(changeID: raised["changeId"] as! String, allow: true)
        require(try allowed["saved"] as? Bool == true && (store.limits(workspace: w)).first { $0["id"] as? String == sage }?["amountUSD"] as? Double == 9.0, "allowing applies it: \(allowed)")
        require(refuses("answering twice") { _ = try world.engine.answer(changeID: raised["changeId"] as! String, allow: true) }, "a request is answered once")
        let denied = try world.engine.answer(changeID: toolOn["changeId"] as! String, allow: false)
        require(try denied["declined"] as? Bool == true && store.change(toolOn["changeId"] as! String)?.status == "declined", "declining leaves it as it was")
        require(try store.openDecisions(workspace: w).filter { $0["kind"] as? String == "confirm" }.count == 3, "answered cards go away")
        require(try store.change(raised["changeId"] as! String)?.old as? Double == 3.0, "the old value recorded is the one at the moment of allowing, not when it was asked")

        // 9. Undo puts the old value back, newest first, and obeys the same rules.
        let renamed = try world.say(sage, "Call her Ranger", ["field": "name", "value": "Ranger", "quote": "Call her Ranger"])
        let renamedAgain = try world.say(sage, "No, call her Wren", ["field": "name", "value": "Wren", "quote": "No, call her Wren"])
        require(refuses("undoing an older change") { _ = try world.engine.undo(actor: sage, text: "Undo that", args: ["changeId": renamed["changeId"] as! String, "quote": "Undo that"]) }, "an older change cannot be undone over a newer one")
        let undone = try world.engine.undo(actor: sage, text: "Undo that rename", args: ["changeId": renamedAgain["changeId"] as! String, "quote": "Undo that rename"])
        let snapshot = try world.engine.snapshot(agent: sage, workspaceFields: true)
        let settings = (snapshot["agent"] as? [String: Any])?["settings"] as? [String: Any]
        require(undone["saved"] as? Bool == true && settings?["name"] as? String == "“Ranger”", "undo restores the previous name: \(undone) \(String(describing: settings?["name"]))")
        require((try store.change(renamedAgain["changeId"] as! String))?.status == "undone", "the undone change says so")
        require(refuses("undo without words") { _ = try world.engine.undo(actor: sage, text: "Undo that", args: ["changeId": undone["changeId"] as! String]) }, "an agent’s undo also needs the person’s words")
        let screenUndo = try world.engine.undo(actor: nil, text: "", args: ["changeId": undone["changeId"] as! String])
        let afterScreen = (try world.engine.snapshot(agent: sage, workspaceFields: false)["agent"] as? [String: Any])?["settings"] as? [String: Any]
        require(screenUndo["saved"] as? Bool == true && afterScreen?["name"] as? String == "“Wren”", "the person can undo from the screen, even an undo: \(screenUndo)")
        let toolBack = try world.say(nil, "", ["agentId": mia, "field": "tools.desktop", "value": "true"])
        require(toolBack["saved"] as? Bool == true, "the person turning a tool on from the screen applies at once")
        let toolOffFromChat = try world.say(chief, "Turn off Mia’s browser", ["agentId": mia, "field": "tools.desktop", "value": "false", "quote": "Turn off Mia’s browser"])
        let undoAccess = try world.engine.undo(actor: chief, text: "Undo that, turn her browser back on", args: ["changeId": toolOffFromChat["changeId"] as! String, "quote": "turn her browser back on"])
        require(undoAccess["needsConfirmation"] as? Bool == true, "an undo that would give access back waits for the person: \(undoAccess)")
        let listed = try world.engine.list(agent: sage)
        require(listed.contains { $0["canUndo"] as? Bool == true } && listed.allSatisfy { ($0["summary"] as? String)?.isEmpty == false }, "the list says what changed in plain words and what can be undone")

        // 10. A write that fails is not recorded as done; being stopped half way is sorted out afterwards.
        world.failWrites = true
        require(refuses("a write that fails") { _ = try world.say(sage, "Set Sage’s model to gpt", ["field": "model", "value": "{\"provider\":\"chatgpt\",\"model\":\"\"}", "quote": "Set Sage’s model to gpt"]) }, "a failed write is reported")
        require((try store.changes(workspace: w, agent: sage, limit: 1)).first?.status == "failed", "and recorded as failed, not done")
        world.failWrites = false
        let halfDone = try store.recordChange(workspace: w, scope: "agent", agent: sage, field: "proactive", old: true, new: false, actor: "chat", source: "chat", quote: "stop the updates", status: "applying", risk: "low")
        let halfNot = try store.recordChange(workspace: w, scope: "agent", agent: sage, field: "model", old: nil, new: ["provider": "chatgpt", "model": ""], actor: "chat", source: "chat", quote: "use gpt", status: "applying", risk: "low")
        world.native["agent:\(sage):proactive"] = false
        try world.engine.reconcile()
        require(try store.change(halfDone)?.status == "applied" && store.change(halfNot)?.status == "failed", "after being stopped, a change counts only if it reached the setting")

        // 11. Standing rules.
        let ask = "For the first three applications, send me the CV so I can check your work. If I'm fine with those three, from then on, you can apply without me having to check on the CV each time."
        require(refuses("a rule without the person’s words") { _ = try world.engine.addRule(actor: sage, text: ask, args: ["rule": "Show the CV first", "then": "proceed", "reviewFirst": 3, "quote": "show me everything"]) }, "a rule needs the person’s own words")
        for bad: [String: Any] in [["rule": "x"], ["rule": "Show the CV first", "then": "proceed"], ["rule": "Show the CV first", "then": "proceed", "reviewFirst": 0], ["rule": "Show the CV first", "then": "proceed", "reviewFirst": 21], ["rule": "Show the CV first", "appliesTo": ["email"]], ["rule": "Show the CV first", "taskKinds": ["coding"]], ["rule": String(repeating: "r", count: 601)]] {
            var args = bad; args["quote"] = "send me the CV so I can check your work"
            require(refuses("a bad rule \(bad)") { _ = try world.engine.addRule(actor: sage, text: ask, args: args) }, "a malformed rule is refused: \(bad)")
        }
        require(try store.rules(workspace: w).isEmpty, "refused rules leave nothing behind")
        let added = try world.engine.addRule(actor: sage, text: ask, args: ["rule": "Send the CV for checking before applying; after three approved, apply without asking.", "then": "proceed", "reviewFirst": 3, "taskKinds": ["applications", "general"], "quote": "send me the CV so I can check your work"])
        let ruleID = added["ruleId"] as! String
        require(added["saved"] as? Bool == true && (added["message"] as? String)?.contains("first 3 times") == true && (added["message"] as? String)?.contains("still always ask") == true && (added["checkpointInstruction"] as? String)?.contains(ruleID) == true, "saving the rule says what happens and what never changes: \(added)")
        var rule = try store.rule(ruleID)!
        require(rule.status == "active" && rule.agentID == sage && rule.relaxes && rule.reviewFirst == 3 && !rule.graduated && rule.appliesTo == ["browser"] && rule.taskKinds == ["applications", "general"] && rule.quote.contains("send me the CV"), "the rule is saved as asked, with the words behind it")
        require(try world.engine.listRules(agent: sage).first?["summary"] as? String == "\(rule.text) (0 of 3 checks approved)", "the list shows progress")

        // 12. The agent’s guidance tells it to show its work until the rule is earned.
        let task = ["workspace": w, "agentId": sage, "kind": "applications"] as [String: Any]
        var guide = store.rulesGuidance(workspace: w, agent: sage)
        require(guide.contains("0 of 3 reviewed") && guide.contains("buddy_review_checkpoint") && guide.contains(ruleID) && guide.contains(String(ruleID.prefix(8))), "the agent is told to call the check until the rule is earned: \(guide)")
        require(BuddyRulesReader.guidance(support: world.support, workspace: w, agent: sage).contains("0 of 3 reviewed") && BuddyRulesReader.guidance(support: world.support, workspace: w, agent: mia).isEmpty, "the chat reads the same rules, and only the agent’s own")
        require(try store.autoApprovingRule(for: task) == nil, "an unearned rule lets nothing through")

        // 13. Checks count once each, only the person’s approvals count, and the third earns it.
        _ = try store.countApproval(rule: ruleID, review: "r1", agentName: "Scout")
        let again = try store.countApproval(rule: ruleID, review: "r1", agentName: "Scout")
        require(again.count == 1 && !again.graduated, "the same check never counts twice")
        require(try store.autoApprovingRule(for: task) == nil, "one check earns nothing")
        let checkedTask: [String: Any] = ["workspace": w, "agentId": sage, "kind": "applications", "checkpoints": [ruleID]]
        require(try store.autoApprovingRule(for: checkedTask)?.id == ruleID, "work the person has already checked in this very task goes ahead")
        require(try store.autoApprovingRule(for: ["workspace": w, "agentId": sage, "kind": "research", "checkpoints": [ruleID]]) == nil, "a kind of work the rule does not cover still asks")
        require(try store.autoApprovingRule(for: ["workspace": w, "agentId": mia, "kind": "applications", "checkpoints": [ruleID]]) == nil, "another agent is not covered")
        require(try store.autoApprovingRule(for: ["workspace": "other", "agentId": sage, "kind": "applications", "checkpoints": [ruleID]]) == nil, "another workspace is not covered")
        _ = try store.countApproval(rule: ruleID, review: "r2", agentName: "Scout")
        require(try store.openDecisions(workspace: w).filter { $0["kind"] as? String == "notice" }.isEmpty, "nothing is announced before it is earned")
        let third = try store.countApproval(rule: ruleID, review: "r3", agentName: "Scout")
        require(third.count == 3 && third.graduated, "the third approved check earns it")
        rule = try store.rule(ruleID)!
        require(rule.graduated, "and it is saved")
        let notices = try store.openDecisions(workspace: w).filter { $0["kind"] as? String == "notice" }
        require(notices.count == 1 && (notices[0]["title"] as? String)?.contains("Scout now works without asking") == true && (notices[0]["payload"] as? [String: Any])?["ruleId"] as? String == ruleID, "the person is told once, in plain words: \(notices)")
        _ = try store.countApproval(rule: ruleID, review: "r4", agentName: "Scout")
        require(try store.openDecisions(workspace: w).filter { $0["kind"] as? String == "notice" }.count == 1, "it is announced once")
        require(try store.autoApprovingRule(for: task)?.id == ruleID, "an earned rule lets that kind of work go ahead without a fresh check")
        require(try store.autoApprovingRule(for: ["workspace": w, "agentId": sage, "kind": "email"]) == nil && store.autoApprovingRule(for: task, tool: "connector") == nil, "only browser steps of the covered kinds")
        guide = store.rulesGuidance(workspace: w, agent: sage)
        require(guide.contains("may now go ahead without asking") && !guide.contains("call buddy_review_checkpoint"), "an earned rule no longer sends the agent to ask: \(guide)")

        // 14. The person can pause, switch off, remove or restart a rule, and each takes effect at once.
        let paused = try world.engine.manageRule(actor: nil, text: "", args: ["action": "pause", "ruleId": ruleID])
        require(try paused["saved"] as? Bool == true && store.autoApprovingRule(for: task) == nil, "a paused rule lets nothing through")
        require(refuses("counting under a paused rule") { _ = try store.countApproval(rule: ruleID, review: "r5") }, "a paused rule counts nothing")
        require(store.rulesGuidance(workspace: w, agent: sage).isEmpty, "a paused rule is not what the agent is told")
        _ = try world.engine.manageRule(actor: nil, text: "", args: ["action": "resume", "ruleId": ruleID])
        require(try store.autoApprovingRule(for: task)?.id == ruleID, "turning it back on restores what it earned")
        _ = try world.engine.manageRule(actor: nil, text: "", args: ["action": "reset", "ruleId": ruleID])
        rule = try store.rule(ruleID)!
        require(try !rule.graduated && store.approvals(rule: ruleID) == 0 && store.autoApprovingRule(for: task) == nil, "starting over means the checks come back")
        require(refuses("an agent managing another agent’s rule") { _ = try world.engine.manageRule(actor: mia, text: "Pause that rule please", args: ["action": "pause", "ruleId": ruleID, "quote": "Pause that rule please"]) }, "a rule belongs to its agent")
        let boss = try world.engine.manageRule(actor: chief, text: "Chief, remove Sage’s CV rule", args: ["action": "remove", "ruleId": ruleID, "quote": "remove Sage’s CV rule"])
        require(try boss["saved"] as? Bool == true && store.rules(workspace: w).isEmpty && store.autoApprovingRule(for: checkedTask) == nil, "a removed rule is gone, and so is what it allowed")
        require(!(try store.rules(workspace: w, includeRevoked: true)).isEmpty, "but its history is kept")

        // 15. A rule that only asks more often is allowed, never relaxes anything, and never graduates.
        let always = try world.engine.addRule(actor: nil, text: "", args: ["agentId": sage, "rule": "Always show me the cover letter first."])
        let alwaysID = always["ruleId"] as! String
        for n in 1...5 { _ = try store.countApproval(rule: alwaysID, review: "x\(n)") }
        require(try !(store.rule(alwaysID)!.graduated) && store.autoApprovingRule(for: ["workspace": w, "agentId": sage, "kind": "applications", "checkpoints": [alwaysID]]) == nil, "a rule that asks every time never lets anything through")
        for n in 0..<30 { _ = try? world.engine.addRule(actor: nil, text: "", args: ["agentId": mia, "rule": "Rule number \(n) in words"]) }
        require(refuses("a thirty-first rule") { _ = try world.engine.addRule(actor: nil, text: "", args: ["agentId": mia, "rule": "One too many rules"]) }, "an agent has at most thirty rules")

        print("PASS: settings change only on the person’s own quoted words and only by someone allowed to; each value is checked; every change keeps old and new and can be undone newest-first; access and spending increases wait for one tap; readers see changes before they are carried home; interrupted changes are sorted out; standing rules count only the person’s approvals, once each, earn their freedom at the number asked, apply to the right agent, kind and workspace, and can be paused, restarted or removed")
    }
}
