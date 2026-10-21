import CryptoKit
import Foundation

/// Which coding commands that leave the sandbox (network access, or a Codex escalation) the team's supervisor may approve in the person's place.
/// It is deliberately narrow: a command is ROUTINE only when every part of it is one of a few shapes Buddy can read word for word — a plain
/// download from a public http(s) site into the project (curl or wget, GET only), a package install into the project or its own virtual
/// environment (pip/uv with a project target or venv, npm/pnpm/yarn in the project), a clone or fetch of a public repository into the project,
/// a look at running processes (pgrep, ps) and making folders in the project. A command whose every part runs PROJECT SCRIPTS with a local
/// interpreter is a SCRIPT command: Buddy reads each script (see `run` and `screen`) and the supervisor reads them again before it may run.
/// Everything else is SENSITIVE and stays with the person: anything that can send data out (uploads, POST, headers, cookies, git push,
/// ssh/scp/rsync, mail, nc, webhooks), a saved sign-in, reading secrets, writing outside the project, installing system-wide, sudo, a private or
/// local address, a script whose contents plainly do one of those, and any command it cannot take apart with confidence (pipes, redirections,
/// variables, substitutions, globs, other separators, options it does not know).
enum BuddyCommandReview {
    /// A project script a command runs, as Buddy read it when the review opened.
    struct Script {
        /// Where it is, relative to the project root; for code given in the command itself, what it is ("inline Python code").
        let path: String
        let sha256: String
        let bytes: Int
        /// Code given in the command itself (`python3 -c '…'`): the approval is for that exact text, so it cannot change after the review.
        var inline = false
        var code: String?
        var record: [String: Any] {
            var r: [String: Any] = ["path": path, "sha256": sha256, "bytes": bytes]
            if inline { r["inline"] = true; r["code"] = code ?? "" }
            return r
        }
    }
    struct Verdict {
        let routine: Bool
        /// In plain words: what the command does (routine, script), or why it stays with the person.
        let reason: String
        let hosts: [String]
        /// Where it writes, relative to the project ("." for the project itself).
        let writes: [String]
        /// Every part runs project scripts Buddy read and found nothing on the person's list in: the supervisor reads them and decides.
        var script = false
        /// The scripts it runs, as read (also kept when a script's contents sent the command to the person, so the page can name them).
        var scripts: [Script] = []
        /// What it runs, in plain words ("Runs the project scripts a.py and b.py."), when it runs project scripts.
        var runs = ""
        var kind: String { routine ? "routine" : script ? "script" : "sensitive" }
    }
    static func sensitive(_ reason: String, hosts: [String] = []) -> Verdict { Verdict(routine: false, reason: reason, hosts: hosts, writes: []) }

    static let sendsOut = "It can send data out of this Mac (an upload, a POST, headers or cookies, git push, ssh/scp/rsync, mail or a raw connection)."
    static let readsSecrets = "It reads secrets (keys, tokens, passwords, sign-in or environment files)."
    static let unclear = "Buddy cannot tell exactly what this command does, so you decide."
    /// What the agent is told when a script it asked to run is no longer what was reviewed.
    static let changedAfterReview = "The script changed after it was reviewed; it did not run."
    /// The most Buddy reads of one script, and the most scripts it reads for one command.
    static let scriptLimit = 64 * 1024, maxScripts = 4
    static let processes = "a look at running processes"

    /// The verdict on `command`, run at `project` (the coding task's own copy), in `cwd` when the command says it runs in a folder of its own
    /// (it must lie inside the project; paths are then read from there). A command with a saved sign-in is never routine.
    static func assess(_ command: String, project: String, cwd: String? = nil, credential: Bool = false) -> Verdict {
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
        let project = URL(fileURLWithPath: project).resolvingSymlinksInPath().standardizedFileURL
        var root = project, prefix = ""
        if let cwd, !cwd.isEmpty {
            guard let place = inside(cwd, root: project) else { return sensitive("It runs outside the project folder.") }
            if place != "." { root = project.appendingPathComponent(place, isDirectory: true); prefix = place + "/" }
        }
        var hosts: [String] = [], writes: [String] = [], kinds: [String] = [], downloads: [Part] = [], scripts: [Loaded] = []
        for segment in segments {
            switch simple(segment, root: root) {
            case .failure(let refusal): return sensitive(refusal.reason, hosts: hosts)
            case .success(let part):
                hosts += part.hosts; writes += part.writes; scripts += part.scripts
                if part.kind == "script" { continue }
                if part.kind.hasPrefix("a download from ") { downloads.append(part) } else if part.kind != "folder" { kinds.append(part.kind) }
            }
        }
        func unique(_ list: [String]) -> [String] { Array(NSOrderedSet(array: list)) as? [String] ?? list }
        let uniqueHosts = unique(hosts), uniqueWrites = unique(writes)
        if !scripts.isEmpty {
            // Scripts beside folders or a look at processes only; a download or an install beside them is more than one read covers.
            guard downloads.isEmpty, kinds.allSatisfy({ $0 == processes }) else { return sensitive(unclear) }
            return scripted(scripts, writes: uniqueWrites, project: project, root: root, prefix: prefix)
        }
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
                // A `?` inside a web address (an unquoted query such as papers.cfm?abstract_id=1) is part of the address: no file path starts
                // with "http", so it can't match anything as a wildcard. Anywhere else it is still refused.
                if c == "?", word.lowercased().hasPrefix("http://") || word.lowercased().hasPrefix("https://") { word.append(c); started = true; i += 1; continue }
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

    struct Part { var kind: String, hosts: [String] = [], writes: [String] = [], scripts: [Loaded] = [] }
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
            case "uv": return uv(Array(w.dropFirst()), root: root)
            case "npm", "pnpm", "yarn": return node(name, Array(w.dropFirst()), root: root)
            case "mkdir": return mkdir(Array(w.dropFirst()), root: root)
            case "pgrep": return pgrep(Array(w.dropFirst()))
            case "ps": return ps(Array(w.dropFirst()))
            default:
                guard let tool = interpreter(head, root: root) else { return refuse() }
                if tool == "python", w.count >= 3, w[1] == "-m", w[2] == "pip" { return pip(Array(w.dropFirst(3)), root: root, venv: false) }
                return run(w, root: root)
            }
        }
        // A project virtual environment's own pip or python: <venv>/bin/pip install …, <venv>/bin/python -m pip install …, <venv>/bin/python x.py.
        let name = (head as NSString).lastPathComponent
        if let bin = inside((head as NSString).deletingLastPathComponent, root: root), bin == "bin" || bin.hasSuffix("/bin") {
            if ["pip", "pip3"].contains(name) { return pip(Array(w.dropFirst()), root: root, venv: true) }
            if interpreter(head, root: root) == "python" {
                if w.count >= 3, w[1] == "-m", w[2] == "pip" { return pip(Array(w.dropFirst(3)), root: root, venv: true) }
                return run(w, root: root)
            }
        }
        // A project file run directly: ./x.py, stages/…/x.sh.
        if head.contains("/") { return run(w, root: root) }
        return refuse()
    }

    // MARK: places

    /// `path` as a path relative to the project if it stays inside it (after following links), else nil. A relative path is read from `from`
    /// (a folder in the project; the project itself when nil).
    static func inside(_ path: String, root: URL, from: URL? = nil) -> String? {
        guard !path.isEmpty, !path.hasPrefix("~"), !path.hasPrefix("-") else { return nil }
        let url = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : (from ?? root).appendingPathComponent(path)).standardizedFileURL
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

    // MARK: running processes

    /// pgrep with flags that only list (pkill is another program; -F reads a file).
    private static func pgrep(_ args: [String]) -> Result<Part, Refusal> {
        var i = 0
        while i < args.count {
            let a = args[i]
            if a.hasPrefix("-"), a.count > 1 {
                if ["-u", "-U", "-g", "-G", "-P", "-t", "-s", "-d"].contains(a) { guard i + 1 < args.count else { return refuse() }; i += 2; continue }
                guard a.dropFirst().allSatisfy({ "aflinoqvxLS".contains($0) }) else { return refuse() }
            }
            i += 1
        }
        return .success(Part(kind: processes))
    }
    /// ps with flags that only list: never e or E (on this Mac and its BSD relatives they show each process's environment, which can hold secrets).
    private static func ps(_ args: [String]) -> Result<Part, Refusal> {
        var i = 0
        while i < args.count {
            let a = args[i], dashed = a.hasPrefix("-")
            let letters = dashed ? String(a.dropFirst()) : i == 0 ? a : ""
            guard !letters.isEmpty else { return refuse() }
            if dashed, ["o", "O", "p", "U", "u", "G", "g", "t"].contains(letters) {
                guard i + 1 < args.count, !args[i + 1].lowercased().contains("env") else { return refuse() }
                i += 2; continue
            }
            // `u` is the user format only in the old style without a dash (`ps aux`); with a dash it takes a user.
            guard letters.allSatisfy({ "AaCcfhjLlMmrSTvwxX".contains($0) || !dashed && $0 == "u" }) else { return refuse() }
            i += 1
        }
        return .success(Part(kind: processes))
    }

    // MARK: project scripts

    /// A script as read, before it becomes a `Script`: its place relative to the folder the command runs in, and its text for the pre-screen.
    struct Loaded { let place: String, sha256: String, bytes: Int, inline: Bool, text: String, name: String, language: String }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static let languages = ["python": "Python", "node": "JavaScript", "bash": "shell", "sh": "shell", "zsh": "shell", "Rscript": "R", "ruby": "Ruby", "perl": "Perl"]
    private static let extensions = ["py": "Python", "js": "JavaScript", "mjs": "JavaScript", "cjs": "JavaScript", "sh": "shell", "bash": "shell", "zsh": "shell", "r": "R", "rb": "Ruby", "pl": "Perl"]
    /// Programs that, given to a script as its arguments, mean the script runs a command Buddy has not read (a guard that runs `rm -rf …`).
    private static let wrapped: Set<String> = ["sudo", "doas", "su", "brew", "port", "softwareupdate", "installer", "launchctl", "defaults", "osascript", "ssh", "scp", "sftp", "rsync", "ftp",
                                               "mail", "mailx", "sendmail", "mutt", "nc", "ncat", "netcat", "telnet", "socat", "curl", "wget", "git", "gh", "rm", "rmdir", "mv", "cp", "dd", "ln",
                                               "chmod", "chown", "tee", "xargs", "env", "exec", "eval", "security", "open", "kill", "killall", "pkill", "hdiutil", "diskutil", "pip", "pip3",
                                               "npm", "npx", "pnpm", "yarn", "uv", "docker", "crontab", "ditto", "install"]

    /// The interpreter a word names, if it is one Buddy reads scripts for (python, node, bash/sh/zsh, Rscript, ruby, perl): a bare name or one
    /// in the system's program folders, or a project virtual environment's own python.
    static func interpreter(_ word: String, root: URL) -> String? {
        let name = (word as NSString).lastPathComponent
        let tool = name.range(of: #"^python(3(\.\d+)?)?$"#, options: .regularExpression) != nil ? "python" : languages[name] != nil ? name : nil
        guard let tool else { return nil }
        if program(word) != nil { return tool }
        if tool == "python", let bin = inside((word as NSString).deletingLastPathComponent, root: root), bin == "bin" || bin.hasSuffix("/bin") { return tool }
        return nil
    }
    private static func run(_ w: [String], root: URL) -> Result<Part, Refusal> {
        var loaded: [Loaded] = []
        if let refusal = invocation(w[...], root: root, into: &loaded, depth: 0) { return .failure(refusal) }
        return .success(Part(kind: "script", scripts: loaded))
    }
    /// One interpreter running a project script: `python3 [-u -B -X utf8 …] <path> | -m <project module> | -c <code>`, `node <path> | -e <code>`,
    /// `bash|sh|zsh [-eux] <path> | -c <code>`, `Rscript|ruby|perl <path> | -e <code>`, a project venv's bin/python, or a project file run
    /// directly (its first line names one of those, or none: the shell). Whatever follows is the script's arguments (`arguments`).
    private static func invocation(_ w: ArraySlice<String>, root: URL, into loaded: inout [Loaded], depth: Int) -> Refusal? {
        guard depth < 4, let head = w.first else { return Refusal(reason: unclear) }
        var rest = w.dropFirst()
        guard let tool = interpreter(head, root: root) else {
            guard head.contains("/"), !head.hasPrefix("-") else { return Refusal(reason: unclear) }
            switch file(head, root: root, language: nil) { case .failure(let r): return r; case .success(let s): loaded.append(s) }
            return arguments(rest, root: root, into: &loaded, depth: depth)
        }
        let language = languages[tool] ?? tool
        let inlineFlags: Set<String> = ["python", "bash", "sh", "zsh"].contains(tool) ? ["-c"] : tool == "node" ? ["-e", "--eval", "-p", "--print"] : tool == "perl" ? ["-e", "-E"] : ["-e"]
        while let a = rest.first, a.hasPrefix("-"), a.count > 1 {
            if inlineFlags.contains(a) {
                // Code given in the command: each piece counts as a script whose content is that code.
                while let flag = rest.first, inlineFlags.contains(flag) {
                    rest = rest.dropFirst()
                    guard let code = rest.first, !code.isEmpty else { return Refusal(reason: unclear) }
                    let data = Data(code.utf8)
                    loaded.append(Loaded(place: "", sha256: digest(data), bytes: data.count, inline: true, text: code, name: "inline \(language) code", language: language))
                    rest = rest.dropFirst()
                }
                return arguments(rest, root: root, into: &loaded, depth: depth)
            }
            if tool == "python", a == "-m" {
                // A module counts only when it is a file of the project (python runs it from the folder the command runs in).
                guard let module = rest.dropFirst().first, module.range(of: #"^[A-Za-z_]\w*(\.[A-Za-z_]\w*)*$"#, options: .regularExpression) != nil else { return Refusal(reason: unclear) }
                let base = module.replacingOccurrences(of: ".", with: "/")
                guard let path = [base + ".py", base + "/__main__.py"].first(where: { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }) else { return Refusal(reason: unclear) }
                switch file(path, root: root, language: language) { case .failure(let r): return r; case .success(let s): loaded.append(s) }
                return arguments(rest.dropFirst(2), root: root, into: &loaded, depth: depth)
            }
            guard let taken = option(a, next: rest.dropFirst().first, tool: tool) else { return Refusal(reason: unclear) }
            rest = rest.dropFirst(taken)
        }
        // No script: the interpreter would read its program from its input, which Buddy cannot see.
        guard let path = rest.first, path != "-" else { return Refusal(reason: unclear) }
        switch file(path, root: root, language: language) { case .failure(let r): return r; case .success(let s): loaded.append(s) }
        return arguments(rest.dropFirst(), root: root, into: &loaded, depth: depth)
    }
    /// How many words an interpreter's option takes (1 or 2), or nil for an option Buddy does not accept here: only ones that change how
    /// output is shown or how strict the interpreter is, never ones that load other code, read input or settings, or wait for a debugger.
    private static func option(_ a: String, next: String?, tool: String) -> Int? {
        switch tool {
        case "python":
            func valid(_ flag: String, _ value: String) -> Bool {
                value.range(of: flag == "-X" ? #"^(utf8(=[01])?|dev|faulthandler|importtime|tracemalloc(=\d+)?|warn_default_encoding|no_debug_ranges|frozen_modules=(on|off))$"# : #"^[A-Za-z]+(:[A-Za-z_.]*){0,4}$"#, options: .regularExpression) != nil
            }
            if a == "-X" || a == "-W" { guard let next, valid(a, next) else { return nil }; return 2 }
            if a.hasPrefix("-X") || a.hasPrefix("-W") { return valid(String(a.prefix(2)), String(a.dropFirst(2))) ? 1 : nil }
            return !a.hasPrefix("--") && a.dropFirst().allSatisfy({ "uBOEsSIqbPv".contains($0) }) ? 1 : nil
        case "node":
            if ["--no-warnings", "--enable-source-maps", "--trace-warnings", "--no-deprecation", "--trace-uncaught", "--throw-deprecation"].contains(a) { return 1 }
            let parts = a.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            switch parts[0] {
            case "--max-old-space-size", "--stack-size": return Int(parts[1]) != nil ? 1 : nil
            case "--unhandled-rejections": return ["strict", "warn", "throw", "none", "warn-with-error-code"].contains(parts[1]) ? 1 : nil
            case "--input-type": return ["module", "commonjs"].contains(parts[1]) ? 1 : nil
            default: return nil
            }
        case "bash", "sh", "zsh":
            if a == "-o" { guard let next, ["pipefail", "errexit", "nounset", "xtrace"].contains(next) else { return nil }; return 2 }
            return !a.hasPrefix("--") && a.dropFirst().allSatisfy({ "eux".contains($0) }) ? 1 : nil
        case "Rscript": return ["--vanilla", "--no-save", "--no-restore", "--no-environ", "--no-site-file", "--no-init-file", "--quiet", "--slave", "--no-echo", "--verbose"].contains(a) ? 1 : nil
        case "ruby": return ["-w", "-W0", "-W1", "-W2", "--disable-gems"].contains(a) ? 1 : nil
        case "perl": return ["-w", "-W", "-X", "-T", "-t"].contains(a) ? 1 : nil
        default: return nil
        }
    }
    /// A script's arguments. One that names an interpreter starts another script (run_guard.py's child: `run_guard.py 420 python3 x.py`); one
    /// that names a program Buddy does not let a script run for it makes the command unclear; one with a script's extension must be a project
    /// script, read like the first; and a path that leaves the project sends the command to the person.
    private static func arguments(_ args: ArraySlice<String>, root: URL, into loaded: inout [Loaded], depth: Int) -> Refusal? {
        var rest = args
        while let a = rest.first {
            if interpreter(a, root: root) != nil { return invocation(rest, root: root, into: &loaded, depth: depth + 1) }
            if let name = program(a), wrapped.contains(name) { return Refusal(reason: unclear) }
            let value = a.hasPrefix("-") ? (a.firstIndex(of: "=").map { String(a[a.index(after: $0)...]) } ?? "") : a
            if !value.isEmpty, !value.contains("://") {
                if let language = extensions[(value as NSString).pathExtension.lowercased()] {
                    switch file(value, root: root, language: language) { case .failure(let r): return r; case .success(let s): loaded.append(s) }
                } else if value.hasPrefix("/") || value.hasPrefix("~") || value == ".." || value.hasPrefix("../") || value.contains("/../") || value.hasSuffix("/..") {
                    guard inside(value, root: root) != nil else { return Refusal(reason: "It points a script at a place outside the project.") }
                }
            }
            rest = rest.dropFirst()
        }
        return nil
    }
    /// A project script, read once: inside the project (after following links), a regular text file of at most 64 KB. Run directly
    /// (`language` nil), its first line must name an interpreter Buddy reads, or none (the shell runs it).
    private static func file(_ path: String, root: URL, language: String?) -> Result<Loaded, Refusal> {
        guard !path.hasPrefix("-") else { return .failure(Refusal(reason: unclear)) }
        guard let place = inside(path, root: root), place != "." else { return .failure(Refusal(reason: "It runs a script from outside the project.")) }
        let url = root.appendingPathComponent(place), name = (place as NSString).lastPathComponent
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path), attributes[.type] as? FileAttributeType == .typeRegular else { return .failure(Refusal(reason: unclear)) }
        guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= scriptLimit else { return .failure(Refusal(reason: "The script \(name) is larger than Buddy reads (64 KB), so you decide.")) }
        guard let data = FileManager.default.contents(atPath: url.path), data.count <= scriptLimit, !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            return .failure(Refusal(reason: "Buddy cannot read the script \(name) as text, so you decide."))
        }
        var language = language
        if language == nil {
            if text.hasPrefix("#!") {
                var words = text.prefix { $0 != "\n" }.dropFirst(2).split(separator: " ").map(String.init)
                if let first = words.first, program(first) == "env" { words.removeFirst() }
                guard let first = words.first, let tool = interpreter(first, root: root) else { return .failure(Refusal(reason: unclear)) }
                var flags = words.dropFirst()
                while let flag = flags.first { guard let taken = option(flag, next: flags.dropFirst().first, tool: tool) else { return .failure(Refusal(reason: unclear)) }; flags = flags.dropFirst(taken) }
                language = languages[tool]
            } else { language = "shell" }
        }
        return .success(Loaded(place: place, sha256: digest(data), bytes: data.count, inline: false, text: text, name: name, language: language ?? "shell"))
    }
    /// The verdict on a command that runs project scripts: each one is read for what is on the person's list (`screen`); a hit sends the
    /// command to the person with what Buddy saw, and nothing found gives it to the supervisor, who reads them in full.
    private static func scripted(_ found: [Loaded], writes: [String], project: URL, root: URL, prefix: String) -> Verdict {
        var seen = Set<String>(), list: [Loaded] = []
        for s in found where seen.insert(s.inline ? "inline:" + s.sha256 : s.place).inserted { list.append(s) }
        guard list.count <= maxScripts else { return sensitive("It runs more than \(maxScripts) scripts; Buddy reads at most \(maxScripts) for one command, so you decide.") }
        let records = list.map { Script(path: $0.inline ? $0.name : prefix + $0.place, sha256: $0.sha256, bytes: $0.bytes, inline: $0.inline, code: $0.inline ? $0.text : nil) }
        func unique(_ items: [String]) -> [String] { Array(NSOrderedSet(array: items)) as? [String] ?? items }
        let files = unique(list.filter { !$0.inline }.map(\.name)), inline = unique(list.filter(\.inline).map(\.name))
        let runs = "Runs " + listed((files.isEmpty ? [] : [(files.count == 1 ? "the project script " : "the project scripts ") + listed(files)]) + inline) + "."
        for s in list {
            let folder = s.inline ? root : root.appendingPathComponent(s.place).deletingLastPathComponent()
            if let concern = screen(s.text, subject: s.inline ? "The " + s.name : "The script " + s.name, shell: s.language == "shell", project: project, root: root, folder: folder) {
                return Verdict(routine: false, reason: concern, hosts: [], writes: [], scripts: records, runs: runs)
            }
        }
        return Verdict(routine: false, reason: runs, hosts: [], writes: writes, script: true, scripts: records, runs: runs)
    }

    // MARK: the pre-screen

    /// A heuristic net, not the judge: it reads a script's text for what plainly does something on the person's list, and a hit sends the
    /// command to the person; finding nothing only means the supervisor reads it next. It looks for (1) secrets: the marks above, environment
    /// reads of password, token or key names, the Keychain and `security`, ~/.ssh, ~/.pgpass, browsers' cookies and saved logins; (2) sending
    /// data out: HTTP POST/PUT/PATCH and uploads (requests, httpx, urllib, fetch, axios, curl -d/-F/-T, wget --post), mail, sockets,
    /// ssh/scp/rsync/ftp, cloud storage clients, git push and webhooks; (3) changing the Mac: sudo, brew/port/softwareupdate/installer, account-
    /// or system-wide package installs, launchctl and login items, defaults write, osascript, system settings tools, hdiutil attach of something
    /// outside the project, and writing to /Applications or ~/Library; (4) deleting or writing outside the project: a delete or write on a line
    /// that names an absolute path outside the project, the home folder or a `..` that leaves it, and any recursive delete in a file that names
    /// such a path anywhere. It does not follow what a script imports, values built at run time or passed through variables to a write on
    /// another line, or what a program it starts does on its own.
    static func screen(_ text: String, subject: String, shell: Bool, project: URL, root: URL, folder: URL) -> String? {
        func hit(_ rules: [NSRegularExpression]) -> String? {
            for rule in rules { if let found = first(rule, in: text) { return label(found) } }
            return nil
        }
        if let found = hit(secretRules) { return "\(subject) reads passwords, keys or tokens (\(found))." }
        if let found = hit(sendRules + (shell ? [shellSends] : [])) { return "\(subject) can send data out of this Mac (\(found))." }
        if let found = hit(macRules) { return "\(subject) changes this Mac (\(found))." }
        let lines = text.components(separatedBy: .newlines)
        var named: String?
        for (index, line) in lines.enumerated() where !(index == 0 && line.hasPrefix("#!")) {
            let refs = outside(line, project: project, root: root, folder: folder)
            guard let ref = refs.first else { continue }
            if named == nil, !ref.hasPrefix("..") { named = ref }
            if let hdiutil = first(attach, in: line) { return "\(subject) changes this Mac (\(label(hdiutil)) \(label(ref)))." }
            guard let op = first(deletes, in: line) ?? first(writes, in: line) else { continue }
            let lowered = line.lowercased()
            let system = refs.contains { r in ["/applications", "/library", "/system", "/usr", "/opt", "/etc", "/private/etc"].contains { r.lowercased() == $0 || r.lowercased().hasPrefix($0 + "/") } }
            if system || lowered.contains("library") && refs.contains(where: { $0.hasPrefix("~") || !$0.hasPrefix("/") && !$0.hasPrefix("..") }) {
                return "\(subject) changes this Mac (\(label(op)) \(label(ref)))."
            }
            return "\(subject) deletes or writes files outside the project (\(label(op)) \(label(ref)))."
        }
        // A recursive delete in a file that names a place outside the project anywhere: the place may reach it through a variable.
        if let named, let op = first(recursiveDelete, in: text) { return "\(subject) deletes or writes files outside the project (\(label(op)) \(label(named)))." }
        return nil
    }
    /// The places outside the project a line names: absolute paths (except /dev/null and the like), the home folder in any of its spellings,
    /// and `..` paths that leave the project when read from the script's folder or from where the command runs.
    private static func outside(_ line: String, project: URL, root: URL, folder: URL) -> [String] {
        var refs: [String] = []
        for path in all(absolutePath, in: line) where !["/dev/null", "/dev/stdout", "/dev/stderr", "/dev/tty"].contains(path) {
            if inside(path, root: project) == nil { refs.append(path) }
        }
        if let home = first(homeRef, in: line) { refs.append(home) }
        for path in all(parentPath, in: line) where inside(path, root: project, from: folder) == nil || inside(path, root: project, from: root) == nil { refs.append(path) }
        return refs
    }
    private static func rx(_ pattern: String, caseless: Bool = true) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: caseless ? [.caseInsensitive, .anchorsMatchLines] : [.anchorsMatchLines])
    }
    private static func first(_ rule: NSRegularExpression, in text: String) -> String? {
        guard let match = rule.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(match.range, in: text) else { return nil }
        return String(text[range])
    }
    private static func all(_ rule: NSRegularExpression, in text: String) -> [String] {
        rule.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }
    /// What Buddy saw, shown in the reason: one short line without quotes or brackets.
    private static func label(_ found: String) -> String {
        let plain = found.replacingOccurrences(of: #"[\s'"`\[\]{}(),]+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return plain.count > 48 ? String(plain.prefix(47)) + "…" : plain
    }
    private static let secretRules: [NSRegularExpression] = [
        rx(#"\.ssh|id_rsa|id_ed25519|id_ecdsa|\.pgpass|\.netrc|\.aws/|\.npmrc|\.pypirc|\.git-credentials|\.docker/config|keychain|keyring|dotenv|login data|cookies\.(binarycookies|sqlite)|/cookies\b|logins\.json|key4\.db|library/application support|pgpassword|api_?key|credential|passw(or)?d|secret|/etc/"#),
        rx(#"(?<![a-z0-9_])\.env(?![a-z0-9_])"#),
        rx(#"token(?!i[sz]|s\b)"#),
        rx(#"(os\.environ|getenv|process\.env|\benv\s*\[|\$env\{|\bENV\s*\[)[^\n]{0,60}?(pass|token|secret|key|auth|cred)"#),
        rx(#"\bsecurity['"\s,]+(find-|dump-keychain|export|unlock-keychain|add-generic|add-internet|delete-)|SecItemCopyMatching|SecKeychain"#),
    ]
    private static let sendRules: [NSRegularExpression] = [
        rx(#"[\w$]*\.\s*post\s*\(|\b(requests|httpx|aiohttp|urllib3|session|client|axios|http|api)\s*\.\s*(put|patch|request|delete)\s*\(|->\s*(post|put|patch|request)\b|Net::HTTP::(Post|Put|Patch)"#),
        rx(#"\b(POST|PUT|PATCH)\s*\("#, caseless: false),
        rx(#"method\s*[=:]\s*['"](post|put|patch|delete)['"]|\.request\s*\(\s*['"](post|put|patch|delete)['"]|urlopen\s*\([^\n]*data\s*=|\bRequest\s*\([^\n]*data\s*=|sendbeacon|xmlhttprequest|websocket"#),
        rx(#"\.upload(_file|_fileobj|file)?\s*\(|curl\b[^\n]*?[\s'"]-(d|F|T|-data[\w-]*|-form|-upload-file|-json|X['"\s,]*(POST|PUT|PATCH|DELETE))\b|wget\b[^\n]*?--(post-data|post-file|method|body-data|body-file)"#, caseless: false),
        rx(#"smtplib|sendmail|nodemailer|\bsmtp\b|\bmailx?\s+-s\b|import socket\b|from socket import|socket\.(socket|create_connection)|require\(\s*['"](net|dgram|tls)['"]\s*\)|\bnet\.(connect|createconnection)\b|\b(paramiko|ftplib|pysftp|boto3|botocore|google\.cloud|azure\.storage|dropbox|smbclient)\b"#),
        rx(#"['"](ssh|scp|sftp|rsync|ftp|nc|ncat|netcat|telnet|socat)(['"]|\s)|\bgit['"\s,]+push\b|\bgh\s+(pr|issue|release|gist|api|repo)\b|webhook|hooks\.slack\.com|hooks\.zapier\.com|maker\.ifttt\.com|requestbin|pipedream|ngrok|beeceptor|requestcatcher"#),
    ]
    /// The same programs at the start of a shell script's command (in other languages a bare `nc` is as likely a variable as a program).
    private static let shellSends = rx(#"(^|[;&|(`]|\$\()\s*(ssh|scp|sftp|rsync|ftp|nc|ncat|netcat|telnet|socat|mail|mailx|sendmail)\s"#)
    private static let macRules: [NSRegularExpression] = [
        rx(#"\b(sudo|doas)\b|\bbrew['"\s,]+(install|uninstall|reinstall|upgrade|update|tap|untap|link|unlink|services|remove|rm|cleanup|pin)\b|\bport['"\s,]+(install|uninstall|selfupdate|upgrade)\b|softwareupdate|\binstaller['"\s,]+-pkg"#),
        rx(#"launchctl|launchagents|launchdaemons|login ?items|crontab|\bdefaults['"\s,]+(write|delete|import|rename)\b|osascript|tell application|\bpmset\b|systemsetup|networksetup|\bscutil['"\s,]+--set|\bnvram\b|csrutil|\bspctl\b|\bdiskutil['"\s,]+(erase|partition|apfs|rename|unmount|mount|eject)|kextload|kmutil|tccutil|\bprofiles['"\s,]+(install|remove)"#),
        rx(#"\bpip3?['"\s,]+install\b|\bnpm['"\s,]+(install|i)\b[^\n]*(\s-g\b|--global)|\bgem['"\s,]+install\b|install\.packages\s*\(|\bcargo['"\s,]+install\b|\bgo['"\s,]+install\b|\bconda['"\s,]+install\b|\bmas['"\s,]+install\b"#),
    ]
    private static let attach = rx(#"hdiutil['"\s,]+attach"#)
    private static let absolutePath = rx(#"(?<![\w.:/~$@)\]-])/(?!Volumes/)[A-Za-z0-9._@+-][^\s'"`;|&()<>,\[\]{}]*"#)
    private static let homeRef = rx(#"(?<![\w])~(?=/|['"\s]|$)|expanduser|path\.home\s*\(|os\.homedir|homedir\(|\$home\b|\$\{home\}|['"]home['"]\s*\]|getenv\(\s*['"]home['"]"#)
    private static let parentPath = rx(#"(?<![\w.])\.\.(/[^\s'"`;|&()<>,]*)?(?![\w.])"#)
    private static let deletes = rx(#"\b(rm|rmdir|unlink|unlinksync|rmtree|rmsync|removedirs|shred|srm)\b|os\.remove\b|shutil\.move|os\.rename|os\.replace|\bmv\b|fileutils\.rm|file\.delete"#)
    private static let writes = rx(#"\bopen\s*\([^\n]*['"](w|a|x|wb|ab|xb|w\+|a\+|r\+|wt|at)['"]|mode\s*=\s*['"][wax]|\.write_(text|bytes)\s*\(|\.to_(csv|parquet|excel|json|pickle|feather|hdf|sql|stata|html|latex)\s*\(|savefig\s*\(|\bnp\.save|\bsave(rds|rdata)?\s*\(|write\.(csv|table)|writefile|appendfile|createwritestream|\bcp\b|\bditto\b|\bcopy(file|tree|2)?\s*\(|shutil\.copy|\bmkdir\b|makedirs|\btouch\b|\bchmod\b|\bchown\b|\bchflags\b|\bxattr\b|\bln\b|symlink|\btee\b|>>?\s*['"]?[/~$]|\binstall\s+-|\bsink\s*\(|\bdd\b[^\n]*\bof=|extractall\s*\(|\.write\s*\("#)
    private static let recursiveDelete = rx(#"\brm\s+-[a-z]*r|rmtree|removedirs|rmsync|\brm\s*\([^\n]*recursive"#)

    // MARK: after the review

    /// A project script's current bytes, read the way the review reads them: inside the project after following links, a regular file. Nil
    /// when it is gone or no longer such a file. At most `limit` bytes are read (`whole` says whether that was all of it).
    static func contents(_ path: String, project: String, limit: Int = 1 << 20) -> (data: Data, size: Int, whole: Bool)? {
        let root = URL(fileURLWithPath: project).resolvingSymlinksInPath().standardizedFileURL
        guard let place = inside(path, root: root), place != "." else { return nil }
        let url = root.appendingPathComponent(place)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path), attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.intValue, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: max(0, limit)) else { return size == 0 ? (Data(), 0, true) : nil }
        return (data, size, data.count >= size)
    }
    /// Whether every project script a review read is still exactly what was read: same place in the project, same bytes. Inline code is part
    /// of the command itself, so it cannot change.
    static func unchanged(_ scripts: [[String: Any]], project: String) -> Bool {
        for script in scripts where script["inline"] as? Bool != true {
            guard let path = script["path"] as? String, let expected = script["sha256"] as? String, let bytes = script["bytes"] as? Int,
                  let now = contents(path, project: project, limit: bytes + 1), now.whole, now.size == bytes, digest(now.data) == expected else { return false }
        }
        return true
    }
}
