import Foundation
@main struct RoutineTests {
    @MainActor static func require(_ value:Bool,_ message:String) {if !value{fputs("FAILED: \(message)\n",stderr);exit(1)}}
    @MainActor static func main() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("buddy-routine-tests-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let w=UUID().uuidString,a=UUID().uuidString,f=ISO8601DateFormatter(),now=f.date(from:"2026-10-16T18:00:00Z")!
        let rules=try BuddyRoutineStore(directory:root),queue=try BuddyWorkerStore(directory:root)
        let args:[String:Any]=["action":"create","title":"Check assessments","goal":"Review relevant job assessment mail and reconcile completion","kind":"email","query":"in:anywhere -in:trash newer_than:90d {assessment assessments}","hour":9,"minute":0,"weekdays":[2,3,4,5,6],"timeZone":"America/Los_Angeles"]
        let created=try rules.manage(args,workspace:w,agent:a,requestID:"user-turn",provider:"claude",budget:0.5,model:"claude-pinned",now:now),r=created["routine"] as! [String:Any],rid=r["id"] as! String
        require(r["nextRun"] as? String=="2026-10-19T16:00:00Z","Friday after 9 schedules Monday 9 local")
        _ = try rules.manage(args,workspace:w,agent:a,requestID:"user-turn",provider:"claude",budget:0.5,now:now)
        _ = try rules.manage(args,workspace:w,agent:a,requestID:"model-repeated-tool-call",provider:"claude",budget:0.5,now:now)
        require(rules.routines.count==1,"retries and repeated calls do not duplicate a routine")
        _ = try rules.manage(["action":"update","routineID":rid,"title":"Updated title"],workspace:w,agent:a,requestID:"new-model",provider:"chatgpt",budget:0,model:"different-model",now:now)
        require(rules.routines[0]["model"] as? String=="claude-pinned" && rules.routines[0]["provider"] as? String=="claude","editing the agent model does not mutate an existing routine")
        let wake=f.date(from:"2026-10-22T18:00:00Z")!
        try rules.enqueueDue(store:queue,workspace:w,now:wake);try rules.enqueueDue(store:queue,workspace:w,now:wake)
        require(queue.jobs.count==1 && rules.routines[0]["nextRun"] as? String=="2026-10-23T16:00:00Z","sleep catches up once and advances past missed days without bursts")
        let id=queue.jobs[0]["id"] as! String
        require(queue.jobs[0]["model"] as? String=="claude-pinned","routine occurrence retains its pinned model")
        require(queue.jobs[0]["inboxQuery"] as? String==args["query"] as? String && queue.jobs[0]["routineID"] as? String==rid,"native task carries saved search and stable routine memory")
        // simulate lost routine update after queue was saved
        var saved=try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("routines.json"))) as! [String:Any]
        var values=saved["routines"] as! [[String:Any]];values[0]["nextRun"]=r["nextRun"];saved["routines"]=values
        try JSONSerialization.data(withJSONObject:saved).write(to:root.appendingPathComponent("routines.json"))
        let restarted=try BuddyRoutineStore(directory:root);try restarted.enqueueDue(store:queue,workspace:w,now:wake)
        require(queue.jobs.count==1,"restart cannot duplicate an already queued occurrence")
        try queue.update(id,["status":"completed","result":"Zopa pending; UBS complete"])
        try rules.enqueueDue(store:queue,workspace:w,now:f.date(from:"2026-10-23T18:00:00Z")!)
        require(queue.jobs.count==2 && queue.jobs[1]["previousRoutineResult"] as? String=="Zopa pending; UBS complete","next run carries unresolved findings, not an empty inbox assumption")
        try queue.update(queue.jobs[1]["id"] as! String,["status":"interrupted"])
        try rules.enqueueDue(store:queue,workspace:w,now:f.date(from:"2026-10-26T18:00:00Z")!)
        require(rules.routines[0]["status"] as? String=="needs_attention" && queue.jobs.count==2,"interrupted external work blocks automatic recurrence")
        try rules.resumeBlockedBy(queue.jobs.last!,now:now)
        require(rules.routines[0]["status"] as? String=="active","explicitly resuming the blocking task restores only its automatically blocked routine")
        _ = try rules.manage(["action":"resume","routineID":rid],workspace:w,agent:a,requestID:"resume",provider:"claude",budget:0.5,now:now)
        _ = try rules.manage(["action":"pause","routineID":rid],workspace:w,agent:a,requestID:"pause",provider:"claude",budget:0.5,now:now)
        try rules.resumeBlockedBy(queue.jobs.last!,now:now)
        require(try BuddyRoutineStore(directory:root).routines[0]["status"] as? String=="paused","pause survives process restart")
        let dst=try BuddyRoutineStore.next(after:f.date(from:"2026-10-31T18:00:00Z")!,rule:["timeZone":"America/Los_Angeles","hour":9,"minute":0,"weekdays":[1,2,3,4,5,6,7]])
        require(f.string(from:dst)=="2026-11-01T17:00:00Z","schedule keeps 9 local across daylight saving")
        var bad=false;do{_ = try rules.manage(["action":"create","title":"invalid","goal":"x","kind":"email"],workspace:w,agent:a,requestID:"bad",provider:"chatgpt",budget:0,now:now)}catch{bad=true};require(bad,"email routines require a targeted search")
        let inbox=UUID().uuidString,run=UUID().uuidString,user=UUID().uuidString,text="take them off, create a new agent for my inbox and make same interval checks"
        let authority:[String:Any] = ["agents":[["id":a,"name":"Chief"],["id":inbox,"name":"Inbox","managedBy":a]],"runs":[run:["target":a,"status":"answering","userId":user]],"messages":[a:[["id":user,"who":"you","body":text]]]]
        let delegated:[String:Any] = ["agentId":inbox,"authorizationQuote":text]
        require(try BuddyRoutineAuthorization.owner(delegated,actor:a,runID:run,text:text,state:authority)==inbox,"the actual user can authorize scheduling for a managed teammate")
        do{_ = try BuddyRoutineAuthorization.owner(delegated,actor:a,runID:run,text:"every day",state:authority);require(false,"forged schedule authority rejected")}catch{}
        let batchRoot=root.appendingPathComponent("Batch"),batch=try BuddyRoutineStore(directory:batchRoot),batchQueue=try BuddyWorkerStore(directory:batchRoot)
        let hours=[8,10,12,14,16,18,20]
        let plan:[String:Any] = ["action":"create","title":"Inbox checks","goal":"Read both requested inboxes","kind":"general","hours":hours,"minute":0,"weekdays":[1,2,3,4,5,6,7],"timeZone":"America/Los_Angeles","browserAgentId":a,"browserOrigin":"https://console.agentmail.to"]
        let receipt=try batch.manage(plan,workspace:w,agent:inbox,requestID:"handoff",provider:"claude",budget:0.5,now:now)
        _ = try batch.manage(plan,workspace:w,agent:inbox,requestID:"handoff",provider:"claude",budget:0.5,now:now)
        let reopenedBatch=try BuddyRoutineStore(directory:batchRoot)
        require((receipt["routines"] as! [Any]).count==7 && reopenedBatch.routines.count==7 && reopenedBatch.routines.compactMap{$0["hour"] as? Int}.sorted()==hours,"one idempotent batch durably saves all seven teammate checks")
        require(reopenedBatch.routines.allSatisfy{$0["agentId"] as? String==inbox && $0["browserAgentId"] as? String==a},"teammate schedules retain only the explicitly delegated browser owner")
        try reopenedBatch.enqueueDue(store:batchQueue,workspace:w,now:wake)
        require(batchQueue.jobs.count==1,"a batch catches up only once after sleep")
        require(batchQueue.jobs.allSatisfy{$0["browserOrigin"] as? String=="https://console.agentmail.to" && $0["browserAgentId"] as? String==a},"the exact website scope reaches scheduled task execution")
        let series=reopenedBatch.routines.first!["routineSeriesID"] as! String
        require(reopenedBatch.routines.allSatisfy{$0["routineSeriesID"] as? String==series},"all daily checks share the same review memory")
        try batchQueue.update(batchQueue.jobs[0]["id"] as! String,["status":"completed","result":"Retain a verified unresolved deadline"])
        try reopenedBatch.enqueueDue(store:batchQueue,workspace:w,now:f.date(from:"2026-10-22T19:01:00Z")!)
        require(batchQueue.jobs.count==2 && batchQueue.jobs.last?["previousRoutineResult"] as? String=="Retain a verified unresolved deadline" && batchQueue.jobs.last?["routineSeriesID"] as? String==series,"the next time slot retains the shared prior findings")
        var invalidBatch=plan;invalidBatch["hours"]=[8,8]
        do{_ = try batch.manage(invalidBatch,workspace:w,agent:inbox,requestID:"bad",provider:"claude",budget:0.5,now:now);require(false,"invalid batch rejected")}catch{}
        require(try BuddyRoutineStore(directory:batchRoot).routines.count==7,"failed batches preserve existing schedules")
        print("PASS: saved schedule receipt, local timezone/weekdays/DST, deduplication, one wake catch-up, restart idempotency, non-overlap, prior findings, interrupted-run attention and durable pause")
    }
}
