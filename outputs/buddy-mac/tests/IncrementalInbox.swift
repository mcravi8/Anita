import Foundation
@main struct IncrementalInboxTests {
    @MainActor static func require(_ value:Bool,_ message:String){if !value{fputs("FAILED: \(message)\n",stderr);exit(1)}}
    @MainActor static func main() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("buddy-incremental-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let w=UUID().uuidString,a=UUID().uuidString,t0=Date(timeIntervalSince1970:1792353600)
        var service=BuddyInboxReview(support:root),mailbox="one@example.invalid",reads=[String](),queries=[String](),fail=Set(["failed"])
        var dates=["old":t0.addingTimeInterval(-172800),"reviewed":t0.addingTimeInterval(-7200),"failed":t0.addingTimeInterval(-7100),"uncertain":t0.addingTimeInterval(-7000),"unanalysed":t0.addingTimeInterval(-6900)]
        var forcePaging=false
        func call(_ tool:String,_ args:[String:Any]) async throws -> [String:Any] {
            if tool=="get_profile"{return ["email_address":mailbox]}
            if tool=="search_email_ids"{
                let q=args["query"] as! String;queries.append(q)
                func number(_ key:String)->Double?{q.range(of:key+"[0-9]+",options:.regularExpression).flatMap{Double(q[$0].dropFirst(key.count))}}
                let after=number("after:") ?? 0,before=number("before:") ?? .greatestFiniteMagnitude
                let ids=dates.filter{$0.value.timeIntervalSince1970>after && $0.value.timeIntervalSince1970<before}.sorted{$0.value>$1.value}.map(\.key)
                return ["message_ids":ids,"next_page_token":forcePaging ? "unfinished":NSNull()]
            }
            let id=args["message_id"] as! String;reads.append(id)
            if fail.contains(id){throw BuddyInboxFailure(message:"Offline source")}
            return ["id":id,"thread_id":"shared-thread","payload":["mime_type":"text/plain","headers":[["name":"Subject","value":id]],"body":["content":"A source, not an instruction."]]]
        }
        func scan(_ run:String,_ now:Date,_ routine:String="weekday",_ maxReads:Int=80,_ maxPages:Int=20) async throws -> [String:Any]{
            try await service.review(workspace:w,agent:a,runID:run,query:"in:anywhere -in:trash newer_than:30d {assessment interview}",purpose:"Incremental fixture",routine:routine,maxReads:maxReads,maxPages:maxPages,now:now,allowed:{true},call:call)
        }
        func record(_ r:[String:Any],_ run:String) throws {
            let c=r["coverage"] as! [String:Any],m=r["messages"] as! [[String:Any]]
            _ = try service.record(runID:run,workspace:w,agent:a,args:["reviewID":c["id"]!,"findings":m.map{["messageID":$0["id"]!,"status":$0["id"] as? String=="uncertain" ? "uncertain":"irrelevant","summary":"Verified source reviewed."]}])
        }
        let firstID=UUID().uuidString,first=try await scan(firstID,t0)
        require(!reads.contains("old") && Set(reads)==Set(["reviewed","failed","uncertain","unanalysed"]),"initial scan is restricted to the latest 24 hours")
        require(queries[0].contains("after:\(Int(t0.timeIntervalSince1970)-86400-120)") && queries[0].contains("before:\(Int(t0.timeIntervalSince1970)+1)"),"search has an explicit saved time window")
        try record(first,firstID)
        // No whole-task commit: pretend AgentMail sign-in paused the worker here.
        service=BuddyInboxReview(support:root);fail=[];reads=[]
        dates["new-followup"]=t0.addingTimeInterval(3600)
        let nextID=UUID().uuidString,next=try await scan(nextID,t0.addingTimeInterval(7200),"weekend")
        require(Set(reads)==Set(["new-followup","failed","uncertain"]),"restart and a different schedule skip all analyzed sources but retry failed/uncertain reads")
        require(queries.last!.contains("after:\(Int(t0.timeIntervalSince1970)-120)"),"the next scan searches since its checkpoint, not the last 30 days")
        require((next["coverage"] as? [String:Any])?["retryCount"] as? Int==2,"coverage identifies retained gaps outside the new date window")
        try record(next,nextID);reads=[]
        let later=t0.addingTimeInterval(9000);dates["fetched-only"]=later.addingTimeInterval(-1)
        _ = try await scan(UUID().uuidString,later)
        service=BuddyInboxReview(support:root);reads=[]
        _ = try await scan(UUID().uuidString,later.addingTimeInterval(7200))
        require(reads.contains("fetched-only") && !reads.contains("reviewed"),"fetching without analysis never marks an email done")
        // A partial search cannot move past unseen pages.
        let ledger=try FileManager.default.contentsOfDirectory(at:service.root,includingPropertiesForKeys:nil).first{$0.lastPathComponent.hasPrefix("seen-")}!
        let before=try JSONSerialization.jsonObject(with:Data(contentsOf:ledger)) as! [String:Any]
        forcePaging=true
        _ = try await scan(UUID().uuidString,later.addingTimeInterval(14400),"weekend",1,1)
        let after=try JSONSerialization.jsonObject(with:Data(contentsOf:ledger)) as! [String:Any]
        let oldScan=(before["scans"] as! [String:[String:Any]]).values.first!,newScan=(after["scans"] as! [String:[String:Any]]).values.first!
        require(oldScan["since"] as? Int==newScan["since"] as? Int,"unfinished pagination never advances the date checkpoint")
        forcePaging=false;mailbox="different@example.invalid";reads=[]
        _ = try await scan(UUID().uuidString,t0.addingTimeInterval(14400))
        require(reads.contains("reviewed"),"another Gmail account cannot inherit read history")
        // Preserve imported historical analysis, without inventing coverage for unread mail.
        let legacyRoot=root.appendingPathComponent("legacy"),legacy=BuddyInboxReview(support:legacyRoot)
        try FileManager.default.createDirectory(at:legacy.root,withIntermediateDirectories:true)
        let receipt:[String:Any] = ["workspace":w,"agent":a,"accountHash":BuddyInboxReview.accountHash(mailbox),"committed":true,"analysisRecorded":true,"readIDs":["reviewed"],"findings":[["messageID":"reviewed","status":"irrelevant","summary":"Actually reviewed before upgrade."]]]
        try JSONSerialization.data(withJSONObject:receipt).write(to:legacy.root.appendingPathComponent(UUID().uuidString+"-"+UUID().uuidString+".json"))
        reads=[]
        _ = try await legacy.review(workspace:w,agent:a,runID:UUID().uuidString,query:"assessment",purpose:"Migration",routine:"new",now:t0,allowed:{true},call:call)
        require(!reads.contains("reviewed") && reads.contains("failed"),"upgrade imports verified past analysis without treating old unread messages as reviewed")
        var corrupt=after;corrupt["scans"]=["broken"]
        try JSONSerialization.data(withJSONObject:corrupt).write(to:ledger)
        mailbox="one@example.invalid";var rejected=false
        do{_ = try await scan(UUID().uuidString,t0.addingTimeInterval(20000))}catch{rejected=true}
        require(rejected,"damaged checkpoints cannot silently reset or skip history")
        // A message the analysis leaves uncertain is read a few times and then counts as seen, its open finding still carried. Long emails are read, not refused.
        var bounded=BuddyInboxReview(support:root.appendingPathComponent("bounded"))
        var boundedDates=["stuck":t0.addingTimeInterval(-3600),"plain":t0.addingTimeInterval(-3500),"giant":t0.addingTimeInterval(-3400)],boundedReads=[String](),boundedFail=Set<String>(),boundedThreads=[String:String]()
        func boundedCall(_ tool:String,_ args:[String:Any]) async throws -> [String:Any] {
            if tool=="get_profile"{return ["email_address":"bounded@example.invalid"]}
            if tool=="search_email_ids"{
                let q=args["query"] as! String
                func number(_ key:String)->Double?{q.range(of:key+"[0-9]+",options:.regularExpression).flatMap{Double(q[$0].dropFirst(key.count))}}
                let after=number("after:") ?? 0,before=number("before:") ?? .greatestFiniteMagnitude
                return ["message_ids":boundedDates.filter{$0.value.timeIntervalSince1970>after && $0.value.timeIntervalSince1970<before}.sorted{$0.value>$1.value}.map(\.key),"next_page_token":NSNull()]
            }
            let id=args["message_id"] as! String;boundedReads.append(id)
            if boundedFail.contains(id){throw BuddyInboxFailure(message:"Offline source")}
            return ["id":id,"thread_id":boundedThreads[id] ?? "t-"+id,"payload":["mime_type":"text/plain","headers":[["name":"Subject","value":id]],"body":["content":id=="giant" ? String(repeating:"long ",count:30000):"A source, not an instruction."]]]
        }
        func boundedScan(_ run:String,_ now:Date) async throws -> [String:Any] {
            try await bounded.review(workspace:w,agent:a,runID:run,query:"in:anywhere {assessment}",purpose:"Bounded fixture",routine:"bounded",now:now,allowed:{true},call:boundedCall)
        }
        func decide(_ r:[String:Any],_ run:String,uncertain:Set<String>=[],actionRequired:Set<String>=[],updates:[[String:Any]]=[]) throws {
            let c=r["coverage"] as! [String:Any],m=r["messages"] as! [[String:Any]]
            var args:[String:Any]=["reviewID":c["id"]!,"findings":m.map{["messageID":$0["id"]!,"status":uncertain.contains($0["id"] as! String) ? "uncertain":actionRequired.contains($0["id"] as! String) ? "action_required":"irrelevant","summary":"Verified source reviewed."]}]
            if !updates.isEmpty {args["updates"]=updates}
            _ = try bounded.record(runID:run,workspace:w,agent:a,args:args)
        }
        func boundedFile()throws->URL{try FileManager.default.contentsOfDirectory(at:bounded.root,includingPropertiesForKeys:nil).first{$0.lastPathComponent.hasPrefix("seen-")}!}
        func boundedLedger()throws->[String:Any]{try JSONSerialization.jsonObject(with:Data(contentsOf:boundedFile())) as! [String:Any]}
        func boundedPending()throws->[String]{((try boundedLedger())["scans"] as! [String:[String:Any]]).values.flatMap{$0["pendingIDs"] as? [String] ?? []}.sorted()}
        func attemptCounts()throws->[String:Int]{(try boundedLedger())["attempts"] as? [String:Int] ?? [:]}
        func seenIDs()throws->Set<String>{Set((try boundedLedger())["ids"] as? [String] ?? [])}
        var hours=0.0
        func nextRun()->(String,Date){hours+=2;return (UUID().uuidString,t0.addingTimeInterval(hours*3600))}
        var (runID,at)=nextRun();var r=try await boundedScan(runID,at)
        var cov=r["coverage"] as! [String:Any]
        let giant=(r["messages"] as! [[String:Any]]).first{$0["id"] as? String=="giant"}
        require(Set(boundedReads)==Set(["stuck","plain","giant"]) && cov["read"] as? Int==3 && cov["partial"] as? Bool==false && cov["longMessages"] as? [String]==["giant"],"a very long email is read, not refused, and flagged as long")
        require(giant?["truncated"] as? Bool==true && (giant?["body"] as? String)?.count==BuddyInboxReview.bodyLimit,"only its first part is passed on")
        try decide(r,runID,uncertain:["stuck"])
        var counts=try attemptCounts(),pendingNow=try boundedPending(),done=try seenIDs()
        require(counts==["stuck":1] && pendingNow==["stuck"],"a message left uncertain is counted, and stays pending the first time")
        require(done.contains("giant") && done.contains("plain"),"a long email that was analysed is done like any other")
        boundedReads=[];(runID,at)=nextRun();r=try await boundedScan(runID,at)
        require(boundedReads==["stuck"],"it is read once more")
        try decide(r,runID,uncertain:["stuck"])
        counts=try attemptCounts()
        require(counts==["stuck":2],"and counted again")
        boundedReads=[];(runID,at)=nextRun();r=try await boundedScan(runID,at)
        require(boundedReads==["stuck"],"and a third time")
        try decide(r,runID,uncertain:["stuck"])
        var state=try boundedLedger();pendingNow=try boundedPending()
        require(state["attempts"]==nil && (state["ids"] as! [String]).contains("stuck") && pendingNow.isEmpty,"after the limit it counts as seen and is no longer pending")
        require((state["findings"] as? [String:Any])?["stuck"] != nil,"but its open finding is kept")
        boundedReads=[];(runID,at)=nextRun();r=try await boundedScan(runID,at)
        cov=r["coverage"] as! [String:Any]
        require(boundedReads.isEmpty && cov["retryCount"] as? Int==0 && (r["previousFindings"] as! [[String:Any]]).contains{$0["messageID"] as? String=="stuck"},"it is no longer read, and every run is still shown its open finding")
        // Analysis that was never recorded is retried until it is, and does not count against the limit.
        boundedDates["flaky"]=at.addingTimeInterval(-60)
        boundedReads=[];(runID,at)=nextRun();r=try await boundedScan(runID,at)
        require(boundedReads==["flaky"],"a new message is read")
        boundedReads=[];(runID,at)=nextRun();r=try await boundedScan(runID,at)
        counts=try attemptCounts()
        require(boundedReads==["flaky"] && counts.isEmpty,"a message whose analysis was never recorded is read again, and that is not counted")
        try decide(r,runID)
        boundedReads=[];(runID,at)=nextRun();r=try await boundedScan(runID,at)
        require(boundedReads.isEmpty,"once its analysis is recorded it is done")
        // A message that settles into a real finding is done, and its count is cleared.
        boundedDates["wobbly"]=at.addingTimeInterval(-60)
        boundedReads=[];(runID,at)=nextRun();r=try await boundedScan(runID,at);try decide(r,runID,uncertain:["wobbly"])
        counts=try attemptCounts()
        require(counts["wobbly"]==1,"an uncertain message is counted")
        boundedReads=[];(runID,at)=nextRun();r=try await boundedScan(runID,at);try decide(r,runID,actionRequired:["wobbly"])
        counts=try attemptCounts();done=try seenIDs()
        require(boundedReads==["wobbly"] && counts["wobbly"]==nil && done.contains("wobbly"),"once it becomes a real finding its count is cleared and it is done")
        // A finding settled by newer evidence needs no second look at the message it came from.
        boundedDates["origin"]=at.addingTimeInterval(-100)
        boundedReads=[];(runID,at)=nextRun();r=try await boundedScan(runID,at);try decide(r,runID,uncertain:["origin"])
        boundedDates["evidence"]=at.addingTimeInterval(-60)
        boundedReads=[];(runID,at)=nextRun();r=try await boundedScan(runID,at)
        try decide(r,runID,uncertain:["origin"],updates:[["messageID":"origin","evidenceMessageID":"evidence","status":"resolved","summary":"Settled by the newer message."]])
        state=try boundedLedger();pendingNow=try boundedPending();counts=try attemptCounts();done=try seenIDs()
        require(done.contains("origin") && pendingNow.isEmpty && counts["origin"]==nil && (state["findings"] as? [String:Any])?["origin"]==nil,"a finding settled by newer evidence is closed and its message is not read again")
        // Pacing: what is new is said at once, a scan with nothing new is silent, and what is still open is brought up again only once a day.
        boundedDates["pace-new"]=at.addingTimeInterval(-60)
        boundedReads=[];(runID,at)=nextRun();r=try await boundedScan(runID,at);try decide(r,runID,actionRequired:["pace-new"])
        require(bounded.pacing(runID:runID)=="news","a scan that finds something new says so")
        boundedDates["pace-noise"]=at.addingTimeInterval(-60)
        (runID,at)=nextRun();r=try await boundedScan(runID,at);try decide(r,runID)
        require(bounded.pacing(runID:runID)=="quiet","a scan that finds only noise, soon after the person was told, is silent")
        (runID,at)=nextRun();r=try await boundedScan(runID,at);try bounded.commit(runID:runID)
        require(bounded.pacing(runID:runID)=="quiet","and so is one that finds nothing at all")
        var pacedLedger=try boundedLedger();pacedLedger["digestAt"]=ISO8601DateFormatter().string(from:Date().addingTimeInterval(-21*3600));try JSONSerialization.data(withJSONObject:pacedLedger).write(to:boundedFile())
        boundedDates["pace-noise-2"]=at.addingTimeInterval(-60)
        (runID,at)=nextRun();r=try await boundedScan(runID,at);try decide(r,runID)
        require(bounded.pacing(runID:runID)=="reminder","a day later the open items are brought up again")
        boundedDates["pace-noise-3"]=at.addingTimeInterval(-60)
        (runID,at)=nextRun();r=try await boundedScan(runID,at);try decide(r,runID)
        require(bounded.pacing(runID:runID)=="quiet","and not again at the next scan")
        require(bounded.pacing(runID:UUID().uuidString)==nil,"a run that did no routine check has no verdict")
        // Old memory without counters still works; a damaged counter is refused rather than guessed.
        var old=try boundedLedger();old.removeValue(forKey:"attempts")
        try JSONSerialization.data(withJSONObject:old).write(to:boundedFile())
        boundedReads=[];(runID,at)=nextRun();_ = try await boundedScan(runID,at)
        old["attempts"]=["x":"not a number"]
        try JSONSerialization.data(withJSONObject:old).write(to:boundedFile())
        var damaged=false;do{(runID,at)=nextRun();_ = try await boundedScan(runID,at)}catch{damaged=true}
        require(damaged,"memory written before counters existed still loads, and damaged counters are refused")
        // The rule as it meets the real mailbox. The app is restarted before every run, so nothing but the cursor file can carry a count.
        require(BuddyInboxReview.uncertainReadLimit>=1 && BuddyInboxReview.uncertainReadLimit<=5,"an uncertain message is read a small fixed number of times")
        let shapeSupport=root.appendingPathComponent("cursor-before-counters")
        bounded=BuddyInboxReview(support:shapeSupport);boundedDates=[:];boundedReads=[];boundedFail=[];boundedThreads=[:]
        (runID,at)=nextRun();r=try await boundedScan(runID,at)
        // Rewrite the cursor as an older app left it: one pending message that already has an open uncertain finding, no counter and no seen IDs.
        var shape=try boundedLedger()
        let shapeKey=(shape["scans"] as! [String:[String:Any]]).keys.first!
        shape["scans"]=[shapeKey:["since":Int(at.timeIntervalSince1970),"pendingIDs":["old-stuck"]]]
        shape["findings"]=["old-stuck":["messageID":"old-stuck","status":"uncertain","summary":"Could not tell whether the test was taken.","subject":"old-stuck","url":"","at":ISO8601DateFormatter().string(from:at)]]
        shape["ids"]=[String]();shape.removeValue(forKey:"attempts")
        try JSONSerialization.data(withJSONObject:shape).write(to:boundedFile())
        // It is older than any scan window, so only the retry list can find it.
        boundedDates["old-stuck"]=at.addingTimeInterval(-5*86400);boundedThreads["old-stuck"]="thread-1"
        for n in 1...BuddyInboxReview.uncertainReadLimit {
            bounded=BuddyInboxReview(support:shapeSupport);boundedReads=[];(runID,at)=nextRun();r=try await boundedScan(runID,at)
            require(boundedReads==["old-stuck"] && (r["previousFindings"] as! [[String:Any]]).contains{$0["messageID"] as? String=="old-stuck"},"a cursor from before counters still retries its pending message (read \(n)), and shows it its open finding")
            bounded=BuddyInboxReview(support:shapeSupport);try decide(r,runID,uncertain:["old-stuck"])
            let kept=try attemptCounts()
            if n<BuddyInboxReview.uncertainReadLimit {require(kept==["old-stuck":n],"the count survives the restart in the cursor file")}
            else {let waiting=try boundedPending();require(kept.isEmpty && waiting.isEmpty,"at the limit the count and the pending entry leave the cursor file, as the message now counts as seen")}
        }
        for _ in 0..<6 {
            bounded=BuddyInboxReview(support:shapeSupport);boundedReads=[];hours+=70;(runID,at)=nextRun();r=try await boundedScan(runID,at)
            cov=r["coverage"] as! [String:Any]
            require(boundedReads.isEmpty && cov["retryCount"] as? Int==0 && cov["partial"] as? Bool==false,"after the limit the message is not read again, however many days pass, and the run is not left partial")
            require((r["previousFindings"] as! [[String:Any]]).contains{$0["messageID"] as? String=="old-stuck" && $0["status"] as? String=="uncertain"},"but its uncertain finding is still shown to every run")
        }
        let doneNow=try seenIDs(),stillPending=try boundedPending()
        require(stillPending.isEmpty && doneNow==Set(["old-stuck"]),"it is no longer pending and counts as seen")
        // Mail that arrives later in the same thread is new, so it is read and can change what is open, without the first message being read again.
        boundedDates["reply"]=at.addingTimeInterval(-60);boundedThreads["reply"]="thread-1"
        bounded=BuddyInboxReview(support:shapeSupport);boundedReads=[];(runID,at)=nextRun();r=try await boundedScan(runID,at)
        require(boundedReads==["reply"],"a newer message in the same thread is read, and the stuck one is not")
        try decide(r,runID,updates:[["messageID":"old-stuck","evidenceMessageID":"reply","status":"action_required","summary":"The reply says the test is due Friday."]])
        state=try boundedLedger()
        require((state["findings"] as? [String:[String:Any]])?["old-stuck"]?["status"] as? String=="action_required" && (state["findings"] as? [String:[String:Any]])?["old-stuck"]?["summary"] as? String=="The reply says the test is due Friday.","the newer message changes the open finding")
        boundedDates["done"]=at.addingTimeInterval(-60);boundedThreads["done"]="thread-1"
        bounded=BuddyInboxReview(support:shapeSupport);boundedReads=[];(runID,at)=nextRun();r=try await boundedScan(runID,at)
        try decide(r,runID,updates:[["messageID":"old-stuck","evidenceMessageID":"done","status":"resolved","summary":"Confirmed taken."]])
        state=try boundedLedger()
        require(boundedReads==["done"] && (state["findings"] as? [String:Any])?["old-stuck"]==nil && boundedReads.filter{$0=="old-stuck"}.isEmpty,"a later message closes it, and still the stuck one is never re-read")
        // A read that fails is not an uncertain answer: it is retried on every run, past the limit, and uses up no attempts (an analysis that is never recorded is covered above).
        boundedDates["offline"]=at.addingTimeInterval(-60);boundedFail=["offline"]
        for _ in 0..<(BuddyInboxReview.uncertainReadLimit+2) {
            bounded=BuddyInboxReview(support:shapeSupport);boundedReads=[];(runID,at)=nextRun();r=try await boundedScan(runID,at)
            cov=r["coverage"] as! [String:Any]
            require(boundedReads==["offline"] && cov["read"] as? Int==0 && cov["partial"] as? Bool==true,"a message that cannot be read is tried again on every run and shown as an unfinished read")
            let counted=try attemptCounts(),waiting=try boundedPending()
            require(counted.isEmpty && waiting==["offline"],"and it is neither counted nor dropped")
        }
        boundedFail=[];bounded=BuddyInboxReview(support:shapeSupport);boundedReads=[];(runID,at)=nextRun();r=try await boundedScan(runID,at);try decide(r,runID,uncertain:["offline"])
        let firstAttempt=try attemptCounts()
        require(boundedReads==["offline"] && firstAttempt==["offline":1],"its first real analysis is the first attempt")
        print("PASS: latest-only queries, durable per-batch checkpoints, cross-schedule deduplication, new follow-ups, unfinished-read retries, pagination safety, legacy migration, account isolation, corrupt-state rejection, bounded re-reads of uncertain messages with their findings kept, long emails read not refused, settled findings closed, memory from before counters, the limit with a restart before every run, newer mail in the same thread changing an open finding, and failed reads retried without being counted")
    }
}
