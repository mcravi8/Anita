import Foundation
@main struct TeamMonitorTests {
 @MainActor static func require(_ value:Bool,_ message:String){if !value{fputs("FAILED: \(message)\n",stderr);exit(1)}}
 @MainActor static func main() async throws {
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
  var foreignHistory=state;foreignHistory["conversationWorkspace"]=UUID().uuidString
  require((try historyStore.messages(state:foreignHistory)["messages"] as! [[String:Any]]).isEmpty,"foreign workspace history stays inaccessible")
  let learned=(try BuddyAgentMemory.overlay(state,support:root)["agents"] as! [[String:Any]])[1]
  require((learned["description"] as? String)?.contains("concise")==true && (learned["learnedRules"] as? [[String:Any]])?.first?["messageId"] as? String=="user-pref","ongoing explicit preferences update effective instructions with exact user-message evidence")
  let callsURL=root.appendingPathComponent("TeamMonitor/fixture-calls.jsonl")
  let calls=try String(contentsOf:callsURL,encoding:.utf8).split(separator:"\n").map{try JSONSerialization.jsonObject(with:Data($0.utf8)) as! [String:Any]}
  require(calls.contains{$0["kind"] as? String=="checkin" && $0["model"] as? String=="fixture-maze"} && calls.contains{$0["kind"] as? String=="overview" && $0["model"] as? String=="fixture-chief"},"each check-in uses that agent's selected model")
  for _ in 0..<8 {await step()}
  require(try String(contentsOf:callsURL,encoding:.utf8).split(separator:"\n").count==calls.count,"unchanged work and saved preferences do not trigger repeat model calls")
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
