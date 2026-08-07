# Mac Telemetry Hub

A private, extensible macOS status reporter. Charger telemetry is one optional
module alongside desktop activity, local Apple Music playback, and coding
usage, rather than the identity of the whole application.

## What the app includes

- independently switchable charger, foreground-app, Apple Music, and ccusage modules
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
- foreground application reporting, limited to the app's name, bundle ID, and icon
- ccusage aggregation that never uploads session IDs, project paths, prompts, or replies
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
  "version": 2,
  "modules": {
    "desktop": {},
    "apple_music": {},
    "charger": {},
    "vibe_coding": {}
  }
}
```

Version 2 is the only accepted contract; there is no legacy payload fallback.
The POST body is deliberately bounded. ccusage's complete reports stay on the
Mac for the native dashboard; the app uploads only display-ready totals, seven
daily points, 30-day token totals, and 60 twelve-hour activity buckets. That
module is sent again only after ccusage refreshes, while the smaller live
modules are also sent only when their display content changes. A heartbeat-only
envelope is sent every 30 seconds so the site can detect an offline reporter
without receiving duplicate charger, desktop, music, or ccusage snapshots.

## Plan tier and rate-limit windows

ccusage counts tokens found in local JSONL files; it knows nothing about the
subscription behind them. Plan tier and remaining quota are server-side facts,
so they are collected separately and merged into the `vibe_coding` module as a
`plan` object and a `limits` array on each agent.

- Codex: `codex app-server` over stdio JSON-RPC, `account/rateLimits/read`. The
  reply is read from `rateLimitsByLimitId`, so per-model buckets (for example
  the Spark bucket) appear alongside the main one. Each bucket reports its
  window length in minutes.
- Claude Code: the plan tier comes from `oauthAccount.organizationRateLimitTier`
  in `~/.claude.json`. Window usage comes from `GET /api/oauth/usage` on
  `api.anthropic.com`, authenticated with the OAuth token that Claude Code
  already stores in the login keychain under `Claude Code-credentials`. The
  token is read, never written, and never refreshed — rotating it would knock
  the user's own Claude Code session offline. It is not logged and does not
  leave the Mac.

**This endpoint is not public API.** It is what Claude Code's own `/usage`
panel calls, and Anthropic can change or withdraw it without notice. When it
fails, the plan tier still renders and the limits section simply disappears.

The two sources disagree about what they can describe, and the payload keeps
both rather than inventing the missing half: Codex reports a window length but
no grouping, Claude reports a grouping (`session`, `weekly`) but no length.
Consumers render whichever is present. Window counts and durations are never
assumed — OpenAI dropped the five-hour window from some plans and may restore
it, so `limits` is a plain array with no fixed slots.

`position_ms` in the music module is an anchor, not a stream. Paired with
`observed_at` and `state` it lets the site interpolate the playhead on its own,
so the module is re-sent only on a track change, a play/pause transition, or a
seek — detected as the playhead drifting more than 2.5 s from what the site
would be showing. A track played straight through uploads once, not once per
post interval.

Play/pause transitions, track changes, and foreground-application switches skip
the throttle window entirely: they wake the reporter loop the moment they happen
and upload at once, then reset the window so the next scheduled post is a full
interval away. Everything else — seeks, charger readings, ccusage — waits for
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
source of their own: the 30 second heartbeat and the ccusage interval check.

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
- Apple Music asks once for permission to communicate with Music.app.
- ccusage requires paths to the local Node executable and
  `node_modules/ccusage/src/cli.js`; its minimum refresh interval is 60 seconds.
- Codex limits require the path to the `codex` executable. Leaving it blank
  skips that half; the Claude side is unaffected.
- Claude limits ask for access to the `Claude Code-credentials` keychain item.
  Choose **Always Allow**; **Allow** grants a single read and macOS re-prompts
  on every refresh. Declining leaves the plan tier — which is read from a plain
  file — and drops only the usage windows.

## Open and run in Xcode

1. Open `MacTelemetryHub.xcodeproj`.
2. Select the `MacTelemetryHub` target, then **Signing & Capabilities**.
3. Select your Apple Developer team and keep **Automatically manage signing**
   enabled.
4. Run on **My Mac** and approve the Bluetooth prompt once.
5. Open Settings in the app, enter the Anker user ID and optional CoreBluetooth
   device UUID, then choose **保存并重连**.

The current charger's CoreBluetooth identifier is
`102DC514-2EB9-DAC9-C11A-4A0781776A73`. Leaving it blank enables scanning for an
`ASHDJW*` device instead.

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
