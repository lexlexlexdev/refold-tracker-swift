# Reliability and integration

SwiftUI menu-bar app. macOS 13+, Xcode / Swift toolchain. No external dependencies.

## Build and open

```sh
zsh scripts/build-app.sh
open "dist/Refold Tracker.app"
```

Click the stopwatch in the menu bar, or press Control–Option–R. Use **Sign in / open Refold**
to sign in within the app. Its persistent WebKit session is separate from Chrome.
Google/Firebase popup windows are hosted in separate native windows using WebKit's
supplied configuration, preserving the opener and authentication session. The site
can close them after login; JavaScript alerts and confirmations are supported.
Start one of the three Korean actions, then **Stop & Save**. The app does not expose
countdown, manual entry, daily tasks, reports or decks. The login/fallback window shows
the real Refold site; it is not a restricted kiosk.

## Data and recovery

- SQLite: `~/Library/Application Support/RefoldTracker/tracker.sqlite`, WAL, synchronous FULL.
- Start and stop are committed before changing the UI or sending a mutation.
- The display uses monotonic elapsed time. Active duration checkpoints every five seconds.
- Sleep ends the session locally; wake attempts synchronization. No automatic restart.
- Normal quit ends the session locally; the next launch attempts synchronization.
- After an abnormal exit, the last checkpoint becomes an entry requiring duration review.
  Unobserved time is not counted. Checkpoints can lose up to about five seconds while the
  event loop is responsive; a blocked process may have an older checkpoint.
- Offline pending entries stay local. An uncertain POST is **not retried automatically**.
  Refresh reconciles a unique matching new server entry against the pre-request history.
  An ambiguous result must be checked on the website; the app does not guarantee server-side
  exactly-once semantics.
- Duration edits are journaled before sending. External changes detected on refresh are
  not overwritten. There is still a race without server-side conditional updates.
- A storage error blocks further tracking and requests; existing files are never reset.

## Integration status

Research confirmed the website's local stopwatch state, recent-history serialization and
client calls to `saveAction` / `editUserAction`. This prototype discovers Next.js Server
Action IDs from the current dashboard scripts and invokes them in the authenticated WebKit
context. It does not hard-code build hashes, export Chrome cookies or collect passwords.

**Google popup login, history loading, stopwatch saving and duration editing have been
verified manually against Refold. Deletion has not yet been verified against the account.**
This is an internal, undocumented integration, not a supported Refold API. Site changes may
break reads or writes; local tracking remains independent. Firebase provider login may be
restricted by Google inside WebKit even with popup support. A Google `disallowed_useragent`
error would require a separate supported authentication design; opening the URL in Chrome
alone does not transfer the session back to WebKit. Full history pagination, automatic login-item setup, signed distribution,
and end-to-end reliability testing are not included in this prototype.

Fixed mappings: Anki → 60202 (Vocab Study); Podcast / video listening → 30104
(Freeflow Listening); 문법 / 읽기 / 쓰기 / 발음 → 20101 (Interactive Reading). Language `ko`.
Date and start time are formatted in `Asia/Seoul`, matching the inspected account.
Refold is responsible for grouping the saved entry using its configured day boundary.

The app reads recent history and offers duration-only editing for these exact mappings.
Other record fields are preserved. Confirmed local and server deletion is available in
the edit window. Server deletions are journaled and are not blindly retried after a crash
or uncertain response. Absence from recent history alone is not proof of deletion.
There is no blind resend button,
or automatic mutation merely from opening the app without pending user-created work.
