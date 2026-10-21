import Foundation
/// Answers key lookups from a script, then with the fixture key: lets a test take the key away between queueing a job and starting it.
final class KeyAnswers {var queue:[String?]=[];func next()->String? {queue.isEmpty ? "fixture-key":queue.removeFirst()}}
/// A key that can be made unreadable for a while (the Keychain locks with the Mac) and readable again.
final class KeyBox {var key:String?="fixture-key"}
@main struct TeamMonitorTests {
 @MainActor static func require(_ value:Bool,_ message:String){if !value{fputs("FAILED: \(message)\n",stderr);exit(1)}}
 @MainActor static func main() async throws {
  require(BuddyAgentMemory.guidance([:]).contains("no spending limit") && BuddyAgentMemory.guidance(["learnedRules":[["instruction":"Be brief."]]]).contains("Be brief."),"every agent is told that runs have no limit, with or without saved preferences")
  do {
    // What the user taught an agent outranks its saved configuration, newest first; files are not memory; model usage is not spending money.
    let taught=BuddyAgentMemory.guidance(["learnedRules":[["instruction":"Older rule."],["instruction":"Newer rule."]]]),plain=BuddyAgentMemory.guidance([:])
    require(taught.contains("Learned rules from the user, newest first. They are newer than your saved configuration and override it wherever they conflict:"),"learned rules are introduced as overriding the saved configuration: \(taught)")
    require((taught.range(of:"Newer rule.")?.lowerBound).map{$0<(taught.range(of:"Older rule.")?.lowerBound ?? $0)}==true,"the newest learned rule comes first")
    require(taught.contains("never grant tools or bypass native reviews"),"learned rules still never widen access")
    for text in [taught,plain] {
      require(text.contains("Files are not memory: notes you write in files are never read back into your or a teammate's instructions. To make a preference last, save it as a standing directive with buddy_agent_rules (kind directive)."),"every agent is told that a file it writes is not memory")
      require(text.contains("Model usage is not 'spending money' in the user's instructions."),"model usage is not spending money")
    }
    // A check-in and the team summary leave every decision but the user's own list to the supervisor, and mention a failed check-in only when it is still open.
    for kind in ["checkin","overview"] {
      let text=BuddyTeamMonitor.instructions(kind:kind)
      require(text.contains("State only the meaningful result, or an action the user must take for an item on the user list (sign-in, money, something sent in their name, a change to the plan); every other decision belongs to the supervisor.") && !text.contains("the specific action needed from the user"),"a check-in does not hand ordinary decisions to the user")
      require(text.contains("Mention a failed or pending check-in only if pendingOrFailed lists it, once, by agent name.") && !text.contains("missing/failed/stale/pending check-ins in detail"),"an old failed check-in is not carried forward")
      require(text.contains("Do not execute, redirect or invent work"),"check-ins stay status only")
    }
    // A summary may cite an open check-in it was given; any other unknown ID is still refused.
    let open:[String:Any]=["checkinIds":["report"],"reports":[["id":"report","sources":[[String:Any]]()]],"pendingOrFailed":[["id":"check:abc","agent":"Inbox","status":"failed","at":"2026-10-19T10:00:00Z","error":"x"]]]
    let cited=try BuddyTeamMonitor.checkedOutput(["notify":true,"body":"Inbox's check-in failed.","priority":1,"sourceIds":["check:abc","report"]],input:open,kind:"overview")
    require(cited["sourceIds"] as? [String]==["check:abc","report"],"an open check-in listed in pendingOrFailed can be cited by its ID")
    do{_ = try BuddyTeamMonitor.checkedOutput(["notify":true,"body":"x","priority":1,"sourceIds":["check:other"]],input:open,kind:"overview");require(false,"an ID that was not supplied is still refused")}catch{}
    // A rejected learning answer is kept at most 8 KB, with credential text withheld.
    let huge=BuddyTeamMonitor.bounded(["changed":true,"rules":[["instruction":String(repeating:"é",count:9000)]]]),secret=BuddyTeamMonitor.bounded(["note":"api key is sk-proj-"+String(repeating:"a",count:30)])
    require((huge as? String).map{$0.utf8.count<=8192 && $0.hasPrefix("{")}==true && (secret as? [String:Any])?["note"] as? String=="[Credential text excluded from background coordination and preference learning.]","a rejected answer is bounded and never keeps credential text")
  }
  do {
    // The same assessment, worded four ways by different summaries over a morning, is told once; a change to it is told.
    let now=Date(),stamp=ISO8601DateFormatter(),names:Set<String>=["lyra","forge","vera","chief","inbox"]
    let first:[[String:Any]]=[["at":stamp.string(from:now.addingTimeInterval(-7200)),"body":"Your Bank of America assessment is due about Oct 21 and is not completed yet."]]
    func told(_ text:String,_ prior:[[String:Any]]=first,age:TimeInterval=0)->Bool {BuddyTeamMonitorStore.toldAlready(text,updates:prior,agentNames:names,now:now.addingTimeInterval(age))}
    require(told("Bank of America assessment is still open, with an inferred deadline of about Oct 21, 1:15 PM PDT."),"the same assessment, reworded, is not told again")
    require(told("Bank of America assessment may be due Oct 21, 1:15 PM PDT (inferred, not confirmed)."),"nor with a hedge in brackets")
    require(told("Bank of America assessment is likely due Oct 21, 1:15 PM PDT (inferred from a 72-hour window, not stated in the email)."),"nor with the reasoning added")
    require(!told("Bank of America assessment is completed."),"but its being completed is new, though the earlier message said it was not")
    require(!told("Your Bank of America assessment is now due Oct 22."),"and so is a different date")
    require(!told("Your Bank of America assessment recruiter replied with a new link."),"and so is a reply")
    require(!told("Bank of America assessment is still open, with an inferred deadline of about Oct 21.",first,age:21*3600),"and after a day it may be brought up once more")
    require(!told("Lyra needs two answers from you."),"a message about the team's own agents is not matched by their names")
    require(!told("Bank of America assessment is still open.",[]),"nothing told yet means nothing is repeated")
  }
  do {
    let stamp=ISO8601DateFormatter(),at=Date(),agentRows:[[String:Any]]=[["id":"forge","name":"Forge"],["id":"chief","name":"Chief"]]
    let outcomes=BuddyTeamMonitor.recentOutcomes([["agentId":"chief","title":"Omori VIX pipeline re-run","status":"completed","updatedAt":stamp.string(from:at.addingTimeInterval(-600)),"result":"The 34 events reproduce."],["agentId":"forge","title":"Old task","status":"completed","updatedAt":stamp.string(from:at.addingTimeInterval(-3*86400)),"result":"Too old."],["agentId":"forge","title":"Still going","status":"running","updatedAt":stamp.string(from:at)],["agentId":"forge","title":"Check mail (08:00)","status":"completed","kind":"email","routineID":"r","updatedAt":stamp.string(from:at.addingTimeInterval(-60)),"result":"Bank of America assessment due Oct 21."]],agents:agentRows,now:at)
    require(outcomes.count==1 && outcomes[0]["agent"] as? String=="Chief" && (outcomes[0]["result"] as? String)?.contains("34 events")==true,"the team summary is told what finished in the last day, by whom, and nothing older, unfinished or scheduled (a scan is delivered by its own pacing, not re-told here): \(outcomes)")
    let reports:[[String:Any]]=[["id":"c1"],["id":"c2"]]
    require(BuddyTeamMonitor.alreadyTold(reports:reports,cited:["c1"],told:["c1"]) && !BuddyTeamMonitor.alreadyTold(reports:reports,cited:["c1","c2"],told:["c1"]) && !BuddyTeamMonitor.alreadyTold(reports:reports,cited:["nope"],told:["c1"]),"a summary is dropped only when every check-in it covers already reached the person")
    require(BuddyTeamMonitor.instructions(kind:"overview").contains("recentOutcomes"),"the summary is told that a newer outcome replaces an older report's status")
  }
  do {
    let base=Date(timeIntervalSince1970:1792400000),stamp=ISO8601DateFormatter()
    func check(_ id:String,_ status:String,hours:Double,pacing:String?=nil,progress:String="Finished",routine:Bool=true)->[String:Any] {
      var j:[String:Any]=["id":id,"kind":"email","status":status,"createdAt":stamp.string(from:base.addingTimeInterval(hours*3600)),"progress":progress]
      if routine {j["routineID"]="r1"};if let pacing {j["emailPacing"]=pacing};return j
    }
    let silent=BuddyEmailPacing.quietJobs([check("a","completed",hours:0,pacing:"news"),check("b","completed",hours:2,pacing:"quiet"),check("c","completed",hours:4,pacing:"reminder"),
      check("d","failed",hours:6,progress:"Reached maximum budget ($0.5)"),check("e","failed",hours:8,progress:"Reached maximum budget ($0.50)"),check("f","failed",hours:10,progress:"Something else broke"),
      check("g","failed",hours:30,progress:"Reached maximum budget ($0.5)"),check("h","completed",hours:12,pacing:"quiet",routine:false)])
    require(silent==["b","e"],"a scheduled check with nothing new is silent, a repeat of the failure just reported is silent, and news, a daily nudge, a different failure, the same failure a day later and a check the person asked for are all said: \(silent.sorted())")
  }
  let known:[String:Any] = ["checkinIds":["report"],"reports":[["id":"report","sources":[["id":"worker:known-task"]]]]]
  let output:[String:Any] = ["notify":true,"body":"Inbox needs sign-in.","priority":0,"sourceIds":["worker:known-task"]]
  require(try BuddyTeamMonitor.checkedOutput(output,input:known,kind:"overview")["sourceIds"] as? [String]==["report"],"an exact supplied nested source resolves to its real enclosing report")
  var foreignOutput=output;foreignOutput["sourceIds"]=["worker:foreign"]
  do{_ = try BuddyTeamMonitor.checkedOutput(foreignOutput,input:known,kind:"overview");require(false,"unknown summary sources must remain rejected")}catch{}
  require(try BuddyTeamMonitor.checkedOutput(["notify":false,"body":"","priority":0,"sourceIds":[String]()],input:["urgent":true],kind:"checkin")["notify"] as? Bool==false,"already surfaced blockers may remain quiet without manufacturing a check-in failure")
  // Saying the same thing again is recognised however it is worded; anything new is not.
  let said="Your Acme online assessment looks due about Oct 21, 1:15 PM PDT, and Beta's about Oct 24–25."
  require(BuddyTeamMonitorStore.restates("Your Acme assessment is likely due Oct 21 around 1:15 PM PT, and Beta's around Oct 24–25.",said),"the same facts, reworded, are a restatement")
  require(BuddyTeamMonitorStore.restates(said,said),"identical text is a restatement")
  require(!BuddyTeamMonitorStore.restates("Your Acme online assessment looks due about Oct 22, 1:15 PM PDT, and Beta's about Oct 24–25.",said),"a changed date is new information")
  require(!BuddyTeamMonitorStore.restates("Your Acme online assessment looks due about Oct 21, 1:15 PM PDT, and Beta's about Oct 24–25. Gamma wants 3 references.",said),"a new number is new information")
  require(!BuddyTeamMonitorStore.restates("Your Acme online assessment is not due Oct 21, 1:15 PM PDT, and Beta's about Oct 24–25.",said),"a negation is new information even when every other word is the same")
  require(!BuddyTeamMonitorStore.restates("Your Acme online assessment was cancelled; Beta's is still about Oct 24–25.",said),"a change word is new information")
  require(!BuddyTeamMonitorStore.restates("Gamma replied about the reference letters.",said),"an unrelated update is not a restatement")
  require(!BuddyTeamMonitorStore.restates("",said) && !BuddyTeamMonitorStore.restates(said,"") && !BuddyTeamMonitorStore.restates("12 34 56","12 34 56"),"empty text, and text with no words, are never restatements")
  let reported=Date()
  require(BuddyTeamMonitorStore.repeats(said,priority:1,prior:(said,reported.addingTimeInterval(-20*3600)),now:reported),"an ordinary update is a repeat for a day")
  require(!BuddyTeamMonitorStore.repeats(said,priority:1,prior:(said,reported.addingTimeInterval(-25*3600)),now:reported),"and is reminded after that")
  require(BuddyTeamMonitorStore.repeats(said,priority:0,prior:(said,reported.addingTimeInterval(-2*3600)),now:reported) && !BuddyTeamMonitorStore.repeats(said,priority:0,prior:(said,reported.addingTimeInterval(-4*3600)),now:reported),"a blocker is repeated after three hours")
  require(!BuddyTeamMonitorStore.repeats(said,priority:1,prior:nil,now:reported),"nothing is a repeat of nothing")
  // A status result never grows past what a model can open: it is trimmed to fit, says so, and a small one is left alone.
  func jsonSize(_ value:[String:Any])->Int {(try? JSONSerialization.data(withJSONObject:value).count) ?? -1}
  func bigWork(_ agents:Int)->[[String:Any]] {(0..<agents).map{n in ["agentId":"agent-\(n)","name":"Agent \(n)","sources":(0..<6).map{k in ["id":"worker:\(n)-\(k)","kind":"worker","status":"completed","result":String(repeating:"result ",count:200),"progress":String(repeating:"x",count:600)] as [String:Any]}]}}
  let heavy:[String:Any]=["roster":[["id":"a","name":"A"]],"agents":["a":["proactive":true]],"checks":(0..<80).map{["id":"c\($0)","status":"completed","output":["body":String(repeating:"b",count:1500)]] as [String:Any]},"work":bigWork(20),"observed":bigWork(20)]
  let fitted=BuddyTeamMonitor.fitting(heavy)
  require(jsonSize(heavy)>BuddyTeamMonitor.toolResultLimit && jsonSize(fitted)<=BuddyTeamMonitor.toolResultLimit,"an oversized status result is trimmed to fit")
  require((fitted["trimmed"] as? [String])?.isEmpty==false && fitted["roster"] != nil && fitted["agents"] != nil,"it says what it trimmed and keeps the core")
  let small:[String:Any]=["roster":[String](),"checks":[String]()]
  require(NSDictionary(dictionary:BuddyTeamMonitor.fitting(small)).isEqual(to:small),"a small result is left exactly as it is")
  let mild=BuddyTeamMonitor.fitting(heavy,limit:jsonSize(heavy)-1000)
  require((mild["trimmed"] as? [String])==["long text shortened"],"a result a little over the limit only has its long text shortened")
  let extreme:[String:Any]=["roster":(0..<3000).map{["id":"a\($0)","name":"Agent number \($0)"]},"checks":(0..<80).map{["id":"c\($0)","output":["body":String(repeating:"b",count:1500)]] as [String:Any]},"work":bigWork(20)]
  require(jsonSize(BuddyTeamMonitor.fitting(extreme,limit:10_000))>0 && (BuddyTeamMonitor.fitting(extreme,limit:10_000)["trimmed"] as? [String])?.last=="only the core","even an absurd result is cut down to its core rather than refused")
  let compacted=BuddyTeamMonitor.compact(["id":"c","agentId":"a","kind":"checkin","status":"completed","input":["x":"private"],"output":["notify":true,"priority":0,"body":String(repeating:"b",count:900),"detail":String(repeating:"d",count:900),"sourceIds":["s"]] as [String:Any]])
  let compactOutput=compacted["output"] as? [String:Any] ?? [:]
  require(compacted["input"]==nil && compactOutput["detail"]==nil && (compactOutput["body"] as? String)?.count==200 && compactOutput["notify"] as? Bool==true,"a check-in in an agent's status keeps what happened, not its full text")
  let root=FileManager.default.temporaryDirectory.appendingPathComponent("buddy-monitor-"+UUID().uuidString+".noindex")
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
  let w=UUID().uuidString,chief=UUID().uuidString,maze=UUID().uuidString,task=UUID().uuidString
  var state:[String:Any] = ["version":1,"conversationWorkspace":w,"agents":[["id":chief,"name":"Chief","role":"Chief of staff","description":"Oversee the team. Report only what needs my attention, most urgent first.","setupStatus":"ready","profileRevision":1],["id":maze,"name":"Maze","role":"Researcher","description":"Research public evidence.","setupStatus":"ready","profileRevision":1]],"messages":[chief:[[String:Any]](),maze:[[String:Any]]()],"groups":[],"tasks":[],"runs":[:]]
  func save()throws {try JSONSerialization.data(withJSONObject:state).write(to:root.appendingPathComponent("workspace.json"),options:.atomic)}
  try save();_ = try BuddyAISettings(support:root).update(w,provider:"claude",enabled:("claude",true),budget:0.5)
  for id in [chief,maze]{try BuddyAgentModels(support:root).set(workspace:w,agent:id,selection:.init(provider:"claude",model:"fixture-"+(id==chief ? "chief":"maze")))}
  let factory={BuddyWorkerProcess(resource:URL(fileURLWithPath:CommandLine.arguments[1]),runtime:URL(fileURLWithPath:CommandLine.arguments[2]))}
  let monitor=try BuddyTeamMonitor(support:root,makeClaude:factory,keyReader:{_ in "fixture-key"})
  let first=try monitor.status(state);require(first["supervisorId"] as? String==chief,"existing Chief is selected by stable ID without creating an agent")
  require(first["supervisorName"] as? String=="Chief" && first["supervisorChosen"]==nil,"the status says who supervises and never shows a 'not chosen' flag an agent could take for an unfinished setup")
  monitor.lastError="Fixture diagnostic"
  let diagnostic=try monitor.status(state)
  require(diagnostic["monitorError"] as? String=="Fixture diagnostic" && diagnostic["error"]==nil && (diagnostic["profiles"] as? [[String:Any]])?.count==2,"monitor diagnostics preserve the usable snapshot and never occupy the IPC failure key")
  monitor.lastError=""
  require((first["agents"] as? [String:[String:Any]])?[maze]?["proactive"] as? Bool != true,"other agents default to quiet user updates")
  var messages=state["messages"] as! [String:[[String:Any]]];messages[maze]=[["id":"user-pref","who":"you","body":"Always keep answers concise.","createdAt":BuddyAgentMemory.timestamp(Date().addingTimeInterval(1)),"live":true]];state["messages"]=messages;try save()
  let jobs:[[String:Any]] = [["id":task,"workspace":w,"agentId":maze,"title":"Research brief","status":"waiting_user","progress":"Choose which source to prioritize.","updatedAt":"2026-10-17T12:00:00Z"]]
  var now=Date()
  func step(_ raw:[String:Any]?=nil,_ work:[[String:Any]]?=nil) async {now=now.addingTimeInterval(11);await monitor.tick(state:raw ?? state,jobs:work ?? jobs,paused:false,now:now);try? await Task.sleep(nanoseconds:120_000_000)}
  for _ in 0..<12 {await step()}
  let done=try monitor.status(state),updates=done["updates"] as! [[String:Any]],checks=done["checks"] as! [[String:Any]]
  require(updates.count==1 && updates[0]["agentId"] as? String==chief,"a real peer check-in reaches Chief once and stays out of the quiet peer's DM")
  require((updates[0]["sources"] as! [[String:Any]]).contains{$0["taskId"] as? String==task},"Chief update retains actual task-source provenance")
  require(checks.contains{$0["kind"] as? String=="checkin" && $0["status"] as? String=="completed"} && checks.contains{$0["kind"] as? String=="overview" && $0["status"] as? String=="completed"},"separate target-agent response and Chief summary have completed receipts")
  let history=try monitor.handle(["action":"messages","agentId":maze],state:state,jobs:jobs)
  let exchanges=history["messages"] as! [[String:Any]]
  require(exchanges.count==1 && exchanges[0]["fromAgentId"] as? String==chief && exchanges[0]["toAgentId"] as? String==maze && exchanges[0]["status"] as? String=="completed","the actual completed peer check-in is inspectable with its true participants")
  require(exchanges[0]["input"]==nil && exchanges[0]["sources"]==nil && exchanges[0]["output"]==nil,"message history excludes internal prompts and model context")
  require((done["agentMessages"] as? [String:[String:Any]])?[maze]?["count"] as? Int==2,"the collapsed chat link counts a recorded request and response")
  // The supervisor answers the person itself, with the plan and everyone's work in view. An automatic check-in of its own saw neither, ran
  // beside that answer and posted a second report that contradicted it, so the supervisor never gets one.
  func chiefCheckins()throws->Int{(try monitor.status(state)["checks"] as! [[String:Any]]).filter{$0["kind"] as? String=="checkin" && $0["agentId"] as? String==chief}.count}
  var chiefAsked=state,chiefAskedMessages=chiefAsked["messages"] as! [String:[[String:Any]]];chiefAskedMessages[chief]=[["id":"ask-maze","who":"you","body":"What is @Maze working on?","createdAt":BuddyAgentMemory.timestamp(now.addingTimeInterval(1)),"live":true]];chiefAsked["messages"]=chiefAskedMessages
  let chiefCheckinsBefore=try chiefCheckins()
  for _ in 0..<4 {await step(chiefAsked)}
  require(try chiefCheckins()==chiefCheckinsBefore,"a message to the supervisor never starts an automatic check-in on the supervisor beside its own reply")
  let activity=(done["agentMessages"] as! [String:[String:Any]])[maze]!["events"] as! [[String:Any]]
  require(activity.count==2 && activity[0]["at"] as? String==exchanges[0]["createdAt"] as? String && activity[1]["at"] as? String==exchanges[0]["finishedAt"] as? String,"timeline markers retain the actual request and reply times")
  require(activity.allSatisfy{$0["exchangeId"] as? String==exchanges[0]["id"] as? String && $0["body"]==nil && $0["input"]==nil},"timeline metadata links to real exchanges without exposing their private content")
  do{_ = try monitor.handle(["action":"messages"],state:state,jobs:jobs,actor:maze);require(false,"models cannot use the user-only full history endpoint")}catch{}
  let reopenedJournal=try BuddyTeamMonitorStore(support:root)
  require((try reopenedJournal.messages(state:state,agent:chief)["messages"] as! [[String:Any]]).count==1,"recorded messages survive reopening without replay")
  try FileManager.default.createDirectory(at:root.appendingPathComponent("HistoryFixture"),withIntermediateDirectories:true)
  let historyStore=try BuddyTeamMonitorStore(support:root.appendingPathComponent("HistoryFixture"))
  for n in 0..<45 {let j=try historyStore.enqueue(kind:"checkin",workspace:w,agent:maze,input:["requesterId":chief,"question":"Fixture question \(n)"],fingerprint:"fixture-\(n)",policy:monitor.store.policy(state),selection:.init(provider:"claude",model:"fixture"),now:Date(),force:true);try historyStore.update(j["id"] as! String,["status":"completed","output":["body":"Fixture reply \(n)"]])}
  let latestPage=try historyStore.messages(state:state,agent:chief),latestRows=latestPage["messages"] as! [[String:Any]]
  require(latestRows.count==40 && latestRows.first?["question"] as? String=="Fixture question 5","history starts with the most recent saved page")
  let earlierPage=try historyStore.messages(state:state,agent:chief,before:latestPage["nextCursor"] as? String)
  require((earlierPage["messages"] as! [[String:Any]]).count==5 && earlierPage["nextCursor"] is NSNull,"earlier pages retain all saved exchanges without duplicating the boundary")
  let earliest=(earlierPage["messages"] as! [[String:Any]])[0],selectedHistory=try historyStore.messages(state:state,agent:chief,exchangeIDs:[earliest["id"] as! String])
  require((selectedHistory["messages"] as! [[String:Any]]).count==1 && (selectedHistory["messages"] as! [[String:Any]])[0]["id"] as? String==earliest["id"] as? String,"clicking an old timeline marker opens that exchange beyond the latest page")
  do{_ = try historyStore.messages(state:state,agent:chief,exchangeIDs:[UUID().uuidString]);require(false,"unavailable or foreign exchange IDs rejected")}catch{}
  var foreignHistory=state;foreignHistory["conversationWorkspace"]=UUID().uuidString
  require((try historyStore.messages(state:foreignHistory)["messages"] as! [[String:Any]]).isEmpty,"foreign workspace history stays inaccessible")
  let learned=(try BuddyAgentMemory.overlay(state,support:root)["agents"] as! [[String:Any]])[1]
  require(learned["description"] as? String=="Research public evidence." && (learned["learnedRules"] as? [[String:Any]])?.first?["messageId"] as? String=="user-pref" && BuddyAgentMemory.guidance(learned).contains("- Keep answers concise."),"an explicit preference is learned as a sourced rule with exact user-message evidence, and the instructions the user saved are left as written: \(learned)")
  // What wakes oversight: things ending or needing the user, never bookkeeping.
  let watchRoot=root.appendingPathComponent("Watching");try FileManager.default.createDirectory(at:watchRoot.appendingPathComponent("Worker"),withIntermediateDirectories:true)
  let watchStore=try BuddyTeamMonitorStore(support:watchRoot),rid=UUID().uuidString
  func lone(_ chat:[[String:Any]]=[])->[String:Any]{["version":1,"conversationWorkspace":w,"agents":[["id":maze,"name":"Maze","role":"Researcher","description":"x","setupStatus":"ready","profileRevision":1]],"messages":[maze:chat]]}
  func routineFile(next:String,status:String="active",error:String="")throws{try JSONSerialization.data(withJSONObject:["version":1,"routines":[["id":rid,"workspace":w,"agentId":maze,"title":"Check mail","status":status,"nextRun":next,"lastError":error]]]).write(to:watchRoot.appendingPathComponent("Worker/routines.json"))}
  func watched(_ work:[[String:Any]],chat:[[String:Any]]=[])throws->(fingerprint:String,meaningful:Bool){let r=try watchStore.observed(lone(chat),jobs:work,now:Date()).first!;return (r["fingerprint"] as! String,r["meaningful"] as! Bool)}
  func routineRun(_ n:Int,_ status:String,result:String="",progress:String="",updated:String="2026-10-18T10:00:00Z")->[String:Any]{["id":"run-\(n)","workspace":w,"agentId":maze,"title":"Check mail","status":status,"progress":progress,"result":result,"routineID":rid,"createdAt":"2026-10-18T0\(n):00:00Z","updatedAt":updated]}
  let nothingNew="Nothing new needs attention in either mailbox."
  try routineFile(next:"2026-10-19T16:00:00Z")
  let one=routineRun(1,"completed",result:nothingNew),base=try watched([one]).fingerprint
  let runningPrint=try watched([one,routineRun(2,"running")]).fingerprint,queuedPrint=try watched([one,routineRun(2,"queued")]).fingerprint
  require(runningPrint==base && queuedPrint==base,"a run being queued or worked on is not news")
  require(try watched([routineRun(1,"completed",result:nothingNew,updated:"2026-10-18T23:00:00Z")]).fingerprint==base,"a changed timestamp is not news")
  try routineFile(next:"2026-10-20T16:00:00Z")
  require(try watched([one]).fingerprint==base,"a routine's next-run time moving on is not news")
  require(try watched([one,routineRun(2,"completed",result:"Nothing new needs attention in either mailbox right now.")]).fingerprint==base,"a routine run that only says again what the run before it said is not news")
  require(try watched([one,routineRun(2,"completed",result:"Acme assessment due Oct 24 at 1:15 PM.")]).fingerprint != base,"a routine run with a new result is news")
  let blockedRun=try watched([one,routineRun(2,"waiting_user",progress:"Please sign in.")]).fingerprint
  let changedNeed=try watched([one,routineRun(2,"waiting_user",progress:"Please verify your email.")]).fingerprint
  require(blockedRun != base && changedNeed != blockedRun,"a run that needs the user is news, and so is a change in what it needs")
  let pausedA=try watched([one,routineRun(2,"paused",progress:"Paused for now.")]).fingerprint,pausedB=try watched([one,routineRun(2,"paused",progress:"Paused a while ago.")]).fingerprint
  require(pausedA==pausedB,"progress text of work that is not blocked is not news")
  try routineFile(next:"2026-10-20T16:00:00Z",status:"needs_attention",error:"The previous run needs attention.")
  require(try watched([one]).fingerprint != base,"a routine needing attention is news")
  try routineFile(next:"2026-10-20T16:00:00Z")
  require(try watched([one],chat:[["id":"c1","who":"you","body":"Hello","createdAt":"2026-10-18T09:00:00Z"]]).fingerprint != base,"a new message is news")
  try? FileManager.default.removeItem(at:watchRoot.appendingPathComponent("Worker/routines.json"))
  let onlyBusy=try watched([routineRun(1,"running"),routineRun(2,"queued")]),nothing=try watched([])
  require(!onlyBusy.meaningful && !nothing.meaningful && onlyBusy.fingerprint==nothing.fingerprint,"an agent whose only work is in progress has nothing to check")
  let callsURL=root.appendingPathComponent("TeamMonitor/fixture-calls.jsonl")
  let calls=try String(contentsOf:callsURL,encoding:.utf8).split(separator:"\n").map{try JSONSerialization.jsonObject(with:Data($0.utf8)) as! [String:Any]}
  let oversightCalls=calls.filter{$0["kind"] as? String != "memory"}
  require(calls.contains{$0["kind"] as? String=="checkin"} && calls.contains{$0["kind"] as? String=="overview"} && oversightCalls.allSatisfy{$0["model"] as? String==BuddyTeamMonitorStore.defaultCheckInModel},"check-ins and team summaries run on the small default model, not the model each agent chats with (Chief and Maze are set to other models)")
  let learningCalls=calls.filter{$0["kind"] as? String=="memory"}
  require(!learningCalls.isEmpty && learningCalls.allSatisfy{$0["required"] as? [String]==["changed","rules"] && $0["rewrites"] as? Bool==false},"the learner is asked for sourced rules only, never a rewrite of the agent's role or instructions: \(learningCalls)")
  for _ in 0..<8 {await step()}
  require(try String(contentsOf:callsURL,encoding:.utf8).split(separator:"\n").count==calls.count,"unchanged work and saved preferences do not trigger repeat model calls")
  // The same report about another blocker is not sent up again; a different one is; a check the user asks for is always answered.
  func mazeCheckins()throws->[[String:Any]]{(try monitor.status(state)["checks"] as! [[String:Any]]).filter{$0["kind"] as? String=="checkin" && $0["agentId"] as? String==maze}}
  func overviewCount()throws->Int{(try monitor.status(state)["checks"] as! [[String:Any]]).filter{$0["kind"] as? String=="overview"}.count}
  func chiefUpdates()throws->[[String:Any]]{(try monitor.status(state)["updates"] as! [[String:Any]]).filter{$0["agentId"] as? String==chief}}
  func blockers(_ extra:Int)->[[String:Any]]{jobs+(0..<extra).map{["id":"extra-\($0)","workspace":w,"agentId":maze,"title":"Another brief \($0)","status":"waiting_user","progress":"Choose which source to prioritize next \($0).","updatedAt":"2026-10-17T13:00:00Z"]}}
  func settle(_ work:[[String:Any]],_ rounds:Int=12) async {now=now.addingTimeInterval(1000);for _ in 0..<rounds {await step(nil,work)}}
  let sayCheckin=root.appendingPathComponent("TeamMonitor/fixture-checkin-body.txt"),sayOverview=root.appendingPathComponent("TeamMonitor/fixture-overview-body.txt")
  let overviewsBefore=try overviewCount(),updatesBefore=try chiefUpdates().count,checkinsBefore=try mazeCheckins().count
  await settle(blockers(1))
  var latest=try mazeCheckins().last!,checked=latest["output"] as? [String:Any] ?? [:]
  var counted=try mazeCheckins().count
  require(counted==checkinsBefore+1 && latest["status"] as? String=="completed" && checked["suppressed"] as? String=="repeat" && checked["notify"] as? Bool==false,"a check-in that only repeats its last report is not sent up")
  var summaries=try overviewCount(),posted=try chiefUpdates().count
  require(summaries==overviewsBefore && posted==updatesBefore,"so no team summary is spent on it and nothing is added to Chief's chat")
  try "I still need a decision from you before continuing.".write(to:sayCheckin,atomically:true,encoding:.utf8)
  await settle(blockers(2))
  latest=try mazeCheckins().last!;checked=latest["output"] as? [String:Any] ?? [:]
  counted=try mazeCheckins().count;summaries=try overviewCount()
  require(counted==checkinsBefore+2 && checked["suppressed"] as? String=="repeat" && summaries==overviewsBefore,"the same report in other words is still a repeat")
  try "Maze finished the research: 3 sources need your approval.".write(to:sayCheckin,atomically:true,encoding:.utf8)
  try "Maze finished the research and needs 3 sources approved.".write(to:sayOverview,atomically:true,encoding:.utf8)
  await settle(blockers(3))
  latest=try mazeCheckins().last!;checked=latest["output"] as? [String:Any] ?? [:]
  counted=try mazeCheckins().count
  require(counted==checkinsBefore+3 && checked["suppressed"]==nil && checked["notify"] as? Bool==true,"a report with something new is sent up")
  summaries=try overviewCount();let postedNow=try chiefUpdates();let lastBody=postedNow.last?["body"] as? String ?? ""
  require(summaries==overviewsBefore+1 && postedNow.count==updatesBefore+1 && lastBody.contains("3 sources"),"and reaches Chief's chat once")
  try "Maze finished the research: 4 sources need your approval.".write(to:sayCheckin,atomically:true,encoding:.utf8)
  await settle(blockers(4))
  let overviews=(try monitor.status(state)["checks"] as! [[String:Any]]).filter{$0["kind"] as? String=="overview" && $0["status"] as? String=="completed"}
  summaries=try overviewCount();posted=try chiefUpdates().count
  require(summaries==overviewsBefore+2 && (overviews.last?["output"] as? [String:Any])?["suppressed"] as? String=="repeat" && posted==updatesBefore+1,"a summary that only repeats Chief's last message is not posted")
  _ = try monitor.handle(["action":"check_in","agentId":maze],state:state,jobs:blockers(4))
  await settle(blockers(4))
  latest=try mazeCheckins().last!;checked=latest["output"] as? [String:Any] ?? [:]
  require(latest["force"] as? Bool==true && checked["notify"] as? Bool==true && checked["suppressed"]==nil,"a check-in the user asks for is always answered, even with the same words")
  await settle(blockers(4),8)
  try? FileManager.default.removeItem(at:sayCheckin);try? FileManager.default.removeItem(at:sayOverview)
  // The model for check-ins can be chosen; the default is the small one.
  let asked=try monitor.handle(["action":"check_in","agentId":maze],state:state,jobs:jobs)
  require(monitor.store.checks.first{$0["id"] as? String==(asked["queuedCheckIds"] as! [String])[0]}?["model"] as? String==BuddyTeamMonitorStore.defaultCheckInModel,"a requested check-in also uses the small default model")
  _ = try monitor.handle(["action":"configure","checkInModel":"fixture-custom"],state:state,jobs:jobs)
  let custom=try monitor.handle(["action":"check_in","agentId":maze],state:state,jobs:jobs)
  let shownModel=try monitor.status(state)["checkInModel"] as? String
  require(monitor.store.checks.first{$0["id"] as? String==(custom["queuedCheckIds"] as! [String])[0]}?["model"] as? String=="fixture-custom" && shownModel=="fixture-custom","a chosen check-in model is used and shown")
  do{_ = try monitor.handle(["action":"configure","checkInModel":"bad model!"],state:state,jobs:jobs);require(false,"an invalid check-in model name is rejected")}catch{}
  _ = try monitor.handle(["action":"configure","checkInModel":""],state:state,jobs:jobs)
  let restoredModel=try monitor.status(state)["checkInModel"] as? String
  require(restoredModel==BuddyTeamMonitorStore.defaultCheckInModel,"an empty name restores the default")
  // An agent whose only work is in progress has nothing to check; the moment it needs the user, it does.
  let quietRoot=root.appendingPathComponent("Quiet");try FileManager.default.createDirectory(at:quietRoot,withIntermediateDirectories:true)
  let solo=UUID().uuidString,quietChief=UUID().uuidString
  let quietState:[String:Any]=["version":1,"conversationWorkspace":w,"agents":[["id":quietChief,"name":"Chief","role":"Chief of staff","description":"Oversee.","setupStatus":"ready","profileRevision":1],["id":solo,"name":"Solo","role":"Researcher","description":"Research.","setupStatus":"ready","profileRevision":1]],"messages":[String:Any]()]
  try JSONSerialization.data(withJSONObject:quietState).write(to:quietRoot.appendingPathComponent("workspace.json"),options:.atomic)
  _ = try BuddyAISettings(support:quietRoot).update(w,provider:"claude",enabled:("claude",true),budget:0.5)
  let quietMonitor=try BuddyTeamMonitor(support:quietRoot,makeClaude:factory,keyReader:{_ in "fixture-key"})
  func quietCalls()->Int{((try? String(contentsOf:quietRoot.appendingPathComponent("TeamMonitor/fixture-calls.jsonl"),encoding:.utf8)) ?? "").split(separator:"\n").filter{$0.contains("\"checkin\"")}.count}
  var quietNow=Date()
  func quietStep(_ work:[[String:Any]]) async {quietNow=quietNow.addingTimeInterval(11);await quietMonitor.tick(state:quietState,jobs:work,paused:false,now:quietNow);try? await Task.sleep(nanoseconds:120_000_000)}
  let busyWork:[[String:Any]]=[["id":"busy","workspace":w,"agentId":solo,"title":"Research","status":"running","progress":"Reading sources","updatedAt":"2026-10-18T10:00:00Z"]]
  for _ in 0..<8 {await quietStep(busyWork)}
  require(quietCalls()==0,"work that is simply in progress is not checked")
  var needed=busyWork;needed[0]["status"]="waiting_user";needed[0]["progress"]="Choose a source."
  for _ in 0..<10 {await quietStep(needed)}
  require(quietCalls()==1,"work that needs the user is checked at once")
  // However much history there is, an agent's status stays small enough to open; the screen still gets all of it.
  func addReports(_ range:Range<Int>)throws {for n in range {let job=try quietMonitor.store.enqueue(kind:"checkin",workspace:w,agent:solo,input:["requesterId":quietChief,"question":"Fixture \(n)"],fingerprint:"big-\(n)",policy:quietMonitor.store.policy(quietState),selection:.init(provider:"claude",model:"fixture"),now:Date(),force:true);try quietMonitor.store.update(job["id"] as! String,["status":"completed","output":["notify":true,"priority":1,"body":String(repeating:"Long report. ",count:150),"detail":String(repeating:"Detail. ",count:300),"sourceIds":["x"]] as [String:Any]])}}
  try addReports(0..<3)
  let fewView=try quietMonitor.handle(["action":"status"],state:quietState,jobs:needed,actor:quietChief),fewChecks=(fewView["checks"] as? [[String:Any]] ?? []).filter{($0["output"] as? [String:Any])?["notify"] as? Bool==true}
  func bodyLength(_ check:[String:Any])->Int {((check["output"] as? [String:Any])?["body"] as? String)?.count ?? 0}
  require(jsonSize(fewView)<BuddyTeamMonitor.toolResultLimit && fewView["trimmed"]==nil && fewChecks.allSatisfy{($0["output"] as? [String:Any])?["detail"]==nil && bodyLength($0)<=200} && fewChecks.filter{bodyLength($0)==200}.count==3,"a modest history is not trimmed as a whole, but each past report is short")
  for n in 3..<60 {let job=try quietMonitor.store.enqueue(kind:"checkin",workspace:w,agent:solo,input:["requesterId":quietChief,"question":"Fixture \(n)"],fingerprint:"big-\(n)",policy:quietMonitor.store.policy(quietState),selection:.init(provider:"claude",model:"fixture"),now:Date(),force:true);try quietMonitor.store.update(job["id"] as! String,["status":"completed","output":["notify":true,"priority":1,"body":String(repeating:"Long report. ",count:150),"detail":String(repeating:"Detail. ",count:300),"sourceIds":["x"]] as [String:Any]])}
  let agentView=try quietMonitor.handle(["action":"status"],state:quietState,jobs:needed,actor:quietChief),screenView=try quietMonitor.status(quietState)
  let agentChecks=agentView["checks"] as? [[String:Any]] ?? []
  require(jsonSize(agentView)<=BuddyTeamMonitor.toolResultLimit && agentChecks.count<=20 && agentChecks.allSatisfy{($0["output"] as? [String:Any])?["detail"]==nil},"an agent's status stays small however much history there is, and carries no past report text")
  require((screenView["checks"] as? [[String:Any]] ?? []).count>20 && jsonSize(screenView)>BuddyTeamMonitor.toolResultLimit,"while the screen still gets the whole history")
  quietMonitor.shutdown()
  do{_ = try monitor.handle(["action":"set_proactive","enabled":true,"quote":"keep me updated"],state:state,jobs:jobs,actor:maze,authorizedText:"A different task.");require(false,"invented authorization rejected")}catch{}
  let enabled=try monitor.handle(["action":"set_proactive","enabled":true,"quote":"keep me updated"],state:state,jobs:jobs,actor:maze,authorizedText:"Please keep me updated.")
  require(enabled["saved"] as? Bool==true && enabled["agentId"] as? String==maze && enabled["proactive"] as? Bool==true,"an explicit request saves this agent's proactive mode with a real receipt")
  let changedJobs:[[String:Any]] = [["id":task,"workspace":w,"agentId":maze,"title":"Research brief","status":"completed","progress":"Finished","updatedAt":"2026-10-17T12:30:00Z"]]
  now=now.addingTimeInterval(1000);for _ in 0..<10 {await step(nil,changedJobs)}
  require(!(try monitor.status(state)["updates"] as! [[String:Any]]).contains{$0["agentId"] as? String==maze},"a peer's worker result is delivered by the worker without a duplicate monitor message")
  _ = try monitor.handle(["action":"configure","agentId":maze,"participates":false],state:state,jobs:jobs)
  let privateStatus=try monitor.handle(["action":"status","agentId":maze],state:state,jobs:jobs,actor:chief)
  let automaticUsage=privateStatus["automaticClaudeUsage"] as! [String:Any]
  require(privateStatus["dailyLimitUSD"]==nil && automaticUsage["dailyLimitUSD"] as? Double==2 && (automaticUsage["excludes"] as? [String])?.contains("scheduled_tasks")==true,"agent-facing limits carry their real scope instead of implying an overall daily task budget")
  require((privateStatus["work"] as? [[String:Any]])?.isEmpty==true && privateStatus["profiles"]==nil,"revoking team sharing hides peer conversations, instructions and work from Chief tools")
  var longHistory=jobs
  for n in 0..<100 {longHistory.append(["id":UUID().uuidString,"workspace":w,"agentId":maze,"title":"Newer completed task \(n)","status":"completed","updatedAt":"2026-10-18T00:00:00Z"])}
  let evidence=try monitor.store.observed(state,jobs:longHistory,now:Date()).first{$0["agentId"] as? String==maze}!["sources"] as! [[String:Any]]
  require(evidence.contains{$0["taskId"] as? String==task},"old unfinished work cannot fall behind a recent-message or recent-task cutoff")
  var agents=state["agents"] as! [[String:Any]];agents[1]["profileRevision"]=2;agents[1]["profileSource"]="manual";agents[1]["profileUpdatedAt"]=BuddyAgentMemory.timestamp(Date().addingTimeInterval(2));agents[1]["description"]="My manual instructions win.";agents[1]["learnedRules"]=[["instruction":"STALE RULE"]];state["agents"]=agents;try save()
  let manual=(try BuddyAgentMemory.overlay(state,support:root)["agents"] as! [[String:Any]])[1]
  require(manual["description"] as? String=="My manual instructions win." && manual["learnedRules"]==nil,"manual revisions invalidate learned overlays and stale saved rules")
  try monitor.memory.synchronize(state)
  var freshMessages=state["messages"] as! [String:[[String:Any]]];freshMessages[maze]!.append(["id":"new-rule","who":"you","body":"Always be concise.","createdAt":BuddyAgentMemory.timestamp(Date().addingTimeInterval(4))]);state["messages"]=freshMessages;try save()
  guard let input=monitor.memory.input(state,agent:agents[1]) else{require(false,"new rule after manual edit remains eligible");return}
  let bad:[String:Any]=["changed":true,"role":"Researcher","instructions":"Bad overwrite","rules":[["messageId":"new-rule","quote":"this text was never said","instruction":"Bad rule","replaces":[String]()]]]
  do{try monitor.memory.commit(bad,input:input,workspace:w,agent:maze,state:state,now:Date());require(false,"fabricated quotes rejected")}catch{}
  require((try BuddyAgentMemory.overlay(state,support:root)["agents"] as! [[String:Any]])[1]["description"] as? String=="My manual instructions win.","invalid learned evidence cannot overwrite a manual profile")
  let secret="sk-ant-"+String(repeating:"x",count:32)
  freshMessages[maze]!.append(["id":"secret","who":"you","body":"My api key: "+secret,"createdAt":BuddyAgentMemory.timestamp(Date().addingTimeInterval(5))]);state["messages"]=freshMessages
  let safeInput=monitor.memory.input(state,agent:agents[1])!,encoded=String(data:try JSONSerialization.data(withJSONObject:safeInput),encoding:.utf8)!
  require(!encoded.contains(secret) && (safeInput["messages"] as! [[String:Any]]).contains{$0["id"] as? String=="secret" && $0["excluded"] as? Bool==true},"credential-shaped messages are excluded before the background learning call")
  let safeWork=try monitor.store.observed(state,jobs:jobs+[["id":"secret-job","workspace":w,"agentId":maze,"title":"Saved password: hunter22","status":"waiting_user"]],now:Date())
  require(!String(data:try JSONSerialization.data(withJSONObject:safeWork),encoding:.utf8)!.contains("hunter22"),"credential text is withheld from teammate work records")
  require(BuddyAgentMemory.containsCredential("Bearer "+String(repeating:"a",count:30)) && !BuddyAgentMemory.containsCredential("Always ask me to enter passwords privately."),"credential filters distinguish literal tokens from ordinary credential-handling preferences")
  for text in ["The risk-adjusted-performance-metrics table needs review.","The risk-adjusted-2025-performance-metrics table is due.","The API key is stored in Keychain.","Password: never share it with anyone."] {require(!BuddyAgentMemory.containsCredential(text),"ordinary finance and credential-handling sentences are not credentials: \(text)")}
  for text in ["password=hunter2","My password: hunter22","api key is sk-proj-"+String(repeating:"a",count:30),"Bearer "+String(repeating:"b",count:30)] {require(BuddyAgentMemory.containsCredential(text),"real credential text is still caught: \(text)")}
  // Learning must not wedge: a batch that fails is retried one message at a time, and a message that still fails is passed over.
  for (n,id) in ["w1","w2","w3"].enumerated() {freshMessages[maze]!.append(["id":id,"who":"you","body":"Rule number \(n).","createdAt":BuddyAgentMemory.timestamp(Date().addingTimeInterval(Double(10+n)))])}
  state["messages"]=freshMessages
  let wholeBatch=monitor.memory.input(state,agent:agents[1])!,batchIds=(wholeBatch["messages"] as! [[String:Any]]).compactMap{$0["id"] as? String}
  require(batchIds.count>1,"several unlearned messages are offered together at first")
  try monitor.memory.failure(workspace:w,agent:maze,error:"The learned instructions didn't fit the saved format.",messageIds:batchIds)
  let single=monitor.memory.input(state,agent:agents[1])!,singleIds=(single["messages"] as! [[String:Any]]).compactMap{$0["id"] as? String}
  require(singleIds==[batchIds[0]],"after a failure the same batch is not offered again; the first message is tried alone: \(singleIds)")
  try monitor.memory.failure(workspace:w,agent:maze,error:"Still no.",messageIds:singleIds)
  let afterSkip=monitor.memory.input(state,agent:agents[1])!,skippedTo=(afterSkip["messages"] as! [[String:Any]]).compactMap{$0["id"] as? String}
  require(!skippedTo.isEmpty && !skippedTo.contains(batchIds[0]) && Set(skippedTo).isSubset(of:Set(batchIds)),"a message that cannot be learned from is passed over so the ones after it are not held back: \(skippedTo)")
  // Rules the model copied with straight quotes for the person's curly ones still match; one rule without a quote does not spoil the rest.
  let curly:[String:Any]=["id":"curly","text":"You’re to always say “thanks”.","audience":"Direct message to this agent","createdAt":"","conversationId":maze]
  let curlyInput:[String:Any]=["messages":[curly],"baseRevision":afterSkip["baseRevision"]!,"memoryRevision":afterSkip["memoryRevision"]!]
  let mixed:[String:Any]=["changed":true,"role":"Researcher","instructions":"Always say thanks.","rules":[["messageId":"curly","quote":"You're to always say \"thanks\".","instruction":"Always say thanks.","replaces":[String]()],["messageId":"curly","quote":"never said this","instruction":"Invented rule.","replaces":[String]()]]]
  try monitor.memory.commit(mixed,input:curlyInput,workspace:w,agent:maze,state:state,now:Date())
  let keptRules=monitor.memory.records[w+":"+maze]?["rules"] as? [[String:Any]] ?? []
  require(keptRules.count==1 && keptRules[0]["instruction"] as? String=="Always say thanks.","the rule with a real quote is kept and the invented one is left out: \(keptRules)")
  _ = try monitor.handle(["action":"learning","agentId":maze,"enabled":false],state:state,jobs:jobs)
  require(monitor.memory.input(state,agent:agents[1])==nil,"learning can be disabled independently per agent")
  let other=UUID().uuidString;var foreign=state;foreign["conversationWorkspace"]=other;let foreignStatus=try monitor.status(foreign)
  require((foreignStatus["updates"] as? [[String:Any]])?.isEmpty==true,"team updates are isolated by workspace")
  monitor.shutdown()
  _ = try BuddyAISettings(support:root).update(w,enabled:("chatgpt",true))
  try BuddyAgentModels(support:root).set(workspace:w,agent:chief,selection:.init(provider:"chatgpt",model:"fixture-gpt"))
  let gpt=try BuddyTeamMonitor(support:root,makeClaude:factory,makeGPT:{ConversationService(support:root,executable:URL(fileURLWithPath:CommandLine.arguments[3]))},keyReader:{_ in "fixture-key"})
  _ = try gpt.handle(["action":"configure","agentId":maze,"participates":true],state:state,jobs:jobs)
  _ = try gpt.handle(["action":"check_in","agentId":maze],state:state,jobs:jobs)
  for _ in 0..<14 {now=now.addingTimeInterval(11);await gpt.tick(state:state,jobs:jobs,paused:false,now:now);try await Task.sleep(nanoseconds:120_000_000)}
  require((try gpt.status(state)["updates"] as! [[String:Any]]).contains{($0["body"] as? String)?.contains("GPT Chief verified")==true},"a ChatGPT-selected Chief uses the subscription transport, structured output and no tool surface")
  require(BuddyWorkerClient.proactiveRequest("Keep me updated.")==true && BuddyWorkerClient.proactiveRequest("Only update me when I ask.")==false && BuddyWorkerClient.proactiveRequest("Don't keep me updated.")==false && BuddyWorkerClient.proactiveRequest("Stop keeping me informed.")==false && BuddyWorkerClient.proactiveRequest("If I said keep me updated, would you?")==nil,"standing proactive commands distinguish opt-out and hypothetical questions")
  let budgetRoot=root.appendingPathComponent("Budget",isDirectory:true);try FileManager.default.createDirectory(at:budgetRoot,withIntermediateDirectories:true)
  let budgetStore=try BuddyTeamMonitorStore(support:budgetRoot),policy=try budgetStore.policy(state),budgetJob=try budgetStore.enqueue(kind:"checkin",workspace:w,agent:maze,input:[:],fingerprint:"budget",policy:policy,selection:.init(provider:"claude",model:"fixture"),now:Date())
  require(try budgetStore.reserve(budgetJob,policy:["dailyLimitUSD":0.1],limit:0.2,now:Date())==false,"automatic calls cannot reserve above the configured daily estimate")
  for invalid in [Double.nan,Double.infinity,-1,0] {
   do{_ = try budgetStore.setPolicy(["dailyLimitUSD":invalid],state:state);require(false,"invalid daily limits are rejected")}catch{}
  }
  let waitingMemory=try budgetStore.enqueue(kind:"memory",workspace:w,agent:maze,input:[:],fingerprint:"waiting-memory",policy:policy,selection:.init(provider:"claude",model:"fixture"),now:Date())
  require(try budgetStore.reserve(waitingMemory,policy:["dailyLimitUSD":0.1],limit:0.2,now:Date())==false,"blocked learning has not consumed a model call")
  _ = try budgetStore.setPolicy(["dailyLimitUSD":35.0],state:state)
  require(budgetStore.checks.first{$0["id"] as? String==waitingMemory["id"] as? String}?["status"] as? String=="queued","raising the daily limit makes blocked learning eligible today")
  let reopenedBudget=try BuddyTeamMonitorStore(support:budgetRoot)
  require(try reopenedBudget.policy(state)["dailyLimitUSD"] as? Double==35,"an edited daily estimate persists when settings are reopened")
  let reserveJob=try budgetStore.enqueue(kind:"checkin",workspace:w,agent:maze,input:[:],fingerprint:"reserved",policy:policy,selection:.init(provider:"claude",model:"fixture"),now:Date())
  require(try budgetStore.reserve(reserveJob,policy:policy,limit:0.2,now:Date()),"an allowed estimate is durably reserved before calling a model")
  let restarted=try BuddyTeamMonitorStore(support:budgetRoot)
  require(restarted.checks.contains{$0["id"] as? String==reserveJob["id"] as? String && $0["status"] as? String=="interrupted"},"restart marks uncertain calls interrupted without auto replay")
  let verbose="The AgentMail inbox needs your sign-in. Task 5BD6689F-E3FE-4EC2-B92C-2C436E740F9B changed at 05:44:19Z. "+String(repeating:"Diagnostic details. ",count:40)
  try budgetStore.publish(agent:chief,job:reserveJob,body:verbose,sources:[],priority:0,now:Date())
  let brief=budgetStore.updates.last!
  require(brief["body"] as? String=="The AgentMail inbox needs your sign-in." && brief["detail"] as? String==verbose,"proactive DMs stay short while preserving complete diagnostics for expansion")
  require(BuddyTeamMonitorStore.brief("Task 5BD6689F-E3FE-4EC2-B92C-2C436E740F9B is waiting at 05:44:19Z.")=="There’s an update on your work. Open Work details.","technical IDs cannot leak into a proactive DM")
  let usageBefore=try JSONSerialization.data(withJSONObject:budgetStore.value["daily"] ?? [:],options:.sortedKeys)
  _ = try budgetStore.setPolicy(["dailyLimitUSD":50.0],state:state)
  require(try JSONSerialization.data(withJSONObject:budgetStore.value["daily"] ?? [:],options:.sortedKeys)==usageBefore,"raising a daily limit preserves spent and uncertain reserved usage")
  let quiet=try budgetStore.setPolicy(["agentId":chief,"proactive":false],state:state)
  require(budgetStore.configuration(quiet,agent:chief)["proactive"] as? Bool==false,"Chief can be switched to quiet mode explicitly")
  gpt.shutdown()
  func waitUntil(_ rounds:Int=60,_ done:()->Bool) async {for _ in 0..<rounds {if done(){return};try? await Task.sleep(nanoseconds:100_000_000)}}
  func agentRow(_ id:String,_ name:String,_ extra:[String:Any]=[:])->[String:Any] {(["id":id,"name":name,"role":"Researcher","description":"Research public evidence.","setupStatus":"ready","profileRevision":1] as [String:Any]).merging(extra){_,n in n}}
  func fixtureRoot(_ name:String,_ workspace:[String:Any]?=nil)throws->URL {
    let url=root.appendingPathComponent(name);try FileManager.default.createDirectory(at:url.appendingPathComponent("TeamMonitor"),withIntermediateDirectories:true)
    if let workspace {try JSONSerialization.data(withJSONObject:workspace).write(to:url.appendingPathComponent("workspace.json"),options:.atomic)}
    _ = try BuddyAISettings(support:url).update(w,provider:"claude",enabled:("claude",true),budget:0.5);return url
  }
  do {
    // Who may read whose work: an agent sees its own, its manager and the supervisor see it too, and nobody else does.
    let boss=UUID().uuidString,lead=UUID().uuidString,helper=UUID().uuidString,outsider=UUID().uuidString
    let accessState:[String:Any]=["version":1,"conversationWorkspace":w,"agents":[agentRow(boss,"Chief"),agentRow(lead,"Lead"),agentRow(helper,"Helper",["managedBy":lead]),agentRow(outsider,"Outsider")],"messages":[helper:[["id":"h1","who":"you","body":"Private note for Helper only.","createdAt":"2026-10-18T09:00:00Z"]]]]
    let access=try BuddyTeamMonitor(support:try fixtureRoot("Access",accessState),makeClaude:factory,keyReader:{_ in "fixture-key"})
    let accessJobs:[[String:Any]]=[boss,lead,helper,outsider].map{["id":UUID().uuidString,"workspace":w,"agentId":$0,"title":"Brief","status":"waiting_user","progress":"Needs a choice.","updatedAt":"2026-10-18T10:00:00Z"]}
    func visible(_ args:[String:Any],_ actor:String)throws->Set<String> {Set((try access.handle(args,state:accessState,jobs:accessJobs,actor:actor)["work"] as? [[String:Any]] ?? []).compactMap{$0["agentId"] as? String})}
    let peek=try access.handle(["action":"status","agentId":helper],state:accessState,jobs:accessJobs,actor:outsider)
    let peekText=String(data:try JSONSerialization.data(withJSONObject:peek),encoding:.utf8)!
    require((peek["work"] as? [[String:Any]] ?? []).isEmpty && !peekText.contains("Private note"),"a teammate that neither supervises nor manages an agent gets none of its work or chat: \(peek["work"] ?? "")")
    require(try visible(["action":"status"],outsider)==[outsider],"an agent's own status shows only its own work")
    require(try visible(["action":"status","agentId":helper],lead)==[helper] && (try visible(["action":"status"],lead))==[lead,helper],"a manager sees the agents it manages")
    require(try visible(["action":"status"],boss)==[boss,lead,helper,outsider],"the supervisor sees everyone who shares work")
    for (actor,target) in [(outsider,helper),(outsider,nil),(helper,lead),(lead,nil)] as [(String,String?)] {
      var args:[String:Any]=["action":"check_in"];if let target {args["agentId"]=target}
      do{_ = try access.handle(args,state:accessState,jobs:accessJobs,actor:actor);require(false,"only the supervisor or the manager can ask an agent for a check-in")}catch{require(error.localizedDescription=="Only the supervisor or this agent's manager can ask it for a check-in.","the refusal says who may ask: \(error.localizedDescription)")}
    }
    require(access.store.checks.isEmpty,"a refused check-in queues nothing")
    let managerAsk=try access.handle(["action":"check_in","agentId":helper],state:accessState,jobs:accessJobs,actor:lead)
    let asked=access.store.checks.first{$0["id"] as? String==(managerAsk["queuedCheckIds"] as? [String])?.first}
    require(managerAsk["accepted"] as? Bool==true && (asked?["input"] as? [String:Any])?["question"] as? String=="What changed, what is blocked, and what needs a decision — by you, the supervisor, or (only for sign-ins, money, things sent in the user's name, or plan changes) the user?","a manager can ask its own agent, and the default question routes decisions to the supervisor")
    do{_ = try access.handle(["action":"check_in","agentId":outsider,"question":String(repeating:"a",count:1501)],state:accessState,jobs:accessJobs,actor:boss);require(false,"an over-long check-in question is refused rather than cut")}catch{require(error.localizedDescription=="A check-in question is limited to 1,500 characters and only asks for status. To give a teammate work, add it to the team plan with buddy_plan.","the refusal points to the plan: \(error.localizedDescription)")}
    let longest=try access.handle(["action":"check_in","agentId":outsider,"question":String(repeating:"b",count:1500)],state:accessState,jobs:accessJobs,actor:boss)
    require(((access.store.checks.first{$0["id"] as? String==(longest["queuedCheckIds"] as? [String])?.first}?["input"] as? [String:Any])?["question"] as? String)?.count==1500,"a question at the limit is kept whole")
    require(try access.handle(["action":"check_in","agentId":lead],state:accessState,jobs:accessJobs)["accepted"] as? Bool==true,"the person on screen can still ask any agent")
    access.shutdown()
  }
  do {
    // The team summary lists only each agent's latest check-in, only while it is open and recent, by ID and name.
    let pChief=UUID().uuidString,xena=UUID().uuidString,yuri=UUID().uuidString,zed=UUID().uuidString
    let pendState:[String:Any]=["version":1,"conversationWorkspace":w,"agents":[agentRow(pChief,"Chief"),agentRow(xena,"Xena"),agentRow(yuri,"Yuri"),agentRow(zed,"Zed")],"messages":[String:Any]()]
    let pend=try BuddyTeamMonitor(support:try fixtureRoot("Pending",pendState),makeClaude:factory,keyReader:{_ in "fixture-key"})
    let policy=try pend.store.policy(pendState),clock=Date()
    func recorded(_ agent:String,_ status:String,hoursAgo:Double,kind:String="checkin",error:String="",output:[String:Any]?=nil,input:[String:Any]?=nil)throws->String {
      let at=clock.addingTimeInterval(-hoursAgo*3600)
      let job=try pend.store.enqueue(kind:kind,workspace:w,agent:agent,input:input ?? ["requesterId":pChief,"agent":["id":agent,"name":"Teammate"]],fingerprint:UUID().uuidString,policy:policy,selection:.init(provider:"claude",model:"fixture"),now:at,force:true)
      var fields:[String:Any]=["status":status,"error":error,"startedAt":BuddyTeamMonitorStore.stamp(at),"finishedAt":BuddyTeamMonitorStore.stamp(at)];if let output {fields["output"]=output}
      try pend.store.update(job["id"] as! String,fields);return job["id"] as! String
    }
    let xenaFailed=try recorded(xena,"failed",hoursAgo:2,error:"The check-in returned no verified structured result.")
    let xenaDone=try recorded(xena,"completed",hoursAgo:1,output:["notify":true,"body":"Xena finished the draft.","priority":1,"sourceIds":[String]()])
    let yuriFailed=try recorded(yuri,"failed",hoursAgo:1,error:String(repeating:"Long failure. ",count:40))
    let zedFailed=try recorded(zed,"failed",hoursAgo:30,error:"An old failure.")
    await pend.tick(state:pendState,jobs:[],paused:false,now:clock)
    let summary=pend.store.checks.last{$0["kind"] as? String=="overview"},listed=(summary?["input"] as? [String:Any])?["pendingOrFailed"] as? [[String:Any]] ?? []
    require(((summary?["input"] as? [String:Any])?["checkinIds"] as? [String])==[xenaDone],"the summary covers the completed check-in")
    require(listed.count==1 && listed[0]["id"] as? String=="check:"+yuriFailed && listed[0]["agent"] as? String=="Yuri" && listed[0]["status"] as? String=="failed" && listed[0]["at"] is String && (listed[0]["error"] as? String)?.count==200,"only an agent whose latest check-in is still open and recent is listed, by ID and name, with a short error: \(listed)")
    require(!String(describing:listed).contains(xenaFailed) && !String(describing:listed).contains(zedFailed),"a failure replaced by a later completed check-in, or older than a day, is not carried forward")
    await waitUntil{pend.store.checks.allSatisfy{!["queued","running"].contains($0["status"] as? String ?? "")}}
    // A summary that failed over an unknown source before the source fix is not retried by a one-off compatibility pass any more.
    let stale=try recorded(pChief,"failed",hoursAgo:1,kind:"overview",error:"A team update referenced work outside its actual check-in.",input:["checkinIds":[xenaDone]])
    await pend.tick(state:pendState,jobs:[],paused:false,now:clock.addingTimeInterval(11))
    require(!pend.store.checks.contains{$0["compatibilityRetry"] as? Bool==true} && pend.store.checks.first{$0["id"] as? String==stale}?["status"] as? String=="failed","the compatibility retry for summaries is gone")
    await waitUntil{pend.store.checks.allSatisfy{!["queued","running"].contains($0["status"] as? String ?? "")}}
    pend.shutdown()
  }
  func offered(_ job:[String:Any]?)->[String] {((job?["input"] as? [String:Any])?["messages"] as? [[String:Any]] ?? []).compactMap{$0["id"] as? String}}
  func future(_ id:String,_ seconds:Double,_ body:String)->[String:Any] {["id":id,"who":"you","body":body,"createdAt":BuddyAgentMemory.timestamp(Date().addingTimeInterval(seconds))]}
  do {
    // Learning never wedges: a rejected batch is kept with its reason, retried one message at a time, and a message that still fails is passed over.
    let lyra=UUID().uuidString,learnRoot=try fixtureRoot("Learning")
    let learner=try BuddyTeamMonitor(support:learnRoot,makeClaude:factory,keyReader:{_ in "fixture-key"})
    let learnState:[String:Any]=["version":1,"conversationWorkspace":w,"agents":[agentRow(lyra,"Lyra")],"messages":[lyra:(0..<6).map{future("m\($0)",Double(10+$0),"Standing rule number \($0).")}]]
    try JSONSerialization.data(withJSONObject:learnState).write(to:learnRoot.appendingPathComponent("workspace.json"),options:.atomic)
    try "no_rules".write(to:learnRoot.appendingPathComponent("TeamMonitor/fixture-memory-mode.txt"),atomically:true,encoding:.utf8)
    var learnNow=Date()
    func learning()->[[String:Any]] {learner.store.checks.filter{$0["kind"] as? String=="memory"}}
    func learnTick() async {learnNow=learnNow.addingTimeInterval(11);await learner.tick(state:learnState,jobs:[],paused:false,now:learnNow)}
    await learnTick();await waitUntil{learning().first?["status"] as? String=="failed"}
    let batch=learning().first,firstIds=offered(batch)
    require(firstIds.count==5 && batch?["status"] as? String=="failed","several unlearned messages are offered together at first: \(firstIds)")
    require(batch?["rejectedReason"] as? String=="changed_without_rules" && (batch?["rejectedOutput"] as? [String:Any])?["changed"] as? Bool==true,"a rejected learning result is kept on the check with the reason it was rejected: \(batch ?? [:])")
    await learnTick()
    require(learning().count==2 && offered(learning().last)==[firstIds[0]],"after the batch fails, the next tick queues a new learning job with its first message alone: \(learning().map(offered))")
    await waitUntil{learning().count==2 && learning()[1]["status"] as? String=="failed"}
    await learnTick()
    require(learning().count==3 && offered(learning().last).first==firstIds[1] && !offered(learning().last).contains(firstIds[0]),"after that message fails alone it is passed over and the next unseen message is offered: \(learning().map(offered))")
    await waitUntil{learning().allSatisfy{!["queued","running"].contains($0["status"] as? String ?? "")}}
    learner.shutdown()
  }
  do {
    // A learning job that fails before the model even runs (the key went away) moves the batch on the same way, instead of holding learning for good.
    let pia=UUID().uuidString,answers=KeyAnswers(),keyRoot=try fixtureRoot("Reconnect")
    let piaState:[String:Any]=["version":1,"conversationWorkspace":w,"agents":[agentRow(pia,"Pia")],"messages":[pia:(0..<3).map{future("p\($0)",Double(10+$0),"Please remember rule \($0).")}]]
    try JSONSerialization.data(withJSONObject:piaState).write(to:keyRoot.appendingPathComponent("workspace.json"),options:.atomic)
    let reconnect=try BuddyTeamMonitor(support:keyRoot,makeClaude:factory,keyReader:{_ in answers.next()})
    func memoryJobs()->[[String:Any]] {reconnect.store.checks.filter{$0["kind"] as? String=="memory"}}
    answers.queue=["fixture-key",nil]
    await reconnect.tick(state:piaState,jobs:[],paused:false,now:Date().addingTimeInterval(11))
    require(memoryJobs().count==1 && memoryJobs()[0]["status"] as? String=="failed" && offered(memoryJobs()[0]).count==3,"the job fails before the model runs: \(memoryJobs())")
    let record=reconnect.memory.records[w+":"+pia]
    require(record?["singly"] as? Bool==true && !(record?["error"] as? String ?? "").isEmpty,"and the failure is recorded against its batch: \(record ?? [:])")
    await reconnect.tick(state:piaState,jobs:[],paused:false,now:Date().addingTimeInterval(22))
    require(memoryJobs().count==2 && memoryJobs()[1]["id"] as? String != memoryJobs()[0]["id"] as? String && offered(memoryJobs()[1])==["p0"],"so the next tick queues a new job instead of being held by the failed one: \(memoryJobs().map(offered))")
    await waitUntil{memoryJobs().allSatisfy{!["queued","running"].contains($0["status"] as? String ?? "")}}
    reconnect.shutdown()
  }
  do {
    // Records wedged before batches were split (an error, and no "singly" key) are retried one message at a time once, and only those.
    let stuck=UUID().uuidString,settled=UUID().uuidString,clean=UUID().uuidString,wedgedRoot=try fixtureRoot("Wedged")
    func memoryRecord(_ id:String,_ extra:[String:Any])->[String:Any] {(["workspace":w,"agentId":id,"baseRevision":1,"revision":0,"enabled":true,"rules":[[String:Any]](),"seen":[String](),"history":[[String:Any]]()] as [String:Any]).merging(extra){_,n in n}}
    try JSONSerialization.data(withJSONObject:["version":1,"activatedAt":"2026-10-17T00:00:00.000Z","records":[w+":"+stuck:memoryRecord(stuck,["error":"The learned instructions didn't fit the saved format."]),w+":"+settled:memoryRecord(settled,["error":"Still no.","singly":false]),w+":"+clean:memoryRecord(clean,["error":""])]]).write(to:wedgedRoot.appendingPathComponent("agent-memory.json"))
    let wedgedState:[String:Any]=["version":1,"conversationWorkspace":w,"agents":[agentRow(stuck,"Chief"),agentRow(settled,"Vera"),agentRow(clean,"Forge")],"messages":[stuck:(0..<4).map{["id":"s\($0)","who":"you","body":"Rule \($0).","createdAt":"2026-10-18T0\($0):00:00Z"]}]]
    let wedged=try BuddyAgentMemory(support:wedgedRoot)
    require(offered(["input":wedged.input(wedgedState,agent:agentRow(stuck,"Chief")) ?? [:]]).count==4,"before the fix the whole wedged batch is offered again")
    try wedged.synchronize(wedgedState)
    let reread=try BuddyAgentMemory.read(wedgedRoot)
    require(wedged.records[w+":"+stuck]?["singly"] as? Bool==true && reread[w+":"+stuck]?["singly"] as? Bool==true,"a record with an error and no singly key is set to one message at a time, and saved")
    require(wedged.records[w+":"+settled]?["singly"] as? Bool==false && wedged.records[w+":"+clean]?["singly"]==nil,"a record that already says, or has no error, is left alone")
    require(offered(["input":wedged.input(wedgedState,agent:agentRow(stuck,"Chief")) ?? [:]])==["s0"],"so its first message is tried alone")
    let once=wedged.records;try wedged.synchronize(wedgedState)
    require(NSDictionary(dictionary:once).isEqual(to:wedged.records),"doing it again changes nothing")
  }
  do {
    // A failed learning batch never stands in for a new attempt at the same messages; check-ins about unchanged work are still not repeated on their own.
    let dedupe=try BuddyTeamMonitorStore(support:try fixtureRoot("Dedupe")),dp=try dedupe.policy(state)
    let lost=try dedupe.enqueue(kind:"memory",workspace:w,agent:maze,input:["messages":[["id":"a"]]],fingerprint:"same-batch",policy:dp,selection:.init(provider:"claude",model:"fixture"),now:Date())
    try dedupe.update(lost["id"] as! String,["status":"failed","error":"Rejected."])
    let again=try dedupe.enqueue(kind:"memory",workspace:w,agent:maze,input:["messages":[["id":"a"]]],fingerprint:"same-batch",policy:dp,selection:.init(provider:"claude",model:"fixture"),now:Date())
    require(again["id"] as? String != lost["id"] as? String && again["status"] as? String=="queued","a failed learning batch does not block a new one")
    let check=try dedupe.enqueue(kind:"checkin",workspace:w,agent:maze,input:[:],fingerprint:"same-work",policy:dp,selection:.init(provider:"claude",model:"fixture"),now:Date())
    try dedupe.update(check["id"] as! String,["status":"failed"])
    require(try dedupe.enqueue(kind:"checkin",workspace:w,agent:maze,input:[:],fingerprint:"same-work",policy:dp,selection:.init(provider:"claude",model:"fixture"),now:Date())["id"] as? String==check["id"] as? String,"a check-in's own retries stay paced separately")
  }
  do {
    // The check-in journal stays small: old bulky inputs are dropped (keeping who asked what), old failures go after a week, and trimming keeps 400 finished checks.
    let fmt=ISO8601DateFormatter(),clock=Date()
    func ago(_ days:Double)->String {fmt.string(from:clock.addingTimeInterval(-days*86400))}
    func row(_ status:String,_ days:Double)->[String:Any] {["id":UUID().uuidString,"workspace":w,"agentId":maze,"kind":"checkin","status":status,"createdAt":ago(days),"finishedAt":ago(days),"fingerprint":UUID().uuidString,"policyRevision":1,"provider":"claude","model":"fixture","input":["requesterId":chief,"question":"How is it going?","sources":[["id":"chat:x","text":String(repeating:"private context ",count:20)]]]]}
    func journal(_ name:String,_ rows:[[String:Any]])throws->BuddyTeamMonitorStore {
      let url=try fixtureRoot(name);try JSONSerialization.data(withJSONObject:["version":1,"settings":[String:[String:Any]](),"checks":rows,"updates":[[String:Any]](),"observed":[String:[String:Any]](),"daily":[String:Any]()]).write(to:url.appendingPathComponent("team-monitor.json"));return try BuddyTeamMonitorStore(support:url)
    }
    func age(_ c:[String:Any])->Double {clock.timeIntervalSince(fmt.date(from:(c["finishedAt"] ?? c["createdAt"]) as? String ?? "") ?? clock)/86400}
    func inputOf(_ c:[String:Any])->[String:Any] {c["input"] as? [String:Any] ?? [:]}
    let small=try journal("GrowthSmall",[row("failed",8),row("interrupted",8),row("completed",3),row("cancelled",2),row("failed",2),row("interrupted",3),row("completed",0.1)])
    _ = try small.enqueue(kind:"checkin",workspace:w,agent:maze,input:["requesterId":chief,"question":"New?"],fingerprint:"fresh",policy:try small.policy(state),selection:.init(provider:"claude",model:"fixture"),now:clock)
    let compacted=small.checks
    require(compacted.count==6 && !compacted.contains{["failed","interrupted"].contains($0["status"] as? String ?? "") && age($0)>7},"failed and interrupted checks older than a week are dropped: \(compacted.map{$0["status"] ?? ""})")
    require(compacted.filter{["completed","cancelled","failed"].contains($0["status"] as? String ?? "") && age($0)>1}.allSatisfy{inputOf($0)["sources"]==nil && inputOf($0)["requesterId"] as? String==chief && inputOf($0)["question"] as? String=="How is it going?"},"finished checks older than a day lose their bulky input but keep who asked what, for the message history")
    require(compacted.filter{$0["status"] as? String=="interrupted" || age($0)<1}.allSatisfy{$0["id"] as? String != nil && (inputOf($0)["sources"] != nil || inputOf($0)["question"] as? String=="New?")},"recent and interrupted checks keep their input")
    let rows=(0..<760).map{_ in row("completed",3)}+(0..<10).map{_ in row("failed",8)}+(0..<10).map{_ in row("interrupted",8)}+(0..<20).map{_ in row("failed",2)}+(0..<20).map{_ in row("completed",0.01)}+(0..<9).map{_ in row("queued",0.01)}
    let big=try journal("Growth",rows)
    let fresh=try big.enqueue(kind:"checkin",workspace:w,agent:maze,input:["requesterId":chief,"question":"New?"],fingerprint:"fresh",policy:try big.policy(state),selection:.init(provider:"claude",model:"fixture"),now:clock)
    let kept=big.checks,finished=kept.filter{!["queued","running","budget"].contains($0["status"] as? String ?? "")}
    require(finished.count==400 && kept.filter{$0["status"] as? String=="queued"}.count==10 && kept.contains{$0["id"] as? String==fresh["id"] as? String},"trimming keeps at most 400 finished checks and every waiting one: \(finished.count) of \(kept.count)")
    require(finished.filter{age($0)<1}.count==20 && finished.filter{$0["status"] as? String=="failed"}.count==20,"the newest finished checks are the ones kept")
    require(kept.filter{$0["status"] as? String=="queued" && $0["id"] as? String != fresh["id"] as? String}.allSatisfy{inputOf($0)["sources"] != nil},"waiting checks keep their full input")
    require(try BuddyTeamMonitorStore(support:root.appendingPathComponent("Growth")).checks.count==kept.count,"the trimmed journal reopens")
  }
  do {
    // Inbox's three automatic check-ins each "stopped because access, settings, or its time limit changed", and each was shown to the person.
    // A check-in cut short is nobody's business: a key that can't be read for a moment or time asleep does not stop it, a pause, a reconnect or
    // its time limit queues it again quietly (paced and bounded), one that can no longer happen is dropped without a word, and none of it is shown.
    var failed:[String]=[]
    func expect(_ value:Bool,_ message:String){if !value{failed.append(message);fputs("FAILED: \(message)\n",stderr)}}
    let cChief=UUID().uuidString,rex=UUID().uuidString
    let cutState:[String:Any]=["version":1,"conversationWorkspace":w,"agents":[agentRow(cChief,"Chief"),agentRow(rex,"Inbox")],"messages":[String:Any]()]
    let cutRoot=try fixtureRoot("CutShort",cutState)
    try "hang".write(to:cutRoot.appendingPathComponent("TeamMonitor/fixture-checkin-mode.txt"),atomically:true,encoding:.utf8)
    let box=KeyBox()
    let cut=try BuddyTeamMonitor(support:cutRoot,makeClaude:factory,keyReader:{_ in box.key})
    let cutJobs:[[String:Any]]=[["id":UUID().uuidString,"workspace":w,"agentId":rex,"title":"Check AgentMail and Gmail (06:00)","status":"failed","progress":"failed to refresh installed connector runtime state: failed to refresh tools for MCP server 'codex_apps'","updatedAt":"2026-10-20T14:25:38Z"]]
    var clock=Date()
    func cutTick(_ seconds:TimeInterval=11,paused:Bool=false) async {clock=clock.addingTimeInterval(seconds);await cut.tick(state:cutState,jobs:cutJobs,paused:paused,now:clock)}
    func checkins()->[[String:Any]] {cut.store.checks.filter{$0["kind"] as? String=="checkin" && $0["agentId"] as? String==rex}}
    func check(_ id:String)->[String:Any] {cut.store.checks.first{$0["id"] as? String==id} ?? [:]}
    func said(_ c:[String:Any])->String {"\(c["status"] ?? "-") requeues \(c["requeues"] ?? 0) \(c["error"] ?? "")"}
    /// What the person can see of check-ins on Inbox: the agent-message history, and the checks and timeline markers in the page's status.
    func seen()throws->(history:[[String:Any]],checks:[[String:Any]],markers:Int) {
      let s=try cut.status(cutState)
      return (try cut.handle(["action":"messages"],state:cutState,jobs:cutJobs)["messages"] as? [[String:Any]] ?? [],(s["checks"] as? [[String:Any]] ?? []).filter{$0["agentId"] as? String==rex},((s["agentMessages"] as? [String:[String:Any]])?[rex]?["events"] as? [[String:Any]] ?? []).count)
    }
    func quiet(_ label:String,hiding id:String)throws {
      let now=try seen()
      expect(!now.history.contains{["interrupted","cancelled"].contains($0["status"] as? String ?? "") || $0["id"] as? String==id} && !now.checks.contains{$0["status"] as? String=="interrupted"} && now.markers==0,
             "\(label): it is not in the agent-message history or the page's status: \(now.history.map{"\($0["status"] ?? "") · \($0["error"] ?? "")"}) \(now.checks.map{$0["status"] ?? ""}) markers \(now.markers)")
    }
    await cutTick()
    await waitUntil{checkins().first?["status"] as? String=="running"}
    let checkID=checkins().first?["id"] as? String ?? ""
    expect(checkins().count==1 && check(checkID)["status"] as? String=="running","the automatic check-in on Inbox starts: \(checkins().map(said))")
    box.key=nil;await cutTick();box.key="fixture-key"
    expect(check(checkID)["status"] as? String=="running","a Claude key that can't be read for a moment (the Keychain locks with the Mac) does not stop a check that already has it: \(said(check(checkID)))")
    await cutTick(600)
    expect(check(checkID)["status"] as? String=="running","ten minutes asleep do not count toward its three-minute limit: \(said(check(checkID)))")
    for _ in 0..<17 {await cutTick()}
    let requeued=check(checkID)
    expect(requeued["status"] as? String=="queued" && requeued["requeues"] as? Int==1 && requeued["retryAt"] is String && checkins().count==1,"three awake minutes without an answer queue the same check again, to wait its turn: \(checkins().map(said))")
    try quiet("cut short by its time limit",hiding:checkID)
    await cutTick()
    expect(check(checkID)["status"] as? String=="queued","it waits before it is tried again: \(said(check(checkID)))")
    await cutTick(601)
    await waitUntil{check(checkID)["status"] as? String=="running"}
    expect(check(checkID)["status"] as? String=="running" && checkins().count==1,"after its wait the same check runs again under the current settings: \(checkins().map(said))")
    await cutTick(paused:true)
    expect(check(checkID)["status"] as? String=="queued" && check(checkID)["requeues"] as? Int==1,"Pause all puts it back in the queue without counting against it: \(said(check(checkID)))")
    await cutTick()
    await waitUntil{check(checkID)["status"] as? String=="running"}
    expect(check(checkID)["status"] as? String=="running","and it runs again once the queue does: \(said(check(checkID)))")
    _ = try BuddyAISettings(support:cutRoot).update(w,enabled:("claude",false))
    await cutTick()
    expect(check(checkID)["status"] as? String=="cancelled","a check whose provider the person disconnected can no longer happen and is dropped: \(said(check(checkID)))")
    for _ in 0..<3 {await cutTick(61)}
    expect(checkins().count==1,"no new check-in is queued while the provider is disconnected: \(checkins().map(said))")
    try quiet("dropped after a disconnect",hiding:checkID)
    _ = try BuddyAISettings(support:cutRoot).update(w,enabled:("claude",true))
    await cutTick(61)
    await waitUntil{checkins().count==2 && checkins()[1]["status"] as? String=="running"}
    let lastID=checkins().last?["id"] as? String ?? ""
    expect(checkins().count==2 && check(lastID)["status"] as? String=="running","once reconnected the next check-in runs: \(checkins().map(said))")
    try cut.store.update(lastID,["requeues":3])
    for _ in 0..<17 {await cutTick()}
    expect(check(lastID)["status"] as? String=="interrupted","a check cut short a fourth time is given up (and kept on record): \(said(check(lastID)))")
    try quiet("given up",hiding:lastID)
    for _ in 0..<3 {await cutTick(601)}
    expect(checkins().count==2,"and nothing loops: no further automatic retry follows: \(checkins().map(said))")
    cut.shutdown()
    // Records the older build saved (Inbox's three, startedAt = createdAt and no finishedAt) stay saved, and stop showing.
    let oldState:[String:Any]=["version":1,"conversationWorkspace":w,"agents":[agentRow(cChief,"Chief"),agentRow(rex,"Inbox")],"messages":[String:Any]()]
    let oldRoot=try fixtureRoot("SavedInterruptions",oldState),policyRow:[String:Any]=["enabled":true,"supervisorId":cChief,"supervisorChosen":true,"agents":[String:Any](),"intervalMinutes":15,"dailyLimitUSD":2.0,"revision":1]
    func oldCheck(_ id:String,_ at:String,_ status:String,_ extra:[String:Any]=[:])->[String:Any] {(["id":id,"workspace":w,"agentId":rex,"kind":"checkin","status":status,"createdAt":at,"startedAt":at,"fingerprint":"f","policyRevision":1,"provider":"claude","model":"claude-haiku-5-5","force":false,"input":["requesterId":cChief,"agent":["id":rex,"name":"Inbox"]]] as [String:Any]).merging(extra){_,n in n}}
    let stoppedText="This check stopped because access, settings, or its time limit changed."
    let answered=UUID().uuidString,old=[UUID().uuidString,UUID().uuidString,UUID().uuidString],stamp=ISO8601DateFormatter()
    var oldChecks:[[String:Any]]=[oldCheck(answered,stamp.string(from:Date().addingTimeInterval(-3*3600)),"completed",["finishedAt":stamp.string(from:Date().addingTimeInterval(-3*3600+30)),"output":["notify":false,"body":"","priority":2,"sourceIds":[String]()]])]
    for (id,ago) in zip(old,[-7200.0,-5400,-3600]) {oldChecks.append(oldCheck(id,stamp.string(from:Date().addingTimeInterval(ago)),"interrupted",["error":stoppedText]))}
    try JSONSerialization.data(withJSONObject:["version":1,"settings":[w:policyRow],"checks":oldChecks,"updates":[[String:Any]](),"observed":[String:Any](),"daily":[String:Any]()]).write(to:oldRoot.appendingPathComponent("team-monitor.json"))
    let older=try BuddyTeamMonitor(support:oldRoot,makeClaude:factory,keyReader:{_ in "fixture-key"})
    let oldHistory=try older.handle(["action":"messages"],state:oldState,jobs:[])["messages"] as? [[String:Any]] ?? [],oldStatus=try older.status(oldState)
    expect(oldHistory.map{$0["id"] as? String ?? ""}==[answered],"saved interrupted check-ins are not in the agent-message history, the answered one still is: \(oldHistory.map{"\($0["status"] ?? "") · \($0["error"] ?? "")"})")
    expect(!(oldStatus["checks"] as? [[String:Any]] ?? []).contains{$0["status"] as? String=="interrupted"} && ((oldStatus["agentMessages"] as? [String:[String:Any]])?[rex]?["count"] as? Int)==1,"nor in the page's status or its chat markers: \(oldStatus["agentMessages"] ?? "")")
    expect(BuddyTeamMonitor.pendingOrFailed(older.store.checks,workspace:w,agents:oldState["agents"] as! [[String:Any]],now:Date()).isEmpty,"and a team summary is not told about them")
    let onDisk=try JSONSerialization.jsonObject(with:Data(contentsOf:oldRoot.appendingPathComponent("team-monitor.json"))) as? [String:Any] ?? [:]
    expect(Set(old).isSubset(of:Set((onDisk["checks"] as? [[String:Any]] ?? []).compactMap{$0["id"] as? String})) && older.store.checks.filter{$0["status"] as? String=="interrupted"}.count==3,"they are still saved, not deleted")
    older.shutdown()
    require(failed.isEmpty,"\(failed.count) expectation(s) about check-ins cut short failed")
    print("PASS: an automatic check-in cut short is never shown: an unreadable key or time asleep does not stop it, a pause, a reconnect or its time limit queue it again quietly (paced and bounded), a disconnect drops it without a word, and saved interruptions stop showing without being deleted")
  }
  print("PASS: real private check-ins, Chief oversight, selected models, quiet defaults and opt-in updates, idle suppression, source receipts, ongoing preference learning, exact quotes, manual precedence, sharing revocation and workspace isolation")
 }
}
