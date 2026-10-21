import Foundation
import Security

/// The last output a helper wrote to stderr. It is kept for a crash log, never put into task records, which are shown to the user.
final class BuddyErrorTail: @unchecked Sendable {
    private let lock = NSLock(); private var data = Data()
    func append(_ chunk: Data) { lock.lock(); data.append(chunk); if data.count > 32_768 { data = data.suffix(32_768) }; lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

@MainActor final class BuddyWorkerProcess {
    /// Where a helper that exits abnormally leaves its last error output (private to the user, replaced by the next crash).
    static var logDirectory: URL?
    private var errorTail = BuddyErrorTail()
    private var moduleName = ""
    private var process: Process?
    private var input: FileHandle?
    private var lines = BuddyProtocolLines()
    private var next = 0
    private var pending: [Int: (Result<[String: Any], Error>) -> Void] = [:]
    private let resourceOverride: URL?
    private let runtimeOverride: URL?
    init(resource: URL? = nil, runtime: URL? = nil) { self.resourceOverride=resource; self.runtimeOverride=runtime }
    var onEvent: (([String: Any]) -> Void)?
    var isRunning: Bool { process?.isRunning == true }
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
        let p = Process(), incoming = Pipe(), outgoing = Pipe(), errors = Pipe()
        moduleName = module; let tail = BuddyErrorTail(); errorTail = tail
        p.executableURL = runtime; p.arguments = [resource.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        for key in ["OPENAI_API_KEY", "ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "NODE_OPTIONS", "NODE_PATH", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY"] { environment.removeValue(forKey: key) }
        let working = resource.deletingLastPathComponent()
        environment["PWD"] = working.path; environment.removeValue(forKey: "OLDPWD")
        p.currentDirectoryURL = working
        p.environment = environment; p.standardInput = incoming; p.standardOutput = outgoing; p.standardError = errors
        try p.run(); process = p; input = incoming.fileHandleForWriting
        let errorReader = errors.fileHandleForReading
        DispatchQueue.global(qos: .utility).async { BuddyPipeReader.read(errorReader) { tail.append($0) } }
        let reader = outgoing.fileHandleForReading
        DispatchQueue.global(qos: .utility).async { BuddyPipeReader.read(reader) { data in DispatchQueue.main.async { [weak self] in guard self?.process === p else{return};self?.receive(data) } }; var status: Int32?, signalled = false; for _ in 0..<20 { if !p.isRunning { status = p.terminationStatus; signalled = p.terminationReason == .uncaughtSignal; break }; usleep(50_000) }; DispatchQueue.main.async { [weak self] in guard self?.process === p else{return};self?.process=nil;self?.input=nil;self?.ended(status: status, signalled: signalled) } }
    }
    func send(_ value: [String: Any]) throws {
        guard let input, process?.isRunning == true else { throw BuddyWorkerFailure(message: "The worker’s browser or Claude process stopped. Check the task before retrying.") }
        var data = try JSONSerialization.data(withJSONObject: value); data.append(10); try input.write(contentsOf: data)
    }
    func request(_ payload: [String: Any], timeout:TimeInterval?=nil) async throws -> [String: Any] {
        next += 1; let id = next; var value = payload; value["id"] = id
        let seconds=timeout ?? (payload["command"] as? String=="run" ? min(360,((payload["timeoutSeconds"] as? NSNumber)?.doubleValue ?? 120)+30):45)
        return try await withCheckedThrowingContinuation { c in
            var deadline:Task<Void,Never>?
            pending[id] = { deadline?.cancel();c.resume(with:$0) }
            deadline=Task { [weak self] in
                let duration=seconds.isFinite ? min(360,max(0.01,seconds)):45
                do {try await Task.sleep(nanoseconds:UInt64(duration*1_000_000_000))}catch{return}
                self?.pending.removeValue(forKey:id)?(.failure(BuddyWorkerFailure(message:"The operation stopped responding. Check its last result before trying again.")))
            }
            do { try send(value) } catch { pending.removeValue(forKey: id)?(.failure(error)) }
        }
    }
    private func receive(_ data: Data) {
        for line in lines.append(data) {
            guard line.count <= 48*1024*1024, let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if let id = value["id"] as? Int, let callback = pending.removeValue(forKey: id) {
                if let error = value["error"] as? String { callback(.failure(BuddyWorkerFailure(message: error))) } else { callback(.success(value["result"] as? [String: Any] ?? [:])) }
            } else { onEvent?(value) }
        }
    }
    private func ended(status: Int32? = nil, signalled: Bool = false) {
        var detail = ""
        if let status, status != 0 || signalled {
            detail = signalled ? " (stopped by signal \(status))" : " (exit status \(status))"
            if let name = writeCrashLog(status: status, signalled: signalled) { detail += ". Technical details were saved in Buddy’s support folder (Worker/\(name))" }
        }
        let callbacks = pending.values; pending.removeAll()
        callbacks.forEach { $0(.failure(BuddyWorkerFailure(message: "The worker subprocess ended\(detail). Check the task’s last action before continuing."))) }
        onEvent?(["type": "closed"])
    }
    private func writeCrashLog(status: Int32, signalled: Bool) -> String? {
        guard let directory = Self.logDirectory else { return nil }
        let name = "crash-" + moduleName.replacingOccurrences(of: "/", with: "_") + ".log"
        let text = "\(ISO8601DateFormatter().string(from: Date())) \(moduleName) \(signalled ? "signal" : "exit status") \(status)\n\n" + errorTail.text
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let url = directory.appendingPathComponent(name)
            try Data(text.utf8).write(to: url, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return name
        } catch { return nil }
    }
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
