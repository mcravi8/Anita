// run-tests: BuddyTeam.swift BuddyAgentProposals.swift BuddyProjectFiles.swift BuddyDocuments.swift
import Foundation

/// An agent with web search is told which tool it is and how to keep its answer small, so it doesn't list the whole tool catalogue to find
/// it (about 3% of ChatGPT tokens on 20 Oct 2026 went to `ALL_TOOLS.filter(...)` lookups). An agent without it isn't told about it.
@main struct RuntimeGuidanceTests {
    static func require(_ ok: Bool, _ label: String) { if !ok { fputs("FAILED: \(label)\n", stderr); exit(1) } }
    static func main() {
        let chatgpt = BuddyRuntimeCapabilities.guidance(provider: "chatgpt", model: "gpt-fixture", webSearch: true)
        require(chatgpt.contains("mcp__codex_apps__search_service_web_run") && chatgpt.contains("tools.mcp__codex_apps__search_service_web_run"), "ChatGPT is told the search tool's name, as code calls it")
        require(chatgpt.contains("ALL_TOOLS") && chatgpt.contains("system2_search_query") && chatgpt.contains(#"response_length "short""#) && chatgpt.contains("open"), "and to call it directly, short, opening only the results it needs")
        let claude = BuddyRuntimeCapabilities.guidance(provider: "claude", model: "claude-fixture", webSearch: true)
        require(claude.contains("buddy_service_read") && claude.contains(#""Search Service""#) && claude.contains(#""web_run""#) && claude.contains("system2_search_query") && claude.contains("buddy_service_tools"), "Claude is told the exact direct read for web search, without discovering it first")
        require(!claude.contains("mcp__codex_apps"), "Claude isn't told about a tool only ChatGPT has")
        for provider in ["chatgpt", "claude"] {
            let without = BuddyRuntimeCapabilities.guidance(provider: provider, model: "m", webSearch: false)
            require(!without.contains("web_run") && !without.contains("search_service"), "\(provider) without web search isn't told about it")
            require(without == BuddyRuntimeCapabilities.guidance(provider: provider, model: "m"), "web search is off unless the caller knows it is there")
        }
        print("PASS: an agent with web search is told the tool and how to keep its results short; one without it is not")
    }
}
