// run-tests: BuddyDesktopDrop.swift
import AppKit

/// The desktop drop's panel: a transparent, borderless, non-activating panel above other apps' windows, on every Space and beside full-screen
/// apps, that never takes focus, stays out of the window cycle and Mission Control, and lets every click through except on a holder or its label.
/// The page asks for a drop only from Buddy's own main web view; the payload is checked before anything is drawn.
@main struct DesktopDropChecks {
    static func require(_ value: Bool, _ message: String) { if !value { fputs("FAILED: \(message)\n", stderr); exit(1) } }
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)

        // MARK: the panel
        let visible = NSRect(x: 0, y: 0, width: 1512, height: 944)
        let frame = BuddyDrop.panelFrame(visible: visible)
        require(frame == NSRect(x: 0, y: 944 - BuddyDrop.panelSize.height, width: BuddyDrop.panelSize.width, height: BuddyDrop.panelSize.height), "anchored at the top-left of the visible frame, below the menu bar: \(frame)")
        require(BuddyDrop.panelSize.height >= 76 + 3 * 92 + 34 + 40 && BuddyDrop.panelSize.width >= 340, "room for four holders, their pulse rings and labels: \(BuddyDrop.panelSize)")
        let docked = BuddyDrop.panelFrame(visible: NSRect(x: 64, y: 0, width: 1448, height: 944))
        require(docked.minX == 64 && docked.maxY == 944, "a Dock on the left moves it right: \(docked)")
        let second = BuddyDrop.panelFrame(visible: NSRect(x: -1920, y: 200, width: 1920, height: 300))
        require(second.minX == -1920 && second.maxY == 500 && second.height == 300, "a short screen elsewhere keeps the panel on it: \(second)")

        let panel = BuddyDropPanel(frame: frame)
        require(panel.styleMask == [.borderless, .nonactivatingPanel], "borderless and non-activating: \(panel.styleMask)")
        require(panel.level == .statusBar, "above normal and floating windows: \(panel.level)")
        require(panel.collectionBehavior == [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle], "every Space, beside full-screen apps, left in place by Mission Control, out of the window cycle: \(panel.collectionBehavior)")
        require(panel.ignoresMouseEvents, "click-through by default")
        require(!panel.canBecomeKey && !panel.canBecomeMain, "never takes focus from the app the person is in")
        require(!panel.hasShadow && !panel.isOpaque && panel.backgroundColor.alphaComponent == 0, "transparent, the page draws its own shadow")
        require(!panel.hidesOnDeactivate, "shown while Buddy is in the background")
        require(panel.isExcludedFromWindowsMenu, "not listed in Buddy's Window menu")
        require(!panel.isReleasedWhenClosed && panel.frame == frame, "kept and placed where asked")

        // MARK: what can be clicked
        let regions = BuddyDrop.regions([["id": "atlas", "part": "holder", "x": 12, "y": 38, "w": 76, "h": 76, "round": true],
                                          ["id": "atlas", "part": "label", "x": 96, "y": 48, "w": 160, "h": 56],
                                          ["id": "", "part": "holder", "x": 0, "y": 0, "w": 10, "h": 10],
                                          ["id": "nova", "part": "holder", "x": "12", "y": 130, "w": 76, "h": 76],
                                          ["id": "huge", "part": "holder", "x": 0, "y": 0, "w": 9000, "h": 9000]])
        require(regions.map(\.id) == ["atlas", "atlas"], "only well-formed regions on the panel: \(regions)")
        let hit = BuddyDropHitView(frame: NSRect(origin: .zero, size: frame.size))
        panel.contentView = hit
        hit.regions = regions
        require(hit.region(at: NSPoint(x: 50, y: 76)) == "atlas", "the holder's centre")
        require(hit.region(at: NSPoint(x: 14, y: 40)) == nil, "the holder is round: its bounding box corner is not it")
        require(hit.region(at: NSPoint(x: 120, y: 70)) == "atlas", "the visible label")
        require(hit.region(at: NSPoint(x: 200, y: 300)) == nil, "anywhere else is the app underneath")
        // AppKit asks with the point in the superview's (unflipped) coordinates; the page's coordinates start at the top.
        require(hit.hitTest(NSPoint(x: 50, y: frame.height - 76)) === hit, "a click on the holder lands on the panel")
        require(hit.hitTest(NSPoint(x: 200, y: 40)) == nil, "a click elsewhere never stops at the panel")
        require(hit.acceptsFirstMouse(for: nil), "the first click counts without activating anything")
        require(BuddyDrop.pagePoint(screen: NSPoint(x: frame.minX + 50, y: frame.maxY - 76), panel: frame) == NSPoint(x: 50, y: 76), "mouse position on screen to page coordinates")

        // MARK: who may ask
        let main = NSObject(), dropPage = NSObject()
        let entry = URL(fileURLWithPath: "/Applications/Buddy.app/Contents/Resources/Web/index.html")
        require(BuddyDrop.accepts(sender: main, main: main, isMainFrame: true, page: entry, entry: entry), "Buddy's own window asks")
        require(!BuddyDrop.accepts(sender: dropPage, main: main, isMainFrame: true, page: entry, entry: entry), "another web view (the drop's own page) cannot")
        require(!BuddyDrop.accepts(sender: main, main: main, isMainFrame: false, page: entry, entry: entry), "a frame inside the page cannot")
        require(!BuddyDrop.accepts(sender: main, main: main, isMainFrame: true, page: entry.deletingLastPathComponent().appendingPathComponent("buddy-drop.html"), entry: entry), "another page cannot")
        require(!BuddyDrop.accepts(sender: main, main: main, isMainFrame: true, page: URL(string: "https://example.com/Web/index.html"), entry: entry), "a website cannot")
        require(!BuddyDrop.accepts(sender: nil, main: nil, isMainFrame: true, page: entry, entry: entry), "nothing before Buddy's window exists")
        require(!BuddyDrop.accepts(sender: main, main: main, isMainFrame: true, page: entry, entry: nil), "nothing without Buddy's own page")

        // MARK: what is drawn
        let agents: Set<String> = ["lyra", "chief"], chats: Set<String> = ["lyra", "chief", "team"]
        let good: [String: Any] = ["eventId": "worker-t1-1-completed", "agentId": "lyra", "kind": "done", "text": "Find five references", "chat": "lyra", "name": "Lyra", "shape": "sphere", "color": "blue"]
        require(BuddyDrop.item(good, agents: agents, chats: chats) == BuddyDrop.Item(eventId: "worker-t1-1-completed", agentId: "lyra", kind: "done", text: "Find five references", chat: "lyra", name: "Lyra", shape: "sphere", color: "blue"), "a complete drop")
        var team = good; team["agentId"] = "chief"; team["chat"] = "team"; team["kind"] = "needs"
        require(BuddyDrop.item(team, agents: agents, chats: chats)?.chat == "team", "a team chat opens from its supervisor's holder")
        for (key, value) in [("kind", "urgent"), ("agentId", "stranger"), ("chat", "elsewhere"), ("eventId", ""), ("agentId", 7)] as [(String, Any)] {
            var bad = good; bad[key] = value
            require(BuddyDrop.item(bad, agents: agents, chats: chats) == nil, "refused: \(key) = \(value)")
        }
        require(BuddyDrop.item("not a drop", agents: agents, chats: chats) == nil, "refused: not an object")
        var odd = good; odd["shape"] = "rocket"; odd["color"] = "#ff0000"; odd["name"] = "Ly\nra\u{0}"; odd["text"] = String(repeating: "word ", count: 60)
        let cleaned = BuddyDrop.item(odd, agents: agents, chats: chats)
        require(cleaned?.shape == "diamond" && cleaned?.color == "lilac", "unknown looks fall back to the default figure: \(String(describing: cleaned))")
        require(cleaned?.name == "Ly ra" && (cleaned?.text.count ?? 0) <= 80 && cleaned?.text.hasSuffix("…") == true, "plain, short text: \(String(describing: cleaned))")
        var seen = BuddyDrop.Seen(limit: 3)
        require(seen.first("e1") && !seen.first("e1"), "one event is shown once")
        require(seen.first("e2") && seen.first("e3") && seen.first("e4") && seen.first("e1"), "the oldest are forgotten past the limit")
        print("Desktop drop checks passed.")
    }
}
