import Foundation

/// Which Google accounts the shared Chrome profile is signed in to, for the Browser sign-in page: `chrome` is the account Chrome itself is
/// signed in to (Google Password Manager comes from it), `accounts` every Google account the profile knows. Only Chrome's settings files are
/// read, for these names; never its cookie or password databases. A missing or half-written file reads as nobody.
enum BuddyChromeAccounts {
    static func read(profile: URL) -> [String: Any] {
        func json(_ url: URL) -> [String: Any]? { (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
        func email(_ value: Any?) -> String? {
            guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), text.count <= 254, text.contains("@"), !text.contains(where: \.isNewline) else { return nil }
            return text
        }
        let cache = ((json(profile.appendingPathComponent("Local State"))?["profile"] as? [String: Any])?["info_cache"] as? [String: Any])?["Default"] as? [String: Any]
        let chrome = email(cache?["user_name"])
        var accounts: [String] = chrome.map { [$0] } ?? []
        for account in (json(profile.appendingPathComponent("Default/Preferences"))?["account_info"] as? [[String: Any]]) ?? [] {
            if let address = email(account["email"]), !accounts.contains(where: { $0.caseInsensitiveCompare(address) == .orderedSame }) { accounts.append(address) }
        }
        return ["chrome": chrome as Any? ?? NSNull(), "accounts": Array(accounts.prefix(10))]
    }
}
