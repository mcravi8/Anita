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
        require(queue.jobs[0]["supervisorId"]==nil,"with no supervisor named, a scheduled run names none")
        require(queue.jobs[0]["inboxQuery"] as? String==args["query"] as? String && queue.jobs[0]["routineID"] as? String==rid,"native task carries saved search and stable routine memory")
        // simulate lost routine update after queue was saved
        let database=try BuddyOperationsDB(directory:root,existing:true)
        var lost=try BuddyOperationsDB.decode(database.rows("SELECT body FROM routines").first!.first!.string!);lost["nextRun"]=r["nextRun"]
        try database.run("UPDATE routines SET body = ?",[.text(BuddyOperationsDB.encode(lost))])
        let restarted=try BuddyRoutineStore(directory:root);try restarted.enqueueDue(store:queue,workspace:w,now:wake)
        require(queue.jobs.count==1,"restart cannot duplicate an already queued occurrence")
        try queue.update(id,["status":"completed","result":"Zopa pending; UBS complete"])
        try rules.enqueueDue(store:queue,workspace:w,now:f.date(from:"2026-10-23T18:00:00Z")!)
        require(queue.jobs.count==2 && queue.jobs[1]["previousRoutineResult"] as? String=="Zopa pending; UBS complete","next run carries unresolved findings, not an empty inbox assumption")
        // An interrupted run whose action may have been sent waits for the person; one with nothing in flight does not block.
        try queue.update(queue.jobs[1]["id"] as! String,["status":"interrupted","reviews":[["id":"sent","status":"uncertain"]]])
        try rules.enqueueDue(store:queue,workspace:w,now:f.date(from:"2026-10-26T18:00:00Z")!)
        require(rules.routines[0]["status"] as? String=="needs_attention" && queue.jobs.count==2,"an interrupted run with an uncertain action blocks automatic recurrence")
        try rules.resumeBlockedBy(queue.jobs.last!,now:now)
        require(rules.routines[0]["status"] as? String=="active","explicitly resuming the blocking task restores only its automatically blocked routine")
        try queue.update(queue.jobs[1]["id"] as! String,["reviews":[[String:Any]]()])
        try rules.enqueueDue(store:queue,workspace:w,now:now)
        require(rules.routines[0]["status"] as? String=="active" && queue.jobs.count==2,"an interrupted run with nothing in flight does not block automatic recurrence")
        require(BuddyRoutineModel.resolve(pinned:"claude-sonnet-4-6",provider:"claude",current:(provider:"claude",model:"claude-haiku-5-5"))=="claude-haiku-5-5","a scheduled run uses the agent's current model, not the one it had when the routine was saved")
        require(BuddyRoutineModel.resolve(pinned:"claude-sonnet-4-6",provider:"claude",current:(provider:"chatgpt",model:"gpt-x"))=="claude-sonnet-4-6" && BuddyRoutineModel.resolve(pinned:"claude-sonnet-4-6",provider:"claude",current:nil)=="claude-sonnet-4-6","but a routine never switches provider on its own")
        // A read-only check that merely failed (nothing uncertain happened) does not stop the schedule; one that left an action uncertain still waits for the person.
        try queue.update(queue.jobs.last!["id"] as! String,["status":"failed","progress":"Reached maximum budget"])
        try rules.enqueueDue(store:queue,workspace:w,now:f.date(from:"2026-10-27T18:00:00Z")!)
        require(rules.routines[0]["status"] as? String=="active" && queue.jobs.count==2,"a failed read-only check no longer stops the schedule (the occurrence already queued is not repeated)")
        try rules.enqueueDue(store:queue,workspace:w,now:f.date(from:"2026-10-28T18:00:00Z")!)
        require(rules.routines[0]["status"] as? String=="active" && queue.jobs.count==3,"the next scheduled check runs after a failed one")
        try queue.update(queue.jobs.last!["id"] as! String,["status":"failed","reviews":[["id":"r","status":"uncertain"]]])
        try rules.enqueueDue(store:queue,workspace:w,now:f.date(from:"2026-10-29T18:00:00Z")!)
        require(rules.routines[0]["status"] as? String=="needs_attention" && queue.jobs.count==3,"but one that left an action uncertain still waits for the person")
        try queue.update(queue.jobs.last!["id"] as! String,["reviews":[[String:Any]]()])
        try rules.enqueueDue(store:queue,workspace:w,now:f.date(from:"2026-10-30T18:00:00Z")!)
        require(rules.routines[0]["status"] as? String=="active","a routine that was stopped only by a harmless failure is set going again")
        try rules.enqueueDue(store:queue,workspace:w,now:f.date(from:"2026-11-02T18:00:00Z")!)
        require(queue.jobs.count==4,"and runs at its next time")
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
        let occurrence=batchQueue.jobs[0],occurrenceRule=occurrence["routineID"] as! String,newOwner=UUID().uuidString
        _ = try reopenedBatch.manage(["action":"update","routineID":occurrenceRule,"browserAgentId":newOwner,"browserOrigin":"https://console.agentmail.to"],workspace:w,agent:inbox,requestID:"repair-session",provider:"claude",budget:0.5,now:now)
        require(reopenedBatch.browserScope(for:occurrence)?["browserAgentId"] as? String==newOwner,"retry can reuse the repaired saved website delegation without copying credentials")
        var foreignOccurrence=occurrence;foreignOccurrence["agentId"]=a
        require(reopenedBatch.browserScope(for:foreignOccurrence)==nil,"another agent cannot inherit this routine's website delegation")
        let series=reopenedBatch.routines.first!["routineSeriesID"] as! String
        require(reopenedBatch.routines.allSatisfy{$0["routineSeriesID"] as? String==series},"all daily checks share the same review memory")
        try batchQueue.update(batchQueue.jobs[0]["id"] as! String,["status":"completed","result":"Retain a verified unresolved deadline"])
        try reopenedBatch.enqueueDue(store:batchQueue,workspace:w,now:f.date(from:"2026-10-22T19:01:00Z")!)
        require(batchQueue.jobs.count==2 && batchQueue.jobs.last?["previousRoutineResult"] as? String=="Retain a verified unresolved deadline" && batchQueue.jobs.last?["routineSeriesID"] as? String==series,"the next time slot retains the shared prior findings")
        var invalidBatch=plan;invalidBatch["hours"]=[8,8]
        do{_ = try batch.manage(invalidBatch,workspace:w,agent:inbox,requestID:"bad",provider:"claude",budget:0.5,now:now);require(false,"invalid batch rejected")}catch{}
        require(try BuddyRoutineStore(directory:batchRoot).routines.count==7,"failed batches preserve existing schedules")
        try batchQueue.update(batchQueue.jobs.last!["id"] as! String,["status":"completed","result":"Prior verified findings"])
        let nextTimes=reopenedBatch.routines.map{$0["nextRun"] as! String},manualRequest=UUID().uuidString
        let manual=try reopenedBatch.runNow(occurrenceRule,workspace:w,agent:inbox,requestID:manualRequest,store:batchQueue)
        let sameManual=try reopenedBatch.runNow(occurrenceRule,workspace:w,agent:inbox,requestID:manualRequest,store:batchQueue)
        require(manual["id"] as? String==sameManual["id"] as? String && batchQueue.jobs.count==3,"explicit run-now requests are idempotent and do not duplicate work")
        require(manual["previousRoutineResult"] as? String=="Prior verified findings" && manual["routineSeriesID"] as? String==series && manual["inboxQuery"] as? String=="","manual verification keeps routine memory and prior findings")
        require(reopenedBatch.routines.map{$0["nextRun"] as! String}==nextTimes,"running a saved check now never changes its normal intervals")
        require(reopenedBatch.routines.first{$0["id"] as? String==occurrenceRule}?["lastTaskID"] as? String==manual["id"] as? String,"prepared results can find the manual run through the saved routine")
        do{_ = try reopenedBatch.runNow(occurrenceRule,workspace:w,agent:inbox,requestID:UUID().uuidString,store:batchQueue);require(false,"overlapping manual scans rejected")}catch{}
        print("PASS: saved schedule receipt, local timezone/weekdays/DST, deduplication, one wake catch-up, restart idempotency, non-overlap, prior findings, interrupted-run attention and durable pause")

        // Health is judged per routine: one routine's harmless stop never freezes the rest of its series.
        let seriesRoot=root.appendingPathComponent("Series"),seriesRules=try BuddyRoutineStore(directory:seriesRoot),seriesQueue=try BuddyWorkerStore(directory:seriesRoot)
        let three:[String:Any]=["action":"create","title":"Keep notes current","goal":"Review the shared notes and write down what changed","kind":"general","hours":[9,13,17],"minute":0,"weekdays":[1,2,3,4,5,6,7],"timeZone":"UTC"]
        let threeMade=try seriesRules.manage(three,workspace:w,agent:a,requestID:"three",provider:"chatgpt",budget:0,now:now)
        let ids=(threeMade["routines"] as! [[String:Any]]).sorted{($0["hour"] as! Int)<($1["hour"] as! Int)}.map{$0["id"] as! String}
        func routine(_ id:String)->[String:Any] {seriesRules.routines.first{$0["id"] as? String==id}!}
        func at(_ stamp:String)->Date {f.date(from:stamp)!}
        try seriesRules.enqueueDue(store:seriesQueue,workspace:w,now:at("2026-10-17T09:30:00Z"))
        require(seriesQueue.jobs.count==1 && seriesQueue.jobs[0]["routineID"] as? String==ids[0],"the 9:00 routine (A) runs")
        try seriesQueue.update(seriesQueue.jobs[0]["id"] as! String,["status":"interrupted","progress":"The worker restarted."])
        try seriesRules.enqueueDue(store:seriesQueue,workspace:w,now:at("2026-10-17T13:30:00Z"))
        require(seriesQueue.jobs.count==2 && seriesQueue.jobs[1]["routineID"] as? String==ids[1] && seriesRules.routines.allSatisfy{$0["status"] as? String=="active"},"A's run was interrupted with nothing in flight, so B's slot still runs and A stays active: \(seriesRules.routines.map{$0["status"] ?? ""})")
        try seriesQueue.update(seriesQueue.jobs[1]["id"] as! String,["status":"completed","result":"Notes reviewed."])
        require(try seriesQueue.job(seriesQueue.jobs[0]["id"] as! String)["stopCause"] as? String=="superseded","B finishing the same work supersedes A's interrupted run")
        try seriesRules.enqueueDue(store:seriesQueue,workspace:w,now:at("2026-10-17T17:30:00Z"))
        try seriesQueue.update(seriesQueue.jobs.last!["id"] as! String,["status":"completed","result":"Notes reviewed."])
        // A's own runs keep ending without finishing (each superseded or failed): after three in a row only A waits for attention.
        for day in ["18","19"] {
            try seriesRules.enqueueDue(store:seriesQueue,workspace:w,now:at("2026-10-\(day)T09:30:00Z"))
            require(seriesQueue.jobs.last?["routineID"] as? String==ids[0],"A runs on the \(day)th")
            try seriesQueue.update(seriesQueue.jobs.last!["id"] as! String,["status":"failed","progress":"The page did not load."])
            for hour in ["13","17"] {
                try seriesRules.enqueueDue(store:seriesQueue,workspace:w,now:at("2026-10-\(day)T\(hour):30:00Z"))
                require(seriesQueue.jobs.last?["routineID"] as? String==ids[hour=="13" ? 1:2] && seriesQueue.jobs.last?["status"] as? String=="queued","the \(hour):00 routine runs on the \(day)th")
                try seriesQueue.update(seriesQueue.jobs.last!["id"] as! String,["status":"completed","result":"Notes reviewed."])
            }
        }
        require(routine(ids[0])["status"] as? String=="needs_attention" && seriesQueue.jobs.suffix(2).map{$0["routineID"] as? String ?? ""}==[ids[1],ids[2]],"three of A's own runs in a row did not finish, so A waits for attention while B and C keep running")
        let beforeAttention=seriesQueue.jobs.count
        try seriesRules.enqueueDue(store:seriesQueue,workspace:w,now:at("2026-10-20T10:00:00Z"))
        require(routine(ids[0])["status"] as? String=="needs_attention" && routine(ids[1])["status"] as? String=="active" && routine(ids[2])["status"] as? String=="active" && seriesQueue.jobs.count==beforeAttention,"only A waits: \(seriesRules.routines.map{$0["status"] ?? ""})")
        // Reviving A an hour after the slot it missed runs that slot, once.
        require(routine(ids[0])["nextRun"] as? String=="2026-10-20T09:00:00Z","A's missed slot is still on record")
        _ = try seriesRules.manage(["action":"resume","routineID":ids[0]],workspace:w,agent:a,requestID:"revive",provider:"chatgpt",budget:0,now:at("2026-10-20T10:00:00Z"))
        require(routine(ids[0])["status"] as? String=="active" && routine(ids[0])["nextRun"] as? String=="2026-10-20T09:00:00Z","reviving keeps a slot missed within the last day")
        try seriesRules.enqueueDue(store:seriesQueue,workspace:w,now:at("2026-10-20T10:00:00Z"))
        try seriesRules.enqueueDue(store:seriesQueue,workspace:w,now:at("2026-10-20T10:01:00Z"))
        require(seriesQueue.jobs.count==beforeAttention+1 && seriesQueue.jobs.last?["requestId"] as? String=="routine:\(ids[0]):2026-10-20T09:00:00Z" && routine(ids[0])["status"] as? String=="active","exactly one job runs for the slot A missed, and A is not parked again for the runs before it was revived")
        require(routine(ids[0])["nextRun"] as? String=="2026-10-21T09:00:00Z","and A's next slot is its normal one")
        try seriesQueue.update(seriesQueue.jobs.last!["id"] as! String,["status":"completed","result":"Notes reviewed."])
        // A routine the person paused keeps the slot it missed while paused (its siblings running do not move it), and resuming it within the day runs it once.
        _ = try seriesRules.manage(["action":"pause","routineID":ids[2]],workspace:w,agent:a,requestID:"pause-c",provider:"chatgpt",budget:0,now:at("2026-10-20T10:05:00Z"))
        try seriesRules.enqueueDue(store:seriesQueue,workspace:w,now:at("2026-10-21T09:30:00Z"))
        require(seriesQueue.jobs.last?["routineID"] as? String==ids[0] && routine(ids[1])["nextRun"] as? String=="2026-10-21T13:00:00Z" && routine(ids[2])["nextRun"] as? String=="2026-10-20T17:00:00Z","A runs; B's missed slot is skipped, not caught up in a burst; paused C's is kept")
        try seriesQueue.update(seriesQueue.jobs.last!["id"] as! String,["status":"completed","result":"Notes reviewed."])
        _ = try seriesRules.manage(["action":"resume","routineID":ids[2]],workspace:w,agent:a,requestID:"resume-c",provider:"chatgpt",budget:0,now:at("2026-10-21T09:45:00Z"))
        let beforeResume=seriesQueue.jobs.count
        try seriesRules.enqueueDue(store:seriesQueue,workspace:w,now:at("2026-10-21T09:45:00Z"))
        try seriesRules.enqueueDue(store:seriesQueue,workspace:w,now:at("2026-10-21T09:46:00Z"))
        require(seriesQueue.jobs.count==beforeResume+1 && seriesQueue.jobs.last?["requestId"] as? String=="routine:\(ids[2]):2026-10-20T17:00:00Z","resuming C within a day of its missed slot runs that slot once")
        require(try BuddyRoutineStore.resumedNext(["nextRun":"2026-10-19T09:00:00Z","timeZone":"UTC","hour":9,"minute":0,"weekdays":[1,2,3,4,5,6,7]],now:at("2026-10-20T10:00:00Z"))=="2026-10-21T09:00:00Z","a slot missed more than a day ago is skipped, never caught up in a burst") // new-api

        // A scheduled run cannot start coding sessions or give teammates work, so a routine that asks for that is refused with a reason.
        let before=rules.routines.count
        var refusal:BuddyWorkerFailure?
        do{_ = try rules.manage(["action":"create","title":"Keep going","goal":"Every hour, start the next coding session for Forge and give each agent its next task","kind":"general"],workspace:w,agent:a,requestID:"keep-going",provider:"claude",budget:0,now:now)}catch let failure as BuddyWorkerFailure{refusal=failure}
        require(refusal?.code=="unsupported_in_background" && refusal?.message.contains("team plan")==true && rules.routines.count==before,"a routine that would need team work is refused with a reason and nothing is saved: \(String(describing: refusal?.message))") // new-api
        var editRefused=false
        do{_ = try rules.manage(["action":"update","routineID":rid,"goal":"Via check_in, ask Forge for status"],workspace:w,agent:a,requestID:"edit",provider:"claude",budget:0,now:now)}catch{editRefused=true}
        require(editRefused && rules.routines[0]["goal"] as? String==args["goal"] as? String,"an edit that would need team work is refused too, and the routine is unchanged")
        require(BuddyRoutineGoals.unsupported("call buddy_coding_session") && BuddyRoutineGoals.unsupported("Use buddy_computer_task to open the site") && !BuddyRoutineGoals.unsupported(args["goal"] as! String) && !BuddyRoutineGoals.unsupported("Write a coding-session summary for the user"),"only goals that need team work are refused") // new-api
        print("PASS: routine health judged per routine (a harmless stop does not freeze the series; three unfinished own runs park only that routine), revival keeps a slot missed within a day and runs it once, and routines that need team work are refused") // new-api

        // A scheduled run, due or started now, records the team's supervisor like any other task, so its stops reach the supervisor first.
        let supervisedRoot=root.appendingPathComponent("supervised"),chief=UUID().uuidString
        let supervisedRules=try BuddyRoutineStore(directory:supervisedRoot),supervisedQueue=try BuddyWorkerStore(directory:supervisedRoot)
        let daily:[String:Any]=["action":"create","title":"Check AgentMail and Gmail (06:00)","goal":"Check the inbox and say what needs attention","kind":"email","query":"in:inbox newer_than:1d","hour":6,"minute":0,"weekdays":[1,2,3,4,5,6,7],"timeZone":"America/Los_Angeles"]
        let dailyID=(try supervisedRules.manage(daily,workspace:w,agent:a,requestID:"daily",provider:"claude",budget:BuddyRunLimit.none,now:now)["routine"] as! [String:Any])["id"] as! String
        try supervisedRules.enqueueDue(store:supervisedQueue,workspace:w,now:f.date(from:"2026-10-17T14:00:00Z")!,supervisor:chief) // new-api
        require(supervisedQueue.jobs.count==1 && supervisedQueue.jobs[0]["supervisorId"] as? String==chief && supervisedQueue.jobs[0]["routineID"] as? String==dailyID,"a due run records the team's supervisor: \(supervisedQueue.jobs.first?["supervisorId"] ?? "none")")
        try supervisedQueue.update(supervisedQueue.jobs[0]["id"] as! String,["status":"completed"])
        let manualRun=try supervisedRules.runNow(dailyID,workspace:w,agent:a,requestID:UUID().uuidString,store:supervisedQueue,supervisor:chief) // new-api
        require(manualRun["supervisorId"] as? String==chief,"so does a run started now")
        let unsupervised=try supervisedRules.runNow(dailyID,workspace:w,agent:a,requestID:UUID().uuidString,store:BuddyWorkerStore(directory:supervisedRoot.appendingPathComponent("none")),supervisor:nil) // new-api
        require(unsupervised["supervisorId"]==nil,"and with no supervisor it names none")
        print("PASS: scheduled runs, due or started now, record the team's supervisor like any task") // new-api
    }
}
