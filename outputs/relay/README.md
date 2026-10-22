# Buddy frontend

A simple personal messaging app for agents, inspired by the supplied Grok Bot screenshot and the direct-message feel of WhatsApp. The main view shows a chat list and one conversation. Files, tasks, computers, profiles, and instructions are available on request in drawers or dialogs.

## Open it

Open `index.html` in a browser, or serve this folder locally:

```sh
python3 -m http.server 4173 --bind 127.0.0.1
```

Then open `http://127.0.0.1:4173`. There are no dependencies or build steps.

## Try the interface

- Set up your first Buddy: choose a name and look. Start chatting saves the agent and immediately opens its job interview in the DM. In the Mac app, Claude asks relevant follow-ups and generates editable instructions once the brief is clear. Fresh workspaces start without sample agents. Setup choices and answers persist across reloads.
- Use the plus beside Chats to create an agent or a group.
- Click the conversation title or three dots for agent/group details and instructions.
- Pick a figure (Diamond, Sphere, Hex or Pill) and one of seven colors independently from the agent's name, role, instructions, and tool preferences. The preview is the live figure.
- Settings → Appearance switches between Light, Dark and Match system.
- Open a conversation's details → Create a similar agent to start from a copy of that agent's configuration. Editing the new agent does not change the original.
- Open New chat → Agent suggestions → Try a sample suggestion to review the approval journey. Change the suggested configuration, save it for later, decline it, or approve and add it to selected groups.
- The chat header is a floating pill with the figure and name. The chevron on its right slides out the subtitle and the actions (shared files, details); the choice holds as you move between chats. Messages scroll under a soft fade.
- The sidebar's dot field plays: quiet patterns form and dissolve in the background; a working agent has a thought cloud over its head; opening a chat grows roots from the agent's head across its row; a reply that lands in a chat you are not in shows as a dot-matrix count at the right of the row (dots converge on it as it lands); typing sends dots from the composer into the agent and it looks your way; after 15 idle seconds agents close their eyes and only choosing one wakes it. With reduced motion the counts, the sleeping eyes and the cloud stay and the moving effects go. The code is `buddy-field-play.js`, plugged into `BuddyFigures.extend`.
- Click the folder in a conversation header for shared Files, Tasks, and Computer tabs.
- Write messages, mention bots, and revisit saved drafts.
- Create tasks, assign ownership, hand off work, and mark tasks done.
- Inspect shared files, edit their contents, save versions, and download them.
- Search bots, groups, and files with the search button or Command/Ctrl + K.
- Open workspace settings from the bottom of the chat list for subscription and Connections.

Changes are stored in this browser. Settings → Reset preview restores the original samples. Browser storage may be unavailable under some browser privacy settings; the interface then reports that changes are temporary.

## Frontend boundary

The optional sample workspace's conversations, tasks, and files are clearly labeled sample content. Fresh workspaces begin with onboarding and no fixed agents. The standalone browser preview has no native model connection and directs you to open the Buddy Mac app for real chats. No bot responses, tool activity, or cloud execution are manufactured after a message is sent. Attachment selection records file names and sizes only; files are not uploaded or read by an agent.

Agent proposals are local records. Pending proposals never create an agent, chat, group membership, or task. Approval creates an independent agent from the reviewed configuration; decline creates nothing. Sample proposals are labeled and appear only when requested. The proposal history keeps the original suggestion and the approved configuration. In the Mac app, Shared files grants read/create/edit access to the selected folder; it is on by default and can be removed. Web research is a preference; reading-service access is managed in Connections. Browser checkboxes alone do not connect tools.

The native Buddy Mac app now connects direct messages through the local Codex app-server using ChatGPT sign-in; see `../buddy-mac/README.md`. The Mac app supports real group teamwork: hidden coordination, assignments and dependent handoffs, one combined reply, and inspectable contributions through a small Teamwork link. Shared-folder file execution is live in the Mac app: actual save cards, direct editing, conflict comparison, and restore history. Desktop control, cloud computers, binary attachments, and direct-message delegation remain future work. Agent suggestions are live in the Mac app. Supported connected-service reading is on by default in the native app, with individual access removals in Connections. Browser assets make no direct model requests.

The native Mac integration exposes only pending suggestion creation to model turns. Approval, edits, and decline use the bundled UI bridge and are validated by the native backend. Frontend actor checks support the standalone preview; they are not the live authorization boundary.

## Source

- `index.html`: application entry point.
- `styles.css`: visual system and responsive layouts.
- `agent-config.css`: customizable agent and proposal review surfaces.
- `buddy-brand.css`: Buddy wordmark and face-logo sizing.
- `agent-team.js`: configuration, migration, proposal state, and approval transitions.
- `agent-team.test.js`: invariant tests for independent configuration and approval gating.
- `app.js`: rendering, interactions, persistence, and the native chat bridge.
- `buddy-chat.js`: isolated conversation state, retries, streaming updates, and interrupted-reply recovery.
- `buddy-chat.css`: quiet live-reply and expandable-example styling.
- `buddy-chat.test.js`: conversation-state invariants and isolation checks.
- `buddy-connections.js` / `.css`: real native connection discovery, per-agent reading permissions, refresh/errors and unavailable computer states.
- `buddy-connections.test.js`: unavailable-service gating, independent grants, and revocation checks.
- `buddy-proposals.js` / `.test.js`: live native suggestion discovery, reply cards, reviewed decisions, and verified agent registration.
- `buddy-files.js` / `.css` / `.test.js`: native shared-file interface and receipt/conflict checks.
- `buddy-drop-events.js` / `.test.js`: the desktop drop's events: which delivered task results, plan notices and sign-in requests put an agent on the screen while Buddy is in the background, once each; Settings → Desktop drop; opening the chat a clicked holder was for.
- `buddy-drop.html` / `buddy-drop.js`: the desktop drop itself, drawn in the Mac app's transparent panel: the holder built from dots, the figure, the label, stacking, and the Reduce Motion path.
- `buddy-signin.js` / `.css` / `.test.js`: sign-ins asked in the chats (the agent's, and the team's group chat for team-plan work): a private field for a website's password or code, or a service sign-in, sent only to the app's sign-in bridge and never kept on the page; Done for a step done elsewhere.
- `buddy-onboarding.js` / `.css` / `.test.js`: empty initial workspace, migration, resumable setup, and atomic first-agent registration.
- `buddy-agent-setup.js` / `.test.js`: immediate first question, native interview snapshots, retry/stop, profile updates and manual edits.
- `buddy-figures.js` / `.test.js`: the halftone figure engine (shape distance fields, springs, blinking, eyes, progress rings) and the runtime that paints every `canvas[data-fig]` and the sidebar dot field.
- `buddy-figure-modes.js` / `.test.js`: turns real workspace state into figure modes (nothing animates between members).
- `buddy-theme.js` / `.css` / `.test.js`: Light, Dark and Match system, the design tokens, and the restyled surfaces. Loaded last.
- `assets/buddy-logo.svg`: the Buddy mark, used as the browser icon. The in-app logo is a live figure.

The Buddy source ZIP includes all assets. `../buddy.html` is an earlier standalone version with styles, script, logo and the old 3D avatar images embedded; it was not regenerated for the figures.

The icon polish pass replaced the uneven settings outline with a symmetric gear and removed inherited padding from document badges. Rendered SVG centers match their badge centers on desktop and phone. Chat header/composer buttons, shared-file and task drawers, document details, task details, and Settings were visually inspected; the tested phone views have no horizontal overflow. Settings and detail text now follow Buddy's neutral palette. These changes leave the data and approval flows unchanged.

## Figures, the dot-field sidebar and appearance

Agents are halftone dot figures in one ink colour with the eyes cut out as negative space. The four shapes are Diamond, Sphere, Hex and Pill; the saved IDs are `diamond`, `sphere`, `hex` and `pill`. Saved workspaces, proposals, model suggestions and team plans that still say `star`, `pebble`, `cube` or `clover` are read as the figure that replaced them (`agent-team.js` `migrate()`/`appearance()`, `BuddyAvatar` in the native app). Unknown shapes fall back to the diamond instead of breaking the avatar.

The seven colour IDs are unchanged (`lilac`, `blue`, `peach`, `mint`, `red`, `gold`, `cobalt`; earlier `rose` and `stone` still migrate to `red` and `cobalt`). Each has a light ink, a dark ink and an author-name colour in `agent-team.js`; `buddy-figures.js` draws with the same inks and a test keeps the tables equal.

`BuddyFigures.avatarHTML(agentOrGroup, size)` returns a `canvas[data-fig]`; one `requestAnimationFrame` loop paints every visible one (alternating halves of the list, about 30 fps each) and skips canvases that are off screen. CSS decides how large a figure is drawn. The whole chat-list sidebar is one dot field: rows hold empty slots and the field draws each head at the slot's measured position, so hand-offs, needs pulses and the selected and hover bands can travel between rows. Eyes follow the cursor while it is over the sidebar.

Figure motion comes from real state (`buddy-figure-modes.js`, synced after every render and save): a reply that is starting is *planning*, streaming is *working* (progress ring), an action review waiting on you is *needs* (pulse, looks at you), a finished reply is *done* (spin, sparkles, back to ready after 1.7 s) and a failed one is *stuck* (tilt, back to ready after 8 s). In a group run the lead plans while members watch the lead, the member whose step is running works while the others watch them, no stream of dots joins members or the group row (the member working is simply shown working), and a completed run is *done* for everyone, 160 ms apart. Opening the app never replays old runs.

Appearance is saved in the workspace as `theme` (`light`, `dark` or `system`; missing means light). `buddy-theme.js` writes the resolved theme to `<html data-theme>` and every stylesheet reads the tokens in `buddy-theme.css`. The Mac app is told the choice (`BuddyDesktop.setAppearance`) so the window, title bar and system controls match. The fonts are Geist and Geist Mono, bundled in `assets/fonts/` (SIL Open Font License, see `OFL.txt`), with the system fonts as the fallback.

## Connections

Settings → Connections shows the installed services returned by the real ChatGPT account. Common services appear first; additional connections and Files & computers expand on request. Select a service and choose which agents may read it. Sending and external changes stay disabled. All available connections start enabled for every agent. Individual removals are persisted independently by the native app for each workspace and agent; new services default on. Updating permissions interrupts a current reply and applies a fresh policy while retaining history on the next message. New agents start with all available reading connections, independently of a copied agent’s removals.

Browser previews explain that Connections requires the Mac app. Loading and refresh failures do not grant access; an unavailable service can only have existing access removed. Native service discovery, default-on migration and permission controls, and a real public-web tool call followed by same-agent revocation are recorded in `../buddy-connections-verification.json`. Private Gmail, Drive, calendar and contact contents were not accessed during verification.

## Group teamwork

Create a group or open an existing one and send a text message in Buddy for Mac. A coordinator chooses actual members based on their current roles and instructions, runs up to three useful assignments, hands completed work to reviewers, and selects an actual member to give one combined streamed reply. Simple requests can be answered without extra assignments. Coordination does not add messages to individual DMs. The Teamwork link shows actual assignments, dependencies, errors, and contributions on request. Group history is independent of DMs; sample content is excluded. Stop interrupts all running contributions. Retry reuses the original user message with current group settings. Editing the group stops its current request first.

Group tools use the intersection of members’ access, so an agent’s removal cannot be bypassed through teammates. Service tools remain read-only. Per-agent defaults stay enabled. Internal group model sessions are ephemeral; real group messages and work products are saved in the local workspace. The standalone browser remains an interface preview and does not simulate replies or progress.

Twenty-five frontend domain tests cover configurable agents, proposals, palette migrations, direct/group routing, atomic event validation, isolated history, partial retries, restart recovery, and connections. Native orchestration and real ChatGPT subscription tests are recorded in `../buddy-teamwork-verification.json`.

## Shared files in Buddy for Mac

Open the folder in any chat for actual files. Ask an agent or group to read, create, or edit them. Successful saves add a file card to the reply; the card opens the current contents. You can edit directly, create a file, refer to it with Use in chat, and restore previous contents through Saved versions. Folder & access hides the actual folder location, Finder shortcut, folder picker, and capability details until requested. Every agent starts with file access; remove it through Agent settings → Tools. Group access requires every member. Stale edits retain the manual draft and offer Compare latest version; nothing silently overwrites another Buddy agent’s edit. The native backend checks paths, current permissions, folder identity, and full-content version on every operation. Native tests and live model/native UI evidence are recorded in `../buddy-files-verification.json`. `buddy-files.js` and `buddy-files.css` implement the native file interface; the standalone browser remains an interface preview.

## First-agent setup verification

Thirty-two frontend domain tests include empty first launch, preservation of existing work, independent configuration, stable registration IDs across retries, duplicate/invalid configuration rejection, completion, and resumable setup. The real native save bridge was checked in an isolated Mac app: configured a green Cube named Cedar, deliberately failed a save, retained all choices with zero agents registered, retried successfully, and reopened the saved empty DM. No model messages or private connected-service reads were needed for these setup checks. The phone view was visually checked at 390 × 844 with appearance collapsed and expanded; no horizontal overflow was observed and shape/color controls meet 44 px minimum touch targets. See `../buddy-onboarding-verification.json` for installation and data-preservation evidence.

## Live agent suggestions

Chief and other agents can now save real pending suggestions through `buddy_propose_agent`. Review cards appear in the actual reply. Editing appearance is optional; name, role, instructions, and the human decision stay clear. Suggestions and edits survive restart. Approval registers exactly one independent agent and only the reviewed groups; declined suggestions add nothing. Neither model text nor frontend actor flags can approve a native suggestion. Native decision failures keep the review open and retain its entered configuration. New chat → Agent suggestions shows current pending records and decision receipts; the sample entry and sample-reset action are hidden in the Mac app.

Forty-three frontend domain tests include authentic suggestion association, workspace isolation, late-event rejection, independent/idempotent approved registration, and rejection of mismatched approval evidence. Native and live test results are recorded in `../buddy-proposals-verification.json`.

Reply handling now keeps tool progress separate from the conversation result. A completed tool cannot discard the final answer; a genuinely empty completion has a retryable error. The affected Maze reply was recovered from its exact stored final answer, without another Gmail search.

Replies render Markdown locally: headings, emphasis, lists, labeled links, code, quotes, and tables. The bundled marked 18.1.0 parser and DOMPurify 3.4.16 sanitizer do not use a CDN. Raw HTML is displayed as text; images do not fetch automatically; only HTTP, HTTPS, and mailto links can become links. Desktop and 390 px phone rendering, readable wrapping, and unsafe content were checked. Shared-file and agent-proposal tools now use one canonical configuration; a real model used both successfully in one reply.


## Mac app access · 0.10

The native Mac build now has This Mac setup, default-on per-agent Mac-app access after connection, in-chat app and operation reviews, and durable receipts. Extra information stays in Connections and collapsed details. The missing shared confirmation-toast function is restored. Capacity failures keep the original message and suggest retrying shortly. Cloud computers remain unavailable through Buddy; no paid hosting or API fallback is created. The frontend alone does not grant or operate a computer. Native and live evidence is in `../buddy-computer-verification.json`.
