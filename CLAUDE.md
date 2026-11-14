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

Roles so far: `generalist` (Pip, desk), `coder` (Nova, IDE), `writer` (Ember, studio), `coach` (Rally, training room).

## Working here

- Build with `Run Spryts.command`; it writes `build.log`. Don't build inside this folder by hand: it is synced by iCloud.
- Never write API keys or message text to logs. `.env` stays out of git.
- This folder is the working copy. The GitHub repo (`bschippers718/Spryts`) is updated from it.
