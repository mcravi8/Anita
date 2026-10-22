# Buddy background worker

Buddy 0.12 runs a separate per-user macOS helper, a durable task queue that runs several tasks at once (one per agent, up to three unless you change **Run at once** in Background work → Worker settings, from 1 to 6), and one private Chrome profile that every agent with internet access shares (each task drives its own page in it). Task files live in `~/Library/Application Support/Buddy/Worker/Tasks/<task-id>/Files`. This is a separate local browser and file workspace, not a virtual machine or a supplied cloud computer. The Mac must be awake, signed in, and online.

Open **Background work → Start worker → New task**, or explicitly ask an agent in a direct chat to run a task in the background. The initial default is the existing ChatGPT subscription via Codex app-server. Settings → AI provider chooses the default for new replies and tasks and manages both connections. Closing or quitting the main Buddy app does not stop the helper. Pause queue stops current work and holds queued tasks. Resume can include additional facts or instructions.

## Installation and providers

Before building, install Node.js 22+, Chrome, and the supported Codex CLI with ChatGPT sign-in, then run:

```sh
npm ci --ignore-scripts --no-audit --no-fund --prefix outputs/buddy-worker
python3 outputs/buddy-mac/build.py --install
```

The app packages pinned worker dependencies; no browser download is needed. The Claude SDK's native runtime follows the build machine architecture. Build on the intended Mac architecture (or include the matching official `@anthropic-ai/claude-agent-sdk-darwin-*` optional dependency) for Claude support. The Swift app/helper themselves are universal.

**Settings → AI provider → Claude → Connect** opens a native secure field. API keys are stored in macOS Keychain, never in web state, task files, or this repository. Claude uses Console API credits, not a Claude subscription login. Console credits are used before purchased balance; Console billing/auto-reload controls funding after credits run out. Buddy cannot verify promotional-credit-only funding.

Tasks have no spending limit of their own. The only limit is an optional daily limit per agent: a run that reaches it pauses and continues by itself the next day or when the limit is raised, and a chat turn never sets aside money in advance. Technical stops (worker restart, a stall, the step cap, a dropped bridge, a provider or connector error) carry a recorded cause and are retried automatically within bounds, then handed to the team's supervisor; only sign-ins, credentials, money, irreversible actions in your name and plan changes come to you. Coding sessions and the supervisor's background reviews run on the agent's own provider and use the other provider when that one is unavailable. Claude's built-in shell, filesystem, delegation, plugins, and user/project settings are disabled; only bounded Buddy MCP tools are registered. Bounded connected-service requests use the existing ChatGPT subscription and its current connection grants, with the same human action reviews.

## Browser, files, and reviews

The helper starts Chrome through Playwright Core's supported `chrome` channel with a private profile and Chromium sandbox enabled. It does not attach to or copy the normal Chrome profile. No remote debugging TCP listener is exposed. Persistent profile cookies stay local to that agent's browser.

Public HTTP(S) pages can be opened and read. Local/private-network destinations and non-web schemes are blocked, including subrequests and redirects, using URL and DNS checks. This is application-level isolation, not an OS/network VM boundary; Chromium and the Mac remain the underlying security boundary. Service workers and extensions are disabled. Downloads are currently disabled; deliverables are written through Buddy's scoped file tools.

Every browser mutation (click, grouped fill, select, upload) first produces an exact native review. A submission review includes the current form values. Approval is single-use and bound to the observed URL and page/control fingerprint; a changed page must be reread. Passwords, verification, known sensitive identity/payment fields, and recognizable legal/security steps require a user handoff. **Open task browser** pauses the queue, opens that private profile for the user, and preserves session cookies. Resume closes the manual window before automation resumes. CAPTCHA, login, complex forms, or unsupported sites can require the user; applications cannot be guaranteed to finish unattended.

Private task files and current connected user folders use the existing format, size, version, backup, and link restrictions. Cross-process file commits share a lock and verify full-content versions. Folder access is loaded again on each call. Changes to an active agent or connection grants pause the task; reviews recheck the current permission set before external actions. HTML/document previews reuse Buddy's sanitized, script-free readers.

Task briefs, partial/final results, file receipts, and reviews are saved locally. Only an actual service/browser result can confirm an effect. On restart, active work becomes interrupted, pending approvals expire, and previously accepted actions without receipts remain uncertain. Nothing is automatically resubmitted. Explicit Resume must reconcile external state first. Tasks are serial, limited to one hour per attempt and 150 browser calls; logged actions and pending reviews are bounded. Daily/weekday routines run through the local durable scheduler; no remote host is supplied.

## What the private browser refuses on the network

Every request Chrome makes (page and frame loads, each hop of a redirect, images, scripts, fetches, WebSockets) goes through a checking proxy that runs inside the helper (`network-guard.mjs`). It listens on 127.0.0.1 only, and only Chrome, which holds a per-session password, can use it. For each connection it resolves the name itself, requires every answer to be a public address, and connects to the address it checked. So a page can no longer reach the private network by redirecting (one hop or a chain), by loading a subresource or opening a socket, or by answering a DNS lookup differently the second time (DNS rebinding). Loopback, private, link-local, documentation, carrier-grade, mapped and `.local`/`.internal`/`localhost` names are refused. Chrome's built-in exemption for localhost is switched off so loopback traffic reaches the proxy as well, and WebRTC's non-proxied UDP is disabled.

The address check before a page opens is still there, for clearer messages; the proxy is what enforces it. Limits worth knowing: the proxy connects directly, so a network that requires an HTTP proxy to reach the internet is not supported by the private browser; the ordinary Chrome window opened for private sign-in is not routed through it (it is a separate, user-driven Chrome); and Chrome's own background services use it too.

A helper that exits abnormally leaves its last error output in `Worker/crash-<helper>.log` (see the Mac app README). A page that stops responding resets the browser after 40 seconds, and a browser whose Chrome died is started again by the next command.

## Runtime plumbing and checks

`Buddy Worker.app` has a separate bundle identity so the helper cannot intercept reopening Buddy. `~/Library/LaunchAgents/app.buddy.worker.plist` starts it for the signed-in user. The private Unix socket uses a short per-user temporary directory, owner-only permissions, and peer UID validation. Requests carry workspace/task IDs; create requests have stable idempotency IDs. No network control port is opened.

```sh
node --test outputs/relay/*.test.js
node --test outputs/buddy-worker/test/*.test.mjs
python3 outputs/buddy-mac/run-tests.py
```

Token ledger (off by default): when Buddy is started with `BUDDY_TOKEN_LEDGER` set to a file path (for example `launchctl setenv BUDDY_TOKEN_LEDGER "$HOME/Library/Application Support/Buddy/token-ledger.jsonl"`, then quit and reopen Buddy), the Claude bridges (`claude.mjs`, `coding.mjs`) append one JSON line per model call: the SDK's usage (input, cache read, cache write, output) and the size in characters of each part of that call's input — instructions, tool schemas, briefing, live-work context, chat history, file contents, other tool output and the model's own earlier output — plus one summary line per run. Sizes only, never content; a write failure never affects a run. ChatGPT runs already leave per-call usage in Codex's own session files. `launchctl unsetenv BUDDY_TOKEN_LEDGER` turns it off.

Browser tests use an inert local form with a test-origin allowance provided directly by the test harness; production callers cannot enable that allowance. Native worker tests use an inert app-server and temporary files. No real emails or job applications are sent by automated tests. Live Claude execution requires the user to connect their API key; fixture tests do not use credentials or credits.

Official integrations: [OpenAI app-server](https://learn.chatgpt.com/docs/app-server), [Claude Agent SDK](https://code.claude.com/docs/en/agent-sdk/overview), [Claude subscriber API credits](https://platform.claude.com/docs/en/about-claude/api-credits-for-subscribers), [Playwright persistent contexts](https://playwright.dev/docs/api/class-browsertype#browser-type-launch-persistent-context).


Private browser sign-in is set up once in Background work → Browser sign-in and is requested through the worker’s buddy_browser_signin tool; the person answers in the agent's chat (a masked field typed into that page only, or Buddy's Chrome window and Done). Chrome owns password storage and autofill; Buddy receives session results. New account creation requests a human choice and private Chrome. Supported email-code forms use a restricted native Gmail lookup after consent for that website. The Mac app guide describes supported forms, sender/recipient checks, private handoff recovery, and current verification limits.

Buddy 0.16 adds direct read-only connector discovery/calls for Claude through the current ChatGPT connector transport, without a second model turn. Writes and unsupported operations retain their reviewed delegate. Native Gmail review overlaps up to four independent reads with deterministic source receipts and unchanged coverage/analysis checks. Completed email routines can supply same-day prepared answers in chat with their original checked timestamp; explicit fresh checks bypass reuse. See the Mac app guide for freshness, source, account and access requirements.
