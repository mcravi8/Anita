# Anita

A personal AI workspace with configurable agents, individual chats, and group teamwork. This repository contains the Buddy macOS app and its web frontend.

## Features

- Configurable agents with independent conversations, roles, appearances, instructions, and access settings.
- **Team plans that run on their own.** Chief splits an objective into stages, each with tasks for named agents, and asks which stage to do. Say "get stage 1 done" (or tap the stage button on the plan strip) and the team works through that stage without waiting for you: each task starts when its inputs are ready, Chief reviews results, reworks or accepts them, plans an empty stage itself, and the team stops at the end of the stage with one report.
- **Agents decide by default.** Only sign-ins and credentials, money, anything sent or deleted in your name, changes to the plan, and facts only you know come to you; everything else goes to the team's supervisor (Chief), who decides in the background and records why.
- **Work recovers by itself.** Restarts, stalls, step caps, dropped connections and connector failures retry within bounds and then go to the supervisor; a stop is never silent, and nothing waits for you unless it is on that short list.
- Halftone dot figures whose motion shows what each agent is really doing, one dot field behind the chat list, and Light, Dark or Match system appearance.
- Live progress in every chat: an agent sees its running background work (what is running, since when, the command running now, recent results) and the supervisor sees everyone's; times are always in your own time zone.
- Adaptive setup in each new agent's chat, turned into editable instructions; standing preferences you state are saved as directives that override older instructions.
- Agents create requested teams and teammates, with editable briefs and approval for unsolicited suggestions.
- Group coordination with assignments, dependent handoffs, and one shared response.
- **ChatGPT or Claude, switchable in one step.** Settings → AI provider → "Switch all agents to …" previews and moves every agent to the matching model on the other side (by the account's own model descriptions), and switching back restores each agent's previous model. ChatGPT uses your subscription through the local Codex app-server; Claude uses Console/API credits.
- Coding sessions on the agent's own provider: Claude Code on Claude, Codex on ChatGPT, always in a private copy of the project with network and outside writes behind your review.
- Connected services for research, email, and other supported tools, with action reviews.
- Connected-folder files with version checks, recoverable edits, and in-app previews.
- Word paragraph editing, Excel cell and formula editing, PDF forms and annotations, Markdown, HTML, and code.
- Reviewed control of applications on the connected Mac.
- Durable background tasks with a separate local browser and files, saved results, approvals, and pause/resume.
- Spending: runs have no limit of their own; an optional daily limit per agent is the only thing that stops paid work, and a run that reaches it pauses and continues by itself the next day or when the limit is raised.

Independent cloud computers and an always-on remote worker are future work. The local Mac must remain available for local operations. The browser-only frontend is a preview; real conversations and tools run in the native app.

## Source layout

| Directory | Contents |
| --- | --- |
| `outputs/buddy-mac/` | Native Swift app, scoped tools, build script, and native tests |
| `outputs/buddy-worker/` | Private Playwright browser bridge, optional Claude Agent SDK bridge, pinned dependencies and tests |
| `outputs/relay/` | Web frontend, assets, vendored dependencies, and frontend tests |

## Build the Mac app

Requires macOS 13 or later, Xcode command-line tools, Python 3, Node.js 22+, and Chrome for the worker browser.

```sh
npm ci --ignore-scripts --no-audit --no-fund --prefix outputs/buddy-worker
python3 outputs/buddy-mac/build.py --install
```

Quit Buddy before installing an update (background tasks that were running continue by themselves after the restart). This updates the single `/Applications/Buddy.app`, with Apple Silicon and Intel support and an ad-hoc signature. Build staging is temporary and excluded from search; packages and rollback copies are ZIP archives. Agents, chats, files, browser profiles, and Keychain credentials stay in their existing locations. To produce only `outputs/Buddy-mac.zip`, omit `--install`; to install that archive later, run `python3 outputs/buddy-mac/install.py`. Do not create separate check apps or unpack builds elsewhere. Real conversations also require the supported Codex CLI/app-server and ChatGPT sign-in; see the [native app documentation](outputs/buddy-mac/README.md).

## Preview the frontend

```sh
python3 -m http.server 4173 --bind 127.0.0.1 --directory outputs/relay
```

Open `http://127.0.0.1:4173`. See the [frontend documentation](outputs/relay/README.md) for interface details.

## Run checks

Frontend checks require Node.js:

```sh
node --test outputs/relay/*.test.js
node --test outputs/buddy-worker/test/*.test.mjs
```

Native checks require macOS and Xcode command-line tools:

```sh
python3 outputs/buddy-mac/run-tests.py
```

The native tests use isolated local fixtures rather than personal account actions.

## Local data and limits

Runtime conversations, credentials, connected-folder registrations, file history, local backups, app bundles, and generated archives are excluded from version control. Buddy stores runtime state separately in the user's Application Support folder.

PDF editing covers forms, annotations, page rotation, and additional pages; existing printed text is preserved. Excel recalculates formulas when opened in Excel. See the native documentation for format, size, access, and preview limits.

Third-party frontend dependency licenses are included in `outputs/relay/vendor/`.

See the [background worker guide](outputs/buddy-worker/README.md) for startup, provider connections, approvals, local isolation, recovery, and daily limits.
