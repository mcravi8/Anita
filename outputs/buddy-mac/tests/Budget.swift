import Foundation

@main struct BudgetChecks {
    @MainActor static func require(_ value: Bool, _ message: String) { if !value { fputs("FAILED: \(message)\n", stderr); exit(1) } }
    static func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }
    static func run(_ path: String, _ environment: [String: String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path); process.standardOutput = Pipe(); process.standardError = Pipe()
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        try process.run(); process.waitUntilExit()
        return process.terminationStatus
    }
    static let authorization = "7E5D3B5A-2B6C-4B65-9C5B-0D0B6C2C1A22"

    // One commit per step.
    @MainActor static func script(_ store: BuddyWorkerStore, _ w: String, _ a: String, steps count: Int) throws {
        var id = ""
        let all: [() throws -> Void] = [
            { id = try store.create(workspace: w, agent: a, requestId: "money", title: "Paid work", goal: "Do it", kind: "general", provider: "claude", budget: 0.5)["id"] as! String },
            { try store.update(id, ["status": "running", "attempt": 1, "executionRunID": "r1", "remainingBudgetUSD": 0, "reservedBudgetUSD": 0.5]) },
            { try store.update(id, ["status": "completed", "spentUSD": 0.12, "remainingBudgetUSD": 0.38, "reservedBudgetUSD": 0]) },
            { try store.update(id, ["status": "running", "attempt": 2, "executionRunID": "r2", "remainingBudgetUSD": 0, "reservedBudgetUSD": 0.38]) },
            { try store.update(id, ["status": "interrupted"]) },
            { _ = try store.resume(id, additionalBudgetUSD: 0.3, authorizationID: authorization) },
        ]
        for step in 0..<min(count, all.count) { try all[step]() }
    }
    static let steps = 6
    @MainActor static func summary(_ directory: URL) throws -> [String] {
        let store = try BuddyWorkerStore(directory: directory)
        guard let job = store.jobs.first else { return ["empty"] }
        let ledger = try store.ledger(of: job["id"] as! String).map { "\($0["kind"] as! String)=\(String(format: "%.2f", $0["amountUSD"] as! Double))" }
        return ["status:\(job["status"] as? String ?? "")", "spent:\(job["spentUSD"] ?? 0)", "uncertain:\(job["uncertainBudgetUSD"] ?? 0)", "reserved:\(job["reservedBudgetUSD"] ?? 0)", "ledger:\(ledger)"]
    }
    /// Whenever the process is ended, the ledger and the task agree on what was spent and what cannot be accounted for.
    static func problems(_ directory: URL) throws -> [String] {
        let db = try BuddyOperationsDB(directory: directory, existing: true)
        var out: [String] = []
        for task in try db.rows("SELECT id, body FROM tasks") {
            guard let id = task[0].string, let body = try? BuddyOperationsDB.decode(task[1].string ?? "{}") else { continue }
            func total(_ kind: String) throws -> Double { Double(try db.rows("SELECT COALESCE(SUM(amount_usd), 0) FROM budget_entries WHERE task_id = ? AND kind = ?", [.text(id), .text(kind)]).first?.first?.string ?? "0") ?? 0 }
            func field(_ key: String) -> Double { (body[key] as? NSNumber)?.doubleValue ?? 0 }
            if !close(try total("spend"), field("spentUSD")) { out.append("spent \(try total("spend")) in the ledger but \(field("spentUSD")) on the task") }
            if !close(try total("uncertain"), field("uncertainBudgetUSD")) { out.append("uncertain \(try total("uncertain")) in the ledger but \(field("uncertainBudgetUSD")) on the task") }
            let held = try total("reserve") - total("release") - total("spend") - total("uncertain")
            if !close(held, field("reservedBudgetUSD")) { out.append("\(held) set aside by the ledger but \(field("reservedBudgetUSD")) on the task") }
        }
        return out
    }

    @MainActor static func main() throws {
        let environment = ProcessInfo.processInfo.environment
        if environment["BUDDY_CRASH_CHILD"] == "budget" {
            let directory = URL(fileURLWithPath: environment["BUDDY_CRASH_DIR"]!), phase = environment["BUDDY_CRASH_PHASE"] ?? "before", target = Int(environment["BUDDY_CRASH_AT"] ?? "") ?? 999
            let store = try BuddyWorkerStore(directory: directory)
            var count = 0
            BuddyOperationsDB.beforeCommit = { count += 1; if phase == "before" && count == target { _exit(137) } }
            BuddyOperationsDB.afterCommit = { if phase == "after" && count == target { _exit(137) } }
            try script(store, environment["BUDDY_CRASH_W"]!, environment["BUDDY_CRASH_A"]!, steps: steps)
            exit(0)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("buddy-budget-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let w = UUID().uuidString, a = UUID().uuidString, b = UUID().uuidString

        // 1. Every money event is one entry, written with the task.
        let main = root.appendingPathComponent("main"), worker = main.appendingPathComponent("Worker")
        let store = try BuddyWorkerStore(directory: worker)
        let paid = try store.create(workspace: w, agent: a, requestId: "paid", title: "Paid", goal: "Do it", kind: "general", provider: "claude", budget: 0.5), id = paid["id"] as! String
        var kinds = try store.ledger(of: id)
        require(kinds.count == 1 && kinds[0]["kind"] as? String == "authorize" && close(kinds[0]["amountUSD"] as! Double, 0.5), "a Claude task's allowance is the first entry")
        let free = try store.create(workspace: w, agent: a, requestId: "free", title: "Free", goal: "Do it", kind: "general", provider: "chatgpt", budget: 0)
        require(try store.ledger(of: free["id"] as! String).isEmpty, "a task that spends no money has no entries")
        try store.update(id, ["status": "running", "attempt": 1, "executionRunID": "r1", "remainingBudgetUSD": 0, "reservedBudgetUSD": 0.5])
        try store.update(id, ["progress": "Only text changed"])
        kinds = try store.ledger(of: id)
        require(kinds.map { $0["kind"] as! String } == ["authorize", "reserve"], "setting money aside is an entry, and changing text is not")
        try store.update(id, ["status": "completed", "spentUSD": 0.12, "remainingBudgetUSD": 0.38, "reservedBudgetUSD": 0])
        kinds = try store.ledger(of: id)
        require(kinds.map { $0["kind"] as! String } == ["authorize", "reserve", "spend", "release"] && close(kinds[2]["amountUSD"] as! Double, 0.12) && close(kinds[3]["amountUSD"] as! Double, 0.38), "an attempt that ends turns its reservation into what was spent and gives back the rest")
        try store.update(id, ["status": "running", "attempt": 2, "remainingBudgetUSD": 0, "reservedBudgetUSD": 0.38])
        try store.update(id, ["status": "interrupted"])
        _ = try store.resume(id, additionalBudgetUSD: 0.3, authorizationID: authorization)
        _ = try store.resume(id, additionalBudgetUSD: 0.3, authorizationID: authorization)
        kinds = try store.ledger(of: id)
        let tailEntries = Array(kinds.suffix(2)), tail = tailEntries.map { $0["kind"] as! String }
        require(tail == ["uncertain", "authorize"] && close(tailEntries[0]["amountUSD"] as! Double, 0.38) && kinds.filter { $0["kind"] as? String == "authorize" }.count == 2, "an abandoned reservation becomes an uncertain amount, a new allowance is one entry, and asking twice adds no second one")
        let mainProblems = try problems(worker)
        require(mainProblems.isEmpty, "the ledger and the task agree: \(mainProblems)")

        // 2. Money spent before the record began is kept, on the day it was spent, and never counted as today's.
        let legacy = root.appendingPathComponent("legacy/Worker")
        do {
            let seeded = try BuddyWorkerStore(directory: legacy)
            let old = try seeded.create(workspace: w, agent: a, requestId: "old", title: "Old", goal: "Do it", kind: "general", provider: "claude", budget: 0.5)
            try seeded.update(old["id"] as! String, ["status": "completed", "spentUSD": 0.2, "uncertainBudgetUSD": 0.1])
            let raw = try BuddyOperationsDB(directory: legacy, existing: true)
            try raw.run("DELETE FROM budget_entries"); try raw.run("PRAGMA user_version = 3")
            // As if the task had last changed long ago.
            for row in try raw.rows("SELECT id, body FROM tasks") {
                var body = try BuddyOperationsDB.decode(row[1].string ?? "{}"); body["updatedAt"] = "2026-01-02T10:00:00Z"
                try raw.run("UPDATE tasks SET body = ? WHERE id = ?", [.text(try BuddyOperationsDB.encode(body)), .text(row[0].string ?? "")])
            }
        }
        let upgraded = try BuddyWorkerStore(directory: legacy)
        let oldID = upgraded.jobs[0]["id"] as! String, oldEntries = try upgraded.ledger(of: oldID)
        require(oldEntries.map { $0["kind"] as! String } == ["spend", "uncertain"] && oldEntries.allSatisfy { $0["cause"] as? String == "history.begins" && ($0["day"] as? String ?? "").hasPrefix("2026-01-0") }, "earlier spending is entered once, on its own day")
        require(close(try upgraded.exposure(workspace: w, agent: a).total, 0), "and is not counted as today's")
        _ = try BuddyWorkerStore(directory: legacy)
        require(try upgraded.ledger(of: oldID).count == 2, "starting again does not enter it twice")

        // 3. Limits: one agent's own, or the workspace's; today's spending, set-aside money and uncertain money all count; tomorrow starts clear.
        let busy = try store.create(workspace: w, agent: b, requestId: "busy", title: "Busy", goal: "Do it", kind: "general", provider: "claude", budget: 0.5), busyID = busy["id"] as! String
        try store.update(busyID, ["status": "running", "attempt": 1, "remainingBudgetUSD": 0, "reservedBudgetUSD": 0.5])
        let busyUse = try store.exposure(workspace: w, agent: b)
        require(close(busyUse.reserved, 0.5) && close(busyUse.total, 0.5), "money a running task has set aside counts")
        let aExposure = try store.exposure(workspace: w, agent: a)
        require(close(aExposure.spent, 0.12) && close(aExposure.uncertain, 0.38), "spending and uncertain amounts count (\(aExposure))")
        require(BuddyBudget.headroom(support: main, workspace: w, agent: a) == nil, "with no limit set there is nothing to check")
        try store.setLimit(workspace: w, scope: "workspace", amount: 10, setBy: "user")
        try store.setLimit(workspace: w, scope: "agent", id: a, amount: 1, setBy: "user", quote: "Keep her to a dollar a day")
        var room = BuddyBudget.headroom(support: main, workspace: w, agent: a)
        require(room?.scope == "agent" && close(room?.limit ?? 0, 1) && close(room?.room ?? 0, 0.5), "an agent's own limit applies, with its room left (\(String(describing: room)))")
        room = BuddyBudget.headroom(support: main, workspace: w, agent: b)
        require(room?.scope == "workspace" && close(room?.limit ?? 0, 10) && close(room?.room ?? 0, 9.5), "an agent with none falls back to the workspace's")
        let listed = try store.limits(workspace: w)
        require(listed.count == 2 && listed.contains { $0["quote"] as? String == "Keep her to a dollar a day" }, "limits are listed with who set them and what was said")
        try store.setLimit(workspace: w, scope: "agent", id: a, amount: 0.3, setBy: "user")
        require(close(BuddyBudget.headroom(support: main, workspace: w, agent: a)?.room ?? -1, 0), "a limit below what is already used leaves no room")
        try store.setLimit(workspace: w, scope: "agent", id: a, amount: nil, setBy: "user")
        require(BuddyBudget.headroom(support: main, workspace: w, agent: a)?.scope == "workspace", "removing an agent's limit falls back again")
        // Runs have no limit of their own: a task with none sets nothing aside, and the model is only held to what a daily limit leaves.
        let open = try store.create(workspace: w, agent: b, requestId: "open-ended", title: "Open", goal: "Do it", kind: "general", provider: "claude", budget: BuddyRunLimit.none)
        try store.update(open["id"] as! String, ["status": "running", "attempt": 1, "remainingBudgetUSD": 0, "reservedBudgetUSD": BuddyRunLimit.none])
        require(close(try store.exposure(workspace: w, agent: b).reserved, 0.5), "a task with no limit of its own sets nothing aside")
        require(BuddyRunLimit.bridge(BuddyRunLimit.none, room: nil) is NSNull, "with no run limit and no daily limit the model gets no ceiling")
        require(close(BuddyRunLimit.bridge(BuddyRunLimit.none, room: 3.2) as? Double ?? 0, 3.2) && close(BuddyRunLimit.bridge(BuddyRunLimit.none, room: 0) as? Double ?? 0, 0.01), "a daily limit is the only ceiling there is")
        // A limit on the whole workspace is spent by everyone in it.
        try JSONSerialization.data(withJSONObject: ["agents": [["id": a], ["id": b]]]).write(to: main.appendingPathComponent("workspace.json"))
        require(close(BuddyBudget.headroom(support: main, workspace: w, agent: b)?.room ?? -1, 9.0), "a workspace-wide limit counts what the whole team has used, not one agent's share")
        for bad in [-1.0, Double.nan, Double.infinity, 200000] { var refused = false; do { try store.setLimit(workspace: w, scope: "workspace", amount: bad, setBy: "user") } catch { refused = true }; require(refused, "a limit of \(bad) is refused") }
        var badScope = false; do { try store.setLimit(workspace: w, scope: "agent", id: "not-an-agent", amount: 1, setBy: "user") } catch { badScope = true }
        require(badScope, "a limit needs a real agent")
        let tomorrow = Date().addingTimeInterval(36 * 3600)
        let nextDay = try store.exposure(workspace: w, agent: a, now: tomorrow)
        require(close(nextDay.spent, 0) && close(nextDay.uncertain, 0), "tomorrow's spending starts clear")
        let status = try store.budgetStatus(workspace: w, agents: [a, b])
        let rows = status["agents"] as! [String: [String: Any]]
        require((rows[b]?["roomUSD"] as? Double).map { close($0, 9.5) } == true && rows[a]?["limitScope"] as? String == "workspace", "the status shows each agent's money and room")

        // 4. Chat turns are counted too: what they cost, what a running one may still cost, and what a turn that never reported might have cost.
        let chatSupport = root.appendingPathComponent("chat"); let chatWorker = chatSupport.appendingPathComponent("Worker")
        let chatStore = try BuddyWorkerStore(directory: chatWorker)
        try chatStore.setLimit(workspace: w, scope: "agent", id: a, amount: 2, setBy: "user")
        let now = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!   // midday, so a few hours later is still today
        BuddyBudget.recordChat(support: chatSupport, workspace: w, agent: a, runID: "turn-1", kind: "reserve", amount: 0.5, now: now)
        BuddyBudget.recordChat(support: chatSupport, workspace: w, agent: a, runID: "turn-1", kind: "spend", amount: 0.31, now: now)
        BuddyBudget.recordChat(support: chatSupport, workspace: w, agent: a, runID: "turn-2", kind: "reserve", amount: 0.5, now: now)
        BuddyBudget.recordChat(support: chatSupport, workspace: w, agent: b, runID: "turn-3", kind: "spend", amount: 9, now: now)
        var chatUse = try chatStore.exposure(workspace: w, agent: a, now: now)
        require(close(chatUse.spent, 0.31) && close(chatUse.reserved, 0.5) && close(chatUse.uncertain, 0), "a finished chat turn counts what it cost and a running one what it may cost, for its own agent only (\(chatUse))")
        chatUse = try chatStore.exposure(workspace: w, agent: a, now: now.addingTimeInterval(3 * 3600))
        require(close(chatUse.reserved, 0) && close(chatUse.uncertain, 0.5), "a turn that never reported is counted as uncertain, so a crash cannot make money disappear (\(chatUse))")
        let chatRoom = BuddyBudget.headroom(support: chatSupport, workspace: w, agent: a, now: now)
        require(close(chatRoom?.room ?? -1, 2 - 0.31 - 0.5), "a chat turn is held to what is left of the day's limit")
        BuddyBudget.recordChat(support: chatSupport, workspace: w, agent: a, runID: "bad", kind: "spend", amount: -5, now: now)
        BuddyBudget.recordChat(support: chatSupport, workspace: w, agent: a, runID: "bad", kind: "mystery", amount: 5, now: now)
        require(close(try chatStore.exposure(workspace: w, agent: a, now: now).spent, 0.31), "a negative amount or an unknown kind is never recorded")

        // 5. A task that would pass the limit waits, resumable, with the reason, and nothing is set aside.
        let heldStore = try BuddyWorkerStore(directory: root.appendingPathComponent("held/Worker"))
        let held = try heldStore.create(workspace: w, agent: a, requestId: "held", title: "Held", goal: "Do it", kind: "general", provider: "claude", budget: 0.5), heldID = held["id"] as! String
        try heldStore.setLimit(workspace: w, scope: "agent", id: a, amount: 0.4, setBy: "user")
        let heldRoom = BuddyBudget.headroom(support: root.appendingPathComponent("held"), workspace: w, agent: a)!
        require(heldRoom.room + 1e-9 < 0.5, "half a dollar does not fit in forty cents")
        try heldStore.refuseForLimit(heldID, limit: heldRoom.limit, scope: heldRoom.scope, exposure: heldRoom.exposure, wanted: 0.5)
        let waiting = try heldStore.job(heldID), message = waiting["progress"] as? String ?? ""
        require(waiting["status"] as? String == "paused" && message.contains("$0.40") && message.contains("$0.50") && message.contains("resume"), "the task is paused with a plain reason: \(message)")
        require(try heldStore.history(of: heldID).contains { $0.type == "budget.refused" && $0.payload["limitUSD"] as? Double == 0.4 }, "and the refusal is in its history")
        require(close(try heldStore.exposure(workspace: w, agent: a).reserved, 0), "nothing was set aside")
        try heldStore.setLimit(workspace: w, scope: "agent", id: a, amount: 5, setBy: "user")
        let resumed = try heldStore.resume(heldID)
        require(resumed["status"] as? String == "queued", "raising the limit lets it be resumed")

        // 6. Ending the process at every commit of a task's money life keeps the ledger and the task in step.
        let binary = CommandLine.arguments[0]
        var reference: [Int: [String]] = [:]
        for count in 0...steps {
            let directory = root.appendingPathComponent("reference-\(count)")
            try script(try BuddyWorkerStore(directory: directory), w, a, steps: count)
            reference[count] = try summary(directory)
        }
        let referenceProblems = try problems(root.appendingPathComponent("reference-\(steps)"))
        require(referenceProblems.isEmpty, "a whole life of spending balances: \(referenceProblems)")
        for commit in 1...steps {
            for phase in ["before", "after"] {
                let directory = root.appendingPathComponent("crash-\(phase)-\(commit)")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let status = try run(binary, ["BUDDY_CRASH_CHILD": "budget", "BUDDY_CRASH_DIR": directory.path, "BUDDY_CRASH_AT": "\(commit)", "BUDDY_CRASH_PHASE": phase, "BUDDY_CRASH_W": w, "BUDDY_CRASH_A": a])
                require(status == 137, "the worker was ended \(phase) commit \(commit)")
                let raw = try problems(directory)
                require(raw.isEmpty, "straight after being ended \(phase) commit \(commit), the ledger and the task agree: \(raw)")
                let expected = reference[phase == "before" ? commit - 1 : commit]!, found = try summary(directory)
                require(found == expected, "after being ended \(phase) commit \(commit), the money is exactly as \(phase == "before" ? "before" : "after") that step\n found: \(found)\n wanted: \(expected)")
            }
        }
        print("PASS: every money event is a ledger entry written with its task; earlier spending kept on its own day; limits per agent and workspace with fallback, rollover and validation; chat turns counted, held to the room left, and unreported ones kept as uncertain; a task that would pass its limit waits with the reason and resumes when it is raised; and the process ended at all \(steps * 2) commit boundaries")
    }
}
