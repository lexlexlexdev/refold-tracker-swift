# Tinycast controls for Refold Tracker

This small Raycast-compatible Tinycast extension sends `refoldtracker://toggle` to the
standalone app. It pauses a running session or resumes a paused one. The native app remains
the only owner of timer state, persistence, and Refold sync.

The standalone app registers the `refoldtracker` URL scheme. Open **Tinycast → Settings →
Extensions → Add from folder** and select this folder, or install it into Tinycast's
extension folder. Search for **Toggle Refold Tracking**.
Assign global shortcuts in Tinycast if desired.

After the first installation or an app update, relaunch Refold Tracker to register its
URL handlers. Finish and save any active session before relaunching.

Tinycast reports that the request was sent; the standalone app owns the current session
state. If no session is active, it opens the tracker with a message. Stop & Save remains
in the standalone app.
