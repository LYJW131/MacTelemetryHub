# Mac Telemetry Hub

A private, extensible macOS status reporter. Charger telemetry is one optional
module alongside desktop activity, local Apple Music playback, and coding
usage, rather than the identity of the whole application.

## What the app includes

- independently switchable charger, foreground-app, Apple Music, Mac timezone, and CodexBar modules
- CoreBluetooth discovery or a pinned peripheral UUID for the charger module
- AES-GCM + ephemeral P-256 ECDH session handshake
- account-scoped 40-character Anker user ID stored in Keychain
- native dashboard and menu-bar controls
- disconnect and reconnect actions
- local HTTP server on all network interfaces
- the existing minimal `/status` shape and separate `/debug/status`
- `/health`, `/ports`, `/metrics`, `POST /disconnect`, and `POST /reconnect`
- a versioned telemetry envelope posted to one shared ingest endpoint
- direct local Music.app state via Apple Events (separate from Apple Music Web API)
- optional MusicKit library authorization and Apple Music token upload
- foreground application reporting, limited to the app's name, bundle ID, and icon
- CodexBar aggregation that never uploads session IDs, project paths, prompts, or replies
- subscription plan tier and server-side rate-limit windows for Claude Code and Codex
- login launch using `SMAppService.mainApp`

Each module can be disabled without stopping the others. Disabling the charger
module also stops its BLE session. The Anker user ID is deliberately not
compiled into the app and is only required while the charger module is enabled.

## Unified ingest protocol

Point the app at `https://<site>/api/ingest/telemetry` and set the same Bearer
secret as the site's `TELEMETRY_INGEST_SECRET`. Every request uses a versioned
envelope and may contain only the modules that have fresh data:

```json
{
  "version": 3,
  "modules": {
    "desktop": {
      "application_name": "Safari",
      "bundle_identifier": "com.apple.Safari",
      "icon_hash": "<sha256>",
      "icon_data": "<base64, only when missing remotely>"
    },
    "apple_music": {},
    "timezone": {},
    "charger": {},
    "vibe_coding": {}
  }
}
```

Version 3 is the only accepted contract; desktop icons are addressed by SHA-256,
with PNG bytes included only when that hash is not already stored by the receiver.
There is no legacy payload fallback.
The POST body is deliberately bounded. The app discards CodexBar's project-level
details after parsing and uploads only display-ready totals, seven daily points,
30-day token totals, and 60 daily activity buckets. Token inspection stays in
CodexBar's own GUI; Mac Telemetry Hub only shows the collector's health. That
module is sent again only after CodexBar refreshes, while the smaller live
modules are also sent only when their display content changes. Presence uses its
own endpoint every 30 seconds so the site can detect an offline reporter without
receiving duplicate charger, desktop, music, or CodexBar snapshots.

## Plan tier and rate-limit windows

All coding data comes through the CodexBar CLI, with no Node/ccusage process,
direct Claude credential read, or Codex app-server fallback:

- `cost --provider both --provider-native-only --days 365 --format json --refresh`
  reads Claude and Codex local logs in one process and supplies token/cost history.
- `usage --provider both --source web --no-credits --format json` reads both
  providers' plan tiers and server-side quota windows in one process.

The app keeps the existing `vibe_coding` payload shape by merging those two
results into each agent's `plan` object and `limits` array. Window counts and
durations are taken from CodexBar's response rather than assumed.

`position_ms` in the music module is an anchor, not a stream. Paired with
`observed_at` and `state` it lets the site interpolate the playhead on its own,
so the module is re-sent only on a track change, a play/pause transition, or a
seek — detected as the playhead drifting more than 2.5 s from what the site
would be showing. A track played straight through uploads once, not once per
post interval.

Play/pause transitions, track changes, and foreground-application switches skip
the throttle window entirely: they wake the reporter loop the moment they happen
and upload at once, then reset the window so the next scheduled post is a full
interval away. Everything else — seeks, charger readings, CodexBar — waits for
that window, and rides along in whichever envelope goes out first. While a post
is failing, the urgent path is suspended until the backoff expires.

Foreground activity is event-driven: the snapshot is rewritten by the
`NSWorkspace` activation notification, using the `NSRunningApplication` the
notification carries rather than re-reading `frontmostApplication`, which can
still hold the previous app when the notification arrives.

Playback is event-driven too. Music.app posts `com.apple.Music.playerInfo` on
`DistributedNotificationCenter` for every track change and play/pause, carrying
the player state, track identity, and total time — but neither the playhead nor
the artwork. The notification is therefore used only as a trigger: each one runs
a single AppleScript read for the two fields it omits. Music.app fires several
notifications per change, so refreshes coalesce rather than queue up. Scrubbing
the playhead posts nothing at all, which is the one transition left to a 25
second fallback poll; every other change arrives as an event.

Both monitors wake the reporter loop directly rather than waiting to be sampled.
An activation reschedules a 400 ms settle timer, so a burst of Cmd-Tab switches
uploads only the application it lands on — the ones passed through never outlive
the window. Playback needs no such timer; the confirmation read already absorbs
the race. The loop's own five-second tick is left to the parts with no event
source of their own: the 30 second heartbeat and the CodexBar interval check.

The charger wakes it too, but selectively. Its stream arrives at ~1 Hz (below),
and waking on every frame would turn a five-second loop into a one-second one
to watch numbers that were always going to wait for the throttle window. So the
callback compares a structural fingerprint first — ports, cables, device
identity — and only a plug, unplug, or device swap gets through. Those then take
the same urgent path as a track change, so they upload about a second after they
happen instead of up to five seconds later.

The charger is event-driven at the acquisition layer as well. Nothing is polled
over BLE: the handshake — specifically `0x0022`/`0x0027` — arms an unprompted
`0x0300` stream that the charger then pushes at ~1 Hz, and after that the app
transmits nothing. Measured on firmware `v0.0.5.1`, disabling the former 12 s
status and 6 s realtime polls left the rate unchanged at 1.00 frames/s with a
1.24 s worst-case gap, and a 72 second capture recorded 9 transmitted frames,
all of them handshake steps, against 72 received pushes.

Dropping the polls also drops the only thing that used to fail loudly when the
charger stopped answering — a BLE link can stay connected while the stream is
dead, leaving the dashboard and the uploader on a frozen snapshot.
`startStreamWatchdog` covers that without reintroducing periodic traffic: under
10 s of silence it does nothing; past that it re-sends the arming pair once per
quiet period; past 20 s it drops the peripheral so the normal reconnect path
builds a fresh session. The observed worst-case gap is ~1.2 s, so the threshold
sits far outside normal jitter, and the timer is local — it puts nothing on the
air unless the stream has already gone quiet.

One consequence worth knowing: `raw_status` is no longer refreshed on a timer.
It holds whatever the last `0x0200` reply carried, normally the one the
handshake requested, so it carries its own `raw_status_updated_at` in
`/debug/status`. Port telemetry stays ~1 Hz fresh; the two ages are not
interchangeable.

Measured end to end, from the event to the site serving the new state: play and
pause land in 320–490 ms, application switches in 560–620 ms.

The app also exposes local debugging snapshots at `GET /activity` and
`GET /telemetry`; the original charger `GET /status` remains compatible.

## Module permissions

- Foreground app names and icons use `NSWorkspace` and need no special
  permission. Window contents and titles are never read, so the app needs no
  Accessibility permission at all.
- Apple Music asks once for permission to communicate with Music.app. The
  separate “授权并上报 Apple Music token” action asks for MusicKit library
  permission, obtains a Music User Token and a MusicKit-generated developer
  token, and sends them only to the dedicated credentials endpoint described
  below.
- Coding usage requires CodexBar and its App-bundled CLI. Use
  `/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI`; the app resolves a
  Homebrew symlink to this real path when settings are saved so the CLI can use
  CodexBar GUI's Keychain cookie cache. The minimum local-cost refresh interval
  is 60 seconds.

## Open and run in Xcode

1. Open `MacTelemetryHub.xcodeproj`.
2. Select the `MacTelemetryHub` target, then **Signing & Capabilities**.
3. Select your Apple Developer team and keep **Automatically manage signing**
   enabled.
4. Run on **My Mac** and approve the Bluetooth prompt once.
5. Open Settings in the app, enter the Anker user ID, then press **扫描充电头**
   and pick the charger from the list. Choosing one stores its CoreBluetooth
   UUID and saves.

Pairing is the only time the app scans. Once a UUID is stored, it only ever
issues a directed connect to that one charger — the request stays pending until
the charger powers on, so there is no scanning, no timeout, and no retry loop.
**重新配对** clears the UUID and brings the scan button back.

The current charger's CoreBluetooth identifier is
`102DC514-2EB9-DAC9-C11A-4A0781776A73`.

## Apple Music credentials upload

The app keeps the existing playback snapshot separate from MusicKit. In the
Apple Music section of Settings, click **授权并上报 Apple Music token**. After
the user approves the macOS media-library prompt, MusicKit obtains both tokens
and the app sends:

```http
POST /api/ingest/apple-music/credentials
Authorization: Bearer <TELEMETRY_INGEST_SECRET>
Content-Type: application/json
```

```json
{
  "version": 1,
  "device_id": "<telemetry device id>",
  "music_user_token": "<Music User Token>",
  "developer_token": "<developer token>"
}
```

The endpoint is derived from the configured telemetry URL, so
`/api/ingest/telemetry` becomes `/api/ingest/apple-music/credentials`. The
backend should treat both token fields as secrets, avoid logging them, and
return a 2xx response only after accepting the payload. The local
`GET /apple-music/authorization` endpoint exposes status only and never returns
token values.

Production builds require HTTPS for this credentials request. Debug builds
also allow plain HTTP when the derived endpoint is hosted on localhost,
127.0.0.1, or ::1, so a local backend can be tested without setting up a
certificate. HTTP is still rejected for LAN and public hosts.

For automatic developer-token generation, enable **MusicKit** in the App ID's
App Services in Certificates, Identifiers & Profiles, use the explicit Bundle
ID `com.liangyangjunwei.MacTelemetryHub`, and run a team-signed build. The
client never contains your MusicKit private key.

## Build a local app bundle

```bash
chmod +x build-release.sh
./build-release.sh
open "build/Mac Telemetry Hub.app"
```

This script makes a local ad-hoc signature. For login launch and a stable TCC
Bluetooth grant, move the app to `/Applications` and use an Apple Development
or Developer ID signature from Xcode.

## Login launch

After installing the signed app in `/Applications`, enable **登录后自动启动** in
Settings. This uses the supported macOS `SMAppService` API and starts after the
user logs in; it is not a root LaunchDaemon.

Closing the dashboard window does not stop the service. Use the menu-bar status
icon to reopen the window, disconnect, reconnect, or quit.

## HTTP API

The default port is `8787` and the listener accepts connections on all local
interfaces, including the Mac's Tailscale address. If the port is temporarily
occupied, the app retries every three seconds.

`GET /status` always returns a fixed machine-readable shape. Nullable fields
are present as JSON `null` rather than being omitted. Numeric voltage, current,
and power values are rounded to two decimal places; `updated_at` is the Unix
timestamp of the last decoded charger data.

## Tests

The protocol core is also a Swift package so it can be tested without opening
Xcode:

```bash
swift test
```

Tests cover the Python-compatible AES-GCM frame vector, fragmented FF09 frame
assembly, user-ID injection, live port/cable/device parsing, and the fixed
minimal JSON response.
