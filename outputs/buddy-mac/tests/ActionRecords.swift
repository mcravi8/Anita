import Foundation

@main struct ActionChecks {
    @MainActor static func require(_ value: Bool, _ message: String) { if !value { fputs("FAILED: \(message)\n", stderr); exit(1) } }

    static func review(_ id: String, kind: String? = "browser", tool: String = "Click Send", detail: String = "to alice", status: String = "pending") -> [String: Any] {
        var r: [String: Any] = ["id": id, "status": status, "tool": ["name": tool, "service": "Buddy private browser", "arguments": ["target": detail]], "questions": [] as [[String: Any]]]
        if let kind { r["kind"] = kind }
        return r
    }
    static func run(_ path: String, _ arguments: [String], environment: [String: String] = [:]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments; process.standardOutput = Pipe(); process.standardError = Pipe()
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        try process.run(); process.waitUntilExit()
        return process.terminationStatus
    }
    static func fails(_ body: () throws -> Void) -> String? { do { try body(); return nil } catch { return error.localizedDescription } }

    // One step each, one commit each.
    @MainActor static func propose(_ store: BuddyWorkerStore, _ task: String, _ review: [String: Any]) throws {
        var reviews = try store.job(task)["reviews"] as? [[String: Any]] ?? []; reviews.append(review)
        try store.update(task, ["reviews": reviews, "status": "waiting_review"])
    }
    @MainActor static func approve(_ store: BuddyWorkerStore, _ task: String, _ id: String) throws {
        var reviews = try store.job(task)["reviews"] as? [[String: Any]] ?? []
        let i = reviews.firstIndex { $0["id"] as? String == id }!; reviews[i]["status"] = "answered"
        try store.update(task, ["reviews": reviews, "status": "running"])
    }
    @MainActor static func start(_ store: BuddyWorkerStore, _ w: String, _ a: String, request: String = "t", run: String = "run-1") throws -> String {
        let id = try store.create(workspace: w, agent: a, requestId: request, title: "Send the form", goal: "Do it", kind: "general", provider: "claude", budget: 0.5)["id"] as! String
        try store.update(id, ["status": "running", "attempt": 1, "executionRunID": run, "remainingBudgetUSD": 0, "reservedBudgetUSD": 0.5])
        return id
    }
    @MainActor static func newAttempt(_ store: BuddyWorkerStore, _ id: String, _ number: Int) throws {
        try store.update(id, ["status": "paused"]); try store.update(id, ["status": "queued"])
        try store.update(id, ["status": "running", "attempt": number, "executionRunID": "run-\(number)"])
    }
    static let mapping = ["pending": "proposed", "answered": "approved", "dispatched": "dispatched", "completed": "confirmed", "uncertain": "uncertain", "cancelled": "declined", "expired": "expired", "not_sent": "not_sent"]

    static let steps = 11
    @MainActor static func script(_ store: BuddyWorkerStore, _ w: String, _ a: String, steps count: Int) throws {
        var id = ""
        let all: [() throws -> Void] = [
            { id = try store.create(workspace: w, agent: a, requestId: "t", title: "Send the form", goal: "Do it", kind: "general", provider: "claude", budget: 0.5)["id"] as! String },
            { try store.update(id, ["status": "running", "attempt": 1, "executionRunID": "run-1"]) },
            { try propose(store, id, review("r1")) },
            { try approve(store, id, "r1") },
            { try store.markDispatched(task: id, review: "r1") },
            { try store.finishAction(task: id, review: "r1", status: "completed", receipt: ["performed": true]) },
            { try propose(store, id, review("r2", detail: "to bob")) },
            { try approve(store, id, "r2") },
            { try store.markDispatched(task: id, review: "r2") },
            { try store.finishAction(task: id, review: "r2", status: "uncertain", receipt: ["error": "lost connection"]) },
            { try store.resolveAction(task: id, review: "r2", confirmed: false) },
        ]
        for step in 0..<min(count, all.count) { try all[step]() }
    }
    @MainActor static func summary(_ directory: URL) throws -> [String] {
        let store = try BuddyWorkerStore(directory: directory)
        guard let job = store.jobs.first else { return ["empty"] }
        let id = job["id"] as! String
        let reviews = (job["reviews"] as? [[String: Any]] ?? []).map { "\($0["id"] as? String ?? "")=\($0["status"] as? String ?? "")" }
        let actions = try store.actions(of: id).map { "\($0.id)=\($0.state)" }
        let types = try store.history(of: id).map(\.type).joined(separator: ",")
        return ["status:\(job["status"] as? String ?? "")", "reviews:\(reviews)", "actions:\(actions)", "history:\(types)"]
    }
    /// Whenever the process is ended: each action's record says what the task's review says, and its last event says it too.
    static func problems(_ directory: URL) throws -> [String] {
        let db = try BuddyOperationsDB(directory: directory, existing: true)
        var out: [String] = []
        for task in try db.rows("SELECT id, body FROM tasks") {
            guard let id = task[0].string, let body = try? BuddyOperationsDB.decode(task[1].string ?? "{}") else { continue }
            let shown = Dictionary(uniqueKeysWithValues: (body["reviews"] as? [[String: Any]] ?? []).compactMap { r in (r["id"] as? String).map { ($0, mapping[r["status"] as? String ?? ""] ?? "?") } })
            var rows: [String: String] = [:]
            for row in try db.rows("SELECT id, state FROM actions WHERE task_id = ?", [.text(id)]) { if let k = row[0].string, let v = row[1].string { rows[k] = v } }
            if shown != rows { out.append("reviews \(shown) and records \(rows) disagree") }
            var last: [String: String] = [:]
            for event in try db.rows("SELECT type, payload FROM events WHERE task_id = ? AND type LIKE 'action.%' ORDER BY seq", [.text(id)]) {
                let payload = (try? BuddyOperationsDB.decode(event[1].string ?? "{}")) ?? [:]
                if let k = payload["id"] as? String, let state = payload["state"] as? String { last[k] = state }
            }
            if last != rows { out.append("last events \(last) and records \(rows) disagree") }
        }
        return out
    }

    @MainActor static func main() throws {
        let environment = ProcessInfo.processInfo.environment
        if environment["BUDDY_CRASH_CHILD"] == "actions" {
            let directory = URL(fileURLWithPath: environment["BUDDY_CRASH_DIR"]!), phase = environment["BUDDY_CRASH_PHASE"] ?? "before", target = Int(environment["BUDDY_CRASH_AT"] ?? "") ?? 999
            let store = try BuddyWorkerStore(directory: directory)
            var count = 0
            BuddyOperationsDB.beforeCommit = { count += 1; if phase == "before" && count == target { _exit(137) } }
            BuddyOperationsDB.afterCommit = { if phase == "after" && count == target { _exit(137) } }
            try script(store, environment["BUDDY_CRASH_W"]!, environment["BUDDY_CRASH_A"]!, steps: steps)
            exit(0)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("buddy-actions-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let w = UUID().uuidString, a = UUID().uuidString

        // 1. One record for every action, following it from proposal to receipt, with what happened written beside it.
        let life = try BuddyWorkerStore(directory: root.appendingPathComponent("life"))
        let t1 = try start(life, w, a)
        try propose(life, t1, review("r1"))
        var rows = try life.actions(of: t1)
        require(rows.count == 1 && rows[0].state == "proposed" && rows[0].kind == "browser" && rows[0].tool == "Click Send" && rows[0].runID == "run-1" && rows[0].attempt == 1, "a proposed action gets a record with its kind, tool and attempt")
        require(rows[0].payloadHash.count == 64, "and a fingerprint of exactly what the user was shown")
        try approve(life, t1, "r1")
        require(try life.actions(of: t1)[0].state == "approved", "approval is recorded")
        try life.markDispatched(task: t1, review: "r1")
        rows = try life.actions(of: t1)
        let shownDispatched = (try life.job(t1)["reviews"] as! [[String: Any]])[0]["status"] as? String
        require(rows[0].state == "dispatched" && rows[0].dispatchedAt != nil && shownDispatched == "dispatched", "being sent is recorded, in the record and on the task")
        try life.finishAction(task: t1, review: "r1", status: "completed", receipt: ["performed": true])
        rows = try life.actions(of: t1)
        require(rows[0].state == "confirmed" && rows[0].finishedAt != nil && rows[0].receipt["performed"] as? Bool == true && !rows[0].late, "the receipt is kept and the action is confirmed")
        let actionEvents = try life.history(of: t1).filter { $0.type.hasPrefix("action.") }
        require(actionEvents.map(\.type) == ["action.proposed", "action.approved", "action.dispatched", "action.confirmed"], "each step is an event, in order: \(actionEvents.map(\.type))")
        require(actionEvents.allSatisfy { ($0.payload["id"] as? String) == "r1" && ($0.payload["tool"] as? String) == "Click Send" }, "and each says which action and what")
        let lifeProblems = try problems(root.appendingPathComponent("life"))
        require(lifeProblems.isEmpty, "records, reviews and events agree: \(lifeProblems)")
        require(life.actionFacts(of: t1).contains("“Click Send”: done") && life.actionFacts(of: t1).contains("Do not repeat it"), "the model is told what was done")

        // 2. Nothing is sent when it must not be.
        let guarded = try BuddyWorkerStore(directory: root.appendingPathComponent("guarded"))
        let t2 = try start(guarded, w, a)
        try propose(guarded, t2, review("late"))
        try newAttempt(guarded, t2, 2)
        let stale = fails { try guarded.markDispatched(task: t2, review: "late") }
        require(stale?.contains("replaced") == true, "an action proposed by a replaced attempt is not sent: \(stale ?? "no error")")
        require(try guarded.actions(of: t2).first { $0.id == "late" }?.state == "proposed", "and its record is untouched")
        try propose(guarded, t2, review("a1", detail: "to carol")); try approve(guarded, t2, "a1")
        try guarded.update(t2, ["status": "paused"])
        let notWorking = fails { try guarded.markDispatched(task: t2, review: "a1") }
        require(notWorking?.contains("no longer working") == true, "nothing is sent for a task that is not working: \(notWorking ?? "no error")")
        try guarded.update(t2, ["status": "running"])
        try guarded.markDispatched(task: t2, review: "a1")
        let twice = fails { try guarded.markDispatched(task: t2, review: "a1") }
        require(twice?.contains("already") == true, "an action cannot be sent twice: \(twice ?? "no error")")
        let missing = fails { try guarded.markDispatched(task: t2, review: "nope") }
        require(missing != nil, "an action that is not on the task is not sent")
        // An identical action is held back while an earlier one is unconfirmed.
        try propose(guarded, t2, review("twin-a", detail: "to dave")); try propose(guarded, t2, review("twin-b", detail: "to dave")); try propose(guarded, t2, review("other", detail: "to erin"))
        try guarded.markDispatched(task: t2, review: "twin-a")
        let inFlight = fails { try guarded.markDispatched(task: t2, review: "twin-b") }
        require(inFlight?.contains("identical") == true, "an identical action is held back while the first is still being sent: \(inFlight ?? "no error")")
        try guarded.finishAction(task: t2, review: "twin-a", status: "uncertain", receipt: ["error": "lost connection"])
        let unconfirmed = fails { try guarded.markDispatched(task: t2, review: "twin-b") }
        require(unconfirmed?.contains("identical") == true, "and while it is unconfirmed")
        try guarded.markDispatched(task: t2, review: "other")
        require(try guarded.actions(of: t2).first { $0.id == "other" }?.state == "dispatched", "a different action is not held back")
        try guarded.resolveAction(task: t2, review: "twin-a", confirmed: true)
        try guarded.markDispatched(task: t2, review: "twin-b")
        require(try guarded.actions(of: t2).first { $0.id == "twin-b" }?.state == "dispatched", "once the first is checked off, the same action may be sent")
        let guardedProblems = try problems(root.appendingPathComponent("guarded"))
        require(guardedProblems.isEmpty, "records, reviews and events still agree: \(guardedProblems)")

        // 3. A receipt from a replaced attempt is still a fact. It is recorded, and marked late.
        let slow = try BuddyWorkerStore(directory: root.appendingPathComponent("slow"))
        let t3 = try start(slow, w, a)
        try propose(slow, t3, review("slow-1")); try approve(slow, t3, "slow-1"); try slow.markDispatched(task: t3, review: "slow-1")
        try newAttempt(slow, t3, 2)
        try slow.finishAction(task: t3, review: "slow-1", status: "completed", receipt: ["performed": true])
        let late = try slow.actions(of: t3)[0]
        let lateEvent = try slow.history(of: t3).last { $0.type == "action.confirmed" }
        require(late.state == "confirmed" && late.late && lateEvent?.payload["late"] as? Bool == true, "a late receipt is recorded and marked late")
        // A copy of a review that arrives late cannot move an action backwards.
        let t3b = try start(slow, w, a, request: "t3b", run: "run-1")
        try propose(slow, t3b, review("copy")); try approve(slow, t3b, "copy"); try slow.markDispatched(task: t3b, review: "copy")
        var regress = try slow.job(t3b)["reviews"] as! [[String: Any]]; regress[0]["status"] = "answered"
        try slow.update(t3b, ["reviews": regress])
        let shownCopy = (try slow.job(t3b)["reviews"] as! [[String: Any]])[0]["status"] as? String, recordedCopy = try slow.actions(of: t3b)[0].state
        require(shownCopy == "dispatched" && recordedCopy == "dispatched", "a stale copy of a review does not move an action backwards")
        // A terminal result cannot be overwritten by a later, different one.
        try slow.finishAction(task: t3b, review: "copy", status: "completed", receipt: ["performed": true])
        try slow.finishAction(task: t3b, review: "copy", status: "cancelled", receipt: [:])
        require((try slow.actions(of: t3b))[0].state == "confirmed", "a finished action stays as it finished")

        // 4. A restart settles every waiting action by how far it got.
        let crashed = root.appendingPathComponent("crashed")
        var tools: [String: String] = [:]
        let t4: String
        do {
            let before = try BuddyWorkerStore(directory: crashed)
            t4 = try start(before, w, a)
            try propose(before, t4, review("never-approved", detail: "x1"))
            try propose(before, t4, review("approved-only", detail: "x2")); try approve(before, t4, "approved-only")
            try propose(before, t4, review("being-sent", tool: "Submit application", detail: "x3")); try approve(before, t4, "being-sent"); try before.markDispatched(task: t4, review: "being-sent")
            try propose(before, t4, review("odd-kind", kind: "mystery", tool: "Strange thing", detail: "x4")); try approve(before, t4, "odd-kind")
            try propose(before, t4, review("connector", kind: nil, tool: "Send email", detail: "x5")); try approve(before, t4, "connector")
            tools = ["being-sent": "Submit application", "odd-kind": "Strange thing"]
        }
        let after = try BuddyWorkerStore(directory: crashed)
        let statuses = Dictionary(uniqueKeysWithValues: (try after.job(t4)["reviews"] as! [[String: Any]]).map { ($0["id"] as! String, $0["status"] as! String) })
        require(statuses == ["never-approved": "expired", "approved-only": "not_sent", "being-sent": "uncertain", "odd-kind": "uncertain", "connector": "uncertain"], "a restart settles each action by how far it got, and an approved connected-service request counts as possibly sent: \(statuses)")
        let settled = Dictionary(uniqueKeysWithValues: try after.actions(of: t4).map { ($0.id, $0.state) })
        require(settled == ["never-approved": "expired", "approved-only": "not_sent", "being-sent": "uncertain", "odd-kind": "uncertain", "connector": "uncertain"], "and the records say the same: \(settled)")
        let progress = try after.job(t4)["progress"] as? String ?? ""
        require(after.jobs[0]["status"] as? String == "interrupted" && progress.contains("may have been sent") && progress.contains("3 actions"), "the task says plainly that actions need checking: \(progress)")
        let causes = try after.history(of: t4).filter { ["action.expired", "action.not_sent", "action.uncertain"].contains($0.type) }.map { "\($0.type)/\($0.cause)" }
        require(causes.sorted() == ["action.expired/worker.restart", "action.not_sent/worker.restart", "action.uncertain/worker.restart", "action.uncertain/worker.restart", "action.uncertain/worker.restart"], "each outcome is an event caused by the restart: \(causes)")
        let facts = after.actionFacts(of: t4)
        require(facts.contains("“Submit application”: unconfirmed") && facts.contains("not sent") && !tools.isEmpty, "the model is told what is unconfirmed and what is safe to propose again")
        // Reviews that were saved before records existed are assumed to have been sent.
        let legacy = root.appendingPathComponent("legacy")
        do {
            let seeded = try BuddyWorkerStore(directory: legacy)
            let id = try start(seeded, w, a)
            try propose(seeded, id, review("old", detail: "y")); try approve(seeded, id, "old")
            try BuddyOperationsDB(directory: legacy, existing: true).run("DELETE FROM actions")
        }
        let reopened = try BuddyWorkerStore(directory: legacy)
        let oldStates = Dictionary(uniqueKeysWithValues: try reopened.actions(of: reopened.jobs[0]["id"] as! String).map { ($0.id, $0.state) })
        require(oldStates == ["old": "uncertain"] && (reopened.jobs[0]["reviews"] as! [[String: Any]])[0]["status"] as? String == "uncertain", "an approval from before records existed is treated as possibly sent: \(oldStates)")
        let restartProblems = try problems(crashed)
        require(restartProblems.isEmpty, "after a restart, records, reviews and events agree: \(restartProblems)")

        // 5. Stopping a task settles its actions the same way.
        let stopped = try BuddyWorkerStore(directory: root.appendingPathComponent("stopped"))
        let t5 = try start(stopped, w, a)
        try propose(stopped, t5, review("s-pending", detail: "p1"))
        try propose(stopped, t5, review("s-approved", detail: "p2")); try approve(stopped, t5, "s-approved")
        try propose(stopped, t5, review("s-sent", detail: "p3")); try approve(stopped, t5, "s-sent"); try stopped.markDispatched(task: t5, review: "s-sent")
        try stopped.settleActions(of: t5, pending: "cancelled", cause: "stop")
        let stoppedStates = Dictionary(uniqueKeysWithValues: try stopped.actions(of: t5).map { ($0.id, $0.state) })
        require(stoppedStates == ["s-pending": "declined", "s-approved": "not_sent", "s-sent": "uncertain"], "stopping settles actions by how far they got: \(stoppedStates)")
        try stopped.settleActions(of: t5, pending: "cancelled", cause: "stop")
        require(try stopped.history(of: t5).filter { $0.cause == "stop" }.count == 3, "settling again changes nothing")

        // 6. The user checks an unconfirmed action off: it went through, or it did not.
        let t6 = t5
        try stopped.resolveAction(task: t6, review: "s-sent", confirmed: true)
        var resolved = try stopped.actions(of: t6).first { $0.id == "s-sent" }!
        require(resolved.state == "confirmed" && resolved.resolvedBy == "user" && resolved.receipt["outcome"] as? String == "went_through", "the user can say it went through")
        let again = fails { try stopped.resolveAction(task: t6, review: "s-sent", confirmed: false) }
        require(again != nil, "an action that is not waiting to be checked cannot be marked: \(again ?? "no error")")
        let t7 = try start(stopped, w, a, request: "t7")
        try propose(stopped, t7, review("u1", detail: "z")); try approve(stopped, t7, "u1"); try stopped.markDispatched(task: t7, review: "u1")
        try stopped.settleActions(of: t7, pending: "cancelled", cause: "stop")
        try stopped.resolveAction(task: t7, review: "u1", confirmed: false)
        resolved = try stopped.actions(of: t7)[0]
        let shownResolved = (try stopped.job(t7)["reviews"] as! [[String: Any]])[0]["status"] as? String
        require(resolved.state == "not_sent" && resolved.resolvedBy == "user" && shownResolved == "not_sent", "or that it did not")
        require(stopped.actionFacts(of: t7).contains("safe to propose again"), "and then it is safe to propose again")
        let resolveEvent = try stopped.history(of: t7).last { $0.type == "action.not_sent" }
        require(resolveEvent?.cause == "user.resolved", "the answer is an event with its cause")
        let stoppedProblems = try problems(root.appendingPathComponent("stopped"))
        require(stoppedProblems.isEmpty, "records, reviews and events agree after checking off: \(stoppedProblems)")

        // 7. Leases: one holder at a time, a number that only goes up, and a token that stops working when the resource changes hands.
        let rented = try BuddyWorkerStore(directory: root.appendingPathComponent("leases"))
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try rented.acquireLease("browser:agent", holder: "task-1#run-1", task: "task-1", ttl: 100, now: t0)
        require(first == BuddyLease(resource: "browser:agent", generation: 1, holder: "task-1#run-1"), "the first holder gets generation 1")
        let renewed = try rented.acquireLease("browser:agent", holder: "task-1#run-1", task: "task-1", ttl: 100, now: t0.addingTimeInterval(50))
        require(renewed == first, "the same holder asking again keeps its generation")
        let busy = try rented.acquireLease("browser:agent", holder: "task-2#run-1", task: "task-2", ttl: 100, now: t0.addingTimeInterval(60), isLive: { _ in true })
        require(busy == nil, "another holder is turned away while the first is live and unexpired")
        let other = try rented.acquireLease("browser:other", holder: "task-2#run-1", task: "task-2", ttl: 100, now: t0)
        require(other?.generation == 1, "another resource is independent")
        let gone = try rented.acquireLease("browser:agent", holder: "task-2#run-1", task: "task-2", ttl: 100, now: t0.addingTimeInterval(60), isLive: { _ in false })
        require(gone?.generation == 2 && gone?.holder == "task-2#run-1", "a holder that is no longer alive is replaced with the next generation")
        let firstIsCurrent = try rented.leaseIsCurrent(first!), goneIsCurrent = try rented.leaseIsCurrent(gone!)
        require(!firstIsCurrent && goneIsCurrent, "the replaced holder's token stops working and the new one works")
        try rented.releaseLease(first!)
        let stillHeld = try rented.leaseIsCurrent(gone!)
        require(stillHeld, "an old token cannot release a lease it no longer holds")
        let expiredTake = try rented.acquireLease("browser:agent", holder: "task-3#run-1", task: "task-3", ttl: 100, now: t0.addingTimeInterval(1000), isLive: { _ in true })
        require(expiredTake?.generation == 3, "an expired lease can be taken over even if its holder looks alive")
        try rented.releaseLease(expiredTake!)
        let freed = try rented.leaseIsCurrent(expiredTake!)
        require(!freed, "a released lease is no longer current")
        let afterRelease = try rented.acquireLease("browser:agent", holder: "task-3#run-1", task: "task-3", ttl: 100, now: t0.addingTimeInterval(1001))
        require(afterRelease?.generation == 4, "releasing keeps the number, so the next holder gets a higher one and an old token never matches")
        try rented.releaseLeases(heldBy: "task-3")
        let byTask = try rented.leaseIsCurrent(afterRelease!)
        require(!byTask, "all of a task's leases can be freed at once")
        _ = try rented.acquireLease("browser:agent", holder: "task-4#run-1", task: "task-4", ttl: 100, now: t0.addingTimeInterval(2000))
        _ = try rented.acquireLease("browser:other", holder: "task-4#run-1", task: "task-4", ttl: 100, now: t0.addingTimeInterval(2000), isLive: { _ in true })
        require(try rented.breakAllLeases() >= 1, "a worker that has just started frees whatever the last one held")
        let reacquired = try rented.acquireLease("browser:agent", holder: "task-5#run-1", task: "task-5", ttl: 100, now: t0.addingTimeInterval(2001))
        require(reacquired?.generation == 6, "and the numbers carry on from where they were (\(String(describing: reacquired?.generation)))")

        // 8. Ending the process at every commit boundary of an action's life: the record, the review and the history never disagree.
        let binary = CommandLine.arguments[0]
        var reference: [Int: [String]] = [:]
        for count in 0...steps {
            let directory = root.appendingPathComponent("reference-\(count)")
            try script(try BuddyWorkerStore(directory: directory), w, a, steps: count)
            reference[count] = try summary(directory)
        }
        for commit in 1...steps {
            for phase in ["before", "after"] {
                let directory = root.appendingPathComponent("crash-\(phase)-\(commit)")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let status = try run(binary, [], environment: ["BUDDY_CRASH_CHILD": "actions", "BUDDY_CRASH_DIR": directory.path, "BUDDY_CRASH_AT": "\(commit)", "BUDDY_CRASH_PHASE": phase, "BUDDY_CRASH_W": w, "BUDDY_CRASH_A": a])
                require(status == 137, "the worker was ended \(phase) commit \(commit)")
                let raw = try problems(directory)
                require(raw.isEmpty, "straight after being ended \(phase) commit \(commit), records, reviews and events agree: \(raw)")
                let expected = reference[phase == "before" ? commit - 1 : commit]!, found = try summary(directory)
                require(found == expected, "after being ended \(phase) commit \(commit), the task is exactly as \(phase == "before" ? "before" : "after") that step\n found: \(found)\n wanted: \(expected)")
                let tidy = try problems(directory)
                require(tidy.isEmpty, "after the restart settles things, they still agree: \(tidy)")
            }
        }
        print("PASS: action records follow proposal, approval, sending and receipt with events; nothing is sent for a replaced attempt, a stopped task or an identical unconfirmed action; late receipts are marked; a restart or stop settles each action by how far it got; the user can check one off; leases hand out a rising generation; and the process ended at all \(steps * 2) commit boundaries")
    }
}
