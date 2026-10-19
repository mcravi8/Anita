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
    static let schemaVersion: Int64 = 1
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
            try run("PRAGMA user_version = \(Self.schemaVersion)")
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
