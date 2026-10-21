import Foundation

/// Which coding commands that leave the sandbox (network access, or a Codex escalation) the team's supervisor may approve in the person's place.
/// It is deliberately narrow: a command is ROUTINE only when every part of it is one of a few shapes Buddy can read word for word — a plain
/// download from a public http(s) site into the project (curl or wget, GET only), a package install into the project or its own virtual
/// environment (pip/uv with a project target or venv, npm/pnpm/yarn in the project), a clone or fetch of a public repository into the project,
/// and making folders in the project. Everything else is SENSITIVE and stays with the person: anything that can send data out (uploads, POST,
/// headers, cookies, git push, ssh/scp/rsync, mail, nc, webhooks), a saved sign-in, reading secrets, writing outside the project, installing
/// system-wide, sudo, a private or local address, and any command it cannot take apart with confidence (pipes, redirections, variables,
/// substitutions, globs, other separators, options it does not know).
enum BuddyCommandReview {
    struct Verdict {
        let routine: Bool
        /// In plain words: what the command does (routine), or why it stays with the person.
        let reason: String
        let hosts: [String]
        /// Where it writes, relative to the project ("." for the project itself).
        let writes: [String]
    }
    static func sensitive(_ reason: String, hosts: [String] = []) -> Verdict { Verdict(routine: false, reason: reason, hosts: hosts, writes: []) }

    static let sendsOut = "It can send data out of this Mac (an upload, a POST, headers or cookies, git push, ssh/scp/rsync, mail or a raw connection)."
    static let readsSecrets = "It reads secrets (keys, tokens, passwords, sign-in or environment files)."
    static let unclear = "Buddy cannot tell exactly what this command does, so you decide."

    /// The verdict on `command`, run at `project` (the coding task's own copy). A command with a saved sign-in is never routine.
    static func assess(_ command: String, project: String, credential: Bool = false) -> Verdict {
        if credential { return sensitive("It signs in with your saved sign-in.") }
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 4000 else { return sensitive(unclear) }
        let lowered = text.lowercased()
        if secretMarks.contains(where: { lowered.contains($0) }) { return sensitive(readsSecrets) }
        guard var segments = words(text) else { return sensitive(unclear) }
        // One shell wrapper, as Codex sends its commands: /bin/zsh -lc '<script>'.
        if segments.count == 1, let script = unwrapped(segments[0]) {
            guard let inner = words(script) else { return sensitive(unclear) }
            segments = inner
        }
        let root = URL(fileURLWithPath: project).resolvingSymlinksInPath().standardizedFileURL
        var hosts: [String] = [], writes: [String] = [], kinds: [String] = [], downloads: [Part] = []
        for segment in segments {
            switch simple(segment, root: root) {
            case .failure(let refusal): return sensitive(refusal.reason, hosts: hosts)
            case .success(let part):
                hosts += part.hosts; writes += part.writes
                if part.kind.hasPrefix("a download from ") { downloads.append(part) } else if part.kind != "folder" { kinds.append(part.kind) }
            }
        }
        func unique(_ list: [String]) -> [String] { Array(NSOrderedSet(array: list)) as? [String] ?? list }
        let uniqueHosts = unique(hosts), uniqueWrites = unique(writes)
        // Several downloads read as one phrase ("3 downloads from arxiv.org and iop.org into the project"), so the person sees one line.
        let files = downloads.reduce(0) { $0 + max(1, $1.hosts.count) }
        let fetched: [String] = files == 1 ? [downloads[0].kind] : files > 1 ? ["\(files) downloads from \(listed(unique(downloads.flatMap(\.hosts)))) into the project"] : []
        let what = fetched + unique(kinds)
        let summary = what.isEmpty ? "It only makes folders in the project." : what.joined(separator: "; ")
        return Verdict(routine: true, reason: summary.prefix(1).uppercased() + summary.dropFirst() + (summary.hasSuffix(".") ? "" : "."), hosts: uniqueHosts, writes: uniqueWrites)
    }

    /// "a", "a and b", "a, b and c".
    static func listed(_ items: [String]) -> String { items.count <= 2 ? items.joined(separator: " and ") : items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1] }

    static let secretMarks = [".ssh", "id_rsa", "id_ed25519", "id_ecdsa", ".pgpass", ".netrc", ".aws", ".env", ".npmrc", ".pypirc", ".git-credentials", ".docker/config", "keychain",
                              "security find", "token", "password", "passwd", "secret", "credential", "api_key", "apikey", "pgpassword", "/etc/", "library/application support"]

    // MARK: reading the words

    /// The command as simple commands joined by `&&`, `;` or a new line (each one is judged on its own, so running one after another is no
    /// riskier than one at a time), each a list of words, or nil when it uses anything else of the shell (pipes, redirections, `||`,
    /// background `&`, substitutions, variables, globs, history, comments, a backslash) or leaves a quote open.
    static func words(_ text: String) -> [[String]]? {
        var segments: [[String]] = [], current: [String] = [], word = "", started = false
        var single = false, double = false
        let chars = Array(text)
        var i = 0
        func endWord() { if started { current.append(word) }; word = ""; started = false }
        while i < chars.count {
            let c = chars[i]
            if c == "\r" || c == "\0" { return nil }
            if single { if c == "'" { single = false } else { word.append(c) }; i += 1; continue }
            if double {
                if c == "\"" { double = false } else if "$`\\!".contains(c) { return nil } else { word.append(c) }
                i += 1; continue
            }
            switch c {
            case " ", "\t": endWord()
            case "'": single = true; started = true
            case "\"": double = true; started = true
            case "&":
                guard i + 1 < chars.count, chars[i + 1] == "&" else { return nil }
                endWord(); guard !current.isEmpty else { return nil }
                segments.append(current); current = []; i += 1
            case "\n", ";":
                // Codex writes several commands as lines of one script. A blank line, or a line break after `&&`, adds nothing.
                endWord(); if !current.isEmpty { segments.append(current); current = [] }
            default:
                if "|<>()$`{}*?[]!~#\\^".contains(c) { return nil }
                word.append(c); started = true
            }
            i += 1
        }
        guard !single, !double else { return nil }
        endWord()
        guard !current.isEmpty else { return nil }
        segments.append(current)
        return segments
    }
    /// The script of `zsh|bash|sh [-l] -c '<script>'` (with or without /bin/), else nil.
    static func unwrapped(_ words: [String]) -> String? {
        guard let first = words.first, ["zsh", "/bin/zsh", "bash", "/bin/bash", "sh", "/bin/sh"].contains(first) else { return nil }
        let flags = Array(words.dropFirst().dropLast())
        guard words.count >= 3, flags == ["-c"] || flags == ["-lc"] || flags == ["-l", "-c"] else { return nil }
        return words.last
    }

    // MARK: one simple command

    struct Part { var kind: String, hosts: [String] = [], writes: [String] = [] }
    struct Refusal: Error { let reason: String }
    private static func refuse(_ reason: String = unclear) -> Result<Part, Refusal> { .failure(Refusal(reason: reason)) }

    /// The program a word names, if it is one Buddy reads here: a bare name or one in the system's program folders.
    private static func program(_ word: String) -> String? {
        let name = (word as NSString).lastPathComponent
        if !word.contains("/") { return name }
        let folder = (word as NSString).deletingLastPathComponent
        return ["/usr/bin", "/bin", "/usr/local/bin", "/opt/homebrew/bin"].contains(folder) ? name : nil
    }
    private static func simple(_ w: [String], root: URL) -> Result<Part, Refusal> {
        guard let head = w.first else { return refuse() }
        if head.contains("=") { return refuse() }   // VAR=value before a command changes what it does
        if let name = program(head) {
            switch name {
            case "sudo", "doas", "su", "brew", "port", "softwareupdate", "installer", "launchctl", "defaults", "osascript": return refuse("It changes this Mac outside the project (sudo, system installs or settings).")
            case "ssh", "scp", "sftp", "rsync", "ftp", "mail", "mailx", "sendmail", "mutt", "nc", "ncat", "netcat", "telnet", "socat": return refuse(sendsOut)
            case "curl": return curl(Array(w.dropFirst()), root: root)
            case "wget": return wget(Array(w.dropFirst()), root: root)
            case "git": return git(Array(w.dropFirst()), root: root)
            case "pip", "pip3": return pip(Array(w.dropFirst()), root: root, venv: false)
            case "python", "python3":
                guard w.count >= 3, w[1] == "-m", w[2] == "pip" else { return refuse() }
                return pip(Array(w.dropFirst(3)), root: root, venv: false)
            case "uv": return uv(Array(w.dropFirst()), root: root)
            case "npm", "pnpm", "yarn": return node(name, Array(w.dropFirst()), root: root)
            case "mkdir": return mkdir(Array(w.dropFirst()), root: root)
            default: return refuse()
            }
        }
        // A project virtual environment's own pip or python: <venv>/bin/pip install …, <venv>/bin/python -m pip install …
        guard let path = inside(head, root: root), path.hasSuffix("/bin/" + (head as NSString).lastPathComponent) else { return refuse() }
        let name = (head as NSString).lastPathComponent
        if ["pip", "pip3"].contains(name) { return pip(Array(w.dropFirst()), root: root, venv: true) }
        if ["python", "python3"].contains(name), w.count >= 3, w[1] == "-m", w[2] == "pip" { return pip(Array(w.dropFirst(3)), root: root, venv: true) }
        return refuse()
    }

    // MARK: places

    /// `path` as a path relative to the project if it stays inside it (after following links), else nil.
    static func inside(_ path: String, root: URL) -> String? {
        guard !path.isEmpty, !path.hasPrefix("~"), !path.hasPrefix("-") else { return nil }
        let url = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)).standardizedFileURL
        // Links are followed for the part that exists, so a link in the project that points elsewhere does not count as inside.
        var existing = url, rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" { rest.insert(existing.lastPathComponent, at: 0); existing = existing.deletingLastPathComponent() }
        var resolved = existing.resolvingSymlinksInPath().standardizedFileURL
        for part in rest { resolved.appendPathComponent(part) }
        let full = resolved.standardizedFileURL.path, base = root.path
        guard full == base || full.hasPrefix(base + "/") else { return nil }
        return full == base ? "." : String(full.dropFirst(base.count + 1))
    }
    static let privateSuffixes = [".local", ".localhost", ".internal", ".lan", ".home", ".corp", ".intranet", ".test", ".invalid", ".example"]
    static let webhookMarks = ["webhook", "hooks.slack.com", "hooks.zapier.com", "maker.ifttt.com", "requestbin", "pipedream", "ngrok", "beeceptor", "requestcatcher", "/api/webhooks"]
    /// The host of a public http(s) address that only reads (no sign-in in it, no long query, no webhook), else the reason it is not one.
    static func publicHost(_ text: String) -> Result<String, Refusal> {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), let host = url.host?.lowercased(), !host.isEmpty else { return .failure(Refusal(reason: unclear)) }
        if url.user != nil || url.password != nil || text.lowercased().contains("@") && text.range(of: "://[^/]*@", options: .regularExpression) != nil { return .failure(Refusal(reason: "It puts a sign-in into the web address.")) }
        if webhookMarks.contains(where: { text.lowercased().contains($0) }) { return .failure(Refusal(reason: sendsOut)) }
        if (url.query ?? "").count > 200 { return .failure(Refusal(reason: sendsOut)) }
        if text.contains("[") || text.contains("]") || text.contains("{") || text.contains("}") { return .failure(Refusal(reason: unclear)) }
        let numeric = host.allSatisfy { $0.isNumber || $0 == "." } || host.contains(":")
        guard !numeric, host.contains("."), host != "localhost", !privateSuffixes.contains(where: { host.hasSuffix($0) }) else { return .failure(Refusal(reason: "It reaches a local or private address Buddy cannot check is public.")) }
        return .success(host)
    }

    // MARK: downloads

    private static func curl(_ args: [String], root: URL) -> Result<Part, Refusal> {
        let plain: Set<String> = ["-f", "--fail", "--fail-with-body", "-L", "--location", "-s", "--silent", "-S", "--show-error", "-O", "--remote-name", "--remote-name-all", "--create-dirs",
                                  "--compressed", "-#", "--progress-bar", "--no-progress-meter", "--retry-all-errors", "--http1.1", "--http2", "-4", "-6"]
        let valued: Set<String> = ["-o", "--output", "--output-dir", "--retry", "--retry-delay", "--retry-max-time", "-m", "--max-time", "--connect-timeout", "-C", "--continue-at", "-A", "--user-agent"]
        let sending: Set<String> = ["-d", "--data", "--data-raw", "--data-binary", "--data-urlencode", "--data-ascii", "-F", "--form", "--form-string", "-T", "--upload-file", "-X", "--request", "--json",
                                    "-H", "--header", "-b", "--cookie", "-c", "--cookie-jar", "-u", "--user", "-e", "--referer", "--oauth2-bearer", "-E", "--cert", "--key", "-K", "--config", "-x", "--proxy"]
        var outputs: [String] = [], urls: [String] = [], remoteName = false, folder: String?
        var i = 0
        func value(_ option: String) -> String? { if i + 1 < args.count { i += 1; return args[i] }; return nil }
        func take(_ option: String, _ given: String?) -> Refusal? {
            guard let given else { return Refusal(reason: unclear) }
            switch option {
            case "-o", "--output": outputs.append(given)
            case "--output-dir": folder = given
            case "-C", "--continue-at": if given != "-" && Int(given) == nil { return Refusal(reason: unclear) }
            case "-A", "--user-agent": break
            default: if Double(given) == nil { return Refusal(reason: unclear) }
            }
            return nil
        }
        while i < args.count {
            let a = args[i]
            if a.hasPrefix("--") {
                let parts = a.split(separator: "=", maxSplits: 1).map(String.init), option = parts[0]
                if sending.contains(option) { return refuse(sendsOut) }
                if plain.contains(option), parts.count == 1 { if option == "--remote-name" || option == "--remote-name-all" { remoteName = true } }
                else if valued.contains(option) { if let r = take(option, parts.count == 2 ? parts[1] : value(option)) { return .failure(r) } }
                else { return refuse() }
            } else if a.hasPrefix("-"), a.count > 1 {
                let letters = Array(a.dropFirst())
                var j = 0
                while j < letters.count {
                    let flag = "-" + String(letters[j])
                    if sending.contains(flag) { return refuse(sendsOut) }
                    if plain.contains(flag) { if flag == "-O" { remoteName = true }; j += 1; continue }
                    guard valued.contains(flag) else { return refuse() }
                    let attached = j + 1 < letters.count ? String(letters[(j + 1)...]) : nil
                    if let r = take(flag, attached ?? value(flag)) { return .failure(r) }
                    j = letters.count
                }
            } else { urls.append(a) }
            i += 1
        }
        guard !urls.isEmpty else { return refuse() }
        var hosts: [String] = []
        for url in urls { switch publicHost(url) { case .success(let h): hosts.append(h); case .failure(let r): return .failure(r) } }
        var writes: [String] = []
        let base = folder ?? "."
        if folder != nil, inside(base, root: root) == nil { return refuse("It writes outside the project.") }
        for output in outputs where output != "-" {
            let path = output.hasPrefix("/") || folder == nil ? output : (base as NSString).appendingPathComponent(output)
            guard let place = inside(path, root: root) else { return refuse("It writes outside the project.") }
            writes.append(place)
        }
        if remoteName {
            for url in urls.dropFirst(outputs.count) {
                let name = URL(string: url)?.lastPathComponent ?? ""
                guard !name.isEmpty, name != "/", let place = inside((base as NSString).appendingPathComponent(name), root: root) else { return refuse("It writes outside the project.") }
                writes.append(place)
            }
        }
        return .success(Part(kind: "a download from " + hosts.joined(separator: ", ") + (writes.isEmpty ? " (shown, not saved)" : " into the project"), hosts: hosts, writes: writes))
    }
    private static func wget(_ args: [String], root: URL) -> Result<Part, Refusal> {
        let plain: Set<String> = ["-q", "--quiet", "-nv", "--no-verbose", "-c", "--continue", "-nc", "--no-clobber", "-N", "--timestamping", "--show-progress", "-4", "-6", "--retry-connrefused"]
        let valued: Set<String> = ["-O", "--output-document", "-P", "--directory-prefix", "-t", "--tries", "-T", "--timeout", "--progress", "--wait"]
        var output: String?, folder: String?, urls: [String] = []
        var i = 0
        while i < args.count {
            let a = args[i]
            let parts = a.hasPrefix("--") ? a.split(separator: "=", maxSplits: 1).map(String.init) : [a]
            let option = parts[0]
            if ["--post-data", "--post-file", "--method", "--body-data", "--body-file", "--header", "--user", "--password", "--http-user", "--http-password", "--load-cookies", "-e", "--execute", "-i", "--input-file", "-r", "--recursive", "-m", "--mirror"].contains(option) { return refuse(option.hasPrefix("--post") || option == "--method" || option.hasPrefix("--body") || option == "--header" ? sendsOut : unclear) }
            if plain.contains(option), parts.count == 1 { i += 1; continue }
            if valued.contains(option) {
                var given = parts.count == 2 ? parts[1] : nil
                if given == nil { guard i + 1 < args.count else { return refuse() }; i += 1; given = args[i] }
                switch option { case "-O", "--output-document": output = given; case "-P", "--directory-prefix": folder = given; default: break }
                i += 1; continue
            }
            if option.hasPrefix("-") { return refuse() }
            urls.append(a); i += 1
        }
        guard !urls.isEmpty else { return refuse() }
        var hosts: [String] = []
        for url in urls { switch publicHost(url) { case .success(let h): hosts.append(h); case .failure(let r): return .failure(r) } }
        var writes: [String] = []
        if let output, output != "-" { guard let place = inside(output, root: root) else { return refuse("It writes outside the project.") }; writes.append(place) }
        else if output == nil {
            for url in urls {
                let name = URL(string: url)?.lastPathComponent ?? ""
                guard let place = inside(((folder ?? ".") as NSString).appendingPathComponent(name.isEmpty || name == "/" ? "index.html" : name), root: root) else { return refuse("It writes outside the project.") }
                writes.append(place)
            }
        }
        return .success(Part(kind: "a download from " + hosts.joined(separator: ", ") + " into the project", hosts: hosts, writes: writes))
    }

    // MARK: repositories and packages

    private static func git(_ args: [String], root: URL) -> Result<Part, Refusal> {
        guard let sub = args.first else { return refuse() }
        if sub == "push" || sub == "send-email" || sub == "request-pull" { return refuse(sendsOut) }
        guard sub == "clone" || sub == "fetch" else { return refuse() }
        let plain: Set<String> = ["-q", "--quiet", "--single-branch", "--no-single-branch", "--no-tags", "--tags", "--prune"]
        let valued: Set<String> = ["--depth", "-b", "--branch", "--filter"]
        var positional: [String] = []
        var i = 1
        while i < args.count {
            let a = args[i]
            let parts = a.hasPrefix("--") ? a.split(separator: "=", maxSplits: 1).map(String.init) : [a]
            if plain.contains(parts[0]), parts.count == 1 { i += 1; continue }
            if valued.contains(parts[0]) { if parts.count == 1 { guard i + 1 < args.count else { return refuse() }; i += 1 }; i += 1; continue }
            if a.hasPrefix("-") { return refuse() }
            positional.append(a); i += 1
        }
        guard let address = positional.first else { return refuse() }
        let host: String
        switch publicHost(address) { case .success(let h): host = h; case .failure(let r): return .failure(r) }
        if sub == "fetch" {
            guard inside(".git", root: root) != nil else { return refuse() }
            return .success(Part(kind: "a fetch of a public repository from \(host) into the project", hosts: [host], writes: [".git"]))
        }
        guard positional.count <= 2 else { return refuse() }
        let name = ((URL(string: address)?.lastPathComponent ?? "") as NSString).deletingPathExtension
        guard let place = inside(positional.count == 2 ? positional[1] : name, root: root), !name.isEmpty || positional.count == 2 else { return refuse("It writes outside the project.") }
        return .success(Part(kind: "a clone of a public repository from \(host) into the project", hosts: [host], writes: [place]))
    }
    private static let packageFlags: Set<String> = ["-U", "--upgrade", "--no-deps", "-q", "--quiet", "--no-cache-dir", "--disable-pip-version-check", "--prefer-binary", "--no-input", "--pre",
                                                    "--force-reinstall", "--no-warn-script-location", "--no-build-isolation", "--compile", "--no-compile"]
    private static let packageValues: Set<String> = ["-t", "--target", "-r", "--requirement", "-c", "--constraint", "--upgrade-strategy", "--only-binary", "--no-binary", "--python", "-p"]
    /// A package as written to an installer: a name with an optional version or extras, a public address, or a path in the project.
    private static func package(_ word: String, root: URL) -> Result<String?, Refusal> {
        if word.contains("://") {
            let address = word.hasPrefix("git+") ? String(word.dropFirst(4)) : word
            switch publicHost(address) { case .success(let h): return .success(h); case .failure(let r): return .failure(r) }
        }
        if word.contains("/") || word.hasPrefix(".") || word.hasPrefix("file:") { return inside(word, root: root) == nil || word.hasPrefix("file:") ? .failure(Refusal(reason: "It installs from a place outside the project.")) : .success(nil) }
        guard word.range(of: #"^@?[A-Za-z0-9][A-Za-z0-9._\-]*(/[A-Za-z0-9._\-]+)?(\[[A-Za-z0-9,._\-]+\])?([<>=!~^@][A-Za-z0-9.*,<>=!~^_\-]*)?$"#, options: .regularExpression) != nil else { return .failure(Refusal(reason: unclear)) }
        return .success(nil)
    }
    private static func pip(_ args: [String], root: URL, venv: Bool) -> Result<Part, Refusal> {
        guard args.first == "install" else { return refuse() }
        var target: String?, i = 1, named = 0
        while i < args.count {
            let a = args[i], parts = a.hasPrefix("--") ? a.split(separator: "=", maxSplits: 1).map(String.init) : [a], option = parts[0]
            if ["--user", "--prefix", "--root", "--system", "--break-system-packages", "--src", "-e", "--editable", "--trusted-host", "--extra-index-url", "-i", "--index-url", "--global-option", "--config-settings"].contains(option) {
                return refuse(["--user", "--prefix", "--root", "--system", "--break-system-packages"].contains(option) ? "It installs outside the project (for the whole Mac or your account)." : unclear)
            }
            if packageFlags.contains(option), parts.count == 1 { i += 1; continue }
            if packageValues.contains(option), option != "--python", option != "-p" {
                var given = parts.count == 2 ? parts[1] : nil
                if given == nil { guard i + 1 < args.count else { return refuse() }; i += 1; given = args[i] }
                if ["-t", "--target", "-r", "--requirement", "-c", "--constraint"].contains(option) {
                    guard let place = inside(given ?? "", root: root) else { return refuse(option == "-t" || option == "--target" ? "It installs outside the project." : "It installs from a place outside the project.") }
                    if option == "-t" || option == "--target" { target = place } else { named += 1 }
                }
                i += 1; continue
            }
            if a.hasPrefix("-") { return refuse() }
            switch package(a, root: root) { case .failure(let r): return .failure(r); case .success: named += 1 }
            i += 1
        }
        guard named > 0 else { return refuse() }
        guard venv || target != nil else { return refuse("It installs outside the project (for the whole Mac or your account).") }
        return .success(Part(kind: "a package install into the project", hosts: ["pypi.org"], writes: [target ?? "its virtual environment"]))
    }
    private static func uv(_ args: [String], root: URL) -> Result<Part, Refusal> {
        guard let sub = args.first else { return refuse() }
        if sub == "pip" {
            guard args.count >= 2, args[1] == "install" else { return refuse() }
            var rest = Array(args.dropFirst(2)), python: String?
            if let at = rest.firstIndex(where: { $0 == "--python" || $0 == "-p" }) { guard at + 1 < rest.count else { return refuse() }; python = rest[at + 1]; rest.removeSubrange(at...(at + 1)) }
            if let python { guard let place = inside(python, root: root), place.contains("/bin/") else { return refuse("It installs outside the project.") } }
            let hasTarget = rest.contains { $0 == "-t" || $0 == "--target" || $0.hasPrefix("--target=") }
            let projectVenv = FileManager.default.fileExists(atPath: root.appendingPathComponent(".venv/bin/python").path)
            return pip(["install"] + rest, root: root, venv: python != nil || (!hasTarget && projectVenv))
        }
        guard ["sync", "add"].contains(sub) else { return refuse() }
        var named = 0
        for a in args.dropFirst() {
            if ["--frozen", "--locked", "-q", "--quiet", "--no-dev", "--dev", "--all-extras"].contains(a) { continue }
            if a.hasPrefix("-") { return refuse() }
            guard sub == "add" else { return refuse() }
            switch package(a, root: root) { case .failure(let r): return .failure(r); case .success: named += 1 }
        }
        if sub == "add", named == 0 { return refuse() }
        return .success(Part(kind: "a package install into the project", hosts: ["pypi.org"], writes: [".venv"]))
    }
    private static func node(_ tool: String, _ args: [String], root: URL) -> Result<Part, Refusal> {
        let verbs: Set<String> = tool == "npm" ? ["install", "i", "ci", "add"] : tool == "pnpm" ? ["install", "i", "add"] : ["install", "add"]
        var rest = args
        if !(tool == "yarn" && rest.isEmpty) {
            guard let sub = rest.first, verbs.contains(sub) else { return refuse() }
            rest.removeFirst()
        }
        let flags: Set<String> = ["-D", "--save-dev", "-S", "--save", "-E", "--save-exact", "--no-save", "--no-audit", "--no-fund", "--silent", "-s", "--ignore-scripts", "--legacy-peer-deps",
                                  "--prefer-offline", "--frozen-lockfile", "--immutable", "--dev", "--exact"]
        for a in rest {
            if ["-g", "--global", "--location=global", "--prefix", "-C", "--dir", "--cwd", "--registry", "--userconfig", "--globalconfig"].contains(a) || a.hasPrefix("--prefix=") || a.hasPrefix("--registry=") || a.hasPrefix("--location") {
                return refuse(a == "-g" || a.hasPrefix("--global") || a.hasPrefix("--location") ? "It installs outside the project (for the whole Mac or your account)." : unclear)
            }
            if flags.contains(a) { continue }
            if a.hasPrefix("-") { return refuse() }
            if case .failure(let r) = package(a, root: root) { return .failure(r) }
        }
        return .success(Part(kind: "a package install into the project", hosts: [tool == "npm" ? "registry.npmjs.org" : tool == "pnpm" ? "registry.npmjs.org" : "registry.yarnpkg.com"], writes: ["node_modules"]))
    }
    private static func mkdir(_ args: [String], root: URL) -> Result<Part, Refusal> {
        var writes: [String] = []
        for a in args {
            if a == "-p" { continue }
            if a.hasPrefix("-") { return refuse() }
            guard let place = inside(a, root: root) else { return refuse("It writes outside the project.") }
            writes.append(place)
        }
        guard !writes.isEmpty else { return refuse() }
        return .success(Part(kind: "folder", writes: writes))
    }
}
