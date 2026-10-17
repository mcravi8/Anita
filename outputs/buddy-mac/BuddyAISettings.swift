import Foundation

struct BuddyAIChoice: Codable, Equatable {
    var provider = "chatgpt"
    var chatgptEnabled = true
    var claudeEnabled = true
    var claudeBudgetUSD = 0.5
    var chatgptRevision = "initial"
    var claudeRevision = "initial"
    func enabled(_ provider: String) -> Bool { provider == "chatgpt" ? chatgptEnabled : provider == "claude" && claudeEnabled }
    func revision(_ provider: String) -> String { provider == "claude" ? claudeRevision : chatgptRevision }
}

@MainActor final class BuddyAISettings {
    private struct Saved: Codable { var version = 1; var workspaces: [String: BuddyAIChoice] = [:] }
    private let support: URL
    init(support: URL) { self.support = support }
    private var url: URL { support.appendingPathComponent("ai-providers.json") }
    private func saved() throws -> Saved {
        guard FileManager.default.fileExists(atPath: url.path) else { return Saved() }
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 1024*1024 else { throw BuddyFailure(message: "Provider settings are too large.") }
            let saved = try JSONDecoder().decode(Saved.self, from: data)
            guard saved.version == 1, saved.workspaces.allSatisfy({ UUID(uuidString: $0.key) != nil && ["chatgpt", "claude"].contains($0.value.provider) && $0.value.claudeBudgetUSD.isFinite && (0.1...10).contains($0.value.claudeBudgetUSD) }) else { throw BuddyFailure(message: "Invalid provider settings.") }
            return saved
        } catch { throw BuddyFailure(message: "Buddy couldn’t verify your AI settings. Restore ai-providers.json before reconnecting or starting work.") }
    }
    func current(_ workspace: String) throws -> BuddyAIChoice {
        guard UUID(uuidString: workspace) != nil else { throw BuddyFailure(message: "This workspace is unavailable.") }
        return try saved().workspaces[workspace] ?? BuddyAIChoice()
    }
    @discardableResult func update(_ workspace: String, provider: String? = nil, enabled: (String, Bool)? = nil, budget: Double? = nil) throws -> BuddyAIChoice {
        var saved = try self.saved(); var choice = try current(workspace)
        if let provider { guard ["chatgpt", "claude"].contains(provider) else { throw BuddyFailure(message: "Choose ChatGPT or Claude.") }; choice.provider = provider }
        if let budget { guard budget.isFinite, (0.1...10).contains(budget) else { throw BuddyFailure(message: "Choose a Claude limit between $0.10 and $10.") }; choice.claudeBudgetUSD = budget }
        if let (provider, value) = enabled {
            guard ["chatgpt", "claude"].contains(provider) else { throw BuddyFailure(message: "Unsupported provider.") }
            if provider == "chatgpt" { choice.chatgptEnabled = value; choice.chatgptRevision = UUID().uuidString }
            else { choice.claudeEnabled = value; choice.claudeRevision = UUID().uuidString }
        }
        saved.workspaces[workspace] = choice
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try JSONEncoder().encode(saved).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return choice
    }
}
