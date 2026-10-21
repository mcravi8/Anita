import Foundation

/// One-time changes to saved data, run before the worker's stores load. Each runs once, records that it ran, and keeps a ZIP backup first.
///
/// Before the first pending change the whole database is copied (`VACUUM INTO`) and zipped into `Worker/Backups`; nothing is written without
/// that backup. Each change is its own transaction and records `meta('migration.<name>')` with it, so it runs exactly once. A change that fails
/// is written to `Worker/migration-error.txt`, is not recorded (it runs again on the next start), and never stops the others. Nothing is
/// deleted: stale runs become cancelled with a note, routines are paused, and the change to Chief's instructions waits for the user's tap.
///
/// It needs only Foundation, the database and the pure helpers in the core (`BuddyRoutineGoals`, `BuddyAgentChanges`), and reads the JSON files
/// it uses (`workspace.json`, `team-monitor.json`, `agent-models.json`, `agent-memory.json`) itself.
@MainActor enum BuddyMigrations {
    static let names = ["routine-models.v1", "legacy-stops.v1", "keepgoing-routines.v1", "attempt-results.v1", "supervisor-instructions-card.v1"]
    static let decideText = "Decide and keep the team's work moving without waiting for the CEO; record each decision and why. Model usage within the daily limit needs no approval; paying for, buying or subscribing to anything needs the CEO's OK first."
    static let pausedText = "Paused by the update: scheduled runs cannot start work; the team plan does that now."
    static let receiptsMarker = "\n\n---\nCommand receipts"
    private static let askFirst = try! NSRegularExpression(pattern: #"(?i)if in doubt,? ask|check with (?:the|my) [^.]{0,20} first|always get [^.]{0,40}approval first"#)

    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }
    private struct Context { let support, worker: URL; let db: BuddyOperationsDB; let now: Date; let stamp: String }

    static func run(support: URL, now: Date = Date()) throws -> [String] {
        let worker = support.appendingPathComponent("Worker", isDirectory: true), stamp = ISO8601DateFormatter().string(from: now)
        // A new install has nothing to migrate, and a database whose old files are not imported yet is left to the store first.
        guard FileManager.default.fileExists(atPath: worker.appendingPathComponent(BuddyOperationsDB.fileName).path) else { return [] }
        let pending: [String]
        do {
            let reader = try BuddyOperationsDB(directory: worker, existing: true)
            let tables = Set(try reader.rows("SELECT name FROM sqlite_master WHERE type = 'table'").compactMap { $0.first?.string })
            guard tables.isSuperset(of: ["meta", "tasks", "routines", "attempts", "decisions", "setting_changes"]), try reader.meta("migration") != nil else { return [] }
            let done = Set(try reader.rows("SELECT key FROM meta WHERE key LIKE 'migration.%'").compactMap { $0.first?.string })
            pending = names.filter { !done.contains("migration." + $0) }
            guard !pending.isEmpty else { return [] }
            try backUp(reader, worker: worker, now: now)
        } catch { note(worker, stamp, "backup", error); throw error }
        let db: BuddyOperationsDB
        do { db = try BuddyOperationsDB(directory: worker) } catch { note(worker, stamp, "open", error); throw error }
        let context = Context(support: support, worker: worker, db: db, now: now, stamp: stamp)
        var applied: [String] = []
        for name in pending {
            do {
                try db.transaction {
                    switch name {
                    case "routine-models.v1": try routineModels(context)
                    case "legacy-stops.v1": try legacyStops(context)
                    case "keepgoing-routines.v1": try keepGoingRoutines(context)
                    case "attempt-results.v1": try attemptResults(context)
                    case "supervisor-instructions-card.v1": try instructionsCard(context)
                    default: break
                    }
                    try db.setMeta("migration." + name, stamp)
                }
                applied.append(name)
            } catch { note(worker, stamp, name, error) }
        }
        return applied
    }

    // MARK: backup and errors

    /// `VACUUM INTO` a staging folder, zipped into `Worker/Backups/operations-before-migrations-<stamp>.zip`, checked, made private, and the
    /// staging folder removed. Any failure stops every migration.
    private static func backUp(_ db: BuddyOperationsDB, worker: URL, now: Date) throws {
        let fm = FileManager.default, folder = worker.appendingPathComponent("Backups", isDirectory: true)
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        var stamp = f.string(from: now)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if fm.fileExists(atPath: folder.appendingPathComponent("operations-before-migrations-\(stamp).zip").path) { stamp += "-" + UUID().uuidString.prefix(8) }
        let staging = folder.appendingPathComponent("migrate-\(stamp).noindex", isDirectory: true), zip = folder.appendingPathComponent("operations-before-migrations-\(stamp).zip")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        let copy = staging.appendingPathComponent(BuddyOperationsDB.fileName)
        try db.run("VACUUM INTO ?", [.text(copy.path)])
        func tool(_ path: String, _ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments; process.standardOutput = Pipe(); process.standardError = Pipe()
            try process.run(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw Failure(message: "Buddy couldn’t back up its task database before updating it, so nothing was changed.") }
        }
        try tool("/usr/bin/zip", ["-q", "-j", "-X", zip.path, copy.path])
        do { try tool("/usr/bin/unzip", ["-tq", zip.path]) } catch { try? fm.removeItem(at: zip); throw error }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: zip.path)
    }
    private static func note(_ worker: URL, _ stamp: String, _ name: String, _ error: Error) {
        let line = "\(stamp) \(name): \(error.localizedDescription)\n", url = worker.appendingPathComponent("migration-error.txt")
        if let handle = try? FileHandle(forWritingTo: url) { _ = try? handle.seekToEnd(); try? handle.write(contentsOf: Data(line.utf8)); try? handle.close() }
        else { FileManager.default.createFile(atPath: url.path, contents: Data(line.utf8), attributes: [.posixPermissions: 0o600]) }
    }

    // MARK: reading

    /// A JSON file in the support folder: nil when it is not there, an error when it is there and cannot be read.
    private static func object(_ support: URL, _ name: String) throws -> [String: Any]? {
        let url = support.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let value = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] else { throw Failure(message: "Buddy couldn’t read \(name).") }
        return value
    }
    private static func agents(_ c: Context) throws -> (workspace: String, agents: [[String: Any]]) {
        let state = try object(c.support, "workspace.json") ?? [:]
        return (state["conversationWorkspace"] as? String ?? "", state["agents"] as? [[String: Any]] ?? [])
    }
    /// The supervisor the team check-in policy names for a workspace, if that agent exists (a single agent named Chief when none was chosen, as the
    /// check-in policy itself does).
    private static func supervisor(_ c: Context, workspace: String) throws -> [String: Any]? {
        let (current, agents) = try agents(c)
        guard workspace == current else { return nil }
        let policy = ((try object(c.support, "team-monitor.json"))?["settings"] as? [String: Any])?[workspace] as? [String: Any]
        if let id = policy?["supervisorId"] as? String, !id.isEmpty { return agents.first { $0["id"] as? String == id } }
        guard policy?["supervisorChosen"] as? Bool != true else { return nil }
        let chiefs = agents.filter { ($0["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "chief" }
        return chiefs.count == 1 ? chiefs[0] : nil
    }
    private static func number(_ value: Any?) -> Double? { (value as? Double) ?? (value as? NSNumber)?.doubleValue }
    private static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let f = ISO8601DateFormatter()
        if let d = f.date(from: text) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: text)
    }
    private struct Stored { let seq: Int64; let archived: Bool; var body: [String: Any]; var id: String { body["id"] as? String ?? "" } }
    private static func tasks(_ c: Context) throws -> [Stored] {
        try c.db.rows("SELECT seq, archived, body FROM tasks ORDER BY seq").compactMap { row in
            guard let seq = row[0].int, let body = try? BuddyOperationsDB.decode(row[2].string ?? "") else { return nil }
            return Stored(seq: seq, archived: row[1].int == 1, body: body)
        }
    }
    /// Saves a task's changed body the way the store does (row columns in step, version up, a status change in its history). The time it was
    /// last updated is kept: a stop rewritten today must not count its old reservation as today's money.
    private static func save(_ new: [String: Any], from old: [String: Any], cause: String, _ c: Context) throws {
        let id = new["id"] as? String ?? ""
        try c.db.run("UPDATE tasks SET status = ?, updated_at = ?, version = version + 1, body = ? WHERE id = ?",
                     [.text(new["status"] as? String ?? ""), .text(new["updatedAt"] as? String ?? ""), .text(try BuddyOperationsDB.encode(new)), .text(id)])
        let before = old["status"] as? String ?? "", after = new["status"] as? String ?? ""
        if before != after { try BuddyWorkerStore.appendEvent("task.status", task: new, attempt: new["attempt"] as? Int, cause: cause, payload: ["from": before, "to": after], in: c.db) }
    }
    private static func unsure(_ job: [String: Any]) -> Bool {
        (job["reviews"] as? [[String: Any]] ?? []).contains { ["uncertain", "dispatched"].contains($0["status"] as? String ?? "") }
    }

    // MARK: MIG-1 routine-models.v1

    /// Claude routines pinned to a model that is not their agent's, or carrying an old per-run allowance, move to the agent's model and to no
    /// run limit.
    private static func routineModels(_ c: Context) throws {
        let saved = try object(c.support, "agent-models.json")
        if let saved { guard saved["version"] as? Int == 1, saved["workspaces"] is [String: Any] else { throw Failure(message: "Buddy couldn’t read agent-models.json.") } }
        let models = saved?["workspaces"] as? [String: [String: [String: Any]]] ?? [:]
        for row in try c.db.rows("SELECT id, body FROM routines ORDER BY seq") {
            guard let id = row[0].string, var routine = try? BuddyOperationsDB.decode(row[1].string ?? ""), routine["provider"] as? String == "claude" else { continue }
            let chosen = models[routine["workspace"] as? String ?? ""]?[routine["agentId"] as? String ?? ""]
            let agentModel = chosen?["provider"] as? String == "claude" ? (chosen?["model"] as? String).flatMap { $0.isEmpty ? nil : $0 } : nil
            let wrongModel = agentModel != nil && routine["model"] as? String != agentModel
            guard wrongModel || (number(routine["budgetUSD"]) ?? 0) < 500_000 else { continue }
            if let agentModel { routine["model"] = agentModel }
            routine["budgetUSD"] = BuddyRunLimit.none
            try c.db.run("UPDATE routines SET body = ?, version = version + 1 WHERE id = ?", [.text(try BuddyOperationsDB.encode(routine)), .text(id)])
        }
    }

    // MARK: MIG-2 legacy-stops.v1

    /// (a) A stopped run of some work (the same plan task, else the same routine series) that a later run of that work finished is cancelled as
    /// superseded. (b) What is left stopped becomes old work for the supervisor. Runs that may have sent something, and stops the person made,
    /// are left as they are.
    private static func legacyStops(_ c: Context) throws {
        func key(_ job: [String: Any]) -> String? {
            if let plan = job["planTaskId"] as? String, !plan.isEmpty { return "plan:" + plan }
            if let routine = (job["routineSeriesID"] ?? job["routineID"]) as? String, !routine.isEmpty { return "routine:" + routine }
            return nil
        }
        let stopped: Set<String> = ["failed", "interrupted", "paused"]
        var all = try tasks(c)
        for i in all.indices where !all[i].archived {
            let job = all[i].body
            guard stopped.contains(job["status"] as? String ?? ""), !unsure(job), let mine = key(job),
                  let later = all.first(where: { $0.seq > all[i].seq && $0.body["workspace"] as? String == job["workspace"] as? String && key($0.body) == mine && $0.body["status"] as? String == "completed" }) else { continue }
            var next = job
            next["status"] = "cancelled"; next["stopCause"] = "superseded"; next["supersededBy"] = later.id; next["progress"] = "Superseded: a later run of the same work finished."
            try save(next, from: job, cause: "migration.legacy-stops.v1", c)
            all[i].body = next
        }
        let now = ISO8601DateFormatter().string(from: c.now)
        var supervisors: [String: String] = [:]
        for task in all where !task.archived {
            let job = task.body, cause = job["stopCause"] as? String ?? ""
            guard stopped.contains(job["status"] as? String ?? ""), (job["updatedAt"] as? String ?? "") < now, !unsure(job), !cause.hasPrefix("user"), job["legacy"] as? Bool != true else { continue }
            let workspace = job["workspace"] as? String ?? ""
            if supervisors[workspace] == nil { supervisors[workspace] = (try supervisor(c, workspace: workspace))?["id"] as? String ?? "" }
            var next = job
            next["legacy"] = true
            if cause.isEmpty { next["stopCause"] = "legacy" }
            if (job["supervisorId"] as? String ?? "").isEmpty, let id = supervisors[workspace], !id.isEmpty { next["supervisorId"] = id }
            try save(next, from: job, cause: "migration.legacy-stops.v1", c)
        }
    }

    // MARK: MIG-3 keepgoing-routines.v1

    /// "Keep going" routines an agent scheduled (they ask for coding or delegation, which a scheduled run cannot do) are paused, with one notice
    /// for the user per workspace. Routines the person made on the page are left alone.
    private static func keepGoingRoutines(_ c: Context) throws {
        func byAgent(_ request: String) -> Bool {
            // An agent's request is "<run>:<call>" (with ":hour:<h>" for each hour of a series); the page's is a plain UUID.
            let base = request.replacingOccurrences(of: #":hour:\d+$"#, with: "", options: .regularExpression)
            return UUID(uuidString: base) == nil && base.contains(":")
        }
        var paused: [String: [[String: Any]]] = [:]
        for row in try c.db.rows("SELECT id, body FROM routines ORDER BY seq") {
            guard let id = row[0].string, var routine = try? BuddyOperationsDB.decode(row[1].string ?? ""), routine["status"] as? String == "active",
                  BuddyRoutineGoals.unsupported(routine["goal"] as? String ?? ""), byAgent(routine["requestID"] as? String ?? "") else { continue }
            routine["status"] = "paused"; routine["lastError"] = pausedText
            try c.db.run("UPDATE routines SET status = 'paused', version = version + 1, body = ? WHERE id = ?", [.text(try BuddyOperationsDB.encode(routine)), .text(id)])
            paused[routine["workspace"] as? String ?? "", default: []].append(routine)
        }
        guard !paused.isEmpty else { return }
        let (_, agents) = try agents(c), all = try tasks(c)
        for (workspace, routines) in paused {
            let ids = Set(routines.compactMap { $0["id"] as? String }), owners = Set(routines.compactMap { $0["agentId"] as? String })
            let owner = owners.count == 1 ? owners.first ?? "" : ""
            let name = (agents.first { $0["id"] as? String == owner }?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "your agents"
            let first = all.filter { ids.contains($0.body["routineID"] as? String ?? "") }.compactMap { date($0.body["createdAt"] as? String) }.min()
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current; f.dateFormat = "MMM d"
            let when = first.map { " on " + f.string(from: $0) } ?? ""
            let hourly = routines.allSatisfy { !($0["routineSeriesID"] as? String ?? "").isEmpty } ? "hourly" : "scheduled"
            let text = routines.count == 1
                ? "I paused the \(hourly) “keep going” run \(name) set up\(when). It couldn't start any work — scheduled runs have no coding or delegation tools — and the team plan now keeps work moving. You can resume it in Background work."
                : "I paused the \(hourly) “keep going” runs \(name) set up\(when) (\(routines.count) of them). They couldn't start any work — scheduled runs have no coding or delegation tools — and the team plan now keeps work moving. You can resume them in Background work."
            try c.db.run("INSERT OR IGNORE INTO decisions(id, workspace, agent_id, task_id, kind, title, question, label, payload, created_at, audience) VALUES(?, ?, ?, '', 'notice', ?, ?, 'Background work', ?, ?, 'user')",
                         [.text("migration:keepgoing-routines.v1:" + workspace), .text(workspace), .text(owner), .text("Scheduled “keep going” runs paused"), .text(text),
                          .text(try BuddyOperationsDB.encode(["routineIds": ids.sorted()])), .text(c.stamp)])
        }
    }

    // MARK: MIG-4 attempt-results.v1

    /// What a coding attempt said last, from its saved transcript, for attempts recorded before each attempt kept its own result. A task whose
    /// result was overwritten by a later, empty attempt gets the newest text back, with its receipts.
    private static func attemptResults(_ c: Context) throws {
        for task in try tasks(c) where task.body["kind"] as? String == "coding" {
            guard let session = task.body["codingSessionID"] as? String, UUID(uuidString: session) != nil, UUID(uuidString: task.id) != nil else { continue }
            let projects = c.worker.appendingPathComponent("Tasks/\(task.id)/Claude/projects", isDirectory: true)
            var said: [(at: Date, text: String)] = []
            for folder in (try? FileManager.default.contentsOfDirectory(atPath: projects.path)) ?? [] {
                guard let data = try? String(contentsOf: projects.appendingPathComponent(folder).appendingPathComponent(session + ".jsonl"), encoding: .utf8) else { continue }
                for line in data.split(separator: "\n") {
                    guard let value = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any], value["type"] as? String == "assistant",
                          let at = date(value["timestamp"] as? String), let message = value["message"] as? [String: Any] else { continue }
                    let text: String
                    if let plain = message["content"] as? String { text = plain }
                    else { text = (message["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n") }
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { said.append((at, text)) }
                }
            }
            for attempt in try c.db.rows("SELECT n, started_at, ended_at FROM attempts WHERE task_id = ? AND result IS NULL ORDER BY n", [.text(task.id)]) {
                guard let n = attempt[0].int, let start = date(attempt[1].string), let end = date(attempt[2].string) else { continue }
                guard let last = said.filter({ $0.at >= start && $0.at <= end.addingTimeInterval(5) }).max(by: { $0.at < $1.at }) else { continue }
                try c.db.run("UPDATE attempts SET result = ? WHERE task_id = ? AND n = ? AND result IS NULL", [.text(String(last.text.suffix(100_000))), .text(task.id), .int(n)])
            }
            let result = task.body["result"] as? String ?? ""
            let cut = result.range(of: receiptsMarker, options: .backwards)
            let before = cut.map { String(result[..<$0.lowerBound]) } ?? result, suffix = cut.map { String(result[$0.lowerBound...]) } ?? ""
            guard before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let newest = try c.db.rows("SELECT result FROM attempts WHERE task_id = ? AND result IS NOT NULL ORDER BY n DESC", [.text(task.id)]).compactMap { row -> String? in
                let text = row[0].string ?? "", own = text.range(of: receiptsMarker, options: .backwards).map { String(text[..<$0.lowerBound]) } ?? text
                return own.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : own.trimmingCharacters(in: .whitespacesAndNewlines)
            }.first
            guard let newest else { continue }
            var next = task.body
            next["result"] = newest + suffix
            try save(next, from: task.body, cause: "migration.attempt-results.v1", c)
        }
    }

    // MARK: MIG-5 supervisor-instructions-card.v1

    /// The setup assistant wrote "if in doubt, ask" lines into Chief's instructions, which make Chief stop to ask. They are the user's data, so they
    /// are never rewritten silently: one pending change (and its card) offers the instructions without them, plus the decide-by-default line.
    /// When Chief's learning suggested a revised text for the current instructions, the card starts from that text and says so.
    private static func instructionsCard(_ c: Context) throws {
        let workspace = try agents(c).workspace
        guard UUID(uuidString: workspace) != nil, let chief = try supervisor(c, workspace: workspace), let id = chief["id"] as? String, UUID(uuidString: id) != nil else { return }
        let name = (chief["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "the supervisor"
        // The instructions as they stand: the saved profile, any learned rewrite still in force, then any change not yet carried into the profile.
        var current = chief["description"] as? String ?? ""
        let record = ((try object(c.support, "agent-memory.json"))?["records"] as? [String: Any])?[workspace + ":" + id] as? [String: Any]
        let revision = chief["profileRevision"] as? Int ?? 0
        if let record, record["baseRevision"] as? Int == revision, let learned = record["instructions"] as? String { current = learned }
        if let row = try c.db.rows("SELECT new_value FROM setting_changes WHERE workspace = ? AND scope = 'agent' AND agent_id = ? AND field = 'instructions' AND adopter <> '' AND adopted = 0 AND status = 'applied' ORDER BY seq DESC LIMIT 1", [.text(workspace), .text(id)]).first,
           let text = BuddyAgentChanges.decode(row[0].string ?? "null") as? String { current = text }
        let found = sentences(current).filter { askFirst.firstMatch(in: $0.text, range: NSRange(location: 0, length: ($0.text as NSString).length)) != nil }
        guard !found.isEmpty else { return }
        guard try c.db.rows("SELECT 1 FROM setting_changes WHERE workspace = ? AND agent_id = ? AND field = 'instructions' AND source = 'migration:autonomy'", [.text(workspace), .text(id)]).isEmpty else { return }
        let suggestion = record.flatMap { r -> String? in
            guard let s = r["suggestedInstructions"] as? [String: Any], s["baseRevision"] as? Int == revision, let text = (s["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return text
        }
        let base = suggestion ?? current
        var kept = "", cursor = base.startIndex
        for sentence in sentences(base) {
            kept += base[cursor..<sentence.range.lowerBound]
            if askFirst.firstMatch(in: sentence.text, range: NSRange(location: 0, length: (sentence.text as NSString).length)) == nil { kept += base[sentence.range] }
            cursor = sentence.range.upperBound
        }
        kept += base[cursor...]
        kept = kept.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        let joiner = kept.isEmpty ? "" : ".!?".contains(kept.last ?? " ") ? " " : "\n"
        if kept.count + joiner.count + decideText.count > 1500 { kept = String(kept.prefix(max(0, 1500 - decideText.count - joiner.count - 1))) + "…" }
        let new = kept + joiner + decideText
        let quoted = found.map { "“" + clause($0.text) + "”" }.joined(separator: ", ")
        let lines = found.count == 1 ? "A line" : found.count <= 4 ? ["Two", "Three", "Four"][found.count - 2] + " lines" : "\(found.count) lines"
        // Only text the setup assistant wrote is said to be the assistant's.
        let fromSetup = ["setup", "team-brief"].contains(chief["profileSource"] as? String ?? "")
        var question = "\(lines) in \(name)'s instructions (\(quoted)) " + (found.count == 1 ? (fromSetup ? "was added by the setup assistant, not by you, and it makes" : "makes") : (fromSetup ? "were added by the setup assistant, not by you, and they make" : "make")) + " \(name) stop to ask."
        if suggestion != nil { question += " The new text also brings in the wording \(name) suggested from your messages." }
        question += found.count == 1 ? " Replace it with 'decide and keep work moving; purchases still need your OK'?" : " Replace them with 'decide and keep work moving; purchases still need your OK'?"
        let change = UUID().uuidString
        let seq = Int64(try c.db.rows("SELECT COALESCE(MAX(seq), 0) + 1 FROM setting_changes WHERE workspace = ?", [.text(workspace)]).first?.first?.int ?? 1)
        try c.db.run("INSERT INTO setting_changes(id, workspace, scope, agent_id, field, old_value, new_value, actor, source, quote, status, risk, adopter, adopted, seq, created_at, updated_at) VALUES(?, ?, 'agent', ?, 'instructions', ?, ?, 'migration', 'migration:autonomy', '', 'pending', 'confirm', ?, 0, ?, ?, ?)",
                     [.text(change), .text(workspace), .text(id), .text(BuddyAgentChanges.encode(current)), .text(BuddyAgentChanges.encode(new)), .text(BuddyAgentChanges.adopter(scope: "agent", field: "instructions")), .int(seq), .text(c.stamp), .text(c.stamp)])
        try c.db.run("INSERT OR IGNORE INTO decisions(id, workspace, agent_id, task_id, kind, title, question, label, payload, created_at, audience) VALUES(?, ?, ?, '', 'confirm', ?, ?, 'Allow', ?, ?, 'user')",
                     [.text("change:" + change), .text(workspace), .text(id), .text("Update \(name)'s instructions?"), .text(String(question.prefix(1200))), .text(try BuddyOperationsDB.encode(["changeId": change])), .text(c.stamp)])
    }
    /// The sentences of a text, each with its range including the space after it, so removing one leaves the rest as it was written.
    private static func sentences(_ text: String) -> [(text: String, range: Range<String.Index>)] {
        var out: [(text: String, range: Range<String.Index>)] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .bySentences) { sentence, _, enclosing, _ in
            if let sentence { out.append((sentence, enclosing)) }
        }
        return out
    }
    private static func clause(_ text: String) -> String {
        var out = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = out.last, ".!?".contains(last) { out.removeLast() }
        return out
    }
}
