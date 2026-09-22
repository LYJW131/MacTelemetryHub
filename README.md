# Mac Telemetry Hub

A personal, extensible macOS status reporter. Charger telemetry is one optional
module alongside desktop activity, local Apple Music playback, and coding
usage, rather than the identity of the whole application. The user interface is
Simplified Chinese; this README documents the protocol and behaviour in English.

## Where the data goes

Nothing leaves the Mac until you configure a destination. Every network path
below is off by default.

| Data | Destination | Default |
| --- | --- | --- |
| The telemetry envelope: charger readings, frontmost app name and icon, window titles cleared for publishing, Music.app state, coding usage | The `POST` URL you enter under 设置 › 上报. The author's own backend is not published; the ingest protocol below is the whole contract and is enough to build one. | Off (`postEnabled` false, empty URL) |
| Window titles that are neither blacklisted nor trusted, with the app name and bundle ID | `https://api.typesafe.ai/v1/systemone` (TypeSafe's Jev model), to decide whether the title may be published; see **Module permissions** | Off until a TypeSafe API key is entered |
| Charger cover JPEG and app icons | The S3-compatible bucket (R2) you configure | Off |
| Cursor cloud usage history | `https://cursor.com` dashboard endpoints, using Cursor.app's own local login | Off (coding usage module disabled) |
| Local HTTP API: `/health` (frontmost app, icon state, a window title only when it is already cleared for publishing), `/apple-music/authorization`, charging SSE streams | Whoever can reach the bind address; no authentication | Off; loopback only when enabled |

## What the app includes

- independently switchable charger, foreground-app, Apple Music, Mac timezone, and coding-usage modules
- power-bank idle sleep: drop BLE after several minutes of no charge or discharge, then reconnect periodically to look again
- CoreBluetooth discovery or a pinned peripheral UUID for the charger module
- AES-GCM + ephemeral P-256 ECDH session handshake
- account-scoped 40-character Anker user ID stored in Keychain
- native dashboard and menu-bar controls
- disconnect and reconnect actions
- optional local HTTP listener with `/health` and per-device SSE
- a versioned telemetry envelope posted to one shared ingest endpoint
- direct local Music.app state via Apple Events (separate from Apple Music Web API)
- optional MusicKit library authorization and Apple Music token upload
- foreground application reporting: the app's name, bundle ID, icon, and — when a
  judgment clears it — the focused window title, with an exact Bundle ID blacklist
  for remote reporting
- window titles gated by a blacklist plus six TypeSafe Jev yes/no judgments
  asked in one request (secrets, private matters, employer material, adult
  content, political sensitivity, informativeness): blacklisted apps are never
  read, trusted apps are published directly, everything else lands in one of
  four verdicts — published, locked (with the dimensions that triggered it),
  omitted (nothing to show, e.g. a title that is just the app's own name) or
  pending. A pending title raises a notification with a single 公开 button;
  closing the notification locks it, and pending titles can also be settled from
  the menu bar
- coding-usage aggregation that never uploads session IDs, project paths, prompts, or replies
- charger cover name plus the original JPEG uploaded to R2 (no resize or transcode; the point is to leave Anker's signed URL)
- coding agent usage aggregation in the envelope (subscription plan tiers and rate-limit windows are out of scope here; the author reports them from a separate container to `/api/ingest/agents`)
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
  "activeModules": ["desktop", "appleMusic", "timezone", "charger", "vibeCoding", "vibeCodingYear"],
  "modules": {
    "desktop": {
      "applicationName": "Safari",
      "bundleIdentifier": "com.apple.Safari",
      "iconHash": "<sha256>",
      "iconObjectKey": "<sha256>.png",
      "windowTitle": "ReportDecision.swift — MacTelemetryHub"
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

`activeModules` lists enabled capabilities, not the payload keys above. One coding
usage toggle enables `vibeCoding` and `vibeCodingYear`, which feed three modules.
`charger` and `powerBank` are the exception: they are listed only while the
toggle is on **and** the BLE link is actually connected, because their data
comes from outside this process — a dropped link would otherwise keep the site
renewing their heartbeat forever. Connected but idle still counts as active:
a charger with nothing plugged in has no new readings to send, and that is
exactly what heartbeat renewal is for.

`modules.desktop.windowTitle` is a string or `null`; an absent key means the same as
`null` — no publishable title right now. It is only ever present when the title
cleared the judgment described under **Module permissions**, so the site can render
it as-is. The Mac normalizes it before sending (spinners, `[n/m]` progress, `nn%`,
unread badges stripped, whitespace collapsed), trims it, drops an empty string to
`null`, and truncates at **200 Unicode scalars**; the Worker applies the same limit
in the same unit. The `hidden` virtual application never carries a title.

Version 4 is the only accepted contract; desktop icons are addressed by SHA-256.
The Mac renders each icon at 96 px, encodes it once as PNG, signs an S3-compatible
PUT, uploads `<sha256>.png` directly to R2, and sends only `iconObjectKey`
(charger covers go the same way as `<sha256>.jpg`).
The R2 access key and secret are stored in macOS Keychain. There is no base64 fallback;
the server never receives image bytes.

An envelope with no `modules` (or an empty one) is a pure heartbeat: it refreshes
liveness without touching any module's timestamp. One is sent every 90 s while
nothing changes, and never alongside a data post — that post already proves the
reporter is alive. `presence: "offline"` covers graceful exits (quit, sleep) and is
sent synchronously so it beats the disconnect; crashes, network loss, and forced
shutdowns still rely on the site's "nothing received for a while" timeout. Both
paths are needed; neither replaces the other.
The POST body is deliberately bounded. `CodingUsageKit` reduces original local
and cloud records to display-ready totals, today's usage, model names, and a
compact calendar. Session identities are hashed only for local deduplication;
session IDs, project paths, prompts, replies, and Cursor credentials are never
included in coding telemetry.

Vibe coding is split into three modules by **how often it changes**, not by which
endpoint produced it:

| Module | Interval | Contents |
| --- | --- | --- |
| `vibeCodingNow` | 60 s | activity inferred from local session metadata, current model, and last activity time |
| `vibeCodingUsage` | 10 min | retained token history, today's usage, API-equivalent valuation, session count, and per-source collection status |
| `vibeCodingYear` | 1 h | 371 days from the same ledger, with daily totals and a compact top-5 model mix |

These intervals are configurable, with a 60-second minimum. Session collection
runs independently of the slower cloud history refresh. The calendar reads the
local ledger without starting a second history download. Usage and session counts
are assembled by the shared engine before upload.

Plan tiers and rate-limit windows come from a separate producer (the author runs
a small container that posts them to `/api/ingest/agents`; it is not part of this
repository). This app reports usage through `/api/ingest/mac` and does not fetch
or forward those account limits.

Every module is sent only when its own display content changes.

## Coding agent usage and sessions

采集实现位于 `Sources/CodingUsageKit/`，App 只负责调度和显示状态。应用无需运行
TokenTracker，也不连接它的 HTTP 面板，不读取或导入它的 queue、缓存和汇总文件。
首次历史重建只使用本机仍存在的原始数据与 Cursor 云端目前可返回的记录。

| 来源 | 用量历史 | 会话与此刻状态 |
| --- | --- | --- |
| Claude、Codex、Grok、Antigravity | 固定版本的 `ccusage` 读取本机原始日志或数据库；Antigravity 使用其本地 SQLite 用量记录 | `ccusage <source> session` 的本机会话元数据 |
| 其他被 `ccusage` 发现且支持的来源 | 同样读取本机原始历史，动态纳入按来源统计 | 同样读取本机会话元数据 |
| Cursor | 独立 Swift reader 分页读取 Cursor 账号云端历史 | 当前没有本机会话适配器，不把云端历史冒充正在使用状态 |

本地采集先通过 `ccusage daily --by-agent --json --offline` 发现来源，再按来源读取
`daily` 和 `session`。所有日桶统一为 `Asia/Shanghai`，命令不传 `--since` 或 `--until`，
不把“今日”或“近一年”当成累计用量的历史范围。年度图是完整账本的一个窗口。
活动天数按所有来源中 token 大于零的日期取并集；会话数只统计实际读到且去重的本机会话。

Cursor 的 `state.vscdb` 只提供本机登录态；历史来自
`POST https://cursor.com/api/dashboard/get-filtered-usage-events`。采集器固定本次查询的
起止时刻，从 epoch 起请求所有可见记录，核对每一页的服务端总数。缺页、总数变化、
异常格式、重复整页、鉴权失败或分页上限均会报错，不能作为完整历史写入。
没有稳定事件 ID 时，只剔除服务端总数能够证明重复的相邻页边界记录。
账号只保留基于身份的哈希，重新登录换 token 不会生成新账号；切换账号则隔离历史。

用量账本默认位于
`~/Library/Application Support/MacTelemetryHub/CodingUsage/history.json`，按来源、账号和日期
保存聚合值，并以文件锁和原子写入保护并发刷新。一次成功的完整日桶可以接受上游更正，
包括 token 下调；没有返回的旧活动日、失败来源和异常缩短的历史范围保留已有数据并显示诊断。
原始日志删除、离线或云端不再返回某个月份，不会自动清空已经保存的历史。
这不能恢复首次采集前就已丢失、且云端也不可获取的记录。

Token 分列互斥：`inputTokens` 不包含缓存读写，`cacheReadTokens` 与
`cacheCreationTokens` 分开统计；`reasoningTokens` 是 `outputTokens` 的子集，总量只加前述
四项。Cursor JSON 的 `cacheWriteTokens` 直接映射缓存创建量。CSV 只用于严格对账，
当前导出中的 `Input (w/ Cache Write)` 也是独立的缓存创建列，不与另一输入列相减。

每个 agent 的 `usageStatus` 包含状态、上次采集时间、覆盖日期、`precision` 和
`costComplete`。旧版 Cursor 按请求计量记录可能没有 token 分列：保留诊断，并展示已计量
部分，不推算出虚构 token。`precision` 描述 token 的测量口径，费用本身始终是
`apiEquivalentCostUSD`，不是订阅费、剩余额度或实际账单扣款。Cursor 按内置公开 API
价格快照估值，不使用导出 `Cost`、`chargedCents` 或套餐扣费替代；本地来源使用 ccusage
的 API 估值。未知模型、路由名或缺失价格保留 token，并将费用标为不完整。价格快照的
来源、版本和适用边界见 `CodingUsagePricing.swift`；历史估值不代表逐日原始账单。

### Pinned ccusage helper

`Tools/install-ccusage.sh` 从 npm 下载官方 ccusage 正式版的平台二进制包
（`@ccusage/ccusage-darwin-*`），固定版本 `20.0.21`。该版本包含 Antigravity SQLite 支持，
并已合入 ccusage/ccusage#1719：不再丢弃 `usage.iterations[].model` 为 `null` 的 Claude 条目
（Fable 5.1 会话）。升级时改脚本里的 `VERSION` 和两个 `ARCHIVE_SHA`（对 npm tarball 算
SHA-256）。脚本按本机架构选择 `darwin-arm64` 或 `darwin-x64`，校验对应归档的 SHA-256，
再检查 Antigravity 子命令，输出到 `.build/ccusage/ccusage`；不会修改全局 npm/Homebrew
安装。`CCUSAGE_ARCH=arm64` 或 `x86_64` 可显式选择构建架构，需与目标 Mac 匹配。

```bash
Tools/install-ccusage.sh
.build/ccusage/ccusage --version
```

`build-release.sh` 已在 Xcode 构建前调用安装脚本；Xcode 的 Embed ccusage 阶段将辅助程序
复制到应用的 `Contents/MacOS/ccusage` 并签名，同时打包 ccusage、价格数据和 Cursor 适配代码
的许可证。直接在 Xcode 运行前也需先执行安装脚本。

新版采集模块使用 `vibeCodingModuleEnabled`，首次安装或从旧版升级后默认关闭，需在设置中
明确启用。CLI 路径依次选择 `CCUSAGE_CLI_PATH` 环境变量、新的 `codingUsageCLIPath` 自定义
设置、应用内置程序、最后才是已知系统路径。旧版保存的 `ccusageCLIPath` 不再继承，避免旧的
全局安装覆盖支持 Antigravity 的内置构建。通常直接使用内置程序即可。

### Read-only source diagnostics

Swift package 提供与 App 共用采集实现的 `coding-usage`。诊断命令只读取原始来源，
不会向站点上报；它会写入显式指定的诊断账本以及可选输出文件。使用独立目录即可与 App
的生产账本分开检查：

```bash
mkdir -p /tmp/mac-telemetry-coding-usage
swift run coding-usage collect \
  --ledger /tmp/mac-telemetry-coding-usage/history.json \
  --ccusage "$PWD/.build/ccusage/ccusage" \
  --output /tmp/mac-telemetry-coding-usage/snapshot.json \
  --offline

swift run coding-usage snapshot \
  --ledger /tmp/mac-telemetry-coding-usage/history.json

swift run coding-usage sessions \
  --ledger /tmp/mac-telemetry-coding-usage/history.json \
  --ccusage "$PWD/.build/ccusage/ccusage"
```

- `--ledger` 必填；`snapshot` 只读该账本，不运行采集器，也不需要 `--ccusage`。
- `--ccusage` 在 `collect` 和 `sessions` 中必填，指向可执行程序。
- `--output` 可选，写入完整的 `usage`、`now`、`year` JSON；标准输出仅显示数量和来源健康摘要。
- `collect --offline` 让 ccusage 使用已有/内置价格信息，**仍会请求 Cursor 云端历史**。
- `collect --local-only` 跳过 Cursor；需要本地离线诊断时同时传 `--offline --local-only`。
- `sessions` 只刷新本机会话元数据，固定使用离线价格模式，不请求 Cursor，也不重算历史 token。

来源失败会进入结果的状态字段，命令仍可能正常输出；检查 `sources[].state` 与 `error`，
不能仅凭退出码认定所有来源完整。

`positionMs` in the music module is an anchor, not a stream. Paired with
`observedAt` and `state` it lets the site interpolate the playhead on its own,
so the module is re-sent only on a track change, a play/pause transition, or a
seek — detected as the playhead drifting more than 2.5 s from what the site
would be showing. A track played straight through uploads once, not once per
post interval.

`appleMusic.queue` is beta. Music.app has no public Playing Next API, so the
reporter reads the on-disk `Queue.dat` next to the local library (title and
persistent ID) and joins artist/album from a single library Apple Event. The
object always includes `"beta": true`. Treat the shape as experimental; a
Music.app update can change the file without warning. The site can ignore it
until it chooses to render it.

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
  focused window title. Window contents are never read.
- Behind the master switch, window titles are gated in three tiers, all
  editable in **设置 › 窗口标题** — the pane that holds every
  window-title setting, from that switch and the two permissions down to the
  lists, the judgment credentials and lines, and the verdict cache. **设置 › 数据源** keeps only
  application identity: the foreground-capture switch and the
  remote-reporting blacklist.
  1. **标题黑名单** — those Bundle IDs never have their accessibility window or
     title read at all, and switching to one detaches the previous observer.
  2. **免判放行** — those titles are reported as they are, with no judgment.
  3. Everything else — each normalized title is sent to TypeSafe's `jev-latest`
     model (`POST https://api.typesafe.ai/v1/systemone`) as **six `noul` (yes/no)
     questions over the same state, asked in one request**. One label per
     question, so that a title can only be caught by a risk it was actually
     asked about:

     | Question | Yes means |
     | --- | --- |
     | `exposesSecret` | a password, key, token, secret or account number |
     | `exposesPrivateMatter` | money, health, legal, romantic or family matters; a named private individual; a personal message subject |
     | `exposesConfidentialWork` | an employer's or client's internal material — the owner's own repositories and hobby projects are not |
     | `isAdultContent` | pornographic or sexually explicit |
     | `isPoliticallySensitive` | political leaders, regimes, movements or contested events, including coded references (homophones, nicknames, memes) |
     | `isInformative` | the title says something beyond the application's own name |

     Each answer is a probability. The five risk questions share one pair of
     measured thresholds and are combined in code by an **any-serious-violation**
     rule, never a weighted average; the four verdicts follow in this order:
     a risk at or above the lock line locks, and every triggered dimension is
     recorded so the UI can say *已锁定 · 政治敏感*; an `isInformative` below
     the informative line omits the title (not reported, no notification, but
     listed in **设置 › 窗口标题** where it can be published by hand); all five
     risks at or below the clear line publishes; anything left — a
     title the model is genuinely unsure about — raises a user notification
     titled *<app> 窗口标题公开确认* whose body is the title itself, and the UI
     names the dimensions that are still in the middle band. The notification
     has exactly one
     action, 公开: macOS folds two or more actions into an 选项 submenu, so a
     second button would cost two clicks. Closing the notification
     (X / Clear / Clear All) locks the title instead, but only while that title is still pending, so
     clearing a stale banner for an already-decided title changes nothing.
     Clicking the notification body decides nothing — it just opens
     **设置 › 窗口标题**. The menu-bar menu lists up to five pending titles at
     the top, each a submenu with 公开 and 锁定, so a missed notification is still
     two clicks from settled. Until the user answers, the title is treated as
     locked. Verdicts are cached on disk by Bundle ID plus normalized title
     (LRU, 500 entries, `~/Library/Application Support/
     MacTelemetryHub/window-title-judgments.json`, format version 3 — an older
     file is discarded and re-judged rather than migrated, because a version-2
     list was never asked about politics or adult content at all) and are
     reviewable, re-judgeable and deletable in **设置 › 窗口标题**, which also
     shows all six probabilities per entry. All three lines are adjustable in
     **设置 › 窗口标题**; saving new ones re-applies them to the cached
     Jev verdicts, leaving the ones decided by hand untouched. A master switch
     — in that same pane and in the menu-bar menu, applied the moment it is
     flipped — turns the whole thing off: no title is read, nothing is asked of
     Jev, the envelope carries a null title and the status reads `disabled`. The
     judgment cache survives, so flipping it back does not re-ask anything.

  Only the title text and the application's name and Bundle ID leave the machine
  for a judgment; the TypeSafe API key lives in Keychain (or `TYPESAFE_API_KEY`).
  Apps in the remote-reporting blacklist are **never** sent to TypeSafe and never
  report a title. A missing key, a timeout (10 s) or any other failure is treated
  as locked and is not cached, so one network hiccup cannot permanently mark a
  title private. Published titles are the only ones that reach the envelope;
  the local UI still shows the current title together with its verdict, and
  `GET /health` reports the verdict always but the title only when it is
  publishable. Judgments are throttled: a title must stay stable for 2 s, each
  application is asked at most once per 10 s, and only one request per cache key
  is ever in flight.
- Bundle IDs in the remote-reporting blacklist remain visible in the local UI
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
- Coding usage reads the original local logs/databases with the bundled `ccusage`
  helper. Cursor cloud history uses Cursor.app's existing local login state and
  sends its credential only to Cursor's HTTPS endpoints. Note that this talks to
  an undocumented dashboard endpoint (`cursor.com/api/dashboard/…`) with the
  cookie Cursor.app already holds — it is not an official API, it can break or
  be disallowed by Cursor at any time, and enabling it is your own call. Enable
  the coding usage module and check the CLI path in Settings; no local panel URL
  is needed. Each collection interval has a 60-second minimum.

## Anker BLE protocol notice

`Sources/ChargerTelemetryKit` implements the BLE protocol of the Anker Prime
charger and power bank as observed between the Anker app and the author's own
devices, including the static AES-GCM material the firmware uses for the
initial handshake. It is published so that owners of the same hardware can read
their own devices; it is not affiliated with, endorsed by, or supported by
Anker, comes with no warranty, and may stop working after a firmware update.
Check your local law and the device's terms before using it. The protocol notes
live in [LYJW131/anker-prime-ble](https://github.com/LYJW131/anker-prime-ble).

## Open and run in Xcode

1. Run `Tools/install-ccusage.sh`, then open `MacTelemetryHub.xcodeproj`.
2. Select the `MacTelemetryHub` target, then **Signing & Capabilities**.
3. Select your Apple Developer team and keep **Automatically manage signing**
   enabled.
4. Run on **My Mac** and approve the Bluetooth prompt once.
5. Open Settings in the app, enter the Anker user ID, then press **扫描充电头**
   and pick the charger from the list. Choosing one writes just that
   CoreBluetooth UUID to disk and reconnects the link. It deliberately skips the
   whole-page validation: an unrelated half-filled field must not fail the
   pairing after the UUID has already changed in memory.

Pairing is the only time the app scans. Once a UUID is stored, it only ever
issues a directed connect to that one charger — the request stays pending until
the charger powers on, so there is no scanning, no timeout, and no retry loop.
**重新配对** clears the UUID and brings the scan button back.

The current charger's CoreBluetooth identifier is
`102DC514-2EB9-DAC9-C11A-4A0781776A73`.

## Apple Music credentials upload

The app keeps the existing playback snapshot separate from MusicKit. In the
Apple Music section of Settings, click **授权并上报 Apple Music token**. After
the user approves the macOS media-library prompt, MusicKit hands over the Music
User Token and the app sends it through the unified ingest endpoint, as an
`appleMusicCredentials` module of the v4 envelope:

```json
{
  "appleMusicCredentials": {
    "musicUserToken": "<Music User Token>"
  }
}
```

There is no separate credentials endpoint — the button only wakes the reporter
loop. The backend should treat the token as a secret, avoid logging it, and
return a 2xx response only after accepting the payload.

The developer token is no longer part of this contract: the receiving backend signs its
own with a MusicKit private key (`.p8`), so nothing expiring travels in the envelope, and
an envelope that still carries `developerToken` or `expiresAt` is rejected. The
app only re-reads MusicKit's cached user token every five minutes and uploads it
when the value changes (it still asks MusicKit for a developer token in passing,
because `userToken(for:)` requires one, but that value is neither kept nor sent).

The local `GET /apple-music/authorization` endpoint exposes status only and never
returns token values: authorization status, whether a user token is held,
`lastUploadAt` (Unix milliseconds) and `lastError`. Mint failures are also
written to the unified log under the `apple-music` category
(`log show --predicate 'category == "apple-music"'`).

The ingest URL is only validated as http-or-https with a host; nothing in the app
forces TLS. Since that one envelope carries the user token and the Bearer secret,
use HTTPS for anything but a local backend.

For automatic developer-token generation, enable **MusicKit** in the App ID's
App Services in Certificates, Identifiers & Profiles, use the explicit Bundle
ID `com.liangyangjunwei.MacTelemetryHub`, and run a team-signed build. The
client never contains your MusicKit private key.

## Build a local app bundle

```bash
chmod +x build-release.sh
./build-release.sh
open "$HOME/Applications/Mac Telemetry Hub.app"
```

The script prepares the pinned ccusage helper and icons, builds with an Apple
Development signature, installs into `~/Applications`, and verifies the signed
bundle. Set `MAC_TELEMETRY_DEVELOPMENT_TEAM` to override the script's development
team and `MAC_TELEMETRY_INSTALL_DIR` to choose another installation directory.
Xcode must be able to provision that team. The diagnostic `coding-usage` command
is a separate Swift package executable; the app bundles the ccusage helper and
links `CodingUsageKit` directly.

`Sources/TelemetryCore` holds the pure, `Sendable` half of the reporter — the
telemetry envelope and module snapshots, per-module upload signatures (change
detection), the R2 SigV4 signer, and the icon upload retry budget. Like
`ChargerTelemetryKit` it is compiled straight into the app
target as a source group (register new files with `Tools/add-source-file.py`) and
doubles as an SPM target so `Tests/TelemetryCoreTests` can pin the wire format and
the change-detection semantics with `swift test`.

## Login launch

After installing the signed app in `/Applications`, enable **登录后自动启动** in
Settings. This uses the supported macOS `SMAppService` API and starts after the
user logs in; it is not a root LaunchDaemon. This one toggle applies the moment
it is flipped — the page says so under the switch. Every other field applies on
**保存**; **取消**, or simply closing the Settings window, re-reads the persisted
values and drops the unsaved edits.

Collection starts in `applicationDidFinishLaunching`, not when the dashboard
window opens: a login launch normally shows no window at all. Closing the
dashboard window does not stop the service either. Use the menu-bar status icon
to reopen the window, disconnect, reconnect, or quit.

## Local HTTP

The default bind is `127.0.0.1:8787` (loopback only). Set the bind address to
`0.0.0.0`, `::`, or a specific interface IP to listen more widely. If the port
is temporarily occupied, the app retries every three seconds.

**There is no authentication on this API.** Bound to anything but loopback,
everyone on that network segment can read `/health` (frontmost app name, icon
hash, and any window title already cleared for publishing),
`/apple-music/authorization`, and the charging SSE streams. Keep the loopback
default unless you trust the whole network.

- `GET /health` — process liveness, plus each charging link's enabled / connected / phase.
  `reporter` carries the remote loop's `postEnabled`, `lastSuccessAt`, `lastError` and
  whether R2 direct upload is fully configured; `desktopIcon` shows the frontmost app's
  icon delivery state (`iconHash`, `iconEncoded`, `objectKeyConfirmed`, `uploadAttempts`,
  `resolving`). Read this first when an app icon is missing on the site. Icon uploads
  back off 2s/4s/8s between failures and, after three failures, retry again ten minutes
  later instead of giving up until restart; failures also go to the unified log under
  category `desktop-icon`. `windowTitle` carries the focused title's judgment
  `status` (`published`, `locked`, `needsConfirmation`, `judging`, `trusted`,
  `blacklisted`, `hidden`, `noAccess`, `unavailable`, `none`), whether a title is
  going out right now (`reportable`), and that `title`. While a new title is
  `judging`, the previous **published** title of the same application keeps being
  reported for up to 20 seconds, so `judging` can legitimately come with
  `reportable: true` and the older title.
- `GET /apple-music/authorization` — Apple Music authorization state, see above.
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
minimal JSON response. `CodingUsageKitTests` additionally covers source parsing,
token/cache/reasoning invariants, Cursor pagination and CSV formats, price
completeness, historical correction and retention, account isolation, process
cancellation, and engine-to-ledger mapping without real credentials or network.
`TelemetryCoreTests` covers the window-title pipeline: normalization (braille and
geometric spinners, `[n/m]`, percentages, unread badges, the 200-scalar cap), the
three verdict thresholds against measured Jev distributions, judgment-cache coding
and LRU eviction, the Jev request body and a recorded live response, and the
reporting rules — a title change posts immediately, an icon-only change does not,
and the hidden virtual application carries no title.

## Pulse window usage

The session refresh includes `modules.vibeCodingNow.tokenUsage`: a rolling 24-hour
set of five-minute, epoch-millisecond usage buckets from Codex and Claude JSONL logs.
The scanner follows file offsets, handles unfinished lines, deduplicates Codex totals
and Claude streaming messages, and never uploads content, paths or session IDs.
`inputTokens` excludes cache reads; reasoning is a subset of output. `eventCount`
counts usage events, not HTTP requests. Source status is `ok`, `partial` or
`unavailable`; unsupported providers are unknown, not zero. Daily usage is unchanged.
Window usage is reconciled by event time, including late-arriving records. It is
internal Jev evidence and does not appear in the public Vibe Coding patch.

Read-only diagnostic: `swift run coding-usage pulse --output /tmp/pulse-usage.json`.
Deploy a backend that accepts the ingest protocol above before installing this reporter.
