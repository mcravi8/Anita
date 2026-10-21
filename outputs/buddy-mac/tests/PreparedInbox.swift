import Foundation
@main struct PreparedTests {
 @MainActor static func require(_ v:Bool,_ m:String){if !v{fputs("FAILED: \(m)\n",stderr);exit(1)}}
 @MainActor static func main() throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent("buddy-prepared-"+UUID().uuidString)
  defer{try? FileManager.default.removeItem(at:root)}
  let workspace=UUID().uuidString,agent=UUID().uuidString,rid=UUID().uuidString,task=UUID().uuidString,run=UUID().uuidString,review=UUID().uuidString
  let now=ISO8601DateFormatter().date(from:"2026-10-16T17:00:00Z")!,at="2026-10-16T16:00:00Z",query="newer_than:90d assessment"
  var routine:[String:Any] = ["id":rid,"workspace":workspace,"agentId":agent,"status":"active","kind":"email","title":"Morning assessments","goal":"Review assessments","query":query,"timeZone":"America/Los_Angeles"]
  var coverage:[String:Any] = ["id":review,"runID":run,"query":query,"partial":false,"searchExhausted":true,"unread":0,"read":2,"checkedAt":at,"at":at,"accountHash":BuddyInboxReview.accountHash("fixture@example.invalid")]
  var receipt=coverage;receipt["workspace"]=workspace;receipt["agent"]=agent;receipt["committed"]=true;receipt["analysisRecorded"]=true;receipt["sources"]=[["id":"ubs","url":"https://example.invalid/ubs"]];receipt["findings"]=[["messageID":"ubs","status":"action_required","summary":"Verified fixture source"]]
  var job:[String:Any] = ["id":task,"routineID":rid,"workspace":workspace,"agentId":agent,"status":"completed","goal":"Review assessments","inboxQuery":query,"createdAt":at,"updatedAt":at,"result":"Found UBS and Zopa in the recorded sources.","coverage":[coverage]]
  func write(_ value:[String:Any],_ path:String)throws{let url=root.appendingPathComponent(path);try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true);try JSONSerialization.data(withJSONObject:value).write(to:url,options:.atomic)}
  func save()throws{try write(["version":1,"routines":[routine]],"Worker/routines.json");try write(["version":1,"tasks":[job]],"Worker/tasks.json");try write(receipt,"InboxReviews/"+run+"-"+review+".json")}
  func candidate(_ text:String="What assessments do I have?",_ q:String?=nil)throws->[String:Any]?{try BuddyPreparedInbox.candidate(support:root,workspace:workspace,agent:agent,text:text,query:q ?? query,now:now)}
  try save();let saved=try candidate();require(saved?["taskID"] as? String==task && (saved?["coverage"] as? [[String:Any]])?.first?["prepared"] as? Bool==true,"completed matching result has checked-time provenance")
  require((saved?["sourceRecords"] as? [[String:Any]])?.first?["sources"] is [[String:Any]],"native source records accompany the saved model summary")
  require(try candidate("Do a fresh check of assessment emails")==nil,"fresh check explicitly bypasses saved results")
  require(try candidate("Refresh my assessment emails now")==nil,"explicit fresh checks bypass prepared results")
  require(try candidate("What assessments?","different query")==nil,"a narrower or unrelated search cannot substitute for the requested scope")
  require(try BuddyPreparedInbox.candidate(support:root,workspace:workspace,agent:UUID().uuidString,text:"assessments",query:query,now:now)==nil,"results cannot cross agents")
  job["status"]="failed";try save();require(try candidate()==nil,"failed or in-progress latest runs cannot serve a successful cache");job["status"]="completed"
  routine["goal"]="Different task";try save();require(try candidate()==nil,"edited routine configuration invalidates old analysis");routine["goal"]="Review assessments"
  routine["status"]="paused";try save();require(try candidate()==nil,"paused routines do not serve prepared answers");routine["status"]="active"
  receipt["committed"]=false;try save();require(try candidate()==nil,"uncommitted source analysis is not a prepared answer");receipt["committed"]=true
  coverage["partial"]=true;job["coverage"]=[coverage];try save();require(try candidate()==nil,"partial coverage requires a fresh review");coverage["partial"]=false
  coverage["checkedAt"]="2026-10-15T16:00:00Z";job["coverage"]=[coverage];try save();require(try candidate()==nil,"yesterday's result cannot be labeled checked today")
  print("PASS: completed prepared results, source provenance, exact query scope, freshness, changed routines, partial/failure rejection and agent isolation")
 }
}
