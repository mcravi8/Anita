import Foundation
import Security

/// An outside service a command signs in to with the person's own account (WRDS first). `env` says which environment variable of the command
/// carries the username and which the password; `mfa` is the second step the service asks for while signing in ("duo-push": the person approves
/// a push on their phone). Websites (`webHosts`) come with the website step. `key`: the API key of a service the person connected
/// ("service:<id>", BuddyConnectedServices): one secret and no username, which Buddy itself sends to that service and never fills into a
/// command, so it is never a command's `credential`.
struct BuddySignInProfile {
    let id: String, name: String
    let mfa: String?
    let env: [String: String]
    let webHosts: [String]
    var key = false
}

/// A saved sign-in. It exists only on its way from the Keychain into one approved command's environment, never in a record or a reply.
struct BuddySignIn { let username: String, password: String }

/// Where saved sign-ins live: the Keychain (`BuddyCredentials`), or a test's own store.
protocol BuddySignInStore {
    func read(workspace: String, profile: String) -> BuddySignIn?
    func save(workspace: String, profile: String, username: String, password: String) throws
    func remove(workspace: String, profile: String) throws
    func has(workspace: String, profile: String) -> Bool
}

/// The person's sign-ins in the Mac's Keychain, kept as the Claude key is (`BuddyClaudeKey`): one generic password per workspace and service,
/// service "app.buddy.signin", account "<workspace>:<profile>", data a JSON object {username, password}. Nothing else in Buddy stores or logs
/// them: the worker reads one only after the person approved the command it is for, and passes it to that command's process alone.
struct BuddyCredentials: BuddySignInStore {
    static let profiles: [BuddySignInProfile] = [
        BuddySignInProfile(id: "wrds", name: "WRDS", mfa: "duo-push", env: ["username": "PGUSER", "password": "PGPASSWORD"], webHosts: []),
    ]
    /// A connected service's key is the saved sign-in "service:<id>" (lowercase letters, digits and dashes).
    static let servicePrefix = "service:"
    static func profile(_ id: String) -> BuddySignInProfile? {
        if id.hasPrefix(servicePrefix) {
            let slug = String(id.dropFirst(servicePrefix.count))
            guard slug.range(of: #"^[a-z0-9][a-z0-9-]{0,39}$"#, options: .regularExpression) != nil else { return nil }
            return BuddySignInProfile(id: id, name: slug, mfa: nil, env: [:], webHosts: [], key: true)
        }
        return profiles.first { $0.id == id }
    }
    /// The sign-ins a command may use (`credential`): every profile but an API key Buddy keeps for itself.
    static func commandProfile(_ id: String) -> BuddySignInProfile? { profiles.first { $0.id == id && !$0.key } }
    static var profileIDs: [String] { profiles.filter { !$0.key }.map(\.id) }

    /// The Keychain service. Only a test passes its own, so it never touches the person's items.
    let service: String
    init(service: String = "app.buddy.signin") { self.service = service }

    private func query(_ workspace: String, _ profile: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: workspace + ":" + profile]
    }
    func read(workspace: String, profile: String) -> BuddySignIn? {
        guard Self.profile(profile) != nil else { return nil }
        var request = query(workspace, profile); request[kSecReturnData] = true; request[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              let saved = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let username = saved["username"] as? String, let password = saved["password"] as? String, !username.isEmpty || Self.profile(profile)?.key == true, !password.isEmpty else { return nil }
        return BuddySignIn(username: username, password: password)
    }
    /// Whether one is saved. Only its attributes are asked for, so this never reads the secret (and never makes macOS ask to use it).
    func has(workspace: String, profile: String) -> Bool {
        guard Self.profile(profile) != nil else { return false }
        var request = query(workspace, profile); request[kSecReturnAttributes] = true; request[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        return SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess
    }
    func save(workspace: String, profile: String, username: String, password: String) throws {
        guard let named = Self.profile(profile) else { throw BuddyWorkerFailure(message: "Buddy has no sign-in for that service.") }
        let user = named.key ? "" : username.trimmingCharacters(in: .whitespacesAndNewlines)
        // An API key is one line as pasted (the spaces and line breaks a copy brings along are not part of it).
        let password = named.key ? password.trimmingCharacters(in: .whitespacesAndNewlines) : password
        if named.key {
            guard password.count >= 8, password.count <= 500, password.rangeOfCharacter(from: .whitespacesAndNewlines) == nil, !password.contains("\0") else {
                throw BuddyWorkerFailure(message: "Paste your \(named.name) API key: one line, with no spaces.")
            }
        } else {
            guard !user.isEmpty, user.count <= 200, !password.isEmpty, password.count <= 1000, !user.contains("\0"), !password.contains("\0") else {
                throw BuddyWorkerFailure(message: "Enter your \(named.name) username and password.")
            }
        }
        let data = try JSONSerialization.data(withJSONObject: ["username": user, "password": password])
        let match = query(workspace, profile)
        let code = SecItemUpdate(match as CFDictionary, [kSecValueData: data] as CFDictionary)
        if code == errSecItemNotFound {
            var add = match; add[kSecValueData] = data; add[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly; add[kSecAttrLabel] = "Buddy: \(named.name) " + (named.key ? "API key" : "sign-in")
            guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw BuddyWorkerFailure(message: "Couldn’t save the \(named.name) sign-in in Keychain.") }
        } else if code != errSecSuccess { throw BuddyWorkerFailure(message: "Couldn’t update the \(named.name) sign-in in Keychain.") }
    }
    func remove(workspace: String, profile: String) throws {
        let code = SecItemDelete(query(workspace, profile) as CFDictionary)
        guard [errSecSuccess, errSecItemNotFound].contains(code) else { throw BuddyWorkerFailure(message: "Couldn’t remove this sign-in from Keychain.") }
    }

    /// The environment variables one command gets for a sign-in (for WRDS: PGUSER and PGPASSWORD, which the wrds package and psql read).
    static func environment(_ profile: BuddySignInProfile, _ signIn: BuddySignIn) -> [String: String] {
        var out: [String: String] = [:]
        if let name = profile.env["username"] { out[name] = signIn.username }
        if let name = profile.env["password"] { out[name] = signIn.password }
        return out
    }
    static let hiddenMark = "[hidden]"
    /// `text` with every saved value, as written and as it appears in a web address, replaced (longest first).
    static func redact(_ text: String, _ values: [String]) -> String {
        let forms = Set(values.filter { !$0.isEmpty }.flatMap { [$0, $0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0] }).sorted { $0.count > $1.count }
        var out = text
        for form in forms where !form.isEmpty { out = out.replacingOccurrences(of: form, with: hiddenMark) }
        return out
    }
    /// A command's result with every saved value taken out of its text.
    static func redact(_ result: [String: Any], _ values: [String]) -> [String: Any] {
        guard !values.isEmpty else { return result }
        return result.mapValues { value in (value as? String).map { redact($0, values) } ?? value }
    }
}

/// A website password the person chose to remember when they typed it in a chat ("Remember for shop.example (ada@example.com)"): which
/// site and which account, never the password.
struct BuddyWebsiteSignIn: Equatable { let origin: String, username: String }

/// Where remembered website passwords live: the Keychain (`BuddyCredentials`), or a test's own store. Buddy reads one only to type it into
/// that very site's sign-in page for that very account (the browser's one-use, site-bound field), the way a typed password goes there.
protocol BuddyWebsiteSignInStore {
    func sitePassword(workspace: String, origin: String, username: String) -> String?
    func saveSite(workspace: String, origin: String, username: String, password: String) throws
    func removeSite(workspace: String, origin: String, username: String) throws
    func sites(workspace: String) -> [BuddyWebsiteSignIn]
}

/// Remembered website passwords in the Keychain: one generic password each, service "app.buddy.signin", account
/// "<workspace>:site:<origin>|<username>", data the password alone. The site and account are in the item's name, so listing them never
/// reads a password (and never makes macOS ask to use one).
extension BuddyCredentials: BuddyWebsiteSignInStore {
    static func siteKey(_ workspace: String, _ origin: String, _ username: String) -> String { workspace + ":site:" + origin + "|" + username }
    private func siteQuery(_ workspace: String, _ origin: String, _ username: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: Self.siteKey(workspace, origin, username)]
    }
    func sitePassword(workspace: String, origin: String, username: String) -> String? {
        var request = siteQuery(workspace, origin, username); request[kSecReturnData] = true; request[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data, let password = String(data: data, encoding: .utf8), !password.isEmpty else { return nil }
        return password
    }
    func saveSite(workspace: String, origin: String, username: String, password: String) throws {
        guard BuddyWebsiteSignIns.origin(origin) == origin, username.count <= 254, !username.contains("\0"), !username.contains("|"), !password.isEmpty, password.count <= 1000, !password.contains("\0") else {
            throw BuddyWorkerFailure(message: "Buddy can remember a password only for a website's sign-in page.")
        }
        let match = siteQuery(workspace, origin, username), data = Data(password.utf8)
        let code = SecItemUpdate(match as CFDictionary, [kSecValueData: data] as CFDictionary)
        if code == errSecItemNotFound {
            var add = match; add[kSecValueData] = data; add[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            add[kSecAttrLabel] = "Buddy: \(URL(string: origin)?.host ?? origin) sign-in" + (username.isEmpty ? "" : " (\(username))")
            guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw BuddyWorkerFailure(message: "Couldn’t save this sign-in in Keychain.") }
        } else if code != errSecSuccess { throw BuddyWorkerFailure(message: "Couldn’t update this sign-in in Keychain.") }
    }
    func removeSite(workspace: String, origin: String, username: String) throws {
        let code = SecItemDelete(siteQuery(workspace, origin, username) as CFDictionary)
        guard [errSecSuccess, errSecItemNotFound].contains(code) else { throw BuddyWorkerFailure(message: "Couldn’t remove this sign-in from Keychain.") }
    }
    func sites(workspace: String) -> [BuddyWebsiteSignIn] {
        let request: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecReturnAttributes: true, kSecMatchLimit: kSecMatchLimitAll]
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let items = result as? [[String: Any]] else { return [] }
        let prefix = workspace + ":site:"
        return items.compactMap { item -> BuddyWebsiteSignIn? in
            guard let account = item[kSecAttrAccount as String] as? String, account.hasPrefix(prefix) else { return nil }
            let rest = account.dropFirst(prefix.count)
            guard let bar = rest.firstIndex(of: "|") else { return nil }
            return BuddyWebsiteSignIn(origin: String(rest[..<bar]), username: String(rest[rest.index(after: bar)...]))
        }.sorted { ($0.origin, $0.username) < ($1.origin, $1.username) }
    }
}

/// The remembered website sign-ins as Buddy's own sign-in box offers them: listed (site and account), replaced, removed.
enum BuddyWebsiteSignIns {
    /// A website's origin as remembered (scheme, host and port, nothing else), or nil.
    static func origin(_ raw: String?) -> String? {
        guard let raw, let parts = URLComponents(string: raw), let scheme = parts.scheme?.lowercased(), ["https", "http"].contains(scheme), let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil else { return nil }
        return scheme + "://" + host + (parts.port.map { ":\($0)" } ?? "")
    }
    static func handle(_ action: String, _ payload: [String: Any], workspace: String, store: BuddyWebsiteSignInStore) throws -> [String: Any] {
        let all = store.sites(workspace: workspace)
        if action == "sites" { return ["sites": all.map { ["origin": $0.origin, "username": $0.username, "site": URL(string: $0.origin)?.host ?? $0.origin] as [String: Any] }] }
        guard let origin = origin(payload["origin"] as? String), let username = payload["username"] as? String, all.contains(BuddyWebsiteSignIn(origin: origin, username: username)) else {
            throw BuddyWorkerFailure(message: "Buddy doesn’t remember a password for that sign-in.")
        }
        if action == "removeSite" { try store.removeSite(workspace: workspace, origin: origin, username: username); return ["removed": true, "origin": origin, "username": username] }
        guard let password = payload["password"] as? String, !password.isEmpty, password.count <= 1000, password.rangeOfCharacter(from: .newlines) == nil, !password.contains("\0") else {
            throw BuddyWorkerFailure(message: "Type the new password on one line, up to 1,000 characters.")
        }
        try store.saveSite(workspace: workspace, origin: origin, username: username, password: password)
        return ["saved": true, "origin": origin, "username": username]
    }
}

/// Accounts Buddy creates on websites for the person, and passwords it resets, always after the person said yes in the chat for that very
/// site (an agent's or the supervisor's answer never counts, and no yes covers another site). The password is made here, never by a model,
/// goes to the browser only to be typed into that site's own form, and then into the Keychain (`BuddyWebsiteSignInStore`), where Buddy fills it
/// in at the next sign-in. Buddy never pays, subscribes or starts a trial that becomes paid: such a sign-up stops before anything is sent.
enum BuddyWebsiteAccounts {
    /// A strong random password from the system's secure random source: `length` characters of letters, digits and symbols, at least one of
    /// each kind, with no characters that are easy to confuse.
    static func password(length: Int = 20) -> String {
        let lower = Array("abcdefghijkmnopqrstuvwxyz"), upper = Array("ABCDEFGHJKLMNPQRSTUVWXYZ"), digits = Array("23456789"), symbols = Array("!#$%&*+-=?@^_")
        let all = lower + upper + digits + symbols
        func pick(_ set: [Character]) -> Character {
            var byte: UInt32 = 0
            let limit = UInt32.max - UInt32.max % UInt32(set.count)
            repeat { _ = withUnsafeMutableBytes(of: &byte) { SecRandomCopyBytes(kSecRandomDefault, 4, $0.baseAddress!) } } while byte >= limit
            return set[Int(byte % UInt32(set.count))]
        }
        var out = [pick(lower), pick(upper), pick(digits), pick(symbols)]
        while out.count < max(length, 12) { out.append(pick(all)) }
        // Shuffled with the same source, so the four kinds are not always first.
        for i in stride(from: out.count - 1, to: 0, by: -1) {
            var byte: UInt32 = 0; _ = withUnsafeMutableBytes(of: &byte) { SecRandomCopyBytes(kSecRandomDefault, 4, $0.baseAddress!) }
            out.swapAt(i, Int(byte % UInt32(i + 1)))
        }
        return String(out)
    }
    /// Other fields a sign-up form requires, as the agent gives them ([{label, value}], from what the person told it or their own profile):
    /// plain one-line text, at most twelve, never a password or payment detail.
    static func details(_ raw: Any?) throws -> [String: String] {
        guard let list = raw as? [[String: Any]], !list.isEmpty else { return [:] }
        guard list.count <= 12 else { throw BuddyWorkerFailure(message: "Give at most twelve details. Nothing was created.", code: "invalid_input") }
        var out: [String: String] = [:]
        for item in list {
            let label = (item["label"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines), value = (item["value"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, label.count <= 80, !value.isEmpty, value.count <= 200, value.rangeOfCharacter(from: .newlines) == nil, !value.contains("\0") else {
                throw BuddyWorkerFailure(message: "Each detail is a label and a one-line value (up to 200 characters). Nothing was created.", code: "invalid_input")
            }
            if (label + " " + value).range(of: #"password|passcode|\bpin\b|card|cvc|cvv|iban|routing|account number|sort code|social security|\bssn\b|passport"#, options: [.regularExpression, .caseInsensitive]) != nil {
                throw BuddyWorkerFailure(message: "Buddy never fills passwords, payment or ID numbers from details. Nothing was created.", code: "invalid_input")
            }
            out[label] = value
        }
        return out
    }
    static func host(_ origin: String) -> String { URL(string: origin)?.host ?? origin }
    /// What the chat card asks, in the person's words.
    static func ask(agent: String, site: String, email: String, purpose: String) -> String {
        purpose == "reset" ? "\(agent) wants to reset your password on \(site) through your email — is that fine?" : "\(agent) wants to create an account on \(site) with \(email) — is that fine?"
    }
    /// What happens on Create account (or Reset password).
    static func what(site: String, purpose: String) -> String {
        purpose == "reset" ? "Buddy asks \(site) for a reset email, opens the link from your Gmail, sets a new strong password and keeps it in your Keychain, then signs in."
            : "Buddy makes a strong password and keeps it in your Keychain; it agrees to the site’s standard terms; it confirms the email in your Gmail."
    }
    static func receipt(site: String, email: String, remembered: Bool) -> String {
        remembered ? "Created an account on \(site) as \(email) — password saved in your Keychain." : "Created an account on \(site) as \(email), but Buddy couldn’t save the password in your Keychain. Reset it from the site if you need it."
    }
    static func resetReceipt(site: String, email: String, remembered: Bool) -> String {
        remembered ? "Reset your password on \(site) for \(email) — the new one is saved in your Keychain." : "Reset your password on \(site) for \(email), but Buddy couldn’t save the new one in your Keychain."
    }
    /// The receipt's details line: Chrome's own Password Manager is not where Buddy keeps it, and why.
    static let keychainNote = "Chrome’s Password Manager can’t be filled in by automation, so Buddy keeps this password in your Mac’s Keychain and fills it in whenever an agent signs in to the site. You’ll find it in Saved sign-ins."
    static func moneyTitle(site: String, kind: String) -> String {
        kind == "trial" ? "This sign-up on \(site) starts a free trial that becomes paid" : "This sign-up on \(site) asks for payment details"
    }
    static func moneyInstruction(site: String, kind: String) -> String {
        moneyTitle(site: site, kind: kind) + ". Buddy stopped. It never enters payment details or starts a paid trial. Open the page to do it yourself in Buddy’s Chrome and press Done, or Skip."
    }
    static func confirmInstruction(site: String) -> String { "Confirm the email from \(site) in your inbox, then press Done." }
    static func smsNote(site: String) -> String { "Enter the code \(site) texted to your phone." }
    static func emailCodeNote(site: String, email: String) -> String { "Enter the code \(site) emailed to \(email)." }
    static func missingNote(site: String, missing: [String]) -> String {
        "The sign-up form on \(site) also needs: \(missing.joined(separator: ", ")). Give them in details only from what the user told you or their own profile; never invent them (a phone number only if their profile has it). Otherwise ask the user with buddy_request_decision (category personal_fact). Nothing was created yet."
    }
    static let noEmail = "Buddy doesn’t know which email address the new account should use: this task has no account of its own, and Buddy’s Chrome has more than one (or no) Google account. Give email (the address the user wants to use; ask them with buddy_request_decision if you don’t know). Nothing was created."
    static func declined(site: String, purpose: String) -> String {
        purpose == "reset" ? "The user said no to resetting the password on \(site). Buddy asks them for the password in the chat instead."
            : "The user said no to creating an account on \(site). Don’t create one or ask again for this site in this task; continue without it, and say in your result what you couldn’t do."
    }
    static func skipNote(site: String) -> String {
        "[Buddy] The user chose Skip: Buddy did not sign up on \(site), and nothing was paid or started there. Don’t try again; continue without it, and say in your result what you couldn’t do."
    }
    static func paidNote(site: String, page: String) -> String {
        "[Buddy] The user handled the payment step on \(site) themselves in Buddy’s Chrome (Buddy never pays). Reopen \(page) and check its actual state before continuing; never enter payment details or start anything paid yourself."
    }
}


/// What the person can type in a chat for a waiting sign-in: the browser's one-use token for one task's page and field, its site and
/// account. Only the worker holds it, in memory; the page and the model never see the token, and it ends after `lifetime`.
struct BuddyTypedSignIn {
    let task: String, token: String, field: String, origin: String
    let account: String?
    var expires: Date
    static var lifetime: TimeInterval = 600
}

/// The app's side of the sign-in requests the person answers in a chat (the page's `signin` bridge). What they type goes from the chat's
/// field to here, and from here only to where it was asked for: a service sign-in (WRDS) into the Keychain (`provide`), or a website's
/// password or code to the worker, which types it into the one page that asked (`secret`). Done on a step outside the chat is `check`
/// (the website waits for something, such as a push on the phone) or `done` (Buddy's Chrome window, or anything else). Replies never
/// carry what was typed. There is no other box: a sign-in without typed values saves nothing.
@MainActor enum BuddySignInBox {
    static let assurance = "Buddy keeps this in your Mac's Keychain. Agents never see it; Buddy fills it in only for commands you approve."
    /// Whether the page's general worker bridge must refuse this payload: typed sign-ins travel only through the sign-in bridge.
    nonisolated static func workerRefuses(_ payload: [String: Any]) -> Bool {
        guard payload["operation"] as? String == "signin" else { return false }
        let action = (payload["arguments"] as? [String: Any])?["action"] as? String ?? "status"
        return !["status"].contains(action)
    }
    /// The page's `signin` request. `status` says which service sign-ins are saved; `provide` saves the username and password typed in the
    /// chat and, if a task waits for it, has the worker resume that task with a plain note; `remove` forgets one; `secret`, `check` and
    /// `done` go to the worker for the task that asked.
    static func handle(_ payload: [String: Any], workspace: String, support: URL, store: BuddySignInStore = BuddyCredentials()) async throws -> [String: Any] {
        let action = payload["action"] as? String ?? "status"
        if action == "status" { return ["profiles": BuddyCredentials.profiles.map { ["id": $0.id, "name": $0.name, "saved": store.has(workspace: workspace, profile: $0.id)] as [String: Any] }] }
        // Remembered website sign-ins (Background work → Browser sign-in): listed, replaced, removed here, in the app, never by the worker.
        if ["sites", "replaceSite", "removeSite"].contains(action) {
            guard let sites = store as? BuddyWebsiteSignInStore else { throw BuddyWorkerFailure(message: "Remembered sign-ins are unavailable.") }
            return try BuddyWebsiteSignIns.handle(action, payload, workspace: workspace, store: sites)
        }
        // `account`: the person's ✓ Create account (or Reset password) / ✗ Don't on an agent's request for one site; `skip`: their Skip on a
        // sign-up Buddy stopped because it asks for money. Only this bridge carries them, so only the person's click answers them.
        if ["secret", "check", "done", "account", "skip"].contains(action) {
            var arguments: [String: Any] = ["action": action, "taskId": payload["taskId"] as? String ?? ""]
            if let review = payload["reviewId"] as? String { arguments["reviewId"] = review }
            if action == "account" { arguments["allow"] = payload["allow"] as? Bool == true }
            // "Remember for <site> (<account>)": kept in the Keychain once the site took it, and filled by Buddy next time.
            if action == "secret" {
                arguments["value"] = payload["value"] as? String ?? ""; arguments["remember"] = payload["remember"] as? Bool == true
                // A sign-in that asks for the email too (both fields in the chat): the account typed with the password.
                if let user = payload["username"] as? String { arguments["username"] = user }
            }
            // Typing into a page, and Done (which may close Chrome and look at the page again), take longer than other requests.
            return try await BuddyWorkerClient.call(support: support, payload: ["workspace": workspace, "operation": "signin", "arguments": arguments], timeout: 90)
        }
        guard ["provide", "remove"].contains(action), let profile = BuddyCredentials.profile(payload["profile"] as? String ?? "") else { throw BuddyWorkerFailure(message: "Choose a sign-in Buddy supports.") }
        // A connected service's key comes with its address and choices (BuddyServiceBox), never on its own.
        guard !profile.key else { throw BuddyWorkerFailure(message: "Connect this service in Connected services, or in the chat's own field.") }
        if action == "remove" { try store.remove(workspace: workspace, profile: profile.id); return ["profile": profile.id, "saved": false] }
        guard let username = payload["username"] as? String, let password = payload["password"] as? String, !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !password.isEmpty else {
            throw BuddyWorkerFailure(message: "Type your \(profile.name) username and password in the sign-in field in the chat.")
        }
        try store.save(workspace: workspace, profile: profile.id, username: username, password: password)
        var reply: [String: Any] = ["profile": profile.id, "name": profile.name, "saved": true]
        if let task = payload["taskId"] as? String, !task.isEmpty {
            do {
                let resumed = try await BuddyWorkerClient.call(support: support, payload: ["workspace": workspace, "operation": "signin", "arguments": ["action": "saved", "profile": profile.id, "taskId": task]])
                reply["resumed"] = resumed["resumed"] as? Bool ?? false
            } catch { reply["resumed"] = false; reply["resumeError"] = error.localizedDescription }
        }
        return reply
    }
}
