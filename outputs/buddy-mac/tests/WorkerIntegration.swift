import AppKit
@main struct WorkerIntegration {
    @MainActor static func require(_ value: Bool, _ message: String) { if !value { fputs("FAILED: \(message)\n", stderr); exit(1) } }
    @MainActor static func main() async throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("buddy-worker-integration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let workspace = UUID().uuidString, agent = UUID().uuidString
        try JSONSerialization.data(withJSONObject: ["conversationWorkspace": workspace, "agents": [["id": agent, "name": "Check", "role": "Fixture", "description": "Inert verification", "tools": [:]]]]).write(to: support.appendingPathComponent("workspace.json"))
        let host = BuddyWorkerHost(support: support, executable: URL(fileURLWithPath: CommandLine.arguments[1]),makeCoding:{BuddyWorkerProcess(resource:URL(fileURLWithPath:CommandLine.arguments[2]),runtime:URL(fileURLWithPath:CommandLine.arguments[3]))},makeCodingShell:{BuddyWorkerProcess(resource:URL(fileURLWithPath:CommandLine.arguments[4]),runtime:URL(fileURLWithPath:CommandLine.arguments[5]))},keyReader:{_ in "inert-fixture-key"})
        host.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer { host.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)) }
        let teamStatus = try await BuddyWorkerClient.call(support: support, payload: ["workspace": workspace, "operation": "team", "arguments": ["action": "status"]])
        require(teamStatus["workspace"] as? String == workspace && (teamStatus["profiles"] as? [[String: Any]])?.first?["id"] as? String == agent, "team preferences cross the real private IPC connection")
        require(teamStatus["error"] == nil && teamStatus["monitorError"] as? String == "", "healthy monitor diagnostics cannot be mistaken for a worker transport failure")
        let savedPreference = try await BuddyWorkerClient.call(support: support, payload: ["workspace": workspace, "operation": "team", "arguments": ["action": "set_proactive", "agentId": agent, "enabled": true]])
        require(savedPreference["saved"] as? Bool == true && savedPreference["proactive"] as? Bool == true, "saved team settings return a usable receipt through IPC")
        print("PASS: team preferences and saved proactive setting receipts through actual worker IPC")
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
        for _ in 0..<50 {let task=try await call(["action":"status","taskId":inputID])["task"] as! [String:Any];if (task["remainingBudgetUSD"] as? Double ?? 0)>0 {accounted=true;break};try await Task.sleep(nanoseconds:100_000_000)}
        require(accounted,"input checkpoint lets the SDK finish and confirm remaining budget")
        _ = try await call(["action":"continue","taskId":inputID,"goal":"Implement the explicit follow-up feature."],requestID:"input-follow-up")
        _ = try await wait(inputID,for:"completed")
        _ = try BuddyAISettings(support:support).update(workspace,enabled:("claude",false))
        do {_ = try await call(["action":"start","title":"Must not run","goal":"Claude is disconnected."],requestID:"disconnected");require(false,"disconnected coding must fail")}catch{}
        print("PASS: coding enqueue, real native file/command/preview, persistent SDK resume, budget accounting, exact internet-command review, and disconnected-provider rejection")
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
        agents[0]["tools"]=["desktop":false];fixture["agents"]=agents;try JSONSerialization.data(withJSONObject:fixture).write(to:support.appendingPathComponent("workspace.json"),options:.atomic)
        do {_ = try await computer(["action":"start","title":"Denied","goal":"Open a website"],requestID:"denied");require(false,"revoked browser permission prevents enqueue")}catch{}
        agents[0]["tools"]=[String:Bool]();fixture["agents"]=agents;try JSONSerialization.data(withJSONObject:fixture).write(to:support.appendingPathComponent("workspace.json"),options:.atomic)
        _ = try BuddyAISettings(support:support).update(workspace,enabled:("claude",true))
        _ = try BuddyAISettings(support:support).update(workspace,provider:"claude")
        try BuddyAgentModels(support:support).set(workspace:workspace,agent:agent,selection:.initial("claude"))
        _ = try BuddyAISettings(support:support).update(workspace,enabled:("chatgpt",false))
        let claudeBrowser=try await computer(["action":"start","title":"Claude website task","goal":"Open AgentMail in my browser."],requestID:"claude-browser")["task"] as! [String:Any]
        require(claudeBrowser["provider"] as? String=="claude" && claudeBrowser["status"] as? String=="queued","Claude website enqueue works with ChatGPT disconnected")
        _ = try await computer(["action":"cancel","taskId":claudeBrowser["id"]!])
        print("PASS: ordinary browser-task IPC, selected provider, idempotency, status, continuation, cancellation, owner isolation, revoked permissions and Claude without ChatGPT")

    }
}
