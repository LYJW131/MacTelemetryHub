# Mac Telemetry Hub

A private, extensible macOS status reporter. Charger telemetry is one optional
module alongside desktop activity, local Apple Music playback, and coding
usage, rather than the identity of the whole application.

## What the app includes

- independently switchable charger, foreground-app, Apple Music, Mac timezone, and coding-usage modules
- CoreBluetooth discovery or a pinned peripheral UUID for the charger module
- AES-GCM + ephemeral P-256 ECDH session handshake
- account-scoped 40-character Anker user ID stored in Keychain
- native dashboard and menu-bar controls
- disconnect and reconnect actions
- optional local HTTP listener with `/health` and per-device SSE
- a versioned telemetry envelope posted to one shared ingest endpoint
- direct local Music.app state via Apple Events (separate from Apple Music Web API)
- optional MusicKit library authorization and Apple Music token upload
- foreground application reporting, limited to the app's name, bundle ID, and icon,
  with an exact Bundle ID blacklist for remote reporting
- coding-usage aggregation that never uploads session IDs, project paths, prompts, or replies
- charger cover name plus the original JPEG uploaded to R2 (no resize or transcode; the point is to leave Anker's signed URL)
- subscription plan tier and server-side rate-limit windows for every coding agent in the envelope
- login launch using `SMAppService.mainApp`

Each module can be disabled without stopping the others. Disabling the charger
module also stops its BLE session. The Anker user ID is deliberately not
compiled into the app and is only required while the charger module is enabled.

## Unified ingest protocol

Point the app at `https://<site>/api/ingest/mac` and set the same Bearer
secret as the site's `TELEMETRY_INGEST_SECRET`. Every request uses a versioned
envelope and may contain only the modules that have fresh data:

```json
{
  "version": 4,
  "heartbeatAt": 1760000000000,
  "presence": "online",
  "activeModules": ["desktop", "appleMusic", "timezone", "charger", "vibeCoding"],
  "modules": {
    "desktop": {
      "applicationName": "Safari",
      "bundleIdentifier": "com.apple.Safari",
      "iconHash": "<sha256>",
      "iconObjectKey": "<sha256>.webp"
    },
    "appleMusic": {},
    "timezone": {},
    "chargingDevices": {},
    "vibeCodingUsage": {},
    "vibeCodingNow": {},
    "vibeCodingYear": {}
  }
}
```

`activeModules` lists the **toggles** the user has switched on, not the module
keys above: vibe coding is one toggle (`vibeCoding`) that feeds three modules.

Version 4 is the only accepted contract; desktop icons are addressed by SHA-256.
The Mac renders each icon at 96 px, encodes it once as WebP, signs an S3-compatible
PUT, uploads `<sha256>.webp` directly to R2, and sends only `iconObjectKey`.
The R2 access key and secret are stored in macOS Keychain. There is no base64 fallback;
the server never receives image bytes.

An envelope with no `modules` (or an empty one) is a pure heartbeat: it refreshes
liveness without touching any module's timestamp. One is sent every 30 s while
nothing changes, and never alongside a data post — that post already proves the
reporter is alive. `presence: "offline"` covers graceful exits (quit, sleep) and is
sent synchronously so it beats the disconnect; crashes, network loss, and forced
shutdowns still rely on the site's "nothing received for a while" timeout. Both
paths are needed; neither replaces the other.
The POST body is deliberately bounded. The app discards TokenTracker's
project-level details after parsing and uploads only display-ready totals
and today's numbers. Token inspection stays in TokenTracker's own panel;
Mac Telemetry Hub only shows the collectors' health.

Vibe coding is split into three modules by **how often it changes**, not by which
endpoint produced it:

| Module | Interval | Contents |
| --- | --- | --- |
| `vibeCodingNow` | 60 s | whether each agent is in use right now, its current model, last activity time |
| `vibeCodingUsage` | 10 min | tokens, cost, plan tiers, and rate-limit windows for every agent, plus lifetime session count |
| `vibeCodingYear` | 1 h (configurable) | last 53 weeks of daily totals plus a compact per-day top-5 model mix, sent as one calendar |

There were three modules before (usage / limits / sessions), one per collector —
a line drawn by *which command produced the data*, back when limits and usage
came from two separate CodexBar invocations and the slow one could take the
freshly fetched limits down with it. All three now come from the same local
service on the same two schedules, so only the real line is left: "right now"
versus "cumulative", and the collectors were merged to match — two modules, two
collectors, two refresh intervals.

Merging the two halves into one collector does not make them share a fate.
Limits failing does not hold up usage: the bars keep their last good values and
carry a `limitsError` so the site can tell "not configured" from "configured but
unreachable". Usage failing drops the whole round instead — limits are attached
to `agents[]` by id, and without the trunk there is nothing to attach them to.
The session count is spliced in at send time (`VibeCodingUsagePayload`), since
it is counted by the other collector.

Every module is sent only when its own display content changes.

## Plan tier and rate-limit windows

Token、费用、限额和会话都来自本机跑着的 TokenTracker 面板，走它 SPA 用的那套
`/functions/<名字>` 接口。不上传 session ID、项目路径、提示词或回复：

- `tokentracker-usage-daily` 给出哪几天有数据，再对每个有数据的日子问一次
  `tokentracker-usage-model-breakdown`，合成 token/费用历史与模型排行。
  同一条按日接口另外喂给 `vibeCodingYear`：过去 53 周的日合计一次发完；有量的日
  子再问一次按模型拆分，编成模型表 + 每天前五的稀疏 mix。间隔单独控（默认一小
  时），不跟用量那 10 分钟绑在一起。
- `tokentracker-usage-limits` 一次带回所有来源的套餐档位和服务端限额窗口。
  信封里五个来源（见 `TelemetryModules.swift` 的 `vibeCodingAgents`：`claude`、
  `codex`、`cursor`、`grok`、`antigravity`）走同一套 agent 形状：token、今日用量、
  套餐、全部限额窗口、展示名和图标都在行内。站点按 id 决定展示形态，不要再拆
  `quotaProviders`。
- `tokentracker-sessions` 给出轻量的在用状态：只留模型名、最后活动时刻和条数。
  前两样走 `vibeCodingNow`（60 秒一轮，五个来源都发）；条数是「一共开过多少次」，
  属于累计量，搭 `vibeCodingUsage` 那份车走。

从前这四份是 CodexBar CLI 两条命令加 ccusage 两条、一共四次进程，光那条
`cost --refresh` 就要十几秒；现在是同一个本机 HTTP 服务的几个 GET。代价是它
得开着 —— 面板没跑的时候三份各自留下自己的错误，互不牵连。

窗口的个数和长度取自上游的回答，不作假设，也不按展示形态裁一条「总额」。
会话状态每 60 秒刷一次；用量和限额每 10 分钟刷一次。

`position_ms` in the music module is an anchor, not a stream. Paired with
`observed_at` and `state` it lets the site interpolate the playhead on its own,
so the module is re-sent only on a track change, a play/pause transition, or a
seek — detected as the playhead drifting more than 2.5 s from what the site
would be showing. A track played straight through uploads once, not once per
post interval.

Play/pause transitions, track changes, and foreground-application switches skip
the throttle window entirely: they wake the reporter loop the moment they happen
and upload at once, then reset the window so the next scheduled post is a full
interval away. Everything else — seeks, charger readings, coding usage — waits for
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
source of their own: the 30 second heartbeat and the coding-usage interval check.

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
the dashboard snapshot. Port telemetry stays ~1 Hz fresh; the two ages are not
interchangeable.

Measured end to end, from the event to the site serving the new state: play and
pause land in 320–490 ms, application switches in 560–620 ms.

## Module permissions

- Foreground app names and icons use `NSWorkspace` and need no special
  permission. With explicit Accessibility permission, the app also reads the
  focused window title for local menu-bar and dashboard display only. Title
  detection uses an exact Bundle ID whitelist that defaults to empty. Apps
  outside the whitelist never have their accessibility window or title read,
  and switching to one detaches the previous observer and clears the local
  title. Window titles are excluded from `DesktopActivitySnapshot`, local JSON
  APIs, debug snapshots, and remote telemetry; window contents are never read.
  Bundle IDs in the remote-reporting blacklist remain visible in the local UI
  and local APIs, but their application identity and icon are not uploaded.
  Entering a blacklisted app reports the dedicated virtual application
  `com.liangyangjunwei.MacTelemetryHub.hidden` with the fixed name
  `Hidden Application`; the site maps that identity to its hidden label and
  icon. The real application name, Bundle ID, and icon never enter the payload.
- Apple Music asks once for permission to communicate with Music.app. The
  separate “授权并上报 Apple Music token” action asks for MusicKit library
  permission, obtains a Music User Token and a MusicKit-generated developer
  token, and sends them only to the dedicated credentials endpoint described
  below.
- Coding usage requires the TokenTracker app running its local panel. Point the
  设置 at its root address — `http://127.0.0.1:7680` by default — and the three
  collectors read from there. The minimum local-cost refresh interval is 60
  seconds.

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
and the app sends them through the unified ingest endpoint, as an
`appleMusicCredentials` module of the v4 envelope:

```json
{
  "appleMusicCredentials": {
    "musicUserToken": "<Music User Token>",
    "developerToken": "<developer token>",
    "expiresAt": 1760000000
  }
}
```

There is no separate credentials endpoint — the button only wakes the reporter
loop, and the two tokens are compared independently, so a rotation uploads just
the field that changed. The backend should treat both token fields as secrets,
avoid logging them, and return a 2xx response only after accepting the payload.
The local
`GET /apple-music/authorization` endpoint exposes status only and never returns
token values.

The ingest URL is only validated as http-or-https with a host; nothing in the app
forces TLS. Since that one envelope carries both tokens and the Bearer secret,
use HTTPS for anything but a local backend.

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

## Local HTTP

The default bind is `127.0.0.1:8787` (loopback only). Set the bind address to
`0.0.0.0`, `::`, or a specific interface IP to listen more widely. If the port
is temporarily occupied, the app retries every three seconds.

- `GET /health` — process liveness, plus each charging link's enabled / connected / phase
- `GET /sse/charger` and `GET /sse/powerbank` — Server-Sent Events. The first
  event is the current snapshot; later events follow the device's BLE push
  (about 1 Hz). There is no local poll timer. Each event is a JSON object with
  `phase`, `connected`, `lastError`, and `device` (the same charging-device
  payload used for remote ingest, or `null` before the first telemetry frame).

## Tests

The protocol core is also a Swift package so it can be tested without opening
Xcode:

```bash
swift test
```

Tests cover the Python-compatible AES-GCM frame vector, fragmented FF09 frame
assembly, user-ID injection, live port/cable/device parsing, and the fixed
minimal JSON response.
