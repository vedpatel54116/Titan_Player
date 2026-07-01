# TitanPlayer Privacy Policy

_Last updated: 2026-06-30_

TitanPlayer is an open-source macOS video player. This page describes what
data the application handles, why, and where it goes.

## Data TitanPlayer Handles

| Data | Where it lives | Why |
|---|---|---|
| Media files you open (videos, audio, sidecar subtitle/cue files) | Local on your Mac | Playback. Never transmitted off-device unless you explicitly use a network-streaming feature. |
| Recent-played file list | Local on your Mac (`~/Library/Application Support/TitanPlayer/Recent.plist`) | Resume your library across launches. |
| Window positions, mini-player size | Local on your Mac (`~/Library/Preferences/com.titanplayer.app.plist`) | Restore your layout. |
| Crash logs (only if you enable them) | Local on your Mac | Optional debugging; off by default. |
| Crash reports you choose to send | Off-device only if you submit them yourself | You control submission; TitanPlayer has no auto-upload. |

## Network Uses

TitanPlayer can connect to the network **only when you enable a streaming
source yourself** — for example an HTTP Live Stream (HLS) URL, a remote
subtitle provider, or an SMB/NFS share. TitanPlayer does not perform
background telemetry, beaconing, or analytics of any kind.

When the App Sandbox is enabled (Mac App Store build):

- Outgoing TCP/UDP (e.g. streaming) is allowed for `com.apple.security.network.client`.
- Incoming TCP/UDP (e.g. the local-network AirPlay receiver that ships in
  certain configurations) is allowed for `com.apple.security.network.server`.
- Local network mDNS/Bonjour discovery is permitted by `NSAllowsLocalNetworking = YES`.

## Microphone

The microphone is read **only** when you explicitly enable audio capture /
voice-over features. Audio is processed locally; TitanPlayer does not record,
store, or transmit microphone audio.

## Apple Events

TitanPlayer may send Apple Events to hand media off to QuickTime or other
players, and to receive Remote control events. These never leave your Mac.

## Movies Asset Library

The Mac App Store build is granted `com.apple.security.assets.movies.read-write`
so it can read media from your Movies folder in addition to files you have
opened explicitly. TitanPlayer does not modify files in that location
without an explicit user action (e.g. "Export Frame" or "Save Subtitles").

## Open-Source Code

TitanPlayer's source is available under the MIT License. Auditing the
network code is encouraged; the relevant paths are:

- `TitanPlayer/TitanPlayer/Streaming/`
- `TitanPlayer/TitanPlayer/Networking/`

## Children's Privacy

TitanPlayer does not target children and does not knowingly collect any
personal data from any user.

## Changes to This Policy

Material changes are documented in the git log of this file. Open-source
contributors are encouraged to PR improvements.

## Contact

Privacy questions: open an issue at the project repository.
