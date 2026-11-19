# Spryts: rules for anyone changing this code

## Every character is its own specialist

A Spryt only works if it is excellent at one job and looks, moves and behaves like nobody else on the screen.
**A new role is not finished when its persona and prompt are written.** It is finished when every item below is
its own. Nothing may fall back to another character's popup, window or habits; the code is written so that a
role with a missing piece shows nothing there, never Pip's version.

When you add a role (the `role` field in `Characters/<id>.json`), build all of these:

| What | Where | Notes |
|---|---|---|
| Look | `Characters/<id>.json`, `Bodies.swift` | Silhouette, colours and at least one feature no other character has. |
| Brain | `Harness.swift` (`harnessPrompt`, allowed tools) | The expert method for the job, what it keeps on disk, its safety limits. |
| Popup strip | `ChatPanel.swift` (`roleStrip`) | The one-line status that matters for this job. Never the app strip: that is Pip's. |
| Popup quick actions | `ChatPanel.swift` (`quickActions`) | Three or four things this specialist is asked most. |
| Popup wording | `ChatPanel.swift` (`emptyHint`, `placeholder`) | In this character's terms. |
| Theme | `Expansions.swift` (`RoleTheme.of`) | Typeface, colour scheme, corner shape. |
| Expanded window | its own file (see `Coach.swift`), wired in `AppDelegate.openWorkspace`, `placeName`, `hasPlace` | Tools for the job, not a chat window with a new colour. |
| Idle behaviour | `Character.swift` | What it does with a spare moment (Nova types, Ember scribbles, Rally does drills). |
| Voice with others | `Character.swift` (`opener`, `answer`), `Games.swift` (lines, throwing style) | A few lines in its own voice. |

Only Pip (the generalist) has the apps, the desk and the Mac-control actions.

Roles so far: `generalist` (Pip, the chief of staff: `ChiefOfStaff.swift`, his office files and the Today desk),
`coder` (Nova, IDE: `Workspace.swift`, `Changes.swift`, `NovaTools.swift`), `writer` (Ember, studio), `coach` (Rally, training room),
`forecaster` (Drizzle, the real weather and nothing else: `Weather.swift`, `Forecast.swift`),
`gamer` (Joy, the arcade: `Joy.swift`, `Arcade.swift`, `ArcadeLevels.swift`).

## Home-made and shared Spryts

Anyone can make a Spryt in the maker (`SprytMaker.swift`, ✦ menu) and share it as a `.spryt` file.

- A `.spryt` file carries look, movement, name and personality text. It never carries a role, tools, an engine or a model.
- Every made or opened Spryt gets the `companion` role: conversation only. It runs with no tools and no folders
  (`--tools ""` on Claude Code, tools disallowed on Grok). Its personality text is wrapped in a fixed frame and treated
  as a description of voice, never as instructions. **Never give a companion tools, and never let a `.spryt` file set
  anything but the fields in `SprytCard`.** A shared file is untrusted input.
- New shape options, extras or movement dials go in `Look` / `MotionStyle`, then in the maker's form, so everyone can use them.
- Walk styles and moves live in `Moves.swift` as pure functions of time. The maker's preview and the stage both call
  them, so what a person sees while making is what they get. A new move is a catalogue entry plus a pose there;
  it must stay a pose (no files, no network, no tools) and fit the stage's budgets: `Moves.eagerness` is the only
  dial on how often moves happen, and it never brings them closer than a few minutes apart.
- Lines a Spryt says (`SprytVoice`) are short text for speech bubbles. They go through `SprytVoice.cleaned` and are
  never added to a prompt.
- The maker is native: system surfaces, grouped forms, the system accent. Four tabs and one stage; a new control
  goes in the tab it belongs to, not in a fifth place.

## The arcade

Joy's games (`Arcade.swift`) are a see-through layer over the screen whose level is built from the open windows
(`ArcadeLevels.swift`).

- **Breaking is pretend.** A game may measure window positions and draw over them. It must never move, resize, close,
  hide, focus or read a real window, and must not ask for screen recording or accessibility permission.
- Esc always leaves at once. Losing focus pauses. A game starts only when the person asks for one.
- Every level must be finishable on any desktop, including an empty one: `ArcadeLevels` is pure, and
  `tools/check-arcade.command` proves it on random desktops and plays both games with scripted keys. Run it after any change.
- Joy has no tools on either engine, like a companion. Games are started by the app's buttons, never by the model.
- A new game is an `ArcadeGame` case, a scene in `Arcade.swift`, a card in her arcade and a line in her prompt.

## Listening

`Listening.swift` turns the message being typed into body language: `Listening.read` (what the words feel like and
whether a move was asked for), `Ear` (typing rhythm), `Listening.cue` (the pose offsets and face) and
`Listening.response` (what happens on Return). `SprytCharacter` and the maker's preview both call it.

- It is pure and local. Never send a draft to an engine, a server or a log to decide a reaction.
- Only the Spryt being typed to reacts, and only while it is standing idle. Listening never interrupts work in progress.
- Bad news gets stillness and a nod, never a performance. A move is performed only when the sentence really asks for
  one; when in doubt, do nothing. Add the sentence to `tools/check_listening.swift` and run `tools/check-listening.command`.
- New reactions go in `Listening.cue` as bounded offsets, scaled by the character's `talkingEnergy`.

## Keep it calm

The screen belongs to the person's work. Every addition must leave it no busier than before.

- **Popup header:** name, a stop button while working, and the ⋯ menu. Nothing else. New actions go in the ⋯ menu
  or in the character's big window, never as another header icon.
- **Popup body:** one strip under the header, the conversation, then one row: shortcuts when idle, or the game offer
  on a long task, or an approval card. Never two of those at once. Progress is one live line; the full step list
  belongs in the big window.
- **One popup at a time,** and none while that character's big window is open.
- **✦ menu:** one line per character, the few everyday actions, then Settings. Anything set once and left alone goes
  in Settings.
- **The stage:** fidgets slow down as more characters are on stage, and only one character-to-character exchange
  happens at a time, minutes apart. A new behaviour must fit inside those budgets, not add to them.

## Look like Apple shipped it

Pip and Nova are fully native (`RoleTheme` with no `paper`); the others move over one at a time. The shared pieces live in `Design.swift`.

- Liquid Glass only for chrome that floats: popups, the desk, toolbars, controls. Content (messages, cards, code, lists) sits on solid system surfaces (`Surface`, `solidCard`).
- System fonts, SF Symbols and semantic colours, so light and dark mode both work. Never force a colour scheme on a native character.
- A character's identity is its accent colour and what it shows, not a repainted window. Code uses Xcode's colours (`CodePalette`).

## Per-character engines

Every character can run on Claude Code or Grok (the `grok` command-line agent). Nova also supports Codex.
Each character keeps its own engine and model; the ✦ menu changes only the default for new characters.
A character's identity must not depend on which engine is behind it. Companions must remain tool-free.

- Claude Code: `Harness.swift`. Approvals come through its `PermissionRequest` hook.
- Grok: `GrokHarness.swift`. Grok has no hook that waits on a permission prompt, so it runs with `--always-approve`
  and a `PreToolUse` gate (`~/.grok/hooks/spryts.json`) asks the person instead. The gate ignores Grok sessions
  Spryts didn't start. If the gate can't be installed, or tools run without it firing, runs fall back to read-only.
  Never weaken that fallback.
- Claude Code and Grok emit the same stream format, so one parser in `Harness.runOnce` serves both. Grok's tool names
  are mapped to the shared ones in `Harness.canonical`.
- Codex: `CodexAgent.swift`, through the installed local app server. It uses the shared visible approval UI, a user reviewer,
  and project-scoped sandboxing. Unknown server requests fail closed. Do not silently expand permissions or reuse another engine's session.
- A missing engine, failed run, interrupted run, or empty result must never become a successful team report.

## Durable work and editing

- `PipLibrary.swift` owns the chief's projects and conversations; `ChatSession` performs save-before-switch transactions.
  New Chat must preserve history and drafts. Project context is local to the active conversation. Never bypass a failed
  save to switch chats, start work, close, quit, or restart. Migrations keep the original file, and interrupted tasks
  must not automatically resume. Changes to project context invalidate the affected engine sessions.
- Pip's connections distinguish installed apps, configured services, and verified connection status. Service checks
  are explicit actions. Adding an HTTPS service writes only after Save, using structured process arguments; sign-in
  and tool permissions remain with the selected engine. Never log service endpoints, credentials, or raw CLI output.
- The X Feed (`PipSift.swift`, `PipSiftWeb.swift`, `PipSiftView.swift`; run `tools/check-sift.command` after changing any of them) is X's own site in a web view with Sift running in the page. The three
  files in `Sift/` are the Chrome extension, unchanged: update Sift by replacing them, never by editing them here or
  re-implementing a filter in Swift. They run in their own content world with only the storage shim in `SiftEngine`.
  The view stays on x.com; other links open in the person's browser. The app never calls X's API from here, never reads
  the password, and never posts, likes or follows. Posts leave the page only when the person presses Brief, at most 20,
  marked as untrusted content. Everything the page sends is checked in `SiftSettings.merge` before it is kept.
- `TeamCoordination.swift` owns persisted handoffs and results. Save before consuming inbox requests. Never automatically
  replay interrupted work or recursively delegate from a delegated task. Keep reports visible without inferring success.
- `WorkspaceModel` owns per-file in-memory drafts. File navigation and agent events must not discard dirty buffers.
  Save must detect disk conflicts; close and quit must ask about unsaved drafts. Do not claim crash recovery until drafts persist.

## Working here

- Build with `Run Spryts.command`; it writes `build.log`. Don't build inside this folder by hand: it is synced by iCloud.
- Never write API keys or message text to logs. `.env` stays out of git.
- This folder is the working copy. The GitHub repo (`bschippers718/Spryts`) is updated from it.
