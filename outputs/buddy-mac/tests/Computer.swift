import Foundation
@main struct ComputerTests {
 @MainActor static func check(_ value:Bool,_ message:String){if !value{fputs("FAILED: \(message)\n",stderr);exit(1)}}
 @MainActor static func main() async throws {
  let support=FileManager.default.temporaryDirectory.appendingPathComponent("buddy-computer-"+UUID().uuidString)
  defer{try? FileManager.default.removeItem(at:support)}
  let computer=BuddyComputer(support:support)
  check(!computer.enabled,"desktop is off until explicitly connected")
  try computer.setEnabled(true)
  check(BuddyComputer(support:support).enabled,"connection persists")
  var effects=0,state="0 window Calculator\n1 button Two\n2 text Result: 0",codes:[String]=[],allowed=true
  let invoke:BuddyComputer.Invoke={thread,code in
   codes.append(code)
   if code=="await cua.getState();"{return ["content":[["type":"text","text":"## Computer Use\nDocumentation"]]]}
   if code.contains("cua.listApps") {return ["content":[["type":"text","text":"{\"apps\":[{\"id\":\"com.apple.calculator\",\"name\":\"Calculator\"}]}"]]]}
   if code.hasPrefix("await buddyComputerApp.click") {effects+=1;state="0 window Calculator\n1 button Two\n2 text Result: 2"}
   return ["content":[["type":"text","text":state]]]
  }
  func call(_ tool:String,_ args:[String:Any],run:String="one") async throws->[String:Any]{try await computer.call(run:run,thread:"thread",tool:tool,args:args,allowed:{allowed},invoke:invoke)}
  func snapshot(_ result:[String:Any])->String{let text=(result["contentItems"] as! [[String:Any]])[0]["text"] as! String;return text.components(separatedBy:"Fresh snapshotId: ")[1].components(separatedBy:"\n")[0]}
  _=try await call("buddy_desktop_apps",[:])
  let observed=try await call("buddy_desktop_observe",["appId":"com.apple.calculator"])
  let first=snapshot(observed)
  let preview=try computer.preview("one",args:["snapshotId":first,"action":"click","element":1])
  check((preview["arguments"] as? [String:Any])?["target"] as? String == "Calculator · Button Two","review shows actual observed target")
  state += "\n3 changed window"
  var denied=false
  do{_=try await call("buddy_desktop_act",["snapshotId":first,"action":"click","element":1])}catch{denied=(error as? BuddyComputerFailure)?.code=="stale_snapshot"}
  check(denied && effects==0,"changed window sends no effect")
  let current=snapshot(try await call("buddy_desktop_observe",["appId":"com.apple.calculator"]))
  _=try await call("buddy_desktop_act",["snapshotId":current,"action":"click","element":1])
  denied=false;do{_=try await call("buddy_desktop_act",["snapshotId":current,"action":"click","element":1])}catch{denied=true}
  check(denied && effects==1,"consumed snapshot cannot repeat effect")
  var teammateAllowed=true
  let beforeWait=codes.count
  let teammate=Task { () -> Bool in
   do { _=try await computer.call(run:"teammate",thread:"other",tool:"buddy_desktop_observe",args:["appId":"com.apple.calculator"],allowed:{teammateAllowed},invoke:invoke);return false }
   catch {return (error as? BuddyComputerFailure)?.code=="access_removed"}
  }
  try await Task.sleep(nanoseconds:200_000_000);teammateAllowed=false
  let blocked=await teammate.value
  check(blocked && codes.count==beforeWait,"a teammate waits for the Mac and cannot act after cancellation")
  allowed=false;denied=false;do{_=try await call("buddy_desktop_observe",["appId":"com.apple.calculator"])}catch{denied=true}
  check(denied,"removed access blocks reads and actions")
  allowed=true;_=try await call("buddy_desktop_release",[:])
  _=try await call("buddy_desktop_apps",[:],run:"two")
  check(codes.first=="await cua.getState();" && codes.filter{$0=="await cua.getState();"}.count==1,"first runtime invocation is bounded and initialized once")
  for args:[String:Any] in [["action":"eval","text":"bad"],["action":"click","element":true],["action":"scroll","element":0,"direction":"down","pages":true],["action":"click","element":0,"code":"bad"],["action":"press_key","key":"\u{0}"]] {
   denied=false;do{_=try BuddyComputer.actionCode(args)}catch{denied=true};check(denied,"unsupported or malformed operation rejected")
  }
  let injection="\"); process.exit(); //\n`$(bad)`"
  let encoded=try BuddyComputer.literal(injection),code=try BuddyComputer.actionCode(["action":"type_text","text":injection])
  check(code.contains("typeText("+encoded+")"),"text remains a quoted literal, never executable code")
  try Data("broken".utf8).write(to:support.appendingPathComponent("computer-access.json"))
  check(!BuddyComputer(support:support).enabled && BuddyComputer(support:support).invalidSettings,"malformed permissions fail closed")
  print("PASS: desktop connection, observed targets, stale UI rejection, no replay, access revocation, strict operations, literal encoding, and corrupt settings")
 }
}
