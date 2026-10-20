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
        // Sleeping is not silence: the host's one-second ticks show the gap, and the stall clock does not count it.
        let before=now.addingTimeInterval(-3600),lastSeen=before.addingTimeInterval(-10)
        require(BuddyWorkerLiveness.asleep(since:now.addingTimeInterval(-1),now:now)==0,"an ordinary tick is not sleep")
        require(BuddyWorkerLiveness.asleep(since:now.addingTimeInterval(-15),now:now)==0,"a busy moment is not sleep")
        let slept=BuddyWorkerLiveness.asleep(since:before,now:now)
        require(slept==3600,"an hour between ticks is reported as the time asleep")
        require(BuddyWorkerLiveness.stalled(status:"running",lastActivity:lastSeen,now:now),"without the credit, an hour asleep would read as a stalled model")
        let credited=BuddyWorkerLiveness.creditingSleep(lastSeen,gap:slept,now:now)
        require(!BuddyWorkerLiveness.stalled(status:"running",lastActivity:credited,now:now),"with the credit, work that slept is not interrupted on waking")
        require(BuddyWorkerLiveness.stalled(status:"running",lastActivity:credited,now:now.addingTimeInterval(181)),"a connection that stays silent for three awake minutes is still caught")
        require(BuddyWorkerLiveness.creditingSleep(now.addingTimeInterval(-1),gap:3600,now:now)==now,"the credit never moves a time into the future")
        require(BuddyWorkerLiveness.asleep(since:now,now:now.addingTimeInterval(-600))==0,"a clock set backwards is not sleep")
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
        let emailRoot=root.appendingPathComponent("MailCompletion"),emailFiles=emailRoot.appendingPathComponent("Files")
        try FileManager.default.createDirectory(at:emailFiles,withIntermediateDirectories:true)
        var mail:[String:Any]=["kind":"email","browserOrigin":"https://console.agentmail.to","browserError":"Website navigation blocked: outside delegated session"]
        require(BuddyWorkerMailCompletion.issue(mail,directory:emailRoot,startedAt:now,now:now)==mail["browserError"] as? String,"a blocked mailbox cannot be reported as a completed scan")
        let execution=UUID().uuidString,receiptTime=ISO8601DateFormatter().string(from:now)
        mail["executionRunID"]=execution;mail["browserPages"]=[["url":"https://console.agentmail.to/inboxes","runID":execution,"at":receiptTime]]
        require(BuddyWorkerMailCompletion.issue(mail,directory:emailRoot,startedAt:now,now:now) != nil,"an inbox list alone is not a finished mailbox review")
        var ledger:[String:Any]=["checkedAt":receiptTime,"mailboxURL":"https://console.agentmail.to/inboxes","timestampSource":"native-browser","nativeRunID":execution,"complete":false,"messages":[[String:Any]]()]
        let ledgerFile=emailFiles.appendingPathComponent("agentmail-review.json")
        try JSONSerialization.data(withJSONObject:ledger).write(to:ledgerFile)
        require(BuddyWorkerMailCompletion.issue(mail,directory:emailRoot,startedAt:now,now:now) != nil,"a partial mailbox ledger stays incomplete")
        ledger["complete"]=true;try JSONSerialization.data(withJSONObject:ledger).write(to:ledgerFile)
        require(BuddyWorkerMailCompletion.issue(mail,directory:emailRoot,startedAt:now,now:now)==nil,"an observed mailbox with a current completed ledger can finish")
        ledger["checkedAt"]=ISO8601DateFormatter().string(from:now.addingTimeInterval(-3600));try JSONSerialization.data(withJSONObject:ledger).write(to:ledgerFile)
        require(BuddyWorkerMailCompletion.issue(mail,directory:emailRoot,startedAt:now,now:now) != nil,"copying an old ledger cannot pass as a fresh mailbox check")
        let mailboxURL="https://console.agentmail.to/dashboard/inboxes/chief%40agentmail.to",stamp=ISO8601DateFormatter().string(from:now)
        mail["id"]=UUID().uuidString;mail["browserPages"]=[["url":mailboxURL,"at":stamp,"runID":execution]]
        ledger["mailboxURL"]=mailboxURL;ledger["checkedAt"]=ISO8601DateFormatter().string(from:now.addingTimeInterval(3600))
        let normalized=BuddyWorkerMailCompletion.normalizeLedger(["path":"agentmail-review.json","content":String(data:try JSONSerialization.data(withJSONObject:ledger),encoding:.utf8)!],job:mail,startedAt:now)
        let stamped=try JSONSerialization.jsonObject(with:Data((normalized["content"] as! String).utf8)) as! [String:Any]
        require(stamped["checkedAt"] as? String==stamp && stamped["timestampSource"] as? String=="native-browser","the actual browser receipt replaces guessed model timestamps")
        try JSONSerialization.data(withJSONObject:stamped).write(to:ledgerFile)
        require(BuddyWorkerMailCompletion.issue(mail,directory:emailRoot,startedAt:now,now:now)==nil,"a native stamped receipt completes only its actual execution")
        mail["executionRunID"]=UUID().uuidString
        require(BuddyWorkerMailCompletion.issue(mail,directory:emailRoot,startedAt:now,now:now) != nil,"a prior attempt's receipt cannot certify a resumed scan")
        let first = try store.create(workspace: workspace, agent: agent, requestId: "once", title: "Fixture task", goal: "Research only", kind: "research", provider: "chatgpt", budget: 0), id = first["id"] as! String
        let duplicate = try store.create(workspace: workspace, agent: agent, requestId: "once", title: "Other title", goal: "Other brief", kind: "research", provider: "chatgpt", budget: 0)
        require(duplicate["id"] as? String == id && store.jobs.count == 1, "unknown response retry is idempotent")
        let savedFirst = try store.job(id)
        require(duplicate["deduplicated"] as? Bool == true && first["deduplicated"] == nil && savedFirst["deduplicated"] == nil, "a retried request says it found the earlier task, and that is never saved on the task")
        try store.update(id, ["status": "waiting_review", "result": "Saved partial work", "reviews": [["id": "pending", "status": "pending"], ["id": "sent", "status": "answered"]]])
        let recovered = try BuddyWorkerStore(directory: root.appendingPathComponent("Worker")), job = try recovered.job(id)
        require(job["status"] as? String == "interrupted" && job["result"] as? String == "Saved partial work", "restart keeps work and never replays an active send")
        let reviews = job["reviews"] as! [[String: Any]]
        require(reviews[0]["status"] as? String == "expired" && reviews[1]["status"] as? String == "uncertain", "old approvals expire and accepted actions become uncertain")
        _ = try recovered.resume(id); require(try recovered.job(id)["status"] as? String == "queued", "explicit resume queues saved work")
        try recovered.setPaused(true); require(try BuddyWorkerStore(directory: root.appendingPathComponent("Worker")).paused, "queue pause survives restart")
        var invalid = false; do { _ = try store.create(workspace: workspace, agent: agent, requestId: "invalid", title: "x", goal: "x", kind: "email", provider: "claude", budget: 2_000_000) } catch { invalid = true }; require(invalid,"an absurd budget cannot enter the queue")
        let unlimited = try store.create(workspace: workspace, agent: agent, requestId: "no-limit", title: "x", goal: "x", kind: "email", provider: "claude", budget: BuddyRunLimit.none)
        require(BuddyRunLimit.isNone(unlimited["budgetUSD"] as? Double ?? 0),"a run with no limit of its own is a normal task")
        let budgetStore=try BuddyWorkerStore(directory:root.appendingPathComponent("Budget")),budgetJob=try budgetStore.create(workspace:workspace,agent:agent,requestId:"budget",title:"Inbox scan",goal:"Read mail",kind:"email",provider:"claude",budget:0.5),bid=budgetJob["id"] as! String
        try budgetStore.update(bid,["status":"failed","remainingBudgetUSD":0.0,"reservedBudgetUSD":0.5,"spentUSD":0.1])
        // Runs have no limit of their own, so a task that stopped with nothing left from the time they did simply carries on.
        let oldScan=try budgetStore.create(workspace:workspace,agent:agent,requestId:"legacy",title:"Old scan",goal:"Read mail",kind:"email",provider:"claude",budget:0.5)
        try budgetStore.update(oldScan["id"] as! String,["status":"failed","remainingBudgetUSD":0.0,"reservedBudgetUSD":0.5,"spentUSD":0.1])
        let carried=try budgetStore.resume(oldScan["id"] as! String)
        require(carried["status"] as? String=="queued" && BuddyRunLimit.isNone(carried["remainingBudgetUSD"] as? Double ?? 0),"a task from when runs had an allowance carries on without one")
        // There is no extra allowance any more: one asked for on resume (an old caller) is ignored, nothing is authorized, and the task carries on.
        try budgetStore.update(bid,["stopCause":"stall"])
        let funded=try budgetStore.resume(bid,additionalBudgetUSD:0.3,authorizationID:UUID().uuidString)
        require(funded["status"] as? String=="queued" && funded["budgetAuthorizations"]==nil && BuddyRunLimit.isNone(funded["remainingBudgetUSD"] as? Double ?? 0) && funded["spentUSD"] as? Double==0.1 && funded["stopCause"] as? String=="","an old extra-allowance request is ignored: the task carries on with no limit of its own, keeps its confirmed usage, and its stop cause is cleared")
        require(try budgetStore.ledger(of:bid).filter{$0["kind"] as? String=="authorize"}.count==1,"and nothing new is authorized")
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
        // A damaged old file stops the first start with the file untouched; a damaged database stops every start after it.
        let legacy = root.appendingPathComponent("Legacy"); try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: legacy.appendingPathComponent("tasks.json"))
        var corrupt = false; do { _ = try BuddyWorkerStore(directory: legacy) } catch { corrupt = true }
        let untouched = try Data(contentsOf: legacy.appendingPathComponent("tasks.json")) == Data("broken".utf8)
        require(corrupt && untouched, "a corrupt old queue fails closed and is left exactly as it was")
        let worn = root.appendingPathComponent("Worker"); _ = try BuddyWorkerStore(directory: worn)
        try Data("this is not a database at all, only some text".utf8).write(to: worn.appendingPathComponent("operations.sqlite"))
        try? FileManager.default.removeItem(at: worn.appendingPathComponent("operations.sqlite-wal")); try? FileManager.default.removeItem(at: worn.appendingPathComponent("operations.sqlite-shm"))
        corrupt = false; do { _ = try BuddyWorkerStore(directory: worn) } catch { corrupt = true }; require(corrupt, "a corrupt task database fails closed")

        // Nothing piles up: a failed run occupies nothing, so it does not count against the cap; a later run of the same work that finishes
        // supersedes the failed ones (unless one may have sent something); and the person is no longer asked about them.
        let capStore = try BuddyWorkerStore(directory: root.appendingPathComponent("Cap")), teammate = UUID().uuidString
        func failedRun(_ n: Int, series: String = "S", reviews: [[String: Any]] = []) throws -> String {
            let made = try capStore.create(workspace: workspace, agent: agent, requestId: "scan-\(series)-\(n)", title: "Inbox scan \(n)", goal: "Read mail", kind: "email", provider: "chatgpt", budget: 0), mid = made["id"] as! String
            try capStore.update(mid, ["routineSeriesID": series, "status": "running", "attempt": 1, "executionRunID": "run-\(series)-\(n)"])
            var fields: [String: Any] = ["status": "failed", "progress": "AgentMail was blocked."]
            if !reviews.isEmpty { fields["reviews"] = reviews }
            try capStore.update(mid, fields)
            return mid
        }
        var staleRuns: [String] = [], piledUp = true
        do { for n in 0..<31 { staleRuns.append(try failedRun(n)) } } catch { piledUp = false }
        require(piledUp, "thirty-one failed scans do not fill the queue, because a failed run occupies nothing")
        let elsewhere = try? capStore.create(workspace: workspace, agent: teammate, requestId: "teammate-work", title: "Other work", goal: "Do it", kind: "research", provider: "chatgpt", budget: 0)
        require(elsewhere != nil, "and another agent can still be given work")
        let unsure = try failedRun(31, reviews: [["id": "sent-1", "kind": "browser", "status": "uncertain", "tool": ["name": "Click Send"]]])
        let unrelated = try failedRun(0, series: "T")
        let stoppedBefore = try capStore.openDecisions(workspace: workspace).filter { $0["kind"] as? String == "stopped" }.count
        require(stoppedBefore == 33, "each failed run is still one entry while nothing has finished (\(stoppedBefore))")
        let fresh = try capStore.create(workspace: workspace, agent: agent, requestId: "scan-S-fresh", title: "Inbox scan", goal: "Read mail", kind: "email", provider: "chatgpt", budget: 0), freshID = fresh["id"] as! String
        try capStore.update(freshID, ["routineSeriesID": "S", "status": "running", "attempt": 1, "executionRunID": "run-fresh"])
        try capStore.update(freshID, ["status": "completed", "result": "Nothing new."])
        for sid in staleRuns {
            let j = try capStore.job(sid)
            require(j["status"] as? String == "cancelled" && j["stopCause"] as? String == "superseded" && j["supersededBy"] as? String == freshID && j["progress"] as? String == "Superseded: a later run of the same work finished.", "a later run of the same work that finished supersedes an older failed one: \(j["status"] ?? "")/\(j["stopCause"] ?? "")")
        }
        require(try capStore.job(unsure)["status"] as? String == "failed", "a run that may have sent something is never superseded")
        require(try capStore.job(unrelated)["status"] as? String == "failed", "a run of other work is left alone")
        let stoppedAfter = Set(try capStore.openDecisions(workspace: workspace).filter { $0["kind"] as? String == "stopped" }.compactMap { $0["taskId"] as? String })
        require(stoppedAfter == Set([unsure, unrelated]), "the superseded runs no longer ask anyone, the others still do: \(stoppedAfter.count)")
        require(try capStore.history(of: staleRuns[0]).contains { $0.type == "task.status" && $0.cause == "superseded" && $0.payload["to"] as? String == "cancelled" }, "the supersession is in the run's history")
        let rereadCap = try BuddyWorkerStore(directory: root.appendingPathComponent("Cap"))
        require(try rereadCap.job(staleRuns[30])["supersededBy"] as? String == freshID && rereadCap.job(freshID)["status"] as? String == "completed", "it was saved with the run that finished")

        // A restart marks the work it interrupted for automatic recovery, unless an action may have been sent.
        let restartDirectory = root.appendingPathComponent("Restart"), today = BuddyBudget.day(Date())
        var plain = "", sent = "", again = ""
        do {
            let before = try BuddyWorkerStore(directory: restartDirectory)
            plain = try before.create(workspace: workspace, agent: agent, requestId: "plain", title: "Plain", goal: "Do it", kind: "research", provider: "chatgpt", budget: 0)["id"] as! String
            try before.update(plain, ["status": "running", "attempt": 1, "executionRunID": "run-plain"])
            again = try before.create(workspace: workspace, agent: agent, requestId: "again", title: "Again", goal: "Do it", kind: "research", provider: "chatgpt", budget: 0)["id"] as! String
            try before.update(again, ["status": "running", "attempt": 2, "executionRunID": "run-again", "recovery": ["cause": "worker.restart", "state": "queued", "tries": 2, "day": today, "nextAt": ""]])
            sent = try before.create(workspace: workspace, agent: agent, requestId: "sent", title: "Sent", goal: "Do it", kind: "general", provider: "chatgpt", budget: 0)["id"] as! String
            try before.update(sent, ["status": "running", "attempt": 1, "executionRunID": "run-sent"])
            try before.update(sent, ["status": "waiting_review", "reviews": [["id": "click", "kind": "browser", "status": "pending", "tool": ["name": "Click Send"]]]])
            try before.update(sent, ["status": "running", "reviews": [["id": "click", "kind": "browser", "status": "answered", "tool": ["name": "Click Send"]]]])
            try before.markDispatched(task: sent, review: "click")
        }
        let afterRestart = try BuddyWorkerStore(directory: restartDirectory)
        let p = try afterRestart.job(plain), recovery = p["recovery"] as? [String: Any]
        require(p["status"] as? String == "interrupted" && p["stopCause"] as? String == "worker.restart" && recovery?["state"] as? String == "pending" && recovery?["cause"] as? String == "worker.restart" && recovery?["tries"] as? Int == 0 && recovery?["day"] as? String == today && (recovery?["nextAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } != nil, "a restart with nothing in flight marks the task for automatic recovery: \(p["stopCause"] ?? "none") \(String(describing: recovery))")
        require((p["progress"] as? String) == "The worker restarted. Buddy will continue this task automatically from its saved progress.", "and says so plainly")
        require(try afterRestart.openDecisions(workspace: workspace).filter { $0["taskId"] as? String == plain }.isEmpty, "nobody is asked about it while it waits to be continued")
        require((try afterRestart.job(again)["recovery"] as? [String: Any])?["tries"] as? Int == 2, "the tries already made today are kept")
        let s = try afterRestart.job(sent)
        require(s["status"] as? String == "interrupted" && s["recovery"] == nil && s["stopCause"] as? String == "worker.restart" && (s["progress"] as? String)?.contains("may have been sent") == true, "a restart while an action may have been sent is never recovered automatically")
        require(try afterRestart.openDecisions(workspace: workspace).filter { $0["taskId"] as? String == sent }.map { $0["kind"] as? String ?? "" }.sorted() == ["stopped", "unconfirmed"], "and the person is asked about it and its action")
        print("PASS: failed runs occupy nothing, later finished runs supersede stale ones and resolve their entries, uncertain runs are kept, retries are marked deduplicated, and a restart marks only safe work for automatic recovery")

        // Who may act on another agent's work: the agent itself, its manager, or the supervisor. Read from native state only.
        let chiefID = UUID().uuidString, forge = UUID().uuidString, lyra = UUID().uuidString
        let team: [String: Any] = ["agents": [["id": chiefID], ["id": forge, "managedBy": chiefID], ["id": lyra]]]
        require(BuddyAuthority.may(forge, actOn: forge, state: team, supervisor: nil), "an agent may act on its own work") // new-api
        require(BuddyAuthority.may(chiefID, actOn: forge, state: team, supervisor: nil), "a manager may act on the work of an agent it manages") // new-api
        require(BuddyAuthority.may(chiefID, actOn: lyra, state: team, supervisor: chiefID), "the supervisor may act on anyone's work") // new-api
        require(!BuddyAuthority.may(lyra, actOn: forge, state: team, supervisor: chiefID) && !BuddyAuthority.may(forge, actOn: lyra, state: team, supervisor: nil), "a teammate that neither manages nor supervises may not") // new-api
        require(!BuddyAuthority.may("", actOn: "", state: team, supervisor: "") && !BuddyAuthority.may("", actOn: forge, state: ["agents": [["id": forge, "managedBy": ""]]], supervisor: nil), "an empty actor is nobody") // new-api
        print("PASS: authority over another agent's work comes from native state only") // new-api
    }
}
