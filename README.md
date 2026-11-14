# Spryts

Small animated characters that live on your Mac's screen. Each one is the face of a chat with Claude or Grok.

## Run it

Double-click **Run Spryts.command**. It builds the app and starts it. Quit from the ✦ icon in the menu bar.

- Hover on a character for a moment to open its chat. Click the character to pin the chat open.
- Drag a character to pick it up and drop it somewhere else.
- Characters walk along the tops of your windows and the bottom of the screen.

## Keys

Keys live in `.env` in this folder:

```
ANTHROPIC_API_KEY=...
XAI_API_KEY=...
MESHY_API_KEY=...
```

Without a chat key a character runs in demo mode and acts out a reply.

## Characters

Each file in `Characters/` is one character: its persona, its look, and the numbers that shape how it moves
(`speed`, `stride`, `bounce`, `armSwing`, `lean`, `tempo`, `fidget`, `jumpiness`, `sway`). Edit a file and run again.

## Generated characters

Double-click **Make Character.command** to build Mochi with Meshy from the prompt in `Characters/mochi.json`.
It saves one animated file per clip into `Characters/models/mochi/`. Mochi appears once those files exist.

## Layout

- `Sources/Spryts/AppDelegate.swift` — the transparent stage, hover and drag
- `Sources/Spryts/World.swift` — finds window edges to stand on
- `Sources/Spryts/Character.swift` — behaviour and the pose for each frame
- `Sources/Spryts/Bodies.swift` — the built-in body and the loader for generated models
- `Sources/Spryts/ChatService.swift` — Claude and Grok, normalised into one event stream
- `Sources/Spryts/ChatPanel.swift` — the chat bubble

## Command center

Pip runs on your installed Claude Code (set by `"harness": "claude-code"` in `Characters/pip.json`), so he can act on this Mac:
open and switch apps, script them, run Shortcuts, read files, and take a screenshot to see the screen.

- **Control-Option-Space** summons Pip with the text field ready. Press it again to dismiss.
- The strip of icons shows open apps, most recently used first, then recently quit ones. Click to switch; right-click for more.
- Drop files on Pip or on the panel to attach them.
- Risky actions wait for you: Allow once, Allow for this task, or Deny. Destructive or outbound actions always ask.
- The stop button, or picking Pip up, stops the run.

The agent works from `~/Library/Application Support/Spryts/workspace`, and can read Desktop, Documents and Downloads without asking.


## Adding a character role

Every character is its own specialist with its own popup, window and habits. The checklist for a new role is in `CLAUDE.md`.
