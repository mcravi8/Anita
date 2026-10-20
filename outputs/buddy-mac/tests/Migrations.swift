// run-tests: BuddyWorkerCore.swift BuddyOperationsDB.swift BuddyMigrations.swift
import Foundation

/// The one-time changes to saved data, run on a fixture support folder shaped like the user's (never on the real one): a ZIP backup comes first,
/// stale stops are superseded or handed to the supervisor, the "keep going" routines an agent scheduled are paused with one notice, routines move
/// to the agent's model, a coding result that was overwritten comes back from its transcript, and Chief's "ask first" lines become one card for
/// the user. Running again changes nothing.
@main struct MigrationChecks {
    @MainActor static func require(_ value: Bool, _ message: String) { if !value { fputs("FAILED: \(message)\n", stderr); exit(1) } }

    static let w = "11111111-1111-4111-8111-111111111111"
    static let chief = "33333333-3333-4333-8333-333333333333", forge = "44444444-4444-4444-8444-444444444444"
    static let failedRun = "1FFBF7F0-0000-4000-8000-000000000001", laterRun = "B2D5DAC0-0000-4000-8000-000000000002", unsure = "AAAAAAAA-0000-4000-8000-000000000003"
    static let coding = "776ACB50-0000-4000-8000-000000000004", parked = "188530F4-0000-4000-8000-000000000005", userPaused = "CCCCCCCC-0000-4000-8000-000000000006"
    static let keepRun = "DDDDDDDD-0000-4000-8000-000000000007", session = "EEEEEEEE-0000-4000-8000-000000000008"
    static let series = "99999999-0000-4000-8000-000000000009", keepSeries = "99999999-0000-4000-8000-00000000000A"
    static let k1 = "A1000000-0000-4000-8000-000000000001", k2 = "A1000000-0000-4000-8000-000000000002", k3 = "A1000000-0000-4000-8000-000000000003"
    static let page = "A2000000-0000-4000-8000-000000000004", pinned = "A3000000-0000-4000-8000-000000000005"
    static let agentRun = "F0000000-0000-4000-8000-0000000000F0", decide = "Decide and keep the team's work moving without waiting for the CEO; record each decision and why. Model usage within the daily limit needs no approval; paying for, buying or subscribing to anything needs the CEO's OK first."
    static let receipts = "\n\n---\nCommand receipts:\n- python3 verify.py (exit 0)"
    static let description = "Lead the Omori team. If in doubt, ask. Always get my approval first before spending money. Report progress daily."

    static func task(_ id: String, status: String, kind: String = "general", agent: String = forge, created: String, updated: String, extra: [String: Any] = [:]) -> [String: Any] {
        var job: [String: Any] = ["id": id, "workspace": w, "agentId": agent, "requestId": "request-" + id, "title": "Task " + id.prefix(8), "goal": "Do the work.", "kind": kind, "provider": "claude", "budgetUSD": 0.5,
                                  "status": status, "progress": status == "completed" ? "Done" : "It stopped.", "createdAt": created, "updatedAt": updated, "attempt": 1, "events": [[String: Any]](), "result": "", "files": [[String: Any]](), "reviews": [[String: Any]]()]
        job.merge(extra) { $1 }
        return job
    }
    static func routine(_ id: String, request: String, hour: Int, model: String, budget: Double, agent: String = chief, goal: String = "Give each agent their next step via check_in and keep the team going.", extra: [String: Any] = [:]) -> [String: Any] {
        var r: [String: Any] = ["id": id, "workspace": w, "agentId": agent, "requestID": request, "provider": "claude", "model": model, "budgetUSD": budget, "title": "Keep going (\(hour):00)", "goal": goal,
                                "hour": hour, "minute": 0, "weekdays": [1, 2, 3, 4, 5, 6, 7], "timeZone": "America/Los_Angeles", "query": "", "kind": "general", "status": "active", "lastError": "", "nextRun": "2026-10-20T16:00:00Z"]
        r.merge(extra) { $1 }
        return r
    }
    static func json(_ value: Any, to url: URL) throws { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: url) }

    /// A support folder in the shape of the user's, built from scratch inside a .noindex folder.
    @MainActor static func fixture(_ support: URL) throws {
        let worker = support.appendingPathComponent("Worker")
        try FileManager.default.createDirectory(at: worker, withIntermediateDirectories: true)
        let db = try BuddyOperationsDB(directory: worker)
        try db.setMeta("migration", "{\"at\":\"2026-10-01T00:00:00Z\",\"live\":0}")
        let jobs: [[String: Any]] = [
            task(failedRun, status: "failed", created: "2026-10-18T06:00:00Z", updated: "2026-10-18T06:10:00Z", extra: ["routineID": "A4000000-0000-4000-8000-000000000001", "routineSeriesID": series, "reservedBudgetUSD": 0.5]),
            task(unsure, status: "failed", created: "2026-10-18T06:30:00Z", updated: "2026-10-18T06:40:00Z", extra: ["routineID": "A4000000-0000-4000-8000-000000000002", "routineSeriesID": series, "reviews": [["id": "rv1", "status": "uncertain", "kind": "browser", "tool": ["name": "Send the form"]]]]),
            task(laterRun, status: "completed", created: "2026-10-18T07:00:00Z", updated: "2026-10-18T07:10:00Z", extra: ["routineID": "A4000000-0000-4000-8000-000000000001", "routineSeriesID": series, "result": "All checked."]),
            task(coding, status: "failed", kind: "coding", created: "2026-10-19T07:59:00Z", updated: "2026-10-19T08:15:00Z", extra: ["attempt": 2, "codingSessionID": session, "result": receipts, "progress": "The coding session returned no final summary."]),
            task(parked, status: "paused", created: "2026-10-19T01:00:00Z", updated: "2026-10-19T02:00:00Z", extra: ["progress": "Paused after an hour of work."]),
            task(userPaused, status: "paused", created: "2026-10-19T03:00:00Z", updated: "2026-10-19T03:05:00Z", extra: ["stopCause": "user.pause", "progress": "Paused by you."]),
            task(keepRun, status: "completed", agent: chief, created: "2026-10-19T09:00:00Z", updated: "2026-10-19T09:02:00Z", extra: ["routineID": k1, "routineSeriesID": keepSeries]),
        ]
        try db.transaction {
            for job in jobs { try BuddyWorkerStore.insert(job, archived: false, in: db) }
            // Entries left by the old app: one for the run a later run superseded, one for the coding task.
            for (id, taskID) in [("stopped:\(failedRun):1:failed", failedRun), ("stopped:\(coding):2:failed", coding)] {
                try db.run("INSERT INTO decisions(id, workspace, agent_id, task_id, kind, title, question, label, payload, created_at) VALUES(?, ?, ?, ?, 'stopped', 'Stopped', 'It stopped.', 'Open task', '{}', '2026-10-18T08:00:00Z')", [.text(id), .text(w), .text(forge), .text(taskID)])
            }
            try db.run("INSERT INTO attempts(task_id, n, run_id, provider, model, started_at, ended_at, outcome, result) VALUES(?, 1, 'r1', 'claude', 'm', '2026-10-19T08:00:00Z', '2026-10-19T08:08:20Z', 'failed', NULL)", [.text(coding)])
            try db.run("INSERT INTO attempts(task_id, n, run_id, provider, model, started_at, ended_at, outcome, result) VALUES(?, 2, 'r2', 'claude', 'm', '2026-10-19T08:10:00Z', '2026-10-19T08:15:00Z', 'failed', NULL)", [.text(coding)])
            let routines: [[String: Any]] = [
                routine(k1, request: "\(agentRun):toolu_01AbC:hour:9", hour: 9, model: "claude-opus-4-1", budget: 0.5, extra: ["routineSeriesID": keepSeries]),
                routine(k2, request: "\(agentRun):toolu_01AbC:hour:10", hour: 10, model: "claude-opus-4-1", budget: 0.5, extra: ["routineSeriesID": keepSeries]),
                routine(k3, request: "\(agentRun):toolu_01AbC:hour:11", hour: 11, model: "claude-opus-4-1", budget: 0.5, extra: ["routineSeriesID": keepSeries]),
                routine(page, request: "A9000000-0000-4000-8000-000000000009", hour: 12, model: "claude-opus-4-1", budget: 0.5),
                routine(pinned, request: "A8000000-0000-4000-8000-000000000008", hour: 7, model: "claude-sonnet-4-5", budget: BuddyRunLimit.none, agent: forge, goal: "Summarise new papers on the topic."),
            ]
            for r in routines { try BuddyRoutineStore.insert(r, body: try BuddyOperationsDB.encode(r), id: r["id"] as? String ?? "", in: db) }
        }
        let transcript = worker.appendingPathComponent("Tasks/\(coding)/Claude/projects/-Users-fixture-project", isDirectory: true)
        try FileManager.default.createDirectory(at: transcript, withIntermediateDirectories: true)
        let lines = [
            #"{"type":"user","timestamp":"2026-10-19T08:00:01.000Z","message":{"role":"user","content":"Verify item 1"}}"#,
            #"{"type":"assistant","timestamp":"2026-10-19T08:02:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Starting the check."}]}}"#,
            "this line is not JSON",
            #"{"type":"assistant","timestamp":"2026-10-19T08:08:21.100Z","message":{"role":"assistant","content":[{"type":"text","text":"Final: item 1 verified"},{"type":"tool_use","id":"x","name":"y","input":{}}]}}"#,
            #"{"type":"assistant","timestamp":"2026-10-19T08:12:00.000Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"z","name":"Bash","input":{}}]}}"#,
            #"{"type":"assistant","timestamp":"2026-10-19T08:30:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Outside every attempt"}]}}"#,
        ]
        try lines.joined(separator: "\n").write(to: transcript.appendingPathComponent("\(session).jsonl"), atomically: true, encoding: .utf8)
        try json(["version": 1, "settings": [w: ["enabled": true, "supervisorId": chief, "revision": 1]], "checks": [], "updates": []], to: support.appendingPathComponent("team-monitor.json"))
        try json(["version": 1, "workspaces": [w: [chief: ["provider": "claude", "model": "claude-opus-5"], forge: ["provider": "claude", "model": "claude-sonnet-4-6"]]]], to: support.appendingPathComponent("agent-models.json"))
        try json(["version": 1, "conversationWorkspace": w, "agents": [
            ["id": chief, "name": "Chief", "role": "Chief of staff", "description": description, "profileSource": "setup", "profileRevision": 2],
            ["id": forge, "name": "Forge", "role": "Engineer", "description": "Write the code.", "profileRevision": 1]]], to: support.appendingPathComponent("workspace.json"))
        try json(["version": 1, "activatedAt": "2026-10-01T00:00:00Z", "records": [w + ":" + chief: ["workspace": w, "agentId": chief, "baseRevision": 2, "revision": 3, "enabled": true, "rules": [[String: Any]](),
            "suggestedInstructions": ["text": "Lead the Omori team and keep work moving. If in doubt, ask. Report progress daily.", "at": "2026-10-19T10:00:00Z", "baseRevision": 2]]]], to: support.appendingPathComponent("agent-memory.json"))
    }

    @MainActor static func snapshot(_ worker: URL) throws -> String {
        let db = try BuddyOperationsDB(directory: worker, existing: true)
        var out: [String] = []
        for sql in ["SELECT id, version, status, updated_at, body FROM tasks ORDER BY seq", "SELECT id, version, status, body FROM routines ORDER BY seq", "SELECT * FROM setting_changes ORDER BY seq",
                    "SELECT id, status, kind, audience, question FROM decisions ORDER BY id", "SELECT task_id, n, result FROM attempts ORDER BY task_id, n", "SELECT key, value FROM meta ORDER BY key", "SELECT COUNT(*) FROM events"] {
            out.append(try db.rows(sql).map { $0.map { "\($0.string ?? $0.int.map { String($0) } ?? "NULL")" }.joined(separator: "|") }.joined(separator: "\n"))
        }
        return out.joined(separator: "\n#\n")
    }
    @MainActor static func body(_ db: BuddyOperationsDB, _ table: String, _ id: String) throws -> [String: Any] {
        try BuddyOperationsDB.decode(try db.rows("SELECT body FROM \(table) WHERE id = ?", [.text(id)]).first?.first?.string ?? "{}")
    }

    @MainActor static func main() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("buddy-migrations-\(UUID().uuidString).noindex", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let support = base.appendingPathComponent("support", isDirectory: true), worker = support.appendingPathComponent("Worker")
        try fixture(support)
        let now = ISO8601DateFormatter().date(from: "2026-10-19T12:00:00Z")!

        let applied = try BuddyMigrations.run(support: support, now: now)
        require(applied == ["routine-models.v1", "legacy-stops.v1", "keepgoing-routines.v1", "attempt-results.v1", "supervisor-instructions-card.v1"], "every migration runs once, in order: \(applied)")
        let backups = (try? FileManager.default.contentsOfDirectory(atPath: worker.appendingPathComponent("Backups").path)) ?? []
        let zips = backups.filter { $0.hasPrefix("operations-before-migrations-") && $0.hasSuffix(".zip") }
        require(zips.count == 1 && !backups.contains { $0.hasSuffix(".noindex") }, "one ZIP backup was made first and its staging folder removed: \(backups)")
        let zip = worker.appendingPathComponent("Backups/" + zips[0])
        let listing = Process(), pipe = Pipe(); listing.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); listing.arguments = ["-Z1", zip.path]; listing.standardOutput = pipe
        try listing.run(); let listed = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); listing.waitUntilExit()
        let mode = (try FileManager.default.attributesOfItem(atPath: zip.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
        require(listing.terminationStatus == 0 && listed.trimmingCharacters(in: .whitespacesAndNewlines) == "operations.sqlite" && mode == 0o600, "the backup holds the database and only the user can read it: \(listed) \(String(mode, radix: 8))")
        require(!FileManager.default.fileExists(atPath: worker.appendingPathComponent("migration-error.txt").path), "nothing failed")

        let first = try snapshot(worker)
        require(try BuddyMigrations.run(support: support, now: now.addingTimeInterval(60)).isEmpty, "the second run has nothing to do")
        require(try snapshot(worker) == first, "the second run changes nothing")
        require(((try? FileManager.default.contentsOfDirectory(atPath: worker.appendingPathComponent("Backups").path)) ?? []).filter { $0.hasSuffix(".zip") }.count == 1, "and makes no second backup")

        let db = try BuddyOperationsDB(directory: worker, existing: true)
        // MIG-2a: the run a later run of the same work superseded.
        let superseded = try body(db, "tasks", failedRun)
        require(superseded["status"] as? String == "cancelled" && superseded["stopCause"] as? String == "superseded" && superseded["supersededBy"] as? String == laterRun && superseded["progress"] as? String == "Superseded: a later run of the same work finished.",
                "the stale failed run is superseded by the later run: \(superseded["status"] ?? "") \(superseded["supersededBy"] ?? "")")
        require(superseded["updatedAt"] as? String == "2026-10-18T06:10:00Z", "it keeps the time it stopped, so nothing it set aside counts as today's money")
        require(try body(db, "tasks", unsure)["status"] as? String == "failed" && (try body(db, "tasks", unsure))["legacy"] == nil, "a run that may have sent something is left for the person")
        // MIG-2b: what is left is the supervisor's, as old work.
        for id in [coding, parked] {
            let job = try body(db, "tasks", id)
            require(job["supervisorId"] as? String == chief && job["legacy"] as? Bool == true && job["stopCause"] as? String == "legacy", "an old stopped task goes to the supervisor as legacy work: \(id) \(job["supervisorId"] ?? "") \(job["stopCause"] ?? "")")
        }
        let paused = try body(db, "tasks", userPaused)
        require(paused["supervisorId"] == nil && paused["legacy"] == nil && paused["stopCause"] as? String == "user.pause", "a task the person paused stays theirs")
        require(try db.rows("SELECT COUNT(*) FROM events WHERE task_id = ? AND type = 'task.status'", [.text(failedRun)]).first?.first?.int == 1, "the change is in the task's history")
        // MIG-1 and MIG-3.
        for id in [k1, k2, k3] {
            let r = try body(db, "routines", id)
            require(r["status"] as? String == "paused" && r["lastError"] as? String == "Paused by the update: scheduled runs cannot start work; the team plan does that now.", "the keep-going routine an agent scheduled is paused: \(id)")
            require(r["model"] as? String == "claude-opus-5" && (r["budgetUSD"] as? Double) == BuddyRunLimit.none, "and moves to the agent's model with no run limit: \(r["model"] ?? "") \(r["budgetUSD"] ?? "")")
        }
        let pageRoutine = try body(db, "routines", page)
        require(pageRoutine["status"] as? String == "active" && pageRoutine["model"] as? String == "claude-opus-5", "the routine the person made on the page stays active (and moves to the agent's model)")
        require(try body(db, "routines", pinned)["model"] as? String == "claude-sonnet-4-6", "a routine pinned to an old model uses the agent's current one")
        require(try db.rows("SELECT status FROM routines WHERE id = ?", [.text(k1)]).first?.first?.string == "paused", "the routine's status column matches its body")
        // MIG-4.
        let attempts = try db.rows("SELECT n, result FROM attempts WHERE task_id = ? ORDER BY n", [.text(coding)])
        require(attempts.count == 2 && attempts[0][1].string == "Final: item 1 verified" && attempts[1][1].string == nil, "attempt 1's last words come back from the transcript; attempt 2 said nothing: \(attempts)")
        require(try body(db, "tasks", coding)["result"] as? String == "Final: item 1 verified" + receipts, "the empty result gets attempt 1's text back, with its receipts")
        // MIG-5.
        let changes = try db.rows("SELECT id, scope, agent_id, field, old_value, new_value, actor, source, status, risk, adopter FROM setting_changes")
        require(changes.count == 1, "one pending change: \(changes.count)")
        let change = changes[0]
        let expected = "Lead the Omori team and keep work moving. Report progress daily. " + decide
        require(change[1].string == "agent" && change[2].string == chief && change[3].string == "instructions" && change[6].string == "migration" && change[7].string == "migration:autonomy" && change[8].string == "pending" && change[9].string == "confirm" && change[10].string == "app",
                "a pending, confirm-risk change of Chief's instructions by the migration: \(change)")
        require(BuddyAgentChanges.decode(change[4].string ?? "") as? String == description && BuddyAgentChanges.decode(change[5].string ?? "") as? String == expected, "it replaces the ask-first lines, starting from the learned suggestion: \(change[5].string ?? "")")
        let changeID = change[0].string ?? ""

        let store = try BuddyWorkerStore(directory: worker)
        _ = try BuddyRoutineStore(directory: worker)
        let open = try store.openDecisions(workspace: w)
        require(!open.contains { $0["id"] as? String == "stopped:\(failedRun):1:failed" }, "the old entry for the superseded run is settled when the store starts")
        require(open.first { $0["id"] as? String == "stopped:\(coding):2:failed" }?["audience"] as? String == "supervisor", "the coding task's entry is now the supervisor's: \(open.map { "\($0["id"] ?? "") \($0["audience"] ?? "")" })")
        require(open.first { $0["taskId"] as? String == parked && $0["kind"] as? String == "paused" }?["audience"] as? String == "supervisor", "the long-paused task is the supervisor's")
        let confirm = open.filter { $0["kind"] as? String == "confirm" }
        require(confirm.count == 1 && confirm[0]["id"] as? String == "change:" + changeID && confirm[0]["title"] as? String == "Update Chief's instructions?" && confirm[0]["audience"] as? String == "user", "one card asks the person: \(confirm)")
        let question = confirm[0]["question"] as? String ?? ""
        require(question.contains("“If in doubt, ask”") && question.contains("“Always get my approval first before spending money”") && question.contains("added by the setup assistant, not by you") && question.hasSuffix("Replace them with 'decide and keep work moving; purchases still need your OK'?"), "the card says which lines and why: \(question)")
        let notice = open.filter { $0["kind"] as? String == "notice" }
        require(notice.count == 1 && (notice[0]["question"] as? String ?? "") == "I paused the hourly “keep going” runs Chief set up on Oct 19 (3 of them). They couldn't start any work — scheduled runs have no coding or delegation tools — and the team plan now keeps work moving. You can resume them in Background work.",
                "one notice says what was paused: \(notice.map { $0["question"] ?? "" })")
        print("PASS: the one-time migrations back up the database first, supersede a stale run, hand old stops to the supervisor, pause an agent's keep-going routines with one notice, move routines to the agent's model, recover an overwritten coding result and leave one card for Chief's instructions; running again changes nothing")

        // A migration that fails is written down and retried later; the others still run.
        let broken = base.appendingPathComponent("broken", isDirectory: true)
        try fixture(broken)
        try "not json".write(to: broken.appendingPathComponent("agent-models.json"), atomically: true, encoding: .utf8)
        let partial = try BuddyMigrations.run(support: broken, now: now)
        require(partial == ["legacy-stops.v1", "keepgoing-routines.v1", "attempt-results.v1", "supervisor-instructions-card.v1"], "the other migrations still run: \(partial)")
        let errors = (try? String(contentsOf: broken.appendingPathComponent("Worker/migration-error.txt"), encoding: .utf8)) ?? ""
        require(errors.contains("routine-models.v1"), "the failure is written to migration-error.txt: \(errors)")
        require(try BuddyOperationsDB(directory: broken.appendingPathComponent("Worker"), existing: true).meta("migration.routine-models.v1") == nil, "and is not recorded as done, so it runs again next time")
        // A new install has nothing to migrate and nothing is created.
        let fresh = base.appendingPathComponent("fresh", isDirectory: true)
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        require(try BuddyMigrations.run(support: fresh, now: now).isEmpty && !FileManager.default.fileExists(atPath: fresh.appendingPathComponent("Worker").path), "a new install has nothing to migrate")
        print("PASS: a failed migration is written to migration-error.txt and retried next start while the others run; a new install is left alone")
    }
}
