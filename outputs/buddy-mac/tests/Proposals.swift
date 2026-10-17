import Foundation

@MainActor func check(_ condition: Bool, _ message: String) { if !condition { fatalError(message) } }
@MainActor func rejects(_ body: () throws -> Any, _ message: String) { do { _ = try body(); fatalError(message) } catch {} }
@main struct ProposalChecks {
 @MainActor static func main() throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent("buddy-proposals-test-"+UUID().uuidString)
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
  defer { try? FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:root.path); try? FileManager.default.removeItem(at:root) }
  let workspace=UUID().uuidString,run=UUID().uuidString,store=BuddyAgentProposals(support:root),url=root.appendingPathComponent("workspace.json")
  let original:[String:Any] = ["version":1,"conversationWorkspace":workspace,"agents":[["id":"chief","name":"Chief","role":"Chief of Staff","description":"Manage the team","tools":["projectFiles":false]]],"groups":[["id":"g","name":"Cedar","members":["chief"]]],"messages":["chief":[["id":"keep","body":"Real history"]]],"drafts":["chief":"Unsent draft"],"files":[]]
  func write(_ value:[String:Any]) throws { try JSONSerialization.data(withJSONObject:value).write(to:url,options:.atomic) }
  func read() throws -> [String:Any] { try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as! [String:Any] }
  try write(original)
  let scope=BuddyProposalScope(workspace:workspace,chat:"chief",actorId:"chief",replyRunId:run)
  let config:[String:Any] = ["name":"Sage","role":"Writer","description":"Draft friendly plant-shop copy.","avatarShape":"cube","avatarColor":"red","reason":"A writer would help draft the launch."]
  let result=try store.propose(scope,executionRunId:run,callId:"call-1",arguments:config),p=result["proposal"] as! [String:Any],id=p["id"] as! String
  check(result["added"] as? Bool == false,"A model proposal must not add an agent")
  check((try read()["agents"] as? [[String:Any]])?.count == 1,"Pending suggestion created an agent")
  check((try store.propose(scope,executionRunId:run,callId:"call-1",arguments:config)["proposal"] as? [String:Any])?["id"] as? String == id,"Duplicate tool call created a new suggestion")
  let reloaded=BuddyAgentProposals(support:root)
  check(try reloaded.list(workspace).count == 1,"Pending suggestion did not survive restart")
  let invalidScope=BuddyProposalScope(workspace:workspace,chat:"chief",actorId:"missing",replyRunId:run)
  rejects({try store.propose(invalidScope,executionRunId:run,callId:"bad",arguments:config)},"Unregistered actor proposed")
  rejects({try store.list(UUID().uuidString)},"Cross-workspace access accepted")
  var edited=config;edited["name"]="Cedar Writer";edited["avatarColor"]="gold";edited["tools"]=["web":true,"projectFiles":false];edited["groupIds"]=["g"]
  let saved=try store.review(workspace,payload:["proposalId":id,"revision":0,"action":"save","config":edited])["proposal"] as! [String:Any]
  check((saved["suggested"] as? [String:Any])?["name"] as? String == "Sage","Original suggestion was lost")
  check((saved["draft"] as? [String:Any])?["name"] as? String == "Cedar Writer","Saved edits missing")
  rejects({try store.review(workspace,payload:["proposalId":id,"revision":0,"action":"approve","config":edited])},"Stale decision accepted")
  var duplicate=edited;duplicate["name"]="Chief"
  rejects({try store.review(workspace,payload:["proposalId":id,"revision":1,"action":"approve","config":duplicate])},"Duplicate agent name accepted")
  try FileManager.default.setAttributes([.posixPermissions:0o555],ofItemAtPath:root.path)
  rejects({try store.review(workspace,payload:["proposalId":id,"revision":1,"action":"approve","config":edited])},"Failed workspace save was treated as approval")
  try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:root.path)
  check((try read()["agents"] as? [[String:Any]])?.count == 1,"Failed approval added an agent")
  let approved=try store.review(workspace,payload:["proposalId":id,"revision":1,"action":"approve","config":edited]),agent=approved["agent"] as! [String:Any]
  check(agent["id"] as? String == id,"Approval needs stable identity")
  check((agent["tools"] as? [String:Bool])?["projectFiles"] == false,"Human access removal was ignored")
  let current=try read()
  check((current["agents"] as? [[String:Any]])?.count == 2,"Approval did not commit exactly one agent")
  check((current["drafts"] as? [String:String])?["chief"] == "Unsent draft","Approval lost existing work")
  check(((current["groups"] as? [[String:Any]])?.first?["members"] as? [String]) == ["chief",id],"Reviewed group membership missing")
  _ = try store.review(workspace,payload:["proposalId":id,"revision":1,"action":"approve","config":edited])
  check((try read()["agents"] as? [[String:Any]])?.count == 2,"Uncertain retry duplicated an agent")
  let protected=try store.preserveApprovals(in:original,previous:current)
  check((protected["agents"] as? [[String:Any]])?.count == 2,"Late UI snapshot removed approved agent")
  check(((protected["groups"] as? [[String:Any]])?.first?["members"] as? [String])?.contains(id) == true,"Late UI snapshot removed approved membership")
  // Simulate the approval committing while its separate receipt write was lost.
  var raw=try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("agent-proposals.json"))) as! [[String:Any]]
  raw[0]["status"]="pending";raw[0].removeValue(forKey:"approved");raw[0].removeValue(forKey:"agentId");raw[0]["draft"]=raw[0]["suggested"]
  try JSONSerialization.data(withJSONObject:raw).write(to:root.appendingPathComponent("agent-proposals.json"),options:.atomic)
  let reconciled=try store.list(workspace)[0]
  check(reconciled["status"] as? String == "approved","Unknown outcome did not recover committed approval")
  check((reconciled["approved"] as? [String:Any])?["name"] as? String == "Cedar Writer","Recovery discarded approved edits")
  var second=config;second["name"]="Scout test"
  let p2=try store.propose(scope,executionRunId:run,callId:"call-2",arguments:second)["proposal"] as! [String:Any]
  _ = try store.review(workspace,payload:["proposalId":p2["id"]!,"revision":0,"action":"decline"])
  rejects({try store.review(workspace,payload:["proposalId":p2["id"]!,"revision":1,"action":"approve","config":second])},"Declined suggestion was approved")
  var third=config;third["name"]="Analyst test"
  _ = try store.propose(scope,executionRunId:run,callId:"call-3",arguments:third)
  var fourth=config;fourth["name"]="Fourth test"
  rejects({try store.propose(scope,executionRunId:run,callId:"call-4",arguments:fourth)},"Per-request proposal limit not enforced")
  try Data("broken".utf8).write(to:root.appendingPathComponent("agent-proposals.json"))
  rejects({try store.propose(scope,executionRunId:UUID().uuidString,callId:"corrupt",arguments:fourth)},"Corrupt records were overwritten")
  check(String(data:try Data(contentsOf:root.appendingPathComponent("agent-proposals.json")),encoding:.utf8)=="broken","Corrupt saved records changed")
  print("Passed native proposal checks: pending isolation, trusted scope, saved edits, failure recovery, one-time approval, groups, late saves, uncertain outcomes, decline, limits, corrupt records.")
 }
}
