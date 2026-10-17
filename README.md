# Anita

A personal AI workspace with configurable agents, individual chats, and group teamwork. This repository contains the Buddy macOS app and its web frontend.

## Features

- Configurable agents with independent conversations, roles, appearances, instructions, and access settings.
- Group coordination with assignments, dependent handoffs, and one shared response.
- ChatGPT sign-in through the local Codex app-server, using subscription allowances.
- Connected services for research, email, and other supported tools, with action reviews.
- Connected-folder files with version checks, recoverable edits, and in-app previews.
- Word paragraph editing, Excel cell and formula editing, PDF forms and annotations, Markdown, HTML, and code.
- Reviewed control of applications on the connected Mac.

Independent cloud computers and an always-on remote worker are future work. The local Mac must remain available for local operations. The browser-only frontend is a preview; real conversations and tools run in the native app.

## Source layout

| Directory | Contents |
| --- | --- |
| `outputs/buddy-mac/` | Native Swift app, scoped tools, build script, and native tests |
| `outputs/relay/` | Web frontend, assets, vendored dependencies, and frontend tests |

## Build the Mac app

Requires macOS 13 or later, Xcode command-line tools, and Python 3.

```sh
python3 outputs/buddy-mac/build.py
```

The build produces `outputs/Buddy.app` and `outputs/Buddy-mac.zip`, with Apple Silicon and Intel support and an ad-hoc signature. Real conversations also require the supported Codex CLI/app-server and ChatGPT sign-in; see the [native app documentation](outputs/buddy-mac/README.md).

## Preview the frontend

```sh
python3 -m http.server 4173 --bind 127.0.0.1 --directory outputs/relay
```

Open `http://127.0.0.1:4173`. See the [frontend documentation](outputs/relay/README.md) for interface details.

## Run checks

Frontend checks require Node.js:

```sh
node --test outputs/relay/*.test.js
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
