import Foundation

/// Connected services: any web API the person connects once (a name, its https address, how its key is sent, whether it can charge money,
/// and the key), which agents then use through Buddy (`buddy_service_api`) without ever seeing the key. On 23 Oct Forge stopped a ten-hour
/// local simulation to move it to RunPod and found Buddy had no way to reach RunPod at all; RunPod is only the first service: nothing here
/// knows about it. The key is the saved sign-in "service:<id>" in the Keychain (BuddyCredentials); the rest is in
/// Support/connected-services.json, which only the person changes, through Buddy's own sign-in bridge (BuddyServiceBox).
struct BuddyConnectedService {
    let id: String, name: String, baseURL: URL, header: String, scheme: String, charges: Bool, addedAt: String
    var profile: String { BuddyCredentials.servicePrefix + id }
    /// How the key is sent, without the key ("Authorization: Bearer …").
    var sends: String { header + ": " + (scheme.isEmpty ? "" : scheme + " ") + "…" }
    var payload: [String: Any] { ["id": id, "name": name, "baseUrl": baseURL.absoluteString, "header": header, "scheme": scheme, "charges": charges, "addedAt": addedAt] }
    init(id: String, name: String, baseURL: URL, header: String, scheme: String, charges: Bool, addedAt: String) {
        self.id = id; self.name = name; self.baseURL = baseURL; self.header = header; self.scheme = scheme; self.charges = charges; self.addedAt = addedAt
    }
    init?(_ value: [String: Any]) {
        guard let id = value["id"] as? String, BuddyConnectedServices.validID(id), let name = value["name"] as? String, let base = BuddyConnectedServices.baseURL(value["baseUrl"] as? String),
              let header = BuddyConnectedServices.header(value["header"] as? String), let scheme = BuddyConnectedServices.scheme(value["scheme"] as? String) else { return nil }
        self.init(id: id, name: name, baseURL: base, header: header, scheme: scheme, charges: value["charges"] as? Bool ?? true, addedAt: value["addedAt"] as? String ?? "")
    }
}

/// The connected services of each workspace: names, addresses and choices, never keys.
struct BuddyConnectedServices {
    let support: URL
    var file: URL { support.appendingPathComponent("connected-services.json") }

    static func validID(_ id: String) -> Bool { id.range(of: #"^[a-z0-9][a-z0-9-]{0,39}$"#, options: .regularExpression) != nil }
    /// A service's id from its name ("RunPod" → "runpod", "Open AI" → "open-ai").
    static func id(_ name: String?) -> String? {
        let words = (name ?? "").lowercased().split { !($0.isLetter && $0.isASCII || $0.isNumber && $0.isASCII) }
        let id = String(words.joined(separator: "-").prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return validID(id) ? id : nil
    }
    /// A plain name for a service: one line, at most 60 characters.
    static func name(_ raw: String?) -> String? {
        let name = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 60, name.rangeOfCharacter(from: .newlines) == nil, !name.contains("\0"), id(name) != nil else { return nil }
        return name
    }
    /// Under tests, nothing may leave this Mac: only a stand-in on the loopback address is a service then.
    static var loopbackOnly: Bool { ProcessInfo.processInfo.environment["BUDDY_TEST_LOOPBACK_ONLY"] == "1" }
    static func loopback(_ host: String?) -> Bool { ["127.0.0.1", "localhost", "::1"].contains(host ?? "") }
    /// A service's API address: https, a host, no user, query or fragment (a test's stand-in on this Mac may use http). Its path is kept,
    /// without a trailing slash, and every request goes under it.
    static func baseURL(_ raw: String?) -> URL? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), text.count <= 300, let parts = URLComponents(string: text), let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else { return nil }
        let scheme = parts.scheme?.lowercased() ?? ""
        if loopbackOnly { guard loopback(host), ["http", "https"].contains(scheme) else { return nil } }
        else { guard scheme == "https" else { return nil } }
        while text.hasSuffix("/") { text.removeLast() }
        return URL(string: text)
    }
    /// The header that carries the key: Authorization by default, or one the service names (X-API-Key). Never one that means something else.
    static func header(_ raw: String?) -> String? {
        let name = (raw ?? "").trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return "Authorization" }
        guard name.range(of: #"^[A-Za-z0-9][A-Za-z0-9-]{0,63}$"#, options: .regularExpression) != nil,
              !["host", "content-length", "content-type", "cookie", "connection", "transfer-encoding", "accept", "user-agent"].contains(name.lowercased()) else { return nil }
        return name
    }
    /// What goes before the key in its header: Bearer by default; nothing for a header that takes the key alone.
    static func scheme(_ raw: String?) -> String? {
        guard let raw else { return "Bearer" }
        let scheme = raw.trimmingCharacters(in: .whitespaces)
        guard scheme.isEmpty || scheme.range(of: #"^[A-Za-z][A-Za-z0-9-]{0,19}$"#, options: .regularExpression) != nil else { return nil }
        return scheme
    }

    private func read() -> [String: Any] { (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:] }
    private func write(_ value: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        try data.write(to: file, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    func list(_ workspace: String) -> [BuddyConnectedService] {
        (((read()["workspaces"] as? [String: Any])?[workspace]) as? [[String: Any]] ?? []).compactMap(BuddyConnectedService.init)
    }
    /// A connected service by its id or its name, however it is written.
    func service(_ workspace: String, _ raw: String?) -> BuddyConnectedService? {
        guard let wanted = Self.id(raw) else { return nil }
        return list(workspace).first { $0.id == wanted }
    }
    func save(_ workspace: String, _ service: BuddyConnectedService) throws {
        var all = read(), spaces = all["workspaces"] as? [String: Any] ?? [:]
        var list = spaces[workspace] as? [[String: Any]] ?? []
        list.removeAll { $0["id"] as? String == service.id }; list.append(service.payload)
        spaces[workspace] = list.sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }; all["workspaces"] = spaces; all["version"] = 1
        try write(all)
    }
    func remove(_ workspace: String, _ id: String) throws {
        var all = read(), spaces = all["workspaces"] as? [String: Any] ?? [:]
        var list = spaces[workspace] as? [[String: Any]] ?? []
        list.removeAll { $0["id"] as? String == id }; spaces[workspace] = list; all["workspaces"] = spaces
        try write(all)
    }
}

/// The app's side of connected services (the page's `signin` bridge, which only the person's page reaches): the list for Settings (never a
/// key), connecting one (from Settings, or from the chat's card when an agent asked for a service that isn't connected: the task then goes on
/// by itself), replacing its key, and removing it.
@MainActor enum BuddyServiceBox {
    static let actions: Set<String> = ["services", "provideService", "removeService"]
    static func handles(_ payload: [String: Any]) -> Bool { actions.contains(payload["action"] as? String ?? "") }
    static func handle(_ payload: [String: Any], workspace: String, support: URL, store: BuddySignInStore = BuddyCredentials()) async throws -> [String: Any] {
        let services = BuddyConnectedServices(support: support), action = payload["action"] as? String ?? ""
        func listed() -> [[String: Any]] { services.list(workspace).map { s in var row = s.payload; row["sends"] = s.sends; row["saved"] = store.has(workspace: workspace, profile: s.profile); return row } }
        if action == "services" { return ["services": listed()] }
        if action == "removeService" {
            guard let id = BuddyConnectedServices.id(payload["id"] as? String), let found = services.list(workspace).first(where: { $0.id == id }) else { throw BuddyWorkerFailure(message: "That service isn’t connected.") }
            try store.remove(workspace: workspace, profile: found.profile); try services.remove(workspace, id)
            return ["removed": true, "id": id, "services": listed()]
        }
        // Connecting (or replacing): the name, the address, how the key is sent, whether it can charge money, and the key. A replacement may
        // keep the key it has by leaving it out.
        guard let name = BuddyConnectedServices.name(payload["name"] as? String), let id = BuddyConnectedServices.id(name) else { throw BuddyWorkerFailure(message: "Give the service a short name, such as RunPod.") }
        guard let base = BuddyConnectedServices.baseURL(payload["baseUrl"] as? String) else { throw BuddyWorkerFailure(message: "Give the service’s API address, starting with https:// (for example https://rest.example.com/v1).") }
        guard let header = BuddyConnectedServices.header(payload["header"] as? String) else { throw BuddyWorkerFailure(message: "The key’s header must be a plain header name, such as Authorization or X-API-Key.") }
        guard let scheme = BuddyConnectedServices.scheme(payload["scheme"] as? String ?? (header == "Authorization" ? "Bearer" : "")) else { throw BuddyWorkerFailure(message: "Choose how the key is written in its header.") }
        guard let charges = payload["charges"] as? Bool else { throw BuddyWorkerFailure(message: "Say whether \(name) can charge you money.") }
        let key = (payload["key"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines), profile = BuddyCredentials.servicePrefix + id
        if key.isEmpty { guard store.has(workspace: workspace, profile: profile) else { throw BuddyWorkerFailure(message: "Paste \(name)’s API key.") } }
        else { try store.save(workspace: workspace, profile: profile, username: "", password: key) }
        let added = services.list(workspace).first { $0.id == id }?.addedAt ?? ISO8601DateFormatter().string(from: Date())
        try services.save(workspace, BuddyConnectedService(id: id, name: name, baseURL: base, header: header, scheme: scheme, charges: charges, addedAt: added))
        var reply: [String: Any] = ["saved": true, "id": id, "name": name, "services": listed()]
        // The task that asked for it goes on by itself, told what the person connected (never the key).
        if let task = payload["taskId"] as? String, !task.isEmpty {
            do {
                let resumed = try await BuddyWorkerClient.call(support: support, payload: ["workspace": workspace, "operation": "signin", "arguments": ["action": "saved", "profile": profile, "taskId": task]])
                reply["resumed"] = resumed["resumed"] as? Bool ?? false
            } catch { reply["resumed"] = false; reply["resumeError"] = error.localizedDescription }
        }
        return reply
    }
}

/// A response from a connected service, as the agent gets it.
struct BuddyServiceResponse { let status: Int, headers: [String: String], data: Data }

/// Requests to a connected service with its key, from Buddy's own process: the key goes only into the header the person chose, on requests to
/// the address they connected; never into a URL, a process's arguments, a record or a reply. Redirects are not followed (a redirect elsewhere
/// would take the key with it); the agent gets the redirect itself.
struct BuddyServiceClient {
    let service: BuddyConnectedService, key: String
    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil; c.httpShouldSetCookies = false; c.urlCache = nil; c.requestCachePolicy = .reloadIgnoringLocalCacheData; c.timeoutIntervalForRequest = 60
        return URLSession(configuration: c)
    }()
    /// The URL of a path under the service's address, or nil when it would leave it.
    static func url(_ service: BuddyConnectedService, path: String, query: [URLQueryItem]) -> URL? {
        let base = service.baseURL
        guard let path = BuddyServiceAPI.path(path), let joined = URL(string: base.absoluteString + path), var parts = URLComponents(url: joined, resolvingAgainstBaseURL: false) else { return nil }
        if !query.isEmpty { parts.queryItems = query }
        guard let url = parts.url, url.scheme == base.scheme, url.host == base.host, url.port == base.port, url.user == nil,
              url.path == base.path || url.path.hasPrefix(base.path.hasSuffix("/") ? base.path : base.path + "/") else { return nil }
        return url
    }
    func send(_ method: String, path: String, query: [URLQueryItem] = [], body: Data? = nil, timeout: TimeInterval = 60) async throws -> BuddyServiceResponse {
        guard BuddyConnectedServices.baseURL(service.baseURL.absoluteString) != nil, let url = Self.url(service, path: path, query: query) else {
            throw BuddyWorkerFailure(message: "That path would leave \(service.name)’s address, so nothing was sent.", code: "invalid_input")
        }
        var request = URLRequest(url: url); request.httpMethod = method; request.timeoutInterval = timeout
        request.setValue((service.scheme.isEmpty ? "" : service.scheme + " ") + key, forHTTPHeaderField: service.header)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body { request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await Self.session.data(for: request, delegate: NoRedirects())
        guard let http = response as? HTTPURLResponse else { throw BuddyWorkerFailure(message: "\(service.name) gave no answer.") }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields { if let name = name as? String, let value = value as? String { headers[name] = value } }
        return BuddyServiceResponse(status: http.statusCode, headers: headers, data: data)
    }
}

/// `buddy_service_api`: what an agent may ask of a connected service, how it is checked, and what it gets back.
enum BuddyServiceAPI {
    static let toolName = "buddy_service_api"
    static let reads: Set<String> = ["GET", "HEAD"], writes: Set<String> = ["POST", "PUT", "PATCH", "DELETE"]
    /// The most hours an agent may ask a lease to live: a week. A bound on what it types; the person approves each lease's hours.
    static let maxHours = 168.0
    static let bodyLimit = 256 * 1024
    static let guidance = "Connected services: call a web API the user connected (or asks you to use) with buddy_service_api: Buddy adds the user's key, which you never see, and never ask for a key in chat (Buddy asks the user itself). Reading (GET) goes ahead. A change on a service that can charge money goes to the user as one approval card with your reason and your cost estimate; anything it creates that bills over time must carry a lease, so Buddy shuts it down itself (when you release it, when the task ends, and at its hours). Heavy computation can run on a machine such a service rents: get Buddy's public key with buddy_remote_machine publicKey for the create request, then upload, run and download with buddy_remote_machine, and release the lease when you are done."

    static var tool: [String: Any] {
        ["type": "function", "name": toolName,
         "description": "Call the API of a service the user connected to Buddy (for example RunPod), with the user's key, which you never see. action request (the default): method, path (relative to the service's API address; never another host), optional query and JSON body. Returns status, headers (never the key) and body (shortened past 256 KB). GET and HEAD go ahead. POST, PUT, PATCH and DELETE need approval first: on a service the user marked as able to charge money, the user approves one card that shows this exact request, your reason and your cost estimate (for POST, PUT and PATCH, required: costPerHour, or costTotal, with maxHours); on other services the team's supervisor reviews it. Something a request creates that bills over time (a machine, a pod, an instance) must carry lease: resource (the id of what it creates, or a JSON pointer into the response that holds it, such as /id), teardown (method and path that delete it, with {id} for the id, such as DELETE /pods/{id}) and maxHours; list in uploads the project paths you will upload to it with buddy_remote_machine, so the card shows them. Buddy records the lease and runs its teardown itself when you release it, when this task ends, is cancelled or fails, when maxHours pass, and if Buddy restarts; keep this attempt going until your work there runs. A service that isn't connected yet: give its name in service and its API address in baseUrl; Buddy asks the user to connect it and you are resumed when they have (end this attempt then). action services lists the connected services; action leases lists this task's leases; action release (lease_id) tears one down now.",
         "inputSchema": ["type": "object", "additionalProperties": false, "properties": [
            "action": ["type": "string", "enum": ["request", "services", "leases", "release"]],
            "service": ["type": "string", "description": "The service's name, such as RunPod."],
            "method": ["type": "string", "enum": ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE"]],
            "path": ["type": "string", "description": "The path under the service's API address, such as /pods or /pods/abc123."],
            "query": ["type": "object", "description": "Query parameters, as names and values."],
            "body": ["type": "object", "description": "The JSON body."],
            "reason": ["type": "string", "maxLength": 300, "description": "One line the reviewer sees: why the task needs this."],
            "costPerHour": ["type": "number", "minimum": 0, "description": "Your estimate, in US dollars per hour, of what this costs while it exists."],
            "costTotal": ["type": "number", "minimum": 0, "description": "Your estimate, in US dollars, of what this costs in all."],
            "maxHours": ["type": "number", "exclusiveMinimum": 0, "maximum": maxHours, "description": "The most hours it may exist (and be charged for)."],
            "billable": ["type": "boolean", "description": "false only when a POST or PUT on a charging service creates nothing that bills over time (then no lease is needed)."],
            "lease": ["type": "object", "additionalProperties": false, "properties": [
                "resource": ["type": "string", "description": "The id of what this creates, or a JSON pointer into the response that holds it (/id)."],
                "teardown": ["type": "object", "additionalProperties": false, "properties": ["method": ["type": "string", "enum": ["DELETE", "POST", "PUT", "PATCH"]], "path": ["type": "string"]], "required": ["method", "path"]],
                "maxHours": ["type": "number", "exclusiveMinimum": 0, "maximum": maxHours]], "required": ["resource", "teardown"]],
            "uploads": ["type": "array", "items": ["type": "string"], "maxItems": 20, "description": "Project paths you will upload to what this creates (shown on the card)."],
            "baseUrl": ["type": "string", "description": "Only for a service that isn't connected yet: its API address, starting with https://."],
            "lease_id": ["type": "string", "description": "release: the lease to tear down."]], "required": []]]
    }

    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }

    /// A path under a service's address, as an agent gives it: no scheme or host, no `..`, no query or fragment (use query).
    static func path(_ raw: Any?) -> String? {
        guard let text = (raw as? String)?.trimmingCharacters(in: .whitespaces), text.count <= 1000, !text.contains("://"), !text.contains("\\"), !text.contains("?"), !text.contains("#"),
              text.range(of: #"^[A-Za-z0-9\-._~!$&'()*+,;=:@/%{}]*$"#, options: .regularExpression) != nil else { return nil }
        let trimmed = String(text.drop { $0 == "/" })
        let segments = trimmed.split(separator: "/", omittingEmptySubsequences: false).map { ($0.removingPercentEncoding ?? String($0)).lowercased() }
        guard !segments.contains(".."), !segments.contains("."), !trimmed.lowercased().contains("%2f") else { return nil }
        return "/" + trimmed
    }
    static func query(_ raw: Any?) throws -> [URLQueryItem] {
        guard let raw else { return [] }
        guard let object = raw as? [String: Any], object.count <= 50 else { throw Failure(message: "query must be names and values. Nothing was sent.") }
        return try object.keys.sorted().map { name in
            let value = object[name]
            if let text = value as? String { return URLQueryItem(name: name, value: text) }
            if let number = value as? NSNumber { return URLQueryItem(name: name, value: CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "true" : "false") : number.stringValue) }
            throw Failure(message: "query values must be text, numbers or true/false. Nothing was sent.")
        }
    }
    static func number(_ raw: Any?) -> Double? {
        guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite, n.doubleValue >= 0 else { return nil }
        return n.doubleValue
    }
    static func money(_ value: Double) -> String { String(format: "$%.2f", value) }
    static func ceiling(_ value: Double) -> Double { (value * 100 - 1e-9).rounded(.up) / 100 }
    static func hours(_ value: Double) -> String {
        if value < 1 { let m = Int((value * 60).rounded()); return "\(m) minute\(m == 1 ? "" : "s")" }
        return (value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)) + " hour" + (value == 1 ? "" : "s")
    }
    /// The agent's cost estimate, checked: per hour or in all, with the most hours. Returns the card's facts.
    static func cost(_ args: [String: Any], required: Bool) throws -> [String: Any]? {
        let perHour = number(args["costPerHour"]), total = number(args["costTotal"]), hours = number(args["maxHours"]) ?? number((args["lease"] as? [String: Any])?["maxHours"])
        if perHour == nil && total == nil {
            if required { throw Failure(message: "This service can charge money: give your cost estimate as costPerHour (US dollars an hour) or costTotal, and maxHours. Nothing was sent.") }
            return nil
        }
        guard let hours, hours > 0, hours <= maxHours else { throw Failure(message: "Give maxHours: the most hours this may exist, more than 0 and at most \(Int(maxHours)). Nothing was sent.") }
        var out: [String: Any] = ["maxHours": hours]
        if let perHour { out["perHour"] = perHour }
        if let total { out["total"] = total }
        out["maxCostUSD"] = ceiling(max(total ?? 0, (perHour ?? 0) * hours))
        return out
    }
    /// A lease as an agent declares it: what it creates (an id, or a JSON pointer into the response), how to delete it, and its hours.
    static func lease(_ raw: Any?, hours fallback: Double?) throws -> [String: Any]? {
        guard let raw else { return nil }
        guard let lease = raw as? [String: Any], let resource = (lease["resource"] as? String)?.trimmingCharacters(in: .whitespaces), !resource.isEmpty, resource.count <= 300,
              let teardown = lease["teardown"] as? [String: Any], let method = (teardown["method"] as? String)?.uppercased(), writes.contains(method), let path = path(teardown["path"]) else {
            throw Failure(message: "lease needs resource (the created thing's id, or a JSON pointer into the response such as /id) and teardown (method and path that delete it, with {id}, such as DELETE /pods/{id}). Nothing was sent.")
        }
        guard let hours = number(lease["maxHours"]) ?? fallback, hours > 0, hours <= maxHours else { throw Failure(message: "Give the lease's maxHours: more than 0 and at most \(Int(maxHours)). Nothing was sent.") }
        if let fallback, let own = number(lease["maxHours"]), abs(own - fallback) > 1e-9 { throw Failure(message: "maxHours and the lease's maxHours differ; give one. Nothing was sent.") }
        return ["resource": resource, "teardown": ["method": method, "path": path], "maxHours": hours]
    }
    /// The value at a JSON pointer (RFC 6901) in a response, as text, when it is a string or a number.
    static func pointer(_ pointer: String, in value: Any?) -> String? {
        guard pointer.hasPrefix("/") else { return nil }
        var current = value
        for raw in pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
            let token = raw.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            if let object = current as? [String: Any] { current = object[token] }
            else if let list = current as? [Any], let i = Int(token), list.indices.contains(i) { current = list[i] }
            else { return nil }
        }
        if let text = current as? String, !text.isEmpty, text.count <= 200 { return text }
        if let number = current as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.stringValue }
        return nil
    }
    /// Every text and number in a response (up to `limit`): what a machine's address may be checked against.
    static func scalars(_ value: Any?, limit: Int = 400) -> [String] {
        var out: [String] = []
        func walk(_ v: Any?) {
            guard out.count < limit else { return }
            if let text = v as? String { if !text.isEmpty, text.count <= 300 { out.append(text) } }
            else if let number = v as? NSNumber { if CFGetTypeID(number) != CFBooleanGetTypeID() { out.append(number.stringValue) } }
            else if let object = v as? [String: Any] { for key in object.keys.sorted() { walk(object[key]) } }
            else if let list = v as? [Any] { for item in list { walk(item) } }
        }
        walk(value); return out
    }
    /// A response as the agent gets it: never the key, the key's header or a cookie; a JSON body as JSON, other text cut at 64 KB.
    static func reply(_ response: BuddyServiceResponse, service: BuddyConnectedService, key: String) -> [String: Any] {
        func clean(_ text: String) -> String { key.count >= 4 ? text.replacingOccurrences(of: key, with: "[key]") : text }
        let hidden: Set<String> = ["authorization", "proxy-authorization", "cookie", "set-cookie", service.header.lowercased()]
        var headers: [String: String] = [:]
        for (name, value) in response.headers where !hidden.contains(name.lowercased()) { headers[name] = clean(value) }
        var out: [String: Any] = ["status": response.status, "headers": headers, "bytes": response.data.count]
        let shown = response.data.prefix(bodyLimit), text = clean(String(decoding: shown, as: UTF8.self))
        if response.data.count <= bodyLimit, let json = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) { out["body"] = json }
        else if !response.data.isEmpty { out["body"] = String(text.prefix(64 * 1024)); if response.data.count > 64 * 1024 { out["truncated"] = true } }
        return out
    }
    /// The body as JSON the request carries, and as the card shows it (pretty, cut at 4,000 characters).
    static func body(_ raw: Any?) throws -> (data: Data?, shown: String) {
        guard let raw, !(raw is NSNull) else { return (nil, "") }
        guard JSONSerialization.isValidJSONObject(raw), let data = try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys]), data.count <= bodyLimit else {
            throw Failure(message: "body must be a JSON object under 256 KB. Nothing was sent.")
        }
        let pretty = (try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys, .prettyPrinted])).map { String(decoding: $0, as: UTF8.self) } ?? ""
        return (data, pretty.count > 4000 ? String(pretty.prefix(3999)) + "…" : pretty)
    }
}
