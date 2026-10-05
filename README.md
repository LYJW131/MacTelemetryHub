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
- Jev participates in window-title judgments; only titles cleared for publication
  enter the reporting envelope
- coding usage facts read from local agent logs — per-day usage, the latest usage event, five-minute token windows — that never include session IDs, project paths, prompts, or replies
- charger cover name plus the original JPEG uploaded to R2 (no resize or transcode; the point is to leave Anker's signed URL)
- coding usage in the envelope covers this Mac's local agents only; Cursor's account history, subscription plan tiers and rate-limit windows are out of scope here (the author reports them from a separate container to `/api/ingest/agents`)
- login launch using `SMAppService.mainApp`

Each module can be disabled without stopping the others. Disabling the charger
module also stops its BLE session. The Anker user ID is deliberately not
compiled into the app and is only required while the charger module is enabled.

## Unified ingest protocol

Point the app at the ingest host (`https://ingest.homepage.lyjw.llc/api/ingest/mac`
for the author's site) and fill in the Cloudflare Access service token issued
for this Mac: **Access Client ID** and **Client Secret** (the secret lives in the
Keychain). Requests then carry `CF-Access-Client-Id` / `CF-Access-Client-Secret`
and no `Authorization` header. `ACCESS_CLIENT_ID` / `ACCESS_CLIENT_SECRET`
environment variables override both fields.

Every request uses a versioned envelope and may
contain only the modules that have fresh data:

```json
{
  "version": 4,
  "heartbeatAt": 1760000000000,
  "presence": "online",
  "activeModules": ["desktop", "appleMusic", "timezone", "charger", "coding"],
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
    "codingUsage": {},
    "codingActivity": {},
    "codingTokenBuckets": {}
  }
}
```

`activeModules` lists enabled capabilities, not the payload keys above. The one coding
usage toggle is listed as `coding` and feeds three modules.
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
`null`, and truncates at `Sources/TelemetryCore/WindowTitleNormalizer.swift#maximumScalarCount`
Unicode scalars; the Worker applies the same limit in the same unit. The `hidden` virtual application never carries a title.

Version 4 is the only accepted contract; desktop icons are addressed by SHA-256.
The Mac renders each icon at 96 px, encodes it once as PNG, signs an S3-compatible
PUT, uploads `<sha256>.png` directly to R2, and sends only `iconObjectKey`
(charger covers go the same way as `<sha256>.jpg`).
The R2 access key and secret are stored in macOS Keychain. There is no base64 fallback;
the server never receives image bytes.

An envelope with no `modules` (or an empty one) is a pure heartbeat: it refreshes
liveness without touching any module's timestamp. One is sent every
`Sources/TelemetryCore/ReportDecision.swift#heartbeatInterval` while nothing
changes, and never alongside a data post — that post already proves the
reporter is alive. `presence: "offline"` covers graceful exits (quit, sleep) and is
sent synchronously so it beats the disconnect; crashes, network loss, and forced
shutdowns still rely on the site's "nothing received for a while" timeout. Both
paths are needed; neither replaces the other.

`CodingUsageKit` reduces the local agent logs to raw facts and nothing more: what
each agent used per day, when it last produced a usage event, and five-minute token
windows. Totals, rankings, "today", the yearly calendar, display names and icons are
the receiving site's job — it merges this Mac with its other sources. Session
identities are hashed only for local deduplication; session IDs, project paths,
prompts and replies are never included.

Coding usage is split into three modules by **how often it changes**:

| Module | Cadence | Contents |
| --- | --- | --- |
| `codingActivity` | scanned on the session interval from `App/MacTelemetryHub/AppSettings.swift#load`; sent when it changes, and again after `Sources/TelemetryCore/CodingPayloads.swift#CodingModule.keepaliveInterval` while it does not | per agent, `lastActivityAt` (epoch ms) and the model of the latest usage event. Codex and Claude come from an incremental scan of their JSONL logs; other local sources run `ccusage session` at most every `Sources/CodingUsageKit/CodingUsageEngine.swift#ccusageSessionInterval` |
| `codingTokenBuckets` | same scan, same `keepaliveInterval` | Codex and Claude token windows (`Sources/CodingUsageKit/CodingTokenScanner.swift#bucketMilliseconds`) over the range that scanner covers |
| `codingUsage` | Claude on the usage interval and every local agent on the full interval, both from `AppSettings.load` (an unset full interval is `App/MacTelemetryHub/CodingUsageMonitors.swift#VibeCodingUsageMonitor.defaultFullInterval`); sent every round | per agent, the complete day history (`Asia/Shanghai` days), session count and collection status. The shorter round carries only Claude; agents missing from an envelope keep what the site already has |

The intervals are configurable. `AppSettings` rejects a coding interval below its
minimum. Session scans run independently of the slower usage refresh. Timestamps
are epoch milliseconds,
dates `YYYY-MM-DD`, and nil fields are omitted rather than sent as `null`.

Plan tiers and rate-limit windows come from a separate producer (the author runs
a small container that posts them to `/api/ingest/agents`; it is not part of this
repository). This app reports usage through `/api/ingest/mac` and does not fetch
or forward those account limits.

Every module is sent only when its own display content changes, with two
exceptions. `codingActivity` and `codingTokenBuckets` ignore their collection
clock (`collectedAt`, and the bucket report's `from`/`to`) when deciding whether they
changed, but an unchanged one is still re-sent after
`Sources/TelemetryCore/CodingPayloads.swift#CodingModule.keepaliveInterval` so the site sees
the clock advance — that advance is how it tells a quiet Mac from a dead
collector. `codingUsage` goes out after every successful round, since each round
moves `collectedAt` forward; a failed round that changes nothing is not re-sent.

The `202` receipt may list `ignored` (module names the site does not know) and
`rejected` (`[{ module, error }]`, coding modules that failed validation and were
dropped on their own while the rest of the envelope was accepted). Either way the
module's latch still advances and the reason shows on its dashboard card; it is
sent again only once its content changes, instead of hitting the same validation
on each `CodingModule.keepaliveInterval`. A manual report always sends.

## Coding agent usage and sessions

采集实现位于 `Sources/CodingUsageKit/`，App 只负责调度、上报和显示状态。应用无需运行
TokenTracker，也不连接它的 HTTP 面板，不读取或导入它的 queue、缓存和汇总文件。
首次历史重建只使用本机仍存在的原始数据。

| 来源 | 用量历史（`codingUsage`） | 活动（`codingActivity`）与五分钟桶（`codingTokenBuckets`） |
| --- | --- | --- |
| Claude、Codex | 固定版本的 `ccusage` 读取本机原始日志 | 每分钟增量扫描 JSONL 日志，只读上次之后追加的部分；最近一条用量事件的时刻和模型就是活动，同一次扫描也产出五分钟桶。会话数仍随用量刷新由 `ccusage session` 更新 |
| Grok、Antigravity | 固定版本的 `ccusage` 读取本机原始日志或数据库；Antigravity 使用其本地 SQLite 用量记录 | 活动来自 `ccusage <source> session` 的本机会话元数据，最多 5 分钟一次（每次都要重读全部历史），不出五分钟桶。Antigravity 一次要解析几百 MB 的对话库：固定走离线价目表（在线模式慢三倍、结果相同），超时 300 秒，`conversations` 里的文件没变就沿用上次输出 |
| 其他被 `ccusage` 发现且支持的来源 | 同样读取本机原始历史，动态纳入按来源统计 | 同上，最多 5 分钟一次 |

Cursor 不是本机来源：它的账号历史由容器里的上报器用自己的登录态上报，这台 Mac 不采集也不上报。
旧账本里留下的 Cursor 日子原样留在盘上，不进任何一份上报。

用量历史分两档刷新：卡片上只有 Claude Code 要看当天的实时用量，所以「Claude 今日用量刷新」
（默认 10 分钟）每轮只读 Claude、报告也只带 Claude；「全部来源刷新」（默认 1 小时）读全部来源，
报告带全部本机 agent。两次完整采集之间，其余来源在账本里原样保留，站点那边也是没出现的 agent 不动。
手动刷新总是完整的。

完整采集先通过 `ccusage daily --by-agent --json --offline` 发现来源，再按来源读取
`daily` 和 `session`。`pi` 的默认目录只有 `~/.pi/agent/sessions`，全来源发现也不接受
`--pi-path`，所以看不到 `~/.omp/agent/sessions`。omp 会话目录里有 jsonl 且 ccusage 提供
`pi` 时，采集会把 `pi` 加进来。`pi` 的 `daily` 和 `session` 传 `--pi-path`，同时包含
`~/.pi/agent/sessions` 与 `~/.omp/agent/sessions`；该参数替换默认目录，只传一边会丢掉另一边。
所有日桶统一为 `Asia/Shanghai`，命令不传 `--since` 或 `--until`，历史范围就是来源还留着的全部记录。

用量账本默认位于
`~/Library/Application Support/MacTelemetryHub/CodingUsage/history.json`，按来源、账号和日期
保存聚合值，并以文件锁和原子写入保护并发刷新。一次成功的完整日桶可以接受上游更正，
包括 token 下调；没有返回的旧活动日、失败来源和异常缩短的历史范围保留已有数据并显示诊断。
原始日志删除或来源不再返回某个月份，不会自动清空已经保存的历史。
这不能恢复首次采集前就已丢失的记录。

### 上报的用量事实

`codingUsage` 里每个 agent 是它在本机账本里的完整历史，站点收到后整份替换这个 agent：

- `state: "ok"`：带 `collectedAt`（最近一次成功采集，epoch 毫秒）、`sessionCount`（本机见过的不同会话数）
  和按日期升序的全部 `days`。扫描当天没有用量的来源补一行全 0，站点据此知道「今天确认没用」而不是「不知道」。
  采到了但有缺口（token 未分列、历史变短而保留旧日子、会话元数据失败等）时仍是 `ok`，缺口写进 `warning`。
- `state: "error"`：这一轮什么都没采到。只带状态、原因和会话数，不带 `days`，站点保留已有的日子；
  `collectedAt` 停在上次成功。从没采到过用量的来源（这台 Mac 上压根没有它）不报。

每个日行：

- Token 分列互斥：`inputTokens` 不包含缓存读写，`cacheReadTokens` 与 `cacheCreationTokens` 分开统计；
  `reasoningTokens` 是 `outputTokens` 的子集。`totalTokens` 是来源实测的总量，可以大于前四列之和——多出来的
  是来源没分列的量（旧记录里常见），保留实测总量，不推算出虚构的分列。
- `models` 是这一天各模型的 token，零用量的不报，按用量降序。模型名是来源的原始 id，只有 Antigravity 的
  `model_placeholder_m…` 占位符换成公开 catalog id（`CodingUsageModelIdentity`），换名后同名的合并。
  隐藏哪些名字（如 `unknown`）、跨 agent 怎么排名都归站点。
- `apiEquivalentCostUSD` 是 ccusage 按公开 API 价估的费用，不是订阅费、剩余额度或实际账单扣款。
  `costComplete` 按天判：这一天有 token 却没有费用、有模型没估到价、有没分列的 token，或是 Antigravity
  的思考量（ccusage 的日 JSON 没有这一列），那天就是 false；一天估不全不连累别的日子。账本里还没记过
  这一格的旧日行，有 token 的按 false 报，下一次完整采集把 ccusage 仍返回的日子补上。

`codingTokenBuckets` 是 Codex 与 Claude JSONL 的滚动窗口，`[from, to)`，`to` 等于 `collectedAt`。窗口只带起点 `from`（`Sources/CodingUsageKit/CodingTokenScanner.swift#bucketMilliseconds` 的整数倍，桶是 `[from, from + bucketMilliseconds)`）。每一行是一个 agent × 模型，含 input、output、cache-read、cache-creation、reasoning 和 `eventCount`。`agents` 标明覆盖了哪些 agent：`ok`、`partial`（有行读不了）或 `unavailable`（没有日志）。覆盖范围内缺桶是零；不支持的来源是未知，不是零。扫描器按文件偏移走，处理未写完的行，并去掉 Codex 总量和 Claude 流式消息的重复。不上报正文、路径或 session ID。`inputTokens` 不含缓存读；reasoning 是 output 的子集。`eventCount` 计的是用量事件，不是 HTTP 请求。窗口按事件时间对齐，迟到的记录也算。按天的用量在 `codingUsage`，不在这些窗口里。

来源 id 必须是站点认的形状（小写字母或数字开头，只含 `a-z0-9._-`）。不合规的来源不上报，原因显示在
「Vibe · 用量」卡片上——一个坏 id 会让站点拒掉整个模块。站点拒收或不认识某个模块时（回执的 `rejected` /
`ignored`），原因同样显示在对应的卡片上。

### Pinned ccusage helper

`Tools/install-ccusage.sh` 从 npm 下载官方 ccusage 正式版的平台二进制包
（`@ccusage/ccusage-darwin-*`），版本是 `Tools/install-ccusage.sh#VERSION`。升级时改
`VERSION` 和两个 `ARCHIVE_SHA`（对 npm tarball 算 SHA-256）。脚本按本机架构选择
`darwin-arm64` 或 `darwin-x64`，校验对应归档的 SHA-256，再检查 Antigravity 子命令，
输出到 `.build/ccusage/ccusage`；不会修改全局 npm/Homebrew 安装。`CCUSAGE_ARCH=arm64`
或 `x86_64` 可显式选择构建架构，需与目标 Mac 匹配。

```bash
Tools/install-ccusage.sh
.build/ccusage/ccusage --version
```

`build-release.sh` 已在 Xcode 构建前调用安装脚本；Xcode 的 Embed ccusage 阶段将辅助程序
复制到应用的 `Contents/MacOS/ccusage` 并签名，同时打包 ccusage 的许可证。直接在 Xcode 运行前也需先执行安装脚本。

`vibeCodingModuleEnabled` 在 `App/MacTelemetryHub/AppSettings.swift#load` 里缺省关闭，需在设置中启用。CLI 路径按同一处的顺序选择：`CCUSAGE_CLI_PATH`、已保存且可执行的 `codingUsageCLIPath`、应用内置程序、已知系统路径。

### Read-only source diagnostics

Swift package 提供与 App 共用采集实现的 `coding-usage`。诊断命令只读取原始来源，
不会向站点上报；它会写入显式指定的诊断账本以及可选输出文件。使用独立目录（或 App 账本的一份拷贝）
即可与 App 的生产账本分开检查：

```bash
mkdir -p /tmp/mac-telemetry-coding-usage
swift run coding-usage collect \
  --ledger /tmp/mac-telemetry-coding-usage/history.json \
  --ccusage "$PWD/.build/ccusage/ccusage" \
  --output /tmp/mac-telemetry-coding-usage/usage.json \
  --offline

swift run coding-usage report \
  --ledger /tmp/mac-telemetry-coding-usage/history.json

swift run coding-usage sessions \
  --ledger /tmp/mac-telemetry-coding-usage/history.json \
  --ccusage "$PWD/.build/ccusage/ccusage" \
  --output /tmp/mac-telemetry-coding-usage/sessions.json

swift run coding-usage pulse --output /tmp/mac-telemetry-coding-usage/buckets.json
```

- `--ledger` 在 `collect`、`report`、`sessions` 中必填；`report` 只读该账本，不运行采集器，也不需要 `--ccusage`。
- `--ccusage` 在 `collect` 和 `sessions` 中必填，指向可执行程序。
- `--output` 可选，写的是信封 `modules` 里对应的那几格，和 App 上报的是同一份，可以原样拼进一封 v4 信封：
  `collect` / `report` 写 `{"codingUsage": …}`（账本里一个来源都没有时是空对象），`sessions` 写
  `{"codingActivity": …, "codingTokenBuckets": …}`，`pulse` 写 `{"codingTokenBuckets": …}`。
  标准输出只显示数量和来源健康摘要。
- `collect --offline` 让 ccusage 使用已有/内置价格信息。
- `sessions` 刷新本机会话元数据（固定离线价格模式，不重算历史 token）并扫一次 Codex / Claude 日志。
- `pulse` 只扫 Codex / Claude 日志，不需要账本和 ccusage。

来源失败会进入结果的状态字段，命令仍可能正常输出；检查 `agents[].state`、`error` 与 `problems`，
不能仅凭退出码认定所有来源完整。

`positionMs` in the music module is an anchor, not a stream. Paired with
`observedAt` and `state` it lets the site interpolate the playhead on its own,
so the module is re-sent only on a track change, a play/pause transition, or a
seek — detected as the playhead drifting more than
`Sources/TelemetryCore/ReportDecision.swift#musicSeekToleranceMs` from what the site
would be showing. A track played straight through uploads once, not once per
post interval.

`appleMusic.queue` is beta. Music.app has no public Playing Next API, so the
reporter reads the on-disk `Queue.dat` next to the local library (title and
persistent ID) and joins artist/album from a single library Apple Event. The
object always includes `"beta": true`. Treat the shape as experimental; a
Music.app update can change the file without warning. The site can ignore it
until it chooses to render it.

Play/pause transitions, track changes, seeks, and foreground-application switches
skip the throttle window: they wake the reporter loop and upload at once, then
reset the window so the next scheduled post is a full interval away. A seek is
urgent — `musicUrgent` includes `musicSeeked` in `Sources/TelemetryCore/ReportDecision.swift`.
Power readings and coding usage wait for that window and ride along in whichever
envelope goes out first. While a post is failing, the urgent path is suspended
until the backoff expires.

Foreground activity is event-driven: the snapshot is rewritten by the
`NSWorkspace` activation notification, using the `NSRunningApplication` the
notification carries rather than re-reading `frontmostApplication`, which can
still hold the previous app when the notification arrives.

Playback is event-driven too. Music.app posts `com.apple.Music.playerInfo` on
`DistributedNotificationCenter` for track changes and play/pause. The notification
is only a trigger: playback state and track info are read immediately, then again
after `App/MacTelemetryHub/TelemetryModules.swift#AppleMusicMonitor.settleDelay`.
The AppleScript does not read artwork. Music.app fires several notifications per
change, so refreshes coalesce rather than queue up. Scrubbing the playhead posts
nothing; that case waits for the fallback poll
(`AppleMusicMonitor.seekPollInterval`).

Both monitors wake the reporter loop directly rather than waiting to be sampled.
An activation reschedules the switch debounce (`App/MacTelemetryHub/AppSettings.swift#desktopSettleDelayMs`, set in Settings),
which only coalesces those event wakeups. A periodic tick can still send an
intermediate application (`ReportDecision`). The confirmation read absorbs the
playback race. The loop tick (`ServiceController.tickInterval`) covers the
quiet-time heartbeat and the coding modules' keepalive.

The charger wakes it too, but selectively. Waking on every pushed frame would turn
the loop tick into a per-frame loop, to watch numbers that wait for the throttle
window. So the callback compares a structural fingerprint first — ports, cables, device
identity, whether current is actually flowing — and only a plug, unplug, or device swap
gets through. A port that is on but drawing no current counts the same as an off port:
with a device plugged in and idle, the mode byte flips on and off at 0 A, and those flips
wait for the throttle window like any other reading. Structural changes then take
the same urgent path as a track change, so they upload about a second after they
happen instead of up to five seconds later — at most once per
`Sources/TelemetryCore/ReportDecision.swift#chargingStructuralCooldown`. Changes inside
the cooldown are merged into the post that ends it (or ride an earlier follow-up post),
so a field that keeps flapping cannot turn the urgent path into a per-frame upload.

The charger is event-driven at the acquisition layer as well. The device pushes
its stream; the app does not poll BLE to keep telemetry flowing. A link can stay
connected while that stream is dead, which would freeze the dashboard and the
uploader. Silence recovery is `App/MacTelemetryHub/BluetoothService.swift#startStreamWatchdog`:
inside `ChargingDeviceSlot.streamIdleTimeout` it sends nothing; past that it calls
`armTelemetry` once per quiet period to resend the status probe (and the realtime
probe when `ChargingDeviceDecoder.needsRealtimeProbe`); past
`ChargingDeviceSlot.streamStallTimeout` it drops the peripheral so reconnect
builds a fresh session. The timer is local and puts nothing on the air unless
the stream has already gone quiet.

`rawStatus` holds whatever the last `0x0200` reply carried, normally the one the
handshake requested, with its own `rawStatusUpdatedAt`
(`Sources/ChargerTelemetryKit/Models.swift#ChargerState`). Port telemetry follows
the pushed stream; the two ages are not interchangeable.

Measured end to end, from the event to the site serving the new state: play and
pause land in 320–490 ms, application switches in 560–620 ms.

## Module permissions

- Foreground app names and icons use `NSWorkspace` and need no special
  permission. With explicit Accessibility permission, the app also reads the
  focused window title. Window contents are never read.
- Window-title reporting is controlled in **设置 › 窗口标题**. Jev participates in
  judging titles; only titles cleared for publication enter the reporting
  envelope. The local pane lets the user review and change verdicts.
- Bundle IDs in the remote-reporting blacklist remain visible in the local UI
  and local APIs, but their application identity and icon are not uploaded.
  Entering a blacklisted app reports the dedicated virtual application
  `com.liangyangjunwei.MacTelemetryHub.hidden` with the fixed name
  `Hidden Application`; the site maps that identity to its hidden label and
  icon. The real application name, Bundle ID, and icon never enter the payload.
- Apple Music asks once for permission to communicate with Music.app. The
  separate “授权并上报 Apple Music token” action asks for MusicKit library
  permission and obtains a Music User Token. The unified envelope carries only
  `musicUserToken` (`Sources/TelemetryCore/TelemetryEnvelope.swift#TelemetryModulesPayload`,
  `Sources/TelemetryCore/Snapshots.swift#AppleMusicCredentialsPayload`).
- Coding usage reads the original local logs and databases with the bundled
  `ccusage` helper and the incremental Codex / Claude log scanner, and makes no
  network request of its own; only the facts described under **Unified ingest
  protocol** reach the envelope. Enable the coding usage module and check the CLI
  path in Settings; no local panel URL is needed. Each collection interval has a
  60-second minimum.

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

Once a UUID is stored, the link uses a directed connect to that peripheral.
Recovery still scans for it (`App/MacTelemetryHub/BluetoothService.swift#startRecoveryScan`),
and `BluetoothService.tickConnectionPump` rebuilds the session when a connect
times out. **重新配对** clears the UUID and brings the scan button back.

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
app only re-reads MusicKit's cached user token every
`App/MacTelemetryHub/AppleMusicCredentialStore.swift#refreshInterval` and uploads it
when the value changes (it still asks MusicKit for a developer token in passing,
because `userToken(for:)` requires one, but that value is neither kept nor sent).

The local `GET /apple-music/authorization` endpoint exposes status only and never
returns token values: authorization status, whether a user token is held,
`lastUploadAt` (Unix milliseconds) and `lastError`. Mint failures are also
written to the unified log under the `apple-music` category
(`log show --predicate 'category == "apple-music"'`).

The ingest URL is only validated as http-or-https with a host; nothing in the app
forces TLS. Since that one envelope carries the user token and the ingest credentials,
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
user logs in; it is not a root LaunchDaemon. Login launch applies the moment it
is flipped. Pairing (`App/MacTelemetryHub/SettingsView.swift`) and the window-title
master switch (`App/MacTelemetryHub/ServiceController.swift#setWindowTitleReporting`)
also apply immediately. Other fields apply on **保存**; **取消**, or simply
closing the Settings window, re-reads the persisted values and drops the unsaved
edits.

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
  follow `Sources/TelemetryCore/IconUploadBudget.swift#noteFailure` between failures
  and, after `IconUploadBudget.maxAttempts`, wait `IconUploadBudget.retryCooldown`
  instead of giving up until restart; failures also go to the unified log under
  category `desktop-icon`. `windowTitle` carries the focused title's judgment
  `status` (`published`, `locked`, `needsConfirmation`, `judging`, `trusted`,
  `blacklisted`, `hidden`, `noAccess`, `unavailable`, `none`), whether a title is
  going out right now (`reportable`), and that `title`. While a new title is
  `judging`, the previous **published** title of the same application keeps being
  reported for up to `Sources/TelemetryCore/WindowTitleJudgment.swift#WindowTitleHold.maximumDuration`, so `judging` can legitimately come with
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
token/cache/reasoning invariants, per-day cost completeness, historical correction
and retention, the `codingUsage` / `codingActivity` / `codingTokenBuckets` wire
shapes, reading ledgers written by earlier versions, account isolation, process
cancellation, and engine-to-ledger mapping without real credentials or network.
`TelemetryCoreTests` covers the window-title pipeline, judgment-cache coding
and LRU eviction, and the reporting rules — a title change posts immediately, an icon-only change does not,
and the hidden virtual application carries no title — plus the coding modules'
change detection that ignores the collection clock, the five-minute keepalive,
and receipts that reject or ignore a module.

## Pulse window usage

`modules.codingTokenBuckets` 的形状见上文「上报的用量事实」。

Read-only diagnostic: `swift run coding-usage pulse --output /tmp/buckets.json`.
