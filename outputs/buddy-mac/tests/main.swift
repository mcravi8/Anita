import Foundation

func require(_ condition: Bool, _ message: String) {
    if !condition { fputs("FAILED: \(message)\n", stderr); exit(1) }
}
let sample = String(repeating: "🙂hello", count: 20_000)
let expected = try JSONSerialization.data(withJSONObject: ["id": 2, "result": ["text": sample]], options: [.sortedKeys])
let first = try JSONSerialization.data(withJSONObject: ["id": 1, "result": ["ready": true]])
var wire = first; wire.append(10); wire.append(expected); wire.append(10)
for size in [1, 7, 8_193, 65_536] {
    var parser = BuddyProtocolLines(), frames: [Data] = []
    var offset = 0
    while offset < wire.count {
        let end = min(offset + size, wire.count)
        frames += parser.append(wire.subdata(in: offset..<end)); offset = end
    }
    require(frames == [first, expected], "fragmented JSONL round-trip with chunk size \(size)")
}
var parser = BuddyProtocolLines()
require(parser.append(first).isEmpty, "partial frames must wait for the newline")
require(parser.append(Data([10])) == [first], "newline completes a partial frame")
print("PASS: fragmented UTF-8, large histories, multiple frames, and partial JSONL frames")

for event in [["turnId": "previous"], ["turn": ["id": "previous", "status": "completed"]], [:]] as [[String: Any]] {
    require(!BuddyTurnScope.matches(event, turnID: "retry"), "late or unscoped events must not affect a retry")
}
require(BuddyTurnScope.matches(["turnId": "retry", "delta": "hello"], turnID: "retry"), "current retry delta is routed")
require(BuddyTurnScope.matches(["turn": ["id": "retry", "status": "completed"]], turnID: "retry"), "current retry completion is routed")
print("PASS: late stopped-turn events are isolated from a new retry")

let mail = BuddyConnection(id: "mail", name: "Gmail", enabled: true, callable: true, tools: [
    ["name": "search", "isReadOnly": true, "isEnabled": true],
    ["name": "send", "isReadOnly": false, "isEnabled": true],
    ["name": "disabled_read", "isReadOnly": true, "isEnabled": false]
])
let drive = BuddyConnection(id: "drive", name: "Drive", enabled: true, callable: true, tools: [["name": "read", "isReadOnly": true]])
let unavailable = BuddyConnection(id: "unavailable", name: "Unavailable", enabled: true, callable: false, tools: [["name": "read", "isReadOnly": true]])
let catalog = [mail, drive, unavailable]
let denied = BuddyConnectionPolicy.configuration(catalog: catalog, allowed: [])
require((denied["_default"] as? [String: Any])?["enabled"] as? Bool == false, "unknown connections default off")
require((denied["mail"] as? [String: Any])?["enabled"] as? Bool == false, "unapproved connection disabled")
let selected = BuddyConnectionPolicy.configuration(catalog: catalog, allowed: ["mail", "unavailable"])
let mailPolicy = selected["mail"] as! [String: Any], tools = mailPolicy["tools"] as! [String: [String: Any]]
require(mailPolicy["enabled"] as? Bool == true, "selected reading connection enabled")
require(tools["search"]?["enabled"] as? Bool == true, "approved reading tool available")
require(tools["send"]?["enabled"] as? Bool == true && tools["send"]?["approval_mode"] as? String == "prompt", "sending enabled with human review")
require(tools["disabled_read"]?["enabled"] as? Bool == false, "disabled reading tool not re-enabled")
require((selected["drive"] as? [String: Any])?["enabled"] as? Bool == false, "other connection stays disabled")
require((selected["unavailable"] as? [String: Any])?["enabled"] as? Bool == false, "unavailable connection cannot be enabled")
require(BuddyConnectionPolicy.fingerprint(catalog: catalog, allowed: []) != BuddyConnectionPolicy.fingerprint(catalog: catalog, allowed: ["mail"]), "permission changes require a fresh thread policy")
require(BuddyConnectionPolicy.fingerprint(catalog: catalog, allowed: []) == BuddyConnectionPolicy.fingerprint(catalog: catalog, allowed: ["unavailable"]), "unavailable connection has no granted capability")
require(tools["search"]?["approval_mode"] as? String == "auto", "reading remains frictionless")
let actionOnly = BuddyConnection(id: "action-only", name: "Actions", enabled: true, callable: true, tools: [["name": "write", "isReadOnly": false, "isEnabled": true]])
require(actionOnly.available && actionOnly.readableTools.isEmpty, "action-only connection is usable")
let changedHint = BuddyConnection(id: "mail", name: "Gmail", enabled: true, callable: true, tools: [["name": "search", "isReadOnly": false, "isEnabled": true]])
require(BuddyConnectionPolicy.fingerprint(catalog: [mail], allowed: ["mail"]) != BuddyConnectionPolicy.fingerprint(catalog: [changedHint], allowed: ["mail"]), "changed capability or approval policy forks the thread")
print("PASS: per-agent connection/action policy and default-deny enforcement")

try MainActor.assumeIsolated {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("buddy-grants-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let grants = BuddyConnectionGrants(support: directory)
    require(try grants.allowed(for: "workspace-one:morgan", catalog: catalog) == ["mail", "drive"], "existing agent starts with every usable service")
    require(try grants.allowed(for: "workspace-one:new-agent", catalog: catalog) == ["mail", "drive"], "new agent starts with every usable service")
    try grants.set(key: "workspace-one:morgan", connection: "mail", allowed: false)
    try grants.set(key: "workspace-one:morgan", connection: "mail", allowed: false)
    let reopened = BuddyConnectionGrants(support: directory)
    require(try reopened.allowed(for: "workspace-one:morgan", catalog: catalog) == ["drive"], "removal persists without duplicates")
    require(try reopened.allowed(for: "workspace-one:atlas", catalog: catalog) == ["mail", "drive"], "removal does not affect another agent")
    require(try reopened.allowed(for: "workspace-two:morgan", catalog: catalog) == ["mail", "drive"], "workspace reset has independent defaults")
    let newService = BuddyConnection(id: "calendar", name: "Calendar", enabled: true, callable: true, tools: [["name": "read", "isReadOnly": true]])
    require(try reopened.allowed(for: "workspace-one:morgan", catalog: catalog + [newService]) == ["drive", "calendar"], "new connections default on without losing removals")
    require(try reopened.allowed(for: "workspace-one:morgan", catalog: [drive, unavailable]) == ["drive"], "temporarily unavailable services cannot execute")
    require(try reopened.allowed(for: "workspace-one:morgan", catalog: catalog) == ["drive"], "removed access stays removed when a service returns")
    require(try reopened.sharedAllowed(keys: ["workspace-one:morgan", "workspace-one:atlas"], catalog: catalog) == ["drive"], "group scope is the intersection of member access")
    require(try reopened.sharedAllowed(keys: ["workspace-one:atlas"], catalog: catalog) == ["mail", "drive"], "group restriction does not change other direct permissions")
    try reopened.set(key: "workspace-one:morgan", connection: "mail", allowed: true)
    require(try BuddyConnectionGrants(support: directory).allowed(for: "workspace-one:morgan", catalog: catalog) == ["mail", "drive"], "restoring access persists")
    let settings = directory.appendingPathComponent("connection-access.json")
    try JSONEncoder().encode(["workspace-one:morgan": [String]()]).write(to: settings, options: .atomic)
    require(try BuddyConnectionGrants(support: directory).allowed(for: "workspace-one:morgan", catalog: catalog) == ["mail", "drive"], "legacy opt-in defaults migrate to the requested default-on policy")
    try Data("corrupted settings".utf8).write(to: settings, options: .atomic)
    let corrupt = BuddyConnectionGrants(support: directory)
    var refusedCorruptState = false
    do { _ = try corrupt.allowed(for: "workspace-one:morgan", catalog: catalog) } catch { refusedCorruptState = true }
    require(refusedCorruptState, "unreadable settings must not silently erase removals")
    var refusedCorruptWrite = false
    do { try corrupt.set(key: "workspace-one:morgan", connection: "mail", allowed: true) } catch { refusedCorruptWrite = true }
    require(refusedCorruptWrite, "corrupt settings must not be overwritten by a permission change")
}
print("PASS: default-on access, new agents/connections, isolated durable removals, restoration, migration, and corrupted-settings handling")

let process = Process(), pipe = Pipe()
process.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
process.arguments = ["-c", "import os,time,json\nos.write(1,b'{\"id\":1,\"result\":{\"ready\":true}}\\n')\ntime.sleep(1)\ndata=(json.dumps({'id':2,'result':{'text':'🙂hello'*20000}},ensure_ascii=False)+'\\n').encode()\nfor i in range(0,len(data),1019): os.write(1,data[i:i+1019])"]
process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
let start = Date(); try process.run()
var firstLatency: Double?, stream = BuddyProtocolLines(), results: [Data] = []
BuddyPipeReader.read(pipe.fileHandleForReading) { data in
    if firstLatency == nil { firstLatency = Date().timeIntervalSince(start) }
    results += stream.append(data)
}
process.waitUntilExit()
require((firstLatency ?? 9) < 0.8, "short RPC response must not wait for the full buffer or EOF")
require(results.count == 2, "all pipe frames delivered")
let second = try JSONSerialization.jsonObject(with: results[1]) as! [String: Any]
require((second["result"] as? [String: String])?["text"] == sample, "large pipe response remains intact and ordered")
require(process.terminationStatus == 0, "fixture process completed")
print("PASS: short-response latency and large fragmented pipe delivery")
