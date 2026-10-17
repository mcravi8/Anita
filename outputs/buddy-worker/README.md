# Buddy background worker

Buddy 0.12 runs a separate per-user macOS helper, a serial durable task queue, and a dedicated Chrome profile per agent. Task files live in `~/Library/Application Support/Buddy/Worker/Tasks/<task-id>/Files`. This is a separate local browser and file workspace, not a virtual machine or a supplied cloud computer. The Mac must be awake, signed in, and online.

Open **Background work → Start worker → New task**, or explicitly ask an agent in a direct chat to run a task in the background. The initial default is the existing ChatGPT subscription via Codex app-server. Settings → AI provider chooses the default for new replies and tasks and manages both connections. Closing or quitting the main Buddy app does not stop the helper. Pause queue stops current work and holds queued tasks. Resume can include additional facts or instructions.

## Installation and providers

Before building, install Node.js 22+, Chrome, and the supported Codex CLI with ChatGPT sign-in, then run:

```sh
npm ci --ignore-scripts --no-audit --no-fund --prefix outputs/buddy-worker
python3 outputs/buddy-mac/build.py
```

The app packages pinned worker dependencies; no browser download is needed. The Claude SDK's native runtime follows the build machine architecture. Build on the intended Mac architecture (or include the matching official `@anthropic-ai/claude-agent-sdk-darwin-*` optional dependency) for Claude support. The Swift app/helper themselves are universal.

**Settings → AI provider → Claude → Connect** opens a native secure field. API keys are stored in macOS Keychain, never in web state, task files, or this repository. Claude uses Console API credits, not a Claude subscription login. Each Claude task has a USD budget (up to $10); the Agent SDK's limit is an estimate and a final request can exceed it. Console credits are used before purchased balance; Console billing/auto-reload controls funding after credits run out. Buddy cannot verify promotional-credit-only funding. There is no automatic provider fallback.

A Claude attempt reserves its entire remaining task allowance before dispatch. A confirmed cost releases the unused portion; an interrupted or unknown-cost attempt keeps that reservation, preventing an automatic paid retry. Reaching that limit requires an explicitly budgeted new task to continue. Claude's built-in shell, filesystem, delegation, plugins, and user/project settings are disabled; only bounded Buddy MCP tools are registered. Bounded connected-service requests use the existing ChatGPT subscription and its current connection grants, with the same human action reviews.

## Browser, files, and reviews

The helper starts Chrome through Playwright Core's supported `chrome` channel with a private profile and Chromium sandbox enabled. It does not attach to or copy the normal Chrome profile. No remote debugging TCP listener is exposed. Persistent profile cookies stay local to that agent's browser.

Public HTTP(S) pages can be opened and read. Local/private-network destinations and non-web schemes are blocked, including subrequests and redirects, using URL and DNS checks. This is application-level isolation, not an OS/network VM boundary; Chromium and the Mac remain the underlying security boundary. Service workers and extensions are disabled. Downloads are currently disabled; deliverables are written through Buddy's scoped file tools.

Every browser mutation (click, grouped fill, select, upload) first produces an exact native review. A submission review includes the current form values. Approval is single-use and bound to the observed URL and page/control fingerprint; a changed page must be reread. Passwords, verification, known sensitive identity/payment fields, and recognizable legal/security steps require a user handoff. **Open task browser** pauses the queue, opens that private profile for the user, and preserves session cookies. Resume closes the manual window before automation resumes. CAPTCHA, login, complex forms, or unsupported sites can require the user; applications cannot be guaranteed to finish unattended.

Private task files and current connected user folders use the existing format, size, version, backup, and link restrictions. Cross-process file commits share a lock and verify full-content versions. Folder access is loaded again on each call. Changes to an active agent or connection grants pause the task; reviews recheck the current permission set before external actions. HTML/document previews reuse Buddy's sanitized, script-free readers.

Task briefs, partial/final results, file receipts, and reviews are saved locally. Only an actual service/browser result can confirm an effect. On restart, active work becomes interrupted, pending approvals expire, and previously accepted actions without receipts remain uncertain. Nothing is automatically resubmitted. Explicit Resume must reconcile external state first. Tasks are serial, limited to one hour per attempt and 150 browser calls; logged actions and pending reviews are bounded. The initial queue has no recurring schedules or remote host.

## Runtime plumbing and checks

`Buddy Worker.app` has a separate bundle identity so the helper cannot intercept reopening Buddy. `~/Library/LaunchAgents/app.buddy.worker.plist` starts it for the signed-in user. The private Unix socket uses a short per-user temporary directory, owner-only permissions, and peer UID validation. Requests carry workspace/task IDs; create requests have stable idempotency IDs. No network control port is opened.

```sh
node --test outputs/relay/*.test.js
node --test outputs/buddy-worker/test/*.test.mjs
python3 outputs/buddy-mac/run-tests.py
```

Browser tests use an inert local form with a test-origin allowance provided directly by the test harness; production callers cannot enable that allowance. Native worker tests use an inert app-server and temporary files. No real emails or job applications are sent by automated tests. Live Claude execution requires the user to connect their API key; fixture tests do not use credentials or credits.

Official integrations: [OpenAI app-server](https://learn.chatgpt.com/docs/app-server), [Claude Agent SDK](https://code.claude.com/docs/en/agent-sdk/overview), [Claude subscriber API credits](https://platform.claude.com/docs/en/about-claude/api-credits-for-subscribers), [Playwright persistent contexts](https://playwright.dev/docs/api/class-browsertype#browser-type-launch-persistent-context).
