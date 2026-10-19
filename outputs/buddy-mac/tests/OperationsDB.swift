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
            { try store.update(id, ["status": "running", "remainingBudgetUSD": 0, "reservedBudgetUSD": 0.5]) },
            { try store.update(id, ["progress": "Halfway there"]) },
            { other = try store.create(workspace: w, agent: a, requestId: "second", title: "Second", goal: "Do more", kind: "general", provider: "chatgpt", budget: 0)["id"] as! String },
            { try store.update(other, ["status": "completed", "result": "Done"]) },
            { try store.setPaused(true) },
            { _ = try store.archiveFinished(keeping: 1) },
            { try store.update(id, ["status": "paused"]) },
            { _ = try store.resume(id, additionalBudgetUSD: 0.3, authorizationID: authorization) },
            { try store.update(id, ["status": "completed", "result": "All finished"]) },
        ]
        for step in 0..<min(steps, all.count) { try all[step](); rest(step + 1) }
    }
    static let scriptSteps = 10
    /// What a restarted worker shows: the same text whichever process wrote it.
    @MainActor static func summary(_ directory: URL) throws -> [String] {
        let store = try BuddyWorkerStore(directory: directory)
        let live = store.jobs.map { "\($0["requestId"] as? String ?? "")|\($0["status"] as? String ?? "")|\($0["progress"] as? String ?? "")|\($0["result"] as? String ?? "")|\($0["remainingBudgetUSD"] ?? "-")|\(($0["budgetAuthorizations"] as? [[String: Any]])?.count ?? 0)" }
        let archived = try store.archivedJobs().map { "archived:\($0["requestId"] as? String ?? "")" }
        return live + archived + ["paused:\(store.paused)"]
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
        require(try probe.rows("PRAGMA user_version").first?.first?.int == 1, "the schema carries a version")
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
                let found = try summary(directory)
                require(found == expected, "after being ended \(phase) commit \(commit), the saved tasks are exactly the state \(phase == "before" ? "before" : "after") that change\n found: \(found)\n wanted: \(expected)")
                let integrity = try BuddyOperationsDB(directory: directory, existing: true).rows("PRAGMA integrity_check").first?.first?.string
                require(integrity == "ok", "the database passes its integrity check after being ended \(phase) commit \(commit)")
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
        let target = Int(environment["BUDDY_CRASH_AT"] ?? "") ?? 999
        let store = try BuddyWorkerStore(directory: directory)
        var count = 0
        BuddyOperationsDB.beforeCommit = { count += 1; if phase == "before" && count == target { _exit(137) } }
        BuddyOperationsDB.afterCommit = { if phase == "after" && count == target { _exit(137) } }
        try script(store, environment["BUDDY_CRASH_W"]!, environment["BUDDY_CRASH_A"]!, steps: scriptSteps)
        exit(0)
    }
}
