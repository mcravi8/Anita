import Foundation
import CryptoKit

@main struct OperationsChecks {
    @MainActor static func require(_ value: Bool, _ message: String) { if !value { fputs("FAILED: \(message)\n", stderr); exit(1) } }
    static let iso = ISO8601DateFormatter()

    static func task(_ i: Int, _ w: String, _ a: String, status: String = "completed", request: String? = nil) -> [String: Any] {
        ["id": UUID().uuidString, "workspace": w, "agentId": a, "requestId": request ?? "seed-\(i)", "title": "Task \(i)", "goal": "Do thing \(i)", "kind": "general", "provider": "chatgpt", "budgetUSD": 0, "status": status,
         "createdAt": String(format: "2026-01-01T00:%02d:%02dZ", (i / 60) % 60, i % 60), "updatedAt": "2026-01-02T00:00:00Z", "result": "Result \(i)", "reviews": [] as [[String: Any]], "attempt": 1]
    }
    static func routine(_ w: String, _ a: String, title: String = "Check mail") -> [String: Any] {
        ["id": UUID().uuidString, "workspace": w, "agentId": a, "status": "active", "title": title, "goal": "Look at the mail", "kind": "email", "provider": "claude", "budgetUSD": 0.5, "query": "newer_than:7d",
         "hour": 9, "minute": 0, "weekdays": [2, 3, 4, 5, 6], "timeZone": "America/Los_Angeles", "nextRun": "2026-10-19T16:00:00Z", "revision": 3]
    }
    static func write(_ value: [String: Any], _ name: String, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: value).write(to: directory.appendingPathComponent(name))
    }
    static func names(_ directory: URL) -> Set<String> { Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []) }
    static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func run(_ path: String, _ arguments: [String], environment: [String: String] = [:]) throws -> (status: Int32, output: Data) {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments; process.standardOutput = pipe; process.standardError = Pipe()
        if !environment.isEmpty { process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 } }
        try process.run(); let output = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        return (process.terminationStatus, output)
    }

    // The scripted history used by the crash checks. Every step is exactly one commit.
    static let authorization = "7E5D3B5A-2B6C-4B65-9C5B-0D0B6C2C1A11"
    @MainActor static func script(_ store: BuddyWorkerStore, _ w: String, _ a: String, steps: Int, rest: (Int) -> Void = { _ in }) throws {
        var id = "", other = ""
        let all: [() throws -> Void] = [
            { id = try store.create(workspace: w, agent: a, requestId: "first", title: "First", goal: "Do it", kind: "general", provider: "claude", budget: 0.5)["id"] as! String },
            { try store.update(id, ["status": "running", "attempt": 1, "executionRunID": "run-1", "remainingBudgetUSD": 0, "reservedBudgetUSD": 0.5]) },
            { try store.update(id, ["progress": "Halfway there"]) },
            { other = try store.create(workspace: w, agent: a, requestId: "second", title: "Second", goal: "Do more", kind: "general", provider: "chatgpt", budget: 0)["id"] as! String },
            { try store.update(other, ["status": "completed", "result": "Done"]) },
            { try store.setPaused(true) },
            { _ = try store.archiveFinished(keeping: 1) },
            { try store.update(id, ["status": "paused"]) },
            { _ = try store.resume(id, additionalBudgetUSD: 0.3, authorizationID: authorization) },
            { try store.update(id, ["status": "running", "attempt": 2, "executionRunID": "run-2"]) },
            { try store.update(id, ["status": "completed", "result": "All finished"]) },
        ]
        for step in 0..<min(steps, all.count) { try all[step](); rest(step + 1) }
    }
    static let scriptSteps = 11
    /// What a restarted worker shows: the same text whichever process wrote it.
    static func authorizationCount(_ value: Any?) -> Int { (value as? [[String: Any]])?.count ?? 0 }
    /// What must hold whenever the process is ended: each task's history has no gaps, its last status entry is the task's status, and an
    /// attempt is open exactly while the task is running. Reads the raw tables, so it sees the state before any restart tidies it.
    static func historyProblems(_ directory: URL) throws -> [String] {
        let db = try BuddyOperationsDB(directory: directory, existing: true)
        var problems: [String] = []
        for row in try db.rows("SELECT id, status FROM tasks") {
            guard let id = row[0].string, let status = row[1].string else { continue }
            let events = try db.rows("SELECT seq, type, payload FROM events WHERE task_id = ? ORDER BY seq", [.text(id)])
            let seqs = events.compactMap { $0[0].int }
            if let first = seqs.first, seqs != Array(first..<(first + Int64(seqs.count))) { problems.append("history skips a number: \(seqs)") }
            var known: String?
            for event in events {
                let payload = (try? BuddyOperationsDB.decode(event[2].string ?? "{}")) ?? [:]
                switch event[1].string ?? "" {
                case "task.created", "task.imported": known = payload["status"] as? String
                case "task.status": known = payload["to"] as? String
                default: break
                }
            }
            if let known, known != status { problems.append("history says \(known) but the task is \(status)") }
            let tries = try db.rows("SELECT COUNT(*) FROM attempts WHERE task_id = ?", [.text(id)]).first?.first?.int ?? 0
            let open = try db.rows("SELECT COUNT(*) FROM attempts WHERE task_id = ? AND outcome IS NULL", [.text(id)]).first?.first?.int ?? 0
            let running: Int64 = ["running", "waiting_review", "stopping"].contains(status) ? 1 : 0
            if tries > 0 && open != running { problems.append("\(open) attempts open while the task is \(status)") }
        }
        return problems
    }
    @MainActor static func summary(_ directory: URL) throws -> [String] {
        let store = try BuddyWorkerStore(directory: directory)
        var live: [String] = []
        for job in store.jobs {
            let tries = try store.attempts(of: job["id"] as? String ?? "").map { "\($0.number)=\($0.outcome ?? "open")" }.joined(separator: ",")
            let types = try store.history(of: job["id"] as? String ?? "").map(\.type).joined(separator: ",")
            live.append("\(job["requestId"] as? String ?? "")|\(job["status"] as? String ?? "")|\(job["progress"] as? String ?? "")|\(job["result"] as? String ?? "")|\(job["remainingBudgetUSD"] ?? "-")|\((authorizationCount(job["budgetAuthorizations"])))|attempts:\(tries)|history:\(types)")
        }
        let archived = try store.archivedJobs().map { "archived:\($0["requestId"] as? String ?? "")" }
        return live + archived + ["paused:\(store.paused)", "events:\(store.eventCount)"]
    }

    @MainActor static func main() throws {
        let environment = ProcessInfo.processInfo.environment
        if let mode = environment["BUDDY_CRASH_CHILD"] { try child(mode, environment); return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("buddy-operations-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let w = UUID().uuidString, a = UUID().uuidString

        // 1. A fresh start: a private database, journaled, with nothing in it and nothing to migrate.
        let fresh = root.appendingPathComponent("fresh")
        let first = try BuddyWorkerStore(directory: fresh)
        require(first.jobs.isEmpty && !first.paused, "a fresh worker starts empty")
        let databaseFile = fresh.appendingPathComponent("operations.sqlite")
        let mode = (try FileManager.default.attributesOfItem(atPath: databaseFile.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
        require(mode == 0o600, "the database is private to the user")
        let probe = try BuddyOperationsDB(directory: fresh, existing: true)
        require(try probe.rows("PRAGMA journal_mode").first?.first?.string == "wal", "changes are journaled so a crash cannot leave half of one")
        require(try probe.rows("PRAGMA user_version").first?.first?.int == 6, "the schema carries a version")
        require(!names(fresh).contains { $0.hasSuffix(".migrated") } && !names(fresh).contains("Backups"), "nothing is backed up or renamed when there was nothing to migrate")

        // 2. A full old history: live tasks, two archive files, routines and a paused queue.
        let old = root.appendingPathComponent("old")
        let live = (0..<5).map { task($0, w, a, status: $0 == 4 ? "paused" : "completed") }
        let archiveOne = (10..<13).map { task($0, w, a) }, archiveTwo = (20..<22).map { task($0, w, a) }
        let routines = [routine(w, a), routine(w, a, title: "Check calendar")]
        try write(["version": 1, "paused": true, "tasks": live], "tasks.json", in: old)
        try write(["version": 1, "archivedAt": "2026-02-01T00-00-00Z", "tasks": archiveOne], "tasks-archive-2026-02-01T00-00-00Z-aaaaaaaa.json", in: old)
        try write(["version": 1, "archivedAt": "2026-03-01T00-00-00Z", "tasks": archiveTwo + [archiveOne[0], live[0]]], "tasks-archive-2026-03-01T00-00-00Z-bbbbbbbb.json", in: old)
        try write(["version": 1, "routines": routines], "routines.json", in: old)
        let originals = try ["tasks.json", "routines.json", "tasks-archive-2026-02-01T00-00-00Z-aaaaaaaa.json", "tasks-archive-2026-03-01T00-00-00Z-bbbbbbbb.json"].map { ($0, try Data(contentsOf: old.appendingPathComponent($0))) }
        let rules = try BuddyRoutineStore(directory: old), queue = try BuddyWorkerStore(directory: old)
        require(queue.jobs.map { $0["id"] as? String } == live.map { $0["id"] as? String }, "every live task keeps its ID and its order")
        require(queue.paused, "a paused queue stays paused")
        require(Set(try queue.archivedJobs().compactMap { $0["id"] as? String }) == Set((archiveOne + archiveTwo).compactMap { $0["id"] as? String }), "archived tasks are all kept, and an ID that is also live or also in an earlier archive is not doubled")
        require(rules.routines.map { $0["id"] as? String } == routines.map { $0["id"] as? String } && rules.routines.map { $0["nextRun"] as? String } == routines.map { $0["nextRun"] as? String }, "routines keep their IDs and their next run times")
        require(rules.routines[0]["revision"] as? Int == 3, "fields the store does not use are carried over untouched")
        require(NSDictionary(dictionary: queue.jobs[0]).isEqual(to: live[0]), "a migrated task is the very same record")
        let after = names(old)
        require(after.contains("tasks.json.migrated") && after.contains("routines.json.migrated") && !after.contains("tasks.json") && !after.contains("routines.json") && after.filter { $0.hasPrefix("tasks-archive-") && $0.hasSuffix(".migrated") }.count == 2, "the old files are set aside, not deleted")
        let backups = try FileManager.default.contentsOfDirectory(atPath: old.appendingPathComponent("Backups").path).filter { $0.hasSuffix(".zip") }
        require(backups.count == 1, "one backup ZIP was made")
        let backup = old.appendingPathComponent("Backups/" + backups[0])
        let zipMode = (try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
        let zipTest = try run("/usr/bin/unzip", ["-tq", backup.path]).status
        require(zipMode == 0o600 && zipTest == 0, "the backup is private and passes the ZIP integrity test")
        for (name, data) in originals { require(try run("/usr/bin/unzip", ["-p", backup.path, name]).output == data, "the backup holds \(name) byte for byte") }
        let record = try BuddyOperationsDB.decode(try BuddyOperationsDB(directory: old, existing: true).meta("migration")!)
        require(record["live"] as? Int == 5 && record["archived"] as? Int == 5 && record["routines"] as? Int == 2 && record["skippedDuplicates"] as? Int == 2, "the import records what it counted")
        require((record["sources"] as? [[String: Any]])?.first { $0["name"] as? String == "tasks.json" }?["sha256"] as? String == sha(originals[0].1), "the import records a fingerprint of each old file")
        let snapshot = try BuddyOperationsDB.snapshot(directory: old)
        require(snapshot?.tasks.count == 5 && snapshot?.routines.count == 2, "other readers see the same live tasks and routines")
        // Starting again changes nothing, and a stray file with the old name is neither imported nor touched.
        try write(["version": 1, "paused": false, "tasks": [task(99, w, a)]], "tasks.json", in: old)
        let again = try BuddyWorkerStore(directory: old)
        require(again.jobs.count == 5 && again.paused && FileManager.default.fileExists(atPath: old.appendingPathComponent("tasks.json").path), "a second start does not import again, and a different file with the old name is left alone")

        // 3. Anything that cannot be verified stops the start and leaves every old file exactly as it was.
        func refuse(_ label: String, _ build: (URL) throws -> Void) throws {
            let directory = root.appendingPathComponent("bad-" + label)
            try build(directory)
            let before = try names(directory).map { ($0, try Data(contentsOf: directory.appendingPathComponent($0))) }.sorted { $0.0 < $1.0 }
            var stopped = false; do { _ = try BuddyWorkerStore(directory: directory); _ = try BuddyRoutineStore(directory: directory) } catch { stopped = true }
            let afterFiles = try names(directory).filter { !$0.hasPrefix("operations.sqlite") && $0 != "Backups" }.map { ($0, try Data(contentsOf: directory.appendingPathComponent($0))) }.sorted { $0.0 < $1.0 }
            require(stopped, "\(label) stops the start")
            var same = afterFiles.count == before.count
            for (x, y) in zip(before, afterFiles) where x.0 != y.0 || x.1 != y.1 { same = false }
            require(same, "\(label) leaves the old files exactly as they were")
            require(try BuddyOperationsDB.snapshot(directory: directory) == nil, "\(label) imports nothing")
        }
        let shared = task(1, w, a)
        try refuse("duplicate-ids") { try write(["version": 1, "tasks": [shared, shared]], "tasks.json", in: $0) }
        try refuse("bad-uuid") { try write(["version": 1, "tasks": [["id": "not-a-uuid", "workspace": w]]], "tasks.json", in: $0) }
        try refuse("same-request") { try write(["version": 1, "tasks": [task(1, w, a, request: "r"), task(2, w, a, request: "r")]], "tasks.json", in: $0) }
        try refuse("wrong-version") { try write(["version": 2, "tasks": []], "tasks.json", in: $0) }
        try refuse("bad-archive") { try write(["version": 1, "tasks": [task(1, w, a)]], "tasks.json", in: $0); try Data("{".utf8).write(to: $0.appendingPathComponent("tasks-archive-x.json")) }
        try refuse("bad-routine") { var bad = routine(w, a); bad["hour"] = 40; try write(["version": 1, "routines": [bad]], "routines.json", in: $0) }
        try refuse("bad-routine-time") { var bad = routine(w, a); bad["nextRun"] = "tomorrow"; try write(["version": 1, "routines": [bad]], "routines.json", in: $0) }
        // Once the file is repaired the same directory starts normally.
        let repaired = root.appendingPathComponent("bad-wrong-version")
        try write(["version": 1, "tasks": [task(1, w, a)]], "tasks.json", in: repaired)
        require(try BuddyWorkerStore(directory: repaired).jobs.count == 1, "a repaired file is then imported")

        // 4. The database itself: one request makes one task, versions count, and a task that grows too large is refused without losing it.
        let rules2 = root.appendingPathComponent("rules")
        let direct = try BuddyWorkerStore(directory: rules2)
        let made = try direct.create(workspace: w, agent: a, requestId: "same", title: "One", goal: "Do it", kind: "general", provider: "chatgpt", budget: 0)
        require(try direct.create(workspace: w, agent: a, requestId: "same", title: "Two", goal: "Do it", kind: "general", provider: "chatgpt", budget: 0)["id"] as? String == made["id"] as? String, "a repeated request returns the same task")
        let db = try BuddyOperationsDB(directory: rules2, existing: true)
        var blocked = false; do { try db.run("INSERT INTO tasks(id, workspace, agent_id, request_id, body) VALUES(?, ?, ?, ?, '{}')", [.text(UUID().uuidString), .text(w), .text(a), .text("same")]) } catch { blocked = true }
        require(blocked, "the database itself refuses a second live task for one request")
        let id = made["id"] as! String
        try direct.update(id, ["progress": "a"]); try direct.update(id, ["progress": "b"])
        require(try db.rows("SELECT version FROM tasks WHERE id = ?", [.text(id)]).first?.first?.int == 3, "each change bumps the row's version")
        var refused = false; do { try direct.update(id, ["progress": String(repeating: "x", count: BuddyWorkerStore.rowLimit + 1)]) } catch { refused = true }
        let inMemory = try direct.job(id)["progress"] as? String, onDisk = try BuddyWorkerStore(directory: rules2).job(id)["progress"] as? String
        require(refused && inMemory == "b" && onDisk == "b", "an oversized change is refused and the saved task is untouched")
        var invalid = false; do { try direct.update(id, ["progress": Double.nan]) } catch { invalid = true }
        let afterNaN = try direct.job(id)["progress"] as? String
        require(invalid && afterNaN == "b", "a value that cannot be saved is refused instead of crashing")
        try direct.update(id, ["status": "completed"])
        _ = try direct.archiveFinished(keeping: 0)
        let reused = try direct.create(workspace: w, agent: a, requestId: "same", title: "Three", goal: "Do it", kind: "general", provider: "chatgpt", budget: 0)
        let keptAside = try direct.archivedJobs().count
        require(reused["id"] as? String != id && direct.jobs.count == 1 && keptAside == 1, "an archived task no longer holds its request ID, as before, and is still kept")
        // A task that was just stopped has no allowance left, and the store says so at once, without waiting for a restart.
        let metered = try direct.create(workspace: w, agent: a, requestId: "metered", title: "Metered", goal: "Do it", kind: "coding", provider: "claude", budget: 0.5), meteredID = metered["id"] as! String
        try direct.update(meteredID, ["status": "paused", "remainingBudgetUSD": 0, "reservedBudgetUSD": 0.5])
        require(try direct.job(meteredID)["remainingBudgetUSD"] as? Double == 0, "a whole-number zero allowance reads back as zero")
        var needsMore = false; do { _ = try direct.resume(meteredID) } catch { needsMore = true }
        require(needsMore, "a stopped Claude task cannot restart on its old budget without a new allowance")
        let funded = try direct.resume(meteredID, additionalBudgetUSD: 0.4, authorizationID: UUID().uuidString)
        require(funded["status"] as? String == "queued" && funded["remainingBudgetUSD"] as? Double == 0.4 && funded["uncertainBudgetUSD"] as? Double == 0.5, "a chosen allowance restarts it, and the earlier unconfirmed spend stays on record")
        // A database from a newer Buddy is refused rather than misread.
        let newer = root.appendingPathComponent("newer"); _ = try BuddyWorkerStore(directory: newer)
        try BuddyOperationsDB(directory: newer, existing: true).run("PRAGMA user_version = 9")
        var tooNew = false; do { _ = try BuddyWorkerStore(directory: newer) } catch { tooNew = true }
        require(tooNew, "a database written by a newer Buddy is refused")

        // 5. Killing the process at every commit boundary keeps every change whole or leaves it out.
        let binary = CommandLine.arguments[0]
        var reference: [Int: [String]] = [:]
        for steps in 0...scriptSteps {
            let directory = root.appendingPathComponent("reference-\(steps)")
            try script(try BuddyWorkerStore(directory: directory), w, a, steps: steps)
            reference[steps] = try summary(directory)
        }
        for commit in 1...scriptSteps {
            for phase in ["before", "after"] {
                let directory = root.appendingPathComponent("crash-\(phase)-\(commit)")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let outcome = try run(binary, [], environment: ["BUDDY_CRASH_CHILD": "script", "BUDDY_CRASH_DIR": directory.path, "BUDDY_CRASH_AT": "\(commit)", "BUDDY_CRASH_PHASE": phase, "BUDDY_CRASH_W": w, "BUDDY_CRASH_A": a])
                require(outcome.status == 137, "the worker was ended \(phase) commit \(commit)")
                let expected = reference[phase == "before" ? commit - 1 : commit]!
                let rawProblems = try historyProblems(directory)
                require(rawProblems.isEmpty, "straight after being ended \(phase) commit \(commit), history and state agree: \(rawProblems)")
                let found = try summary(directory)
                require(found == expected, "after being ended \(phase) commit \(commit), the saved tasks are exactly the state \(phase == "before" ? "before" : "after") that change\n found: \(found)\n wanted: \(expected)")
                let integrity = try BuddyOperationsDB(directory: directory, existing: true).rows("PRAGMA integrity_check").first?.first?.string
                require(integrity == "ok", "the database passes its integrity check after being ended \(phase) commit \(commit)")
                let tidiedProblems = try historyProblems(directory)
                require(tidiedProblems.isEmpty, "after the restart tidies up, history and state still agree: \(tidiedProblems)")
            }
        }
        let finished = root.appendingPathComponent("crash-complete"); try FileManager.default.createDirectory(at: finished, withIntermediateDirectories: true)
        let complete = try run(binary, [], environment: ["BUDDY_CRASH_CHILD": "script", "BUDDY_CRASH_DIR": finished.path, "BUDDY_CRASH_AT": "999", "BUDDY_CRASH_PHASE": "before", "BUDDY_CRASH_W": w, "BUDDY_CRASH_A": a])
        let completeSummary = try summary(finished)
        require(complete.status == 0 && completeSummary == reference[scriptSteps]!, "a worker that is not ended ends in the same state as the reference")

        // 6. Killing the process during the one-time import: before it commits nothing changes, after it commits nothing is lost.
        for phase in ["before", "after"] {
            let directory = root.appendingPathComponent("migrate-\(phase)")
            try write(["version": 1, "paused": true, "tasks": live], "tasks.json", in: directory)
            try write(["version": 1, "routines": routines], "routines.json", in: directory)
            let outcome = try run(binary, [], environment: ["BUDDY_CRASH_CHILD": "migrate", "BUDDY_CRASH_DIR": directory.path, "BUDDY_CRASH_PHASE": phase])
            require(outcome.status == 137, "the worker was ended during the import (\(phase))")
            if phase == "before" {
                require(names(directory).contains("tasks.json") && !names(directory).contains("tasks.json.migrated"), "ended before the import committed, the old files are exactly where they were")
                require(try BuddyOperationsDB.snapshot(directory: directory) == nil, "ended before the import committed, the database has no half-import")
            } else {
                require(names(directory).contains("tasks.json"), "ended after the import committed, the old file has not been renamed yet")
                require(try BuddyOperationsDB.snapshot(directory: directory)?.tasks.count == 5, "ended after the import committed, the import is whole")
            }
            let restarted = try BuddyWorkerStore(directory: directory), rules = try BuddyRoutineStore(directory: directory)
            require(restarted.jobs.map { $0["id"] as? String } == live.map { $0["id"] as? String } && restarted.paused && rules.routines.count == 2, "the next start has every task, the paused flag and every routine, once (\(phase))")
            require(names(directory).contains("tasks.json.migrated") && !names(directory).contains("tasks.json"), "the next start finishes setting the old files aside (\(phase))")
            require(try BuddyOperationsDB(directory: directory, existing: true).rows("SELECT COUNT(*) FROM tasks").first?.first?.int == 5, "no task was imported twice (\(phase))")
        }
        // 7. History: every change leaves the right entries behind, in order, and attempts open and close with the work.
        let story = root.appendingPathComponent("story")
        let tale = try BuddyWorkerStore(directory: story)
        try script(tale, w, a, steps: scriptSteps)
        let firstTask = tale.jobs[0], firstID = firstTask["id"] as! String
        let aside = try tale.archivedJobs()[0]["id"] as! String
        let firstHistory = try tale.history(of: firstID)
        require(firstHistory.map(\.type) == ["task.created", "task.status", "attempt.started", "attempt.ended", "task.status", "decision.opened", "task.status", "decision.resolved", "task.status", "attempt.started", "attempt.ended", "task.status"], "a task's history lists what happened in order, including the blocker that opened when it needed an allowance and ended when it got one: \(firstHistory.map(\.type))")
        require(firstHistory.map(\.seq) == Array(1...12), "a task's entries are numbered one after another without a gap")
        require(firstHistory[0].cause == "request" && firstHistory[0].correlation == "first", "an entry says what caused it and which request it belongs to")
        require(firstHistory[6].cause == "resume" && (firstHistory[6].payload["from"] as? String) == "paused" && (firstHistory[6].payload["to"] as? String) == "queued", "resuming is recorded as a move from paused to queued")
        require(firstHistory.map(\.id) == firstHistory.map(\.id).sorted(), "entries are ordered across the whole log as well")
        require(try tale.history(of: aside).map(\.type) == ["task.created", "task.status", "task.archived"], "a task that is archived says so in its history")
        require(try tale.history(of: firstID, after: 10).map(\.seq) == [11, 12], "history can be read from just after a point")
        let tries = try tale.attempts(of: firstID)
        require(tries.map(\.number) == [1, 2] && tries.map(\.outcome) == ["paused", "completed"] && tries.map(\.runID) == ["run-1", "run-2"] && tries.allSatisfy { $0.provider == "claude" && $0.endedAt != nil }, "attempts record their run, provider and how each ended")
        let storyProblems = try historyProblems(story)
        require(storyProblems.isEmpty, "history and state agree: \(storyProblems)")
        let countBefore = tale.eventCount
        for _ in 0..<5 { _ = try tale.create(workspace: w, agent: a, requestId: "first", title: "First", goal: "Do it", kind: "general", provider: "claude", budget: 0.5) }
        require(tale.eventCount == countBefore && tale.jobs.count == 1, "asking again for the same request adds neither a task nor an entry")
        try tale.update(firstID, ["progress": "Only text changed"])
        require(tale.eventCount == countBefore, "progress text alone is not an event")

        // A restart that finds work still marked running ends its attempt and says why.
        let crashed = root.appendingPathComponent("crashed")
        do {
            let before = try BuddyWorkerStore(directory: crashed)
            let made = try before.create(workspace: w, agent: a, requestId: "interrupted", title: "Running", goal: "Do it", kind: "general", provider: "chatgpt", budget: 0)
            try before.update(made["id"] as! String, ["status": "running", "attempt": 1, "executionRunID": "run-x"])
        }
        let restarted = try BuddyWorkerStore(directory: crashed), interruptedID = restarted.jobs[0]["id"] as! String
        let restartHistory = try restarted.history(of: interruptedID)
        let restartStatus = restartHistory.last { $0.type == "task.status" }
        require(restartHistory.map(\.type) == ["task.created", "task.status", "attempt.started", "attempt.ended", "task.status", "decision.opened"] && restartStatus?.cause == "worker.restart" && restartStatus?.payload["to"] as? String == "interrupted", "a restart records that it interrupted the running task, and that this needs the person")
        require(try restarted.attempts(of: interruptedID).first?.outcome == "interrupted", "and ends the attempt as interrupted")
        let reopenedAgain = try BuddyWorkerStore(directory: crashed)
        require(reopenedAgain.eventCount == restarted.eventCount, "starting again adds nothing")

        // Tasks that were there before history began get one starting entry, from the import and from a database left by slice 1.
        require(try queue.history(of: live[0]["id"] as! String).map(\.type) == ["task.imported"] && queue.eventCount == 5, "imported tasks each begin with one entry, and the archived ones have none")
        let upgraded = root.appendingPathComponent("upgraded")
        do {
            let seeded = try BuddyWorkerStore(directory: upgraded)
            _ = try seeded.create(workspace: w, agent: a, requestId: "one", title: "One", goal: "Do it", kind: "general", provider: "chatgpt", budget: 0)
            _ = try seeded.create(workspace: w, agent: a, requestId: "two", title: "Two", goal: "Do it", kind: "general", provider: "chatgpt", budget: 0)
            let raw = try BuddyOperationsDB(directory: upgraded, existing: true)
            for table in ["events", "attempts", "consumers", "outbox"] { try raw.run("DROP TABLE \(table)") }
            try raw.run("PRAGMA user_version = 1")
        }
        let moved = try BuddyWorkerStore(directory: upgraded)
        require(try BuddyOperationsDB(directory: upgraded, existing: true).rows("PRAGMA user_version").first?.first?.int == 6, "a database from slice 1 is brought up to the current version")
        let movedTypes = try moved.history(of: moved.jobs[0]["id"] as! String).map(\.type)
        require(moved.jobs.count == 2 && moved.eventCount == 2 && movedTypes == ["task.imported"], "each task it already held gets a starting entry")

        // 8. The outbox: events reach each consumer once, and replaying them changes nothing.
        let hub = root.appendingPathComponent("hub")
        let bus = try BuddyWorkerStore(directory: hub)
        try bus.register(consumer: "early")
        let firstMade = try bus.create(workspace: w, agent: a, requestId: "bus-1", title: "Bus", goal: "Do it", kind: "general", provider: "chatgpt", budget: 0), busID = firstMade["id"] as! String
        try bus.register(consumer: "late")
        try bus.register(consumer: "everything", replayHistory: true)
        try bus.update(busID, ["status": "running", "attempt": 1, "executionRunID": "bus-run"])
        try bus.update(busID, ["status": "completed", "result": "Done"])
        let early = try bus.undelivered(for: "early"), late = try bus.undelivered(for: "late"), everything = try bus.undelivered(for: "everything")
        require(early.count == 5 && late.count == 4 && everything.count == 5, "a consumer gets what happened after it signed up, and all of it if it asked for the past (\(early.count), \(late.count), \(everything.count))")
        require(early.map(\.id) == early.map(\.id).sorted() && early.map(\.seq) == Array(1...5), "events arrive oldest first, numbered as in the task's own history")
        try bus.register(consumer: "late")
        require(try bus.undelivered(for: "late").count == 4, "signing up twice changes nothing")
        func note(_ event: BuddyTaskEvent) -> (BuddyOperationsDB) throws -> Void { { db in try db.setMeta("notified:\(event.id)", event.type) } }
        let probeDB = try BuddyOperationsDB(directory: hub, existing: true)
        func notified() throws -> Int { Int(try probeDB.rows("SELECT COUNT(*) FROM meta WHERE key LIKE 'notified:%'").first?.first?.int ?? 0) }
        struct Refused: Error {}
        var failedOnce = false; do { try bus.deliver(early[0], to: "early") { _ in throw Refused() } } catch { failedOnce = true }
        let waitingAfterFailure = try bus.undelivered(for: "early").count
        require(failedOnce && waitingAfterFailure == 5, "an event whose handling fails stays waiting")
        var delivered = 0
        for event in early { if try bus.deliver(event, to: "early", effect: note(event)) { delivered += 1 } }
        let notifiedOnce = try notified(), nothingLeft = try bus.undelivered(for: "early").isEmpty
        require(delivered == 5 && notifiedOnce == 5 && nothingLeft, "each event is handled once, in one step with the record that it was handled")
        var repeated = 0
        for event in early + early { if try bus.deliver(event, to: "early", effect: note(event)) { repeated += 1 } }
        let notifiedAfterReplay = try notified()
        require(repeated == 0 && notifiedAfterReplay == 5, "replaying every event changes nothing: no second notification")
        let lateWaiting = try bus.undelivered(for: "late").count, strangerGot = try bus.deliver(early[0], to: "nobody-signed-up")
        require(lateWaiting == 4 && !strangerGot, "one consumer's progress does not move another's, and an unknown consumer receives nothing")
        // A worker ended while handling an event: before the commit nothing happened, after it everything did, and a retry never doubles it.
        for phase in ["before", "effect", "after"] {
            let directory = root.appendingPathComponent("deliver-\(phase)")
            let outcome = try run(binary, [], environment: ["BUDDY_CRASH_CHILD": "deliver", "BUDDY_CRASH_DIR": directory.path, "BUDDY_CRASH_PHASE": phase, "BUDDY_CRASH_W": w, "BUDDY_CRASH_A": a])
            require(outcome.status == 137, "the worker was ended while handling an event (\(phase))")
            let store = try BuddyWorkerStore(directory: directory), check = try BuddyOperationsDB(directory: directory, existing: true)
            let recorded = Int(try check.rows("SELECT COUNT(*) FROM meta WHERE key LIKE 'handled:%'").first?.first?.int ?? 0)
            let waiting = try store.undelivered(for: "writer")
            require(phase == "after" ? (recorded == 1 && waiting.count == 1) : (recorded == 0 && waiting.count == 2), "ended \(phase) the commit, the event and its effect are both done or both not (\(recorded) handled, \(waiting.count) waiting)")
            for event in waiting { try store.deliver(event, to: "writer") { db in try db.setMeta("handled:\(event.id)", event.type) } }
            let total = Int(try check.rows("SELECT COUNT(*) FROM meta WHERE key LIKE 'handled:%'").first?.first?.int ?? 0)
            let leftWaiting = try store.undelivered(for: "writer").count
            require(total == 2 && leftWaiting == 0, "after the retry every event has been handled exactly once (\(phase))")
        }
        // History is trimmed only from archived tasks, and never an event someone still has to receive.
        let trimmed = root.appendingPathComponent("trimmed")
        do {
            let busy = try BuddyWorkerStore(directory: trimmed)
            for i in 0..<6 {
                let made = try busy.create(workspace: w, agent: a, requestId: "trim-\(i)", title: "Trim", goal: "Do it", kind: "general", provider: "chatgpt", budget: 0)
                try busy.update(made["id"] as! String, ["status": "completed"])
            }
            _ = try busy.archiveFinished(keeping: 0)
            require(busy.eventCount == 18, "six finished tasks leave three entries each")
            try busy.register(consumer: "slow", replayHistory: true)
        }
        BuddyWorkerStore.eventLimit = 5
        let guarded = try BuddyWorkerStore(directory: trimmed)
        require(guarded.eventCount == 18, "events a consumer still has to receive are never trimmed")
        for event in try guarded.undelivered(for: "slow", limit: 1000) { try guarded.deliver(event, to: "slow") }
        let hardlyAny = try BuddyWorkerStore(directory: trimmed)
        BuddyWorkerStore.eventLimit = 100_000
        require(hardlyAny.eventCount == 5, "once they are handled, the oldest entries of archived tasks are trimmed down to the limit (\(hardlyAny.eventCount))")
        print("PASS: first-start migration with a verified ZIP backup, exact IDs and schedules, old files set aside not deleted, refusal of every unverifiable file, one task per request, versions, oversize refusal, newer-schema refusal, and the process ended at all \(scriptSteps * 2) commit boundaries plus both import boundaries")
    }

    /// Runs inside a separate process that ends itself at a chosen commit.
    @MainActor static func child(_ mode: String, _ environment: [String: String]) throws {
        let directory = URL(fileURLWithPath: environment["BUDDY_CRASH_DIR"]!), phase = environment["BUDDY_CRASH_PHASE"] ?? "before"
        if mode == "migrate" {
            _ = try BuddyOperationsDB(directory: directory)   // the schema is made first, so the next commit is the import itself
            if phase == "before" { BuddyOperationsDB.beforeCommit = { _exit(137) } } else { BuddyOperationsMigration.afterImport = { _exit(137) } }
            _ = try BuddyWorkerStore(directory: directory)
            exit(0)
        }
        if mode == "deliver" {
            let store = try BuddyWorkerStore(directory: directory)
            try store.register(consumer: "writer")
            let made = try store.create(workspace: environment["BUDDY_CRASH_W"]!, agent: environment["BUDDY_CRASH_A"]!, requestId: "deliver", title: "Deliver", goal: "Do it", kind: "general", provider: "chatgpt", budget: 0)
            try store.update(made["id"] as! String, ["status": "paused"])
            // two events wait: the creation and the status change; handle the first one and end the process at the chosen point
            let first = try store.undelivered(for: "writer")[0]
            if phase == "before" { BuddyOperationsDB.beforeCommit = { _exit(137) } }
            if phase == "after" { BuddyOperationsDB.afterCommit = { _exit(137) } }
            try store.deliver(first, to: "writer") { db in
                try db.setMeta("handled:\(first.id)", first.type)
                if phase == "effect" { _exit(137) }
            }
            exit(0)
        }
        let target = Int(environment["BUDDY_CRASH_AT"] ?? "") ?? 999
        let store = try BuddyWorkerStore(directory: directory)
        var count = 0
        BuddyOperationsDB.beforeCommit = { count += 1; if phase == "before" && count == target { _exit(137) } }
        BuddyOperationsDB.afterCommit = { if phase == "after" && count == target { _exit(137) } }
        try script(store, environment["BUDDY_CRASH_W"]!, environment["BUDDY_CRASH_A"]!, steps: scriptSteps)
        exit(0)
    }
}
