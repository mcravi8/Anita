import Foundation
@main struct DirectTests {
 @MainActor static func require(_ v:Bool,_ m:String){if !v{fputs("FAILED: \(m)\n",stderr);exit(1)}}
 @MainActor static func main() async throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent("buddy-direct-"+UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
  let workspace=UUID().uuidString,agent=UUID().uuidString,key=workspace+":"+agent,run=UUID().uuidString
  let service=ConversationService(support:root,executable:URL(fileURLWithPath:CommandLine.arguments[1]));defer{service.shutdown()}
  var access=true;service.agentPermission={_,keys in access && keys==[key]}
  func call(_ name:String,_ args:[String:Any]) async throws -> [String:Any] {try await service.directService(name,args:args,workspace:workspace,keys:[key],runID:run,permitted:{access})}
  let catalog=try await call("buddy_service_tools",["service":""])
  require((catalog["services"] as? [[String:Any]])?.first?["name"] as? String=="Gmail","permitted services can be discovered")
  let schema=try await call("buddy_service_tools",["service":"Gmail"])
  let tools=schema["tools"] as! [[String:Any]]
  require(Set(tools.compactMap{$0["name"] as? String})==Set(["get_profile","read_email"]),"both catalog policy and authenticated MCP metadata must certify a read")
  let first=try await call("buddy_service_read",["service":"Gmail","tool":"read_email","argumentsJson":"{\"message_id\":\"one\"}"])
  let second=try await call("buddy_service_read",["service":"Gmail","tool":"read_email","argumentsJson":"{\"message_id\":\"two\"}"])
  require((first["result"] as? [String:Any])?["id"] as? String=="one" && (second["result"] as? [String:Any])?["fixtureThreads"] as? Int==1,"direct observed sources reuse one ready read-only channel across messages")
  for bad in ["send_email","forged_read","other.read_email"] {
   var rejected=false;do{_ = try await call("buddy_service_read",["service":"Gmail","tool":bad,"argumentsJson":"{}"])}catch{rejected=true};require(rejected,"write, unverified and wrong-connector tools are denied")
  }
  // A web search result stays in the agent's context: it comes back short unless the agent asks for more, and never longer than one call's worth.
  func searchText(_ value:[String:Any])->String {((value["result"] as? [String:Any])?["content"] as? [[String:Any]] ?? []).compactMap{$0["text"] as? String}.joined()}
  func search(_ arguments:String) async throws -> [String:Any] {try await call("buddy_service_read",["service":"Search Service","tool":"web_run","argumentsJson":arguments])}
  let quick=try await search(#"{"system2_search_query":[{"q":"vvix history"}]}"#)
  require(searchText(quick).hasPrefix("response_length=short queries=1") && searchText(quick).contains("vvix history") && quick["note"]==nil,"a search that doesn't say how much it wants gets the short answer, whole: \(searchText(quick).prefix(60))")
  let medium=try await search(#"{"system2_search_query":[{"q":"one"}],"response_length":"medium"}"#)
  require(searchText(medium).hasPrefix("response_length=medium") && searchText(medium).count>9000 && medium["note"]==nil,"an answer within the bound is untouched")
  let long=try await search(#"{"system2_search_query":[{"q":"first"},{"q":"second"}],"response_length":"long"}"#),longText=searchText(long),note=long["note"] as? String ?? ""
  require(longText.hasPrefix("response_length=long queries=2") && longText.count<=ConversationService.searchCharacters && longText.contains("Result 0 for first"),"a long answer is cut to one call's worth: \(longText.count) characters")
  require(note.contains("open") && note.contains("lineno") && note.contains("fewer queries") && note.range(of:#"\d{4,} more characters"#,options:.regularExpression) != nil,"the cut says how much was left out and how to read on: \(note)")
  // A prepared result must verify the live mailbox, without rereading its mail.
  let at=ISO8601DateFormatter().string(from:Date()),rid=UUID().uuidString,task=UUID().uuidString,review=UUID().uuidString,sourceRun=UUID().uuidString
  let coverage:[String:Any] = ["id":review,"runID":sourceRun,"query":"assessment","partial":false,"searchExhausted":true,"unread":0,"read":2,"checkedAt":at,"accountHash":BuddyInboxReview.accountHash("fixture@example.invalid")]
  var receipt=coverage;receipt["workspace"]=workspace;receipt["agent"]=agent;receipt["committed"]=true;receipt["analysisRecorded"]=true
  func write(_ value:[String:Any],_ path:String)throws{let url=root.appendingPathComponent(path);try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true);try JSONSerialization.data(withJSONObject:value).write(to:url,options:.atomic)}
  try write(["version":1,"routines":[["id":rid,"workspace":workspace,"agentId":agent,"status":"active","kind":"email","goal":"Assessments","query":"assessment","timeZone":"UTC"]]],"Worker/routines.json")
  try write(["version":1,"tasks":[["id":task,"routineID":rid,"workspace":workspace,"agentId":agent,"status":"completed","goal":"Assessments","inboxQuery":"assessment","createdAt":at,"result":"Observed saved assessments.","coverage":[coverage]]]],"Worker/tasks.json")
  try write(receipt,"InboxReviews/"+sourceRun+"-"+review+".json")
  let prepared=try await service.preparedInbox(workspace:workspace,agent:agent,text:"What assessments?",query:"assessment",keys:[key],permitted:{access})
  require(prepared?["taskID"] as? String==task,"prepared answer uses committed result plus a live account identity check, without a new email search")
  try Data("different@example.invalid".utf8).write(to:root.appendingPathComponent("fixture-mailbox.txt"))
  let changed=try await service.preparedInbox(workspace:workspace,agent:agent,text:"What assessments?",query:"assessment",keys:[key],permitted:{access})
  require(changed==nil,"a changed live Gmail account cannot reuse another mailbox's findings")
  _ = try await service.setConnectionAccess(key:key,connection:"mail",allowed:false)
  var rejected=false;do{_ = try await call("buddy_service_read",["service":"Gmail","tool":"read_email","argumentsJson":"{}"])}catch{rejected=true};require(rejected,"cached channels cannot bypass removed per-agent access")
  _ = try await service.setConnectionAccess(key:key,connection:"mail",allowed:true)
  Task{@MainActor in try? await Task.sleep(nanoseconds:20_000_000);access=false}
  rejected=false;do{_ = try await call("buddy_service_read",["service":"Gmail","tool":"read_email","argumentsJson":"{\"message_id\":\"delayed\"}"])}catch{rejected=true};require(rejected,"revoked in-flight results are withheld")
  print("PASS: direct selected-model reads, verified schema discovery, no model handoff, warm channel reuse, write/forged tool rejection and live access checks")
 }
}
