import Foundation
import CryptoKit

/// Native coordination journal. It records internal requests/responses, never
/// turns a model's status report into an authoritative external-action receipt.
@MainActor final class BuddyTeamMonitorStore {
    let url:URL
    private(set) var value:[String:Any]
    var checks:[[String:Any]] {value["checks"] as? [[String:Any]] ?? []}
    var updates:[[String:Any]] {value["updates"] as? [[String:Any]] ?? []}
    init(support:URL)throws {
        url=support.appendingPathComponent("team-monitor.json")
        if FileManager.default.fileExists(atPath:url.path) {
            let data=try Data(contentsOf:url)
            guard data.count<24*1024*1024,let saved=try JSONSerialization.jsonObject(with:data) as? [String:Any],saved["version"] as? Int==1,saved["settings"] is [String:[String:Any]],let checks=saved["checks"] as? [[String:Any]],checks.count<=1000,saved["updates"] is [[String:Any]],checks.allSatisfy({($0["id"] as? String).flatMap(UUID.init(uuidString:)) != nil && ["memory","checkin","overview"].contains($0["kind"] as? String ?? "")}) else{throw BuddyWorkerFailure(message:"Buddy couldn't verify saved team check-ins. Restore team-monitor.json before restarting.")}
            value=saved
        } else {value=["version":1,"settings":[String:[String:Any]](),"checks":[[String:Any]](),"updates":[[String:Any]](),"observed":[String:[String:Any]](),"daily":[String:Any]()]}
        for j in checks where j["status"] as? String=="running" {try update(j["id"] as! String,["status":"interrupted","error":"The worker restarted during this check. It has not been repeated; retry when ready."])}
    }
    private func save()throws {let data=try JSONSerialization.data(withJSONObject:value,options:.sortedKeys);guard data.count<24*1024*1024 else{throw BuddyWorkerFailure(message:"Team check-in history is full. Review old check-ins before continuing.")};try data.write(to:url,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)}
    private func mutate(_ operation:()throws->Void)throws {let old=value;do{try operation();value["journalRevision"]=(old["journalRevision"] as? Int ?? 0)+1;try save()}catch{value=old;throw error}}
    static func stamp(_ now:Date)->String {ISO8601DateFormatter().string(from:now)}
    static func day(_ now:Date)->String {let f=DateFormatter();f.locale=Locale(identifier:"en_US_POSIX");f.timeZone = .current;f.dateFormat="yyyy-MM-dd";return f.string(from:now)}
    private static func date(_ value:Any?)->Date {guard let text=value as? String else{return .distantPast};let f=ISO8601DateFormatter();if let d=f.date(from:text){return d};f.formatOptions=[.withInternetDateTime,.withFractionalSeconds];return f.date(from:text) ?? .distantPast}
    static func hash(_ object:Any)->String {let data=(try? JSONSerialization.data(withJSONObject:object,options:.sortedKeys)) ?? Data();return SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
    func policy(_ state:[String:Any])throws->[String:Any] {
        let w=state["conversationWorkspace"] as? String ?? "";guard UUID(uuidString:w) != nil else{throw BuddyWorkerFailure(message:"Open your Buddy workspace first.")}
        var all=value["settings"] as? [String:[String:Any]] ?? [:]
        if all[w]==nil {
            let chiefs=(state["agents"] as? [[String:Any]] ?? []).filter{($0["name"] as? String)?.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()=="chief"}
            all[w]=["enabled":true,"supervisorId":chiefs.count==1 ? chiefs[0]["id"]! : NSNull(),"supervisorChosen":false,"agents":[String:[String:Any]](),"intervalMinutes":15,"dailyLimitUSD":2.0,"revision":1]
            try mutate{value["settings"]=all}
        }
        if all[w]?["supervisorId"] as? String==nil,all[w]?["supervisorChosen"] as? Bool != true {let chiefs=(state["agents"] as? [[String:Any]] ?? []).filter{($0["name"] as? String)?.lowercased()=="chief"};if chiefs.count==1{var current=all[w]!;current["supervisorId"]=chiefs[0]["id"];current["revision"]=(current["revision"] as? Int ?? 0)+1;all[w]=current;try mutate{value["settings"]=all}}}
        return all[w]!
    }
    func setPolicy(_ args:[String:Any],state:[String:Any])throws->[String:Any] {
        let w=state["conversationWorkspace"] as! String;var policy=try self.policy(state),all=value["settings"] as? [String:[String:Any]] ?? [:]
        let increasedLimit=(args["dailyLimitUSD"] as? Double).map{$0>(policy["dailyLimitUSD"] as? Double ?? 2)} ?? false
        let ids=Set((state["agents"] as? [[String:Any]] ?? []).compactMap{$0["id"] as? String})
        if let enabled=args["enabled"] as? Bool {policy["enabled"]=enabled}
        if args["supervisorId"] != nil {let id=args["supervisorId"] as? String ?? "";guard id.isEmpty || ids.contains(id) else{throw BuddyWorkerFailure(message:"Choose a current agent to oversee the team.")};if !id.isEmpty && id != policy["supervisorId"] as? String {var agents=policy["agents"] as? [String:[String:Any]] ?? [:],selected=agents[id] ?? [:];selected["proactive"]=true;agents[id]=selected;policy["agents"]=agents};policy["supervisorId"]=id.isEmpty ? NSNull():id as Any;policy["supervisorChosen"]=true}
        if let interval=args["intervalMinutes"] as? Int {guard [5,15,30,60].contains(interval) else{throw BuddyWorkerFailure(message:"Choose 5, 15, 30 or 60 minutes.")};policy["intervalMinutes"]=interval}
        if let budget=args["dailyLimitUSD"] as? Double {guard budget.isFinite,budget>=0.1 else{throw BuddyWorkerFailure(message:"Choose a daily estimated limit of at least $0.10.")};policy["dailyLimitUSD"]=budget}
        if let id=args["agentId"] as? String {guard ids.contains(id) else{throw BuddyWorkerFailure(message:"This agent is no longer here.")};var agents=policy["agents"] as? [String:[String:Any]] ?? [:],p=agents[id] ?? [:];if let mode=args["proactive"] as? Bool {p["proactive"]=mode};if let sharing=args["participates"] as? Bool {p["participates"]=sharing};agents[id]=p;policy["agents"]=agents}
        policy["revision"]=(policy["revision"] as? Int ?? 0)+1;all[w]=policy
        try mutate {
            value["settings"]=all;var jobs=checks
            for i in jobs.indices where jobs[i]["workspace"] as? String==w {
                if jobs[i]["kind"] as? String=="memory" {
                    // A refused reservation never ran. A higher allowance may
                    // retry it today without clearing actual or uncertain usage.
                    if increasedLimit,jobs[i]["status"] as? String=="budget" {jobs[i]["status"]="queued";jobs[i]["error"]=""}
                } else if ["queued","running","budget"].contains(jobs[i]["status"] as? String ?? "") {jobs[i]["status"]="cancelled";jobs[i]["error"]="Team settings changed before this check finished."}
            }
            value["checks"]=jobs
        }
        return policy
    }
    func configuration(_ policy:[String:Any],agent:String)->[String:Any] {var p=(policy["agents"] as? [String:[String:Any]])?[agent] ?? [:];if p["proactive"]==nil{p["proactive"]=policy["supervisorId"] as? String==agent};if p["participates"]==nil{p["participates"]=true};return p}
    func enqueue(kind:String,workspace:String,agent:String,input:[String:Any],fingerprint:String,policy:[String:Any],selection:BuddyAgentModelSelection,now:Date,force:Bool=false)throws->[String:Any] {
        let input=kind=="memory" ? input:BuddyAgentMemory.privateValue(input) as! [String:Any]
        if let job=checks.last(where:{$0["workspace"] as? String==workspace && $0["agentId"] as? String==agent && $0["kind"] as? String==kind && $0["fingerprint"] as? String==fingerprint && $0["status"] as? String != "cancelled" && (kind=="memory" || $0["policyRevision"] as? Int==policy["revision"] as? Int) && (!force || ["queued","running"].contains($0["status"] as? String ?? ""))}) {return job}
        guard checks.filter({["queued","running","budget"].contains($0["status"] as? String ?? "")}).count<100 else{throw BuddyWorkerFailure(message:"The check-in queue is full. Finish or cancel pending checks first.")}
        let job:[String:Any]=["id":UUID().uuidString,"workspace":workspace,"agentId":agent,"kind":kind,"input":input,"fingerprint":fingerprint,"policyRevision":policy["revision"] ?? 0,"provider":kind=="memory" ? "claude":selection.provider,"model":kind=="memory" ? "claude-sonnet-4-6":selection.model,"status":"queued","createdAt":Self.stamp(now),"force":force]
        try mutate{var jobs=checks;if jobs.count>=800{let pending=jobs.filter{!["completed","cancelled"].contains($0["status"] as? String ?? "")},finished=jobs.filter{["completed","cancelled"].contains($0["status"] as? String ?? "")};jobs=Array(finished.suffix(500))+pending};jobs.append(job);value["checks"]=jobs};return job
    }
    func update(_ id:String,_ fields:[String:Any])throws {try mutate{var jobs=checks;guard let i=jobs.firstIndex(where:{$0["id"] as? String==id}) else{throw BuddyWorkerFailure(message:"This check-in is unavailable.")};jobs[i].merge(fields){_,n in n};value["checks"]=jobs}}
    func reserve(_ job:[String:Any],policy:[String:Any],limit:Double,now:Date)throws->Bool {
        let day=Self.day(now);var all=value["daily"] as? [String:[String:Any]] ?? [:],d=all[day] ?? ["spent":0.0,"reserved":0.0]
        let charge=job["provider"] as? String=="claude" ? limit:0
        guard (d["spent"] as? Double ?? 0)+(d["reserved"] as? Double ?? 0)+charge <= (policy["dailyLimitUSD"] as? Double ?? 2) else{try update(job["id"] as! String,["status":"budget","error":"Automatic check-ins and preference learning reached today's estimated Claude limit.","budgetDay":day]);return false}
        d["reserved"]=(d["reserved"] as? Double ?? 0)+charge;all[day]=d;let old=value
        do {value["daily"]=all;try update(job["id"] as! String,["status":"running","startedAt":Self.stamp(now),"reservedUSD":charge,"budgetDay":day])}catch{value=old;throw error};return true
    }
    func receipt(_ job:[String:Any],cost:Double?)throws {
        guard let cost,cost.isFinite,cost>=0,let day=job["budgetDay"] as? String else{return}
        var all=value["daily"] as? [String:[String:Any]] ?? [:],d=all[day] ?? [:];d["reserved"]=max(0,(d["reserved"] as? Double ?? 0)-(job["reservedUSD"] as? Double ?? 0));d["spent"]=(d["spent"] as? Double ?? 0)+cost;all[day]=d;try mutate{value["daily"]=all}
    }
    func observed(_ state:[String:Any],jobs:[[String:Any]],now:Date)throws->[[String:Any]] {
        let w=state["conversationWorkspace"] as? String ?? "",old=value["observed"] as? [String:[String:Any]] ?? [:];var seen=old,out=[[String:Any]]()
        for a in state["agents"] as? [[String:Any]] ?? [] {
            guard let id=a["id"] as? String,a["setupStatus"] as? String != "pending" else{continue}
            var sources=[[String:Any]]()
            for m in ((state["messages"] as? [String:[[String:Any]]])?[id] ?? []).filter({$0["setup"] as? Bool != true && $0["teamUpdate"] as? Bool != true && $0["workerTaskID"]==nil && $0["who"] != nil && ($0["who"] as? String=="you" || $0["status"] as? String=="completed")}).suffix(8) {
                guard let mid=m["id"] as? String else{continue};sources.append(["id":"chat:"+id+":"+mid,"agentId":id,"kind":"chat","speaker":m["who"] as? String=="you" ? "user":"agent","text":String((m["body"] as? String ?? "").prefix(2000)),"messageId":mid,"createdAt":m["createdAt"] ?? ""])
            }
            let owned=jobs.filter{$0["workspace"] as? String==w && $0["agentId"] as? String==id},unfinished=owned.filter{!["completed","cancelled"].contains($0["status"] as? String ?? "")},recent=Array(owned.filter{["completed","cancelled"].contains($0["status"] as? String ?? "")}.sorted{let a=Self.date($0["updatedAt"] ?? $0["createdAt"]),b=Self.date($1["updatedAt"] ?? $1["createdAt"]);return a==b ? ($0["id"] as? String ?? "")<($1["id"] as? String ?? ""):a<b}.suffix(8)),included=Array(unfinished.prefix(40))+recent
            for job in included {sources.append(["id":"worker:"+(job["id"] as? String ?? ""),"agentId":id,"kind":"worker","taskId":job["id"] ?? "","title":job["title"] ?? "","status":job["status"] ?? "","progress":String((job["progress"] as? String ?? "").prefix(600)),"result":String((job["result"] as? String ?? "").suffix(job["status"] as? String=="completed" ? 1200:300)),"updatedAt":job["updatedAt"] ?? ""])}
            for task in (state["tasks"] as? [[String:Any]] ?? []).filter({$0["owner"] as? String==id || $0["assignee"] as? String==id || $0["agentId"] as? String==id || $0["agent"] as? String==id}).suffix(10) {sources.append(["id":"task:"+(task["id"] as? String ?? ""),"agentId":id,"kind":"shared-task","authority":"Manual task-board status; does not confirm agent execution","title":task["title"] ?? "","status":task["status"] ?? ""])}
            var groupSources=[[String:Any]]()
            for run in (state["runs"] as? [String:[String:Any]] ?? [:]).values {for entry in ((run["team"] as? [String:Any])?["entries"] as? [[String:Any]] ?? []).filter({$0["agentId"] as? String==id}) {groupSources.append(["id":"group:"+(run["runId"] as? String ?? "")+":"+id,"agentId":id,"kind":"group","status":entry["status"] ?? "","task":entry["task"] ?? "","updatedAt":run["updatedAt"] ?? run["createdAt"] ?? "","notes":String((entry["notes"] as? String ?? "").suffix(600))])}}
            groupSources.sort{let a=Self.date($0["updatedAt"]),b=Self.date($1["updatedAt"]);return a==b ? ($0["id"] as? String ?? "")<($1["id"] as? String ?? ""):a<b}
            let activeGroups=groupSources.filter{$0["status"] as? String != "completed"},doneGroups=groupSources.filter{$0["status"] as? String=="completed"};sources+=Array(activeGroups.prefix(20))+Array(doneGroups.suffix(8))
            let omitted=max(0,unfinished.count-40)+max(0,activeGroups.count-20)
            if omitted>0 {sources.append(["id":"coverage:"+id,"agentId":id,"kind":"coverage","status":"waiting_user","text":"\(omitted) unfinished work records exceed this check-in's input limits. Coverage is incomplete. Inspect the task list; do not claim all work has been reviewed."])}
            let routineFile=url.deletingLastPathComponent().appendingPathComponent("Worker/routines.json")
            if FileManager.default.fileExists(atPath:routineFile.path),let routineData=try JSONSerialization.jsonObject(with:Data(contentsOf:routineFile)) as? [String:Any] {for r in (routineData["routines"] as? [[String:Any]] ?? []).filter({$0["workspace"] as? String==w && $0["agentId"] as? String==id}) {sources.append(["id":"routine:"+(r["id"] as? String ?? ""),"agentId":id,"kind":"routine","title":r["title"] ?? "","status":r["status"] ?? "","nextRun":r["nextRun"] ?? "","lastError":r["lastError"] ?? ""])}}
            sources=BuddyAgentMemory.privateValue(sources) as! [[String:Any]]
            let fingerprint=Self.hash(sources),key=w+":"+id,previous=old[key]
            var record:[String:Any] = ["workspace":w,"agentId":id,"name":BuddyAgentMemory.privateText(a["name"] as? String ?? "Buddy"),"sources":sources,"fingerprint":fingerprint,"scope":["recentChatLimit":8,"unfinishedTasks":unfinished.count,"includedUnfinishedTasks":min(40,unfinished.count),"recentCompletedTasks":recent.count,"unfinishedGroups":activeGroups.count,"omittedUnfinished":omitted],"observedAt":Self.stamp(now),"changedAt":previous?["changedAt"] ?? Self.stamp(now)]
            if previous?["fingerprint"] as? String != fingerprint {record["changedAt"]=Self.stamp(now)}
            record["urgent"]=sources.contains{["waiting_review","waiting_user","failed","interrupted","needs_attention","blocked"].contains($0["status"] as? String ?? "")}
            seen[key]=record;out.append(record)
        }
        if !NSDictionary(dictionary:old).isEqual(to:seen){try mutate{value["observed"]=seen}};return out
    }
    static func brief(_ body:String)->String {
        let plain=body.replacingOccurrences(of:#"(?m)^\s*[-*]\s+"#,with:"",options:.regularExpression).replacingOccurrences(of:"**",with:"").trimmingCharacters(in:.whitespacesAndNewlines)
        let first=plain.range(of:#"(?s)^.*?[.!?](?=\s|$)"#,options:.regularExpression).map{String(plain[$0])} ?? plain.components(separatedBy:"\n")[0]
        guard !first.isEmpty,first.count<=260,first.range(of:#"\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b|\b\d\d:\d\d:\d\dZ\b|\bTask [0-9a-f]{8}\b"#,options:[.regularExpression,.caseInsensitive])==nil else{return "There’s an update on your work. Open Work details."}
        return first
    }
    func publish(agent:String,job:[String:Any],body:String,sources:[[String:Any]],priority:Int,now:Date,checkStatus:String="completed",detail:String?=nil)throws {
        let id="team-"+(job["id"] as! String)+":"+agent
        guard !updates.contains(where:{$0["id"] as? String==id}) else{return}
        let update:[String:Any]=["id":id,"workspace":job["workspace"]!,"agentId":agent,"checkId":job["id"]!,"body":Self.brief(body),"detail":detail ?? body,"sources":sources,"priority":priority,"checkStatus":checkStatus,"at":Self.stamp(now),"checkedAt":job["startedAt"] ?? Self.stamp(now)]
        try mutate{var entries=updates;guard entries.count<2000 else{throw BuddyWorkerFailure(message:"Saved team updates are full.")};entries.append(update);value["updates"]=entries}
    }
    private func exchanges(state:[String:Any])->[[String:Any]] {
        let w=state["conversationWorkspace"] as? String ?? "",ids=Set((state["agents"] as? [[String:Any]] ?? []).compactMap{$0["id"] as? String})
        return checks.compactMap { j in
            let input=j["input"] as? [String:Any] ?? [:]
            guard j["workspace"] as? String==w,j["kind"] as? String=="checkin",let from=input["requesterId"] as? String,let to=j["agentId"] as? String,from != to,ids.contains(from),ids.contains(to) else{return nil}
            let output=j["status"] as? String=="completed" ? j["output"] as? [String:Any] ?? [:]:[:]
            let row:[String:Any]=["id":j["id"]!,"fromAgentId":from,"toAgentId":to,"question":input["question"] ?? "","body":output["body"] ?? "","detail":output["detail"] ?? "","status":j["status"] ?? "queued","createdAt":j["createdAt"] ?? "","startedAt":j["startedAt"] ?? "","finishedAt":j["finishedAt"] ?? "","error":j["error"] ?? ""]
            return BuddyAgentMemory.privateValue(row) as? [String:Any]
        }
    }
    func messages(state:[String:Any],agent:String?=nil,before:String?=nil,exchangeIDs:[String]?=nil)throws->[String:Any] {
        let ids=Set((state["agents"] as? [[String:Any]] ?? []).compactMap{$0["id"] as? String})
        if let agent,!ids.contains(agent){throw BuddyWorkerFailure(message:"This agent is no longer available.")}
        let all=exchanges(state:state)
        var rows=all.filter{agent==nil || $0["fromAgentId"] as? String==agent || $0["toAgentId"] as? String==agent}
        if let exchangeIDs {
            let selected=Set(exchangeIDs),available=Set(rows.compactMap{$0["id"] as? String})
            guard !selected.isEmpty,selected.count<=40,selected.isSubset(of:available) else{throw BuddyWorkerFailure(message:"This exchange is no longer available. Open Agent messages to view saved history.")}
            rows=rows.filter{selected.contains($0["id"] as? String ?? "")}
        }
        if let before {guard let i=rows.firstIndex(where:{$0["id"] as? String==before}) else{throw BuddyWorkerFailure(message:"This history changed. Refresh to load the saved messages.")};rows=Array(rows.prefix(i))}
        let page=Array(rows.suffix(40))
        return ["workspace":state["conversationWorkspace"] ?? "","messages":page,"nextCursor":rows.count>40 ? page.first!["id"]! : NSNull(),"messageRevision":Self.hash(all)]
    }
    func status(state:[String:Any])->[String:Any] {
        let w=state["conversationWorkspace"] as? String ?? "",ids=Set((state["agents"] as? [[String:Any]] ?? []).compactMap{$0["id"] as? String})
        var out=(value["settings"] as? [String:[String:Any]])?[w] ?? [:]
        out["agents"]=Dictionary(uniqueKeysWithValues:ids.map{($0,configuration(out,agent:$0))})
        out["workspace"]=w;out["checks"]=checks.filter{$0["workspace"] as? String==w && ids.contains($0["agentId"] as? String ?? "")}.suffix(80).map{var j=$0;j.removeValue(forKey:"input");return j}
        out["journalRevision"]=value["journalRevision"] as? Int ?? 0
        out["updates"]=updates.filter{$0["workspace"] as? String==w && ids.contains($0["agentId"] as? String ?? "")}
        out["observed"]=(value["observed"] as? [String:[String:Any]] ?? [:]).values.filter{$0["workspace"] as? String==w && ids.contains($0["agentId"] as? String ?? "")}.map{r in r.filter{$0.key != "sources"}}
        var summaries=[String:[String:Any]]()
        let conversationRows=exchanges(state:state)
        for row in conversationRows {
            let from=row["fromAgentId"] as! String,to=row["toAgentId"] as! String
            let hasReply = !(row["body"] as? String ?? "").isEmpty || !(row["detail"] as? String ?? "").isEmpty
            let count=1+(hasReply ? 1:0)
            var events:[[String:Any]]=[["id":(row["id"] as! String)+":request","exchangeId":row["id"]!,"fromAgentId":from,"toAgentId":to,"at":row["createdAt"]!]]
            if hasReply {events.append(["id":(row["id"] as! String)+":reply","exchangeId":row["id"]!,"fromAgentId":to,"toAgentId":from,"at":row["finishedAt"]!])}
            for (id,peer) in [(from,to),(to,from)] {var s=summaries[id] ?? ["count":0,"peers":[String]()];s["count"]=(s["count"] as? Int ?? 0)+count;var peers=s["peers"] as? [String] ?? [];if !peers.contains(peer){peers.append(peer)};s["peers"]=peers;s["events"]=(s["events"] as? [[String:Any]] ?? [])+events;summaries[id]=s}
        }
        out["agentMessages"]=summaries
        out["agentMessageRevision"]=Self.hash(conversationRows)
        out["daily"]=value["daily"] ?? [:];return out
    }
}
