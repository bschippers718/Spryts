# Spryts

A native macOS team of animated specialists. Pip coordinates your day and your Mac; Nova works on code; Ember writes; Rally coaches. Each has its own movement, personality, and workspace.

## Run it

Double-click **Run Spryts.command**. It builds the app and starts it. Save work before rebuilding: the normal launcher stops the existing app. Quit from the ✦ icon in the menu bar.
For development validation while you keep using Spryts, run `bash "Run Spryts.command" --build-only`; it leaves the running app untouched.

- Hover on a character for a moment to open its chat. Click a specialist to open its workspace.
- Drag a character to pick it up and drop it somewhere else.
- Characters walk along the tops of your windows and the bottom of the screen.

## Engines and models

Choose an engine per character from its model menu. Claude Code and Grok use their own installed agents and sign-in;
Nova also supports OpenAI Codex through its local app server. Codex models are discovered from the installed agent.
You can enter a model ID supported by the selected engine and account. Switching engines starts a fresh agent session
and supplies a bounded excerpt of the previous conversation as context. Other characters keep their engine.

The menu bar's engine setting is only a default for new Spryts. A missing agent is shown as disconnected;
a real task never silently falls back to a demo reply. No API keys are copied between engines.

## API keys

For characters configured to use direct APIs instead of an installed agent, keys live in `.env` in this folder:

```
ANTHROPIC_API_KEY=...
XAI_API_KEY=...
MESHY_API_KEY=...
```

A direct-API character without a chat key shows an explicitly labeled demo reply. Built-in agent-backed characters need their selected engine installed and signed in.

## Characters

Each file in `Characters/` is one character: its persona, its look, and the numbers that shape how it moves
(`speed`, `stride`, `bounce`, `armSwing`, `lean`, `tempo`, `fidget`, `jumpiness`, `sway`). Edit a file and run again.

Walks accelerate and ease to a stop, with footsteps tied to distance travelled. Scarves, ears, stalks and tails
follow through after a turn or a landing. Each specialist has its own small habits and greeting: Pip waves,
Nova nods, Ember bows, and Rally cheers. One nearby Spryt welcomes you back; the others simply wake up.
Quiet mode pauses optional fidgets and social exchanges, and a crowded stage moves less often.

## Generated characters

Double-click **Make Character.command** to build Mochi with Meshy from the prompt in `Characters/mochi.json`.
It saves one animated file per clip into `Characters/models/mochi/`. Mochi appears once those files exist.

## Layout

- `Sources/Spryts/AppDelegate.swift` — the transparent stage, hover and drag
- `Sources/Spryts/World.swift` — finds window edges to stand on
- `Sources/Spryts/Character.swift` — behaviour and the pose for each frame
- `Sources/Spryts/Personality.swift` — role-specific gestures, breathing and neighbourly chatter
- `Sources/Spryts/WalkingMotion.swift` — acceleration and stopping distance
- `Sources/Spryts/Bodies.swift` — the built-in body and the loader for generated models
- `Sources/Spryts/ChatService.swift` — Claude and Grok, normalised into one event stream
- `Sources/Spryts/ChatPanel.swift` — the chat bubble

## Command center

Pip works through your selected installed agent and the macOS permissions you grant. He can act on this Mac:
open and switch apps, script them, run Shortcuts, read files, and take a screenshot to see the screen.

- **Control-Option-Space** summons Pip with the text field ready. Press it again to dismiss.
- The strip of icons shows open apps, most recently used first, then recently quit ones. Click to switch; right-click for more.
- Drop files on Pip or on the panel to attach them.
- Risky actions wait for you: Allow once, Allow for this task, or Deny. Destructive or outbound actions always ask.
- The stop button, or picking Pip up, stops the run.

The agent works from `~/Library/Application Support/Spryts/workspace`, and can read Desktop, Documents and Downloads without asking.


## Pip's workspace

Pip has a native AppKit sidebar, unified window toolbar, and a full conversation view. Recent chats, pinned chats,
projects, Scenes, Today, Connections, and Team live together. All Chats searches saved message text; Archived Chats restores
conversations without deleting them. The optional conversation inspector stays beside your work on wider windows
and opens as the full conversation when space is limited.

Projects group conversations with shared instructions and local reference files. References stay in their original
folders; Pip reads relevant files through the selected engine's normal tools and permissions. Each conversation
keeps its own draft, attachments, model, engine session, working folder, and remembered context. New Chat keeps the
previous conversation. Editing project context or moving a chat resets its engine session to avoid stale instructions.

The library saves atomically on disk. Drafts autosave after a short typing pause and flush before switching chats,
closing the workspace, quitting, or restarting. A failed save keeps the current conversation open and reports the
problem. Existing Pip history migrates without changing the original memory file. Interrupted tasks remain visible
and do not restart automatically.

- **Command-N:** New chat, retaining the current project when applicable.
- **Command-Shift-N:** New project.
- **Command-K:** Search chats and projects.
- **Command-L:** Focus the conversation.
- **Command-Return:** Send; Return inserts a new line.

Connections lists installed Mac apps with Open and Ask Pip actions. It separately checks services configured in
the selected Claude Code or Grok engine. Add Service accepts a remote HTTPS MCP address and saves it to the engine's
personal configuration only when you click Save. Sign-in stays with the engine; a configured service is not assumed
to be connected. Claude's explicit Check Services action may start approved servers to check their health;
Grok's list reports configuration and checks connections when used. No services are checked automatically.
Mac Access includes engine setup and read-only checks of Accessibility and Screen Recording access. Automation
access is granted separately per application; the command-line agent may need its own permissions.

Team shows live specialist activity and a durable history of delegated work, including approvals, failures, and reports.

Handoffs retain their sender, recipient, project, and result. Work is removed from the inbox only after it is saved.
A specialist's final answer appears back in the sender's conversation and Pip's next-turn context.
“Reported back” means the specialist returned a report, which may contain blockers; it is not a claim of verified success.
After a restart, interrupted work stays visible and is never automatically rerun. Delegated work cannot recursively delegate.

## Scenes: five useful starting points

New Pip libraries open to Scenes. Each starter presents an outcome, a short setup form, explicitly selected sources,
optional local references, a project, and a preview of the request. **Open as Draft** saves a new conversation;
**Start Scene** saves it before asking the selected engine to work. Neither action discards the previous conversation's
composer. Missing or unavailable connections must be reported, never inferred from a selected app name.

| Scene | First useful result | Suggested sources |
| --- | --- | --- |
| Start My Day | Three priorities, commitments, conflicts, and a suggested work block | Calendar, Reminders, Mail |
| Meeting Ready | A sourced meeting brief, proposed agenda, decisions, and questions | Calendar, Mail, Notes, selected files |
| Project Launch | A brief, milestones, dependencies, and proposed Nova/Ember handoffs | Selected files, Notes, Reminders, Spryts |
| Paperwork, Sorted | A document inventory, missing-item checklist, and proposed filing changes | Selected files, Mail, Notes |
| Social Studio | Three sourced post drafts and an explicitly unscheduled content plan | X, LinkedIn, Instagram, Threads, Bluesky, Ember, selected files |

First passes are bounded: they inspect a limited batch of selected material and produce reviewable results. They do not
publish posts, send messages, move paperwork, or dispatch a team merely because a starter was selected. App access still
uses the engine's existing tools and permissions; native Calendar and Mail adapters are not included in this change.

Customers can create a Scene, customize a starter, edit it, and delete it while retaining its conversations. Custom Scenes
save atomically per chief. Failed writes remain retryable, and an unreadable file is preserved. Recent Scene conversations
show Draft ready, Working, Response ready, Needs attention, or Interrupted. These describe conversation execution;
Response ready does not certify that every proposed real-world action happened. Scenes are reusable requests, not yet a
scheduled workflow engine with dependency tracking or structured artifact verification.

## Make your own Spryt

**✦ → Make a Spryt** opens the maker: a live stage on the left, four tabs on the right. Whatever you change, the
Spryt on the stage does at once, with the same motion code the real stage uses.

- **Look.** Start from a ready-made Spryt or from **Surprise Me**, then change colours, head, body, eyes, face,
  proportions and extras (ears, tails, wings, capes and the rest).
- **Movement.** Choose its walk (natural, strut, march, bounce, swing, waddle, glide, shuffle), how it likes to get
  around (walking, skipping, running, tiptoeing), and tune speed, bounce, stride, lean and temperament.
- **Moves.** Eighteen things it can do in a spare moment: jump, triple hop, flip, twirl, dizzy spin, dance, swing,
  jumping jacks, high kicks, stomp, shimmy, wiggle, flex, stretch, bow, wave, victory lap, moonwalk. Tap one to
  watch it and add it. Set how high it jumps and how often it shows off.
- **Voice.** Its personality in your words, what it says to other Spryts, how it greets them, and the pitch and
  pace of its speaking voice.

**Bring to Life** puts it on the stage. **⋯ → Share…** writes a `.spryt` file anyone with Spryts can open. A made or
opened Spryt can chat and nothing else: it has no tools and no access to files or the Mac, whatever its file says.

## X Feed (Sift, built in)

Pip's workspace has an **X Feed** pane: X's own site, shown inside Spryts, with [Sift](https://benschippers.com) running
in the page. Sign in to X once in the pane (username and password; Google and Apple sign-in buttons don't work inside
an app) and it stays signed in. No API key, no credits.

- **Filters** is Sift's settings as a Mac form: a List to read from, starter packs and topics, blocked phrases,
  promoted posts, reposts, quotes, accounts to always or never show, a cap per account, and the focus layout.
  Changes apply as you type. Sift's own controls in the page (never show, block a phrase, review what was filtered) write to the same settings.
- **Brief** sends the latest posts Sift kept, twenty at most, to Pip's engine and opens the answer beside the feed.
  Nothing is sent until you press it. Pip can't post, like or follow from here.
- Links that leave X open in your browser. **⋯ → Sign Out of X** forgets the sign-in kept by Spryts only.

The filtering is the extension itself: `Sift/shared.js`, `content.js` and `content.css` are copied from Sift 1.0.1
unchanged. To update, replace those three files. Settings are kept per chief in Application Support.

## X and social connections

Connections includes a native **X Workspace**. It supports OAuth 2.0 public-client PKCE sign-in, account verification,
explicit saved-sign-in restoration, and manual reads of mentions, your posts, or recent search. Credentials stay in a
local, nonsynchronizing Keychain item. Every fetch requests at most ten posts. There are no background feed reads,
pagination, publishing endpoints, or write scopes. API reads consume the registered app's X API credits.

Choose posts and ask Pip to summarize them, draft replies, or develop ideas. This creates a Social Studio conversation
with source URLs, the verified account, original query/feed, fetch time, and post dates. Selected text goes to the chosen
conversation engine. Long content is explicitly excerpted to fit a bounded request; tokens never enter the conversation.
Local disconnect removes the saved credential; revoking the provider grant is a separate action in X account settings.

Before distributing a working connection, register Spryts as an X **Native App**, enable OAuth 2.0, and register the exact
callback `spryts-auth://oauth/x`. Configure its public client ID as `SPRYTS_X_CLIENT_ID`, or enter it in the workspace's
Developer setup disclosure. Do not embed a client secret. This change has fixture coverage but has **not** completed a
live registered-client sign-in; provider acceptance of the callback, account permissions, and production API access still
need an end-to-end check. See X's [OAuth guide](https://docs.x.com/fundamentals/authentication/oauth-2-0/authorization-code)
and [API pricing](https://docs.x.com/x-api/getting-started/pricing).

LinkedIn, Instagram, Threads, and Bluesky have separate setup guidance. Those entries do not connect an account by
themselves; their native adapters are not yet implemented. Existing engine-configured services remain usable where
supported. A production release should register provider apps so customers see ordinary account sign-in rather than
developer configuration, and should report each connection's actual capabilities and availability.

## Nova's workspace

A three-column workspace puts files, code, and the assistant side by side. Use Code, Review, Run, and Terminal modes;
show or hide either sidebar as needed. The editor includes line numbers, native Find, and per-file undo.
Unsaved drafts survive switching files, following agent edits, and switching projects within the running app.
Save detects external changes before overwriting; closing the window or quitting asks about unsaved work.
Drafts are currently held in memory, so force-quitting or a crash can lose them.

- **Command-Shift-O:** Quick Open, with arrow-key selection.
- **Command-1 through 4:** Code, Review, Run, Terminal.
- **Command-L:** Focus the assistant.
- **Command-S / Command-Option-S:** Save / Save All.
- **Command-F / Command-G:** Find / Find Next.

Codex uses native command and file approvals, streams progress into the shared activity view, and reports failures and
interruptions distinctly. Its adapter uses the documented [Codex app-server protocol](https://developers.openai.com/codex/app-server/).
Claude Code and Grok keep their existing approval gates. Models and tool capabilities depend on the installed engine and account.

## Next product milestones

The native workspaces, starter Scenes, and saved team handoffs establish the foundation. Prioritize these next:

1. Complete live X sign-in and ship registered provider apps; then add native LinkedIn, Instagram, Threads, and Bluesky
   adapters with source-linked research and account-specific drafts. Publishing needs a preview of the exact account,
   content, and media, an explicit action, and a provider receipt with duplicate prevention.
2. Make Mac context effortless: native Calendar and Reminders readers, a share action for selected content, and useful
   results that link back to their original document, event, message, or post.
3. Let customers act on a result: preview exact file/calendar changes, apply approved operations, and provide undo where
   supported. Keep a durable run record with inputs, sources, artifacts, and actual completion or blockers.
4. Give Pip a shared project plan with dependencies, bounded Nova/Ember handoffs, progress, and user-controlled retries.
   Only offer recurring Scenes after that execution and recovery model works reliably.
5. Finish Nova's daily coding loop with recoverable editor drafts, richer code intelligence and debugging, and measured
   end-to-end tests across real Mac workflows. Model and tool availability must reflect the customer's actual accounts.

Launch quality should be judged by time to a useful first result, repeat Scene use, source accuracy, recoverable failures,
and verified task completion. These are product goals, not measurements already collected.


## Adding a character role

Every character is its own specialist with its own popup, window and habits. The checklist for a new role is in `CLAUDE.md`.

## Checking movement

Run `bash tools/check-motion.command` to check acceleration, braking, arrival and turns at 30, 60 and 120 fps.
It compiles in temporary storage and does not launch or install the app.

## Checking the workspaces and agents

These checks use temporary storage and fake agent processes; they do not run model inference or install the app:

- `bash tools/check-workspace.command` — drafts, file transitions, and save conflicts.
- `bash tools/check-team.command` — durable handoffs, reports, restart recovery, and write failures.
- `bash tools/check-codex.command` — app-server protocol, approvals, streaming, cancellation, and failures.
- `bash tools/check-chat.command` — turn callbacks, cancellation state, and provider error streams.
- `bash tools/check-pip-library.command` — migration, full history, saved drafts, projects, search, and storage failures.
- `bash tools/check-connections.command` — app discovery, service status parsing, setup validation, and bounded commands.
- `bash tools/check-harness.command` — subprocess completion, diagnostic isolation, and cancellation.
- `bash tools/check-scenes.command` — starter scope, custom Scene persistence, request building, and recovery.
- `bash tools/check-x-connection.command` — PKCE, strict callbacks, token storage, API responses, and cancellation using fixtures.
- `bash tools/check-x-evidence.command` — bounded social evidence, source provenance, escaping, and excerpt labels.
