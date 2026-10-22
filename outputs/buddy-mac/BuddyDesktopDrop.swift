import AppKit
@preconcurrency import WebKit

/// Buddy's desktop drop: while Buddy is in the background, an agent that finishes or needs the person appears at the top-left of the screen
/// the person is working on, in a holder drawn by Buddy's own page (Web/buddy-drop.html). A click brings Buddy to the front on that chat.
///
/// The panel is transparent, borderless and non-activating, above other apps' windows, on every Space and beside full-screen apps. It never
/// becomes key or main, so it never takes focus from the app the person is in, and it stays out of the window cycle, Mission Control and
/// Buddy's Window menu. It ignores the mouse except while the pointer is over a holder or its visible label: a light timer reads the pointer's
/// position (no Accessibility permission is needed for that) and lets the panel take the mouse only there, so every other click goes to the
/// app underneath. The page never receives mouse events itself: the panel's own view takes the click and tells the page.
enum BuddyDrop {
    /// Room for four holders 92pt apart from y 76, their pulse rings and shadows, and a label beside each.
    static let panelSize = NSSize(width: 400, height: 440)
    static let kinds: Set<String> = ["done", "needs"]
    static let shapes: Set<String> = ["diamond", "sphere", "hex", "pill"]
    static let colors: Set<String> = ["lilac", "blue", "peach", "mint", "red", "gold", "cobalt"]

    /// One drop as the page asked for it, checked: an agent of this workspace, a chat of this workspace, and plain short text.
    struct Item: Equatable { let eventId, agentId, kind, text, chat, name, shape, color: String }

    /// A drop is asked for only by Buddy's own main web view, from its main frame, on Buddy's own page.
    static func accepts(sender: AnyObject?, main: AnyObject?, isMainFrame: Bool, page: URL?, entry: URL?) -> Bool {
        guard let sender, let main, sender === main, isMainFrame, let page, page.isFileURL, let entry else { return false }
        return page.standardizedFileURL.path == entry.standardizedFileURL.path
    }
    static func item(_ payload: Any?, agents: Set<String>, chats: Set<String>) -> Item? {
        guard let p = payload as? [String: Any], let event = p["eventId"] as? String, !event.isEmpty, event.count <= 200,
              let agent = p["agentId"] as? String, agents.contains(agent), let chat = p["chat"] as? String, chats.contains(chat),
              let kind = p["kind"] as? String, kinds.contains(kind) else { return nil }
        let shape = p["shape"] as? String ?? "", color = p["color"] as? String ?? "", name = plain(p["name"], 60)
        return Item(eventId: event, agentId: agent, kind: kind, text: plain(p["text"], 80), chat: chat, name: name.isEmpty ? "Buddy" : name,
                    shape: shapes.contains(shape) ? shape : "diamond", color: colors.contains(color) ? color : "lilac")
    }
    /// One line of text: control characters and runs of spaces become one space, and it is shortened with an ellipsis.
    static func plain(_ value: Any?, _ limit: Int) -> String {
        guard let text = value as? String else { return "" }
        let flat = String(String.UnicodeScalarView(text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : $0 }))
        let line = flat.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.count > limit ? String(line.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…" : line
    }
    /// The panel sits at the top-left of the screen's visible frame: below the menu bar, beside a Dock on the left.
    static func panelFrame(visible: NSRect) -> NSRect {
        let height = min(panelSize.height, visible.height), width = min(panelSize.width, visible.width)
        return NSRect(x: visible.minX, y: visible.maxY - height, width: width, height: height)
    }
    /// The events already shown, so one event never shows twice even if the page asks again (after a reload, say). The oldest are forgotten.
    struct Seen {
        private var order: [String] = [], ids = Set<String>()
        let limit: Int
        init(limit: Int = 300) { self.limit = limit }
        mutating func first(_ id: String) -> Bool {
            guard ids.insert(id).inserted else { return false }
            order.append(id)
            if order.count > limit { ids.remove(order.removeFirst()) }
            return true
        }
    }
    /// The pointer's position on screen (origin bottom-left) in the page's coordinates (origin at the panel's top-left).
    static func pagePoint(screen: NSPoint, panel: NSRect) -> NSPoint { NSPoint(x: screen.x - panel.minX, y: panel.maxY - screen.y) }

    /// Where the panel takes the mouse, as the page reports it: each landed holder (a circle) and each visible label.
    struct Region: Equatable {
        let id: String, rect: NSRect, round: Bool
        func contains(_ point: NSPoint) -> Bool {
            guard rect.contains(point) else { return false }
            guard round else { return true }
            let dx = (point.x - rect.midX) / (rect.width / 2), dy = (point.y - rect.midY) / (rect.height / 2)
            return dx * dx + dy * dy <= 1
        }
    }
    static func regions(_ value: Any?) -> [Region] {
        guard let list = value as? [[String: Any]] else { return [] }
        let bounds = NSRect(origin: .zero, size: panelSize).insetBy(dx: -1, dy: -1)
        return list.prefix(16).compactMap { r in
            guard let id = r["id"] as? String, !id.isEmpty, id.count <= 200, let x = r["x"] as? NSNumber, let y = r["y"] as? NSNumber,
                  let w = r["w"] as? NSNumber, let h = r["h"] as? NSNumber else { return nil }
            let rect = NSRect(x: x.doubleValue, y: y.doubleValue, width: w.doubleValue, height: h.doubleValue)
            guard [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite), rect.width > 0, rect.height > 0, bounds.contains(rect) else { return nil }
            return Region(id: id, rect: rect, round: r["round"] as? Bool == true)
        }
    }
}

final class BuddyDropPanel: NSPanel {
    convenience init(frame: NSRect) {
        self.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        becomesKeyOnlyIfNeeded = true
        isMovable = false
        animationBehavior = .none
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The panel's content: it takes a click only on a holder or a visible label (in the page's coordinates, origin top-left), and never passes
/// one to the web view under it.
final class BuddyDropHitView: NSView {
    var regions: [BuddyDrop.Region] = []
    var onClick: ((String) -> Void)?
    override var isFlipped: Bool { true }
    func region(at point: NSPoint) -> String? { regions.last { $0.contains(point) }?.id }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        return region(at: local) == nil ? nil : self
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        if let id = region(at: convert(event.locationInWindow, from: nil)) { onClick?(id) }
    }
}

/// The page's messages reach the drop without the web view's controller keeping the drop alive.
private final class BuddyDropMessages: NSObject, WKScriptMessageHandler {
    weak var target: BuddyDesktopDrop?
    init(_ target: BuddyDesktopDrop) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { target?.receive(message) }
    }
}

@MainActor final class BuddyDesktopDrop: NSObject, WKNavigationDelegate {
    /// Opens the chat a clicked holder was for (Buddy's window comes to the front on it).
    var onOpen: ((String) -> Void)?
    private let root: URL?, page: URL?
    private var panel: BuddyDropPanel?, hitView: BuddyDropHitView?, webView: WKWebView?
    private var ready = false, showing = false, generation = 0
    private var queued: [BuddyDrop.Item] = []
    /// Which chat each agent's holder opens. The page's own word for it is never used.
    private var chats: [String: String] = [:]
    private var tracker: Timer?, hovered: String?
    private var seen = BuddyDrop.Seen()
    private var observers: [NSObjectProtocol] = []

    init(web root: URL?) {
        self.root = root
        page = root?.appendingPathComponent("buddy-drop.html")
        super.init()
        let center = NotificationCenter.default
        // The person came back to Buddy (any way at all): what the holders said is in the app now.
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.clear() } })
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.place(keepScreen: true) } })
    }

    /// Shows one drop, unless Buddy is the active app or this event was shown already. The same agent again updates its holder.
    @discardableResult func show(_ item: BuddyDrop.Item) -> Bool {
        guard !NSApp.isActive, seen.first(item.eventId), let panel = ensurePanel() else { return false }
        generation += 1
        chats[item.agentId] = item.chat
        if !showing {
            // A new stack goes on the screen the person is working on; one already showing stays where it is.
            place(keepScreen: false)
            panel.orderFrontRegardless()
            showing = true
            startTracking()
        }
        if ready { send(item) } else { queued.removeAll { $0.agentId == item.agentId }; queued.append(item) }
        return true
    }
    /// Every holder pops; the panel goes away once the page says it is empty (or shortly after, while Buddy is in front).
    func clear() {
        chats = [:]; queued = []
        guard showing else { return }
        call("BuddyDropPage.clear", NSNull())
        let current = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            MainActor.assumeIsolated { if let self, self.generation == current, self.showing, NSApp.isActive { self.hide() } }
        }
    }

    private func ensurePanel() -> BuddyDropPanel? {
        if let panel { return panel }
        guard let root, let page, FileManager.default.fileExists(atPath: page.path) else { return nil }
        let frame = BuddyDrop.panelFrame(visible: Self.currentScreen()?.visibleFrame ?? NSRect(origin: .zero, size: BuddyDrop.panelSize))
        let panel = BuddyDropPanel(frame: frame)
        let hit = BuddyDropHitView(frame: NSRect(origin: .zero, size: frame.size))
        hit.autoresizingMask = [.width, .height]
        hit.onClick = { [weak self] id in self?.clicked(id) }
        let controller = WKUserContentController()
        controller.add(BuddyDropMessages(self), name: "buddyDrop")
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: hit.bounds, configuration: configuration)
        web.autoresizingMask = [.width, .height]
        web.setValue(false, forKey: "drawsBackground")
        web.underPageBackgroundColor = .clear
        web.navigationDelegate = self
        hit.addSubview(web)
        panel.contentView = hit
        web.loadFileURL(page, allowingReadAccessTo: root)
        self.panel = panel; hitView = hit; webView = web
        return panel
    }
    private func send(_ item: BuddyDrop.Item) {
        call("BuddyDropPage.show", ["id": item.agentId, "name": item.name, "kind": item.kind, "text": item.text, "chat": item.chat, "shape": item.shape, "color": item.color,
                                    "reduceMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion])
    }
    private func call(_ function: String, _ argument: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: [argument]), let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("typeof BuddyDropPage!=='undefined'&&\(function)(\(json)[0])", completionHandler: nil)
    }
    private func hide() {
        if hovered != nil { NSCursor.arrow.set() }
        panel?.orderOut(nil)
        panel?.ignoresMouseEvents = true
        showing = false; hovered = nil; chats = [:]; queued = []
        hitView?.regions = []
        tracker?.invalidate(); tracker = nil
    }
    private func place(keepScreen: Bool) {
        guard let panel else { return }
        let screen = keepScreen ? (panel.screen ?? Self.currentScreen()) : Self.currentScreen()
        guard let visible = screen?.visibleFrame else { return }
        let frame = BuddyDrop.panelFrame(visible: visible)
        if panel.frame != frame { panel.setFrame(frame, display: showing) }
    }
    /// The screen with the pointer, else the one with the key window.
    static func currentScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    // MARK: the pointer

    /// While holders are on screen: thirty times a second with the pointer near the panel, ten times a second when it is far away. Cheap, and it
    /// also notices a holder that springs up under a pointer standing still.
    private func startTracking() {
        guard tracker == nil else { return }
        schedule(1.0 / 30.0)
    }
    private func schedule(_ interval: TimeInterval) {
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(timer, forMode: .common)
        tracker = timer
    }
    private func tick() {
        tracker = nil
        guard showing, let panel else { return }
        track()
        schedule(panel.frame.insetBy(dx: -160, dy: -160).contains(NSEvent.mouseLocation) ? 1.0 / 30.0 : 1.0 / 10.0)
    }
    private func track() {
        guard showing, let panel, let hitView else { return }
        let over = hitView.region(at: BuddyDrop.pagePoint(screen: NSEvent.mouseLocation, panel: panel.frame))
        if panel.ignoresMouseEvents != (over == nil) { panel.ignoresMouseEvents = over == nil }
        guard over != hovered else { return }
        hovered = over
        call("BuddyDropPage.hover", over.map { $0 as Any } ?? NSNull())
        (over == nil ? NSCursor.arrow : NSCursor.pointingHand).set()
    }

    /// A click on a holder: Buddy comes to the front on its chat while the click is still being handled (macOS lets an app activate itself
    /// for the person's own click), and the page pops the holder.
    private func clicked(_ id: String) {
        call("BuddyDropPage.click", id)
        guard let chat = chats.removeValue(forKey: id) else { return }
        hovered = nil
        onOpen?(chat)
    }

    // MARK: the page

    fileprivate func receive(_ message: WKScriptMessage) {
        guard let webView, message.webView === webView, message.frameInfo.isMainFrame, let url = message.frameInfo.request.url, url.isFileURL, let page,
              url.standardizedFileURL.path == page.standardizedFileURL.path, let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            ready = true
            let waiting = queued; queued = []
            waiting.forEach(send)
        case "regions":
            hitView?.regions = BuddyDrop.regions(body["rects"])
            track()
        case "open":
            guard let id = body["id"] as? String, let chat = chats.removeValue(forKey: id) else { return }
            hovered = nil
            onOpen?(chat)
        case "empty":
            if showing { hide() }
        default: break
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        decisionHandler(url?.isFileURL == true && url?.standardizedFileURL.path == page?.standardizedFileURL.path ? .allow : .cancel)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // The holders were in the page that stopped: put the panel away and start the page again for the next drop.
        hide(); ready = false
        if let page, let root { webView.loadFileURL(page, allowingReadAccessTo: root) }
    }
}
