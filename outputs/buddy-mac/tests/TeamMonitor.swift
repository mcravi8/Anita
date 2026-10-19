import Foundation
@main struct TeamMonitorTests {
 @MainActor static func require(_ value:Bool,_ message:String){if !value{fputs("FAILED: \(message)\n",stderr);exit(1)}}
 @MainActor static func main() async throws {
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
  require((learned["description"] as? String)?.contains("concise")==true && (learned["learnedRules"] as? [[String:Any]])?.first?["messageId"] as? String=="user-pref","ongoing explicit preferences update effective instructions with exact user-message evidence")
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
  print("PASS: real private check-ins, Chief oversight, selected models, quiet defaults and opt-in updates, idle suppression, source receipts, ongoing preference learning, exact quotes, manual precedence, sharing revocation and workspace isolation")
 }
}
