import AppKit

@MainActor enum BuddyWorkerClient {
    static func recurringRequest(_ text:String)->Bool {
        let t=text.lowercased()
        guard t.range(of:#"\b(every|each) (morning|day|evening|night|week|monday|tuesday|wednesday|thursday|friday|saturday|sunday)|\b(daily|weekly|weekdays)\b"#,options:.regularExpression) != nil else { return false }
        guard t.range(of:#"\b(run|check|review|search|look|send|do|schedule|repeat|monitor|remind)\b"#,options:.regularExpression) != nil else { return false }
        return t.range(of:#"\b(if|example|hypothetical|would|could|should|pause|stop|cancel|delete|remove)\b|\?"#,options:.regularExpression)==nil
    }
    static var tools: [[String: Any]] { [["type": "function", "name": "buddy_start_background_task", "description": "Queue a durable background task for this agent, only when the user explicitly requests background work. The worker uses its own browser/files on this Mac and the selected AI provider. Return the accepted task ID/title; results and pending reviews appear in Background work.", "inputSchema": ["type": "object", "additionalProperties": false, "properties": ["title": ["type": "string"], "goal": ["type": "string"], "kind": ["type": "string", "enum": ["research", "applications", "email", "general"]]], "required": ["title", "goal", "kind"]]], routineTool] }
    static let routineTool:[String:Any] = ["type":"function","name":"buddy_manage_routine","description":"Save or manage a recurring task when the user requests it, e.g. run this every morning. Creation returns a durable routine ID and nextRun; never claim it is scheduled before saved=true. If unspecified, mornings mean 09:00 in this Mac's timezone. Preserve the user's task/context in goal. Email routines require a targeted Gmail query covering relevant invitations AND completion/rejection/follow-ups; native memory skips previously reviewed messages, retries incomplete reads, and carries the prior result forward. Include lookback window explicitly (e.g. newer_than:90d). This Mac must be awake and online; missed times catch up once. Pins the selected provider and its per-run budget when saved; no automatic provider switching, and existing external-action reviews. Weekdays: 1 Sunday through 7 Saturday. List to discover IDs before updating/pausing/removing an existing routine.","inputSchema":["type":"object","additionalProperties":false,"properties":["action":["type":"string","enum":["create","update","list","pause","resume","delete"]],"routineID":["type":"string"],"title":["type":"string"],"goal":["type":"string"],"kind":["type":"string","enum":["email","research","applications","general"]],"query":["type":"string"],"hour":["type":"integer","minimum":0,"maximum":23],"minute":["type":"integer","minimum":0,"maximum":59],"weekdays":["type":"array","items":["type":"integer","minimum":1,"maximum":7]],"timeZone":["type":"string"]],"required":["action"]]]
    static func call(support: URL, payload: [String: Any]) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { c in DispatchQueue.global(qos: .utility).async { do { c.resume(returning: try BuddyWorkerWire.call(support: support, request: payload)) } catch { c.resume(throwing: error) } } }
    }
    static func start(support: URL, workspace: String) async throws -> [String: Any] {
        if let result = try? await call(support: support, payload: ["workspace": workspace, "operation": "status"]) { return result }
        guard Bundle.main.bundleIdentifier == "app.buddy.desktop", let bundle = Bundle.main.resourceURL?.deletingLastPathComponent() else { throw BuddyWorkerFailure(message: "Start the isolated test worker explicitly.") }
        let executable = bundle.appendingPathComponent("Helpers/Buddy Worker.app/Contents/MacOS/BuddyWorker")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw BuddyWorkerFailure(message: "Buddy’s worker helper is missing. Rebuild the app.") }
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("app.buddy.worker.plist"), logs = support.appendingPathComponent("Worker", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let plist: [String: Any] = ["Label": "app.buddy.worker", "ProgramArguments": [executable.path, "--worker"], "RunAtLoad": true, "KeepAlive": ["SuccessfulExit": false], "ThrottleInterval": 30, "ProcessType": "Background", "LimitLoadToSessionType": "Aqua", "StandardErrorPath": logs.appendingPathComponent("service-error.log").path, "Umask": 0o077]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let domain = "gui/" + String(getuid())
        _ = try await command(["bootstrap", domain, url.path])
        _ = try await command(["kickstart", domain + "/app.buddy.worker"])
        for _ in 0..<40 {
            if let result = try? await call(support: support, payload: ["workspace": workspace, "operation": "status"]) { return result }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        let error = (try? String(contentsOf: logs.appendingPathComponent("startup-error.txt"), encoding: .utf8)) ?? "Buddy’s worker didn’t start. Try again from Background work."
        throw BuddyWorkerFailure(message: error)
    }
    private static func command(_ arguments: [String]) async throws -> Int32 {
        try await withCheckedThrowingContinuation { c in DispatchQueue.global(qos: .utility).async {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/launchctl"); p.arguments = arguments; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            do { try p.run(); p.waitUntilExit(); c.resume(returning: p.terminationStatus) } catch { c.resume(throwing: error) }
        } }
    }
    static func connectClaude(workspace: String) throws -> [String: Any] {
        let alert = NSAlert(); alert.messageText = "Connect Claude API credits"; alert.informativeText = "Paste a Claude Console API key. Buddy stores it in macOS Keychain. Each conversation turn or background task has an estimated spending limit. API credits are used before paid balance; disable Console auto-reload if you want to avoid purchased usage. The SDK limit is estimated and may be exceeded by the final request."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 370, height: 26)); field.placeholderString = "Claude Console API key"; alert.accessoryView = field
        alert.addButton(withTitle: "Connect"); alert.addButton(withTitle: "Cancel"); alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return ["cancelled": true] }
        try BuddyClaudeKey.save(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), workspace: workspace); field.stringValue = ""
        return ["connected": true]
    }
}
