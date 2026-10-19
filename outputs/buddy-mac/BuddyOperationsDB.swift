import Foundation
import SQLite3

struct BuddyOperationsFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The worker's operational database: background tasks, saved routines and the small settings that go with them.
///
/// It replaces two JSON files that were rewritten in full on every change. A change is now one transaction on one row, committed with
/// `synchronous=FULL`, so killing the process at any moment leaves either the whole change or none of it. Each row keeps the task's
/// original dictionary as JSON in `body`, so the code above the store sees exactly the shape it always saw.
final class BuddyOperationsDB {
    static let fileName = "operations.sqlite"
    static let schemaVersion: Int64 = 4
    /// Called just before COMMIT and just after it. Only the crash tests set them, to end the process at each commit boundary.
    static var beforeCommit: (() -> Void)?
    static var afterCommit: (() -> Void)?

    enum Bind { case text(String), int(Int64), null }
    enum Column {
        case text(String), int(Int64), null
        var string: String? { if case .text(let value) = self { return value }; return nil }
        var int: Int64? { if case .int(let value) = self { return value }; return nil }
    }

    let url: URL
    private var handle: OpaquePointer?
    private var inTransaction = false
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// `existing` opens a database that must already be there and never creates or changes the schema. Readers in other places use it.
    init(directory: URL, existing: Bool = false) throws {
        url = directory.appendingPathComponent(Self.fileName)
        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | (existing ? 0 : SQLITE_OPEN_CREATE)
        guard sqlite3_open_v2(url.path, &opened, flags, nil) == SQLITE_OK, let opened else {
            let reason = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "it could not be opened"
            if let opened { sqlite3_close_v2(opened) }
            throw BuddyOperationsFailure(message: "Buddy couldn’t open its task database: \(reason).")
        }
        handle = opened
        do {
            sqlite3_busy_timeout(opened, 5000)
            if !existing {
                // Created private before anything is written; the -wal and -shm files copy this mode when SQLite makes them.
                chmod(url.path, 0o600)
                _ = try rows("PRAGMA journal_mode=WAL")
                try run("PRAGMA synchronous=FULL")
                let check = try rows("PRAGMA quick_check(1)")
                guard check.first?.first?.string == "ok" else { throw BuddyOperationsFailure(message: "Buddy couldn’t verify its saved task database. Restore it from the newest ZIP in Worker/Backups before starting the worker.") }
                try prepareSchema()
            }
        } catch {
            sqlite3_close_v2(opened); handle = nil
            if let known = error as? BuddyOperationsFailure, known.message.hasPrefix("Buddy couldn’t verify") || known.message.hasPrefix("The task database was written by a newer") { throw known }
            throw BuddyOperationsFailure(message: "Buddy couldn’t verify its saved task database (\(error.localizedDescription)). Restore it from the newest ZIP in Worker/Backups before starting the worker.")
        }
    }
    deinit { if let handle { sqlite3_close_v2(handle) } }

    private func prepareSchema() throws {
        let version = try rows("PRAGMA user_version").first?.first?.int ?? 0
        if version > Self.schemaVersion { throw BuddyOperationsFailure(message: "The task database was written by a newer version of Buddy. Update Buddy before starting the worker.") }
        guard version < Self.schemaVersion else { return }
        // Each step is its own transaction, so a database left at version 1 by an earlier Buddy is brought up one version at a time.
        if version < 1 { try createVersion1() }
        if version < 2 { try createVersion2() }
        if version < 3 { try createVersion3() }
        if version < 4 { try createVersion4() }
    }
    private func createVersion1() throws {
        try transaction {
            try run("CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            try run("""
                CREATE TABLE IF NOT EXISTS tasks(
                    seq INTEGER PRIMARY KEY AUTOINCREMENT,
                    id TEXT NOT NULL UNIQUE,
                    workspace TEXT NOT NULL,
                    agent_id TEXT NOT NULL DEFAULT '',
                    request_id TEXT NOT NULL DEFAULT '',
                    status TEXT NOT NULL DEFAULT '',
                    kind TEXT NOT NULL DEFAULT '',
                    version INTEGER NOT NULL DEFAULT 1,
                    archived INTEGER NOT NULL DEFAULT 0,
                    created_at TEXT NOT NULL DEFAULT '',
                    updated_at TEXT NOT NULL DEFAULT '',
                    body TEXT NOT NULL)
                """)
            // One request makes one task. An archived task no longer holds its request ID, as before.
            try run("CREATE UNIQUE INDEX IF NOT EXISTS tasks_request ON tasks(workspace, agent_id, request_id) WHERE archived = 0 AND request_id <> ''")
            try run("CREATE INDEX IF NOT EXISTS tasks_live ON tasks(archived, status)")
            try run("""
                CREATE TABLE IF NOT EXISTS routines(
                    seq INTEGER PRIMARY KEY AUTOINCREMENT,
                    id TEXT NOT NULL UNIQUE,
                    workspace TEXT NOT NULL,
                    agent_id TEXT NOT NULL DEFAULT '',
                    status TEXT NOT NULL DEFAULT '',
                    version INTEGER NOT NULL DEFAULT 1,
                    body TEXT NOT NULL)
                """)
            try run("PRAGMA user_version = 1")
        }
    }
    /// Version 2: attempts, the ordered event log of each task, and the outbox that hands events to whoever registered for them.
    private func createVersion2() throws {
        try transaction {
            // One row per try at a task. `outcome` stays empty while the attempt is still going.
            try run("""
                CREATE TABLE IF NOT EXISTS attempts(
                    task_id TEXT NOT NULL,
                    n INTEGER NOT NULL,
                    run_id TEXT NOT NULL DEFAULT '',
                    provider TEXT NOT NULL DEFAULT '',
                    model TEXT NOT NULL DEFAULT '',
                    started_at TEXT NOT NULL,
                    ended_at TEXT,
                    outcome TEXT,
                    PRIMARY KEY(task_id, n))
                """)
            // `id` orders every event of every task; `seq` orders one task's events and never has a gap.
            try run("""
                CREATE TABLE IF NOT EXISTS events(
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    task_id TEXT NOT NULL,
                    seq INTEGER NOT NULL,
                    type TEXT NOT NULL,
                    cause TEXT NOT NULL DEFAULT '',
                    correlation TEXT NOT NULL DEFAULT '',
                    attempt INTEGER,
                    payload TEXT NOT NULL DEFAULT '{}',
                    created_at TEXT NOT NULL,
                    UNIQUE(task_id, seq))
                """)
            try run("CREATE TABLE IF NOT EXISTS consumers(name TEXT PRIMARY KEY, registered_at TEXT NOT NULL)")
            // One row per event per registered consumer, written in the same transaction as the event. `delivered_at` is the consumer's record that it handled the event.
            try run("CREATE TABLE IF NOT EXISTS outbox(event_id INTEGER NOT NULL, consumer TEXT NOT NULL, delivered_at TEXT, PRIMARY KEY(event_id, consumer))")
            try run("CREATE INDEX IF NOT EXISTS outbox_waiting ON outbox(consumer, event_id) WHERE delivered_at IS NULL")
            try run("PRAGMA user_version = 2")
        }
    }

    // MARK: statements

    private func failure() -> BuddyOperationsFailure {
        BuddyOperationsFailure(message: "Buddy’s task database reported: \(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "closed").")
    }
    private func statement(_ sql: String, _ binds: [Bind]) throws -> OpaquePointer {
        var prepared: OpaquePointer?
        guard let handle, sqlite3_prepare_v2(handle, sql, -1, &prepared, nil) == SQLITE_OK, let prepared else { throw failure() }
        for (index, bind) in binds.enumerated() {
            let position = Int32(index + 1)
            switch bind {
            case .text(let value): sqlite3_bind_text(prepared, position, value, -1, Self.transient)
            case .int(let value): sqlite3_bind_int64(prepared, position, value)
            case .null: sqlite3_bind_null(prepared, position)
            }
        }
        return prepared
    }
    /// Version 3: one record for every action that needs the user's approval (a browser operation, a sign-in, a command with network access, a
    /// connected-service request), and the leases that give one attempt exclusive use of a resource such as a browser profile.
    private func createVersion3() throws {
        try transaction {
            // `state` runs proposed, approved, dispatched, then confirmed or uncertain; declined, expired, not_sent and failed are the other ends.
            // `run_id` is the attempt that proposed it, so a result that arrives from a replaced attempt can be told apart.
            try run("""
                CREATE TABLE IF NOT EXISTS actions(
                    id TEXT PRIMARY KEY,
                    task_id TEXT NOT NULL,
                    attempt INTEGER NOT NULL DEFAULT 0,
                    run_id TEXT NOT NULL DEFAULT '',
                    kind TEXT NOT NULL DEFAULT '',
                    tool TEXT NOT NULL DEFAULT '',
                    payload_hash TEXT NOT NULL DEFAULT '',
                    idempotency_key TEXT NOT NULL DEFAULT '',
                    state TEXT NOT NULL,
                    proposed_at TEXT NOT NULL DEFAULT '',
                    approved_at TEXT,
                    dispatched_at TEXT,
                    finished_at TEXT,
                    late INTEGER NOT NULL DEFAULT 0,
                    resolved_by TEXT NOT NULL DEFAULT '',
                    receipt TEXT NOT NULL DEFAULT '{}')
                """)
            try run("CREATE INDEX IF NOT EXISTS actions_task ON actions(task_id, state)")
            try run("CREATE INDEX IF NOT EXISTS actions_payload ON actions(task_id, payload_hash)")
            // A lease is never deleted, only freed, so `generation` only ever goes up and an old token can never match a newer lease.
            try run("CREATE TABLE IF NOT EXISTS leases(resource TEXT PRIMARY KEY, generation INTEGER NOT NULL, holder TEXT NOT NULL DEFAULT '', task_id TEXT NOT NULL DEFAULT '', acquired_at TEXT NOT NULL DEFAULT '', expires_at INTEGER NOT NULL DEFAULT 0)")
            try run("PRAGMA user_version = 3")
        }
    }
    /// Version 4: the money record. Every change to what a task may spend, has reserved, has spent or cannot account for is one append-only entry,
    /// written in the same transaction as the task, and a daily limit can be set for one agent or for the whole workspace.
    private func createVersion4() throws {
        try transaction {
            // `kind` is authorize, reserve, spend, release or uncertain; the amount is always positive and the kind gives its direction.
            try run("""
                CREATE TABLE IF NOT EXISTS budget_entries(
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    workspace TEXT NOT NULL,
                    agent_id TEXT NOT NULL DEFAULT '',
                    task_id TEXT NOT NULL DEFAULT '',
                    attempt INTEGER,
                    kind TEXT NOT NULL,
                    amount_usd REAL NOT NULL,
                    day TEXT NOT NULL,
                    at TEXT NOT NULL,
                    cause TEXT NOT NULL DEFAULT '',
                    idem TEXT UNIQUE)
                """)
            try run("CREATE INDEX IF NOT EXISTS budget_day ON budget_entries(workspace, agent_id, day)")
            try run("CREATE INDEX IF NOT EXISTS budget_task ON budget_entries(task_id)")
            try run("""
                CREATE TABLE IF NOT EXISTS limits(
                    workspace TEXT NOT NULL,
                    scope TEXT NOT NULL,
                    scope_id TEXT NOT NULL DEFAULT '',
                    period TEXT NOT NULL DEFAULT 'day',
                    amount_usd REAL NOT NULL,
                    set_by TEXT NOT NULL DEFAULT '',
                    quote TEXT NOT NULL DEFAULT '',
                    set_at TEXT NOT NULL,
                    PRIMARY KEY(workspace, scope, scope_id, period))
                """)
            try run("PRAGMA user_version = 4")
        }
    }
    /// The row number SQLite gave the most recent INSERT on this connection.
    var lastInsertID: Int64 { handle.map { sqlite3_last_insert_rowid($0) } ?? 0 }
    /// Runs one statement and returns how many rows it changed.
    @discardableResult func run(_ sql: String, _ binds: [Bind] = []) throws -> Int {
        let prepared = try statement(sql, binds); defer { sqlite3_finalize(prepared) }
        var code = sqlite3_step(prepared)
        while code == SQLITE_ROW { code = sqlite3_step(prepared) }
        guard code == SQLITE_DONE, let handle else { throw failure() }
        return Int(sqlite3_changes(handle))
    }
    func rows(_ sql: String, _ binds: [Bind] = []) throws -> [[Column]] {
        let prepared = try statement(sql, binds); defer { sqlite3_finalize(prepared) }
        var out: [[Column]] = []
        while true {
            let code = sqlite3_step(prepared)
            if code == SQLITE_DONE { return out }
            guard code == SQLITE_ROW else { throw failure() }
            out.append((0..<sqlite3_column_count(prepared)).map { index in
                switch sqlite3_column_type(prepared, index) {
                case SQLITE_INTEGER: return .int(sqlite3_column_int64(prepared, index))
                case SQLITE_NULL: return .null
                default: return sqlite3_column_text(prepared, index).map { .text(String(cString: $0)) } ?? .null
                }
            })
        }
    }
    /// All the statements inside commit together or not at all. A transaction inside a transaction joins the outer one.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        if inTransaction { return try body() }
        try run("BEGIN IMMEDIATE")
        inTransaction = true; defer { inTransaction = false }
        do {
            let value = try body()
            Self.beforeCommit?()
            try run("COMMIT")
            Self.afterCommit?()
            return value
        } catch {
            _ = try? run("ROLLBACK")
            throw error
        }
    }

    // MARK: settings

    func meta(_ key: String) throws -> String? { try rows("SELECT value FROM meta WHERE key = ?", [.text(key)]).first?.first?.string }
    func setMeta(_ key: String, _ value: String) throws {
        try run("INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", [.text(key), .text(value)])
    }

    // MARK: JSON bodies

    static func encode(_ value: [String: Any]) throws -> String {
        guard JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) else {
            throw BuddyOperationsFailure(message: "That change contains a value Buddy can’t save.")
        }
        return text
    }
    static func decode(_ text: String) throws -> [String: Any] {
        guard let data = text.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BuddyOperationsFailure(message: "Buddy couldn’t read a saved record.")
        }
        return value
    }

    // MARK: readers elsewhere

    /// What other parts of the app need to see without owning the store: the live tasks and the routines, as the old files showed them.
    /// Nil means the database has not been set up yet, and the caller should read the old JSON files, which are then still the truth.
    static func snapshot(directory: URL) throws -> (tasks: [[String: Any]], routines: [[String: Any]])? {
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(fileName).path) else { return nil }
        let db = try BuddyOperationsDB(directory: directory, existing: true)
        // A database that was only just created, or whose creation was cut short, has nothing to show yet.
        guard try !db.rows("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'meta'").isEmpty, try db.meta("migration") != nil else { return nil }
        let tasks = try db.rows("SELECT body FROM tasks WHERE archived = 0 ORDER BY seq").compactMap { $0.first?.string }.map(decode)
        let routines = try db.rows("SELECT body FROM routines ORDER BY seq").compactMap { $0.first?.string }.map(decode)
        guard tasks.count <= 1000, routines.count <= 100 else { throw BuddyOperationsFailure(message: "Saved routine results could not be verified.") }
        return (tasks, routines)
    }
}

/// What an agent has spent, set aside or cannot account for today, and what it may spend. Read by every process that starts paid work: the
/// worker (background tasks) and the app (chat turns). Only the worker writes the ledger and the limits.
enum BuddyBudget {
    struct Exposure: Equatable {
        var spent = 0.0, uncertain = 0.0, reserved = 0.0
        var total: Double { spent + uncertain + reserved }
    }
    /// The local calendar day, which is how people read "per day".
    static func day(_ date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current; f.dateFormat = "yyyy-MM-dd"; return f.string(from: date)
    }
    private static func chatFile(_ support: URL, _ now: Date) -> URL {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current; f.dateFormat = "yyyy-MM"
        return support.appendingPathComponent("Claude/spend-" + f.string(from: now) + ".jsonl")
    }
    /// A chat turn's money, one line per event: `reserve` when it starts (the most it may spend) and `spend` when it ends, with its real cost.
    static func recordChat(support: URL, workspace: String, agent: String, runID: String, kind: String, amount: Double, now: Date = Date()) {
        guard amount.isFinite, amount >= 0, ["reserve", "spend"].contains(kind),
              let line = try? JSONSerialization.data(withJSONObject: ["day": day(now), "workspace": workspace, "agent": agent, "run": runID, "kind": kind, "usd": amount, "at": ISO8601DateFormatter().string(from: now)], options: [.sortedKeys]) else { return }
        let file = chatFile(support, now)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd(); try? handle.write(contentsOf: line + Data([10]))
    }
    /// Chat spending today for one agent: what turns have cost, plus what an unfinished turn may still cost. A turn that never reported is counted
    /// at its reserved amount as uncertain, so a crash cannot make money disappear.
    private static func chatExposure(support: URL, workspace: String, agent: String, now: Date) -> Exposure {
        guard let text = try? String(contentsOf: chatFile(support, now), encoding: .utf8) else { return Exposure() }
        let today = day(now)
        var reserved: [String: Double] = [:], spent: [String: Double] = [:], at: [String: Date] = [:]
        for line in text.split(separator: "\n") {
            guard let value = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], value["day"] as? String == today, value["workspace"] as? String == workspace,
                  value["agent"] as? String == agent, let run = value["run"] as? String, let usd = value["usd"] as? Double else { continue }
            if value["kind"] as? String == "spend" { spent[run] = usd } else { reserved[run] = usd; at[run] = (value["at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? now }
        }
        var out = Exposure()
        for (run, usd) in spent { out.spent += usd; _ = run }
        for (run, usd) in reserved where spent[run] == nil {
            // Still running: reserved. Long gone without a report: uncertain.
            if now.timeIntervalSince(at[run] ?? now) > 2 * 3600 { out.uncertain += usd } else { out.reserved += usd }
        }
        return out
    }
    /// The limit that applies to an agent: its own if it has one, else the workspace's.
    static func limit(_ db: BuddyOperationsDB, workspace: String, agent: String) throws -> (amount: Double, scope: String)? {
        for (scope, id) in [("agent", agent), ("workspace", "")] {
            if let row = try db.rows("SELECT amount_usd FROM limits WHERE workspace = ? AND scope = ? AND scope_id = ? AND period = 'day'", [.text(workspace), .text(scope), .text(id)]).first, let text = row[0].string, let amount = Double(text) { return (amount, scope) }
        }
        return nil
    }
    /// Today's money for an agent, from every place it can be spent.
    static func exposure(_ db: BuddyOperationsDB, support: URL, workspace: String, agent: String, now: Date = Date()) throws -> Exposure {
        let today = day(now)
        var out = chatExposure(support: support, workspace: workspace, agent: agent, now: now)
        for row in try db.rows("SELECT kind, SUM(amount_usd) FROM budget_entries WHERE workspace = ? AND agent_id = ? AND day = ? AND kind IN ('spend', 'uncertain') GROUP BY kind", [.text(workspace), .text(agent), .text(today)]) {
            let amount = Double(row[1].string ?? "") ?? 0
            if row[0].string == "spend" { out.spent += amount } else { out.uncertain += amount }
        }
        // What running tasks have set aside right now.
        for row in try db.rows("SELECT body FROM tasks WHERE archived = 0 AND workspace = ? AND agent_id = ?", [.text(workspace), .text(agent)]) {
            if let body = try? BuddyOperationsDB.decode(row[0].string ?? "{}"), let reservedNow = body["reservedBudgetUSD"] as? Double, reservedNow > 0 { out.reserved += reservedNow }
        }
        return out
    }
    /// The read-only check made by whoever is about to start paid work. Nil means there is no database yet, so no limit can have been set.
    static func headroom(support: URL, workspace: String, agent: String, now: Date = Date()) -> (limit: Double, scope: String, exposure: Exposure, room: Double)? {
        let directory = support.appendingPathComponent("Worker")
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(BuddyOperationsDB.fileName).path), let db = try? BuddyOperationsDB(directory: directory, existing: true),
              let limit = try? limit(db, workspace: workspace, agent: agent), let used = try? exposure(db, support: support, workspace: workspace, agent: agent, now: now) else { return nil }
        return (limit.amount, limit.scope, used, max(0, limit.amount - used.total))
    }
}
