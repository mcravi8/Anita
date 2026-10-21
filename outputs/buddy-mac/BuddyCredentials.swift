import Foundation
import Security

/// An outside service a command signs in to with the person's own account (WRDS first). `env` says which environment variable of the command
/// carries the username and which the password; `mfa` is the second step the service asks for while signing in ("duo-push": the person approves
/// a push on their phone). Websites (`webHosts`) come with the website step.
struct BuddySignInProfile {
    let id: String, name: String
    let mfa: String?
    let env: [String: String]
    let webHosts: [String]
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
    static func profile(_ id: String) -> BuddySignInProfile? { profiles.first { $0.id == id } }
    static var profileIDs: [String] { profiles.map(\.id) }

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
              let username = saved["username"] as? String, let password = saved["password"] as? String, !username.isEmpty, !password.isEmpty else { return nil }
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
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty, user.count <= 200, !password.isEmpty, password.count <= 1000, !user.contains("\0"), !password.contains("\0") else {
            throw BuddyWorkerFailure(message: "Enter your \(named.name) username and password.")
        }
        let data = try JSONSerialization.data(withJSONObject: ["username": user, "password": password])
        let match = query(workspace, profile)
        let code = SecItemUpdate(match as CFDictionary, [kSecValueData: data] as CFDictionary)
        if code == errSecItemNotFound {
            var add = match; add[kSecValueData] = data; add[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly; add[kSecAttrLabel] = "Buddy: \(named.name) sign-in"
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
        if ["secret", "check", "done"].contains(action) {
            var arguments: [String: Any] = ["action": action, "taskId": payload["taskId"] as? String ?? ""]
            if let review = payload["reviewId"] as? String { arguments["reviewId"] = review }
            if action == "secret" { arguments["value"] = payload["value"] as? String ?? "" }
            // Typing into a page, and Done (which may close Chrome and look at the page again), take longer than other requests.
            return try await BuddyWorkerClient.call(support: support, payload: ["workspace": workspace, "operation": "signin", "arguments": arguments], timeout: 90)
        }
        guard ["provide", "remove"].contains(action), let profile = BuddyCredentials.profile(payload["profile"] as? String ?? "") else { throw BuddyWorkerFailure(message: "Choose a sign-in Buddy supports.") }
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
