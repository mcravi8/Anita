import Foundation

@main struct ProcessCrashChecks {
    @MainActor static func require(_ value: Bool, _ message: String) { if !value { fputs("FAILED: \(message)\n", stderr); exit(1) } }
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("buddy-process-crash-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        BuddyWorkerProcess.logDirectory = root.appendingPathComponent("Worker")
        func helper(_ name: String, _ body: String) throws -> BuddyWorkerProcess {
            let script = root.appendingPathComponent(name); try Data(body.utf8).write(to: script)
            return BuddyWorkerProcess(resource: script, runtime: URL(fileURLWithPath: "/bin/sh"))
        }
        func failure(_ p: BuddyWorkerProcess) async -> String {
            do { _ = try await p.request(["command": "go"], timeout: 10); return "no failure" } catch { return error.localizedDescription }
        }

        // A helper that crashes after a request: the reason is saved privately and the message says how it ended.
        let crash = try helper("crash.sh", "read line\necho 'PRIVATE-TRACE: could not open the thing' >&2\nexit 3\n")
        try crash.launch("crash.sh")
        let message = await failure(crash)
        require(message.contains("(exit status 3)"), "the message says how the helper ended: \(message)")
        require(message.contains("Worker/crash-crash.sh.log"), "the message points to the crash log: \(message)")
        require(!message.contains("PRIVATE-TRACE"), "raw error output never goes into the message, which ends up in task records")
        let log = root.appendingPathComponent("Worker/crash-crash.sh.log")
        let text = try String(contentsOf: log, encoding: .utf8)
        require(text.contains("PRIVATE-TRACE: could not open the thing") && text.contains("exit status 3"), "the log has the last output and the status")
        let permissions = (try FileManager.default.attributesOfItem(atPath: log.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
        require(permissions == 0o600, "the log is private to the user (\(String(permissions, radix: 8)))")
        require(!crash.isRunning, "a helper that ended is not reported as running")

        // A helper that ends normally leaves no log and no scary detail.
        let calm = try helper("calm.sh", "read line\nexit 0\n")
        try calm.launch("calm.sh")
        let calmMessage = await failure(calm)
        require(calmMessage.hasPrefix("The worker subprocess ended."), "a clean exit has no status detail: \(calmMessage)")
        require(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Worker/crash-calm.sh.log").path), "a clean exit writes no crash log")

        // The log is replaced by the next crash, not appended forever.
        let again = try helper("crash.sh", "read line\necho 'SECOND-TRACE' >&2\nexit 4\n")
        try again.launch("crash.sh")
        _ = await failure(again)
        let second = try String(contentsOf: log, encoding: .utf8)
        require(second.contains("SECOND-TRACE") && !second.contains("PRIVATE-TRACE"), "the next crash replaces the log")
        print("PASS: crash reason saved privately, shown as an exit status, never as raw output; clean exits stay quiet; the log is replaced by the next crash")
    }
}
