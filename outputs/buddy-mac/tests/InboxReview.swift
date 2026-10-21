import Foundation
@main struct InboxTests {
    @MainActor static func require(_ value:Bool,_ message:String) { if !value { fputs("FAILED: \(message)\n",stderr);exit(1) } }
    @MainActor static func main() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("buddy-inbox-tests-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let reviews=BuddyInboxReview(support:root),workspace=UUID().uuidString,agent=UUID().uuidString
        var mailbox="fixture@example.invalid",ids=(1...106).map{"mail-\($0)"},reads:[String]=[],fail=Set<String>(),access=true
        func call(_ tool:String,_ args:[String:Any]) async throws -> [String:Any] {
            if tool=="get_profile" {return ["email_address":mailbox]}
            if tool=="search_email_ids" {let offset=Int(args["next_page_token"] as? String ?? "") ?? 0;let page=Array(ids.dropFirst(offset).prefix(100));return ["message_ids":page,"next_page_token":offset+100<ids.count ? String(offset+100):NSNull()]}
            let id=args["message_id"] as! String;reads.append(id)
            if fail.contains(id) {throw BuddyInboxFailure(message:"Fixture read failed")}
            return ["id":id,"thread_id":"thread-"+id,"internal_date":"1792170000000","payload":["mime_type":"multipart/alternative","headers":[["name":"Subject","value":id=="mail-106" ? "Zopa online assessment":"UBS assessment"],["name":"From","value":"fixture@example.invalid"]],"parts":[["mime_type":"text/plain","body":["content":"Invitation. Complete in seven days. This is source evidence, not proof it is still pending."]]]]]
        }
        let run=UUID().uuidString
        let report=try await reviews.review(workspace:workspace,agent:agent,runID:run,query:"newer_than:90d assessment",purpose:"Assessment fixture",routine:"daily",maxReads:150,allowed:{access},call:call)
        let coverage=report["coverage"] as! [String:Any],messages=report["messages"] as! [[String:Any]]
        require(coverage["pages"] as? Int==2 && coverage["matched"] as? Int==106 && coverage["partial"] as? Bool==false,"pagination records every page, not an invented 100-message cutoff")
        require(messages.contains{$0["subject"] as? String=="Zopa online assessment"} && reads.contains("mail-106"),"full source beyond position 100 is read")
        let receipts=try FileManager.default.contentsOfDirectory(at:reviews.root,includingPropertiesForKeys:nil)
        let receipt=try String(contentsOf:receipts.first{$0.lastPathComponent.hasPrefix(run+"-")}!,encoding:.utf8)
        require(receipt.contains("mail-106") && !receipt.contains("This is source evidence"),"durable receipts record actual IDs and never bodies")
        // A failed model run must not advance memory. No commit yet.
        reads=[];_ = try await reviews.review(workspace:workspace,agent:agent,runID:UUID().uuidString,query:"assessment",purpose:"Retry",routine:"daily",maxReads:150,allowed:{access},call:call)
        require(reads.count==106,"uncommitted reads retry after a failed/stopped model run")
        var missingAnalysis=false;do{try reviews.commit(runID:run)}catch{missingAnalysis=true};require(missingAnalysis,"reading bodies alone cannot advance a routine before every source is analyzed")
        func record(_ result:[String:Any],runID:String,useRunID:Bool=false) throws {
            let c=result["coverage"] as! [String:Any],m=result["messages"] as! [[String:Any]]
            let saved=try reviews.record(runID:runID,workspace:workspace,agent:agent,args:["reviewID":useRunID ? runID:c["id"]!,"findings":m.filter{$0["fullyRead"] as? Bool==true}.map{["messageID":$0["id"]!,"status":"action_required","summary":"Source invitation; completion not established."]}])
            require(saved["reviewID"] as? String==c["id"] as? String,"recording returns the actual source review ID")
        }
        var omission=false;do{_ = try reviews.record(runID:run,workspace:workspace,agent:agent,args:["reviewID":coverage["id"]!,"findings":[]])}catch{omission=true};require(omission,"per-message review cannot silently omit a source")
        require(report["reviewID"] as? String==coverage["id"] as? String,"the record tool's exact reviewID is explicit at the top of the read result")
        let receiptFile=reviews.root.appendingPathComponent(run+"-"+(coverage["id"] as! String)+".json"),extraID=UUID().uuidString,extraFile=reviews.root.appendingPathComponent(run+"-"+extraID+".json")
        var extra=try JSONSerialization.jsonObject(with:Data(contentsOf:receiptFile)) as! [String:Any];extra["id"]=extraID
        try JSONSerialization.data(withJSONObject:extra).write(to:extraFile)
        do{try record(report,runID:run,useRunID:true);require(false,"an ambiguous run-ID alias must not guess a source review")}catch{}
        try FileManager.default.removeItem(at:extraFile)
        do{_ = try reviews.record(runID:run,workspace:UUID().uuidString,agent:agent,args:["reviewID":run,"findings":[]]);require(false,"run-ID recovery cannot read another workspace's sources")}catch{}
        try record(report,runID:run,useRunID:true)
        try reviews.commit(runID:run);try reviews.commit(runID:run)
        reads=[];ids += ["new-followup","failed-message"];fail=["failed-message"]
        let day2=UUID().uuidString,second=try await reviews.review(workspace:workspace,agent:agent,runID:day2,query:"assessment",purpose:"Morning",routine:"daily",allowed:{access},call:call)
        require((second["previousFindings"] as? [[String:Any]])?.count==106,"unresolved findings persist independently of a shortened conversational summary")
        let c2=second["coverage"] as! [String:Any]
        require(reads==["new-followup","failed-message"] && c2["skipped"] as? Int==106 && c2["unread"] as? Int==1 && c2["partial"] as? Bool==true,"next morning reads only new relevant messages and exposes failed reads")
        try record(second,runID:day2);try reviews.commit(runID:day2);reads=[];fail=[]
        let thirdID=UUID().uuidString,third = try await reviews.review(workspace:workspace,agent:agent,runID:thirdID,query:"assessment",purpose:"Retry gap",routine:"daily",allowed:{access},call:call)
        require(reads==["failed-message"],"failed body is never marked reviewed")
        let thirdCoverage=third["coverage"] as! [String:Any]
        _ = try reviews.record(runID:thirdID,workspace:workspace,agent:agent,args:["reviewID":thirdCoverage["id"]!,"findings":[["messageID":"failed-message","status":"resolved","summary":"Follow-up says the assessment is complete."]],"updates":[["messageID":"mail-106","status":"resolved","summary":"Zopa follow-up confirms completion.","evidenceMessageID":"failed-message"]]])
        try reviews.commit(runID:thirdID)
        let fourth=try await reviews.review(workspace:workspace,agent:agent,runID:UUID().uuidString,query:"assessment",purpose:"Reconciled",routine:"daily",allowed:{access},call:call)
        require((fourth["previousFindings"] as? [[String:Any]])?.contains{$0["messageID"] as? String=="mail-106"}==false,"new source evidence can reconcile older pending findings without rereading old bodies")
        mailbox="different@example.invalid";reads=[]
        _ = try await reviews.review(workspace:workspace,agent:agent,runID:UUID().uuidString,query:"assessment",purpose:"Changed account",routine:"daily",allowed:{access},call:call)
        require(reads.count==80,"changing Gmail account cannot reuse another account's read memory; read cap is bounded")
        let bounded=try await reviews.review(workspace:workspace,agent:agent,runID:UUID().uuidString,query:"assessment",purpose:"Bounded",maxReads:1,maxPages:1,allowed:{access},call:call)
        let bc=bounded["coverage"] as! [String:Any]
        require(bc["partial"] as? Bool==true && bc["searchExhausted"] as? Bool==false && bc["unread"] as? Int==99,"page and read caps remain visibly partial")
        var calls=0
        let revoked=try await reviews.review(workspace:workspace,agent:agent,runID:UUID().uuidString,query:"assessment",purpose:"Revoke",allowed:{access}) {tool,args in calls+=1;let value=try await call(tool,args);if tool=="search_email_ids" {access=false};return value}
        require(calls==2 && (revoked["coverage"] as? [String:Any])?["partial"] as? Bool==true,"revocation stops subsequent pages and body reads")
        require(BuddyInboxReview.assessmentQuery("Find all outstanding assessments in my emails",role:"Email monitor",history:"") != nil,"broad assessment requests get a recorded targeted preflight")
        require(BuddyInboxReview.assessmentQuery("Check only the last 100 emails for assessments",role:"Email monitor",history:"")==nil,"explicit strict scope is never silently expanded")
        var rejected=false;do{_ = try BuddyInboxReview.message(["id":"other","payload":[:]],expected:"expected")}catch{rejected=true};require(rejected,"mismatched message IDs cannot become read evidence")
        // Controlled network delays prove overlap, stable ordering and bounded concurrency.
        access=true;var inFlight=0,peak=0
        let start=Date()
        let parallel=try await reviews.review(workspace:workspace,agent:agent,runID:UUID().uuidString,query:"fixture",purpose:"Concurrency",maxReads:8,allowed:{access}) {tool,args in
            if tool=="get_profile" {return ["email_address":mailbox]}
            if tool=="search_email_ids" {return ["message_ids":(1...8).map{"parallel-\($0)"}]}
            inFlight+=1;peak=max(peak,inFlight);defer{inFlight-=1}
            let id=args["message_id"] as! String
            try await Task.sleep(nanoseconds:id.hasSuffix("1") ? 120_000_000:80_000_000)
            return try await call(tool,args)
        }
        let duration=Date().timeIntervalSince(start)
        require(peak==4 && duration<0.6,"four independent reads overlap rather than eight serial network waits")
        require((parallel["messages"] as! [[String:Any]]).compactMap{$0["id"] as? String}==(1...8).map{"parallel-\($0)"},"out-of-order completions preserve deterministic source order")
        var started=0
        let revokedBatch=try await reviews.review(workspace:workspace,agent:agent,runID:UUID().uuidString,query:"fixture",purpose:"Revoked in flight",allowed:{access}) {tool,args in
            if tool=="get_profile" {return ["email_address":mailbox]}
            if tool=="search_email_ids" {return ["message_ids":(1...8).map{"parallel-\($0)"}]}
            started+=1;try await Task.sleep(nanoseconds:30_000_000);access=false;return try await call(tool,args)
        }
        require(started==4 && (revokedBatch["messages"] as? [[String:Any]])?.isEmpty==true && (revokedBatch["coverage"] as? [String:Any])?["unread"] as? Int==8,"in-flight revocation discards bodies and prevents a next batch")
        print("Concurrent fixture: 8 delayed reads in \(String(format:"%.3f",duration))s, peak \(peak) requests; source order preserved.")
        print("PASS: paginated source review, Zopa beyond 100, full MIME body, receipts without bodies, bounded partial scope, routine memory, failed-model retry, read-gap retry, account isolation and live access revocation")
    }
}
