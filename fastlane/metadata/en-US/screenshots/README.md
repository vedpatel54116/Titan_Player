# How to add App Store screenshots

App Store Connect expects up to ten 1280×800 PNG/JPG captures showing the
app in action. Suggested lineup (in this order):

1. **Library** — a multi-window library view with at least one folder tree expanded
2. **Player** — main window showing the 4K HDR chrome and OSD
3. **Mini Player** — the floating mini-player window at its default size
4. **AirPlay** — the AirPlay device picker open over the player
5. **Spatial Audio** — spatial-audio routing panel
6. **Subtitles** — sidecar WebVTT subtitles in two languages

To capture, use **Cmd-Shift-4 / Cmd-Shift-5** in macOS and resize the captured
PNGs to 1280×800. Drop them in this directory as `01.png`, `02.png`, …, and
re-run `fastlane deliver` (or `fastlane mas`) to push them to App Store Connect.

Until the captures are dropped in, `fastlane metadata_only` will warn that the
screenshot slots are empty; that does NOT block textual-metadata validation.
