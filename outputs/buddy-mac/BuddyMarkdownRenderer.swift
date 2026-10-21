// Reused from our Markdown Viewer: Sources/Renderer.swift
import Foundation

/// A heading in the rendered document: what the outline lists and the page scrolls to.
struct BuddyViewerHeading: Identifiable, Hashable {
    let id: String
    let level: Int
    let title: String
}

struct BuddyViewerRenderedDocument {
    var html: String
    var headings: [BuddyViewerHeading]
    /// What the window says under the title: how long the document is.
    var caption: String
}

/// Markdown to HTML.
///
/// The parsing is the system's own: `AttributedString(markdown:)` in `.full` mode is
/// cmark-gfm, and it reports every run of text with the chain of blocks it sits in
/// (`paragraph < listItem < unorderedList`), each block carrying an identity. This
/// file rebuilds the block tree from those chains and writes it out as HTML, so the
/// app uses the system Markdown parser. Math is typeset separately by bundled KaTeX.
enum BuddyViewerMarkdownRenderer {

    static func render(_ source: String) -> BuddyViewerRenderedDocument {
        let text = source.replacingOccurrences(of: "\r\n", with: "\n")
        let (frontMatter, body) = splitFrontMatter(text)
        let math = BuddyViewerMarkdownMath(body)
        let builder = Builder(math: math)

        if let frontMatter {
            builder.root.html += "<pre class=\"front-matter\"><code>"
                + BuddyViewerHighlighter.highlight(frontMatter, language: "yaml") + "</code></pre>\n"
        }

        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        if let parsed = try? AttributedString(markdown: math.text, options: options) {
            for run in parsed.runs {
                builder.add(run, text: String(parsed[run.range].characters))
            }
        } else {
            builder.root.html += "<pre><code>" + BuddyViewerescapeHTML(body) + "</code></pre>\n"
        }

        var html = math.restore(builder.finish())
        if html.isEmpty { html = "<p class=\"empty\">This document is empty.</p>\n" }
        return BuddyViewerRenderedDocument(html: html, headings: builder.headings, caption: caption(words: countWords(body)) + (math.limited ? " · Further equations shown as source" : ""))
    }

    private static func caption(words: Int) -> String {
        guard words > 0 else { return "" }
        let minutes = max(1, Int((Double(words) / 230).rounded()))
        return "\(words.formatted()) words · \(minutes) min read"
    }

    /// YAML front matter is a `---` fence on the first line, closed by another, whose
    /// first line is a key. The key test is what keeps a document that merely opens
    /// with a horizontal rule from losing its first section.
    static func splitFrontMatter(_ text: String) -> (frontMatter: String?, body: String) {
        guard text.hasPrefix("---\n") else { return (nil, text) }
        let rest = text.dropFirst(4)
        guard let firstLine = rest.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first,
              let colon = firstLine.firstIndex(of: ":"),
              colon != firstLine.startIndex,
              firstLine[..<colon].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == " " })
        else { return (nil, text) }

        var lineStart = rest.startIndex
        while lineStart < rest.endIndex {
            let lineEnd = rest[lineStart...].firstIndex(of: "\n") ?? rest.endIndex
            let line = rest[lineStart..<lineEnd]
            if line == "---" || line == "..." {
                let frontMatter = String(rest[rest.startIndex..<lineStart])
                    .trimmingCharacters(in: .newlines)
                let body = lineEnd < rest.endIndex ? String(rest[rest.index(after: lineEnd)...]) : ""
                return (frontMatter, body)
            }
            lineStart = lineEnd < rest.endIndex ? rest.index(after: lineEnd) : rest.endIndex
        }
        return (nil, text)
    }

    static func countWords(_ text: String) -> Int {
        var count = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            let isWord = CharacterSet.alphanumerics.contains(scalar)
            if isWord && !inWord { count += 1 }
            inWord = isWord || (inWord && (scalar == "'" || scalar == "\u{2019}" || scalar == "-"))
        }
        return count
    }
}

// MARK: - Source files

/// A text file shown as written: one numbered line per line, coloured where the
/// language is known.
enum BuddyViewerSourceRenderer {

    static func render(_ source: String, language: String?) -> BuddyViewerRenderedDocument {
        var text = source.replacingOccurrences(of: "\r\n", with: "\n")
        if text.hasSuffix("\n") { text.removeLast() }

        // The highlighter never lets a tag span a line break, so cutting its output
        // at the breaks leaves every line whole.
        let lines = BuddyViewerHighlighter.highlight(text, language: language)
            .split(separator: "\n", omittingEmptySubsequences: false)
        var html = "<pre class=\"source\"><code>"
        for line in lines {
            html += "<span class=\"line\">\(line)</span>"
        }
        html += "</code></pre>\n"

        let caption = text.isEmpty ? "Empty" : "\(lines.count.formatted()) \(lines.count == 1 ? "line" : "lines")"
        return BuddyViewerRenderedDocument(html: html, headings: [], caption: caption)
    }
}

// MARK: - Block tree

/// One open block. Its children's HTML accumulates in `html` and is wrapped when the
/// block closes, which is what lets a heading know its whole title before it is
/// written and a table row fill the cells the parser never mentioned.
private final class Node {
    let kind: PresentationIntent.Kind?
    let identity: Int
    var html = ""
    var plain = ""
    var link: URL?
    var isTask = false
    var hasTasks = false
    var firstOrdinal: Int?
    var cells: [Int: String] = [:]

    init(kind: PresentationIntent.Kind?, identity: Int) {
        self.kind = kind
        self.identity = identity
    }
}

private final class Builder {
    let root = Node(kind: nil, identity: -1)
    private(set) var headings: [BuddyViewerHeading] = []
    private lazy var stack: [Node] = [root]
    private var slugs: [String: Int] = [:]
    private let math: BuddyViewerMarkdownMath

    init(math: BuddyViewerMarkdownMath) { self.math = math }

    func add(_ run: AttributedString.Runs.Run, text: String) {
        let inline = run.inlinePresentationIntent ?? []

        // An HTML block arrives with no block of its own and no word on where it
        // nests, so it is written at the top level, where nearly all of them are.
        guard let intent = run.presentationIntent else {
            close(downTo: 1)
            let isHTML = inline.contains(.blockHTML) || inline.contains(.inlineHTML)
            root.html += isHTML ? text : "<p>" + BuddyViewerescapeHTML(text) + "</p>\n"
            return
        }

        // The chain is innermost-first; the stack is outermost-first under the root.
        let path = Array(intent.components.reversed())
        var shared = 0
        while shared < path.count, shared + 1 < stack.count,
              stack[shared + 1].identity == path[shared].identity {
            shared += 1
        }
        close(downTo: shared + 1)
        for component in path[shared...] {
            stack.append(Node(kind: component.kind, identity: component.identity))
        }
        appendInline(run, inline: inline, text: text)
    }

    func finish() -> String {
        close(downTo: 1)
        return root.html
    }

    // MARK: Inline

    private func appendInline(_ run: AttributedString.Runs.Run,
                              inline: InlinePresentationIntent, text: String) {
        let node = stack[stack.count - 1]
        var text = text

        switch node.kind {
        case .codeBlock?:
            node.plain += text
            return
        case .thematicBreak?:
            return
        default:
            break
        }

        // "- [ ] task": the parser leaves the marker in the item's first run.
        if case .paragraph? = node.kind, node.html.isEmpty, inline.isEmpty, run.link == nil,
           stack.count >= 2 {
            let item = stack[stack.count - 2]
            if case .listItem? = item.kind, item.html.isEmpty, !item.isTask,
               let (checked, rest) = Self.taskMarker(text) {
                item.isTask = true
                node.html += "<input type=\"checkbox\" tabindex=\"-1\"\(checked ? " checked" : "")>"
                text = rest
            }
        }

        if run.link != node.link {
            if node.link != nil { node.html += "</a>" }
            if let link = run.link {
                node.html += "<a href=\"\(BuddyViewerescapeHTML(link.absoluteString))\">"
            }
            node.link = run.link
        }

        if let image = run.imageURL {
            node.html += "<img src=\"\(BuddyViewerescapeHTML(image.absoluteString))\" alt=\"\(BuddyViewerescapeHTML(text))\">"
            node.plain += text
            return
        }
        if inline.contains(.inlineHTML) || inline.contains(.blockHTML) {
            node.html += text
            return
        }
        if inline.contains(.lineBreak) {
            node.html += "<br>\n"
            node.plain += " "
            return
        }
        if inline.contains(.softBreak) {
            node.html += "\n"
            node.plain += " "
            return
        }

        var piece = BuddyViewerescapeHTML(text)
        if inline.contains(.code) { piece = "<code>\(piece)</code>" }
        if inline.contains(.strikethrough) { piece = "<del>\(piece)</del>" }
        if inline.contains(.emphasized) { piece = "<em>\(piece)</em>" }
        if inline.contains(.stronglyEmphasized) { piece = "<strong>\(piece)</strong>" }
        node.html += piece
        node.plain += text
    }

    private static func taskMarker(_ text: String) -> (checked: Bool, rest: String)? {
        for (marker, checked) in [("[ ]", false), ("[x]", true), ("[X]", true)] {
            if text == marker { return (checked, "") }
            if text.hasPrefix(marker + " ") { return (checked, String(text.dropFirst(4))) }
        }
        return nil
    }

    // MARK: Closing blocks

    private func close(downTo count: Int) {
        while stack.count > count {
            let node = stack.removeLast()
            emit(node, into: stack[stack.count - 1])
        }
    }

    private func emit(_ node: Node, into parent: Node) {
        if node.link != nil {
            node.html += "</a>"
            node.link = nil
        }
        guard let kind = node.kind else {
            parent.html += node.html
            return
        }

        switch kind {
        case .paragraph:
            parent.html += "<p>\(node.html)</p>\n"

        case .header(let level):
            let title = math.plain(node.plain).trimmingCharacters(in: .whitespacesAndNewlines)
            let id = slug(title)
            headings.append(BuddyViewerHeading(id: id, level: level, title: title))
            parent.html += "<h\(level) id=\"\(BuddyViewerescapeHTML(id))\">\(node.html)</h\(level)>\n"

        case .orderedList:
            let start = node.firstOrdinal ?? 1
            parent.html += "<ol\(start == 1 ? "" : " start=\"\(start)\"")>\n\(node.html)</ol>\n"

        case .unorderedList:
            parent.html += "<ul\(node.hasTasks ? " class=\"task-list\"" : "")>\n\(node.html)</ul>\n"

        case .listItem(let ordinal):
            if parent.firstOrdinal == nil { parent.firstOrdinal = ordinal }
            if node.isTask { parent.hasTasks = true }
            parent.html += "<li\(node.isTask ? " class=\"task\"" : "")>\(node.html)</li>\n"

        case .codeBlock(let hint):
            // "python title=x" and "{r, echo=FALSE}" both name a language first.
            let language = hint?
                .split(whereSeparator: { " ,{}".contains($0) }).first
                .map { $0.lowercased() }
            var code = node.plain
            if code.hasSuffix("\n") { code.removeLast() }
            if language == "math" || language == "latex" {
                parent.html += BuddyViewerMathTypesetter.shared.render(code, display: true) + "\n"
                return
            }
            let label = language.map { " data-lang=\"\(BuddyViewerescapeHTML($0))\"" } ?? ""
            parent.html += "<pre\(label)><code>\(BuddyViewerHighlighter.highlight(code, language: language))</code></pre>\n"

        case .blockQuote:
            parent.html += Self.alert(node.html) ?? "<blockquote>\n\(node.html)</blockquote>\n"

        case .thematicBreak:
            parent.html += "<hr>\n"

        case .table:
            parent.html += "<div class=\"table-wrap\"><table>\n\(node.html)</table></div>\n"

        case .tableHeaderRow:
            parent.html += "<thead>" + row(node, in: parent, tag: "th") + "</thead>\n"

        case .tableRow:
            parent.html += row(node, in: parent, tag: "td")

        case .tableCell(let column):
            parent.cells[column] = node.html

        @unknown default:
            parent.html += node.html
        }
    }

    /// A row writes every column the table declares: an empty cell produces no run,
    /// so the cells that did arrive are placed by index and the gaps written empty.
    private func row(_ node: Node, in table: Node, tag: String) -> String {
        var columns: [PresentationIntent.TableColumn] = []
        if case .table(let declared)? = table.kind { columns = declared }
        let count = max(columns.count, (node.cells.keys.max() ?? -1) + 1)

        var out = "<tr>"
        for index in 0..<count {
            var align = ""
            if index < columns.count {
                switch columns[index].alignment {
                case .center: align = " class=\"center\""
                case .right: align = " class=\"right\""
                default: break
                }
            }
            out += "<\(tag)\(align)>\(node.cells[index] ?? "")</\(tag)>"
        }
        return out + "</tr>\n"
    }

    /// GitHub's `> [!NOTE]` callouts.
    private static func alert(_ html: String) -> String? {
        let kinds = ["NOTE": "Note", "TIP": "Tip", "IMPORTANT": "Important",
                     "WARNING": "Warning", "CAUTION": "Caution"]
        for (marker, title) in kinds {
            let prefix = "<p>[!\(marker)]"
            guard html.hasPrefix(prefix) else { continue }
            var rest = String(html.dropFirst(prefix.count))
            if rest.hasPrefix("<br>\n") { rest.removeFirst(5) } else if rest.hasPrefix("\n") { rest.removeFirst() }
            rest = rest.hasPrefix("</p>") ? String(rest.dropFirst(4)) : "<p>" + rest
            return "<blockquote class=\"alert alert-\(marker.lowercased())\">"
                + "<p class=\"alert-title\">\(title)</p>\n\(rest)</blockquote>\n"
        }
        return nil
    }

    /// GitHub's anchor rule, so `[link](#some-heading)` written for GitHub lands here too.
    private func slug(_ title: String) -> String {
        var slug = ""
        for character in title.lowercased() {
            if character.isLetter || character.isNumber || character == "-" || character == "_" {
                slug.append(character)
            } else if character == " " {
                slug.append("-")
            }
        }
        if slug.isEmpty { slug = "section" }
        let seen = slugs[slug, default: 0]
        slugs[slug] = seen + 1
        return seen == 0 ? slug : "\(slug)-\(seen)"
    }
}

func BuddyViewerescapeHTML(_ text: String) -> String {
    var out = ""
    out.reserveCapacity(text.utf8.count)
    for character in text {
        switch character {
        case "&": out += "&amp;"
        case "<": out += "&lt;"
        case ">": out += "&gt;"
        case "\"": out += "&quot;"
        default: out.append(character)
        }
    }
    return out
}

// Reused from our Markdown Viewer: Sources/Highlighter.swift
import Foundation

/// Syntax colouring for fenced code blocks.
///
/// A scanner, not a parser: it finds comments, strings, numbers, keywords and calls,
/// which is what a reader's eye uses. A language it does not know is left plain —
/// uncoloured code is honest, and code coloured by the wrong grammar is not.
enum BuddyViewerHighlighter {

    static func highlight(_ code: String, language: String?) -> String {
        guard let name = language?.lowercased(), !name.isEmpty else { return BuddyViewerescapeHTML(code) }
        switch name {
        case "diff", "patch":
            return diff(code)
        case "html", "xml", "svg", "xhtml", "vue", "plist":
            return markup(Array(code))
        case "yaml", "yml", "toml", "ini", "conf", "cfg", "properties", "env", "dotenv":
            return keyValue(code)
        default:
            guard let grammar = Grammar.named[name] else { return BuddyViewerescapeHTML(code) }
            return tokenize(Array(code), grammar)
        }
    }

    // MARK: - Generic scanner

    private static func tokenize(_ c: [Character], _ g: Grammar) -> String {
        var out = ""
        out.reserveCapacity(c.count * 2)
        let n = c.count
        var i = 0

        func matches(_ s: String, at start: Int) -> Bool {
            var j = start
            for character in s {
                guard j < n, c[j] == character else { return false }
                j += 1
            }
            return true
        }
        func emit(_ cls: String, _ from: Int, _ to: Int) {
            out += span(cls, String(c[from..<min(to, n)]))
        }
        func isWord(_ ch: Character) -> Bool {
            ch.isLetter || ch.isNumber || ch == "_" || (g.hyphenWords && ch == "-")
        }

        scan: while i < n {
            let ch = c[i]
            let previous: Character? = i > 0 ? c[i - 1] : nil

            for (open, close) in g.blockComments where matches(open, at: i) {
                var j = i + open.count
                while j < n, !matches(close, at: j) { j += 1 }
                j = min(n, j + close.count)
                emit("c", i, j)
                i = j
                continue scan
            }

            for marker in g.lineComments where matches(marker, at: i) {
                // "#" inside a word ("$#", "a#b") and "//" inside a URL are not comments.
                if marker == "#", let previous, !previous.isWhitespace { continue }
                if marker == "//", previous == ":" { continue }
                var j = i
                while j < n, c[j] != "\n" { j += 1 }
                emit("c", i, j)
                i = j
                continue scan
            }

            for quote in g.longQuotes where matches(quote, at: i) {
                var j = i + quote.count
                var closed = false
                while j < n {
                    if c[j] == "\\" { j += 2; continue }
                    if matches(quote, at: j) { closed = true; break }
                    j += 1
                }
                if closed {
                    j += quote.count
                    emit("s", i, j)
                    i = j
                    continue scan
                }
            }

            // A quote with no partner on its line is an apostrophe, not a string.
            if g.quotes.contains(ch) {
                var j = i + 1
                var closed = false
                while j < n, c[j] != "\n" {
                    if c[j] == "\\" { j += 2; continue }
                    if c[j] == ch { closed = true; break }
                    j += 1
                }
                if closed {
                    j += 1
                    var cls = "s"
                    if g.stringKeys {
                        var k = j
                        while k < n, c[k] == " " { k += 1 }
                        if k < n, c[k] == ":" { cls = "a" }
                    }
                    emit(cls, i, j)
                    i = j
                    continue scan
                }
            }

            if g.variables, ch == "$", i + 1 < n {
                var j = i + 1
                if c[j] == "{" {
                    while j < n, c[j] != "}", c[j] != "\n" { j += 1 }
                    if j < n, c[j] == "}" { j += 1 }
                } else {
                    while j < n, c[j].isLetter || c[j].isNumber || c[j] == "_" { j += 1 }
                }
                if j > i + 1 {
                    emit("v", i, j)
                    i = j
                    continue scan
                }
            }

            if ch.isASCII, ch.isNumber, previous.map({ !isWord($0) }) ?? true {
                var j = i + 1
                while j < n {
                    let d = c[j]
                    if d.isLetter || d.isNumber || d == "_" {
                        j += 1
                    } else if d == ".", j + 1 < n, c[j + 1].isNumber {
                        j += 1
                    } else {
                        break
                    }
                }
                emit("n", i, j)
                i = j
                continue scan
            }

            if ch.isLetter || ch == "_" {
                var j = i + 1
                while j < n, isWord(c[j]) { j += 1 }
                let word = String(c[i..<j])
                let key = g.caseInsensitive ? word.lowercased() : word
                if g.keywords.contains(key) {
                    emit("k", i, j)
                } else if g.literals.contains(key) {
                    emit("l", i, j)
                } else if g.colonKeys, j < n, c[j] == ":" {
                    emit("a", i, j)
                } else if g.functions, j < n, c[j] == "(" {
                    emit("f", i, j)
                } else if g.types, let first = word.first, first.isUppercase,
                          word.contains(where: \.isLowercase) {
                    emit("t", i, j)
                } else {
                    out += BuddyViewerescapeHTML(word)
                }
                i = j
                continue scan
            }

            appendEscaped(ch, to: &out)
            i += 1
        }
        return out
    }

    // MARK: - Line-based formats

    private static func diff(_ code: String) -> String {
        code.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let text = String(line)
            if text.hasPrefix("+++") || text.hasPrefix("---") || text.hasPrefix("diff ")
                || text.hasPrefix("index ") || text.hasPrefix("@@") {
                return span("m", text)
            }
            if text.hasPrefix("+") { return span("add", text) }
            if text.hasPrefix("-") { return span("del", text) }
            return BuddyViewerescapeHTML(text)
        }.joined(separator: "\n")
    }

    /// YAML, TOML, INI: a key, a separator, a value.
    private static func keyValue(_ code: String) -> String {
        code.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let c = Array(line)
            var i = 0
            while i < c.count, c[i] == " " || c[i] == "\t" { i += 1 }
            let indent = String(c[0..<i])
            guard i < c.count else { return indent }
            if c[i] == "#" || c[i] == ";" { return indent + span("c", String(c[i...])) }
            if c[i] == "[", c.last == "]", !c.contains(",") { return indent + span("k", String(c[i...])) }

            var start = i
            var lead = indent
            if start + 1 < c.count, c[start] == "-", c[start + 1] == " " {
                lead += "- "
                start += 2
            }
            var end = start
            while end < c.count,
                  c[end].isLetter || c[end].isNumber || "_-./\"' ".contains(c[end]) { end += 1 }
            let isYAMLKey = end < c.count && c[end] == ":" && (end + 1 == c.count || c[end + 1] == " ")
            let isAssignment = end < c.count && c[end] == "="
            if end > start, isYAMLKey || isAssignment {
                var keyEnd = end
                while keyEnd > start, c[keyEnd - 1] == " " { keyEnd -= 1 }
                return lead + span("a", String(c[start..<keyEnd]))
                    + BuddyViewerescapeHTML(String(c[keyEnd...end]))
                    + tokenize(Array(c[(end + 1)...]), Grammar.configValue)
            }
            return lead + tokenize(Array(c[start...]), Grammar.configValue)
        }.joined(separator: "\n")
    }

    private static func markup(_ c: [Character]) -> String {
        var out = ""
        let n = c.count
        var i = 0

        func matches(_ s: String, at start: Int) -> Bool {
            var j = start
            for character in s {
                guard j < n, c[j] == character else { return false }
                j += 1
            }
            return true
        }

        while i < n {
            if matches("<!--", at: i) {
                var j = i + 4
                while j < n, !matches("-->", at: j) { j += 1 }
                j = min(n, j + 3)
                out += span("c", String(c[i..<j]))
                i = j
            } else if c[i] == "<", i + 1 < n, c[i + 1].isLetter || "/!?".contains(c[i + 1]) {
                out += "&lt;"
                i += 1
                if "/!?".contains(c[i]) {
                    out.append(c[i])
                    i += 1
                }
                var j = i
                while j < n, c[j].isLetter || c[j].isNumber || "-_:.".contains(c[j]) { j += 1 }
                out += span("k", String(c[i..<j]))
                i = j
                while i < n, c[i] != ">" {
                    if c[i] == "\"" || c[i] == "'" {
                        var k = i + 1
                        while k < n, c[k] != c[i] { k += 1 }
                        k = min(n, k + 1)
                        out += span("s", String(c[i..<k]))
                        i = k
                    } else if c[i].isLetter {
                        var k = i
                        while k < n, c[k].isLetter || c[k].isNumber || "-_:.@".contains(c[k]) { k += 1 }
                        out += span("a", String(c[i..<k]))
                        i = k
                    } else {
                        appendEscaped(c[i], to: &out)
                        i += 1
                    }
                }
                if i < n {
                    out += "&gt;"
                    i += 1
                }
            } else {
                appendEscaped(c[i], to: &out)
                i += 1
            }
        }
        return out
    }

    // MARK: - Output

    /// A token that runs over several lines — a block comment, a docstring — is
    /// written as one span per line, so no tag is ever open across a line break and
    /// the output can be cut into lines.
    private static func span(_ cls: String, _ text: String) -> String {
        guard text.contains("\n") else { return "<span class=\"tk-\(cls)\">\(BuddyViewerescapeHTML(text))</span>" }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? "" : "<span class=\"tk-\(cls)\">\(BuddyViewerescapeHTML(String($0)))</span>" }
            .joined(separator: "\n")
    }

    private static func appendEscaped(_ character: Character, to out: inout String) {
        switch character {
        case "&": out += "&amp;"
        case "<": out += "&lt;"
        case ">": out += "&gt;"
        case "\"": out += "&quot;"
        default: out.append(character)
        }
    }
}

// MARK: - Grammars

private struct Grammar {
    var lineComments: [String] = ["//"]
    var blockComments: [(open: String, close: String)] = [("/*", "*/")]
    var quotes: Set<Character> = ["\"", "'"]
    var longQuotes: [String] = []
    var keywords: Set<String> = []
    var literals: Set<String> = ["true", "false", "null"]
    var caseInsensitive = false
    var stringKeys = false      // JSON: a string followed by ":" is a key
    var colonKeys = false       // CSS: a word followed by ":" is a property
    var variables = false       // $NAME and ${NAME}
    var functions = true        // a word followed by "(" is a call
    var types = false           // a Capitalised word is a type
    var hyphenWords = false     // CSS: "font-size" is one word

    static func words(_ list: String) -> Set<String> {
        Set(list.split(separator: " ").map(String.init))
    }

    static let configValue = Grammar(
        lineComments: ["#"], blockComments: [],
        literals: words("true false null yes no on off True False None ~"),
        functions: false
    )

    static let named: [String: Grammar] = {
        var table: [String: Grammar] = [:]
        func register(_ names: String, _ grammar: Grammar) {
            for name in names.split(separator: " ") { table[String(name)] = grammar }
        }

        register("js javascript jsx mjs cjs ts typescript tsx", Grammar(
            longQuotes: ["`"],
            keywords: words("""
                abstract as async await break case catch class const continue debugger declare \
                default delete do else enum export extends finally for from function get if \
                implements import in instanceof interface keyof let namespace new of private \
                protected public readonly return satisfies set static super switch this throw \
                try type typeof var void while with yield
                """),
            literals: words("true false null undefined NaN Infinity"),
            types: true
        ))

        register("py python python3", Grammar(
            lineComments: ["#"], blockComments: [],
            longQuotes: ["\"\"\"", "'''"],
            keywords: words("""
                and as assert async await break case class continue def del elif else except \
                finally for from global if import in is lambda match nonlocal not or pass raise \
                return self try while with yield
                """),
            literals: words("True False None"),
            types: true
        ))

        register("sh bash zsh shell console fish", Grammar(
            lineComments: ["#"], blockComments: [],
            keywords: words("""
                alias break case cd continue declare do done echo elif else esac eval exec exit \
                export fi for function if in local read readonly return set shift source then \
                trap unset until while
                """),
            literals: words("true false"),
            variables: true, functions: false
        ))

        register("swift", Grammar(
            quotes: ["\""], longQuotes: ["\"\"\""],
            keywords: words("""
                actor any as associatedtype async await break case catch class continue default \
                defer deinit do else enum extension fallthrough fileprivate final for func guard \
                if import in indirect init inout internal is lazy let mutating nonisolated open \
                operator override private protocol public repeat rethrows return self Self some \
                static struct subscript super switch throw throws try typealias var weak where while
                """),
            literals: words("true false nil"),
            types: true
        ))

        register("go golang", Grammar(
            longQuotes: ["`"],
            keywords: words("""
                break case chan const continue default defer else fallthrough for func go goto \
                if import interface map package range return select struct switch type var
                """),
            literals: words("true false nil iota"),
            types: true
        ))

        // Single quotes are left alone: 'a is a lifetime far more often than a char.
        register("rust rs", Grammar(
            quotes: ["\""],
            keywords: words("""
                as async await break const continue crate dyn else enum extern fn for if impl in \
                let loop match mod move mut pub ref return self Self static struct super trait \
                type unsafe use where while
                """),
            literals: words("true false"),
            types: true
        ))

        register("java kotlin kt scala csharp cs c# dart groovy", Grammar(
            keywords: words("""
                abstract as assert async await base boolean break byte case catch char class \
                companion const continue data def default do double else enum extends final \
                finally float for fun get if implements import in instanceof int interface \
                internal is long namespace native new object open operator out override package \
                private protected public readonly return sealed set short static struct super \
                suspend switch synchronized this throw throws trait try typeof using val var \
                virtual void volatile when where while with yield
                """),
            types: true
        ))

        register("c h cpp c++ cc cxx hpp objc objective-c m mm", Grammar(
            keywords: words("""
                auto bool break case catch char class const constexpr continue default define \
                delete do double else endif enum explicit extern final float for friend goto if \
                ifdef ifndef include inline int long namespace new noexcept operator override \
                pragma private protected public register return short signed sizeof static \
                struct switch template this throw try typedef typename union unsigned using \
                virtual void volatile while
                """),
            literals: words("true false NULL nullptr nil YES NO")
        ))

        register("php", Grammar(
            lineComments: ["//", "#"],
            keywords: words("""
                abstract as break case catch class const continue default do echo else elseif \
                extends final finally fn for foreach function if implements include interface \
                match namespace new private protected public require return static switch throw \
                trait try use var while yield
                """),
            variables: true
        ))

        register("rb ruby", Grammar(
            lineComments: ["#"], blockComments: [],
            keywords: words("""
                alias and begin break case class def do else elsif end ensure for if in module \
                next not or redo require rescue retry return self super then undef unless until \
                when while yield
                """),
            literals: words("true false nil")
        ))

        register("r", Grammar(
            lineComments: ["#"], blockComments: [],
            keywords: words("break else for function if in library next repeat require return while"),
            literals: words("TRUE FALSE NULL NA NaN Inf")
        ))

        register("sql postgres postgresql psql mysql sqlite", Grammar(
            lineComments: ["--"],
            keywords: words("""
                add all alter and as asc begin between bigint boolean by case commit constraint \
                create cross date default delete desc distinct drop else end exists float foreign \
                from full group having if in index inner insert int integer into is join key left \
                like limit not numeric offset on or order outer primary references returning \
                right rollback select serial set table text then timestamp union unique update \
                values varchar view when where with
                """),
            caseInsensitive: true
        ))

        register("json jsonc json5 jsonl", Grammar(
            quotes: ["\""], stringKeys: true, functions: false
        ))

        register("css scss less sass", Grammar(
            lineComments: [], colonKeys: true, functions: false, hyphenWords: true
        ))

        register("dockerfile docker", Grammar(
            lineComments: ["#"], blockComments: [],
            keywords: words("""
                ADD ARG AS CMD COPY ENTRYPOINT ENV EXPOSE FROM HEALTHCHECK LABEL ONBUILD RUN \
                SHELL STOPSIGNAL USER VOLUME WORKDIR
                """),
            variables: true, functions: false
        ))

        register("makefile make", Grammar(
            lineComments: ["#"], blockComments: [],
            keywords: words("define else endef endif export ifdef ifeq ifndef ifneq include"),
            variables: true, functions: false
        ))

        return table
    }()
}

// Reused from our Markdown Viewer: Sources/Math.swift
import Foundation
import JavaScriptCore

/// The bundled KaTeX engine produces HTML and accessible MathML before a page is
/// loaded. Documents never gain JavaScript permissions or fetch a math library.
final class BuddyViewerMathTypesetter {
    static let shared = BuddyViewerMathTypesetter()
    private let lock = NSLock()
    private let context: JSContext?
    private let function: JSValue?

    private init() {
        guard let url = BuddyMarkdownPreview.resourceRoot.map({ $0.appendingPathComponent("Math/katex.min.js") }),
              let source = try? String(contentsOf: url, encoding: .utf8),
              let context = JSContext() else {
            self.context = nil
            function = nil
            return
        }
        context.evaluateScript(source)
        function = context.evaluateScript("""
            (function(tex, display) {
              return katex.renderToString(tex, {
                displayMode: display, output: 'htmlAndMathml', throwOnError: true,
                trust: false, strict: 'error', maxExpand: 1000, maxSize: 20,
                macros: {}
              });
            })
            """)
        self.context = context
    }

    func render(_ tex: String, display: Bool) -> String {
        lock.lock()
        defer { lock.unlock() }
        let style = display ? "math-display" : "math-inline"
        guard tex.utf8.count <= 100_000, let context, let function else {
            return fallback(tex, style: style, reason: "Math renderer unavailable")
        }
        context.exception = nil
        let value = function.call(withArguments: [tex, display])
        if let exception = context.exception {
            let reason = exception.toString() ?? "Invalid formula"
            context.exception = nil
            return fallback(tex, style: style, reason: reason)
        }
        guard let html = value?.toString(), value?.isUndefined == false else {
            return fallback(tex, style: style, reason: "Unable to render formula")
        }
        return "<span class=\"\(style)\">\(html)</span>"
    }

    private func fallback(_ tex: String, style: String, reason: String) -> String {
        "<span class=\"\(style) math-error\" title=\"\(BuddyViewerescapeHTML(reason))\"><code>\(BuddyViewerescapeHTML(tex))</code></span>"
    }
}

/// Protect TeX from Markdown's handling of underscores, backslashes and pipes.
/// Only explicit math delimiters are interpreted; code and HTML attributes stay
/// literal, and dollar amounts followed by another dollar amount stay ordinary text.
struct BuddyViewerMarkdownMath {
    struct Fragment {
        let token: String
        let tex: String
        let display: Bool
        let literal: String
    }

    let text: String
    let fragments: [Fragment]
    let limited: Bool

    init(_ source: String) {
        let chars = Array(source)
        var prefix = "MDVMATH"
        while source.contains(prefix) { prefix += "X" }
        var out = ""
        var fragments: [Fragment] = []
        var limited=false
        var i = 0

        func matches(_ needle: String, at position: Int, caseInsensitive: Bool = false) -> Bool {
            let part = Array(needle)
            guard position + part.count <= chars.count else { return false }
            let candidate = String(chars[position..<position + part.count])
            return caseInsensitive ? candidate.caseInsensitiveCompare(needle) == .orderedSame : candidate == needle
        }
        func escaped(_ position: Int) -> Bool {
            var j = position
            while j > 0, chars[j - 1] == "\\" { j -= 1 }
            return (position - j) % 2 == 1
        }
        func end(of delimiter: String, from start: Int, singleLine: Bool, caseInsensitive: Bool = false) -> Int? {
            var j = start
            while j < chars.count {
                if singleLine && chars[j] == "\n" { return nil }
                if matches(delimiter, at: j, caseInsensitive: caseInsensitive), !escaped(j) { return j }
                j += 1
            }
            return nil
        }
        func addMath(from start: Int, to finish: Int, display: Bool, delimiterWidth: Int) {
            guard fragments.count<128 else{limited=true;out += String(chars[start-delimiterWidth..<finish+delimiterWidth]);return}
            let tex = String(chars[start..<finish]).trimmingCharacters(in: .whitespacesAndNewlines)
            let token = prefix + String(fragments.count) + "END"
            fragments.append(Fragment(token: token, tex: tex, display: display,
                literal: String(chars[start - delimiterWidth..<finish + delimiterWidth])))
            out += token
        }

        while i < chars.count {
            // Fenced and indented code must survive even if it contains dollars or
            // TeX. A math-labelled fence is handled by the Markdown block renderer.
            if i == 0 || chars[i - 1] == "\n" {
                let lineEnd = chars[i...].firstIndex(of: "\n") ?? chars.count
                var start = i
                while start < lineEnd, chars[start] == " " { start += 1 }
                // A fence inside a blockquote is still a code fence.
                while start < lineEnd, chars[start] == ">" {
                    start += 1
                    while start < lineEnd, chars[start] == " " { start += 1 }
                }
                if start - i >= 4 || (start < lineEnd && chars[start] == "\t") {
                    out += String(chars[i..<lineEnd])
                    i = lineEnd
                    continue
                }
                if start < lineEnd, (chars[start] == "`" || chars[start] == "~") {
                    let marker = chars[start]
                    var n = start
                    while n < lineEnd, chars[n] == marker { n += 1 }
                    if n - start >= 3 {
                        let width = n - start
                        var stop = lineEnd
                        var next = lineEnd < chars.count ? lineEnd + 1 : chars.count
                        while next < chars.count {
                            let finish = chars[next...].firstIndex(of: "\n") ?? chars.count
                            var line = String(chars[next..<finish]).trimmingCharacters(in: .whitespaces)
                            while line.hasPrefix(">") { line.removeFirst(); line = line.trimmingCharacters(in: .whitespaces) }
                            if line.count >= width && line.allSatisfy({ $0 == marker }) {
                                stop = finish
                                break
                            }
                            stop = finish
                            next = finish < chars.count ? finish + 1 : chars.count
                        }
                        out += String(chars[i..<stop])
                        i = stop
                        continue
                    }
                }
            }
            // Inline code uses matching backtick runs, including multiple ticks.
            if chars[i] == "`", !escaped(i) {
                var next = i
                while next < chars.count, chars[next] == "`" { next += 1 }
                let delimiter = String(chars[i..<next])
                var finish: Int?
                var j = next
                while j < chars.count {
                    if chars[j] != "`" { j += 1; continue }
                    let start = j
                    while j < chars.count, chars[j] == "`" { j += 1 }
                    if j - start == delimiter.count { finish = start; break }
                }
                if let finish {
                    out += String(chars[i..<finish + delimiter.count])
                    i = finish + delimiter.count
                    continue
                }
            }
            // Skip tags and their attributes, and the literal contents of HTML code,
            // style and script elements. Nothing from these may become a formula.
            if chars[i] == "<", i + 1 < chars.count,
               (chars[i + 1].isLetter || "/!?".contains(chars[i + 1])) {
                if matches("<!--", at: i), let close = end(of: "-->", from: i + 4, singleLine: false) {
                    out += String(chars[i..<close + 3]); i = close + 3; continue
                }
                var j = i + 1
                var quote: Character?
                while j < chars.count {
                    if let current = quote {
                        if chars[j] == current { quote = nil }
                    } else if chars[j] == "\"" || chars[j] == "'" {
                        quote = chars[j]
                    } else if chars[j] == ">" { break }
                    j += 1
                }
                if j < chars.count {
                    let tag = String(chars[i...j]).lowercased()
                    if let name = ["pre", "code", "script", "style"].first(where: { tag.hasPrefix("<" + $0 + ">") || tag.hasPrefix("<" + $0 + " ") }),
                       let closing = end(of: "</" + name + ">", from: j + 1, singleLine: false, caseInsensitive: true) {
                        j = closing + name.count + 2
                    }
                    out += String(chars[i...j])
                    i = j + 1
                    continue
                }
            }
            if matches("$$", at: i), !escaped(i), let finish = end(of: "$$", from: i + 2, singleLine: false) {
                addMath(from: i + 2, to: finish, display: true, delimiterWidth: 2)
                i = finish + 2
                continue
            }
            if (matches("\\[", at: i) || matches("\\(", at: i)), !escaped(i) {
                let display = chars[i + 1] == "["
                if let finish = end(of: display ? "\\]" : "\\)", from: i + 2, singleLine: !display) {
                    addMath(from: i + 2, to: finish, display: display, delimiterWidth: 2)
                    i = finish + 2
                    continue
                }
            }
            if chars[i] == "$", !escaped(i), i + 1 < chars.count,
               !chars[i + 1].isWhitespace, chars[i + 1] != "$" {
                // A currency number followed by prose does not open inline math.
                if chars[i + 1].isNumber {
                    var numberEnd = i + 1
                    while numberEnd < chars.count, chars[numberEnd].isNumber || ".,".contains(chars[numberEnd]) { numberEnd += 1 }
                    var after = numberEnd
                    while after < chars.count, chars[after] == " " { after += 1 }
                    if after < chars.count, chars[after].isLetter {
                        out.append(chars[i]); i += 1; continue
                    }
                }
                var j = i + 1
                var finish: Int?
                while j < chars.count, chars[j] != "\n" {
                    if chars[j] == "$", !escaped(j) {
                        if !chars[j - 1].isWhitespace,
                           (j + 1 == chars.count || (!chars[j + 1].isNumber && chars[j + 1] != "$")) { finish = j }
                        break
                    }
                    j += 1
                }
                if let finish {
                    addMath(from: i + 1, to: finish, display: false, delimiterWidth: 1)
                    i = finish + 1
                    continue
                }
            }
            out.append(chars[i])
            i += 1
        }
        text = out
        self.fragments = fragments
        self.limited = limited
    }

    func restore(_ html: String) -> String {
        guard !fragments.isEmpty else { return html }
        let rendered = fragments.map { BuddyViewerMathTypesetter.shared.render($0.tex, display: $0.display) }
        func replace(_ part: String, attribute: Bool) -> String {
            zip(fragments, rendered).reduce(part) { result, pair in
                result.replacingOccurrences(of: pair.0.token,
                    with: attribute ? BuddyViewerescapeHTML(pair.0.literal) : pair.1)
            }
        }
        // A marker in an image's alt text or a link URL must stay text. Never
        // insert the typesetter's HTML into an HTML attribute.
        let tags = try! NSRegularExpression(pattern: "<[^>]*>")
        var result = "", start = html.startIndex
        for match in tags.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range, in: html) else { continue }
            result += replace(String(html[start..<range.lowerBound]), attribute: false)
            result += replace(String(html[range]), attribute: true)
            start = range.upperBound
        }
        result += replace(String(html[start...]), attribute: false)
        return result
    }

    func plain(_ text: String) -> String {
        fragments.reduce(text) { result, fragment in
            result.replacingOccurrences(of: fragment.token, with: fragment.tex)
        }
    }
}
