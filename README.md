<div align="center">

# Refold Tracker

**Korean practice. One click. Right in your menu bar.**

Native macOS · SwiftUI · Offline-first

</div>

---

### Stay focused

- **Track** three fixed activities with a live menu-bar stopwatch.
- **Pause / resume** without counting breaks.
- **Toggle pause / resume from Tinycast** with the `Toggle Refold Tracking` command.
- **Cancel** an active session without saving—with confirmation.
- **Edit** duration or **delete** an entry—with confirmation.
- **Sync** to Refold using your own sign-in session, including Google popups.
- **Recover** local progress after a crash. Sleep ends tracking.

| Action | Activity |
| :--- | :--- |
| Anki | Vocab Study |
| Podcast / video listening | Freeflow Listening |
| 문법 / 읽기 / 쓰기 / 발음 | Interactive Reading |

Korean only. No countdown, manual entry, tasks or reports.

### Run

Requires **macOS 13+** and **Xcode 16+**. No third-party dependencies.

```sh
git clone https://github.com/lexlexlexdev/refold-tracker-swift.git
cd refold-tracker-swift
zsh scripts/build-app.sh
open "dist/Refold Tracker.app"
```

Click the stopwatch → **Sign in / open Refold** → start an activity.
**Control–Option–R** opens the tracker from anywhere.

### Before you rely on it

This is an **unofficial prototype**, not affiliated with Refold. It uses internal
website operations, not a supported public API. Site updates can break sync.
Unknown save results are never blindly retried; local data stays on your Mac.

[Reliability & integration](docs/RELIABILITY.md) · [Performance](docs/PERFORMANCE.md)
