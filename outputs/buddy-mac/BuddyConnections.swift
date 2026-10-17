import Foundation

struct BuddyConnection {
    let id: String
    let name: String
    let enabled: Bool
    let callable: Bool
    let tools: [[String: Any]]
    var readableTools: [String] { tools.compactMap { tool in
        guard tool["isReadOnly"] as? Bool == true, tool["isEnabled"] as? Bool != false else { return nil }
        return tool["name"] as? String
    } }
    var usableTools: [String] { tools.compactMap { tool in
        guard tool["isEnabled"] as? Bool != false, let name = tool["name"] as? String, !name.isEmpty else { return nil }
        return name
    } }
    var available: Bool { enabled && callable && !usableTools.isEmpty }
    var summary: [String: Any] { ["id": id, "name": name, "available": available, "readToolCount": readableTools.count, "actionToolCount": usableTools.count - readableTools.count] }
}

enum BuddyConnectionPolicy {
    static func configuration(catalog: [BuddyConnection], allowed: Set<String>) -> [String: Any] {
        var apps: [String: Any] = ["_default": ["enabled": false, "destructive_enabled": false, "open_world_enabled": false, "approvals_reviewer": "user", "default_tools_approval_mode": "prompt"]]
        for app in catalog {
            let permitted = allowed.contains(app.id) && app.available
            let readable = Set(app.readableTools)
            var tools: [String: [String: Any]] = [:]
            for tool in app.tools {
                guard let name = tool["name"] as? String else { continue }
                let enabled = permitted && app.usableTools.contains(name)
                tools[name] = ["enabled": enabled, "approval_mode": enabled && readable.contains(name) ? "auto" : "prompt"]
            }
            apps[app.id] = ["enabled": permitted, "default_tools_enabled": false, "destructive_enabled": permitted, "open_world_enabled": permitted, "approvals_reviewer": "user", "default_tools_approval_mode": "prompt", "tools": tools]
        }
        return apps
    }
    static func fingerprint(catalog: [BuddyConnection], allowed: Set<String>) -> String {
        "actions-v2:" + catalog.filter { allowed.contains($0.id) && $0.available }.sorted { $0.id < $1.id }.map { app in
            app.id + ":" + app.usableTools.sorted().map { $0 + (app.readableTools.contains($0) ? "=read" : "=review") }.joined(separator: ",")
        }.joined(separator: "|")
    }
}

@MainActor final class BuddyConnectionGrants {
    private struct SavedAccess: Codable {
        var version = 2
        var blocked: [String: [String]]
    }
    private struct InvalidSavedAccess: LocalizedError {
        var errorDescription: String? { "Buddy couldn’t read your saved connection settings. Access is paused until those settings can be restored." }
    }
    private let url: URL
    private var blocked: [String: [String]] = [:]
    private var invalidSavedAccess = false
    init(support: URL) {
        url = support.appendingPathComponent("connection-access.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            if let saved = try? JSONDecoder().decode(SavedAccess.self, from: data), saved.version == 2 {
                blocked = saved.blocked
            } else if (try? JSONDecoder().decode([String: [String]].self, from: data)) != nil {
                // Replace the previous opt-in defaults with the user's requested default-on policy.
                // Old absent grants were defaults, not explicit removals under this new policy.
                try JSONEncoder().encode(SavedAccess(blocked: [:])).write(to: url, options: .atomic)
            } else { invalidSavedAccess = true }
        } catch { invalidSavedAccess = true }
    }
    private func refresh() {
        guard FileManager.default.fileExists(atPath: url.path) else { blocked = [:]; invalidSavedAccess = false; return }
        do {
            let saved = try JSONDecoder().decode(SavedAccess.self, from: Data(contentsOf: url))
            guard saved.version == 2 else { throw InvalidSavedAccess() }
            blocked = saved.blocked; invalidSavedAccess = false
        } catch { invalidSavedAccess = true }
    }
    func allowed(for key: String, catalog: [BuddyConnection]) throws -> Set<String> {
        refresh()
        guard !invalidSavedAccess else { throw InvalidSavedAccess() }
        return Set(catalog.filter(\.available).map(\.id)).subtracting(blocked[key] ?? [])
    }
    func snapshot(workspace: String, agents: [String], catalog: [BuddyConnection]) throws -> [String: [String]] {
        try Dictionary(agents.map { ($0, Array(try allowed(for: workspace + ":" + $0, catalog: catalog)).sorted()) }, uniquingKeysWith: { first, _ in first })
    }
    func sharedAllowed(keys: [String], catalog: [BuddyConnection]) throws -> Set<String> {
        var shared = Set(catalog.filter(\.available).map(\.id))
        for key in keys { shared.formIntersection(try allowed(for: key, catalog: catalog)) }
        return shared
    }
    func set(key: String, connection: String, allowed: Bool) throws {
        refresh()
        guard !invalidSavedAccess else { throw InvalidSavedAccess() }
        var next = blocked
        var values = Set(next[key] ?? [])
        if allowed { values.remove(connection) } else { values.insert(connection) }
        if values.isEmpty { next.removeValue(forKey: key) } else { next[key] = values.sorted() }
        try JSONEncoder().encode(SavedAccess(blocked: next)).write(to: url, options: .atomic)
        blocked = next
    }
}
