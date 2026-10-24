# Buddy

**A team of AI agents on your Mac that takes a job from start to finish, and only asks you what matters.**

Give Buddy an objective and its supervisor, Chief, splits it into stages and tasks for
your agents. Say "get stage 1 done" and the team works through that stage on its own,
with your files, your browser accounts and your sign-ins, while the agents never see a
password. It runs on your ChatGPT subscription or your Claude API key.

[Get started](#get-started)
· [Go further](#go-further)
· [Development](#development)
· [Report an issue](https://github.com/mcravi8/BuddyBot/issues)

![Buddy showing a team chat with four agents, the chat list and the dot-field sidebar.](docs/images/buddy.png)

*The interface with its built-in sample team.*

## What you can do

- **Hand over a whole objective.** Chief splits it into stages, each with tasks and a
  clear "done when". Choose a stage and the team runs it to the end: each task starts
  when its inputs are ready, Chief checks the results, asks for rework or accepts them,
  and you get one report when the stage is done. The plan and the project's files stay
  open beside the chat, and you can close or reopen that panel.
- **Only be asked what matters.** Agents decide by default. Sign-ins, money, anything
  sent or deleted in your name, changes to the plan and facts only you know come to you.
  Everything else goes to Chief, who decides in the background and records why.
- **Approve less, in plain words.** Public downloads into the project are approved for
  you, and Chief reads a script before letting it run outside the sandbox. What still
  reaches you reads as one sentence, such as "Chief wants to download 2 files from
  arxiv.org", with the reason, the exact command under Details, and two buttons:
  Approve and Disapprove.
- **Sign in once, for everyone.** Sign in to your accounts in one Chrome window and every
  agent with internet access can use them. A password or code you type goes into a
  private field in the chat and only to the page that asked for it. Your WRDS sign-in is
  kept in your Mac's Keychain, and Duo or any other step you take outside the chat ends
  with a Done button.
- **Use any web service, with cleanup that can't be forgotten.** Connect a service once
  (RunPod, say): its address, how its key is sent, whether it can charge you money, and
  the key, which stays in your Mac's Keychain. Agents call it through Buddy and never see
  the key. Reading is free; a change on a service that can charge money comes to you as
  one card with the exact request, the agent's reason and its cost estimate. Anything it
  creates that bills by the hour is a lease Buddy deletes itself: when the agent is done,
  when the task ends, and after the hours you approved. Updating or restarting Buddy keeps
  it running and watched. A machine it rents is reached over Buddy's own SSH key: agents
  upload project folders, run a command and bring results back without overwriting
  anything.
- **Keep each task on the right account.** Name an account for a task ("use my USC
  account") and Buddy opens every Google page of that task as that account, and stops
  instead of acting as another one.
- **Work with your real files.** Connect folders on your Mac. Agents read and edit the
  originals with version checks: Word, Excel, PDF forms, Markdown, HTML and code. A file
  linked in a chat opens in Buddy, and a finished stage shows the files it made.
- **Code on either provider.** Coding sessions use Claude Code on Claude and Codex on
  ChatGPT, always in a private copy of the project, and save their results back into
  your folders.
- **Switch between ChatGPT and Claude in one step.** Every agent moves to the matching
  model on the other side, and switching back restores each agent's previous model.
- **See what is happening.** Each agent's figure moves with what it is really doing, and
  agents see their own running work: what is running, since when, and the latest result.
  Times are in your own time zone.
- **Leave work to run.** Background tasks and scheduled checks keep going between your
  messages. They recover from restarts, stalls and dropped connections, and a stop is
  never silent.

Each agent has its own chat; group chats bring a team together around one objective.
Buddy has no limit per run: an optional daily limit per agent is the only thing that
stops paid work, and a run that reaches it continues the next day.

## Get started

You need a Mac with macOS 13 or later, the Xcode command-line tools, Python 3,
Node.js 22 or later and Google Chrome. For the AI, use a ChatGPT subscription with the
Codex app signed in, or a Claude API key.

1. Install the background worker's dependencies, then build and install the app:

   ```sh
   npm ci --ignore-scripts --no-audit --no-fund --prefix outputs/buddy-worker
   python3 outputs/buddy-mac/build.py --install
   ```

   This puts a single `Buddy.app` in Applications, for Apple Silicon and Intel.
2. Open Buddy. In **Settings → AI provider**, connect ChatGPT or add your Claude key.
3. Open **Background work → Browser sign-in → Open Chrome**. Sign in to Chrome with your
   Google account, to bring your saved passwords, and to any sites your agents should
   use. The page then shows which Google accounts are signed in.
4. Connect a folder under **Buddy desktop**, create your agents or a team, and give
   Chief an objective. When the plan is ready, say "get stage 1 done".

> **Buddy acts with your accounts.** Every agent with internet access uses the accounts
> signed in to Buddy's Chrome, so give internet access only to agents that need it.
> Agents never see your passwords, codes or saved-password contents, and sending,
> deleting, paying and signing in still wait for you.

Buddy is a personal project. Your ChatGPT or Claude usage follows your provider's plan
and billing.

<details>
<summary>Build without installing, or try the interface in a browser</summary>

To produce only `outputs/Buddy-mac.zip`, leave out `--install`. Install that archive
later with:

```sh
python3 outputs/buddy-mac/install.py
```

To update, build and install the same way. Quit Buddy first; running background tasks
continue by themselves after the restart. Your agents, chats, files, browser profiles
and Keychain sign-ins stay where they are.

To look at the interface without the Mac app, serve the frontend and open
`http://127.0.0.1:4173`:

```sh
python3 -m http.server 4173 --bind 127.0.0.1 --directory outputs/relay
```

The browser preview uses sample content; real conversations and tools run in the app.

</details>

## What happens when you close your Mac?

Buddy runs on your Mac, so its work pauses while the Mac sleeps and picks up by itself
when it wakes. A restart or an update doesn't lose work either: running and waiting
tasks continue afterwards.

To keep the team working with the lid closed, keep the Mac on power and either connect
an external display or use a keep-awake app in closed-display mode. Don't run it closed
inside a bag.

Buddy doesn't move work to cloud machines, because they couldn't use your signed-in
accounts, your Keychain sign-ins or your folders without copying them off your Mac.

## Go further

| Task | Guide |
| --- | --- |
| How plans, the supervisor and recovery work | [How Buddy works now](outputs/buddy-mac/README.md#how-buddy-works-now) |
| Providers, approvals, the private browser and daily limits | [Background worker](outputs/buddy-worker/README.md) |
| What the private browser refuses on the network | [Network rules](outputs/buddy-worker/README.md#what-the-private-browser-refuses-on-the-network) |
| Connect folders and edit documents | [Connected folders](outputs/buddy-mac/README.md#connected-folders) |
| Figures, the dot-field sidebar and appearance | [Interface](outputs/relay/README.md#figures-the-dot-field-sidebar-and-appearance) |
| What Buddy stores on your Mac | [Local data](outputs/buddy-mac/README.md#local-data) |
| Every change, release by release | [Native app notes](outputs/buddy-mac/README.md) |

## Development

This repository (BuddyBot) holds the app in three parts:

| Directory | Contents |
| --- | --- |
| `outputs/buddy-mac/` | Native Swift app, scoped tools, build and install scripts, native tests |
| `outputs/buddy-worker/` | Private Chrome bridge, coding-command runner, pinned dependencies and tests |
| `outputs/relay/` | The interface (web page shown inside the app), assets, vendored dependencies and tests |

Run the checks:

```sh
node --test outputs/relay/*.test.js
node --test outputs/buddy-worker/test/*.test.mjs
python3 outputs/buddy-mac/run-tests.py
```

The native tests use local stand-ins for Claude, Codex, websites and the Keychain.
They never use your accounts.

Keep exactly one installed app, `/Applications/Buddy.app`, and update it in place; see
[AGENTS.md](AGENTS.md). Runtime data, sign-ins, built apps and archives stay out of
version control. Third-party frontend licenses are in `outputs/relay/vendor/`.

Bug reports are welcome as [GitHub issues](https://github.com/mcravi8/BuddyBot/issues).
Include what you did, what you expected and what Buddy showed.
