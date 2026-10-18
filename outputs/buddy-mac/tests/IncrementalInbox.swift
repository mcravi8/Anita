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
        print("PASS: latest-only queries, durable per-batch checkpoints, cross-schedule deduplication, new follow-ups, unfinished-read retries, pagination safety, legacy migration, account isolation and corrupt-state rejection")
    }
}
