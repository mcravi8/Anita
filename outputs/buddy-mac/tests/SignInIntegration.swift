import AppKit
@main struct SignInIntegration {
    static func require(_ value:Bool,_ message:String){if !value{fputs("FAILED: \(message)\n",stderr);exit(1)}}
    @MainActor static func main() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("buddy-signin-tests-"+UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let workspace=UUID().uuidString,agent=UUID().uuidString
        try JSONSerialization.data(withJSONObject:["conversationWorkspace":workspace,"agents":[["id":agent,"name":"Check","role":"Fixture","description":"Inert signup","tools":[:]]]]).write(to:root.appendingPathComponent("workspace.json"))
        let host=BuddyWorkerHost(support:root,executable:URL(fileURLWithPath:CommandLine.arguments[1]),makeBrowser:{BuddyWorkerProcess(resource:URL(fileURLWithPath:CommandLine.arguments[2]),runtime:URL(fileURLWithPath:CommandLine.arguments[3]))})
        host.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification));defer{host.applicationWillTerminate(Notification(name:NSApplication.willTerminateNotification))}
        func call(_ values:[String:Any]) async throws->[String:Any]{try await BuddyWorkerClient.call(support:root,payload:values.merging(["workspace":workspace]){_,new in new})}
        func wait(_ id:String,_ status:String) async throws->[String:Any]{for _ in 0..<120{let t=try await call(["operation":"detail","taskId":id])["task"] as! [String:Any];if t["status"] as? String==status{return t};if t["status"] as? String=="failed"{throw BuddyFailure(message:"Sign-in fixture failed: \(t["progress"] ?? "unknown")")};try await Task.sleep(nanoseconds:100_000_000)};throw BuddyFailure(message:"Sign-in fixture timed out waiting for \(status)")}
        func create(_ request:String) async throws->String{let value=try await call(["operation":"create","agentId":agent,"requestId":request,"title":"Inert account","goal":"Exercise a private sign-in checkpoint only","kind":"general","provider":"chatgpt","budgetUSD":0]);return (value["task"] as! [String:Any])["id"] as! String}
        let declined=try await create("decline"),first=try await wait(declined,"waiting_review"),review=(first["reviews"] as! [[String:Any]])[0]
        require(review["kind"] as? String=="authentication" && review["mode"] as? String=="signup","new accounts always have a native approval before private Chrome opens")
        _ = try await call(["operation":"review","taskId":declined,"id":review["id"]!,"accept":false]);_ = try await wait(declined,"completed")
        require(!FileManager.default.fileExists(atPath:root.appendingPathComponent("Worker/PrivateSignIn.json").path),"declining cannot open a private browser or grant a session")
        let id=try await create("approve"),pending=try await wait(id,"waiting_review"),r=(pending["reviews"] as! [[String:Any]])[0]
        _ = try await call(["operation":"review","taskId":id,"id":r["id"]!,"accept":true,"authAction":"private"])
        _ = try await wait(id,"waiting_user")
        require(FileManager.default.fileExists(atPath:root.appendingPathComponent("Worker/PrivateSignIn.json").path),"private handoff suspends desktop observations across Buddy")
        let status=try await call(["operation":"status"]);require(status["paused"] as? Bool==true && status["privateBrowser"] is [String:Any],"queue is paused and the native private session is visible")
        var finished=false
        for _ in 0..<80{do{_ = try await call(["operation":"finishSignIn"]);finished=true;break}catch{try await Task.sleep(nanoseconds:100_000_000)}}
        require(finished,"human finish closes private handoff after the agent pauses")
        _ = try await wait(id,"completed")
        require(!FileManager.default.fileExists(atPath:root.appendingPathComponent("Worker/PrivateSignIn.json").path),"finish removes the private marker and resumes the saved task")
        print("PASS: native signup approval/decline, private browser handoff, queue pause, protected desktop marker, human finish and task resume without credentials")
    }
}
