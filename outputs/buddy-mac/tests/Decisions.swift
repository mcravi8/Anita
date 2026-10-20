import Foundation

@main struct DecisionChecks {
    @MainActor static func require(_ value: Bool, _ message: String) { if !value { fputs("FAILED: \(message)\n", stderr); exit(1) } }
    static func run(_ path: String, _ environment: [String: String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path); process.standardOutput = Pipe(); process.standardError = Pipe()
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        try process.run(); process.waitUntilExit()
        return process.terminationStatus
    }
    static func review(_ id: String, kind: String? = "browser", tool: String = "Click Send", status: String = "pending") -> [String: Any] {
        var r: [String: Any] = ["id": id, "status": status, "tool": ["name": tool, "service": "Buddy private browser", "arguments": ["target": id]], "questions": [] as [[String: Any]]]
        if let kind { r["kind"] = kind }
        if kind == "authentication" { r["mode"] = "signin"; r["origin"] = "https://example.com" }
        return r
    }
    @MainActor static func start(_ store: BuddyWorkerStore, _ w: String, _ a: String, provider: String = "chatgpt", request: String = "t") throws -> String {
        let id = try store.create(workspace: w, agent: a, requestId: request, title: "Apply for the role", goal: "Do it", kind: "general", provider: provider, budget: provider == "claude" ? 0.5 : 0)["id"] as! String
        try store.update(id, ["status": "running", "attempt": 1, "executionRunID": "run-1"])
        return id
    }
    @MainActor static func propose(_ store: BuddyWorkerStore, _ task: String, _ review: [String: Any]) throws {
        var reviews = try store.job(task)["reviews"] as? [[String: Any]] ?? []; reviews.append(review)
        try store.update(task, ["reviews": reviews, "status": "waiting_review", "progress": "Needs your review"])
    }
    @MainActor static func answer(_ store: BuddyWorkerStore, _ task: String, _ id: String) throws {
        var reviews = try store.job(task)["reviews"] as? [[String: Any]] ?? []
        let i = reviews.firstIndex { $0["id"] as? String == id }!; reviews[i]["status"] = "answered"
        try store.update(task, ["reviews": reviews, "status": "running", "progress": "Running"])
    }
    @MainActor static func open(_ store: BuddyWorkerStore, _ w: String) throws -> [[String: Any]] { try store.openDecisions(workspace: w) }
    static func kinds(_ decisions: [[String: Any]]) -> [String] { decisions.map { $0["kind"] as? String ?? "" }.sorted() }

    static let steps = 7
    @MainActor static func script(_ store: BuddyWorkerStore, _ w: String, _ a: String, steps count: Int) throws {
        var id = ""
        let all: [() throws -> Void] = [
            { id = try store.create(workspace: w, agent: a, requestId: "t", title: "Apply for the role", goal: "Do it", kind: "general", provider: "chatgpt", budget: 0)["id"] as! String },
            { try store.update(id, ["status": "running", "attempt": 1, "executionRunID": "run-1"]) },
            { try propose(store, id, review("r1")) },
            { try answer(store, id, "r1") },
            { try store.update(id, ["status": "waiting_user", "progress": "Browser opened for you."]) },
            { try store.update(id, ["status": "failed", "progress": "The site did not answer."]) },
            { _ = try store.resume(id) },
        ]
        for step in 0..<min(count, all.count) { try all[step]() }
    }
    @MainActor static func summary(_ directory: URL, _ w: String) throws -> [String] {
        let store = try BuddyWorkerStore(directory: directory)
        guard let job = store.jobs.first else { return ["empty"] }
        return ["status:\(job["status"] as? String ?? "")", "open:\(kinds(try open(store, w)))"]
    }
    /// Whenever the process is ended, the open blockers are exactly what the task's saved state implies.
    @MainActor static func problems(_ directory: URL) throws -> [String] {
        let db = try BuddyOperationsDB(directory: directory, existing: true)
        var out: [String] = []
        for task in try db.rows("SELECT id, body FROM tasks") {
            guard let id = task[0].string, let body = try? BuddyOperationsDB.decode(task[1].string ?? "{}") else { continue }
            let wanted = Set(BuddyWorkerStore.desiredDecisions(body).map(\.id))
            let have = Set(try db.rows("SELECT id FROM decisions WHERE task_id = ? AND status = 'open'", [.text(id)]).compactMap { $0[0].string })
            if wanted != have { out.append("task is \(body["status"] as? String ?? "") and needs \(wanted.sorted()) but has \(have.sorted()) open") }
        }
        return out
    }

    @MainActor static func main() throws {
        let environment = ProcessInfo.processInfo.environment
        if environment["BUDDY_CRASH_CHILD"] == "decisions" {
            let directory = URL(fileURLWithPath: environment["BUDDY_CRASH_DIR"]!), phase = environment["BUDDY_CRASH_PHASE"] ?? "before", target = Int(environment["BUDDY_CRASH_AT"] ?? "") ?? 999
            let store = try BuddyWorkerStore(directory: directory)
            var count = 0
            BuddyOperationsDB.beforeCommit = { count += 1; if phase == "before" && count == target { _exit(137) } }
            BuddyOperationsDB.afterCommit = { if phase == "after" && count == target { _exit(137) } }
            try script(store, environment["BUDDY_CRASH_W"]!, environment["BUDDY_CRASH_A"]!, steps: steps)
            exit(0)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("buddy-decisions-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let w = UUID().uuidString, a = UUID().uuidString

        // 1. One blocker is one entry, however often the task is touched while it waits.
        let store = try BuddyWorkerStore(directory: root.appendingPathComponent("main/Worker"))
        let t1 = try start(store, w, a)
        require(try open(store, w).isEmpty, "work that is simply running needs nobody")
        try propose(store, t1, review("signin", kind: "authentication", tool: "Sign in"))
        var now = try open(store, w)
        require(kinds(now) == ["signin"] && now[0]["taskId"] as? String == t1 && (now[0]["payload"] as? [String: Any])?["reviewId"] as? String == "signin", "a sign-in request is one blocker, tied to its task and review")
        try store.update(t1, ["progress": "Still needs your choice"]); try store.update(t1, ["progress": "Still waiting"])
        now = try open(store, w)
        require(now.count == 1, "touching the task while it waits adds nothing")
        try answer(store, t1, "signin")
        require(try open(store, w).isEmpty, "answering it ends the blocker")
        let events = try store.history(of: t1).filter { $0.type.hasPrefix("decision.") }
        require(events.map(\.type) == ["decision.opened", "decision.resolved"] && events[1].payload["id"] as? String == "review:signin", "opening and ending a blocker are events")

        // 2. Each kind of blocker, and no second entry for the same cause.
        try propose(store, t1, review("op1", tool: "Fill the form"))
        let named = try open(store, w)
        require(kinds(named) == ["review"] && named[0]["title"] as? String == "Review: Fill the form", "an exact operation to approve is a blocker named for it")
        try propose(store, t1, review("op2", tool: "Submit"))
        require(kinds(try open(store, w)) == ["review", "review"], "two operations waiting are two blockers")
        try answer(store, t1, "op1"); try answer(store, t1, "op2")
        try store.update(t1, ["status": "waiting_user", "progress": "Browser opened for you. Resume when ready."])
        now = try open(store, w)
        require(kinds(now) == ["waiting"] && (now[0]["question"] as? String)?.contains("Resume when ready") == true, "a task waiting for the person is a blocker that says why")
        try store.update(t1, ["status": "queued"]); try store.update(t1, ["status": "running", "attempt": 2, "executionRunID": "run-2"])
        require(try open(store, w).isEmpty, "going back to work ends it")
        try store.update(t1, ["status": "waiting_user", "progress": "Needs you again."])
        now = try open(store, w)
        require(now.count == 1 && now[0]["id"] as? String == "waiting:\(t1):2", "the same state later, in a new attempt, is a new blocker")
        try store.update(t1, ["status": "failed", "progress": "The site did not answer."])
        require(kinds(try open(store, w)) == ["stopped"], "a failed task is one blocker that says why, and the waiting one has ended")
        _ = try store.resume(t1)
        require(try open(store, w).isEmpty, "resuming ends it")

        // 3. A task from when runs had an allowance is just a stopped task now.
        let paid = try start(store, w, a, provider: "claude", request: "paid")
        try store.update(paid, ["remainingBudgetUSD": 0, "reservedBudgetUSD": 0.5])
        try store.update(paid, ["status": "interrupted", "progress": "Stopped."])
        now = try open(store, w).filter { $0["taskId"] as? String == paid }
        require(kinds(now) == ["stopped"], "runs have no limit of their own, so a Claude task that stopped with nothing left is an ordinary stopped task and never asks for an allowance")
        _ = try store.resume(paid)
        require(try open(store, w).filter { $0["taskId"] as? String == paid }.isEmpty, "resuming it ends the blocker")

        // 4. A restart that leaves an action unconfirmed opens one blocker for it, and checking it off ends it.
        let crashDirectory = root.appendingPathComponent("restart/Worker")
        let crashed: String
        do {
            let before = try BuddyWorkerStore(directory: crashDirectory)
            crashed = try start(before, w, a)
            try propose(before, crashed, review("sent", tool: "Submit application")); try answer(before, crashed, "sent"); try before.markDispatched(task: crashed, review: "sent")
        }
        let after = try BuddyWorkerStore(directory: crashDirectory)
        now = try open(after, w)
        require(kinds(now) == ["stopped", "unconfirmed"] && now.contains { ($0["title"] as? String) == "Check whether “Submit application” went through" }, "a restart opens one blocker for the stopped task and one for the action that may have been sent: \(kinds(now))")
        try after.resolveAction(task: crashed, review: "sent", confirmed: true)
        require(kinds(try open(after, w)) == ["stopped"], "checking the action off ends only its blocker")
        let reopened = try BuddyWorkerStore(directory: crashDirectory)
        require(kinds(try open(reopened, w)) == ["stopped"], "starting again changes nothing")

        // 5. A task stopped by a daily limit is one blocker of its own, and ends when it is resumed.
        let limited = try BuddyWorkerStore(directory: root.appendingPathComponent("limit/Worker"))
        let held = try limited.create(workspace: w, agent: a, requestId: "held", title: "Held", goal: "Do it", kind: "general", provider: "claude", budget: 0.5)["id"] as! String
        try limited.refuseForLimit(held, limit: 0.4, scope: "agent", exposure: BuddyBudget.Exposure(spent: 0.3), wanted: 0.5)
        now = try open(limited, w)
        require(kinds(now) == ["limit"] && (now[0]["question"] as? String)?.contains("$0.40") == true, "a task stopped by a limit is one blocker that names the limit")
        _ = try limited.resume(held)
        require(try open(limited, w).isEmpty, "resuming it ends the blocker")

        // 6. Read and dismissed are separate, kept natively, and change nothing about the work.
        try store.setNotifications(workspace: w, ids: ["decision:a", "task:b:1"], read: true)
        try store.setNotifications(workspace: w, ids: ["decision:a"], dismissed: true)
        var state = try store.notificationState(workspace: w)
        require(state["decision:a"]?["read"] as? Bool == true && state["decision:a"]?["dismissed"] as? Bool == true && state["task:b:1"]?["read"] as? Bool == true && state["task:b:1"]?["dismissed"] as? Bool == false, "read and dismissed are separate")
        try store.setNotifications(workspace: w, ids: ["decision:a"], read: false)
        state = try store.notificationState(workspace: w)
        require(state["decision:a"]?["read"] as? Bool == false && state["decision:a"]?["dismissed"] as? Bool == true, "marking unread does not undo a dismissal")
        let statusBefore = try store.job(t1)["status"] as? String
        try store.setNotifications(workspace: w, ids: ["review:op1"], dismissed: true)
        let statusAfter = try store.job(t1)["status"] as? String, reviewsAfter = try store.job(t1)["reviews"] as! [[String: Any]]
        require(statusAfter == statusBefore && reviewsAfter.allSatisfy { $0["status"] as? String != "cancelled" }, "dismissing an alert does not approve, decline or resume anything")
        let again = try BuddyWorkerStore(directory: root.appendingPathComponent("main/Worker"))
        require((try again.notificationState(workspace: w))["decision:a"]?["dismissed"] as? Bool == true, "it is still dismissed after a restart")
        for bad in [[], [""], [String(repeating: "x", count: 301)]] as [[String]] { var refused = false; do { try store.setNotifications(workspace: w, ids: bad, read: true) } catch { refused = true }; require(refused, "bad ids are refused") }
        var foreign = false; do { try store.setNotifications(workspace: "not-a-workspace", ids: ["x"], read: true) } catch { foreign = true }
        require(foreign, "a made-up workspace is refused")
        let other = UUID().uuidString
        require((try store.notificationState(workspace: other)).isEmpty, "another workspace sees none of it")
        let raw = try BuddyOperationsDB(directory: root.appendingPathComponent("main/Worker"), existing: true)
        try raw.run("UPDATE notification_state SET updated_at = '2020-01-01T00:00:00Z' WHERE id = 'task:b:1'")
        try store.setNotifications(workspace: w, ids: ["decision:a"], read: true)
        require((try store.notificationState(workspace: w))["task:b:1"] == nil, "marks for alerts that are long gone are forgotten")

        // 7. Blockers that were already there when records began are found at start, and stale ones are ended.
        let legacyDirectory = root.appendingPathComponent("legacy/Worker")
        let waiting: String
        do {
            let seeded = try BuddyWorkerStore(directory: legacyDirectory)
            waiting = try start(seeded, w, a)
            try seeded.update(waiting, ["status": "waiting_user", "progress": "Needs you."])
            let rawLegacy = try BuddyOperationsDB(directory: legacyDirectory, existing: true)
            try rawLegacy.run("DELETE FROM decisions")
            try rawLegacy.run("INSERT INTO decisions(id, workspace, task_id, kind, created_at) VALUES('stale:1', ?, ?, 'stopped', '2026-01-01T00:00:00Z')", [.text(w), .text(waiting)])
        }
        let found = try BuddyWorkerStore(directory: legacyDirectory)
        now = try open(found, w)
        require(kinds(now) == ["waiting"] && now[0]["id"] as? String == "waiting:\(waiting):1", "a task that was already waiting gets its entry at start, and an entry whose cause has ended is closed")

        // 8. Ending the process at every commit keeps the open blockers equal to what the task's state implies.
        let binary = CommandLine.arguments[0]
        var reference: [Int: [String]] = [:]
        for count in 0...steps {
            let directory = root.appendingPathComponent("reference-\(count)")
            try script(try BuddyWorkerStore(directory: directory), w, a, steps: count)
            reference[count] = try summary(directory, w)
        }
        for commit in 1...steps {
            for phase in ["before", "after"] {
                let directory = root.appendingPathComponent("crash-\(phase)-\(commit)")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let status = try run(binary, ["BUDDY_CRASH_CHILD": "decisions", "BUDDY_CRASH_DIR": directory.path, "BUDDY_CRASH_AT": "\(commit)", "BUDDY_CRASH_PHASE": phase, "BUDDY_CRASH_W": w, "BUDDY_CRASH_A": a])
                require(status == 137, "the worker was ended \(phase) commit \(commit)")
                let raw = try problems(directory)
                require(raw.isEmpty, "straight after being ended \(phase) commit \(commit), the blockers match the task: \(raw)")
                let expected = reference[phase == "before" ? commit - 1 : commit]!, found = try summary(directory, w)
                require(found == expected, "after being ended \(phase) commit \(commit) the blockers are exactly as \(phase == "before" ? "before" : "after") that step\n found: \(found)\n wanted: \(expected)")
            }
        }
        print("PASS: one blocker per cause with a stable identity, each kind (sign-in, operation, waiting, stopped, allowance, unconfirmed action, limit), no duplicates, events for opening and ending, read and dismissed kept natively and separate, blockers found at start, and the process ended at all \(steps * 2) commit boundaries")

        // 9. Every stop is seen by someone, and each entry says who it is for: the person, or the supervisor when the task names one.
        let audienceDirectory = root.appendingPathComponent("audience/Worker")
        let routed = try BuddyWorkerStore(directory: audienceDirectory)
        func mine(_ task: String) throws -> [[String: Any]] { try open(routed, w).filter { $0["taskId"] as? String == task } }
        let narrowed = try start(routed, w, a, request: "narrowed")
        try routed.update(narrowed, ["status": "paused", "stopCause": "access.narrowed", "progress": "Paused: this agent's access was reduced while it worked."])
        var got = try mine(narrowed)
        require(kinds(got) == ["paused"] && got[0]["id"] as? String == "paused:\(narrowed):1:access.narrowed" && got[0]["audience"] as? String == "user" && (got[0]["question"] as? String)?.contains("access was reduced") == true, "a pause the system made is one entry that says why, for the person when no supervisor is named: \(got)")
        _ = try routed.resume(narrowed)
        require(try mine(narrowed).isEmpty && (try routed.job(narrowed))["stopCause"] as? String == "", "resuming ends it and clears the cause")
        let mute = try start(routed, w, a, request: "mute")
        try routed.update(mute, ["status": "paused", "stopCause": "user.pause"])
        require(try mine(mute).isEmpty, "a pause the person made needs nobody")
        for cause in ["user.pauseAll", "user.plan_stop", "routine.paused", "superseded"] { try routed.update(mute, ["stopCause": cause]); require(try mine(mute).isEmpty, "a pause by \(cause) needs nobody") }
        try routed.update(mute, ["stopCause": "", "progress": ""])
        got = try mine(mute)
        require(kinds(got) == ["paused"] && got[0]["id"] as? String == "paused:\(mute):1:unknown" && got[0]["question"] as? String == "This task stopped by itself.", "a pause with no recorded cause is never silent: \(got)")

        let retrying = try start(routed, w, a, request: "retrying")
        try routed.update(retrying, ["status": "failed", "progress": "The connection stalled.", "stopCause": "stall", "recovery": ["cause": "stall", "state": "pending", "tries": 1]])
        require(try mine(retrying).isEmpty, "a stop that is being retried by itself asks nobody")
        try routed.update(retrying, ["recovery": ["cause": "stall", "state": "queued", "tries": 1]])
        require(try mine(retrying).isEmpty, "nor while the retry is queued")
        try routed.update(retrying, ["recovery": ["cause": "stall", "state": "exhausted", "tries": 3]])
        got = try mine(retrying)
        require(kinds(got) == ["stopped"] && got[0]["audience"] as? String == "user", "once the retries are used up it is a stopped task again: \(got)")
        let chief = UUID().uuidString
        try routed.update(retrying, ["supervisorId": chief])
        got = try mine(retrying)
        require(got.count == 1 && got[0]["audience"] as? String == "supervisor" && got[0]["id"] as? String == "stopped:\(retrying):1:failed", "naming a supervisor moves the open entry to them, in place: \(got)")

        let supervised = try start(routed, w, a, request: "supervised")
        try routed.update(supervised, ["supervisorId": chief])
        try routed.update(supervised, ["status": "interrupted", "progress": "Stopped."])
        got = try mine(supervised)
        require(kinds(got) == ["stopped"] && got[0]["audience"] as? String == "supervisor", "a stop on a supervised task goes to the supervisor")
        try routed.update(supervised, ["status": "paused", "stopCause": "provider.disconnected", "progress": "Paused: Claude was disconnected."])
        got = try mine(supervised)
        require(kinds(got) == ["paused"] && got[0]["audience"] as? String == "supervisor", "and so does a pause the system made")

        let asking = try start(routed, w, a, request: "asking")
        var checkpoint: [String: Any] = ["id": "c1", "question": "Which draft should go first?", "options": [String](), "recommendation": "The shorter one", "context": "", "routedTo": "supervisor", "at": "2026-10-19T12:00:00Z"]
        try routed.update(asking, ["status": "waiting_user", "progress": "Which draft should go first?", "stopCause": "checkpoint.supervisor", "checkpoint": checkpoint])
        got = try mine(asking)
        require(kinds(got) == ["waiting"] && got[0]["audience"] as? String == "supervisor", "a question for the supervisor waits for the supervisor: \(got)")
        checkpoint["routedTo"] = "user"
        try routed.update(asking, ["checkpoint": checkpoint, "stopCause": "checkpoint.user"])
        got = try mine(asking)
        require(got.count == 1 && got[0]["audience"] as? String == "user", "one the person must answer waits for the person")

        let parked = try start(routed, w, a, request: "parked")
        try routed.update(parked, ["status": "waiting_user", "stopCause": "review.parked", "progress": "Set aside so other work could run."])
        got = try mine(parked)
        require(kinds(got) == ["waiting"] && got[0]["audience"] as? String == "user" && got[0]["question"] as? String == "Buddy set this aside so other work could run. Resume it when you can review the step it was waiting for.", "a review set aside so others could run is the person's, and says so: \(got)")

        let delivered = try start(routed, w, a, request: "delivered")
        try routed.update(delivered, ["reportsTo": chief, "status": "completed", "result": "Drafted both letters."])
        got = try mine(delivered)
        require(kinds(got) == ["result"] && got[0]["id"] as? String == "result:\(delivered):1" && got[0]["audience"] as? String == "supervisor" && got[0]["title"] as? String == "Result to review: Apply for the role", "a finished result the supervisor has to review is an entry for the supervisor: \(got)")
        try routed.update(delivered, ["acceptedAt": "2026-10-19T12:00:00Z"])
        require(try mine(delivered).isEmpty, "accepting the result ends it")
        let finished = try start(routed, w, a, request: "finished")
        try routed.update(finished, ["status": "completed", "result": "Done."])
        require(try mine(finished).isEmpty, "a finished task with no one to report to needs nobody")
        require(try open(routed, w).allSatisfy { ["user", "supervisor"].contains($0["audience"] as? String ?? "") }, "every entry says who it is for")

        // An entry saved with the wrong audience (an older build) is put right at start.
        let rawRouted = try BuddyOperationsDB(directory: audienceDirectory, existing: true)
        try rawRouted.run("UPDATE decisions SET audience = 'user' WHERE task_id = ? AND status = 'open'", [.text(supervised)])
        let reopenedRouted = try BuddyWorkerStore(directory: audienceDirectory)
        require(try reopenedRouted.openDecisions(workspace: w).filter { $0["taskId"] as? String == supervised }.map { $0["audience"] as? String ?? "" } == ["supervisor"], "an entry saved with the wrong audience is put right at start")

        // Notices can be for the supervisor, and an entry can be resolved by someone, which is recorded.
        try reopenedRouted.openDecision(workspace: w, id: "notice:handoff", agent: a, kind: "notice", title: "Handed over", question: "Forge now owns the pipeline.", label: "Open", payload: [:], audience: "supervisor") // new-api
        require(try reopenedRouted.openDecisions(workspace: w).first { $0["id"] as? String == "notice:handoff" }?["audience"] as? String == "supervisor", "a notice can be for the supervisor") // new-api
        try reopenedRouted.resolveDecision(id: "notice:handoff", by: chief, resolution: "answered") // new-api
        let resolvedRow = try rawRouted.rows("SELECT status, resolution, resolved_by FROM decisions WHERE id = 'notice:handoff'").first
        require(resolvedRow?[0].string == "resolved" && resolvedRow?[1].string == "answered" && resolvedRow?[2].string == chief, "resolving records who did it and how") // new-api
        let stoppedID = "stopped:\(retrying):1:failed"
        try reopenedRouted.resolveDecision(id: stoppedID, by: chief, resolution: "dismissed") // new-api
        try reopenedRouted.update(retrying, ["progress": "Still stopped."])
        require(try reopenedRouted.openDecisions(workspace: w).filter { $0["taskId"] as? String == retrying }.isEmpty, "a resolved entry stays resolved until the task's state changes") // new-api
        require(try reopenedRouted.history(of: retrying).contains { $0.type == "decision.resolved" && $0.payload["id"] as? String == stoppedID && $0.payload["by"] as? String == chief }, "and resolving it is in the task's history") // new-api
        print("PASS: system pauses and exhausted retries are never silent, retries in progress ask nobody, the person's own pauses ask nobody, each entry has its audience (supervisor when named, re-derived in place and at start), parked reviews and results have their own entries, and resolutions record who") // new-api
    }
}
