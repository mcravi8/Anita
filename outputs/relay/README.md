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
- Pick a 3D shape and one of seven colors independently from the agent's name, role, instructions, and tool preferences.
- Open a conversation's details → Create a similar agent to start from a copy of that agent's configuration. Editing the new agent does not change the original.
- Open New chat → Agent suggestions → Try a sample suggestion to review the approval journey. Change the suggested configuration, save it for later, decline it, or approve and add it to selected groups.
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
- `buddy-onboarding.js` / `.css` / `.test.js`: empty initial workspace, migration, resumable setup, and atomic first-agent registration.
- `buddy-agent-setup.js` / `.test.js`: immediate first question, native interview snapshots, retry/stop, profile updates and manual edits.
- `assets/`: four transparent 3D avatar PNGs and the exact generation prompts in `prompts.json`. Created with built-in image generation; original output images were copied into this project unchanged.
- `assets/buddy-logo.svg`: vector logo with the agents' glossy eyes and smile on a white background, also used as the browser icon.

Avatar paths:

- `assets/morgan-3d.png`: lilac star.
- `assets/atlas-3d.png`: blue pebble.
- `assets/nova-3d.png`: orange cube.
- `assets/scout-3d.png`: mint clover.

The Buddy source ZIP includes all assets and their prompts. `../buddy.html` is a standalone version with styles, script, logo, and avatar images embedded. Existing saved chats and settings retain their storage key across the app rename.

## Verification

The messaging redesign was checked at desktop (1440 × 900), intermediate (1024 × 768), and phone (390 × 844) sizes. Verified direct/group navigation, new-chat menu, avatar selection and cancellation, shared-work drawer and task details, draft persistence across reload, empty chat search, phone chat-list navigation, and Escape returning focus from a drawer. No page-level overflow was observed on the tested phone/intermediate layouts; the composer stays visible. The previous version's task handoff, file editing, local message submission, and creation forms remain in the app.

The configurable-team revision was checked on desktop and phone. Verified creating a same-shape agent with independent name/color/instructions, unchanged original settings, editing and saving a pending proposal across reload, approval into a selected group, and declining without adding a member. The phone review scrolls vertically with no horizontal overflow and 44 px decision buttons. Seven domain tests cover migration, pending-proposal isolation, actor guards, saved edits, idempotent approval, configuration independence, atomic validation, and decline finality. Run them with `node --test agent-team.test.js`.

Dialogs contain focus and hide the background from accessibility navigation. The interface supports visible keyboard focus and reduced-motion CSS. Screen-reader operation, storage-failure behavior, file-picker interaction, real network failures and computer operations were not verified in the original frontend pass. Native live model verification is recorded separately in `../buddy-conversations-verification.json`.

The icon polish pass replaced the uneven settings outline with a symmetric gear and removed inherited padding from document badges. Rendered SVG centers match their badge centers on desktop and phone. Chat header/composer buttons, shared-file and task drawers, document details, task details, and Settings were visually inspected; the tested phone views have no horizontal overflow. Settings and detail text now follow Buddy's neutral palette. These changes leave the data and approval flows unchanged.

## Consistent agent colors

All four shapes now use the same Lilac, Light blue, Peach, Green, Autumn red, Yellow, and Blue palette. `agent-team.js` generates SVG color filters that align measured lightness landmarks from each original avatar, then apply shared surface midtones, shadows, and highlights. The original PNG files, transparent edges, silhouettes, glossy lighting, and faces are retained. This replaces the old hue rotation that left Pebble and Cube darker and more saturated.

Existing `rose` appearances migrate to `red`, and removed grey (`stone`) migrates to the new deeper Blue (`cobalt`) in agents and suggested, edited, and approved proposal configurations. Existing `blue`, `mint`, and `gold` IDs remain valid and now display Light blue, Green, and Yellow. Green is a richer leaf green; Autumn red uses a warm rust red; deeper Blue is distinct from Light blue. Live shape/color previews share the same filters as chat avatars. The selected-color check uses dark ink on light colors and white on Autumn red and Blue. All 28 final combinations were visually inspected in a separate preview, and Blue/Cube, Green/Clover, and Autumn red/Star switching and cancellation were checked in the real creation dialog. Ten team tests include palette matching and migration preservation; proof is saved in `../buddy-agent-colors.png`, `../buddy-agent-color-picker.png`, and `../buddy-agent-colors-verification.json`.

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
