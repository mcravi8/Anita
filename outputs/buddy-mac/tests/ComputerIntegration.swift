import Foundation
@main struct ComputerIntegration {
 @MainActor static func check(_ value:Bool,_ message:String){if !value{fputs("FAILED: \(message)\n",stderr);exit(1)}}
 @MainActor static func wait(_ predicate:()->Bool) async {for _ in 0..<600{if predicate(){return};try? await Task.sleep(nanoseconds:10_000_000)};check(false,"desktop fixture timed out")}
 @MainActor static func main() async throws {
  let support=FileManager.default.temporaryDirectory.appendingPathComponent("buddy-computer-rpc-"+UUID().uuidString)
  defer{try? FileManager.default.removeItem(at:support)}
  let workspace=UUID().uuidString,agent=UUID().uuidString,key=workspace+":"+agent
  try FileManager.default.createDirectory(at:support,withIntermediateDirectories:true)
  try JSONSerialization.data(withJSONObject:["conversationWorkspace":workspace,"agents":[["id":agent,"name":"Check"]],"groups":[]]).write(to:support.appendingPathComponent("workspace.json"))
  let service=ConversationService(support:support,executable:URL(fileURLWithPath:CommandLine.arguments[1]))
  var access=true
  service.agentPermission={w,ks in w==workspace && ks==[key]};service.computerPermission={w,ks in access && w==workspace && ks==[key]}
  _=try await service.setComputerAccess(true)
  func effects()->Int{((try? String(contentsOf:support.appendingPathComponent("Conversations/desktop-effects.jsonl"),encoding:.utf8)) ?? "").split(separator:"\n").count}
  func pending(_ run:String)->[String:Any]?{service.pendingInputs(workspace:workspace).first{$0["runId"] as? String==run && $0["status"] as? String=="pending"}}
  func terminal(_ run:String)->Bool{service.snapshots().contains{$0["runId"] as? String==run && ["completed","failed","stopped"].contains($0["status"] as? String ?? "")}}
  func send(_ mode:String) throws->String{
   let run=UUID().uuidString;var options=BuddyTurnOptions();options.actorId=agent;options.proposalScope=BuddyProposalScope(workspace:workspace,chat:agent,actorId:agent,replyRunId:run)
   _=try service.send(["runId":run,"key":key,"agent":["name":"Check","role":"Check","description":"Fixture only"],"text":mode],options:options);return run
  }
  func answer(_ r:[String:Any],_ choice:String) throws{_=try service.answerInput(workspace:workspace,payload:["id":r["id"]!,"answers":["operation":[choice]]])}
  func operation(_ run:String) async throws->[String:Any] {
   await wait{pending(run) != nil}
   if (pending(run)!["tool"] as? [String:Any])?["name"] as? String=="Allow app access" {
    let accessReview=pending(run)!
    try answer(accessReview,"Accept")
    await wait{pending(run) != nil && pending(run)!["id"] as? String != accessReview["id"] as? String}
   }
   return pending(run)!
  }
  let accepted=try send("accept");await wait{pending(accepted) != nil}
  let accessReview=pending(accepted)!
  check((accessReview["tool"] as? [String:Any])?["name"] as? String=="Allow app access" && effects()==0,"provider app permissions require a scoped human review")
  let record=try await operation(accepted)
  check(effects()==0,"no operation before human review")
  check(((record["tool"] as? [String:Any])?["arguments"] as? [String:Any])?["target"] as? String=="Calculator · Button Two","review uses exact observed control")
  try answer(record,"Accept");await wait{terminal(accepted)};check(effects()==1,"exactly one operation after review")
  check(service.pendingInputs(workspace:workspace).contains{$0["id"] as? String==record["id"] as? String && $0["status"] as? String=="completed"},"receipt requires real resulting observation")
  var rejected=false;do{try answer(record,"Accept")}catch{rejected=true};check(rejected,"duplicate review cannot replay")
  let declined=try send("decline");let declinedRecord=try await operation(declined);try answer(declinedRecord,"Decline");await wait{terminal(declined)};check(effects()==1,"decline sends no operation")
  let stopped=try send("stop");let stale=try await operation(stopped);_=try await service.stop(stopped);await wait{terminal(stopped)}
  rejected=false;do{try answer(stale,"Accept")}catch{rejected=true};check(rejected && effects()==1,"Stop invalidates waiting review")
  let revoked=try send("revoke");let old=try await operation(revoked);access=false
  try answer(old,"Accept");await wait{terminal(revoked)};check(effects()==1,"access removal at commitment blocks effect")
  access=true;let disabled=try send("disconnect");_=try await operation(disabled);_=try await service.setComputerAccess(false);await wait{terminal(disabled)};check(effects()==1 && pending(disabled)==nil,"disconnect stops pending work")
  service.shutdown();let restarted=ConversationService(support:support,executable:URL(fileURLWithPath:CommandLine.arguments[1]))
  check(!restarted.computer.enabled,"disconnect survives restart")
  rejected=false;do{_=try restarted.answerInput(workspace:workspace,payload:["id":record["id"]!,"answers":["operation":["Accept"]]])}catch{rejected=true};check(rejected && effects()==1,"restart cannot replay old operation")
  restarted.shutdown()
  print("PASS: desktop RPC routing, exact operation review, observation receipts, duplicate rejection, decline, Stop, per-agent revocation, disconnect, and restart")
 }
}
