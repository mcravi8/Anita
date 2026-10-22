import AppKit
@main struct WorkerIntegration {
    @MainActor static func require(_ value: Bool, _ message: String) { if !value { fputs("FAILED: \(message)\n", stderr); exit(1) } }
    @MainActor static func main() async throws {
        // A fixture folder (.noindex): the worker runs its one-time data migrations on whatever support folder it starts with.
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("buddy-worker-integration-" + UUID().uuidString + ".noindex")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let workspace = UUID().uuidString, agent = UUID().uuidString
        try JSONSerialization.data(withJSONObject: ["conversationWorkspace": workspace, "hiddenAgents": [agent], "agents": [["id": agent, "name": "Check", "role": "Fixture", "description": "Inert verification", "tools": [:]]]]).write(to: support.appendingPathComponent("workspace.json"))
        let host = BuddyWorkerHost(support: support, executable: URL(fileURLWithPath: CommandLine.arguments[1]),makeBrowser:{BuddyWorkerProcess(resource:URL(fileURLWithPath:CommandLine.arguments[7]),runtime:URL(fileURLWithPath:CommandLine.arguments[3]))},makeCoding:{BuddyWorkerProcess(resource:URL(fileURLWithPath:CommandLine.arguments[2]),runtime:URL(fileURLWithPath:CommandLine.arguments[3]))},makeCodingShell:{BuddyWorkerProcess(resource:URL(fileURLWithPath:CommandLine.arguments[4]),runtime:URL(fileURLWithPath:CommandLine.arguments[5]))},makeClaude:{BuddyWorkerProcess(resource:URL(fileURLWithPath:CommandLine.arguments[6]),runtime:URL(fileURLWithPath:CommandLine.arguments[5]))},keyReader:{_ in "inert-fixture-key"})
        host.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer { host.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)) }
        let teamStatus = try await BuddyWorkerClient.call(support: support, payload: ["workspace": workspace, "operation": "team", "arguments": ["action": "status"]])
        require(teamStatus["workspace"] as? String == workspace && (teamStatus["profiles"] as? [[String: Any]])?.first?["id"] as? String == agent, "team preferences cross the real private IPC connection")
        require(teamStatus["error"] == nil && teamStatus["monitorError"] as? String == "", "healthy monitor diagnostics cannot be mistaken for a worker transport failure")
        let savedPreference = try await BuddyWorkerClient.call(support: support, payload: ["workspace": workspace, "operation": "team", "arguments": ["action": "set_proactive", "agentId": agent, "enabled": true]])
        require(savedPreference["saved"] as? Bool == true && savedPreference["proactive"] as? Bool == true, "saved team settings return a usable receipt through IPC")
        print("PASS: team preferences and saved proactive setting receipts through actual worker IPC")
        // Only Buddy's own processes may use the worker connection. Any other program run by the same user is turned away before a word is read.
        let outsider = Process(), heard = Pipe()
        outsider.executableURL = URL(fileURLWithPath: CommandLine.arguments[3])
        outsider.arguments = ["-c", #"""
import socket,sys
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM)
s.settimeout(5)
data=b''
try:
    s.connect(sys.argv[1])
    s.sendall(('{"operation":"status","workspace":"'+sys.argv[2]+'"}\n').encode())
    data=s.recv(65536)
except Exception:
    pass
sys.stdout.write('GOT:'+data.decode('utf-8','replace'))
"""#, BuddyWorkerWire.socketURL(support).path, workspace]
        outsider.standardOutput = heard
        try outsider.run()
        var outsiderWaits = 0
        while outsider.isRunning && outsiderWaits < 200 { outsiderWaits += 1; try await Task.sleep(nanoseconds: 50_000_000) }
        let outsiderSaid = String(decoding: heard.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        require(outsiderSaid.hasPrefix("GOT:") && !outsiderSaid.contains("{"), "another program on this Mac gets no answer from the worker: \(outsiderSaid)")
        let refusals = (try? String(contentsOf: support.appendingPathComponent("Worker/refused-peers.log"), encoding: .utf8)) ?? ""
        require(refusals.contains("pid "), "the refused connection is recorded for diagnosis: \(refusals)")
        let ownStatus = try await BuddyWorkerClient.call(support: support, payload: ["workspace": workspace, "operation": "status"])
        require(ownStatus["online"] as? Bool == true, "Buddy's own process still reaches the worker")
        print("PASS: peer authentication: a different program of the same user is refused and recorded, Buddy's own process is served")
        // Settings and rules on the person's word, over the same connection: the app fills in the actor and the person's message.
        func send(_ operation: String, _ arguments: [String: Any], actor: String?, text: String) async throws -> [String: Any] {
            var payload: [String: Any] = ["workspace": workspace, "operation": operation, "arguments": arguments]
            if let actor { payload["actorId"] = actor; payload["authorizedText"] = text }
            return try await BuddyWorkerClient.call(support: support, payload: payload)
        }
        func settings(_ arguments: [String: Any], actor: String? = nil, text: String = "") async throws -> [String: Any] { try await send("settings", arguments, actor: actor, text: text) }
        func rules(_ arguments: [String: Any], actor: String? = nil, text: String = "") async throws -> [String: Any] { try await send("rules", arguments, actor: actor, text: text) }
        func refused(_ arguments: [String: Any], actor: String? = nil, text: String = "", operation: String = "settings") async -> Bool {
            do { _ = try await send(operation, arguments, actor: actor, text: text); return false } catch { return true }
        }
        let ask = "Please call me Scout from now on, and keep me posted proactively"
        require(await refused(["action": "change", "field": "name", "value": "Scout"], actor: agent, text: ask), "a change with no quote is refused over IPC")
        require(await refused(["action": "change", "field": "name", "value": "Scout", "quote": "call me Captain please"], actor: agent, text: ask), "a quote that is not in the person’s message is refused over IPC")
        require(await refused(["action": "change", "field": "name", "value": "Scout", "quote": "call me Scout from now on"], actor: UUID().uuidString, text: ask), "an actor that is not an agent here is refused")
        let renamed = try await settings(["action": "change", "field": "name", "value": "Scout", "quote": "call me Scout from now on"], actor: agent, text: ask)
        require(renamed["saved"] as? Bool == true && renamed["canUndo"] as? Bool == true, "a quoted rename is saved with a receipt: \(renamed)")
        require(await refused(["action": "pending", "adopter": "page"], actor: agent, text: ask), "an agent cannot read or acknowledge what the page has to carry")
        let owed = try await settings(["action": "pending", "adopter": "page"])["changes"] as? [[String: Any]] ?? []
        require(owed.count == 1 && owed[0]["field"] as? String == "name" && owed[0]["new"] as? String == "Scout" && owed[0]["old"] as? String == "Check", "the page is owed exactly the rename, with old and new")
        let named = (try await BuddyWorkerClient.call(support: support, payload: ["workspace": workspace, "operation": "team", "arguments": ["action": "status"]]))["profiles"] as? [[String: Any]]
        require(named?.first?["name"] as? String == "Scout", "everything else in the worker already sees the new name before the page has carried it: \(String(describing: named))")
        _ = try await settings(["action": "adopt", "adopter": "page", "ids": owed.compactMap { $0["id"] as? String }])
        require((try await settings(["action": "pending", "adopter": "page"])["changes"] as? [[String: Any]])?.isEmpty == true, "an acknowledged change is no longer owed")
        let switchedOff = try await settings(["action": "change", "field": "tools.web", "value": "false", "quote": "turn off the web"], actor: agent, text: "Please turn off the web for me")
        require(switchedOff["saved"] as? Bool == true, "turning access off applies at once")
        let switchedOn = try await settings(["action": "change", "field": "tools.web", "value": "true", "quote": "turn the web back on"], actor: agent, text: "Now turn the web back on")
        require(switchedOn["saved"] as? Bool == false && switchedOn["needsConfirmation"] as? Bool == true, "turning access on waits: \(switchedOn)")
        let waitingStatus = try await BuddyWorkerClient.call(support: support, payload: ["workspace": workspace, "operation": "status"])
        let cards = (waitingStatus["decisions"] as? [[String: Any]] ?? []).filter { $0["kind"] as? String == "confirm" }
        require(cards.count == 1 && (cards[0]["payload"] as? [String: Any])?["changeId"] as? String == switchedOn["changeId"] as? String, "the waiting change is one card in the worker’s list of what needs the person")
        require(await refused(["action": "answer", "changeId": switchedOn["changeId"]!, "allow": true], actor: agent, text: "Yes allow it"), "the agent cannot answer its own request")
        let answered = try await settings(["action": "answer", "changeId": switchedOn["changeId"]!, "allow": true])
        require(answered["saved"] as? Bool == true, "the person allows it from the screen")
        let after = try await BuddyWorkerClient.call(support: support, payload: ["workspace": workspace, "operation": "status"])
        require((after["decisions"] as? [[String: Any]] ?? []).filter { $0["kind"] as? String == "confirm" }.isEmpty, "answering removes the card")
        let ruleText = "For the first three applications, send me the CV so I can check your work; then go ahead on your own"
        require(await refused(["action": "add", "rule": "Show the CV first", "then": "proceed", "reviewFirst": 3, "quote": "show me the cv"], actor: agent, text: ruleText, operation: "rules"), "a rule needs the person’s own words over IPC")
        let rule = try await rules(["action": "add", "rule": "Send the CV for checking before applying; after three approved, apply without asking.", "then": "proceed", "reviewFirst": 3, "quote": "send me the CV so I can check your work"], actor: agent, text: ruleText)
        require(rule["saved"] as? Bool == true && (rule["ruleId"] as? String)?.isEmpty == false, "a quoted rule is saved: \(rule)")
        let listedRules = try await rules(["action": "list"])["rules"] as? [[String: Any]] ?? []
        require(listedRules.count == 1 && listedRules[0]["needed"] as? Int == 3 && listedRules[0]["approved"] as? Int == 0 && listedRules[0]["earned"] as? Bool == false, "the screen lists the rule and its progress")
        let paused = try await rules(["action": "pause", "ruleId": rule["ruleId"]!])
        require(paused["saved"] as? Bool == true, "the person can pause it from the screen")
        let undoneName = try await settings(["action": "undo", "changeId": renamed["changeId"]!])
        require(undoneName["saved"] as? Bool == true, "the person can undo the rename from the screen")
        print("PASS: settings and rules on the person’s word over actual worker IPC: quotes checked, access increases wait for the person, the page is owed exactly what changed, everything else sees it at once")
        var request: [String: Any] = ["workspace": workspace, "operation": "create", "agentId": agent, "requestId": "once", "title": "Fixture report", "goal": "Create a private report", "kind": "research", "provider": "chatgpt", "budgetUSD": 0]
        let result = try await BuddyWorkerClient.call(support: support, payload: request), job = result["task"] as! [String: Any], id = job["id"] as! String
        let duplicate = try await BuddyWorkerClient.call(support: support, payload: request)
        require((duplicate["task"] as? [String: Any])?["id"] as? String == id, "IPC create retry does not duplicate a task")
        request = ["workspace": workspace, "operation": "detail", "taskId": id]
        var completed: [String: Any] = [:]
        for _ in 0..<150 {
            let detail = try await BuddyWorkerClient.call(support: support, payload: request)["task"] as! [String: Any]
            if detail["status"] as? String == "completed" { completed = detail; break }
            if detail["status"] as? String == "failed" { fputs("\(detail["progress"] ?? "failed")\n",stderr); break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        require(!completed.isEmpty, "worker executes a queued task through the real app-server protocol")
        require((completed["fileList"] as? [[String: Any]])?.contains { $0["path"] as? String == "fixture.md" } == true, "completed task has private file deliverable")
        let preview = try await BuddyWorkerClient.call(support: support, payload: ["workspace": workspace, "operation": "preview", "taskId": id, "path": "fixture.md"])
        require((preview["content"] as? String)?.contains("Background result") == true, "file preview comes from saved worker bytes")
        let resumed = try BuddyWorkerStore(directory: support.appendingPathComponent("Worker"))
        require(try resumed.job(id)["status"] as? String == "completed", "completed task survives service recreation")
        let routine=try await BuddyWorkerClient.call(support:support,payload:["workspace":workspace,"operation":"routine","agentId":agent,"requestId":"morning","arguments":["action":"create","title":"Morning research","goal":"Research the explicitly requested topic","kind":"research"]])
        let r=routine["routine"] as! [String:Any]
        require(routine["saved"] as? Bool==true && (r["nextRun"] as? String).flatMap{ISO8601DateFormatter().date(from:$0)} != nil,"chat scheduling tool reaches the real worker and returns a durable next-run receipt")
        let status=try await BuddyWorkerClient.call(support:support,payload:["workspace":workspace,"operation":"status"])
        require((status["routines"] as? [[String:Any]])?.count==1,"saved routines are discoverable in the actual background status API")
        _ = try await BuddyWorkerClient.call(support:support,payload:["workspace":workspace,"operation":"routine","agentId":agent,"arguments":["action":"pause","routineID":r["id"]!]])
        require(try BuddyRoutineStore(directory:support.appendingPathComponent("Worker")).routines.first?["status"] as? String=="paused","direct routine pause reaches durable storage")
        print("PASS: native IPC routine creation, actual next-run receipt, status discovery and durable pause")
        // "Switch all agents to Claude": the running worker moves the routine saved on ChatGPT to its agent's Claude model by itself. The agent
        // then goes back to ChatGPT remembering that Claude model, and is put back on Claude for the coding sessions below (a coding session runs
        // on the agent's own provider; ChatGPT coding is checked in tests/CodexCoding.swift).
        try BuddyAgentModels(support:support).setAll(workspace:workspace,selections:[agent:.init(provider:"claude",model:"claude-fixture-switched")])
        _ = try BuddyAISettings(support:support).update(workspace,teamSwitch:true)
        var moved:[String:Any]=[:]
        for _ in 0..<60 {moved=try BuddyRoutineStore(directory:support.appendingPathComponent("Worker")).routines.first ?? [:];if moved["provider"] as? String=="claude" {break};try await Task.sleep(nanoseconds:100_000_000)}
        require(moved["provider"] as? String=="claude" && moved["model"] as? String=="claude-fixture-switched","after a team switch the worker moves the saved routine to its agent's provider and model: \(moved)")
        try BuddyAgentModels(support:support).setAll(workspace:workspace,selections:[agent:.init(provider:"chatgpt",model:"",alternates:["claude":"claude-fixture-switched"])])
        print("PASS: the running worker moves a saved routine to its agent's new provider and model after a team switch")
        try BuddyAgentModels(support:support).set(workspace:workspace,agent:agent,selection:.init(provider:"claude",model:"claude-fixture-switched"))
        print("PASS: private Unix IPC, accepted/queued/running/completed worker journey, idempotent enqueue, subscription protocol, real saved file and preview, durable completion")
        func call(_ arguments:[String:Any],agentID:String?=nil,requestID:String="coding-once") async throws -> [String:Any] {
            try await BuddyWorkerClient.call(support:support,payload:["workspace":workspace,"operation":"coding","agentId":agentID ?? agent,"requestId":requestID,"arguments":arguments])
        }
        func wait(_ id:String,for status:String) async throws -> [String:Any] {
            for _ in 0..<150 {
                let value=try await call(["action":"status","taskId":id])["task"] as! [String:Any]
                if value["status"] as? String==status {return value}
                if value["status"] as? String=="failed" {fputs("Coding failure: \(value["progress"] ?? "")\n",stderr);break}
                try await Task.sleep(nanoseconds:100_000_000)
            };require(false,"coding task reaches \(status)");return [:]
        }
        let queued=try await call(["action":"start","title":"Coding fixture","goal":"Build and syntax-check the fixture."])["task"] as! [String:Any],codingID=queued["id"] as! String
        require(queued["provider"] as? String=="claude" && queued["model"] as? String=="claude-fixture-switched","an agent on Claude codes on Claude, on its Claude model: \(queued["provider"] ?? "") \(queued["model"] ?? "")")
        let same=try await call(["action":"start","title":"Coding fixture","goal":"Build and syntax-check the fixture."])["task"] as! [String:Any]
        require(same["id"] as? String==codingID,"coding enqueue is idempotent")
        let done=try await wait(codingID,for:"completed"),commands=done["commands"] as? [[String:Any]] ?? []
        require(commands.first?["exitCode"] as? Int==0,"actual sandboxed Node command returns a confirmed exit code")
        require(done["codingSessionID"] as? String=="4b088c90-af25-410c-8a7d-74d54e9c1cad","SDK session ID is stored for later continuation")
        require((done["result"] as? String)?.contains("Command receipts: 1 finished, 1 exited successfully")==true,"native receipts accompany the model summary")
        let codePreview=try await BuddyWorkerClient.call(support:support,payload:["workspace":workspace,"operation":"preview","taskId":codingID,"path":"index.js"])
        require((codePreview["content"] as? String)?.contains("fixture coding tool")==true,"coding deliverable is previewable from saved bytes")
        _ = try await call(["action":"continue","taskId":codingID,"goal":"Run the syntax check once more as this explicit follow-up."],requestID:"follow-up")
        let followed=try await wait(codingID,for:"completed")
        require(followed["attempt"] as? Int==2 && (followed["commands"] as? [[String:Any]])?.count==2,"completed coding session resumes saved SDK context for an explicit follow-up")
        // Files in a connected folder reach the project natively, however large; the model never sees their contents.
        let copySource=support.appendingPathComponent("Copy source"),dataset=Data((0..<2_500_000).map{UInt8(truncatingIfNeeded:$0 &* 7)})
        try FileManager.default.createDirectory(at:copySource.appendingPathComponent("data"),withIntermediateDirectories:true);try dataset.write(to:copySource.appendingPathComponent("data/prices.csv"))
        let connectedID=try BuddyProjectFiles(support:support).addFolder(workspace,to:copySource)["folderId"] as! String
        let copyTask=try await call(["action":"start","title":"Copy fixture","goal":"COPY_FIXTURE "+connectedID],requestID:"copy")["task"] as! [String:Any],copyID=copyTask["id"] as! String
        let copied=try await wait(copyID,for:"completed")
        require(try Data(contentsOf:support.appendingPathComponent("Worker/Tasks/"+copyID+"/Files/data/prices.csv"))==dataset,"a connected folder's file reaches the coding project byte for byte without passing through the model")
        require((copied["commands"] as? [[String:Any]])?.first?["output"] as? String=="2500000\n","a command in the project reads the copied file")
        require(try Data(contentsOf:copySource.appendingPathComponent("results/data/prices.csv"))==dataset,"a result saved from the project reaches the connected folder byte for byte")
        // Chatting with an agent renames it, teaches it preferences and bumps its revisions; none of that is a reason to stop what it is doing.
        let slow=try await call(["action":"start","title":"Slow fixture","goal":"SLOW_FIXTURE"],requestID:"slow")["task"] as! [String:Any],slowID=slow["id"] as! String
        for _ in 0..<100 {if (try await call(["action":"status","taskId":slowID])["task"] as! [String:Any])["status"] as? String=="running" {break};try await Task.sleep(nanoseconds:50_000_000)}
        var churn=try JSONSerialization.jsonObject(with:Data(contentsOf:support.appendingPathComponent("workspace.json"))) as! [String:Any]
        var churnAgents=churn["agents"] as! [[String:Any]]
        let churned=churnAgents.firstIndex(where:{$0["id"] as? String==agent})
        require(churned != nil,"the agent whose work is under way is in the workspace the test changes")
        if let i=churned {churnAgents[i]["name"]="Renamed while working";churnAgents[i]["description"]="New instructions.";churnAgents[i]["memoryRevision"]=99;churnAgents[i]["profileRevision"]=7;churnAgents[i]["learnedRules"]=[["instruction":"Be brief.","quote":"be brief please","at":"2026-10-19T00:00:00Z"]]}
        churn["agents"]=churnAgents;try JSONSerialization.data(withJSONObject:churn).write(to:support.appendingPathComponent("workspace.json"),options:.atomic)
        var sawPaused=false
        for _ in 0..<200 {
            let status=(try await call(["action":"status","taskId":slowID])["task"] as! [String:Any])["status"] as? String
            if status=="paused" || status=="interrupted" {sawPaused=true;break}
            if status=="completed" {break}
            try await Task.sleep(nanoseconds:100_000_000)
        }
        require(!sawPaused,"renaming an agent or teaching it a preference does not pause the work it is doing")
        let slowDone=try await wait(slowID,for:"completed")
        require((slowDone["result"] as? String)?.contains("Implemented the fixture")==true && (slowDone["commands"] as? [[String:Any]])?.first?["exitCode"] as? Int==0,"nor is its next command refused: \(slowDone["result"] ?? "")")
        let net=try await call(["action":"start","title":"Network review fixture","goal":"NETWORK_REVIEW_FIXTURE"],requestID:"network")["task"] as! [String:Any],netID=net["id"] as! String
        _ = try await wait(netID,for:"waiting_review")
        let pending=try await BuddyWorkerClient.call(support:support,payload:["workspace":workspace,"operation":"detail","taskId":netID])["task"] as! [String:Any],review=(pending["reviews"] as! [[String:Any]]).last!
        let output=support.appendingPathComponent("Worker/Tasks/"+netID+"/Files/reviewed.txt")
        require(!FileManager.default.fileExists(atPath:output.path),"internet command cannot run before native review")
        _ = try await BuddyWorkerClient.call(support:support,payload:["workspace":workspace,"operation":"review","taskId":netID,"id":review["id"]!,"accept":true])
        _ = try await wait(netID,for:"completed")
        let approved=try await BuddyWorkerClient.call(support:support,payload:["workspace":workspace,"operation":"detail","taskId":netID])["task"] as! [String:Any]
        require(try String(contentsOf:output,encoding:.utf8)=="approved","exact reviewed command runs after approval")
        require((approved["reviews"] as? [[String:Any]])?.last?["status"] as? String=="completed","review completion is backed by command receipt")
        let checkpoint=try await call(["action":"start","title":"Input fixture","goal":"CHECKPOINT_FIXTURE"],requestID:"input")["task"] as! [String:Any],inputID=checkpoint["id"] as! String
        _ = try await wait(inputID,for:"waiting_user")
        var accounted=false
        for _ in 0..<50 {let task=try await BuddyWorkerClient.call(support:support,payload:["workspace":workspace,"operation":"detail","taskId":inputID])["task"] as! [String:Any];if (task["remainingBudgetUSD"] as? Double ?? 0)>0 {accounted=true;break};try await Task.sleep(nanoseconds:100_000_000)}
        require(accounted,"input checkpoint lets the SDK finish and confirm remaining budget")
        _ = try await call(["action":"continue","taskId":inputID,"goal":"Implement the explicit follow-up feature."],requestID:"input-follow-up")
        _ = try await wait(inputID,for:"completed")

        // A stop that is only technical is not a reason to wait for the person: it is recorded with its cause, and Buddy tries again by itself a bounded
        // number of times. These run through the real worker, socket and coding bridge protocol.
        func poll(_ id:String,_ label:String,tries:Int=240,_ done:([String:Any])->Bool) async throws -> [String:Any] {
            for _ in 0..<tries {
                let value=try await call(["action":"status","taskId":id])["task"] as! [String:Any]
                if done(value) {return value}
                try await Task.sleep(nanoseconds:50_000_000)
            }
            let last=try await call(["action":"status","taskId":id])["task"] as! [String:Any]
            require(false,"\(label) (last seen: \(last["status"] ?? "") / \(last["stopCause"] ?? "-") / \(last["progress"] ?? ""))");return [:]
        }
        func recoveryOf(_ job:[String:Any])->[String:Any] {job["recovery"] as? [String:Any] ?? [:]}
        func settled(_ job:[String:Any])->Bool {["completed","failed","paused","interrupted","waiting_user","cancelled"].contains(job["status"] as? String ?? "")}
        func commandDone(_ job:[String:Any])->Bool {job["status"] as? String=="running" && (job["commands"] as? [[String:Any]])?.first?["status"] as? String=="completed"}
        func start(_ goal:String,_ request:String) async throws -> String {(try await call(["action":"start","title":"Recovery fixture","goal":goal],requestID:request)["task"] as! [String:Any])["id"] as! String}
        func setTools(_ tools:[String:Bool]) throws {
            var saved=try JSONSerialization.jsonObject(with:Data(contentsOf:support.appendingPathComponent("workspace.json"))) as! [String:Any]
            var list=saved["agents"] as! [[String:Any]]
            if let i=list.firstIndex(where:{$0["id"] as? String==agent}) {list[i]["tools"]=tools}
            saved["agents"]=list;try JSONSerialization.data(withJSONObject:saved).write(to:support.appendingPathComponent("workspace.json"),options:.atomic)
        }
        // 1. Three silent minutes: the attempt is stopped as a stall, queued for a retry, and the retry finishes.
        let stallID=try await start("STALL_FIXTURE","stall")
        _ = try await poll(stallID,"the silent attempt starts"){$0["status"] as? String=="running" && $0["codingSessionID"] != nil}
        host.testingAgeActivity(by:181)
        let stalled=try await poll(stallID,"a silent attempt is stopped"){settled($0)}
        require(stalled["status"] as? String=="interrupted" && stalled["stopCause"] as? String=="stall" && recoveryOf(stalled)["cause"] as? String=="stall" && recoveryOf(stalled)["state"] as? String=="pending","a stall is recorded as a stall and waits for its retry: \(stalled["status"] ?? "") \(stalled["stopCause"] ?? "-") \(recoveryOf(stalled))")
        BuddyRecovery.delayScale=0.001
        let unstalled=try await poll(stallID,"the stalled task tries again by itself and finishes"){$0["status"] as? String=="completed"}
        BuddyRecovery.delayScale=1
        require(unstalled["attempt"] as? Int==2 && (unstalled["result"] as? String)?.contains("Recovered") == true,"the retry is a second attempt that finished: \(unstalled["attempt"] ?? "") \(unstalled["result"] ?? "")")
        require((unstalled["updates"] as? [String])?.last?.hasPrefix("Continue the same brief. The last attempt stopped because:")==true && (unstalled["stopCause"] as? String ?? "").isEmpty,"the retry is told why the last attempt stopped, and the cause is cleared once it carries on")
        print("PASS: a stalled attempt is stopped with its cause, waits its delay, and is resumed by itself to completion")
        // 2. The step cap is not the end of the work: it carries on by itself.
        let cappedID=try await start("MAXTURNS_FIXTURE","max-turns")
        let carried=try await poll(cappedID,"a task that hit its step cap carries on by itself"){$0["status"] as? String=="completed"}
        require(carried["attempt"] as? Int==2 && recoveryOf(carried)["cause"] as? String=="max_turns" && recoveryOf(carried)["tries"] as? Int==1,"one automatic continuation after the step cap: \(carried["attempt"] ?? "") \(recoveryOf(carried))")
        print("PASS: the step cap is continued automatically, counted once")
        // 3. The daily limit reached mid-run is a pause that ends by itself once there is room, not a failure.
        func limit(_ amount:Any) async throws {_ = try await BuddyWorkerClient.call(support:support,payload:["workspace":workspace,"operation":"limit","scope":"agent","agentId":agent,"amountUSD":amount])}
        try await limit(1.0)
        BuddyRecovery.limitPassInterval=0.5
        let limitedID=try await start("LIMIT_FIXTURE","limit")
        let limited=try await poll(limitedID,"a mid-run daily limit pauses the task"){settled($0)}
        require(limited["status"] as? String=="paused" && limited["blockedBy"] as? String=="limit" && limited["stopCause"] as? String=="limit" && (limited["progress"] as? String)?.contains("is used up. It continues by itself tomorrow, or as soon as the limit is raised.")==true,"the limit is a resumable pause with a plain reason: \(limited["status"] ?? "") \(limited["blockedBy"] ?? "-") \(limited["progress"] ?? "")")
        try await Task.sleep(nanoseconds:1_500_000_000)
        require((try await call(["action":"status","taskId":limitedID])["task"] as! [String:Any])["status"] as? String=="paused","with no room left it stays paused")
        try await limit(5.0)
        let roomAgain=try await poll(limitedID,"raising the limit lets it continue by itself"){$0["status"] as? String=="completed"}
        require(roomAgain["attempt"] as? Int==2,"it continued in a second attempt")
        try await limit(NSNull())
        // The bridge says the limit was reached but none is set any more (it was removed meanwhile): still a pause, and it carries straight on.
        let unlimitedID=try await start("LIMIT_FIXTURE","limit-removed")
        let unlimited=try await poll(unlimitedID,"a limit stop with no limit left carries on by itself"){settled($0) && $0["attempt"] as? Int==2}
        require(unlimited["status"] as? String=="completed","it continued instead of failing: \(unlimited["status"] ?? "") \(unlimited["progress"] ?? "")")
        BuddyRecovery.limitPassInterval=60
        print("PASS: a daily limit reached mid-run pauses with a plain reason and resumes by itself once the limit is raised")
        // 4. An attempt that streams its work and then ends without a summary keeps what it said, and its real error wins.
        let lostID=try await start("LOST_SUMMARY_FIXTURE","lost-summary")
        _ = try await poll(lostID,"the first attempt finishes"){$0["status"] as? String=="completed"}
        _ = try await call(["action":"continue","taskId":lostID,"goal":"Carry on with the explicit follow-up."],requestID:"lost-follow-up")
        let lost=try await poll(lostID,"the second attempt ends"){$0["attempt"] as? Int==2 && settled($0)}
        require((lost["result"] as? String)?.contains("streamed text")==true,"what the attempt said is kept as its result: \(lost["result"] ?? "")")
        require((lost["progress"] as? String)?.hasPrefix("Claude hit an error while working.")==true && (lost["progress"] as? String)?.contains("no final summary")==false,"the bridge's error is the reason shown, not a derived one: \(lost["progress"] ?? "")")
        _ = try await call(["action":"cancel","taskId":lostID])
        print("PASS: a streamed result survives an empty final summary, and the real error is the stop reason")
        // 5. Access: more access while working changes nothing; less access is a visible pause that ends by itself when access is back.
        try setTools(["desktop":false])
        let widenID=try await start("SLOW_FIXTURE","slow-widen")
        _ = try await poll(widenID,"the slow task runs its command"){commandDone($0)}
        try setTools([:])
        let widened=try await poll(widenID,"the widened task ends",tries:300){settled($0)}
        require(widened["status"] as? String=="completed","turning a tool on while an agent works does not stop it: \(widened["status"] ?? "") \(widened["progress"] ?? "")")
        let narrowID=try await start("SLOW_FIXTURE","slow-narrow")
        _ = try await poll(narrowID,"the slow task runs its command"){commandDone($0)}
        try setTools(["projectFiles":false])
        let narrowed=try await poll(narrowID,"reduced access pauses the task"){settled($0)}
        require(narrowed["status"] as? String=="paused" && narrowed["stopCause"] as? String=="access.narrowed" && recoveryOf(narrowed)["state"] as? String=="pending" && narrowed["progress"] as? String=="Paused: this agent's access was reduced while it worked. It continues when access is back.","reduced access is a visible pause with its cause: \(narrowed["status"] ?? "") \(narrowed["stopCause"] ?? "-") \(narrowed["progress"] ?? "")")
        try await Task.sleep(nanoseconds:1_500_000_000)
        require((try await call(["action":"status","taskId":narrowID])["task"] as! [String:Any])["status"] as? String=="paused","it stays paused while access is still reduced")
        try setTools([:])
        let restored=try await poll(narrowID,"restored access lets it continue by itself"){$0["status"] as? String=="completed"}
        require(restored["attempt"] as? Int==2,"it continued in a second attempt")
        print("PASS: widened access is adopted without a stop; narrowed access pauses visibly and resumes by itself when restored")
        // 6. A reconnect (a new provider revision) is not a stop; a disconnect is a pause that ends when the provider is back.
        let reconnectID=try await start("SLOW_FIXTURE","slow-reconnect")
        _ = try await poll(reconnectID,"the slow task runs its command"){commandDone($0)}
        _ = try BuddyAISettings(support:support).update(workspace,enabled:("claude",true))
        let reconnected=try await poll(reconnectID,"the reconnected task ends",tries:300){settled($0)}
        require(reconnected["status"] as? String=="completed","re-enabling Claude while it works does not stop the work: \(reconnected["status"] ?? "") \(reconnected["progress"] ?? "")")
        let disconnectID=try await start("SLOW_FIXTURE","slow-disconnect")
        _ = try await poll(disconnectID,"the slow task runs its command"){commandDone($0)}
        _ = try BuddyAISettings(support:support).update(workspace,enabled:("claude",false))
        let disconnected=try await poll(disconnectID,"a disconnect pauses the task"){settled($0)}
        require(disconnected["status"] as? String=="paused" && disconnected["stopCause"] as? String=="provider.disconnected" && disconnected["progress"] as? String=="Paused: Claude was disconnected. It continues by itself once reconnected.","a disconnect is a visible pause with its cause: \(disconnected["status"] ?? "") \(disconnected["stopCause"] ?? "-") \(disconnected["progress"] ?? "")")
        _ = try BuddyAISettings(support:support).update(workspace,enabled:("claude",true))
        _ = try await poll(disconnectID,"reconnecting lets it continue by itself"){$0["status"] as? String=="completed"}
        print("PASS: a reconnect keeps work running; a disconnect pauses visibly and resumes by itself once reconnected")
        // 7. A review left waiting is set aside when other work is queued, so one unanswered review does not hold every agent.
        BuddyWorkerHost.reviewParkAfter=1
        let parkID=try await start("NETWORK_REVIEW_FIXTURE","park-network")
        _ = try await poll(parkID,"the command waits for its review"){$0["status"] as? String=="waiting_review"}
        let nextID=try await start("SLOW_FIXTURE","park-slow")
        let parked=try await poll(parkID,"the waiting review is set aside"){$0["status"] as? String != "waiting_review"}
        require(parked["status"] as? String=="waiting_user" && parked["stopCause"] as? String=="review.parked" && parked["progress"] as? String=="Set aside so other work could run. Resume it when you can review the step it was waiting for.","the parked task says why and what to do: \(parked["status"] ?? "") \(parked["stopCause"] ?? "-") \(parked["progress"] ?? "")")
        _ = try await poll(nextID,"the queued task runs instead"){["running","completed"].contains($0["status"] as? String ?? "")}
        _ = try await poll(nextID,"the queued task finishes",tries:300){$0["status"] as? String=="completed"}
        BuddyWorkerHost.reviewParkAfter=600
        _ = try await call(["action":"cancel","taskId":parkID])
        print("PASS: a review left waiting is parked after its time when other work is queued, and the queue moves on")
        // 9 and 10. Pause all belongs to the person: an agent continuing its work does not lift it, and nothing restarts by itself while it holds.
        // A task left "running" with no attempt behind it is recognised as orphaned and recovered once the queue runs again.
        _ = try await BuddyWorkerClient.call(support:support,payload:["workspace":workspace,"operation":"pauseAll","paused":true])
        _ = try await call(["action":"continue","taskId":codingID,"goal":"Run the syntax check again as this explicit follow-up."],requestID:"paused-follow-up")
        require((try await BuddyWorkerClient.call(support:support,payload:["workspace":workspace,"operation":"status"]))["paused"] as? Bool==true,"an agent's coding continue does not lift the person's Pause all")
        let orphanID=try await start("Build and syntax-check the orphan fixture.","orphan")
        host.testingMarkRunning(orphanID)
        let orphaned=try await poll(orphanID,"a running task with no attempt is noticed"){$0["status"] as? String=="interrupted"}
        require(orphaned["stopCause"] as? String=="orphaned" && recoveryOf(orphaned)["state"] as? String=="pending","an orphan is recorded as such and queued for recovery: \(orphaned["stopCause"] ?? "-") \(recoveryOf(orphaned))")
        try await Task.sleep(nanoseconds:1_500_000_000)
        require((try await call(["action":"status","taskId":orphanID])["task"] as! [String:Any])["status"] as? String=="interrupted","nothing restarts by itself while everything is paused")
        _ = try await BuddyWorkerClient.call(support:support,payload:["workspace":workspace,"operation":"pauseAll","paused":false])
        _ = try await poll(codingID,"the continued task runs once the person resumes everything",tries:300){$0["status"] as? String=="completed" && $0["attempt"] as? Int==3}
        _ = try await poll(orphanID,"the orphan is recovered by itself",tries:300){$0["status"] as? String=="completed"}
        print("PASS: an agent's continue keeps Pause all; an orphaned task is recorded, held while paused, and recovered by itself afterwards")
        // 11. A task started while the team has a supervisor records who supervises it.
        _ = try await BuddyWorkerClient.call(support:support,payload:["workspace":workspace,"operation":"team","arguments":["action":"configure","supervisorId":agent]])
        let supervisedID=try await start("Build and syntax-check the supervised fixture.","supervised")
        let supervised=try await call(["action":"status","taskId":supervisedID])["task"] as! [String:Any]
        require(supervised["supervisorId"] as? String==agent,"the task records the team's supervisor: \(supervised["supervisorId"] ?? "none")")
        _ = try await poll(supervisedID,"the supervised task finishes",tries:300){$0["status"] as? String=="completed"}
        _ = try await BuddyWorkerClient.call(support:support,payload:["workspace":workspace,"operation":"team","arguments":["action":"configure","supervisorId":""]])
        print("PASS: a new task records the team's supervisor")

        // The team plan and the supervisor, through the real worker. A team: Lead supervises (the team's check-in policy names it), Forge and
        // Vera work. `raw` keeps a refusal's code, which the app-side client drops.
        func raw(_ payload: [String: Any]) async throws -> [String: Any] {
            let request = payload.merging(["workspace": workspace]) { old, _ in old }
            return try await withCheckedThrowingContinuation { c in DispatchQueue.global(qos: .utility).async {
                let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0); defer { Darwin.close(fd) }
                do {
                    var address = try BuddyWorkerWire.address(BuddyWorkerWire.socketURL(support)); BuddyWorkerWire.timeouts(fd)
                    let code = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
                    guard code == 0 else { throw BuddyFailure(message: "The worker is not listening.") }
                    try BuddyWorkerWire.send(request, to: fd); c.resume(returning: try BuddyWorkerWire.receive(fd))
                } catch { c.resume(throwing: error) }
            } }
        }
        let lead = UUID().uuidString, forge = UUID().uuidString, vera = UUID().uuidString, team = UUID().uuidString, side = UUID().uuidString
        var withTeam = try JSONSerialization.jsonObject(with: Data(contentsOf: support.appendingPathComponent("workspace.json"))) as! [String: Any]
        withTeam["agents"] = (withTeam["agents"] as! [[String: Any]]) + [["id": lead, "name": "Lead", "role": "Supervisor", "description": "Oversees the fixture team", "tools": [String: Bool]()],
                                                                           ["id": forge, "name": "Forge", "role": "Engineer", "description": "Builds fixtures", "tools": [String: Bool]()],
                                                                           ["id": vera, "name": "Vera", "role": "Researcher", "description": "Reviews fixtures", "tools": [String: Bool]()]]
        withTeam["groups"] = [["id": team, "name": "Fixture team", "members": [lead, forge, vera]], ["id": side, "name": "Side team", "members": [lead, vera]]]
        try JSONSerialization.data(withJSONObject: withTeam).write(to: support.appendingPathComponent("workspace.json"), options: .atomic)
        // Forge and Vera code on Claude here (the Claude coding fixture); a coding session runs on its agent's own provider.
        func onProvider(_ provider: String, _ members: [String]) throws { for member in members { try BuddyAgentModels(support: support).set(workspace: workspace, agent: member, selection: .initial(provider)) } }
        try onProvider("claude", [forge, vera])
        // Check-ins stay off, so no background check-in runs through these fixtures.
        _ = try await raw(["operation": "team", "arguments": ["action": "configure", "supervisorId": lead, "enabled": false]])
        func taskAs(_ owner: String, _ id: String) async throws -> [String: Any] { (try await call(["action": "status", "taskId": id], agentID: owner))["task"] as! [String: Any] }
        func pollAs(_ owner: String, _ id: String, _ label: String, tries: Int = 300, _ done: ([String: Any]) -> Bool) async throws -> [String: Any] {
            for _ in 0..<tries { let value = try await taskAs(owner, id); if done(value) { return value }; try await Task.sleep(nanoseconds: 50_000_000) }
            let last = try await taskAs(owner, id)
            require(false, "\(label) (last seen: \(last["status"] ?? "") / \(last["stopCause"] ?? "-") / \(last["progress"] ?? ""))"); return [:]
        }
        func startAs(_ owner: String, _ goal: String, _ request: String) async throws -> String { (try await call(["action": "start", "title": "Team fixture", "goal": goal], agentID: owner, requestID: request)["task"] as! [String: Any])["id"] as! String }
        func decisionsFor(_ id: String) async throws -> [[String: Any]] { (try await raw(["operation": "status"])["decisions"] as? [[String: Any]] ?? []).filter { $0["taskId"] as? String == id } }

        // 3. A question the agent may not decide goes to its supervisor, not to the person; what only the person can do in person goes to the person.
        let askID = try await startAs(forge, "REQUEST_DECISION_FIXTURE: build the report", "ask")
        let asked = try await pollAs(forge, askID, "a question for the supervisor ends the attempt") { settled($0) }
        let question = asked["checkpoint"] as? [String: Any] ?? [:]
        require(asked["status"] as? String == "waiting_user" && asked["stopCause"] as? String == "checkpoint.supervisor" && question["routedTo"] as? String == "supervisor" && question["category"] as? String == "approach"
                && question["recommendation"] as? String == "Use the 2015 data." && (question["options"] as? [String])?.count == 2,
                "the question is saved for the supervisor with its category, options and recommendation: \(asked["status"] ?? "") \(asked["stopCause"] ?? "-") \(question)")
        require((asked["progress"] as? String)?.hasPrefix("Waiting for Lead: Which data year") == true, "the task says whom it waits for: \(asked["progress"] ?? "")")
        let askDecisions = try await decisionsFor(askID)
        require(askDecisions.count == 1 && askDecisions[0]["kind"] as? String == "waiting" && askDecisions[0]["audience"] as? String == "supervisor", "the open question is the supervisor's to answer: \(askDecisions)")
        let signinID = try await startAs(forge, "SIGNIN_CHECKPOINT_FIXTURE: open the fixture site", "signin-need")
        let signin = try await pollAs(forge, signinID, "a sign-in checkpoint ends the attempt") { settled($0) }
        let need = signin["checkpoint"] as? [String: Any] ?? [:]
        // A coding session's commands can't use Chrome, so its sign-in is refused and it asks the person to save the file instead.
        require(signin["status"] as? String == "waiting_user" && need["need"] as? String == "file" && need["url"] as? String == "https://fixture.example/article/1" && need["path"] as? String == "sources/article.pdf" && need["routedTo"] as? String == "user", "a blocked download waits for the person to save the file, saying from which page and where: \(signin["status"] ?? "") \(need)")
        let signinDecisions = try await decisionsFor(signinID)
        require(signinDecisions.count == 1 && signinDecisions[0]["audience"] as? String == "user", "saving the file is the person's: \(signinDecisions)")
        // The same question from a research task on the ChatGPT protocol goes the same way.
        let generalID = ((try await raw(["operation": "create", "agentId": vera, "requestId": "ask-general", "title": "Research fixture", "goal": "REQUEST_DECISION_FIXTURE: research the topic", "kind": "research", "provider": "chatgpt", "budgetUSD": 0]))["task"] as! [String: Any])["id"] as! String
        var general: [String: Any] = [:]
        for _ in 0..<300 { general = (try await raw(["operation": "detail", "taskId": generalID]))["task"] as? [String: Any] ?? [:]; if settled(general) { break }; try await Task.sleep(nanoseconds: 50_000_000) }
        require(general["status"] as? String == "waiting_user" && general["stopCause"] as? String == "checkpoint.supervisor" && (general["checkpoint"] as? [String: Any])?["routedTo"] as? String == "supervisor",
                "a research task's question goes to the supervisor too: \(general["status"] ?? "") \(general["stopCause"] ?? "-") \(general["progress"] ?? "")")
        require(try await decisionsFor(generalID).first?["audience"] as? String == "supervisor", "and its open question is the supervisor's")
        print("PASS: a question an agent may not decide goes to its supervisor (coding and research tasks), and a sign-in it cannot do goes to the person")

        // 4. Who may act on whose task: the supervisor reads and continues a teammate's technically stopped task; a teammate who neither supervises
        // nor manages it may not; and nobody but the owner continues a task that waits for an answer.
        let stuckID = try await startAs(forge, "STALL_FIXTURE: the supervisor continues this", "stuck")
        _ = try await pollAs(forge, stuckID, "the silent attempt starts") { $0["status"] as? String == "running" && $0["codingSessionID"] != nil }
        host.testingAgeActivity(by: 181)
        let stuck = try await pollAs(forge, stuckID, "the silent attempt is stopped") { settled($0) }
        require(stuck["stopCause"] as? String == "stall", "the attempt stopped as a stall: \(stuck["stopCause"] ?? "-")")
        let peek = try await raw(["operation": "coding", "agentId": vera, "requestId": "peek", "arguments": ["action": "status", "taskId": stuckID]])
        let poke = try await raw(["operation": "coding", "agentId": vera, "requestId": "poke", "arguments": ["action": "continue", "taskId": stuckID, "goal": "SUPERVISOR_CONTINUE"]])
        require(peek["code"] as? String == "not_authorized" && peek["task"] == nil && poke["code"] as? String == "not_authorized", "a teammate who neither supervises nor manages Forge may not read or continue its task: \(peek) \(poke)")
        let seen = try await raw(["operation": "coding", "agentId": lead, "requestId": "look", "arguments": ["action": "status", "taskId": stuckID]])["task"] as? [String: Any] ?? [:]
        require(seen["id"] as? String == stuckID && seen["stopCause"] as? String == "stall", "the supervisor reads the teammate's task: \(seen["stopCause"] ?? "-")")
        let pushed = try await raw(["operation": "coding", "agentId": lead, "requestId": "push", "arguments": ["action": "continue", "taskId": stuckID, "goal": "SUPERVISOR_CONTINUE: carry on from the saved files."]])
        require(pushed["error"] == nil && (pushed["task"] as? [String: Any])?["status"] as? String == "queued", "the supervisor continues it: \(pushed)")
        let carriedOn = try await pollAs(forge, stuckID, "the continued task finishes") { $0["status"] as? String == "completed" }
        require(carriedOn["attempt"] as? Int == 2 && (carriedOn["updates"] as? [String])?.last?.hasPrefix("[From Lead, your supervisor] ") == true, "it carried on in a second attempt, told who asked: \(carriedOn["attempt"] ?? "") \(carriedOn["updates"] ?? "")")
        let skip = try await raw(["operation": "coding", "agentId": lead, "requestId": "skip", "arguments": ["action": "continue", "taskId": askID, "goal": "Never mind the question."]])
        require(skip["code"] as? String == "not_authorized", "a task waiting for an answer is not continued by someone else: \(skip)")
        print("PASS: the supervisor reads and continues a teammate's technically stopped task; a non-manager is refused with not_authorized")

        // 5. The pulse: who is working right now, and since when nothing is.
        let pulseID = try await startAs(vera, "SLOW_FIXTURE: a slow build", "pulse")
        var sawWorking = false
        for _ in 0..<300 {
            let pulse = (try await raw(["operation": "status"]))["pulse"] as? [String: Any] ?? [:]
            if ((pulse["agents"] as? [String: Any])?[vera] as? [String: Any])?["state"] as? String == "working" { sawWorking = pulse["idleSince"] is NSNull; break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        require(sawWorking, "the pulse shows the agent working while its task runs, and the team is not idle")
        _ = try await pollAs(vera, pulseID, "the slow task finishes") { $0["status"] as? String == "completed" }
        var quiet: [String: Any] = [:]
        for _ in 0..<100 { quiet = (try await raw(["operation": "status"]))["pulse"] as? [String: Any] ?? [:]; if quiet["idleSince"] is String { break }; try await Task.sleep(nanoseconds: 50_000_000) }
        let states = (quiet["agents"] as? [String: Any] ?? [:]).compactMapValues { ($0 as? [String: Any])?["state"] as? String }
        require(quiet["idleSince"] is String && states[vera] == "with_supervisor" && states[forge] == "needs_you" && states[lead] == "idle",
                "once it finished the team is idle since a time, and each agent says what it waits for: \(quiet["idleSince"] ?? "-") \(states)")
        print("PASS: the pulse shows who is working, and once nothing runs, since when the team is idle and what each agent waits for")

        // Set up once: the person's Chrome window on the one shared profile holds no agent's work. Every routine can still be run now; only
        // their pages wait for the window to close.
        func manageRoutine(_ owner: String, _ arguments: [String: Any]) async throws -> [String: Any] { try await raw(["operation": "routine", "agentId": owner, "requestId": UUID().uuidString, "arguments": arguments]) }
        try onProvider("chatgpt", [forge, vera])   // their routines are saved on ChatGPT, as before
        let forgeRoutine = ((try await manageRoutine(forge, ["action": "create", "title": "Forge research", "goal": "Research the explicitly requested topic", "kind": "research"]))["routine"] as? [String: Any])?["id"] as? String ?? ""
        let veraRoutine = ((try await manageRoutine(vera, ["action": "create", "title": "Vera research", "goal": "Research the explicitly requested topic", "kind": "research"]))["routine"] as? [String: Any])?["id"] as? String ?? ""
        require(!forgeRoutine.isEmpty && !veraRoutine.isEmpty, "both routines are saved")
        let opened = try await raw(["operation": "openGoogle"])
        require(opened["private"] as? Bool == true, "the shared Chrome window is open for setup: \(opened)")
        let ranOther = try await manageRoutine(forge, ["action": "run", "routineID": forgeRoutine])
        let ranOwn = try await manageRoutine(vera, ["action": "run", "routineID": veraRoutine])
        _ = try await raw(["operation": "finishSignIn"])
        for (owner, id) in [(forge, forgeRoutine), (vera, veraRoutine)] { _ = try await manageRoutine(owner, ["action": "pause", "routineID": id]) }
        require(ranOther["error"] == nil && (ranOther["task"] as? [String: Any])?["id"] is String, "a routine runs now while the shared Chrome window is open: \(ranOther)")
        require(ranOwn["error"] == nil && (ranOwn["task"] as? [String: Any])?["id"] is String, "so does every other agent's: \(ranOwn)")
        print("PASS: with the shared Chrome window open for setup, every routine can still be run now")

        // 1, 2, 6 and 8. The team plan over the socket: who may propose and authorize, exactly-once dispatch inside the authorized stage only,
        // keeping the Mac awake while authorized work is live, and the person's stop.
        func plan(_ arguments: [String: Any], actor: String? = nil, text: String = "", messageID: String? = nil) async throws -> [String: Any] {
            var payload: [String: Any] = ["operation": "plan", "requestId": UUID().uuidString, "arguments": arguments]
            if let actor { payload["actorId"] = actor; payload["authorizedText"] = text }
            if let messageID { payload["messageId"] = messageID }
            return try await raw(payload)
        }
        func planJobs() async throws -> [[String: Any]] { ((try await raw(["operation": "status"]))["tasks"] as? [[String: Any]] ?? []).filter { ($0["requestId"] as? String ?? "").hasPrefix("plan:") } }
        try onProvider("claude", [forge])   // the plan's coding task runs on Forge's provider, the Claude coding fixture
        let proposal: [String: Any] = ["action": "propose", "groupId": team, "objective": "Ship the fixture report",
                                       "stages": [["title": "Build", "goal": "Build the fixture", "acceptance": ["index.js passes node --check"]], ["title": "Polish", "goal": "Polish the fixture", "acceptance": ["README.md is written"]]],
                                       "tasks": [["stage": 1, "key": "t1", "title": "Build the fixture", "assignee": forge, "kind": "coding", "brief": "STALL_FIXTURE: build it and keep at it", "deliverable": "index.js"],
                                                 ["stage": 1, "key": "t2", "title": "Review the build", "assignee": vera, "kind": "research", "brief": "Review the build", "deliverable": "review.md", "dependsOn": ["t1"]],
                                                 ["stage": 2, "key": "t3", "title": "Write the README", "assignee": forge, "kind": "coding", "brief": "Write the README", "deliverable": "README.md"]]]
        let stranger = try await plan(proposal, actor: vera, text: "Plan the fixture report for the team")
        require(stranger["code"] as? String == "not_authorized" && stranger["plan"] == nil, "a teammate who neither supervises nor manages the group cannot propose its plan: \(stranger)")
        let drafted = try await plan(proposal, actor: lead, text: "Plan the fixture report for the team")
        let draft = drafted["plan"] as? [String: Any] ?? [:], planID = draft["id"] as? String ?? ""
        require(drafted["error"] == nil && draft["status"] as? String == "draft" && (drafted["menu"] as? String)?.contains("Which stage should the team get done") == true, "the supervisor's proposal is a draft that ends with the stage menu: \(drafted)")
        let draftStages = draft["stages"] as? [[String: Any]] ?? []
        func planTask(_ stage: Int, _ index: Int) -> String {
            guard stage < draftStages.count, let tasks = draftStages[stage]["tasks"] as? [[String: Any]], index < tasks.count else { return "" }
            return tasks[index]["id"] as? String ?? ""
        }
        let t1 = planTask(0, 0), t2 = planTask(0, 1), t3 = planTask(1, 0)
        require(!t1.isEmpty && !t2.isEmpty && !t3.isEmpty, "the draft lists its tasks by stage")
        require(!draftStages.contains { ($0["tasks"] as? [[String: Any]] ?? []).contains { $0["brief"] != nil } }, "plan replies carry the summary, never the task briefs")
        let looked = try await plan(["action": "get"], actor: lead, text: "How is the plan going?")
        require((looked["plan"] as? [String: Any])?["id"] as? String == planID && (looked["plans"] as? [[String: Any]])?.count == 1, "in a direct chat the supervisor gets the plan it supervises: \(looked)")
        let leadTeam = try await raw(["operation": "team", "actorId": lead, "arguments": ["action": "status"]]), veraTeam = try await raw(["operation": "team", "actorId": vera, "arguments": ["action": "status"]])
        require((leadTeam["plans"] as? [[String: Any]])?.contains { $0["id"] as? String == planID } == true && veraTeam["plans"] == nil, "the team status shows the supervisor its plans, and a teammate none: \(leadTeam["plans"] ?? "-") \(veraTeam["plans"] ?? "-")")
        try await Task.sleep(nanoseconds: 2_500_000_000)
        require(try await planJobs().isEmpty, "a draft starts nothing")
        let vague = try await plan(["action": "authorize", "planId": planID, "through": 1, "quote": "please plan it"], actor: lead, text: "please plan it")
        require(vague["code"] as? String == "not_authorized", "an agent cannot authorize a stage the user's message does not ask for: \(vague)")
        let worded = try await plan(["action": "authorize", "planId": planID, "through": 1, "quote": "get stage 1 done"], actor: lead, text: "Looks right. Please get stage 1 done.")
        let activePlan = worded["plan"] as? [String: Any] ?? [:]
        require(worded["error"] == nil && activePlan["status"] as? String == "active" && (activePlan["scope"] as? [String: Any])?["through"] as? Int == 1, "an agent quoting the user's own request authorizes stage 1: \(worded)")
        // The app passing on the person's own message (no actor, their words as the quote, the message's id) is the person authorizing.
        let native = try await plan(["action": "authorize", "planId": planID, "through": 1, "quote": "Looks right. Please get stage 1 done."], messageID: UUID().uuidString)
        let nativeScope = (native["plan"] as? [String: Any])?["scope"] as? [String: Any] ?? [:]
        require(native["error"] == nil && (nativeScope["through"] as? Int ?? 0) >= 1 && nativeScope["status"] as? String == "active", "the person's own words, passed on by the app, authorize: \(native)")
        var dispatched: [String: Any] = [:]
        let dispatchDeadline = Date().addingTimeInterval(5)
        while Date() < dispatchDeadline { if let found = try await planJobs().first(where: { $0["requestId"] as? String == "plan:\(t1):1" }) { dispatched = found; break }; try await Task.sleep(nanoseconds: 50_000_000) }
        require(dispatched["agentId"] as? String == forge && dispatched["planTaskId"] as? String == t1 && dispatched["planId"] as? String == planID && dispatched["reportsTo"] as? String == lead
                && dispatched["supervisorId"] as? String == lead && dispatched["kind"] as? String == "coding", "within 5 s the stage's first task is a worker task for its assignee, reporting to the supervisor: \(dispatched)")
        let t1Job = dispatched["id"] as? String ?? ""
        _ = try await pollAs(forge, t1Job, "the dispatched task starts") { $0["status"] as? String == "running" }
        require(host.testingHoldingAwake, "the Mac is kept awake while an authorized stage has live work")
        let leadList = (try await raw(["operation": "coding", "agentId": lead, "requestId": "list", "arguments": ["action": "status"]]))["tasks"] as? [[String: Any]] ?? []
        let veraList = (try await raw(["operation": "coding", "agentId": vera, "requestId": "list", "arguments": ["action": "status"]]))["tasks"] as? [[String: Any]] ?? []
        require(leadList.contains { $0["id"] as? String == t1Job } && !veraList.contains { $0["id"] as? String == t1Job }, "the supervisor's list includes the plan members' tasks; a teammate's does not")
        // The person's own path: proposed and authorized on screen, with no quote, and stopped by the person only.
        let sideDraft = try await plan(["action": "propose", "groupId": side, "objective": "Tidy the side notes",
                                        "stages": [["title": "Sort", "goal": "Sort the notes", "acceptance": ["notes are sorted"]], ["title": "Share", "goal": "Share the notes", "acceptance": ["notes are shared"]]], "tasks": [Any]()])
        let sideID = (sideDraft["plan"] as? [String: Any])?["id"] as? String ?? ""
        // The page's tap: no actor and no message behind it (with or without a quote of its own). The plan confirms it in chat.
        let sideOn = try await plan(["action": "authorize", "planId": sideID, "through": 1, "quote": "Tapped “Get stage 1 done”"])
        let sideScope = (sideOn["plan"] as? [String: Any])?["scope"] as? [String: Any] ?? [:], sideNotices = (sideOn["plan"] as? [String: Any])?["notices"] as? [[String: Any]] ?? []
        require(sideOn["error"] == nil && (sideOn["plan"] as? [String: Any])?["status"] as? String == "active" && (sideScope["quote"] as? String)?.hasPrefix("Tapped") == true
                && sideNotices.contains { $0["kind"] as? String == "authorized" && $0["chat"] as? Bool == true }, "the person's tap authorizes a stage and is confirmed in chat: \(sideOn)")
        let wordedNotices = ((try await plan(["action": "get", "planId": planID]))["plan"] as? [String: Any])?["notices"] as? [[String: Any]] ?? []
        require(wordedNotices.contains { $0["kind"] as? String == "authorized" && $0["chat"] as? Bool == false }, "an authorization passed on in a conversation is answered there, not repeated as a chat notice: \(wordedNotices)")
        let agentStop = try await plan(["action": "stop", "planId": sideID], actor: lead, text: "stop the side plan")
        require(agentStop["code"] as? String == "not_authorized", "only the person stops a plan: \(agentStop)")
        _ = try await plan(["action": "stop", "planId": sideID])
        let stoppedPlan = try await plan(["action": "stop", "planId": planID])
        require(stoppedPlan["error"] == nil && (stoppedPlan["plan"] as? [String: Any])?["status"] as? String == "holding", "the person stops the plan: \(stoppedPlan)")
        let pausedPlanTask = try await pollAs(forge, t1Job, "the live plan task is paused") { $0["status"] as? String == "paused" }
        require(pausedPlanTask["stopCause"] as? String == "user.plan_stop", "it is paused because the person stopped the plan: \(pausedPlanTask["stopCause"] ?? "-")")
        var letSleep = false
        for _ in 0..<100 { if !host.testingHoldingAwake { letSleep = true; break }; try await Task.sleep(nanoseconds: 50_000_000) }
        require(letSleep, "the Mac may sleep again once the plan holds")
        try await Task.sleep(nanoseconds: 2_500_000_000)
        let made = try await planJobs()
        require(made.count == 1 && made[0]["id"] as? String == t1Job, "nothing else was ever dispatched: no second task of stage 1 and no stage-2 task: \(made.map { $0["requestId"] ?? "" })")
        let shown = try await raw(["operation": "status"])
        require((shown["plans"] as? [[String: Any]])?.contains { $0["id"] as? String == planID && $0["status"] as? String == "holding" } == true && (shown["supervisorLane"] as? [String: Any])?["online"] is Bool
                && (shown["pulse"] as? [String: Any])?["queuePaused"] as? Bool == false, "the status reply carries the plans, the supervisor lane and the pulse")
        // "You can choose a stage again later": the person authorizes the stage again, and the run their stop paused goes on, with no second
        // worker task for it.
        let reauthorized = try await plan(["action": "authorize", "planId": planID, "through": 1, "quote": "Tapped “Get stage 1 done”"])
        require(reauthorized["error"] == nil && (reauthorized["plan"] as? [String: Any])?["status"] as? String == "active", "the person authorizes stage 1 again: \(reauthorized)")
        let goingOn = try await pollAs(forge, t1Job, "the run the stop paused goes on") { $0["status"] as? String != "paused" }
        require(["queued", "starting", "running"].contains(goingOn["status"] as? String ?? "") && (goingOn["stopCause"] as? String ?? "").isEmpty, "it is queued or running again: \(goingOn["status"] ?? "")")
        try await Task.sleep(nanoseconds: 2_500_000_000)
        let madeAgain = try await planJobs()
        require(madeAgain.count == 1 && madeAgain[0]["id"] as? String == t1Job, "and no second worker task is made for it: \(madeAgain.map { $0["requestId"] ?? "" })")
        for id in [askID, signinID, generalID, t1Job] { _ = try await raw(["operation": "cancel", "taskId": id]) }
        _ = try await raw(["operation": "team", "arguments": ["action": "configure", "supervisorId": "", "enabled": true]])
        print("PASS: the team plan through the worker: only the supervisor proposes, only the user's words or tap authorize, the stage's first task is dispatched once inside the stage, the Mac stays awake while it is live, the person's stop pauses it, and authorizing the stage again lets that run go on")

        // 7. A restart in the middle of an attempt: the next worker carries the same task on to completion by itself, and nobody is asked.
        let again = FileManager.default.temporaryDirectory.appendingPathComponent("buddy-worker-restart-" + UUID().uuidString + ".noindex")
        try FileManager.default.createDirectory(at: again, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: again) }
        let againSpace = UUID().uuidString, builder = UUID().uuidString
        try JSONSerialization.data(withJSONObject: ["conversationWorkspace": againSpace, "agents": [["id": builder, "name": "Builder", "role": "Fixture", "description": "Restart fixture", "tools": [String: Bool]()]]]).write(to: again.appendingPathComponent("workspace.json"))
        try BuddyAgentModels(support: again).set(workspace: againSpace, agent: builder, selection: .initial("claude"))   // codes on the Claude coding fixture
        func restartHost() -> BuddyWorkerHost { BuddyWorkerHost(support: again, executable: URL(fileURLWithPath: CommandLine.arguments[1]),makeBrowser:{BuddyWorkerProcess(resource:URL(fileURLWithPath:CommandLine.arguments[7]),runtime:URL(fileURLWithPath:CommandLine.arguments[3]))},makeCoding:{BuddyWorkerProcess(resource:URL(fileURLWithPath:CommandLine.arguments[2]),runtime:URL(fileURLWithPath:CommandLine.arguments[3]))},makeCodingShell:{BuddyWorkerProcess(resource:URL(fileURLWithPath:CommandLine.arguments[4]),runtime:URL(fileURLWithPath:CommandLine.arguments[5]))},makeClaude:{BuddyWorkerProcess(resource:URL(fileURLWithPath:CommandLine.arguments[6]),runtime:URL(fileURLWithPath:CommandLine.arguments[5]))},keyReader:{_ in "inert-fixture-key"}) }
        func codingAgain(_ arguments: [String: Any]) async throws -> [String: Any] { try await BuddyWorkerClient.call(support: again, payload: ["workspace": againSpace, "operation": "coding", "agentId": builder, "requestId": "restart", "arguments": arguments]) }
        let previous = restartHost()
        previous.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        let restartID = ((try await codingAgain(["action": "start", "title": "Restart fixture", "goal": "SLOW_FIXTURE across a restart"]))["task"] as! [String: Any])["id"] as! String
        var midway = false
        for _ in 0..<300 { if commandDone((try await codingAgain(["action": "status", "taskId": restartID]))["task"] as? [String: Any] ?? [:]) { midway = true; break }; try await Task.sleep(nanoseconds: 50_000_000) }
        require(midway, "the attempt is under way when the worker stops")
        previous.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        let successor = restartHost()
        successor.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer { successor.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)) }
        var restarted: [String: Any] = [:]
        for _ in 0..<300 { restarted = (try await codingAgain(["action": "status", "taskId": restartID]))["task"] as? [String: Any] ?? [:]; if ["completed", "failed", "cancelled"].contains(restarted["status"] as? String ?? "") { break }; try await Task.sleep(nanoseconds: 50_000_000) }
        let restartDecisions = ((try await BuddyWorkerClient.call(support: again, payload: ["workspace": againSpace, "operation": "status"]))["decisions"] as? [[String: Any]] ?? []).filter { $0["taskId"] as? String == restartID }
        require(restarted["status"] as? String == "completed" && restarted["attempt"] as? Int == 2 && (restarted["result"] as? String)?.contains("Recovered") == true && restartDecisions.isEmpty,
                "after the restart the task continued by itself in attempt 2 and finished, asking nobody: \(restarted["status"] ?? "") \(restarted["attempt"] ?? "") \(restarted["stopCause"] ?? "-") \(restartDecisions)")
        print("PASS: a worker restart in the middle of an attempt: the next worker continues the task by itself to completion, with no open decision")

        // With the agent's own provider off a coding session would move to the other one (tests/CodexCoding.swift); with neither it is refused.
        _ = try BuddyAISettings(support:support).update(workspace,enabled:("claude",false))
        _ = try BuddyAISettings(support:support).update(workspace,enabled:("chatgpt",false))
        do {_ = try await call(["action":"start","title":"Must not run","goal":"Claude is disconnected."],requestID:"disconnected");require(false,"disconnected coding must fail")}catch{}
        _ = try BuddyAISettings(support:support).update(workspace,enabled:("chatgpt",true))
        print("PASS: coding enqueue, real native file/command/preview, persistent SDK resume, budget accounting, exact internet-command review, and disconnected-provider rejection")
        try BuddyAgentModels(support:support).set(workspace:workspace,agent:agent,selection:.init(provider:"chatgpt",model:""))   // back on ChatGPT for the website tasks below
        _ = try await BuddyWorkerClient.call(support:support,payload:["workspace":workspace,"operation":"pauseAll","paused":true])
        func computer(_ args:[String:Any],owner:String?=nil,requestID:String="ordinary-website-request") async throws -> [String:Any] {
            try await BuddyWorkerClient.call(support:support,payload:["workspace":workspace,"operation":"computer","agentId":owner ?? agent,"requestId":requestID,"arguments":args])
        }
        let ordinary=try await computer(["action":"start","title":"Create AgentMail inbox","goal":"Open AgentMail and create an inbox in my existing account."])["task"] as! [String:Any],browserID=ordinary["id"] as! String
        require(ordinary["status"] as? String=="queued" && ordinary["provider"] as? String=="chatgpt","ordinary website request queues without background wording")
        let sameBrowser=try await computer(["action":"start","title":"Create AgentMail inbox","goal":"Open AgentMail and create an inbox in my existing account."])["task"] as! [String:Any]
        require(sameBrowser["id"] as? String==browserID,"unknown browser enqueue response is safe to retry")
        let listed=try await computer(["action":"status"])["tasks"] as! [[String:Any]]
        require(listed.contains{$0["id"] as? String==browserID} && listed.allSatisfy{$0["goal"]==nil && $0["reviews"]==nil},"task status exposes own non-coding records without review or brief payloads")
        let inspected=try await computer(["action":"status","taskId":browserID])["task"] as! [String:Any]
        require(inspected["status"] as? String=="queued" && inspected["pendingReviewCount"] as? Int==0,"queued receipt remains distinct from completed work")
        do {_ = try await computer(["action":"continue","taskId":browserID,"goal":"Do it again"]);require(false,"queued task must not be duplicated by continuation")}catch{}
        _ = try await BuddyWorkerClient.call(support:support,payload:["workspace":workspace,"operation":"pause","taskId":browserID])
        _ = try await computer(["action":"continue","taskId":browserID,"goal":"Use chief as the requested address."])
        require((try await BuddyWorkerClient.call(support:support,payload:["workspace":workspace,"operation":"status"]))["paused"] as? Bool==true,"an agent continuing its own website task does not lift the person's Pause all")
        let continued=try await computer(["action":"status","taskId":browserID])["task"] as! [String:Any]
        require((continued["updates"] as? [String])?.last=="Use chief as the requested address.","ordinary follow-up reuses the same task with missing details")
        _ = try await computer(["action":"cancel","taskId":browserID])
        _ = try await BuddyWorkerClient.call(support:support,payload:["workspace":workspace,"operation":"pauseAll","paused":true])
        do {_ = try await computer(["action":"status","taskId":codingID]);require(false,"browser tool cannot claim coding sessions")}catch{}
        let second=UUID().uuidString
        var fixture=try JSONSerialization.jsonObject(with:Data(contentsOf:support.appendingPathComponent("workspace.json"))) as! [String:Any]
        var agents=fixture["agents"] as! [[String:Any]];agents.append(["id":second,"name":"Other","tools":[:]]);fixture["agents"]=agents
        try JSONSerialization.data(withJSONObject:fixture).write(to:support.appendingPathComponent("workspace.json"),options:.atomic)
        for action in ["status","cancel","continue"] {
            do {_ = try await computer(["action":action,"taskId":browserID,"goal":"Not mine"],owner:second);require(false,"browser tool cannot inspect or control another agent's task")}catch{}
        }
        // Internet access (Web research) alone gives an agent Buddy's Chrome; Mac apps is about other apps on this Mac. (The other agent: the first
        // one's Web research was changed in chat earlier, and that change counts over the saved workspace.)
        let other=agents.count-1
        agents[other]["tools"]=["desktop":false];fixture["agents"]=agents;try JSONSerialization.data(withJSONObject:fixture).write(to:support.appendingPathComponent("workspace.json"),options:.atomic)
        let webOnly=try await computer(["action":"start","title":"Web only","goal":"Open a website"],owner:second,requestID:"web-only")["task"] as? [String:Any] ?? [:]
        require(webOnly["status"] as? String=="queued","an agent with Web research on and Mac apps off starts a website task: \(webOnly)")
        _ = try await computer(["action":"cancel","taskId":webOnly["id"] ?? ""],owner:second)
        agents[other]["tools"]=["web":false];fixture["agents"]=agents;try JSONSerialization.data(withJSONObject:fixture).write(to:support.appendingPathComponent("workspace.json"),options:.atomic)
        do {_ = try await computer(["action":"start","title":"Denied","goal":"Open a website"],owner:second,requestID:"denied");require(false,"an agent with Web research off gets no browser: revoked browser permission prevents enqueue")}catch{}
        agents[other]["tools"]=[String:Bool]()
        agents[0]["tools"]=[String:Bool]();fixture["agents"]=agents;try JSONSerialization.data(withJSONObject:fixture).write(to:support.appendingPathComponent("workspace.json"),options:.atomic)
        _ = try BuddyAISettings(support:support).update(workspace,enabled:("claude",true))
        _ = try BuddyAISettings(support:support).update(workspace,provider:"claude")
        try BuddyAgentModels(support:support).set(workspace:workspace,agent:agent,selection:.initial("claude"))
        _ = try BuddyAISettings(support:support).update(workspace,enabled:("chatgpt",false))
        let claudeBrowser=try await computer(["action":"start","title":"Claude website task","goal":"Open AgentMail in my browser."],requestID:"claude-browser")["task"] as! [String:Any]
        require(claudeBrowser["provider"] as? String=="claude" && claudeBrowser["status"] as? String=="queued","Claude website enqueue works with ChatGPT disconnected")
        _ = try await BuddyWorkerClient.call(support:support,payload:["workspace":workspace,"operation":"pauseAll","paused":false])
        var browserDone:[String:Any]=[:]
        for _ in 0..<120 {
            let value=try await computer(["action":"status","taskId":claudeBrowser["id"]!])["task"] as! [String:Any]
            if value["status"] as? String=="completed" {browserDone=value;break}
            if value["status"] as? String=="failed" {throw BuddyFailure(message:"Ordinary Claude runtime failed: \(value["progress"] ?? "")")}
            try await Task.sleep(nanoseconds:50_000_000)
        }
        require(browserDone["result"] as? String=="Opened the website and checked the observed session.","real ClaudeSession receives Swift's browser result with the same run ID")
        let browserFull=try await BuddyWorkerClient.call(support:support,payload:["workspace":workspace,"operation":"detail","taskId":claudeBrowser["id"]!])["task"] as! [String:Any]
        require(abs((browserFull["spentUSD"] as? Double ?? 0)-0.02)<0.0001 && (browserFull["remainingBudgetUSD"] as? Double ?? 0)>0,"completed browser attempt confirms usage instead of leaving a silent reservation")
        let observed=try await BuddyWorkerClient.call(support:support,payload:["workspace":workspace,"operation":"detail","taskId":claudeBrowser["id"]!])["task"] as! [String:Any]
        let browserEvents=observed["events"] as? [[String:Any]] ?? []
        require(browserEvents.contains{$0["tool"] as? String=="buddy_browser" && $0["status"] as? String=="completed"},"ordinary Claude browser calls have bounded native activity receipts")
        func fullTask(_ id:String) async throws -> [String:Any] {try await BuddyWorkerClient.call(support:support,payload:["workspace":workspace,"operation":"detail","taskId":id])["task"] as! [String:Any]}
        let checkpointBrowser=try await computer(["action":"start","title":"Inbox checkpoint fixture","goal":"BROWSER_CHECKPOINT_FIXTURE"],requestID:"browser-checkpoint")["task"] as! [String:Any],checkpointID=checkpointBrowser["id"] as! String
        var checkpointAccounted=false
        for _ in 0..<120 {
            let value=try await fullTask(checkpointID)
            if value["status"] as? String=="waiting_user",value["reservedBudgetUSD"] as? Double==0,(value["spentUSD"] as? Double ?? 0)>0 {
                require(BuddyRunLimit.isNone(value["remainingBudgetUSD"] as? Double ?? 0),"a task with no limit of its own is still not limited after a checkpoint");checkpointAccounted=true;break
            }
            try await Task.sleep(nanoseconds:50_000_000)
        }
        require(checkpointAccounted,"browser checkpoint lets the SDK return actual usage instead of being killed")
        _ = try await computer(["action":"continue","taskId":checkpointID,"goal":"CONTINUE_CHECKPOINT with the user's missing detail."],requestID:"checkpoint-continue")
        var checkpointFinished=false
        for _ in 0..<120 {
            let value=try await fullTask(checkpointID)
            if value["status"] as? String=="completed" {require(abs((value["spentUSD"] as? Double ?? 0)-0.05)<0.0001,"continuation preserves accumulated actual costs");checkpointFinished=true;break}
            try await Task.sleep(nanoseconds:50_000_000)
        }
        require(checkpointFinished,"ordinary browser task resumes from its confirmed unused allowance without another budget request")
        // A standing rule, end to end: the agent shows its work, the person's approvals are counted, and only then do browser steps go ahead unreviewed.
        let twoChecks = "For the first two applications, send me the CV so I can check your work; then apply on your own"
        let standing = try await BuddyWorkerClient.call(support: support, payload: ["workspace": workspace, "operation": "rules", "arguments": ["action": "add", "rule": "Send the CV for checking before applying; after two approved, apply without asking.", "then": "proceed", "reviewFirst": 2, "quote": "send me the CV"], "actorId": agent, "authorizedText": twoChecks])
        let standingID = standing["ruleId"] as! String
        func ruleTask(_ goal: String, _ request: String) async throws -> String {
            (try await computer(["action": "start", "title": "Apply to Acme", "goal": goal], requestID: request)["task"] as! [String: Any])["id"] as! String
        }
        func detail(_ id: String) async throws -> [String: Any] { try await BuddyWorkerClient.call(support: support, payload: ["workspace": workspace, "operation": "detail", "taskId": id])["task"] as! [String: Any] }
        func reach(_ id: String, _ status: String) async throws -> [String: Any] {
            for _ in 0..<200 {
                let value = try await detail(id)
                if value["status"] as? String == status { return value }
                if value["status"] as? String == "failed" { throw BuddyFailure(message: "Rule fixture failed: \(value["progress"] ?? "")") }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            require(false, "task reaches \(status)"); return [:]
        }
        func reviews(_ job: [String: Any], _ kind: String) -> [[String: Any]] { (job["reviews"] as? [[String: Any]] ?? []).filter { $0["kind"] as? String == kind } }
        for number in 1...2 {
            let id = try await ruleTask("RULES_FIXTURE apply \(number)", "rule-task-\(number)")
            let waiting = try await reach(id, "waiting_review")
            let check = reviews(waiting, "checkpoint")
            require(check.count == 1 && check[0]["status"] as? String == "pending" && reviews(waiting, "browser").isEmpty, "the agent shows its work before touching the form (task \(number))")
            let arguments = (check[0]["tool"] as? [String: Any])?["arguments"] as? [String: Any] ?? [:]
            require(arguments["summary"] as? String == "Here is the CV for Acme." && arguments["check"] as? Int == number && arguments["of"] as? Int == 2, "the card says what it is and which check it is: \(arguments)")
            let waitingStatus = try await BuddyWorkerClient.call(support: support, payload: ["workspace": workspace, "operation": "status"])
            require((waitingStatus["decisions"] as? [[String: Any]] ?? []).contains { $0["kind"] as? String == "review" && ($0["title"] as? String)?.hasPrefix("Check the work") == true }, "a check is one entry in what needs the person")
            _ = try await BuddyWorkerClient.call(support: support, payload: ["workspace": workspace, "operation": "review", "taskId": id, "id": check[0]["id"]!, "accept": true, "feedback": ""])
            let done = try await reach(id, "completed")
            require((done["result"] as? String)?.contains("check approved, performed 1") == true || (done["result"] as? String)?.contains("check approved, performed true") == true, "the form was filled after approval: \(done["result"] ?? "")")
            let acts = reviews(done, "browser")
            require(acts.count == 1 && acts[0]["autoApproved"] as? Bool == true && acts[0]["rule"] as? String == standingID && acts[0]["status"] as? String == "completed", "the step went ahead under the rule and is recorded as such, with its receipt: \(acts)")
            let counted = reviews(done, "checkpoint")[0]
            require(counted["status"] as? String == "answered" && counted["counted"] as? Int == number && counted["earned"] as? Bool == (number == 2), "the person’s approval was counted (\(number) of 2)")
        }
        let earnedNotice = (try await BuddyWorkerClient.call(support: support, payload: ["workspace": workspace, "operation": "status"])["decisions"] as? [[String: Any]] ?? []).filter { $0["kind"] as? String == "notice" }
        require(earnedNotice.count == 1 && (earnedNotice[0]["payload"] as? [String: Any])?["ruleId"] as? String == standingID, "the person is told once that the agent has earned it")
        let free = try await ruleTask("RULES_FIXTURE RULES_SKIP_CHECK apply three", "rule-task-3")
        let freeDone = try await reach(free, "completed")
        require(reviews(freeDone, "checkpoint").isEmpty && reviews(freeDone, "browser").count == 1 && reviews(freeDone, "browser")[0]["autoApproved"] as? Bool == true, "once earned, the next application needs no check and no per-step review")
        _ = try await BuddyWorkerClient.call(support: support, payload: ["workspace": workspace, "operation": "rules", "arguments": ["action": "pause", "ruleId": standingID]])
        let held = try await ruleTask("RULES_FIXTURE RULES_SKIP_CHECK apply four", "rule-task-4")
        let heldWaiting = try await reach(held, "waiting_review")
        require(reviews(heldWaiting, "browser").count == 1 && reviews(heldWaiting, "browser")[0]["status"] as? String == "pending" && reviews(heldWaiting, "browser")[0]["autoApproved"] == nil, "with the rule paused the same step waits for the person again")
        _ = try await computer(["action": "cancel", "taskId": held])
        print("PASS: a standing rule end to end through the real worker: the agent shows its work, each approval is counted once, the third-time freedom is announced once, an earned rule lets browser steps through with a recorded receipt, and pausing it brings reviews back")

        let rpc=BuddyWorkerProcess(resource:URL(fileURLWithPath:CommandLine.arguments[8]),runtime:URL(fileURLWithPath:CommandLine.arguments[3]));try rpc.launch("fixture")
        defer{rpc.close()};let began=Date()
        do {_ = try await rpc.request(["command":"silent"],timeout:0.05);require(false,"silent RPC must time out")}catch{}
        require(Date().timeIntervalSince(began)<2,"silent RPC has a bounded deadline")
        let pong=try await rpc.request(["command":"ping"],timeout:1)
        require(pong["pong"] as? Bool==true && pong["late"]==nil,"late timed-out response cannot resolve a newer request")
        print("PASS: Swift worker → real ClaudeSession → native browser → matching run-ID response → confirmed completion/usage; RPC deadline and late-response isolation")

        print("PASS: ordinary browser-task IPC, selected provider, idempotency, status, continuation, cancellation, owner isolation, revoked permissions and Claude without ChatGPT")

    }
}
