import AppKit
@main struct SignInIntegration {
    static func require(_ value:Bool,_ message:String){if !value{fputs("FAILED: \(message)\n",stderr);exit(1)}}
    @MainActor static func main() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("buddy-signin-tests-"+UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let workspace=UUID().uuidString,agent=UUID().uuidString,other=UUID().uuidString
        try JSONSerialization.data(withJSONObject:["conversationWorkspace":workspace,"agents":[["id":agent,"name":"Check","role":"Fixture","description":"Inert signup","tools":[:]],["id":other,"name":"Other","role":"Fixture","description":"Inert second agent","tools":[:]]]]).write(to:root.appendingPathComponent("workspace.json"))
        let host=BuddyWorkerHost(support:root,executable:URL(fileURLWithPath:CommandLine.arguments[1]),makeBrowser:{BuddyWorkerProcess(resource:URL(fileURLWithPath:CommandLine.arguments[2]),runtime:URL(fileURLWithPath:CommandLine.arguments[3]))})
        host.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification));defer{host.applicationWillTerminate(Notification(name:NSApplication.willTerminateNotification))}
        func call(_ values:[String:Any]) async throws->[String:Any]{try await BuddyWorkerClient.call(support:root,payload:values.merging(["workspace":workspace]){_,new in new})}
        func wait(_ id:String,_ status:String) async throws->[String:Any]{for _ in 0..<120{let t=try await call(["operation":"detail","taskId":id])["task"] as! [String:Any];if t["status"] as? String==status{return t};if t["status"] as? String=="failed"{throw BuddyFailure(message:"Sign-in fixture failed: \(t["progress"] ?? "unknown")")};try await Task.sleep(nanoseconds:100_000_000)};throw BuddyFailure(message:"Sign-in fixture timed out waiting for \(status)")}
        func create(_ request:String,for owner:String?=nil) async throws->String{let value=try await call(["operation":"create","agentId":owner ?? agent,"requestId":request,"title":"Inert account","goal":"Exercise a private sign-in checkpoint only","kind":"general","provider":"chatgpt","budgetUSD":0]);return (value["task"] as! [String:Any])["id"] as! String}
        let declined=try await create("decline"),first=try await wait(declined,"waiting_review"),review=(first["reviews"] as! [[String:Any]])[0]
        require(review["kind"] as? String=="authentication" && review["mode"] as? String=="signin","a sign-in always has a native choice before private Chrome opens (new accounts ask with their own card: tests/WebsiteAccounts.swift)")
        _ = try await call(["operation":"review","taskId":declined,"id":review["id"]!,"accept":false]);_ = try await wait(declined,"completed")
        require(!FileManager.default.fileExists(atPath:root.appendingPathComponent("Worker/PrivateSignIn.json").path),"declining cannot open a private browser or grant a session")
        let id=try await create("approve"),pending=try await wait(id,"waiting_review"),r=(pending["reviews"] as! [[String:Any]])[0]
        _ = try await call(["operation":"review","taskId":id,"id":r["id"]!,"accept":true,"authAction":"private"])
        _ = try await wait(id,"waiting_user")
        require(FileManager.default.fileExists(atPath:root.appendingPathComponent("Worker/PrivateSignIn.json").path),"private handoff suspends desktop observations across Buddy")
        // The shared Chrome window is the person's while it is open: the queue keeps running, and agents' pages wait for the window.
        let status=try await call(["operation":"status"]);require(status["paused"] as? Bool==false && (status["privateBrowser"] as? [String:Any])?["shared"] as? Bool==true,"the queue is not paused by a private sign-in, and the shared window is visible")
        require((status["signinRequests"] as? [[String:Any]] ?? []).contains{$0["taskId"] as? String==id && $0["kind"] as? String=="step" && $0["chromeOpen"] as? Bool==true},"the chat asks the person to finish in Chrome and press Done")
        let elsewhere=try await create("other-agent",for:other)
        var started:[String:Any]=[:]
        for _ in 0..<120{let t=try await call(["operation":"detail","taskId":elsewhere])["task"] as! [String:Any];if ["running","waiting_review","completed"].contains(t["status"] as? String ?? ""){started=t;break};try await Task.sleep(nanoseconds:100_000_000)}
        require(!started.isEmpty,"another agent's queued task starts while the shared Chrome window is open")
        if started["status"] as? String != "completed" {_ = try await call(["operation":"cancel","taskId":elsewhere])}
        var finished=false
        for _ in 0..<80{do{_ = try await call(["operation":"finishSignIn"]);finished=true;break}catch{try await Task.sleep(nanoseconds:100_000_000)}}
        require(finished,"human finish closes private handoff after the agent pauses")
        _ = try await wait(id,"completed")
        require(!FileManager.default.fileExists(atPath:root.appendingPathComponent("Worker/PrivateSignIn.json").path),"finish removes the private marker and resumes the saved task")
        print("PASS: native sign-in choice/decline, the shared Chrome window handed to the person (the queue keeps running for others), protected desktop marker, Done in the chat and task resume without credentials")
        // Chief on RunPod, 23 Oct: a click on the deploy page's "CPU" tab waited for the user. A step the browser calls routine goes ahead by
        // itself, recorded as Buddy's own decision; one it does not (Deploy) still waits for review.
        func browserStep(_ marker:String) async throws->String{let value=try await call(["operation":"create","agentId":agent,"requestId":marker,"title":"Deploy page","goal":"\(marker) on the deploy page","kind":"general","provider":"chatgpt","budgetUSD":0]);return (value["task"] as! [String:Any])["id"] as! String}
        let shown=try await wait(try await browserStep("ROUTINE-CLICK"),"completed")
        let shownStep=(shown["reviews"] as? [[String:Any]] ?? []).first{$0["kind"] as? String=="browser"} ?? [:]
        require(shownStep["status"] as? String=="completed" && shownStep["autoApproved"] as? Bool==true && shownStep["answeredBy"] as? String=="rule" && shownStep["answeredByName"] as? String=="Buddy"
                && (shownStep["answerReason"] as? String ?? "").contains("only changes what the page shows"),"a routine browser step went ahead as Buddy's own decision: \(shownStep)")
        let held=try await browserStep("REVIEWED-CLICK"),waiting=try await wait(held,"waiting_review")
        let heldStep=(waiting["reviews"] as? [[String:Any]] ?? []).first{$0["kind"] as? String=="browser"} ?? [:]
        require(heldStep["status"] as? String=="pending" && heldStep["autoApproved"]==nil,"a step the browser does not call routine waits for review: \(heldStep)")
        _ = try await call(["operation":"review","taskId":held,"id":heldStep["id"]!,"accept":true]);_ = try await wait(held,"completed")
        print("PASS: a browser step that only shows something goes ahead as Buddy's own decision; one that could change something waits for review")
    }
}
