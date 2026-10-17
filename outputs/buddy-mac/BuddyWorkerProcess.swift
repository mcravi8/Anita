import Foundation
import Security

@MainActor final class BuddyWorkerProcess {
    private var process: Process?
    private var input: FileHandle?
    private var lines = BuddyProtocolLines()
    private var next = 0
    private var pending: [Int: (Result<[String: Any], Error>) -> Void] = [:]
    private let resourceOverride: URL?
    private let runtimeOverride: URL?
    init(resource: URL? = nil, runtime: URL? = nil) { self.resourceOverride=resource; self.runtimeOverride=runtime }
    var onEvent: (([String: Any]) -> Void)?
    static var runtime: URL? {
        ["/usr/local/bin/node", "/opt/homebrew/bin/node"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map(URL.init(fileURLWithPath:))
    }
    static var resources: URL? {
        guard let bundle = Bundle.main.resourceURL else { return nil }
        let direct = bundle.appendingPathComponent("Worker", isDirectory: true)
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        let shared = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Worker", isDirectory: true)
        return FileManager.default.fileExists(atPath: shared.path) ? shared : nil
    }
    func launch(_ module: String, arguments: [String] = []) throws {
        guard let runtime = runtimeOverride ?? Self.runtime, let resource = resourceOverride ?? Self.resources?.appendingPathComponent(module), FileManager.default.fileExists(atPath: resource.path) else { throw BuddyWorkerFailure(message: "Install Node.js 22 or later and rebuild Buddy’s worker resources.") }
        let p = Process(), incoming = Pipe(), outgoing = Pipe()
        p.executableURL = runtime; p.arguments = [resource.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        for key in ["OPENAI_API_KEY", "ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "NODE_OPTIONS", "NODE_PATH", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY"] { environment.removeValue(forKey: key) }
        let working = resource.deletingLastPathComponent()
        environment["PWD"] = working.path; environment.removeValue(forKey: "OLDPWD")
        p.currentDirectoryURL = working
        p.environment = environment; p.standardInput = incoming; p.standardOutput = outgoing; p.standardError = FileHandle.nullDevice
        try p.run(); process = p; input = incoming.fileHandleForWriting
        let reader = outgoing.fileHandleForReading
        DispatchQueue.global(qos: .utility).async { BuddyPipeReader.read(reader) { data in DispatchQueue.main.async { [weak self] in self?.receive(data) } }; DispatchQueue.main.async { [weak self] in self?.ended() } }
    }
    func send(_ value: [String: Any]) throws {
        guard let input, process?.isRunning == true else { throw BuddyWorkerFailure(message: "The worker’s browser or Claude process stopped. Check the task before retrying.") }
        var data = try JSONSerialization.data(withJSONObject: value); data.append(10); try input.write(contentsOf: data)
    }
    func request(_ payload: [String: Any]) async throws -> [String: Any] {
        next += 1; let id = next; var value = payload; value["id"] = id
        return try await withCheckedThrowingContinuation { c in pending[id] = { c.resume(with: $0) }; do { try send(value) } catch { pending.removeValue(forKey: id)?(.failure(error)) } }
    }
    private func receive(_ data: Data) {
        for line in lines.append(data) {
            guard line.count <= 48*1024*1024, let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if let id = value["id"] as? Int, let callback = pending.removeValue(forKey: id) {
                if let error = value["error"] as? String { callback(.failure(BuddyWorkerFailure(message: error))) } else { callback(.success(value["result"] as? [String: Any] ?? [:])) }
            } else { onEvent?(value) }
        }
    }
    private func ended() { let callbacks = pending.values; pending.removeAll(); callbacks.forEach { $0(.failure(BuddyWorkerFailure(message: "The worker subprocess ended. Check the task’s last action before continuing."))) }; onEvent?(["type": "closed"]) }
    func close() { input?.closeFile(); input = nil; if process?.isRunning == true { process?.terminate() }; process = nil; ended() }
}

enum BuddyClaudeKey {
    static func read(_ workspace: String) -> String? {
        var result: CFTypeRef?
        let code = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: "app.buddy.claudeCredits", kSecAttrAccount: workspace, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne] as CFDictionary, &result)
        guard code == errSecSuccess, let data = result as? Data else { return nil }; return String(data: data, encoding: .utf8)
    }
    static func save(_ key: String?, workspace: String) throws {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: "app.buddy.claudeCredits", kSecAttrAccount: workspace]
        if let key {
            guard key.hasPrefix("sk-ant-"), key.count < 500 else { throw BuddyWorkerFailure(message: "Enter a Claude Console API key.") }
            let code = SecItemUpdate(query as CFDictionary, [kSecValueData: Data(key.utf8)] as CFDictionary)
            if code == errSecItemNotFound { var add = query; add[kSecValueData] = Data(key.utf8); add[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly; guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw BuddyWorkerFailure(message: "Couldn’t save the Claude key in Keychain.") } }
            else if code != errSecSuccess { throw BuddyWorkerFailure(message: "Couldn’t update the Claude key in Keychain.") }
        } else { let code = SecItemDelete(query as CFDictionary); guard [errSecSuccess, errSecItemNotFound].contains(code) else { throw BuddyWorkerFailure(message: "Couldn’t remove this Keychain connection.") } }
    }
}
