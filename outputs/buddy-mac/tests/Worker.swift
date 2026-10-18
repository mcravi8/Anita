import Foundation
@main struct WorkerTests {
    @MainActor static func require(_ value: Bool, _ message: String) { if !value { fputs("FAILED: \(message)\n", stderr); exit(1) } }
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("buddy-worker-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let now=Date(),old=now.addingTimeInterval(-181)
        require(BuddyWorkerLiveness.stalled(status:"running",lastActivity:old,now:now),"unresponsive running work is interrupted after three minutes")
        require(!BuddyWorkerLiveness.stalled(status:"running",lastActivity:now,now:now),"active work is not interrupted")
        for status in ["waiting_review","waiting_user","queued","completed","paused"] {require(!BuddyWorkerLiveness.stalled(status:status,lastActivity:old,now:now),"human and inactive states are not mistaken for stalled work")}
        let workspace = UUID().uuidString, agent = UUID().uuidString
        let loginJob:[String:Any] = ["workspace":workspace,"agentId":agent]
        let googlePlan:[String:Any] = ["mode":"signin","googleAvailable":true,"origin":"https://console.agentmail.to"]
        let approval:[String:Any] = ["kind":"authentication","mode":"signin","origin":"https://console.agentmail.to","status":"completed","authAction":"saved"]
        let approved:[String:Any] = ["workspace":workspace,"agentId":agent,"reviews":[approval]]
        require(BuddyWorkerSignInPolicy.reuseGoogle(job:loginJob,plan:googlePlan,jobs:[approved]),"an already-approved site can reuse Google without another sign-in-choice interruption")
        let delegatedLogin:[String:Any] = ["workspace":workspace,"agentId":UUID().uuidString,"browserAgentId":agent,"browserOrigin":"https://console.agentmail.to"]
        require(BuddyWorkerSignInPolicy.reuseGoogle(job:delegatedLogin,plan:googlePlan,jobs:[approved]),"the delegated website can reuse its source browser's confirmed sign-in")
        var outside=googlePlan;outside["origin"]="https://different.example"
        require(!BuddyWorkerSignInPolicy.reuseGoogle(job:delegatedLogin,plan:outside,jobs:[approved]),"delegation never widens the saved sign-in to another website")
        for field in ["workspace","agentId"] {var wrong=approved;wrong[field]=UUID().uuidString;require(!BuddyWorkerSignInPolicy.reuseGoogle(job:loginJob,plan:googlePlan,jobs:[wrong]),"saved sign-in approval is scoped to the actual workspace and agent")}
        var otherSite=googlePlan;otherSite["origin"]="https://other.example";require(!BuddyWorkerSignInPolicy.reuseGoogle(job:loginJob,plan:otherSite,jobs:[approved]),"a saved login does not authorize another site")
        for mode in ["signup","verification"] {var wrong=googlePlan;wrong["mode"]=mode;require(!BuddyWorkerSignInPolicy.reuseGoogle(job:loginJob,plan:wrong,jobs:[approved]),"Google reuse never grants account creation or email verification")}
        var passwordOnly=googlePlan;passwordOnly["googleAvailable"]=false;require(!BuddyWorkerSignInPolicy.reuseGoogle(job:loginJob,plan:passwordOnly,jobs:[approved]),"only an observed Google button gets automatic reuse")
        for status in ["pending","declined","uncertain"] {var review=approval;review["status"]=status;var wrong=approved;wrong["reviews"]=[review];require(!BuddyWorkerSignInPolicy.reuseGoogle(job:loginJob,plan:googlePlan,jobs:[wrong]),"unconfirmed or declined reviews cannot authorize login")}
        let store = try BuddyWorkerStore(directory: root.appendingPathComponent("Worker"))
        let first = try store.create(workspace: workspace, agent: agent, requestId: "once", title: "Fixture task", goal: "Research only", kind: "research", provider: "chatgpt", budget: 0), id = first["id"] as! String
        let duplicate = try store.create(workspace: workspace, agent: agent, requestId: "once", title: "Other title", goal: "Other brief", kind: "research", provider: "chatgpt", budget: 0)
        require(duplicate["id"] as? String == id && store.jobs.count == 1, "unknown response retry is idempotent")
        try store.update(id, ["status": "waiting_review", "result": "Saved partial work", "reviews": [["id": "pending", "status": "pending"], ["id": "sent", "status": "answered"]]])
        let recovered = try BuddyWorkerStore(directory: root.appendingPathComponent("Worker")), job = try recovered.job(id)
        require(job["status"] as? String == "interrupted" && job["result"] as? String == "Saved partial work", "restart keeps work and never replays an active send")
        let reviews = job["reviews"] as! [[String: Any]]
        require(reviews[0]["status"] as? String == "expired" && reviews[1]["status"] as? String == "uncertain", "old approvals expire and accepted actions become uncertain")
        _ = try recovered.resume(id); require(try recovered.job(id)["status"] as? String == "queued", "explicit resume queues saved work")
        try recovered.setPaused(true); require(try BuddyWorkerStore(directory: root.appendingPathComponent("Worker")).paused, "queue pause survives restart")
        var invalid = false; do { _ = try store.create(workspace: workspace, agent: agent, requestId: "invalid", title: "x", goal: "x", kind: "email", provider: "claude", budget: 1000) } catch { invalid = true }; require(invalid,"invalid budget cannot enter queue")
        let budgetStore=try BuddyWorkerStore(directory:root.appendingPathComponent("Budget")),budgetJob=try budgetStore.create(workspace:workspace,agent:agent,requestId:"budget",title:"Inbox scan",goal:"Read mail",kind:"email",provider:"claude",budget:0.5),bid=budgetJob["id"] as! String
        try budgetStore.update(bid,["status":"failed","remainingBudgetUSD":0.0,"reservedBudgetUSD":0.5,"spentUSD":0.1])
        do{_ = try budgetStore.resume(bid);require(false,"an exhausted attempt cannot queue another doomed retry without an allowance")}catch{}
        let authorization=UUID().uuidString
        let funded=try budgetStore.resume(bid,additionalBudgetUSD:0.3,authorizationID:authorization)
        require(funded["remainingBudgetUSD"] as? Double==0.3 && funded["uncertainBudgetUSD"] as? Double==0.5 && funded["reservedBudgetUSD"] as? Double==0 && funded["spentUSD"] as? Double==0.1,"an explicit extra allowance preserves prior uncertain and confirmed usage")
        _ = try budgetStore.resume(bid,additionalBudgetUSD:0.3,authorizationID:authorization)
        require((try budgetStore.job(bid)["budgetAuthorizations"] as? [[String:Any]])?.count==1,"a repeated response cannot authorize the allowance twice")
        do{_ = try budgetStore.resume(bid,additionalBudgetUSD:0.7,authorizationID:authorization);require(false,"an allowance receipt cannot be reused for a changed amount")}catch{}
        try budgetStore.update(bid,["status":"failed","remainingBudgetUSD":0.0])
        for invalid in [-1.0,0,20,Double.nan] {do{_ = try budgetStore.resume(bid,additionalBudgetUSD:invalid,authorizationID:UUID().uuidString);require(false,"invalid extra spending rejected")}catch{}}
        let support = root.appendingPathComponent("Data"), f = BuddyProjectFiles(support: support)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["conversationWorkspace": workspace]).write(to: support.appendingPathComponent("workspace.json"))
        let shared = try f.scope(workspace), own = root.appendingPathComponent("Private")
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        let worker = BuddyProjectFiles(support: support, privateRoot: own, privateFolderID: id), local = try worker.scope(workspace)
        _ = try worker.write(local, path: "report.md", content: "Private result", expectedVersion: "", actor: agent, actorName: "Fixture")
        require(!FileManager.default.fileExists(atPath: support.appendingPathComponent("Projects/" + workspace + "/report.md").path), "task files do not leak into the shared primary folder")
        _ = try f.write(shared, path: "common.md", content: "First", expectedVersion: "", actor: agent, actorName: "Fixture")
        let read = try worker.read(shared, path: "common.md")
        _ = try f.write(shared, path: "common.md", content: "New foreground edit", expectedVersion: read["version"] as! String, actor: agent, actorName: "Fixture")
        var stale = false; do { _ = try worker.write(shared, path: "common.md", content: "Stale background edit", expectedVersion: read["version"] as! String, actor: agent, actorName: "Fixture") } catch { stale = true }
        let latest = try f.read(shared, path: "common.md"); require(stale && latest["content"] as? String == "New foreground edit", "background conflict preserves the foreground edit")
        let other = root.appendingPathComponent("Other"); try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let connected = try f.addFolder(workspace, to: other), otherScope = BuddyFileScope(workspace: workspace, folderId: connected["folderId"] as! String)
        _ = try worker.write(otherScope, path: "a.md", content: "Allowed", expectedVersion: "", actor: agent, actorName: "Fixture")
        try f.removeFolder(workspace, folderId: otherScope.folderId)
        var removed = false; do { _ = try worker.read(otherScope,path:"a.md") } catch { removed = true }; require(removed, "worker rechecks connected folder removal on every access")
        let connection = BuddyConnection(id:"web",name:"Search",enabled:true,callable:true,tools:[["name":"search","isReadOnly":true]])
        let grants = BuddyConnectionGrants(support: support), otherGrants = BuddyConnectionGrants(support: support)
        _ = try grants.allowed(for: workspace + ":" + agent, catalog: [connection]); try otherGrants.set(key: workspace + ":" + agent, connection: "web", allowed: false)
        require(try grants.allowed(for: workspace + ":" + agent, catalog: [connection]).isEmpty, "worker notices access removed by another process")
        print("PASS: durable queue, idempotency, restart/no replay, expired approvals, pause, spending validation, private files, merge conflicts, current folder and service grants")
        try Data("broken".utf8).write(to: root.appendingPathComponent("Worker/tasks.json"))
        var corrupt = false; do { _ = try BuddyWorkerStore(directory: root.appendingPathComponent("Worker")) } catch { corrupt = true }; require(corrupt, "corrupt queue fails closed")
    }
}
