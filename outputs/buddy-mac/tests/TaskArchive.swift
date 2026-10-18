import Foundation

@main struct TaskArchiveChecks {
    @MainActor static func require(_ value: Bool, _ message: String) { if !value { fputs("FAILED: \(message)\n", stderr); exit(1) } }
    static func task(_ i: Int, workspace: String, agent: String, status: String, routine: String? = nil, padding: Int = 0) -> [String: Any] {
        var job: [String: Any] = ["id": UUID().uuidString, "workspace": workspace, "agentId": agent, "requestId": "seed-\(i)", "title": "Task \(i)", "goal": "Do thing \(i)", "kind": "general", "provider": "chatgpt", "budgetUSD": 0, "status": status,
                                  "createdAt": String(format: "2026-01-01T00:%02d:%02dZ", (i / 60) % 60, i % 60), "result": "Result \(i)" + String(repeating: "x", count: padding)]
        if let routine { job["routineID"] = routine }
        return job
    }
    static func journal(_ directory: URL, _ tasks: [[String: Any]]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["version": 1, "paused": false, "tasks": tasks]).write(to: directory.appendingPathComponent("tasks.json"))
    }
    static func archives(_ directory: URL) throws -> [[[String: Any]]] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("tasks-archive-") }.sorted().map { name in
            let value = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent(name))) as! [String: Any]
            return value["tasks"] as! [[String: Any]]
        }
    }
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("buddy-task-archive-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let w = UUID().uuidString, a = UUID().uuidString

        // 1. A full history (what used to stop all background work for good): opening it archives the oldest finished tasks.
        let full = root.appendingPathComponent("full")
        var seeded: [[String: Any]] = []
        for i in 0..<400 { seeded.append(task(i, workspace: w, agent: a, status: "completed", routine: "hourly")) }
        for i in 400..<980 { seeded.append(task(i, workspace: w, agent: a, status: i < 405 ? "failed" : i % 7 == 0 ? "cancelled" : "completed")) }   // five old failures sit among the oldest tasks
        for i in 980..<990 { seeded.append(task(i, workspace: w, agent: a, status: "failed")) }
        for i in 990..<1000 { seeded.append(task(i, workspace: w, agent: a, status: "paused")) }
        try journal(full, seeded)
        let store = try BuddyWorkerStore(directory: full)
        require(store.jobs.count == 600, "the list is brought down to its working size (\(store.jobs.count))")
        let archived = try archives(full).flatMap { $0 }
        require(archived.count == 400, "the oldest finished tasks are in the archive (\(archived.count))")
        let originalIDs = Set(seeded.map { $0["id"] as! String }), keptIDs = Set(store.jobs.map { $0["id"] as! String }), archivedIDs = Set(archived.map { $0["id"] as! String })
        require(keptIDs.union(archivedIDs) == originalIDs && keptIDs.isDisjoint(with: archivedIDs), "every task is in exactly one place: nothing is lost or duplicated")
        require(archived.allSatisfy { ["completed", "cancelled"].contains($0["status"] as? String ?? "") }, "only finished tasks are archived")
        require(store.jobs.filter { ["failed", "paused"].contains($0["status"] as? String ?? "") }.count == 25, "tasks that need attention stay in the list, even the oldest")
        let newestRoutine = seeded.last { $0["routineID"] as? String == "hourly" }!["id"] as! String
        require(store.jobs.last { $0["routineID"] as? String == "hourly" }?["id"] as? String == newestRoutine, "the newest task of a routine stays, because the next run builds on its result")
        require(archived.first?["result"] as? String == "Result 0" && archived.last.map { ($0["id"] as! String) != newestRoutine } == true, "archived tasks keep their full content")
        let mode = (try FileManager.default.attributesOfItem(atPath: full.appendingPathComponent(try FileManager.default.contentsOfDirectory(atPath: full.path).first { $0.hasPrefix("tasks-archive-") }!).path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
        require(mode == 0o600, "the archive is private to the user")
        // New work is accepted again.
        let made = try store.create(workspace: w, agent: a, requestId: "after-archive", title: "New work", goal: "Do it", kind: "general", provider: "chatgpt", budget: 0)
        require(made["status"] as? String == "queued" && store.jobs.count == 601, "a new task can be created")
        let reopened = try BuddyWorkerStore(directory: full)
        require(reopened.jobs.count == 601, "the shorter list is what is saved")

        // 2. Creating a task archives too, once the list reaches the trigger, even if it was opened below it.
        let edge = root.appendingPathComponent("edge")
        try journal(edge, (0..<900).map { task($0, workspace: w, agent: a, status: "completed") })
        let atEdge = try BuddyWorkerStore(directory: edge)
        let edgeBefore = try archives(edge)
        require(atEdge.jobs.count == 900 && edgeBefore.isEmpty, "a list at the trigger is left alone when opened")
        _ = try atEdge.create(workspace: w, agent: a, requestId: "edge-1", title: "Edge", goal: "Do it", kind: "general", provider: "chatgpt", budget: 0)
        let edgeAfter = try archives(edge).flatMap { $0 }
        require(atEdge.jobs.count == 601 && edgeAfter.count == 300, "creating a task archives the oldest finished ones first")

        // 3. A heavy history is archived by size before the journal reaches its own limit.
        let heavy = root.appendingPathComponent("heavy")
        try journal(heavy, (0..<250).map { task($0, workspace: w, agent: a, status: "completed", padding: 110_000) })
        let big = try BuddyWorkerStore(directory: heavy)
        let before = try FileManager.default.attributesOfItem(atPath: heavy.appendingPathComponent("tasks.json").path)[.size] as! Int
        require(before > BuddyWorkerStore.archiveSizeTrigger, "the fixture is heavy (\(before) bytes)")
        _ = try big.create(workspace: w, agent: a, requestId: "heavy-1", title: "Heavy", goal: "Do it", kind: "general", provider: "chatgpt", budget: 0)
        let after = try FileManager.default.attributesOfItem(atPath: heavy.appendingPathComponent("tasks.json").path)[.size] as! Int
        require(big.jobs.count == 201 && after < before, "a heavy journal is cut down by size (\(before) -> \(after))")

        // 4. Without anything finished to archive, the old limit still protects the queue.
        let busy = root.appendingPathComponent("busy")
        try journal(busy, (0..<30).map { task($0, workspace: w, agent: a, status: "paused") })
        let stuck = try BuddyWorkerStore(directory: busy)
        do { _ = try stuck.create(workspace: w, agent: a, requestId: "busy-1", title: "Busy", goal: "Do it", kind: "general", provider: "chatgpt", budget: 0); require(false, "thirty unfinished tasks still block more") } catch {}
        print("PASS: full histories are archived without losing a task, attention and routine tasks stay, the archive is private, new work is accepted again, heavy journals shrink by size, and the unfinished-task limit still holds")
    }
}
