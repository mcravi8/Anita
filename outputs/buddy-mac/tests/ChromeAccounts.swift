// run-tests: BuddyChromeAccounts.swift
import Foundation

/// The Browser sign-in page names the Google accounts the shared Chrome is signed in to. Only Chrome's settings files are read, for names;
/// a missing or half-written file reads as nobody.
@main struct ChromeAccountsChecks {
    static var failures = 0
    static func check(_ ok: Bool, _ name: String) { if ok { print("PASS: \(name)") } else { failures += 1; print("FAILED: \(name)") } }
    static func main() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("buddy-chrome-accounts-\(UUID().uuidString).noindex", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        func profile(_ name: String, localState: Any?, preferences: Any?) throws -> URL {
            let root = base.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Default"), withIntermediateDirectories: true)
            if let localState { try JSONSerialization.data(withJSONObject: localState).write(to: root.appendingPathComponent("Local State")) }
            if let preferences { try JSONSerialization.data(withJSONObject: preferences).write(to: root.appendingPathComponent("Default/Preferences")) }
            // Stand-ins for the databases Buddy must never read: their contents can't reach the reply.
            try Data("secret-cookie".utf8).write(to: root.appendingPathComponent("Default/Cookies"))
            try Data("secret-password".utf8).write(to: root.appendingPathComponent("Default/Login Data"))
            return root
        }

        let signed = try profile("signed", localState: ["profile": ["info_cache": ["Default": ["user_name": "me@gmail.com"]]]],
                                 preferences: ["account_info": [["email": "me@gmail.com"], ["email": "Me@USC.edu"], ["email": "not an address"], ["email": "me@usc.edu"]]])
        let reply = BuddyChromeAccounts.read(profile: signed)
        check(reply["chrome"] as? String == "me@gmail.com", "the account Chrome itself is signed in to comes first")
        check(reply["accounts"] as? [String] == ["me@gmail.com", "Me@USC.edu"], "other Google accounts follow, once each whatever their case, and non-addresses are dropped")
        let text = String(data: try JSONSerialization.data(withJSONObject: reply), encoding: .utf8) ?? ""
        check(!text.contains("secret-cookie") && !text.contains("secret-password"), "nothing from the cookie or password databases reaches the reply")

        let webOnly = try profile("web-only", localState: ["profile": ["info_cache": ["Default": ["user_name": ""]]]], preferences: ["account_info": [["email": "me@usc.edu"]]])
        let web = BuddyChromeAccounts.read(profile: webOnly)
        check(web["chrome"] is NSNull && web["accounts"] as? [String] == ["me@usc.edu"], "a Google account on the web without Chrome sign-in is listed, Chrome itself reads as nobody")

        let empty = BuddyChromeAccounts.read(profile: base.appendingPathComponent("never-created"))
        check(empty["chrome"] is NSNull && (empty["accounts"] as? [String])?.isEmpty == true, "a profile that doesn't exist yet reads as nobody")

        let torn = base.appendingPathComponent("torn", isDirectory: true)
        try FileManager.default.createDirectory(at: torn.appendingPathComponent("Default"), withIntermediateDirectories: true)
        try Data("{\"profile\":{\"info_cache\"".utf8).write(to: torn.appendingPathComponent("Local State"))
        let half = BuddyChromeAccounts.read(profile: torn)
        check(half["chrome"] is NSNull && (half["accounts"] as? [String])?.isEmpty == true, "a half-written settings file reads as nobody instead of failing")

        let many = try profile("many", localState: nil, preferences: ["account_info": (0..<15).map { ["email": "a\($0)@usc.edu"] }])
        check((BuddyChromeAccounts.read(profile: many)["accounts"] as? [String])?.count == 10, "at most ten accounts are listed")

        if failures > 0 { exit(1) }
    }
}
