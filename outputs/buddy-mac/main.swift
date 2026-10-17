import AppKit
@preconcurrency import WebKit

@MainActor final class BuddyApp: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandlerWithReply {
    private var window: NSWindow?
    private var webView: WKWebView?
    private let filePreviews = BuddyFilePreview()
    private let supportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Buddy", isDirectory: true)
    private var stateURL: URL { supportURL.appendingPathComponent("workspace.json") }
    private lazy var conversations = ConversationService(support: supportURL)
    private lazy var ai = BuddyAIRouter(support: supportURL, chatgpt: conversations)
    private lazy var teamwork = BuddyTeamService(conversations: ai)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .aqua)
        if let icon = Bundle.main.url(forResource: "Buddy", withExtension: "icns") {
            NSApp.applicationIconImage = NSImage(contentsOf: icon)
        }
        makeMenus()
        conversations.agentPermission = { [weak self] workspace, keys in
            guard let self, let state = try? self.workspaceState(), state["conversationWorkspace"] as? String == workspace,
                  let agents = state["agents"] as? [[String: Any]], !keys.isEmpty else { return false }
            let registered = Set(agents.compactMap { $0["id"] as? String }.map { workspace + ":" + $0 })
            return keys.allSatisfy { registered.contains($0) }
        }
        conversations.filePermission = { [weak self] workspace, keys in
            guard let self, let state = try? self.workspaceState(), state["conversationWorkspace"] as? String == workspace, let agents = state["agents"] as? [[String: Any]], !keys.isEmpty else { return false }
            return keys.allSatisfy { key in
                guard let agent = agents.first(where: { workspace + ":" + ($0["id"] as? String ?? "") == key }) else { return false }
                return (agent["tools"] as? [String: Bool])?["projectFiles"] != false
            }
        }
        conversations.computerPermission = { [weak self] workspace, keys in
            guard let self,!FileManager.default.fileExists(atPath:self.supportURL.appendingPathComponent("Worker/PrivateSignIn.json").path) else{return false}
            guard let state = try? self.workspaceState(), state["conversationWorkspace"] as? String == workspace, let agents = state["agents"] as? [[String: Any]], !keys.isEmpty else { return false }
            return keys.allSatisfy { key in
                guard let agent = agents.first(where: { workspace + ":" + ($0["id"] as? String ?? "") == key }) else { return false }
                return (agent["tools"] as? [String: Bool])?["desktop"] != false
            }
        }
        conversations.extraToolHandler = { [weak self] tool, args, context in
            guard let self, ["buddy_start_background_task","buddy_manage_routine","buddy_coding_session"].contains(tool), let id = context["agentId"] as? String else { throw BuddyWorkerFailure(message: "Background work is unavailable for this turn.") }
            let workspace = try self.workspaceContext()
            guard workspace.agents.contains(id) else { throw BuddyWorkerFailure(message: "This agent is no longer available.") }
            _ = try await BuddyWorkerClient.start(support: self.supportURL, workspace: workspace.workspace)
            if tool=="buddy_coding_session" {
                return try await BuddyWorkerClient.call(support:self.supportURL,payload:["operation":"coding","workspace":workspace.workspace,"agentId":id,"requestId":(context["runId"] as? String ?? "")+":"+(context["callId"] as? String ?? ""),"arguments":args])
            }
            if tool=="buddy_manage_routine" {
                let result=try await BuddyWorkerClient.call(support:self.supportURL,payload:["operation":"routine","workspace":workspace.workspace,"agentId":id,"requestId":(context["runId"] as? String ?? "")+":"+(context["callId"] as? String ?? ""),"arguments":args])
                if let value=result["routine"] { self.deliver(["type":"routine","runId":context["runId"] ?? "","routine":value]) }
                return result
            }
            let choice = try self.ai.settings.current(workspace.workspace)
            return try await BuddyWorkerClient.call(support: self.supportURL, payload: ["operation": "create", "workspace": workspace.workspace, "agentId": id, "requestId": (context["runId"] as? String ?? "") + ":" + (context["callId"] as? String ?? ""), "title": args["title"] ?? "", "goal": args["goal"] ?? "", "kind": args["kind"] ?? "general", "budgetUSD": choice.claudeBudgetUSD])
        }
        teamwork.onEvent = { [weak self] event in self?.deliver(event) }
        ai.onEvent = { [weak self] event in
            guard let self else { return }
            if event["type"] as? String == "connection" {
                Task { if let workspace = try? self.workspaceContext().workspace, let status = try? await self.ai.status(workspace: workspace) { self.deliver(status.merging(["type": "connection"]) { _, new in new }) } }; return
            }
            if event["type"] as? String == "tool-input" { _ = self.teamwork.consume(event); self.deliver(event); return }
            if event["type"] as? String == "proposal" { self.deliver(event); return }
            if !self.teamwork.consume(event) { self.deliver(event) }
        }
        showWindow()
    }

    private func showWindow() {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 780), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Buddy"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(calibratedWhite: 0.985, alpha: 1)
        window.minSize = NSSize(width: 760, height: 660)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        window.setFrameAutosaveName("BuddyMainWindow")
        if !window.setFrameUsingName("BuddyMainWindow") { window.center() }
        self.window = window

        let controller = WKUserContentController()
        controller.addScriptMessageHandler(self, contentWorld: .page, name: "buddy")
        installBridge(on: controller)
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.autoresizingMask = [.width, .height]
        window.contentView = webView
        self.webView = webView
        guard let resources = Bundle.main.resourceURL?.appendingPathComponent("Web", isDirectory: true) else { showFailure("Buddy’s interface is missing."); return }
        let entry = resources.appendingPathComponent("index.html")
        guard FileManager.default.fileExists(atPath: entry.path) else { showFailure("Buddy’s interface is missing. Rebuild the app and try again."); return }
        webView.loadFileURL(entry, allowingReadAccessTo: resources)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func installBridge(on controller: WKUserContentController) {
        controller.removeAllUserScripts()
        let savedState = (try? String(contentsOf: stateURL, encoding: .utf8))
        let stateLiteral = savedState.flatMap { try? JSONSerialization.data(withJSONObject: [$0]) }.flatMap { String(data: $0, encoding: .utf8) } ?? "[null]"
        let bridge = """
        window.BuddyDesktop = Object.freeze({
          agentModels: payload => window.webkit.messageHandlers.buddy.postMessage({kind: 'agentModels', payload}),
          providerSettings: payload => window.webkit.messageHandlers.buddy.postMessage({kind: 'providerSettings', payload}),
          worker: payload => window.webkit.messageHandlers.buddy.postMessage({kind: 'worker', payload}),
          initialState: \(stateLiteral)[0],
          saveState: value => window.webkit.messageHandlers.buddy.postMessage({kind: 'saveState', value}),
          exportFile: (name, content) => window.webkit.messageHandlers.buddy.postMessage({kind: 'exportFile', name, content}),
          connectionStatus: () => window.webkit.messageHandlers.buddy.postMessage({kind: 'connectionStatus'}),
          signIn: () => window.webkit.messageHandlers.buddy.postMessage({kind: 'signIn'}),
          sendMessage: payload => window.webkit.messageHandlers.buddy.postMessage({kind: 'sendMessage', payload}),
          stopMessage: runId => window.webkit.messageHandlers.buddy.postMessage({kind: 'stopMessage', runId}),
          activeRuns: () => window.webkit.messageHandlers.buddy.postMessage({kind: 'activeRuns'}),
          toolInputs: () => window.webkit.messageHandlers.buddy.postMessage({kind: 'toolInputs'}),
          answerToolInput: payload => window.webkit.messageHandlers.buddy.postMessage({kind: 'answerToolInput', payload}),
          agentProposals: () => window.webkit.messageHandlers.buddy.postMessage({kind: 'agentProposals'}),
          reviewAgentProposal: payload => window.webkit.messageHandlers.buddy.postMessage({kind: 'reviewAgentProposal', payload}),
          connections: refresh => window.webkit.messageHandlers.buddy.postMessage({kind: 'connections', refresh: !!refresh}),
          setConnectionAccess: payload => window.webkit.messageHandlers.buddy.postMessage({kind: 'setConnectionAccess', payload}),
          projectFiles: folderId => window.webkit.messageHandlers.buddy.postMessage({kind: 'projectFiles', folderId: folderId || null}),
          fullProjectPreview: payload => window.webkit.messageHandlers.buddy.postMessage({kind: 'fullProjectPreview', payload}),
          previewProjectFile: payload => window.webkit.messageHandlers.buddy.postMessage({kind: 'previewProjectFile', payload}),
          editProjectDocument: payload => window.webkit.messageHandlers.buddy.postMessage({kind: 'editProjectDocument', payload}),
          createProjectDocument: payload => window.webkit.messageHandlers.buddy.postMessage({kind: 'createProjectDocument', payload}),
          revealProjectFile: payload => window.webkit.messageHandlers.buddy.postMessage({kind: 'revealProjectFile', payload}),
          readProjectFile: payload => window.webkit.messageHandlers.buddy.postMessage({kind: 'readProjectFile', payload}),
          writeProjectFile: payload => window.webkit.messageHandlers.buddy.postMessage({kind: 'writeProjectFile', payload}),
          projectVersions: payload => window.webkit.messageHandlers.buddy.postMessage({kind: 'projectVersions', payload}),
          restoreProjectFile: payload => window.webkit.messageHandlers.buddy.postMessage({kind: 'restoreProjectFile', payload}),
          chooseProjectFolder: () => window.webkit.messageHandlers.buddy.postMessage({kind: 'chooseProjectFolder'}),
          addProjectFolder: () => window.webkit.messageHandlers.buddy.postMessage({kind: 'addProjectFolder'}),
          disconnectProjectFolder: folderId => window.webkit.messageHandlers.buddy.postMessage({kind: 'disconnectProjectFolder', folderId}),
          showProjectFolder: folderId => window.webkit.messageHandlers.buddy.postMessage({kind: 'showProjectFolder', folderId: folderId || null}),
          computerStatus: () => window.webkit.messageHandlers.buddy.postMessage({kind: 'computerStatus'}),
          setComputerAccess: enabled => window.webkit.messageHandlers.buddy.postMessage({kind: 'setComputerAccess', enabled}),
          openChatGPT: () => window.webkit.messageHandlers.buddy.postMessage({kind: 'openChatGPT'})
        });
        """
        controller.addUserScript(WKUserScript(source: bridge, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { teamwork.shutdown(); ai.shutdown() }
    private func deliver(_ event: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: event), let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("window.dispatchEvent(new CustomEvent('buddy-conversation', {detail: \(json)}))", completionHandler: nil)
    }

    private func makeMenus() {
        let menu = NSMenu()
        let appMenu = NSMenu(title: "Buddy")
        appMenu.addItem(item("About Buddy", #selector(about), ""))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Settings…", #selector(settings), ","))
        appMenu.addItem(.separator())
        let services = NSMenu(title: "Services")
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        appMenu.addItem(servicesItem)
        NSApp.servicesMenu = services
        appMenu.addItem(NSMenuItem(title: "Hide Buddy", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        let hideOthers = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(NSMenuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit Buddy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        append(appMenu, to: menu)

        let file = NSMenu(title: "File")
        file.addItem(item("New Chat…", #selector(newChat), "n"))
        file.addItem(.separator())
        file.addItem(NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        append(file, to: menu)

        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        for (title, action, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(NSMenuItem(title: title, action: Selector(action), keyEquivalent: key))
        }
        edit.addItem(.separator())
        edit.addItem(item("Find in Buddy…", #selector(find), "k"))
        append(edit, to: menu)

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        windowMenu.addItem(.separator())
        windowMenu.addItem(NSMenuItem(title: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""))
        append(windowMenu, to: menu)
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = menu
    }

    private func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }
    private func append(_ submenu: NSMenu, to parent: NSMenu) {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        parent.addItem(item)
    }
    private func command(_ action: String) {
        showWindow()
        webView?.evaluateJavaScript("document.querySelector('[data-action=\"\(action)\"]')?.click()", completionHandler: nil)
    }
    @objc private func newChat() { command("new-chat") }
    @objc private func settings() { command("settings") }
    @objc private func find() { showWindow(); webView?.evaluateJavaScript("typeof searchModal === 'function' && searchModal()", completionHandler: nil) }
    @objc private func about() {
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Buddy", .applicationVersion: "0.18.0", .credits: NSAttributedString(string: "Your personal team, one conversation away.\n\nConversations powered by ChatGPT or Claude.")])
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        guard message.frameInfo.isMainFrame, let url = message.frameInfo.request.url, url.isFileURL,
              url.standardizedFileURL.path == Bundle.main.resourceURL?.appendingPathComponent("Web/index.html").standardizedFileURL.path,
              let body = message.body as? [String: Any], let kind = body["kind"] as? String else { replyHandler(nil, "Unsupported request."); return }
        switch kind {
        case "agentModels":
            Task {do {let context=try workspaceContext();let payload=body["payload"] as? [String:Any] ?? [:];replyHandler(try await ai.modelSettings(workspace:context.workspace,agents:context.agents,payload:payload),nil)}catch{replyHandler(nil,error.localizedDescription)}}
        case "providerSettings":
            Task { do { let workspace = try workspaceContext().workspace; replyHandler(try await providerRequest(body["payload"] as? [String: Any] ?? [:], workspace: workspace), nil) } catch { replyHandler(nil, error.localizedDescription) } }
        case "worker":
            do {
                let context = try workspaceContext(); var payload = body["payload"] as? [String: Any] ?? [:]; payload["workspace"] = context.workspace
                if ["connectClaude", "disconnectClaude"].contains(payload["operation"] as? String ?? "") {
                    Task { do { let result = try await providerRequest(["operation": payload["operation"] as? String == "connectClaude" ? "connect" : "disconnect", "provider": "claude"], workspace: context.workspace); replyHandler(["connected": (result["claude"] as? [String: Any])?["connected"] ?? false], nil) } catch { replyHandler(nil, error.localizedDescription) } }; return
                }
                Task { do {
                    if payload["operation"] as? String == "start" { replyHandler(try await BuddyWorkerClient.start(support: supportURL, workspace: context.workspace), nil) }
                    else { replyHandler(try await BuddyWorkerClient.call(support: supportURL, payload: payload), nil) }
                } catch { replyHandler(nil, error.localizedDescription) } }
            } catch { replyHandler(nil, error.localizedDescription) }
        case "connectionStatus":
            Task { do { let workspace = try workspaceContext().workspace; replyHandler(try await ai.status(workspace: workspace), nil) } catch { replyHandler(nil, error.localizedDescription) } }
        case "computerStatus":
            Task { do { replyHandler(try await conversations.computerStatus(), nil) } catch { replyHandler(nil, error.localizedDescription) } }
        case "setComputerAccess":
            guard let enabled = body["enabled"] as? Bool else { replyHandler(nil, "Choose whether to connect this Mac."); return }
            Task { do { replyHandler(try await conversations.setComputerAccess(enabled), nil) } catch { replyHandler(nil, error.localizedDescription) } }
        case "signIn":
            Task { do { let workspace = try workspaceContext().workspace; replyHandler(try await providerRequest(["operation": "connect", "provider": "chatgpt"], workspace: workspace), nil) } catch { replyHandler(nil, error.localizedDescription) } }
        case "sendMessage":
            guard let payload = body["payload"] as? [String: Any] else { replyHandler(nil, "Invalid message."); return }
            do {
                if payload["kind"] as? String == "group" {
                    guard let data = try? Data(contentsOf: stateURL), let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw BuddyFailure(message: "Buddy couldn’t load this group. Reopen the app and try again.") }
                    var request = try BuddyTeamRequest.from(workspace: state, payload: payload)
                    request.fileScope = try conversations.projectFiles.scope(request.workspace)
                    replyHandler(try teamwork.send(request), nil)
                    return
                }
                let context = try workspaceContext()
                guard let agent = payload["agentId"] as? String, context.agents.contains(agent), payload["key"] as? String == context.workspace + ":" + agent else { throw BuddyFailure(message: "This agent is no longer in the workspace. Reopen the chat.") }
                var options = BuddyTurnOptions()
                options.fileScope = try conversations.projectFiles.scope(context.workspace)
                options.actorId = agent
                options.extraTools = BuddyWorkerClient.tools
                options.requiresRoutine = BuddyWorkerClient.recurringRequest(payload["text"] as? String ?? "")
                options.instructions = "For explicit coding/build/test requests or requests to use Claude Code, call buddy_coding_session directly with a complete task brief; it is a native worker tool, not a connected service. Check status for real results. For an explicit recurring request (run this every morning/daily/weekly), call buddy_manage_routine now. Carry the relevant user brief from history into the goal. For email, choose a targeted search with follow-ups and an explicit lookback window. Default to 09:00 local for an unspecified morning, state that assumption and the saved next run. Do not create a one-off task instead. Never claim scheduled without saved=true and a routine ID. Do not schedule hypothetical examples or questions. Use list/update/pause/resume/delete for existing routines. Results and controls are in Background work. This Mac must be awake and online; a missed run catches up once. If the user explicitly asks you to run a task in the background, use buddy_start_background_task. Pass the full authorized brief and the facts needed to execute it; the worker has separate conversation context. It uses this agent’s saved provider and model, its configured spending limit, and current agent permissions, private browser/files, and native human action reviews. Report the returned task title and tell the user results and reviews are in Background work. Don't create background work for ordinary questions, invent tasks, or claim it has finished when only queued."
                options.proposalScope = BuddyProposalScope(workspace: context.workspace, chat: agent, actorId: agent, replyRunId: payload["runId"] as? String ?? "")
                try ai.ensureAgentDefaults(workspace:context.workspace,agents:context.agents)
                options.historyScope=BuddyHistoryScope(workspace:context.workspace,agent:agent)
                options.history = BuddyConversationHistory.context(try workspaceState(), target: agent, runId: payload["runId"] as? String ?? "")
                replyHandler(try ai.send(payload, options: options), nil)
            } catch { replyHandler(nil, error.localizedDescription) }
        case "stopMessage":
            guard let runID = body["runId"] as? String else { replyHandler(nil, "Invalid reply."); return }
            Task { do { replyHandler(try await (teamwork.contains(runID) ? teamwork.stop(runID) : ai.stop(runID)), nil) } catch { replyHandler(nil, error.localizedDescription) } }
        case "activeRuns": replyHandler(ai.snapshots() + teamwork.snapshots(), nil)
        case "toolInputs":
            do { let context = try workspaceContext(); replyHandler(["requests": ai.pendingInputs(workspace: context.workspace)], nil) }
            catch { replyHandler(nil, error.localizedDescription) }
        case "answerToolInput":
            do {
                let context = try workspaceContext()
                guard let payload = body["payload"] as? [String: Any] else { throw BuddyFailure(message: "Review this action first.") }
                replyHandler(try ai.answerInput(workspace: context.workspace, payload: payload), nil)
            } catch { replyHandler(nil, error.localizedDescription) }
        case "agentProposals":
            do { let context = try workspaceContext(); replyHandler(["proposals": try conversations.agentProposals.list(context.workspace)], nil) }
            catch { replyHandler(nil, error.localizedDescription) }
        case "reviewAgentProposal":
            do {
                let context = try workspaceContext()
                guard let payload = body["payload"] as? [String: Any] else { throw BuddyProposalFailure(message: "Review this suggestion first.") }
                replyHandler(try conversations.agentProposals.review(context.workspace, payload: payload), nil)
            } catch { replyHandler(nil, error.localizedDescription) }
        case "connections":
            Task { do {
                let context = try workspaceContext()
                replyHandler(try await conversations.connectionCatalog(workspace: context.workspace, agents: context.agents, refresh: body["refresh"] as? Bool == true), nil)
            } catch { replyHandler(nil, error.localizedDescription) } }
        case "setConnectionAccess":
            Task { do {
                let context = try workspaceContext()
                guard let payload = body["payload"] as? [String: Any], let agent = payload["agentId"] as? String, context.agents.contains(agent), let id = payload["connectionId"] as? String, id.count <= 200, let allowed = payload["allowed"] as? Bool else { throw BuddyFailure(message: "Check the connection and agent, then try again.") }
                let key = context.workspace + ":" + agent
                await teamwork.stopForAgent(key)
                replyHandler(try await conversations.setConnectionAccess(key: key, connection: id, allowed: allowed), nil)
            } catch { replyHandler(nil, error.localizedDescription) } }
        case "projectFiles":
            do { let context = try workspaceContext(); let scope = try (body["folderId"] as? String).map { BuddyFileScope(workspace: context.workspace, folderId: $0) } ?? conversations.projectFiles.scope(context.workspace); replyHandler(try conversations.projectFiles.list(scope), nil) }
            catch { replyHandler(nil, error.localizedDescription) }
        case "readProjectFile", "fullProjectPreview", "previewProjectFile", "createProjectDocument", "editProjectDocument", "revealProjectFile", "writeProjectFile", "projectVersions", "restoreProjectFile":
            do {
                let context = try workspaceContext()
                guard let payload = body["payload"] as? [String: Any], let folderId = payload["folderId"] as? String, let path = payload["path"] as? String else { throw BuddyFailure(message: "Refresh Files and try again.") }
                let scope = BuddyFileScope(workspace: context.workspace, folderId: folderId)
                if kind == "fullProjectPreview" { try filePreviews.open(data:conversations.projectFiles.readBytes(scope,path:path),name:path);replyHandler(["previewed":true],nil) }
                else if kind == "previewProjectFile" { replyHandler(try conversations.projectFiles.preview(scope,path:path,page:payload["page"] as? Int ?? 1),nil) }
                else if kind == "revealProjectFile" { _ = try conversations.projectFiles.readBytes(scope,path:path); let url=try conversations.projectFiles.location(scope).appendingPathComponent(path); NSWorkspace.shared.activateFileViewerSelecting([url]);replyHandler(["revealed":true],nil) }
                else if kind == "createProjectDocument" { guard let spec=payload["specification"] as? [String:Any] else { throw BuddyFailure(message:"Enter document contents.") }; replyHandler(try conversations.projectFiles.document(scope,path:path,expectedVersion:"",specification:spec,operations:nil,actor:"you",actorName:"You"),nil);deliver(["type":"project-files-changed"]) }
                else if kind == "editProjectDocument" { guard let edits=payload["operations"] as? [[String:Any]],let version=payload["expectedVersion"] as? String else { throw BuddyFailure(message:"Read the latest document before editing.") };replyHandler(try conversations.projectFiles.document(scope,path:path,expectedVersion:version,specification:nil,operations:edits,actor:"you",actorName:"You"),nil);deliver(["type":"project-files-changed"]) }
                else if kind == "readProjectFile" { replyHandler(try conversations.projectFiles.read(scope, path: path), nil) }
                else if kind == "projectVersions" { replyHandler(try conversations.projectFiles.versions(scope, path: path), nil) }
                else {
                    guard let version = payload["expectedVersion"] as? String else { throw BuddyFailure(message: "Read the latest file before saving.") }
                    if kind == "restoreProjectFile" {
                        guard let receipt = payload["receiptId"] as? String else { throw BuddyFailure(message: "Choose an earlier edit to restore.") }
                        replyHandler(try conversations.projectFiles.restore(scope, path: path, receiptId: receipt, expectedVersion: version), nil)
                    } else {
                        guard let text = payload["content"] as? String else { throw BuddyFailure(message: "Enter the file contents.") }
                        replyHandler(try conversations.projectFiles.write(scope, path: path, content: text, expectedVersion: version, actor: "you", actorName: "You"), nil)
                    }
                    deliver(["type": "project-files-changed"])
                }
            } catch { replyHandler(nil, error.localizedDescription) }
        case "chooseProjectFolder", "addProjectFolder":
            guard let window else { replyHandler(nil, "Buddy’s window is unavailable."); return }
            let panel = NSOpenPanel()
            panel.title = kind == "addProjectFolder" ? "Connect a folder to Buddy" : "Choose Buddy’s shared folder"; panel.prompt = "Connect folder"
            panel.message = "Your agents can read, create, and edit documents and files here. File access is on by default and can be removed in each agent’s settings."
            panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
            panel.beginSheetModal(for: window) { result in
                guard result == .OK, let url = panel.url else { replyHandler(["cancelled": true], nil); return }
                Task { do {
                    let context = try self.workspaceContext()
                    let selected = kind == "addProjectFolder" ? try self.conversations.projectFiles.addFolder(context.workspace, to: url) : try self.conversations.projectFiles.connect(context.workspace, to: url)
                    await self.teamwork.stopFiles(workspace: context.workspace); await self.ai.stopFiles(workspace: context.workspace)
                    guard let id = selected["folderId"] as? String else { throw BuddyFailure(message: "Reopen Files to see the connected folder.") }
                    replyHandler(try self.conversations.projectFiles.list(BuddyFileScope(workspace: context.workspace, folderId: id)), nil)
                    self.deliver(["type": "project-files-changed"])
                } catch { replyHandler(nil, error.localizedDescription) } }
            }
        case "disconnectProjectFolder":
            Task { do {
                let context = try workspaceContext()
                guard let id = body["folderId"] as? String else { throw BuddyFailure(message: "Choose the folder to disconnect.") }
                try conversations.projectFiles.removeFolder(context.workspace, folderId: id)
                await teamwork.stopFiles(workspace: context.workspace); await ai.stopFiles(workspace: context.workspace)
                replyHandler(["disconnected": true], nil)
                deliver(["type": "project-files-changed"])
            } catch { replyHandler(nil, error.localizedDescription) } }
        case "showProjectFolder":
            do { let context = try workspaceContext(); let scope = try (body["folderId"] as? String).map { BuddyFileScope(workspace: context.workspace, folderId: $0) } ?? conversations.projectFiles.scope(context.workspace); NSWorkspace.shared.open(try conversations.projectFiles.location(scope)); replyHandler(["opened": true], nil) }
            catch { replyHandler(nil, error.localizedDescription) }
        case "openChatGPT":
            NSWorkspace.shared.open(URL(string: "https://chatgpt.com")!)
            replyHandler(["opened": true], nil)
        case "saveState":
            guard let value = body["value"] as? String, let data = value.data(using: .utf8), data.count < 50_000_000,
                  let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any], state["agents"] is [Any], state["version"] as? Int == 1 else { replyHandler(nil, "Invalid workspace."); return }
            do {
                try FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)
                let previous = try? workspaceState()
                let protected = try conversations.agentProposals.preserveApprovals(in: state, previous: previous)
                if let workspace=protected["conversationWorkspace"] as? String,let agents=protected["agents"] as? [[String:Any]] {try ai.ensureAgentDefaults(workspace:workspace,agents:agents.compactMap{$0["id"] as? String})}
                try JSONSerialization.data(withJSONObject: protected).write(to: stateURL, options: .atomic)
                if let workspace = state["conversationWorkspace"] as? String, let agents = state["agents"] as? [[String: Any]], let oldAgents = previous?["agents"] as? [[String: Any]] {
                    for agent in agents where (agent["tools"] as? [String: Bool])?["projectFiles"] == false || (agent["tools"] as? [String: Bool])?["desktop"] == false {
                        guard let id = agent["id"] as? String, let old = oldAgents.first(where: { $0["id"] as? String == id }), ((agent["tools"] as? [String: Bool])?["projectFiles"] == false && (old["tools"] as? [String: Bool])?["projectFiles"] != false) || ((agent["tools"] as? [String: Bool])?["desktop"] == false && (old["tools"] as? [String: Bool])?["desktop"] != false) else { continue }
                        Task { await self.teamwork.stopForAgent(workspace + ":" + id); await self.ai.stopForAgent(workspace + ":" + id) }
                    }
                }
                replyHandler(["saved": true], nil)
            } catch { replyHandler(nil, "Buddy couldn’t save your workspace. Your current changes are still on screen.") }
        case "exportFile":
            guard let name = body["name"] as? String, let content = body["content"] as? String, let window else { replyHandler(nil, "File unavailable."); return }
            let panel = NSSavePanel()
            panel.title = "Save from Buddy"
            panel.nameFieldStringValue = URL(fileURLWithPath: name).lastPathComponent
            panel.canCreateDirectories = true
            panel.beginSheetModal(for: window) { result in
                guard result == .OK, let url = panel.url else { replyHandler(["saved": false], nil); return }
                do { try content.write(to: url, atomically: true, encoding: .utf8); replyHandler(["saved": true], nil) }
                catch { replyHandler(nil, "Buddy couldn’t save this file. Try another folder.") }
            }
        default: replyHandler(nil, "Unsupported request.")
        }
    }

    private func providerRequest(_ payload: [String: Any], workspace: String) async throws -> [String: Any] {
        try ai.ensureAgentDefaults(workspace:workspace)
        let operation = payload["operation"] as? String ?? "status", provider = payload["provider"] as? String ?? "chatgpt"
        var status: [String: Any]
        if operation == "status" { return try await ai.status(workspace: workspace) }
        if operation == "select" { status = try await ai.select(workspace: workspace, provider: provider, budget: payload["claudeBudgetUSD"] as? Double) }
        else if operation == "disconnect" { status = try await ai.disconnect(workspace: workspace, provider: provider) }
        else if ["connect", "reconnect"].contains(operation) {
            guard ["chatgpt", "claude"].contains(provider) else { throw BuddyFailure(message: "Choose ChatGPT or Claude.") }
            if provider == "claude" {
                let connected = try BuddyWorkerClient.connectClaude(workspace: workspace)
                if connected["cancelled"] as? Bool == true { return try await ai.status(workspace: workspace).merging(["cancelled": true]) { _, new in new } }
                status = try await ai.didConnectClaude(workspace: workspace)
            } else {
                let result = try await ai.connectChatGPT(workspace: workspace)
                status = result["status"] as? [String: Any] ?? [:]
                if let login = result["login"] as? [String: Any] {
                    guard let value = login["authUrl"] as? String, let url = URL(string: value), url.scheme == "https", ["auth.openai.com", "chatgpt.com"].contains(url.host ?? "") else { throw BuddyFailure(message: "ChatGPT didn’t provide a valid sign-in page. Try again.") }
                    NSWorkspace.shared.open(url); status["started"] = true
                }
            }
        } else { throw BuddyFailure(message: "Unsupported provider setting.") }
        deliver(status.merging(["type": "connection"]) { _, new in new }); return status
    }

    private func workspaceState() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: stateURL), let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw BuddyFailure(message: "Buddy couldn’t read this workspace. Reopen the app.") }
        return state
    }
    private func workspaceContext() throws -> (workspace: String, agents: [String]) {
        guard let data = try? Data(contentsOf: stateURL), let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let workspace = state["conversationWorkspace"] as? String, UUID(uuidString: workspace) != nil, let agents = state["agents"] as? [[String: Any]] else { throw BuddyFailure(message: "Buddy couldn’t load this workspace. Reopen the app and try again.") }
        return (workspace, agents.compactMap { $0["id"] as? String })
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Attach to Buddy"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        guard let window else { completionHandler(nil); return }
        panel.beginSheetModal(for: window) { result in completionHandler(result == .OK ? panel.urls : nil) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if navigationAction.targetFrame?.isMainFrame == false, url.absoluteString == "about:srcdoc" { decisionHandler(.allow); return }
        if url.isFileURL, let root = Bundle.main.resourceURL?.appendingPathComponent("Web").standardizedFileURL.path,
           url.standardizedFileURL.path.hasPrefix(root + "/") { decisionHandler(.allow); return }
        if navigationAction.navigationType == .linkActivated, ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { showFailure("Buddy couldn’t open its interface. Quit and reopen the app to try again.") }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        installBridge(on: webView.configuration.userContentController)
        webView.reload()
    }
    private func showFailure(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Buddy couldn’t open"
        alert.informativeText = message
        alert.addButton(withTitle: "Quit Buddy")
        alert.runModal()
        NSApp.terminate(nil)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    if CommandLine.arguments.contains("--worker") {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Buddy", isDirectory: true)
        let delegate = BuddyWorkerHost(support: support)
        app.setActivationPolicy(.prohibited); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    } else {
        let delegate = BuddyApp(); app.setActivationPolicy(.regular); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
