import CryptoKit
import Foundation

/// Which coding commands that leave the sandbox (network access, or a Codex escalation) the team's supervisor may approve in the person's place.
/// It is deliberately narrow: a command is ROUTINE only when every part of it is one of a few shapes Buddy can read word for word — a plain
/// download from a public http(s) site into the project or a temporary folder (curl or wget, GET only), a package install into the project or
/// its own virtual environment (pip/uv with a project target or venv, npm/pnpm/yarn in the project), a clone or fetch of a public repository
/// into the project, a look at running processes (pgrep, ps), making folders in the project and reading project files with a read-only text
/// tool. A command whose every part runs PROJECT SCRIPTS with a local interpreter is a SCRIPT command: Buddy reads each script (see `run` and
/// `screen`) and the supervisor reads them again before it may run.
/// Around those parts Buddy reads a few shell shapes that stay in the project and only read: a pipe into read-only text tools (head, tail,
/// grep, rg, wc, sort, uniq, cut, tr, sed, awk, jq, column, cat, and tee into the project), output saved with `>`, `>>`, `2>`, `&>` into the
/// project, a temporary folder (/tmp, $TMPDIR) or /dev/null, input read with `<` from the project, `cd` into a project folder (what follows is
/// read from there), a few harmless settings before a program (PYTHONUNBUFFERED=1, LANG=…, PYTHONPATH inside the project), and $PWD or $TMPDIR
/// in its arguments.
/// Everything else is SENSITIVE and stays with the person: anything that can send data out (uploads, POST, headers, cookies, git push,
/// ssh/scp/rsync, mail, nc, webhooks), a saved sign-in, reading secrets, reading or writing outside the project (temporary folders aside),
/// installing system-wide, sudo, a private or local address, a script whose contents plainly do one of those, and any command it cannot take
/// apart with confidence (a pipe into any other program, other settings or variables, substitutions, heredocs, globs, `||`, background `&`,
/// options it does not know).
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
        /// Where it writes, relative to the project ("." for the project itself); a file in a temporary folder as written (/tmp/x.log, $TMPDIR/x).
        let writes: [String]
        /// Every part runs project scripts Buddy read and found nothing on the person's list in: the supervisor reads them and decides.
        var script = false
        /// The scripts it runs, as read (also kept when a script's contents sent the command to the person, so the page can name them).
        var scripts: [Script] = []
        /// What it runs, in plain words ("Runs the project scripts a.py and b.py."), when it runs project scripts.
        var runs = ""
        /// Whether it is on the person's own list (a saved sign-in, secrets, sending data out, changing the Mac or installing for it, writing or
        /// deleting outside the project, a private network address): only those go to the person. Anything else Buddy could not read is the
        /// team supervisor's, who reads the exact command. (Forge's read-only process listings went to the user seven times on 23 Oct.)
        var forPerson: Bool { !routine && !script && BuddyCommandReview.personal(reason) }
        var kind: String { routine ? "routine" : script ? "script" : forPerson ? "sensitive" : "unclear" }
    }
    /// The reasons on the person's own list, as `assess` and the script screen word them.
    static func personal(_ reason: String) -> Bool {
        let starts = ["It signs in with your saved sign-in", readsSecrets, sendsOut, "It puts a sign-in into the web address", changesMac, "It installs outside the project",
                      writesOutside, "It reaches a local or private address"]
        let screened = [" reads passwords, keys or tokens", " can send data out of this Mac", " changes this Mac", " deletes or writes files outside the project"]
        return starts.contains { reason.hasPrefix($0) } || screened.contains { reason.contains($0) }
    }
    static func sensitive(_ reason: String, hosts: [String] = []) -> Verdict { Verdict(routine: false, reason: reason, hosts: hosts, writes: []) }

    static let sendsOut = "It can send data out of this Mac (an upload, a POST, headers or cookies, git push, ssh/scp/rsync, mail or a raw connection)."
    static let readsSecrets = "It reads secrets (keys, tokens, passwords, sign-in or environment files)."
    static let unclear = "Buddy cannot tell exactly what this command does, so you decide."
    static let readsOutside = "It reads files outside the project."
    static let writesOutside = "It writes outside the project."
    static let changesMac = "It changes this Mac outside the project (sudo, system installs or settings)."
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
        guard var runs = parse(text) else { return sensitive(unclear) }
        // One shell wrapper, as Codex sends its commands: /bin/zsh -lc '<script>'.
        if runs.count == 1, runs[0].count == 1, runs[0][0].settings.isEmpty, runs[0][0].redirects.isEmpty, let script = unwrapped(runs[0][0].words) {
            guard let inner = parse(script) else { return sensitive(unclear) }
            runs = inner
        }
        let root = URL(fileURLWithPath: real(project), isDirectory: true)
        var here = Here(project: root)
        if let cwd, !cwd.isEmpty {
            guard let place = inside(cwd, root: root) else { return sensitive("It runs outside the project folder.") }
            here = Here(project: root, place: place)
        }
        var hosts: [String] = [], writes: [String] = [], kinds: [String] = [], downloads: [Part] = [], scripts: [Loaded] = [], made: [String] = [], reads = false
        for run in runs {
            // cd <a folder in the project>: what follows runs there, and its paths are read from there.
            if run.count == 1, run[0].words.first == "cd" {
                let stage = run[0]
                guard stage.settings.isEmpty, stage.redirects.isEmpty, stage.words.count == 2, let target = expanded(stage.words[1], here), !target.hasPrefix("-"),
                      let place = here.inside(target), folder(place, in: root) || made.contains(where: { $0 == place || $0.hasPrefix(place + "/") }) else { return sensitive(unclear, hosts: hosts) }
                here = Here(project: root, place: place)
                continue
            }
            var first: Part?, saved: [String] = []
            for (index, stage) in run.enumerated() {
                for setting in stage.settings { guard harmless(setting, here) else { return sensitive(unclear, hosts: hosts) } }
                // $PWD and $TMPDIR are read in a program's arguments, never as the program itself.
                guard let head = stage.words.first, !head.unicodeScalars.contains(where: marks.contains) else { return sensitive(unclear, hosts: hosts) }
                var words: [String] = []
                for word in stage.words { guard let w = expanded(word, here) else { return sensitive(unclear, hosts: hosts) }; words.append(w) }
                let part: Part
                switch index == 0 ? simple(words, at: here) : piped(words, at: here) {
                case .failure(let refusal): return sensitive(refusal.reason, hosts: hosts)
                case .success(let p): part = p
                }
                hosts += part.hosts; writes += part.writes; scripts += part.scripts
                if part.kind == "read" { reads = true; saved += part.writes }
                if index == 0 { first = part }
                for (op, raw) in stage.redirects where op != "dup" {
                    guard let target = expanded(raw, here) else { return sensitive(unclear, hosts: hosts) }
                    if op == "<" { guard canRead(target, here) else { return sensitive(readsOutside, hosts: hosts) }; continue }
                    if ["/dev/null", "/dev/stdout", "/dev/stderr"].contains(target) { continue }
                    guard let place = here.reachable(target) else { return sensitive(writesOutside, hosts: hosts) }
                    writes.append(place)
                    if !op.hasPrefix("2") { saved.append(place) }
                }
            }
            guard var part = first else { continue }
            // A download shown on the screen but saved by what follows it (curl … > page.html, curl … | tee page.html) is saved.
            if part.kind.hasPrefix("a download from "), part.kind.hasSuffix(" (shown, not saved)"), !saved.isEmpty { part.kind = "a download from " + part.hosts.joined(separator: ", ") + into(saved) }
            switch part.kind {
            case "script", "read": break
            case "folder": made += part.writes
            default: if part.kind.hasPrefix("a download from ") { downloads.append(part) } else { kinds.append(part.kind) }
            }
        }
        func unique(_ list: [String]) -> [String] { Array(NSOrderedSet(array: list)) as? [String] ?? list }
        let uniqueHosts = unique(hosts), uniqueWrites = unique(writes)
        if !scripts.isEmpty {
            // Scripts beside folders, reads or a look at processes only; a download or an install beside them is more than one read covers.
            guard downloads.isEmpty, kinds.allSatisfy({ $0 == processes }) else { return sensitive(unclear) }
            return scripted(scripts, writes: uniqueWrites, project: root)
        }
        // Several downloads read as one phrase ("3 downloads from arxiv.org and iop.org into the project"), so the person sees one line.
        let files = downloads.reduce(0) { $0 + max(1, $1.hosts.count) }
        let fetched: [String] = files == 1 ? [downloads[0].kind] : files > 1 ? ["\(files) downloads from \(listed(unique(downloads.flatMap(\.hosts)))) into the project"] : []
        let what = fetched + unique(kinds)
        let summary = !what.isEmpty ? what.joined(separator: "; ")
            : reads ? (writes.count > made.count ? "It only reads files and saves what it shows." : "It only reads files in the project.") : "It only makes folders in the project."
        return Verdict(routine: true, reason: summary.prefix(1).uppercased() + summary.dropFirst() + (summary.hasSuffix(".") ? "" : "."), hosts: uniqueHosts, writes: uniqueWrites)
    }

    /// "a", "a and b", "a, b and c".
    static func listed(_ items: [String]) -> String { items.count <= 2 ? items.joined(separator: " and ") : items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1] }
    /// How a download's place reads: shown only, saved into a temporary folder, or saved into the project.
    static func into(_ writes: [String]) -> String {
        writes.isEmpty ? " (shown, not saved)" : writes.allSatisfy({ $0.hasPrefix("/") || $0.hasPrefix("$TMPDIR") }) ? " into a temporary folder" : " into the project"
    }

    static let secretMarks = [".ssh", "id_rsa", "id_ed25519", "id_ecdsa", ".pgpass", ".netrc", ".aws", ".env", ".npmrc", ".pypirc", ".git-credentials", ".docker/config", "keychain",
                              "security find", "token", "password", "passwd", "secret", "credential", "api_key", "apikey", "pgpassword", "/etc/", "library/application support"]

    // MARK: reading the words

    /// One program in a command: the settings before it (`NAME=value`), its words, and where its output goes or its input comes from (`>`,
    /// `>>`, `2>`, `2>>`, `&>`, `&>>`, `<` with the word after it; "dup" for 2>&1 and the like, which only joins one output to the other).
    struct Stage { var settings: [String] = [], words: [String] = [], redirects: [(op: String, target: String)] = [] }
    /// Stand-ins for $PWD (in double quotes, and bare) and $TMPDIR inside a word, filled in where the word is judged (`expanded`): $PWD is the
    /// folder that part runs in, which a `cd` before it changes. A command that holds one of these characters itself is refused.
    static let pwdQuoted: Unicode.Scalar = "\u{E000}", pwdBare: Unicode.Scalar = "\u{E001}", tmpdirMark: Unicode.Scalar = "\u{E002}"
    static let marks: Set<Unicode.Scalar> = [pwdQuoted, pwdBare, tmpdirMark]

    /// The command as runs joined by `&&`, `;` or a new line (each judged on its own, in order, so running one after another is no riskier
    /// than one at a time), each run a pipeline of stages joined by `|`; or nil when it uses anything else of the shell (`||`, `|&`, background
    /// `&`, heredocs and here-strings, substitutions, process substitution, variables other than $PWD and $TMPDIR, globs, history, comments, a
    /// backslash, a `~` inside a word, a redirection of another output or into a command) or leaves a quote open. A `~` starting a word stays
    /// in it, so every path check reads it as outside the project. It reads the command character by character as the shell does (Unicode
    /// scalars, so a quote with a combining mark on it is still a quote).
    static func parse(_ text: String) -> [[Stage]]? {
        enum Piece { case word(String, assignment: Bool), op(String) }
        var pieces: [Piece] = []
        var word = String.UnicodeScalarView(), started = false, quoted = false, assignment = false, single = false, double = false
        let chars = Array(text.unicodeScalars)
        var i = 0
        func at(_ k: Int) -> Unicode.Scalar? { k < chars.count ? chars[k] : nil }
        func one(_ set: String, _ c: Unicode.Scalar?) -> Bool { c.map { set.unicodeScalars.contains($0) } ?? false }
        func endWord() { if started { pieces.append(.word(String(word), assignment: assignment)) }; word = String.UnicodeScalarView(); started = false; quoted = false; assignment = false }
        /// The stand-in for `$NAME` or `${NAME}` at i (its `$`), moving i to its last character; nil for a variable Buddy does not read.
        func variable(quotedNow: Bool) -> Unicode.Scalar? {
            var j = i + 1, name = ""
            let braced = at(j) == "{"
            if braced { j += 1 }
            while let c = at(j), c.isASCII, c.properties.isAlphabetic || ("0"..."9").contains(c) || c == "_" { name.unicodeScalars.append(c); j += 1 }
            if braced { guard at(j) == "}" else { return nil }; j += 1 }
            i = j - 1
            switch name {
            case "PWD": return quotedNow ? pwdQuoted : pwdBare
            // Unquoted, a value with spaces or wildcards would split or expand: only a plain $TMPDIR is read so.
            case "TMPDIR": guard let t = temporaryFolder, quotedNow || !t.contains(where: { $0.isWhitespace || "*?[]".contains($0) }) else { return nil }; return tmpdirMark
            default: return nil
            }
        }
        while i < chars.count {
            let c = chars[i]
            if c == "\r" || c == "\0" || marks.contains(c) { return nil }
            if single { if c == "'" { single = false } else { word.append(c) }; i += 1; continue }
            if double {
                if c == "\"" { double = false }
                else if c == "$" { guard let v = variable(quotedNow: true) else { return nil }; word.append(v) }
                else if one("`\\!", c) { return nil } else { word.append(c) }
                i += 1; continue
            }
            switch c {
            case " ", "\t": endWord()
            case "'": single = true; started = true; quoted = true
            case "\"": double = true; started = true; quoted = true
            case "$": guard let v = variable(quotedNow: false) else { return nil }; word.append(v); started = true
            case "~":
                guard !started else { return nil }
                word.append(c); started = true
            case "=":
                // NAME= unquoted at the start of a word: a setting when it comes before the program (sorted out below).
                if !quoted, !assignment, String(word).range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil { assignment = true }
                word.append(c); started = true
            case "&":
                if at(i + 1) == "&" { endWord(); pieces.append(.op("&&")); i += 1 }
                else if at(i + 1) == ">" { endWord(); if at(i + 2) == ">" { pieces.append(.op("&>>")); i += 2 } else { pieces.append(.op("&>")); i += 1 } }
                else { return nil }
            case "|":
                guard at(i + 1) != "|", at(i + 1) != "&" else { return nil }
                endWord(); pieces.append(.op("|"))
            case "\n", ";": endWord(); pieces.append(.op(";"))
            case ">", "<":
                // A bare 1 or 2 right before > names the output (2> for errors); other numbered outputs and inputs are refused.
                var fd = ""
                if started, !quoted, !word.isEmpty, word.allSatisfy({ ("0"..."9").contains($0) }) {
                    guard c == ">", ["1", "2"].contains(String(word)) else { return nil }
                    fd = String(word); word = String.UnicodeScalarView(); started = false
                }
                endWord()
                let next = at(i + 1)
                if c == "<" {
                    guard !one("<(&>", next) else { return nil }
                    pieces.append(.op("<")); i += 1; continue
                }
                if next == "&" {
                    // 2>&1, >&2: one output joined to the other.
                    guard let to = at(i + 2), to == "1" || to == "2", at(i + 3).map({ one(" \t\n;&|", $0) }) ?? true else { return nil }
                    pieces.append(.op("dup")); i += 3; continue
                }
                guard !one("|(", next) else { return nil }
                if next == ">" { pieces.append(.op(fd + ">>")); i += 2; continue }
                pieces.append(.op(fd + ">")); i += 1; continue
            default:
                // A `?` inside a web address (an unquoted query such as papers.cfm?abstract_id=1) is part of the address: no file path starts
                // with "http", so it can't match anything as a wildcard. Anywhere else it is still refused.
                let sofar = String(word).lowercased()
                if c == "?", sofar.hasPrefix("http://") || sofar.hasPrefix("https://") { word.append(c); started = true; i += 1; continue }
                if one("()`{}*?[]!#\\^", c) { return nil }
                word.append(c); started = true
            }
            i += 1
        }
        guard !single, !double else { return nil }
        endWord()
        var runs: [[Stage]] = [], pipeline: [Stage] = [], stage = Stage(), target: String?, afterAnd = false
        for piece in pieces {
            switch piece {
            case .word(let w, let assignment):
                if let op = target { stage.redirects.append((op, w)); target = nil }
                else if assignment, stage.words.isEmpty { stage.settings.append(w) }
                else { stage.words.append(w) }
                afterAnd = false
            case .op(let op):
                guard target == nil else { return nil }
                switch op {
                case "dup": stage.redirects.append(("dup", ""))
                case "|", "&&", ";":
                    if stage.words.isEmpty {
                        // A blank line, or a line break after `&&`, adds nothing; anything else around a missing program is refused.
                        guard op == ";", pipeline.isEmpty, stage.settings.isEmpty, stage.redirects.isEmpty else { return nil }
                        continue
                    }
                    pipeline.append(stage); stage = Stage()
                    if op != "|" { runs.append(pipeline); pipeline = [] }
                    afterAnd = op == "&&"
                default: target = op
                }
            }
        }
        guard target == nil else { return nil }
        if stage.words.isEmpty { guard pipeline.isEmpty, stage.settings.isEmpty, stage.redirects.isEmpty, !afterAnd else { return nil } }
        else { pipeline.append(stage); runs.append(pipeline) }
        return runs.isEmpty ? nil : runs
    }
    /// The script of `zsh|bash|sh [-l] -c '<script>'` (with or without /bin/), else nil.
    static func unwrapped(_ words: [String]) -> String? {
        guard let first = words.first, ["zsh", "/bin/zsh", "bash", "/bin/bash", "sh", "/bin/sh"].contains(first) else { return nil }
        let flags = Array(words.dropFirst().dropLast())
        guard words.count >= 3, flags == ["-c"] || flags == ["-lc"] || flags == ["-l", "-c"] else { return nil }
        return words.last
    }
    /// A word with $PWD and $TMPDIR filled in, for a part that runs in `here`; nil when a bare $PWD would split or expand there.
    static func expanded(_ word: String, _ here: Here) -> String? {
        guard word.unicodeScalars.contains(where: marks.contains) else { return word }
        let pwd = here.folder.path
        if word.unicodeScalars.contains(pwdBare), pwd.contains(where: { $0.isWhitespace || "*?[]".contains($0) }) { return nil }
        if word.unicodeScalars.contains(tmpdirMark), temporaryFolder == nil { return nil }
        var out = ""
        for c in word.unicodeScalars {
            switch c {
            case pwdQuoted, pwdBare: out += pwd
            case tmpdirMark: out += temporaryFolder ?? ""
            default: out.unicodeScalars.append(c)
            }
        }
        return out
    }
    /// Settings a command may set before its program: output buffering, locale, time zone, colours, the plotting backend (by its plain name:
    /// module://… would load code), thread count, CI mode with a plain value, and PYTHONPATH when every folder in it is in the project. Never
    /// PATH, the loader's (LD_*, DYLD_*) or anything else.
    static let settingNames: Set<String> = ["PYTHONUNBUFFERED", "PYTHONDONTWRITEBYTECODE", "LC_ALL", "LANG", "TZ", "NO_COLOR", "MPLBACKEND", "OMP_NUM_THREADS", "CI"]
    private static func harmless(_ setting: String, _ here: Here) -> Bool {
        guard let equals = setting.firstIndex(of: "=") else { return false }
        let name = String(setting[..<equals]), value = String(setting[setting.index(after: equals)...])
        if name == "PYTHONPATH" {
            guard let path = expanded(value, here), !path.isEmpty else { return false }
            return path.split(separator: ":", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && here.inside(String($0)) != nil }
        }
        return settingNames.contains(name) && value.range(of: name == "MPLBACKEND" ? #"^[A-Za-z0-9_]{1,32}$"# : #"^[A-Za-z0-9._+\-/:]{0,64}$"#, options: .regularExpression) != nil
    }

    // MARK: one simple command

    struct Part { var kind: String, hosts: [String] = [], writes: [String] = [], scripts: [Loaded] = [] }
    struct Refusal: Error { let reason: String }
    private static func refuse(_ reason: String = unclear) -> Result<Part, Refusal> { .failure(Refusal(reason: reason)) }
    static let systemTools: Set<String> = ["sudo", "doas", "su", "brew", "port", "softwareupdate", "installer", "launchctl", "defaults", "osascript"]
    static let senders: Set<String> = ["ssh", "scp", "sftp", "rsync", "ftp", "mail", "mailx", "sendmail", "mutt", "nc", "ncat", "netcat", "telnet", "socat"]

    /// The program a word names, if it is one Buddy reads here: a bare name or one in the system's program folders.
    private static func program(_ word: String) -> String? {
        let name = (word as NSString).lastPathComponent
        if !word.contains("/") { return name }
        let folder = (word as NSString).deletingLastPathComponent
        return ["/usr/bin", "/bin", "/usr/local/bin", "/opt/homebrew/bin"].contains(folder) ? name : nil
    }
    private static func simple(_ w: [String], at here: Here) -> Result<Part, Refusal> {
        guard let head = w.first else { return refuse() }
        if head.contains("=") { return refuse() }   // a setting Buddy did not read as one (quoted, or after the program's name)
        if let name = program(head) {
            if name == "osascript", w.count == 2, !w[1].hasPrefix("-") {
                // A project AppleScript (Word exporting the draft as a PDF): read like any project script. Inline code (-e) and anything
                // else osascript can be given stays with the person.
                switch file(w[1], at: here, language: "AppleScript") { case .failure(let r): return .failure(r); case .success(let s): return .success(Part(kind: "script", scripts: [s])) }
            }
            if systemTools.contains(name) { return refuse(changesMac) }
            if senders.contains(name) { return refuse(sendsOut) }
            if filters.contains(name) { return filter(name, Array(w.dropFirst()), at: here) }
            switch name {
            case "curl": return curl(Array(w.dropFirst()), at: here)
            case "wget": return wget(Array(w.dropFirst()), at: here)
            case "git": return git(Array(w.dropFirst()), at: here)
            case "pip", "pip3": return pip(Array(w.dropFirst()), at: here, venv: false)
            case "uv": return uv(Array(w.dropFirst()), at: here)
            case "npm", "pnpm", "yarn": return node(name, Array(w.dropFirst()), at: here)
            case "mkdir": return mkdir(Array(w.dropFirst()), at: here)
            case "pgrep": return pgrep(Array(w.dropFirst()))
            case "ps": return ps(Array(w.dropFirst()))
            default:
                guard let tool = interpreter(head, at: here) else { return refuse() }
                if tool == "python", w.count >= 3, w[1] == "-m", w[2] == "pip" { return pip(Array(w.dropFirst(3)), at: here, venv: false) }
                return run(w, at: here)
            }
        }
        // A project virtual environment's own pip or python: <venv>/bin/pip install …, <venv>/bin/python -m pip install …, <venv>/bin/python x.py.
        let name = (head as NSString).lastPathComponent
        if let bin = here.inside((head as NSString).deletingLastPathComponent), bin == "bin" || bin.hasSuffix("/bin") {
            if ["pip", "pip3"].contains(name) { return pip(Array(w.dropFirst()), at: here, venv: true) }
            if interpreter(head, at: here) == "python" {
                if w.count >= 3, w[1] == "-m", w[2] == "pip" { return pip(Array(w.dropFirst(3)), at: here, venv: true) }
                return run(w, at: here)
            }
        }
        if let browser = browsers[head] { return render(browser, Array(w.dropFirst()), at: here) }
        // A project file run directly: ./x.py, stages/…/x.sh.
        if head.contains("/") { return run(w, at: here) }
        return refuse()
    }
    /// Browsers an agent may run headless on a project file, by where they are installed.
    static let browsers: [String: String] = ["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome": "Chrome", "/Applications/Chromium.app/Contents/MacOS/Chromium": "Chromium",
                                             "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge": "Edge"]
    static let renderSwitches: Set<String> = ["--disable-gpu", "--no-first-run", "--no-default-browser-check", "--hide-scrollbars", "--disable-extensions", "--mute-audio",
                                              "--disable-background-networking", "--run-all-compositor-stages-before-draw", "--no-pdf-header-footer", "--print-to-pdf-no-header", "--disable-dev-shm-usage"]
    static let renderSizes: Set<String> = ["--window-size", "--virtual-time-budget", "--default-background-color", "--force-device-scale-factor", "--timeout"]
    /// A headless browser rendering one project file into the project: Forge's S04a figure, Chrome screenshotting a saved SVG to a PNG for the
    /// Word draft. Chrome is a program, not a script Buddy reads, so it read as "a script from outside the project" and went to the user. Its own
    /// profile and its output must be in the project or a temporary folder, and the page a file in the project; a page on the internet, the
    /// person's own profile (or none, which is theirs), a window, or any other option is not this.
    private static func render(_ browser: String, _ args: [String], at here: Here) -> Result<Part, Refusal> {
        var headless = false, profile: String?, outputs: [String] = [], pages: [String] = []
        for a in args {
            guard a.hasPrefix("--") else { pages.append(a); continue }
            let pair = a.split(separator: "=", maxSplits: 1).map(String.init), option = pair[0], value = pair.count == 2 ? pair[1] : nil
            switch option {
            case "--headless":
                guard value == nil || ["new", "old", "true"].contains(value ?? "") else { return refuse() }
                headless = true
            case "--user-data-dir":
                guard let value, let place = here.reachable(value) else { return refuse(writesOutside) }
                profile = place
            case "--screenshot", "--print-to-pdf":
                guard let place = here.reachable(value ?? (option == "--screenshot" ? "screenshot.png" : "output.pdf")) else { return refuse(writesOutside) }
                outputs.append(place)
            default:
                if renderSwitches.contains(option), value == nil { continue }
                guard renderSizes.contains(option), let value, value.range(of: #"^[A-Za-z0-9.,#]{1,32}$"#, options: .regularExpression) != nil else { return refuse() }
            }
        }
        guard headless, let profile, !outputs.isEmpty, pages.count == 1 else { return refuse() }
        var page = pages[0]
        if page.lowercased().hasPrefix("file:") {
            guard let url = URL(string: page), url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else { return refuse() }
            page = url.path
        } else if page.contains(":") { return refuse() }
        guard let shown = here.inside(page) else { return refuse(readsOutside) }
        return .success(Part(kind: "a headless \(browser) render of \(shown) into \(outputs.joined(separator: " and "))", writes: outputs + [profile]))
    }
    /// A program after a `|`: only a read-only text tool (it reads what comes before it and prints, or saves it in the project with tee).
    private static func piped(_ w: [String], at here: Here) -> Result<Part, Refusal> {
        guard let head = w.first, let name = program(head) else { return refuse() }
        if filters.contains(name) { return filter(name, Array(w.dropFirst()), at: here) }
        if senders.contains(name) || name == "curl" || name == "wget" { return refuse(sendsOut) }
        if systemTools.contains(name) { return refuse(changesMac) }
        return refuse()
    }

    // MARK: places

    /// Where a part of a command runs: the project (as the system really reaches it) and the folder in it, which the review's own working
    /// folder and each `cd` set. Paths are read from the folder and must stay in the project; places are named relative to the project.
    struct Here {
        let project: URL, folder: URL
        init(project: URL, place: String = ".") { self.project = project; folder = place == "." ? project : project.appendingPathComponent(place, isDirectory: true) }
        func inside(_ path: String) -> String? { BuddyCommandReview.inside(path, root: project, from: folder) }
        func url(_ place: String) -> URL { place == "." ? project : project.appendingPathComponent(place) }
        /// Where a part may write or read `path`: its place in the project, or how a file in a temporary folder is shown; nil for neither.
        func reachable(_ path: String) -> String? { inside(path) ?? BuddyCommandReview.temporary(path) }
    }
    private static func folder(_ place: String, in root: URL) -> Bool {
        var isFolder: ObjCBool = false
        return FileManager.default.fileExists(atPath: place == "." ? root.path : root.appendingPathComponent(place).path, isDirectory: &isFolder) && isFolder.boolValue
    }
    private static func canRead(_ path: String, _ here: Here) -> Bool { ["-", "/dev/null", "/dev/stdin"].contains(path) || here.reachable(path) != nil }

    /// `path` as a path relative to the project if it stays inside it (where it really leads: see `real`), else nil. A relative path is read
    /// from `from` (a folder in the project; the project itself when nil). A hard link looks like any other file, so one in the project that
    /// shares a file outside it is not told apart.
    static func inside(_ path: String, root: URL, from: URL? = nil) -> String? {
        guard !path.isEmpty, !path.hasPrefix("~"), !path.hasPrefix("-") else { return nil }
        let full = real(path.hasPrefix("/") ? path : ((from ?? root).path as NSString).appendingPathComponent(path)), base = real(root.path)
        guard full == base || full.hasPrefix(base + "/") else { return nil }
        return full == base ? "." : String(full.dropFirst(base.count + 1))
    }
    /// Where an absolute path really leads, as the system reads it: every link on the way is followed (also one whose target does not exist
    /// yet, since writing through it creates that target), and each `..` is taken from where the links before it lead (so `link/..` is the
    /// folder above the link's target, not the folder holding the link).
    static func real(_ path: String) -> String {
        let components = (path as NSString).pathComponents
        var pending = components.first == "/" ? Array(components.dropFirst()) : components, current = "/", hops = 0
        while !pending.isEmpty {
            let part = pending.removeFirst()
            if part == "." || part.isEmpty || part == "/" { continue }
            if part == ".." { current = (current as NSString).deletingLastPathComponent; continue }
            let next = (current as NSString).appendingPathComponent(part)
            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: next) {
                hops += 1
                guard hops <= 32 else { return "/" }   // a loop of links leads nowhere Buddy can name
                let parts = (target as NSString).pathComponents
                if target.hasPrefix("/") { current = "/"; pending = Array(parts.dropFirst()) + pending } else { pending = parts + pending }
                continue
            }
            current = next
        }
        return current
    }
    /// This Mac's per-user temporary folder ($TMPDIR, under /var/folders), without the trailing slash; nil when it is not such a folder.
    static let temporaryFolder: String? = {
        var folder = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
        while folder.count > 1, folder.hasSuffix("/") { folder.removeLast() }
        let full = BuddyCommandReview.real(folder)
        return folder.hasPrefix("/") && (full.hasPrefix("/private/var/folders/") || full.hasPrefix("/private/tmp/")) ? folder : nil
    }()
    static let temporaryRoots: [String] = [BuddyCommandReview.real("/tmp")] + (temporaryFolder.map { [BuddyCommandReview.real($0)] } ?? [])
    /// How a path in a temporary folder (/tmp, /private/tmp or $TMPDIR) is shown — as written, or as $TMPDIR/… — when `path` is absolute and
    /// still leads there after following links and `..`; else nil. With `file`, it must name something inside the folder by a plain name (a
    /// delete of /tmp itself, or of /tmp/*, is not a temporary file).
    static func temporary(_ path: String, file: Bool = false) -> String? {
        guard path.hasPrefix("/") else { return nil }
        let full = real(path)
        for root in temporaryRoots where full == root || full.hasPrefix(root + "/") {
            if file { guard full != root, let name = full.dropFirst(root.count + 1).split(separator: "/").first, !name.contains(where: { "*?[]{}".contains($0) }) else { return nil } }
            if let folder = temporaryFolder, path.hasPrefix(folder + "/") { return "$TMPDIR/" + path.dropFirst(folder.count + 1) }
            return path
        }
        return nil
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

    private static func curl(_ args: [String], at here: Here) -> Result<Part, Refusal> {
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
        if let folder, here.reachable(folder) == nil { return refuse(writesOutside) }
        for output in outputs where output != "-" {
            let path = output.hasPrefix("/") || folder == nil ? output : (base as NSString).appendingPathComponent(output)
            guard let place = here.reachable(path) else { return refuse(writesOutside) }
            writes.append(place)
        }
        if remoteName {
            for url in urls.dropFirst(outputs.count) {
                let name = URL(string: url)?.lastPathComponent ?? ""
                guard !name.isEmpty, name != "/", let place = here.reachable((base as NSString).appendingPathComponent(name)) else { return refuse(writesOutside) }
                writes.append(place)
            }
        }
        return .success(Part(kind: "a download from " + hosts.joined(separator: ", ") + into(writes), hosts: hosts, writes: writes))
    }
    private static func wget(_ args: [String], at here: Here) -> Result<Part, Refusal> {
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
        if let output, output != "-" { guard let place = here.reachable(output) else { return refuse(writesOutside) }; writes.append(place) }
        else if output == nil {
            for url in urls {
                let name = URL(string: url)?.lastPathComponent ?? ""
                guard let place = here.reachable(((folder ?? ".") as NSString).appendingPathComponent(name.isEmpty || name == "/" ? "index.html" : name)) else { return refuse(writesOutside) }
                writes.append(place)
            }
        }
        return .success(Part(kind: "a download from " + hosts.joined(separator: ", ") + into(writes), hosts: hosts, writes: writes))
    }

    // MARK: repositories and packages

    private static func git(_ args: [String], at here: Here) -> Result<Part, Refusal> {
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
            guard let place = here.inside(".git") else { return refuse() }
            return .success(Part(kind: "a fetch of a public repository from \(host) into the project", hosts: [host], writes: [place]))
        }
        guard positional.count <= 2 else { return refuse() }
        let name = ((URL(string: address)?.lastPathComponent ?? "") as NSString).deletingPathExtension
        guard let place = here.inside(positional.count == 2 ? positional[1] : name), !name.isEmpty || positional.count == 2 else { return refuse(writesOutside) }
        return .success(Part(kind: "a clone of a public repository from \(host) into the project", hosts: [host], writes: [place]))
    }
    private static let packageFlags: Set<String> = ["-U", "--upgrade", "--no-deps", "-q", "--quiet", "--no-cache-dir", "--disable-pip-version-check", "--prefer-binary", "--no-input", "--pre",
                                                    "--force-reinstall", "--no-warn-script-location", "--no-build-isolation", "--compile", "--no-compile"]
    private static let packageValues: Set<String> = ["-t", "--target", "-r", "--requirement", "-c", "--constraint", "--upgrade-strategy", "--only-binary", "--no-binary", "--python", "-p"]
    /// A package as written to an installer: a name with an optional version or extras, a public address, or a path in the project.
    private static func package(_ word: String, at here: Here) -> Result<String?, Refusal> {
        if word.contains("://") {
            let address = word.hasPrefix("git+") ? String(word.dropFirst(4)) : word
            switch publicHost(address) { case .success(let h): return .success(h); case .failure(let r): return .failure(r) }
        }
        if word.contains("/") || word.hasPrefix(".") || word.hasPrefix("file:") { return here.inside(word) == nil || word.hasPrefix("file:") ? .failure(Refusal(reason: "It installs from a place outside the project.")) : .success(nil) }
        guard word.range(of: #"^@?[A-Za-z0-9][A-Za-z0-9._\-]*(/[A-Za-z0-9._\-]+)?(\[[A-Za-z0-9,._\-]+\])?([<>=!~^@][A-Za-z0-9.*,<>=!~^_\-]*)?$"#, options: .regularExpression) != nil else { return .failure(Refusal(reason: unclear)) }
        return .success(nil)
    }
    private static func pip(_ args: [String], at here: Here, venv: Bool) -> Result<Part, Refusal> {
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
                    guard let place = here.inside(given ?? "") else { return refuse(option == "-t" || option == "--target" ? "It installs outside the project." : "It installs from a place outside the project.") }
                    if option == "-t" || option == "--target" { target = place } else { named += 1 }
                }
                i += 1; continue
            }
            if a.hasPrefix("-") { return refuse() }
            switch package(a, at: here) { case .failure(let r): return .failure(r); case .success: named += 1 }
            i += 1
        }
        guard named > 0 else { return refuse() }
        guard venv || target != nil else { return refuse("It installs outside the project (for the whole Mac or your account).") }
        return .success(Part(kind: "a package install into the project", hosts: ["pypi.org"], writes: [target ?? "its virtual environment"]))
    }
    private static func uv(_ args: [String], at here: Here) -> Result<Part, Refusal> {
        guard let sub = args.first else { return refuse() }
        if sub == "pip" {
            guard args.count >= 2, args[1] == "install" else { return refuse() }
            var rest = Array(args.dropFirst(2)), python: String?
            if let at = rest.firstIndex(where: { $0 == "--python" || $0 == "-p" }) { guard at + 1 < rest.count else { return refuse() }; python = rest[at + 1]; rest.removeSubrange(at...(at + 1)) }
            if let python { guard let place = here.inside(python), place.contains("/bin/") else { return refuse("It installs outside the project.") } }
            let hasTarget = rest.contains { $0 == "-t" || $0 == "--target" || $0.hasPrefix("--target=") }
            let projectVenv = FileManager.default.fileExists(atPath: here.folder.appendingPathComponent(".venv/bin/python").path)
            return pip(["install"] + rest, at: here, venv: python != nil || (!hasTarget && projectVenv))
        }
        guard ["sync", "add"].contains(sub) else { return refuse() }
        var named = 0
        for a in args.dropFirst() {
            if ["--frozen", "--locked", "-q", "--quiet", "--no-dev", "--dev", "--all-extras"].contains(a) { continue }
            if a.hasPrefix("-") { return refuse() }
            guard sub == "add" else { return refuse() }
            switch package(a, at: here) { case .failure(let r): return .failure(r); case .success: named += 1 }
        }
        if sub == "add", named == 0 { return refuse() }
        return .success(Part(kind: "a package install into the project", hosts: ["pypi.org"], writes: [here.inside(".venv") ?? ".venv"]))
    }
    private static func node(_ tool: String, _ args: [String], at here: Here) -> Result<Part, Refusal> {
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
            if case .failure(let r) = package(a, at: here) { return .failure(r) }
        }
        return .success(Part(kind: "a package install into the project", hosts: [tool == "npm" ? "registry.npmjs.org" : tool == "pnpm" ? "registry.npmjs.org" : "registry.yarnpkg.com"], writes: [here.inside("node_modules") ?? "node_modules"]))
    }
    private static func mkdir(_ args: [String], at here: Here) -> Result<Part, Refusal> {
        var writes: [String] = []
        for a in args {
            if a == "-p" { continue }
            if a.hasPrefix("-") { return refuse() }
            guard let place = here.reachable(a) else { return refuse(writesOutside) }
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
            // A letter that takes a value (-o columns, -p pids, …), alone or after others (`-axo pid,command`), with its value next or joined
            // (`-opid,command`). Never the environment (`env` columns, or `e`).
            if dashed, let at = letters.firstIndex(where: { "oOpUuGgt".contains($0) }) {
                let before = letters[..<at], joined = String(letters[letters.index(after: at)...])
                guard before.allSatisfy({ "AaCcfhjLlMmrSTvwxX".contains($0) }) else { return refuse() }
                if joined.isEmpty {
                    guard i + 1 < args.count, !args[i + 1].lowercased().contains("env") else { return refuse() }
                    i += 2
                } else {
                    guard !joined.lowercased().contains("env") else { return refuse() }
                    i += 1
                }
                continue
            }
            // `u` is the user format only in the old style without a dash (`ps aux`); with a dash it takes a user.
            guard letters.allSatisfy({ "AaCcfhjLlMmrSTvwxX".contains($0) || !dashed && $0 == "u" }) else { return refuse() }
            i += 1
        }
        return .success(Part(kind: processes))
    }

    // MARK: read-only text tools

    /// A read-only text tool's options: letters that only change what it shows, letters that take a value (how many lines, which fields, a
    /// pattern), and their long spellings (a long one with a value only as --name=value, which every version of the tool reads the same way;
    /// jq's own take theirs as the next word). None writes a file (sort -o, sed -i), runs a program (rg --pre, sed e, awk system), follows links
    /// out of the project (grep -R, rg -L) or waits forever (tail -f). Where the macOS and GNU versions of a tool disagree on whether an
    /// option takes a value, it is either left out or read as taking none, so Buddy checks every word the tool might read as a file.
    private struct Tool { let plain: String, valued: String; var attachedOnly = "", long: Set<String> = [], longValued: Set<String> = [] }
    private static let tools: [String: Tool] = [
        "head": Tool(plain: "qv", valued: "nc", long: ["--quiet", "--silent", "--verbose"], longValued: ["--lines", "--bytes"]),
        "tail": Tool(plain: "qrv", valued: "nc", long: ["--quiet", "--silent", "--verbose"], longValued: ["--lines", "--bytes"]),
        "cat": Tool(plain: "benstuvAETl", valued: "", long: ["--number", "--number-nonblank", "--squeeze-blank", "--show-all", "--show-ends", "--show-tabs", "--show-nonprinting"]),
        "wc": Tool(plain: "lwcmL", valued: "", long: ["--lines", "--words", "--bytes", "--chars", "--max-line-length"]),
        // BSD grep's -C takes its number only joined to it (-C3); GNU's also as the next word. Joined, both read it the same.
        "grep": Tool(plain: "iyEFGvcnlLhHowxsqIaUZzbr", valued: "efmABC", attachedOnly: "C",
                     long: ["--ignore-case", "--extended-regexp", "--fixed-strings", "--basic-regexp", "--invert-match", "--count", "--line-number", "--files-with-matches", "--files-without-match",
                            "--no-filename", "--with-filename", "--only-matching", "--word-regexp", "--line-regexp", "--no-messages", "--quiet", "--silent", "--text", "--null", "--recursive",
                            "--color", "--colour", "--byte-offset"],
                     longValued: ["--regexp", "--file", "--max-count", "--after-context", "--before-context", "--context", "--include", "--exclude", "--exclude-dir", "--color", "--colour", "--label"]),
        "rg": Tool(plain: "iSsFvcnNlwxoqHIauU0", valued: "efgtTmABCMjd",
                   long: ["--hidden", "--no-ignore", "--no-ignore-vcs", "--no-heading", "--heading", "--json", "--count", "--count-matches", "--files", "--files-with-matches", "--files-without-match",
                          "--line-number", "--no-line-number", "--fixed-strings", "--ignore-case", "--smart-case", "--case-sensitive", "--word-regexp", "--line-regexp", "--invert-match",
                          "--only-matching", "--stats", "--vimgrep", "--trim", "--no-messages", "--null", "--no-filename", "--with-filename", "--multiline", "--text", "--column", "--no-config"],
                   longValued: ["--regexp", "--file", "--glob", "--iglob", "--type", "--type-not", "--max-count", "--after-context", "--before-context", "--context", "--color", "--sort", "--sortr",
                                "--max-depth", "--max-columns", "--threads", "--max-filesize"]),
        "sort": Tool(plain: "bdfghiMnRrsuVcCmz", valued: "ktS", long: ["--numeric-sort", "--reverse", "--unique", "--ignore-case", "--human-numeric-sort", "--version-sort", "--general-numeric-sort",
                                                                       "--month-sort", "--stable", "--check", "--merge", "--ignore-leading-blanks", "--dictionary-order", "--random-sort"],
                     longValued: ["--key", "--field-separator", "--buffer-size", "--parallel"]),
        "uniq": Tool(plain: "cdDiuz", valued: "fs", long: ["--count", "--repeated", "--unique", "--ignore-case", "--zero-terminated"], longValued: ["--skip-fields", "--skip-chars"]),
        "cut": Tool(plain: "snwz", valued: "dfcb", long: ["--only-delimited", "--complement", "--zero-terminated"], longValued: ["--delimiter", "--fields", "--characters", "--bytes", "--output-delimiter"]),
        "tr": Tool(plain: "cCdsu", valued: ""),
        "column": Tool(plain: "tx", valued: "cs", long: ["--table", "--fillrows"], longValued: ["--separator", "--output-separator", "--columns"]),
        "tee": Tool(plain: "ai", valued: "", long: ["--append", "--ignore-interrupts"]),
        "sed": Tool(plain: "nErsuz", valued: "e", long: ["--quiet", "--silent", "--regexp-extended", "--posix", "--unbuffered", "--null-data", "--sandbox", "--debug", "--separate"], longValued: ["--expression"]),
        "awk": Tool(plain: "", valued: "Fv"),
        "jq": Tool(plain: "rjcSesnaCMR", valued: "", long: ["--raw-output", "--join-output", "--compact-output", "--sort-keys", "--exit-status", "--slurp", "--null-input", "--ascii-output",
                                                           "--color-output", "--monochrome-output", "--tab", "--raw-input", "--seq", "--stream", "--raw-output0"]),
    ]
    static let filters: Set<String> = Set(tools.keys).union(["egrep", "fgrep"])

    /// A read-only text tool with options from its list, reading only files in the project or a temporary folder (or what is piped to it) and,
    /// for tee, saving only there; sed only with a script that prints (`sedPrints`), awk only with a program that prints (`awkPrints`), and jq
    /// without the environment or modules. Its options come before its other words (so every version reads them the same way).
    private static func filter(_ name: String, _ args: [String], at here: Here) -> Result<Part, Refusal> {
        let key = name == "egrep" || name == "fgrep" ? "grep" : name
        guard let tool = tools[key] else { return refuse() }
        var values: [(flag: String, value: String)] = [], words: [String] = [], i = 0, rest = false, list = false
        while i < args.count {
            let a = args[i]; i += 1
            if rest || a == "-" || !a.hasPrefix("-") {
                if key == "tail", words.isEmpty, a.range(of: #"^\+\d+$"#, options: .regularExpression) != nil { continue }   // tail +5: from line 5
                words.append(a); continue
            }
            guard words.isEmpty else { return refuse() }   // an option after a file: some versions read it as one more file
            if a == "--" { rest = true; continue }
            if a.hasPrefix("--") {
                let parts = a.split(separator: "=", maxSplits: 1).map(String.init), option = parts[0]
                if tool.long.contains(option), parts.count == 1 { list = list || option == "--files"; continue }
                if tool.longValued.contains(option), parts.count == 2 { values.append((option, parts[1])); continue }
                // jq's --indent N, --arg NAME VALUE and --argjson NAME JSON: a number and values its filter reads as $NAME.
                if key == "jq", parts.count == 1, option == "--indent", i < args.count, Int(args[i]) != nil { i += 1; continue }
                if key == "jq", parts.count == 1, ["--arg", "--argjson"].contains(option), i + 1 < args.count { i += 2; continue }
                return refuse()
            }
            if key == "head" || key == "tail", a.dropFirst().allSatisfy(\.isNumber) { continue }   // head -20
            let letters = Array(a.dropFirst())
            var j = 0
            while j < letters.count {
                let letter = letters[j]
                if tool.plain.contains(letter) { j += 1; continue }
                guard tool.valued.contains(letter) else { return refuse() }
                let attached = j + 1 < letters.count ? String(letters[(j + 1)...]) : nil
                guard attached != nil || !tool.attachedOnly.contains(letter) else { return refuse() }
                guard let value = attached ?? (i < args.count ? args[i] : nil) else { return refuse() }
                if attached == nil { i += 1 }
                values.append(("-" + String(letter), value)); break
            }
        }
        var reads: [String] = [], writes: [String] = []
        switch key {
        case "grep", "rg":
            reads += values.filter { ["-f", "--file"].contains($0.flag) }.map(\.value)
            let patterned = list || values.contains { ["-e", "-f", "--regexp", "--file"].contains($0.flag) }
            guard patterned || !words.isEmpty else { return refuse() }
            reads += patterned ? words : Array(words.dropFirst())
        case "sed":
            let given = values.map(\.value)
            let scripts = given.isEmpty ? Array(words.prefix(1)) : given
            guard !scripts.isEmpty, scripts.allSatisfy(sedPrints) else { return refuse() }
            reads += given.isEmpty ? Array(words.dropFirst()) : words
        case "awk":
            guard let program = words.first, awkPrints(program) else { return refuse() }
            reads += words.dropFirst().filter { $0.range(of: #"^[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) == nil }   // var=value is a setting
        case "jq":
            guard let program = words.first, program.range(of: #"\benv\b|\$ENV\b|\$__loc__|\b(import|include)\b|\binput_filename\b"#, options: .regularExpression) == nil else { return refuse() }
            reads += words.dropFirst()
        case "tr": guard (1...2).contains(words.count) else { return refuse() }   // two sets of characters, no files
        case "uniq": guard words.count <= 1 else { return refuse() }; reads += words   // a second word is where uniq writes
        case "tee":
            for file in words where !["/dev/null", "/dev/stdout", "/dev/stderr"].contains(file) {
                guard let place = here.reachable(file) else { return refuse(writesOutside) }
                writes.append(place)
            }
        default: reads += words
        }
        for file in reads { guard canRead(file, here) else { return refuse(readsOutside) } }
        return .success(Part(kind: "read", writes: writes))
    }
    /// Whether a sed script only prints: addresses (numbers, $, /regex/, first~step, ranges, !), braces and the commands p P d D n N g G h H x
    /// l = z F q Q, s/…/…/ with only the flags g p i I m M and a count, and y/…/…/. Never w or W (write a file), r or R (read one), e (run a
    /// command), the s flags w and e, a, i or c (their text runs to the end of the line), or labels and branches.
    static func sedPrints(_ script: String) -> Bool {
        let c = Array(script.unicodeScalars)
        var i = 0
        func skipBlanks() { while i < c.count, c[i] == " " || c[i] == "\t" { i += 1 } }
        /// Past the next `d` not escaped by a backslash, on the same line.
        func through(_ d: Unicode.Scalar) -> Bool {
            while i < c.count { if c[i] == "\\" { i += 2; continue }; if c[i] == "\n" { return false }; if c[i] == d { i += 1; return true }; i += 1 }
            return false
        }
        func digits() { while i < c.count, ("0"..."9").contains(c[i]) { i += 1 } }
        func address() -> Bool {
            skipBlanks()
            guard i < c.count else { return true }
            if ("0"..."9").contains(c[i]) { digits(); if i < c.count, c[i] == "~" { i += 1; digits() }; return true }
            if c[i] == "$" { i += 1; return true }
            if c[i] == "/" { i += 1; guard through("/") else { return false }; while i < c.count, c[i] == "I" || c[i] == "M" { i += 1 }; return true }
            if c[i] == "\\", i + 1 < c.count { let d = c[i + 1]; i += 2; return through(d) }
            return true
        }
        while true {
            while i < c.count, [" ", "\t", "\n", ";"].contains(c[i]) { i += 1 }
            guard i < c.count else { return true }
            if c[i] == "#" { while i < c.count, c[i] != "\n" { i += 1 }; continue }
            guard address() else { return false }
            skipBlanks()
            if i < c.count, c[i] == "," {
                i += 1; skipBlanks()
                if i < c.count, c[i] == "+" || c[i] == "~" { i += 1; digits() } else { guard address() else { return false } }
            }
            skipBlanks()
            while i < c.count, c[i] == "!" { i += 1; skipBlanks() }
            guard i < c.count else { return false }
            let command = c[i]; i += 1
            switch command {
            case "p", "P", "d", "D", "n", "N", "g", "G", "h", "H", "x", "l", "=", "{", "}", "z", "F": break
            case "q", "Q": skipBlanks(); digits()
            case "s", "y":
                guard i < c.count, c[i] != "\n", c[i] != "\\", c[i] != " " else { return false }
                let d = c[i]; i += 1
                guard through(d), through(d) else { return false }
                if command == "s" { while i < c.count, "gpiImM0123456789".unicodeScalars.contains(c[i]) { i += 1 } }
            default: return false
            }
            if command == "{" { continue }   // a block's first command follows at once
            skipBlanks()
            guard i >= c.count || [";", "\n", "}", "#"].contains(c[i]) else { return false }
        }
    }
    /// Whether an awk program only reads its input and prints: no system(), getline (which reads files or a command's output), | to or from a
    /// command, print or printf redirected with > or |, ENVIRON or PROCINFO, changes to ARGV or ARGC (which choose the files it reads), and no
    /// @-extensions. Strings are left out first; for the | check also regular expressions (/a|b/), where one can start.
    static func awkPrints(_ program: String) -> Bool {
        var code = String.UnicodeScalarView()
        let c = Array(program.unicodeScalars)
        var i = 0
        while i < c.count {
            if c[i] == "\"" { code.append(contentsOf: "\"\"".unicodeScalars); i += 1; while i < c.count, c[i] != "\"" { if c[i] == "\\" { i += 1 }; i += 1 }; i += 1; continue }
            code.append(c[i]); i += 1
        }
        let text = String(code)
        if text.range(of: #"\b(system|getline|ENVIRON|PROCINFO|ARGV|ARGC)\b|@"#, options: .regularExpression) != nil { return false }
        for statement in text.components(separatedBy: CharacterSet(charactersIn: ";{}\n")) {
            if let print = statement.range(of: #"\bprintf?\b"#, options: .regularExpression), statement[print.upperBound...].contains(where: { $0 == ">" || $0 == "|" }) { return false }
        }
        var bare = "", previous: Character?
        let k = Array(text)
        i = 0
        while i < k.count {
            if k[i] == "/", previous.map({ "(,{;!~&|}\n".contains($0) }) ?? true {
                i += 1; while i < k.count, k[i] != "/" { if k[i] == "\\" { i += 1 }; i += 1 }; i += 1
                bare.append(" "); previous = "/"; continue
            }
            bare.append(k[i]); if !k[i].isWhitespace { previous = k[i] }; i += 1
        }
        return bare.range(of: #"(?<!\|)\|(?!\|)"#, options: .regularExpression) == nil
    }

    // MARK: project scripts

    /// A script as read, before it becomes a `Script`: its place relative to the project, its text for the pre-screen, and the folder the
    /// command runs it from.
    struct Loaded { let place: String, sha256: String, bytes: Int, inline: Bool, text: String, name: String, language: String, from: URL }
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
    static func interpreter(_ word: String, at here: Here) -> String? {
        let name = (word as NSString).lastPathComponent
        let tool = name.range(of: #"^python(3(\.\d+)?)?$"#, options: .regularExpression) != nil ? "python" : languages[name] != nil ? name : nil
        guard let tool else { return nil }
        if program(word) != nil { return tool }
        if tool == "python", let bin = here.inside((word as NSString).deletingLastPathComponent), bin == "bin" || bin.hasSuffix("/bin") { return tool }
        return nil
    }
    private static func run(_ w: [String], at here: Here) -> Result<Part, Refusal> {
        var loaded: [Loaded] = []
        if let refusal = invocation(w[...], at: here, into: &loaded, depth: 0) { return .failure(refusal) }
        return .success(Part(kind: "script", scripts: loaded))
    }
    /// One interpreter running a project script: `python3 [-u -B -X utf8 …] <path> | -m <project module> | -c <code>`, `node <path> | -e <code>`,
    /// `bash|sh|zsh [-eux] <path> | -c <code>`, `Rscript|ruby|perl <path> | -e <code>`, a project venv's bin/python, or a project file run
    /// directly (its first line names one of those, or none: the shell). Whatever follows is the script's arguments (`arguments`).
    private static func invocation(_ w: ArraySlice<String>, at here: Here, into loaded: inout [Loaded], depth: Int) -> Refusal? {
        guard depth < 4, let head = w.first else { return Refusal(reason: unclear) }
        var rest = w.dropFirst()
        guard let tool = interpreter(head, at: here) else {
            guard head.contains("/"), !head.hasPrefix("-") else { return Refusal(reason: unclear) }
            switch file(head, at: here, language: nil) { case .failure(let r): return r; case .success(let s): loaded.append(s) }
            return arguments(rest, at: here, into: &loaded, depth: depth)
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
                    loaded.append(Loaded(place: "", sha256: digest(data), bytes: data.count, inline: true, text: code, name: "inline \(language) code", language: language, from: here.folder))
                    rest = rest.dropFirst()
                }
                return arguments(rest, at: here, into: &loaded, depth: depth)
            }
            if tool == "python", a == "-m" {
                // A module counts only when it is a file of the project (python runs it from the folder the command runs in).
                guard let module = rest.dropFirst().first, module.range(of: #"^[A-Za-z_]\w*(\.[A-Za-z_]\w*)*$"#, options: .regularExpression) != nil else { return Refusal(reason: unclear) }
                let base = module.replacingOccurrences(of: ".", with: "/")
                guard let path = [base + ".py", base + "/__main__.py"].first(where: { FileManager.default.fileExists(atPath: here.folder.appendingPathComponent($0).path) }) else { return Refusal(reason: unclear) }
                switch file(path, at: here, language: language) { case .failure(let r): return r; case .success(let s): loaded.append(s) }
                return arguments(rest.dropFirst(2), at: here, into: &loaded, depth: depth)
            }
            guard let taken = option(a, next: rest.dropFirst().first, tool: tool) else { return Refusal(reason: unclear) }
            rest = rest.dropFirst(taken)
        }
        // No script: the interpreter would read its program from its input, which Buddy cannot see.
        guard let path = rest.first, path != "-" else { return Refusal(reason: unclear) }
        switch file(path, at: here, language: language) { case .failure(let r): return r; case .success(let s): loaded.append(s) }
        return arguments(rest.dropFirst(), at: here, into: &loaded, depth: depth)
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
    /// script, read like the first; and a path that leaves the project (other than for a temporary folder) sends the command to the person.
    private static func arguments(_ args: ArraySlice<String>, at here: Here, into loaded: inout [Loaded], depth: Int) -> Refusal? {
        var rest = args
        while let a = rest.first {
            if interpreter(a, at: here) != nil { return invocation(rest, at: here, into: &loaded, depth: depth + 1) }
            if let name = program(a), wrapped.contains(name) { return Refusal(reason: unclear) }
            let value = a.hasPrefix("-") ? (a.firstIndex(of: "=").map { String(a[a.index(after: $0)...]) } ?? "") : a
            if !value.isEmpty, !value.contains("://") {
                if let language = extensions[(value as NSString).pathExtension.lowercased()] {
                    switch file(value, at: here, language: language) { case .failure(let r): return r; case .success(let s): loaded.append(s) }
                } else if value.hasPrefix("/") || value.hasPrefix("~") || value == ".." || value.hasPrefix("../") || value.contains("/../") || value.hasSuffix("/..") {
                    guard here.reachable(value) != nil else { return Refusal(reason: "It points a script at a place outside the project.") }
                }
            }
            rest = rest.dropFirst()
        }
        return nil
    }
    /// A project script, read once: inside the project (after following links), a regular text file of at most 64 KB. Run directly
    /// (`language` nil), its first line must name an interpreter Buddy reads, or none (the shell runs it).
    private static func file(_ path: String, at here: Here, language: String?) -> Result<Loaded, Refusal> {
        guard !path.hasPrefix("-") else { return .failure(Refusal(reason: unclear)) }
        guard let place = here.inside(path), place != "." else { return .failure(Refusal(reason: "It runs a script from outside the project.")) }
        let url = here.url(place), name = (place as NSString).lastPathComponent
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
                guard let first = words.first, let tool = interpreter(first, at: here) else { return .failure(Refusal(reason: unclear)) }
                var flags = words.dropFirst()
                while let flag = flags.first { guard let taken = option(flag, next: flags.dropFirst().first, tool: tool) else { return .failure(Refusal(reason: unclear)) }; flags = flags.dropFirst(taken) }
                language = languages[tool]
            } else { language = "shell" }
        }
        return .success(Loaded(place: place, sha256: digest(data), bytes: data.count, inline: false, text: text, name: name, language: language ?? "shell", from: here.folder))
    }
    /// The verdict on a command that runs project scripts: each one is read for what is on the person's list (`screen`); a hit sends the
    /// command to the person with what Buddy saw, and nothing found gives it to the supervisor, who reads them in full.
    private static func scripted(_ found: [Loaded], writes: [String], project: URL) -> Verdict {
        var seen = Set<String>(), list: [Loaded] = []
        for s in found where seen.insert(s.inline ? "inline:" + s.sha256 : s.place).inserted { list.append(s) }
        guard list.count <= maxScripts else { return sensitive("It runs more than \(maxScripts) scripts; Buddy reads at most \(maxScripts) for one command, so you decide.") }
        let records = list.map { Script(path: $0.inline ? $0.name : $0.place, sha256: $0.sha256, bytes: $0.bytes, inline: $0.inline, code: $0.inline ? $0.text : nil) }
        func unique(_ items: [String]) -> [String] { Array(NSOrderedSet(array: items)) as? [String] ?? items }
        let files = unique(list.filter { !$0.inline }.map(\.name)), inline = unique(list.filter(\.inline).map(\.name))
        let runs = "Runs " + listed((files.isEmpty ? [] : [(files.count == 1 ? "the project script " : "the project scripts ") + listed(files)]) + inline) + "."
        for s in list {
            let folder = s.inline ? s.from : project.appendingPathComponent(s.place).deletingLastPathComponent()
            if let concern = screen(s.text, subject: s.inline ? "The " + s.name : "The script " + s.name, language: s.language, project: project, root: s.from, folder: folder) {
                return Verdict(routine: false, reason: concern, hosts: [], writes: [], scripts: records, runs: runs)
            }
        }
        return Verdict(routine: false, reason: runs, hosts: [], writes: writes, script: true, scripts: records, runs: runs)
    }

    // MARK: the pre-screen

    /// A heuristic net, not the judge: it reads a script's code for what plainly does something on the person's list, and a hit sends the
    /// command to the person; finding nothing only means the supervisor reads it next. It reads code, not comments or plain text (see
    /// `scanned`): comments, Python docstrings and Ruby/Perl documentation are left out, and secret words count only as names in the code or
    /// as a path, setting name or single word in a string ('~/.pgpass', os.environ["DB_PASSWORD"], "keychain") — never inside a message such as
    /// print("No credentials were used"); Python's own `secrets` module (random numbers) is not a secret.
    /// It looks for (1) secrets: the marks above, environment reads of password, token or key names, the Keychain and `security`, ~/.ssh,
    /// ~/.pgpass, browsers' cookies and saved logins; (2) sending data out: HTTP POST/PUT/PATCH and uploads (requests, httpx, urllib, fetch,
    /// axios, curl -d/-F/-T, wget --post), mail, sockets, ssh/scp/rsync/ftp, cloud storage clients, git push and webhooks; (3) changing the Mac:
    /// sudo, brew/port/softwareupdate/installer, account- or system-wide package installs, launchctl and login items, defaults write, osascript,
    /// system settings tools, hdiutil attach of something outside the project, and writing to /Applications or ~/Library; (4) deleting or
    /// writing outside the project: a delete or write on a line that names an absolute path outside the project, the home folder or a `..` that
    /// leaves it, and any recursive delete in a file that names such a path anywhere. Files in a temporary folder (/tmp/…, /private/tmp/…,
    /// $TMPDIR/…) are not outside the project here; deleting /tmp itself or a wildcard in it still is.
    /// Blind spots: it does not follow what a script imports, names or values built at run time or passed through variables to a write on
    /// another line, or what a program it starts does on its own; a string message with a path-like word in it ("see ~/.ssh") still counts;
    /// and a script written to confuse the reading (strings nested inside Python f-strings or shell substitutions in ways it does not follow,
    /// regular expressions or heredocs holding comment marks, Ruby and Perl quoting forms) can hide code from it, as can any obfuscation. The
    /// supervisor still reads every script in full.
    static func screen(_ text: String, subject: String, language: String, project: URL, root: URL, folder: URL) -> String? {
        let (code, words) = scanned(text, language: language)
        func hit(_ rules: [NSRegularExpression], in text: String) -> String? {
            for rule in rules { if let found = first(rule, in: text) { return label(found) } }
            return nil
        }
        if let found = hit(secretRules, in: words) ?? hit([keychain], in: code) { return "\(subject) reads passwords, keys or tokens (\(found))." }
        if let found = hit(sendRules + (language == "shell" ? [shellSends] : []), in: code) { return "\(subject) can send data out of this Mac (\(found))." }
        // An AppleScript tells applications what to do; that alone changes nothing on the Mac (Word exporting a draft as a PDF). Telling Finder,
        // System Events (keystrokes, clicks), Mail, Messages, Terminal or the settings apps, or running shell commands, stays with the person.
        var scanned = code
        if language == "AppleScript" {
            if let found = hit([appleScriptReach], in: code) { return "\(subject) changes this Mac or acts for you in another app (\(found))." }
            scanned = code.replacingOccurrences(of: #"tell\s+application"#, with: "tell app", options: [.regularExpression, .caseInsensitive])
        }
        if let found = hit(macRules, in: scanned) { return "\(subject) changes this Mac (\(found))." }
        var named: String?
        for line in code.components(separatedBy: .newlines) {
            let refs = outside(line, project: project, root: root, folder: folder, deleting: first(deletes, in: line) != nil)
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
        if let named, let op = first(recursiveDelete, in: code) { return "\(subject) deletes or writes files outside the project (\(label(op)) \(label(named)))." }
        return nil
    }
    /// The places outside the project a line names: absolute paths (except /dev/null and the like, and files in a temporary folder), the home
    /// folder in any of its spellings, and `..` paths that leave the project when read from the script's folder or from where the command runs.
    private static func outside(_ line: String, project: URL, root: URL, folder: URL, deleting: Bool) -> [String] {
        var refs: [String] = []
        for path in all(absolutePath, in: line) where !["/dev/null", "/dev/stdout", "/dev/stderr", "/dev/tty"].contains(path) {
            if inside(path, root: project) == nil, temporary(path, file: deleting) == nil { refs.append(path) }
        }
        if let home = first(homeRef, in: line) { refs.append(home) }
        for path in all(parentPath, in: line) where inside(path, root: project, from: folder) == nil || inside(path, root: project, from: root) == nil { refs.append(path) }
        return refs
    }

    /// A script as the pre-screen reads it. `code` is the script without its comments (#… in Python, shell, R, Ruby and Perl; //… and /*…*/
    /// in JavaScript), Python docstrings, Ruby =begin…=end and Perl POD blocks, and its #! line; strings stay whole, since commands, paths and
    /// addresses live in them. `words` is that code with the plain text of its strings left out: a string with a space in it keeps only the
    /// words that look like a path, a name or code (a /, ~, $, {, }, = or _ in them, or a dot inside them), so "No credentials or secrets were
    /// used" says nothing while '~/.pgpass', 'DB_PASSWORD', f"{token}" or "cat ~/.ssh/id_rsa" still do; Python's own `secrets` module (random
    /// numbers) is left out of it too. Both keep the script's line breaks. It reads Unicode scalars, as the interpreters do, so a quote with a
    /// combining mark on it is still a quote; it follows backslash escapes, Python's prefixed, triple-quoted and f-strings (also with strings
    /// inside their braces), shell's single quotes (no escapes), $'…' and $(…) inside double quotes, and JavaScript's template strings (not
    /// templates nested inside them) and regular expressions.
    static func scanned(_ text: String, language: String) -> (code: String, words: String) {
        let c = Array(text.unicodeScalars), n = c.count
        let python = language == "Python", shell = language == "shell", js = language == "JavaScript"
        var code = String.UnicodeScalarView(), words = String.UnicodeScalarView(), i = 0
        var depth = 0, lineStart = true, continued = false, previous: Unicode.Scalar?
        func at(_ k: Int) -> Unicode.Scalar? { k >= 0 && k < n ? c[k] : nil }
        /// A line break as any of these languages may end a comment with: a comment that ends early only leaves more code to read.
        func breaks(_ s: Unicode.Scalar?) -> Bool { s.map { ["\n", "\r", "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}"].contains($0) } ?? false }
        func one(_ set: String, _ s: Unicode.Scalar?) -> Bool { s.map { set.unicodeScalars.contains($0) } ?? false }
        func letter(_ s: Unicode.Scalar?) -> Bool { s.map { $0.isASCII && $0.properties.isAlphabetic } ?? false }
        func identifier(_ s: Unicode.Scalar?) -> Bool { s.map { $0.properties.isAlphabetic || ("0"..."9").contains($0) || $0 == "_" } ?? false }
        func emit(_ from: Int, _ to: Int) { code.append(contentsOf: c[from..<to]); words.append(contentsOf: c[from..<to]) }
        func blank(_ from: Int, _ to: Int) { for s in c[from..<to] { let k: Unicode.Scalar = breaks(s) ? "\n" : " "; code.append(k); words.append(k) } }
        func lineEnd() { while i < n, !breaks(c[i]) { i += 1 } }
        func starts(_ s: String) -> Bool { s.unicodeScalars.enumerated().allSatisfy { at(i + $0.offset) == $0.element } }
        func statementEnds(_ k: Int) -> Bool { var k = k; while one(" \t", at(k)) { k += 1 }; return k >= n || breaks(at(k)) || one("#;", at(k)) }
        /// The word just before i in the code (JavaScript: `return /re/` starts a regular expression).
        func wordBefore() -> String { var k = i - 1; while one(" \t", at(k)) { k -= 1 }; var w = ""; while identifier(at(k)) { w.unicodeScalars.insert(c[k], at: w.unicodeScalars.startIndex); k -= 1 }; return w }
        if starts("#!") { lineEnd() }
        while i < n {
            let ch = c[i]
            // Documentation blocks, each to the end of its closing line: Ruby =begin … =end, Perl POD (=head1, =pod … =cut).
            if i == 0 || breaks(at(i - 1)), ch == "=", (language == "Ruby" && starts("=begin")) || (language == "Perl" && letter(at(i + 1))) {
                let start = i, end = language == "Ruby" ? "=end" : "=cut"
                repeat { lineEnd(); if i < n { i += 1 } } while i < n && !starts(end)
                lineEnd(); blank(start, i); continue
            }
            if js, ch == "/" {
                if at(i + 1) == "/" { lineEnd(); continue }
                if at(i + 1) == "*" { let start = i; i += 2; while i < n, !(c[i] == "*" && at(i + 1) == "/") { i += 1 }; i = min(n, i + 2); blank(start, i); continue }
                if previous == nil || one("(,=:[!&|?{};+-*%<>~^", previous) || ["return", "typeof", "case", "do", "else", "in", "of", "void", "yield", "await", "delete", "new", "instanceof", "throw"].contains(wordBefore()) {
                    // A regular expression: its quotes and slashes are neither strings nor comments.
                    let start = i; i += 1
                    var inClass = false
                    while i < n, !breaks(c[i]) {
                        if c[i] == "\\" { i += 2; continue }
                        if c[i] == "[" { inClass = true } else if c[i] == "]" { inClass = false } else if c[i] == "/", !inClass { i += 1; break }
                        i += 1
                    }
                    i = min(i, n); emit(start, i); previous = "/"; lineStart = false; continue
                }
            }
            if ch == "#", !js {
                let before = at(i - 1)
                let comment = shell ? before == nil || breaks(before) || one(" \t;&|()", before)
                    : language == "Perl" ? before == nil || breaks(before) || one(" \t;{}()", before) : true
                if comment { lineEnd(); continue }
            }
            if ch == "'" || ch == "\"" || (js && ch == "`") {
                let start = i
                var prefix = "", k = i - 1
                while letter(at(k)), prefix.count < 2 { prefix.unicodeScalars.insert(c[k], at: prefix.unicodeScalars.startIndex); k -= 1 }
                let fString = python && !identifier(at(k)) && prefix.lowercased().contains("f") && prefix.lowercased().allSatisfy({ "rfbu".contains($0) })
                let triple = python && at(i + 1) == ch && at(i + 2) == ch
                let literal = shell && ch == "'" && at(i - 1) != "$"   // shell's single quotes have no escapes ($'…' has them)
                let mark = triple ? 3 : 1
                i += mark
                let open = i
                var close = -1, braces = 0, substitutions = 0
                while i < n {
                    let s = c[i]
                    if s == "\\", !literal { i += 2; continue }
                    if fString {
                        if braces == 0, s == "{", at(i + 1) == "{" { i += 2; continue }
                        if s == "{" { braces += 1; i += 1; continue }
                        if braces > 0, s == "}" { braces -= 1; i += 1; continue }
                        if braces > 0, s == "'" || s == "\"" { i += 1; while i < n, c[i] != s, !breaks(c[i]) { if c[i] == "\\" { i += 1 }; i += 1 }; i += 1; continue }
                    }
                    if shell, ch == "\"" {
                        if s == "$", at(i + 1) == "(" { substitutions += 1; i += 2; continue }
                        if substitutions > 0, s == ")" { substitutions -= 1; i += 1; continue }
                        if substitutions > 0, s == "'" || s == "\"" { i += 1; while i < n, c[i] != s { if c[i] == "\\", s == "\"" { i += 1 }; i += 1 }; i += 1; continue }
                    }
                    if s == ch, braces == 0, substitutions == 0, !triple || (at(i + 1) == ch && at(i + 2) == ch) { close = i; i += mark; break }
                    if python, !triple, s == "\n" || s == "\r" { break }   // a one-line Python string ends with its line
                    i += 1
                }
                i = min(i, n)
                let end = close >= 0 ? close : i
                if python, triple, depth == 0, lineStart, !continued, statementEnds(i) { blank(start, i); lineStart = false; continue }   // a docstring
                code.append(contentsOf: c[start..<i])
                words.append(contentsOf: c[start..<open])
                words.append(contentsOf: plainLeftOut(String(String.UnicodeScalarView(c[open..<end]))).unicodeScalars)
                words.append(contentsOf: c[end..<i])
                previous = ch; lineStart = false; continue
            }
            if ch == "\\", i + 1 < n {
                // An escaped character outside strings (a shell \#, a JavaScript \/, a Python line continuation) is neither a quote nor a comment.
                var to = i + 2
                if c[i + 1] == "\r", at(i + 2) == "\n" { to = i + 3 }
                if breaks(c[i + 1]) { continued = true; lineStart = true }
                emit(i, to); i = to; continue
            }
            if python { if one("([{", ch) { depth += 1 } else if one(")]}", ch), depth > 0 { depth -= 1 } }
            if breaks(ch) { lineStart = true; continued = false } else if ch != " ", ch != "\t" { lineStart = false; previous = ch }
            emit(i, i + 1); i += 1
        }
        var plain = String(words)
        if python { for (rule, template) in secretsModule { plain = rule.stringByReplacingMatches(in: plain, range: NSRange(plain.startIndex..., in: plain), withTemplate: template) } }
        return (String(code), plain)
    }
    /// A string's text as the secret check reads it: whole when it is one word, else only its words that look like a path, a name or code.
    private static func plainLeftOut(_ content: String) -> String {
        guard content.contains(where: \.isWhitespace) else { return content }
        var out = "", word = ""
        func flush() { out += word.range(of: #"[/~${}=_]|\.[A-Za-z0-9]"#, options: .regularExpression) != nil ? word : String(repeating: " ", count: word.count); word = "" }
        for ch in content { if ch.isWhitespace { flush(); out.append(ch) } else { word.append(ch) } }
        flush()
        return out
    }
    /// Python's `secrets` module makes random tokens; importing or using it reads no secret.
    private static let secretsModule: [(NSRegularExpression, String)] = [
        (rx(#"^[ \t]*from[ \t]+secrets[ \t]+import\b[^\n]*"#, caseless: false), ""),
        (rx(#"^([ \t]*import\b[^\n]*?)\bsecrets\b([ \t]+as[ \t]+\w+)?"#, caseless: false), "$1"),
        (rx(#"\bsecrets[ \t]*\.[ \t]*(token_hex|token_urlsafe|token_bytes|choice|randbelow|randbits|compare_digest|SystemRandom)\b"#, caseless: false), "random"),
        (rx(#"\btoken_(hex|urlsafe|bytes)\b"#, caseless: false), "random"),
    ]
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
    /// Secrets, read in `words` (the code with plain text left out of its strings).
    private static let secretRules: [NSRegularExpression] = [
        rx(#"\.ssh|id_rsa|id_ed25519|id_ecdsa|\.pgpass|\.netrc|\.aws/|\.npmrc|\.pypirc|\.git-credentials|\.docker/config|keychain|keyring|dotenv|login data|cookies\.(binarycookies|sqlite)|/cookies\b|logins\.json|key4\.db|library/application support|pgpassword|api_?key|credential|passw(or)?d|secret|/etc/"#),
        rx(#"(?<![a-z0-9_])\.env(?![a-z0-9_])"#),
        rx(#"token(?!i[sz]|s\b)"#),
        rx(#"(os\.environ|getenv|process\.env|\benv\s*\[|\$env\{|\bENV\s*\[)[^\n]{0,60}?(pass|token|secret|key|auth|cred)"#),
    ]
    /// The Keychain through its command-line tool or API, read in the code with its strings whole ("security find-generic-password -s x").
    private static let keychain = rx(#"\bsecurity['"\s,]+(find-|dump-keychain|export|unlock-keychain|add-generic|add-internet|delete-)|SecItemCopyMatching|SecKeychain"#)
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
    private static let appleScriptReach = rx(#"tell\s+application\s+(id\s+)?"(Finder|System Events|Mail|Messages|Terminal|iTerm2?|System Settings|System Preferences|Keychain Access|Script Editor|Shortcuts|Automator|com\.apple\.[A-Za-z.]+)"|do\s+shell\s+script|\bkeystroke\b|\bkey\s+code\b"#)
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
        let root = URL(fileURLWithPath: real(project), isDirectory: true)
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
