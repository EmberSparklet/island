# island 入站通知传输方案（task-1）

- 交付人：ipc-scout（只读调研员）
- 日期：2026-10-18
- 工作目录：`/Users/boss/code/z-island`
- 入库位置：`hai/reference/extensions/ipc.md`。原为只读调研交付稿，当时写在构建目录 `.build/plan/` 下（未入库）
- 实验产物：`.build/probe/ipc/`（源码 + 二进制 + 原始日志）。**未入库**，`.build/` 被清理后失效
- 复现全部实测：`bash .build/probe/ipc/run_all.sh 2>&1 | tee .build/probe/ipc/RESULTS.log`（需要未入库的探针源码）
- 标记约定：`[可得]` / `[不可得]` / `[未验证]` + 置信度（高/中/低）。无出处判断标“推断:”。
- 本机环境：macOS 27.0.1（Darwin 27.0.0）、Xcode 27.1 工具链、Swift 6.4（swiftlang-6.4.0.34.1）、umask 022。

---

## 0. 结论速览

1. 主方案：**Unix domain socket**，路径 `~/Library/Application Support/island/ipc/island.sock`。
   - `[可得]` 置信度高。只 `import Foundation` 即可，不需要新依赖，不需要改 `check-layering.sh`。
2. 兜底方案：**落盘收件箱 + DispatchSource 目录监听**。`[可得]` 置信度高。
   - 这是仓库**已有惯例**（island ↔ VS Code 扩展的文件握手），不是新设计。成本最低，但语义弱于 socket。
3. 第三选择（不建议作主方案）：**CFMessagePort**。`[可得]` 置信度高，能双向 + 服务端推送。
   - 但命名冲突语义差：同名重复注册时 API 返回成功、随后 lookup 失败（实测 status=-2）。
4. 排除：NSXPC（必须 launchd job 声明 MachServices）、loopback HTTP（需 `import Network`，触发 lint gate）、URL scheme（island 未注册，且仓库已有"不用 URI"的决策）、DistributedNotificationCenter（无回执、无鉴权、任何本机进程可伪造）。

---

## 1. island 当前进程形态与约束

### 1.1 分层与依赖白名单

- 两个 target：`IslandCore`（库）、`Island`（可执行）。出处：`Package.swift:9-11`。
- `IslandCore` 禁止 `import AppKit|SwiftUI|Carbon`。出处：`scripts/check-layering.sh:16`。
- `Sources/Island` 的 import 白名单只有 5 项：`AppKit`、`Foundation`、`Carbon.HIToolbox`、`ServiceManagement`、`IslandCore`。出处：`scripts/check-layering.sh:27-28`。
  - 推论（事实级）：`import Network` 与 `import Darwin` 都会让 lint gate 直接报错。`import Foundation` 则被允许。
- `IslandCore` 现有 28 个 Swift 文件，全部只 `import Foundation`（实测 `grep -rh '^import ' Sources/IslandCore`）。
- 覆盖率基线 100：`coverage-baseline.txt` 内容为 `100`。`Sources/Island` 逐个文件列入排除项，共 24 条。出处：`coverage.config:17-40`、`hai/CONTEXT.md:95-98`。
  - `coverage.config:16` 明确要求：该目录新增文件必须显式加进排除项。`hai/CONTEXT.md:196` 同。

### 1.2 沙箱与签名

- 无 app sandbox。`scripts/Island.entitlements` 只声明 `com.apple.security.automation.apple-events`（`:8-9`），全文没有 app-sandbox 键。
- 实测本机 `build/Island.app`：
  ```
  Identifier=com.commallama.island
  CodeDirectory v=20400 ... flags=0x2(adhoc)
  Signature=adhoc
  TeamIdentifier=not set
  entitlements: com.apple.security.automation.apple-events = true
  ```
- hardened runtime 只在 Developer ID 分支加。出处：`scripts/build-app.sh:86`（`--options runtime`）；ad-hoc 分支 `scripts/build-app.sh:90` 不加。
  - 本机是 ad-hoc，所以本机构建**没有** hardened runtime 标志（实测 flags 只有 `0x2(adhoc)`）。
- `[未验证]` 置信度中：Developer ID 签名（hardened runtime 生效）下，UDS / CFMessagePort / 文件监听是否仍可用。
  - 推断：hardened runtime 约束的是库校验、代码注入、JIT、`DYLD_*`、Apple events 授权，不触及 POSIX socket 与文件 IO。要确认需做一次 `ISLAND_SIGN_IDENTITY="Developer ID Application: …" ./scripts/build-app.sh` 后重跑同一组探针。

### 1.3 进程形态与 run loop

- accessory app：`LSUIElement=true`（`scripts/build-app.sh:65-66`）+ `setActivationPolicy(.accessory)`（`Sources/Island/main.swift:163`）。
- 入口 `application.run()`（`Sources/Island/main.swift:160-164`）。主线程 run loop 归 `NSApplication`。
- 单实例语义：非 `/Applications` 的副本启动后自行退出，`/Applications` 的那份接管。出处：`Sources/Island/AppDelegate.swift:46-49`。
- 本机实测：`Island` 正在运行（pid 59924），`/Applications/Island.app` 存在；登录项走 `SMAppService.mainApp`（`Sources/Island/LoginItemController.swift:8-22`）。`hai/CONTEXT.md:207` 明确"开机自启用 SMAppService.mainApp（不是 LaunchAgent plist）"。

### 1.4 现有轮询架构（延迟上限的来源）

- 轮询间隔默认 **3 秒**：`Sources/Island/AgentMonitor.swift:32`（`interval: TimeInterval = 3`）。
- 构造处未覆盖该默认值：`Sources/Island/AppDelegate.swift:153-164`。
- 定时器挂在主 run loop 的 `.common` 模式：`Sources/Island/AgentMonitor.swift:49-56`。
- 额外触发点：前台 app 切换时补一轮（`Sources/Island/AppDelegate.swift:169-173`）。
- 设计意图是刻意的：`Sources/Island/AgentMonitor.swift:5-8` 注释写明"MVP 阶段用轮询而不是 FSEvents"。
- 结论：**不改轮询的话，文件收件箱方案的延迟上限 = 3 秒**；改用 DispatchSource 目录监听后实测约 3 毫秒（见 §8.F）。

### 1.5 既有双向文件握手（兜底方案的先例）

- 目录：`~/Library/Application Support/island/vscode`。出处：`Sources/Island/TerminalTabFocuser.swift:17-18`。
- island 写请求：`focus-request.json`。出处：`Sources/Island/TerminalTabFocuser.swift:97`。
- 扩展回写：`focus-response-<id>.json`。出处：`Sources/Island/TerminalTabFocuser.swift:93`；`vscode-extension/extension.js:64`。
- island 侧等待方式：50ms 轮询、上限 1.0s。出处：`Sources/Island/TerminalTabFocuser.swift:20-21`、`:102-118`。
- 扩展侧是事件驱动：`fs.watch(directory, …)`。出处：`vscode-extension/extension.js:71-73`。
- 扩展另有单向状态上报 `window-<pid>.json`（`vscode-extension/extension.js:23`、`:33`），island 读这个文件做"在眼前"判断（`Sources/Island/TaskVisibilityProbe.swift:86-95`）。
- 机制说明：`hai/CONTEXT.md:223`、`hai/CONTEXT.md:245`。

---

## 2. 候选传输逐项评估

### 2.1 对比表

| 传输 | 结论 | 置信度 | 关键依据 | 新增 import | 服务端推送 | 鉴权手段 | 主要风险 |
|---|---|---|---|---|---|---|---|
| Unix domain socket | `[可得]` | 高 | 实测 §8.A/§8.G/§8.J | 无（`Foundation` 已够） | 有（同一条 fd 写） | uid 校验 + 可选 token | 路径冲突、陈旧 socket 文件、路径 ≤103B |
| 落盘收件箱 + 目录监听 | `[可得]` | 高 | 实测 §8.F；仓库先例 `TerminalTabFocuser.swift:17/93/97` | 无 | 有（回写响应文件，靠对端监听） | 目录权限 | 无连接状态、无回执、默认 0755 |
| CFMessagePort | `[可得]` | 高 | 实测 §8.D/§8.K | 无 | 有（客户端自建 port 后服务端反连） | 无内建鉴权 | 同名重复注册破坏服务名（status=-2） |
| NSXPCListener(machServiceName:) 非沙箱直接注册 | `[不可得]` | 高 | 实测 §8.B/§8.B3 | 无 | 有 | NSXPC 自带 audit token | 必须 launchd job 声明 MachServices |
| NSXPC + launchd job（MachServices） | `[可得]`（但要改部署形态） | 高 | 实测 §8.B4 | 无 | 有 | 同上 | 需常驻 LaunchAgent；`hai/CONTEXT.md:207` 现在明确不用 plist |
| 本机 HTTP（Network.framework NWListener） | `[可得]` 但触发 gate | 高 | 实测 §8.E | **需要 `import Network`** | 有（长连接/SSE） | 需自建 token | lint gate 红；默认绑全网卡（`*.47781`）；端口占用 |
| URL scheme | `[未验证]` | 中 | `build-app.sh:41-76` 无 `CFBundleURLTypes`；实测 `plutil` 无 url 键 | 无 | 无（单向拉起） | 无 | 每次唤起可能弹确认框；无法回执 |
| DistributedNotificationCenter | `[可得]` 但不建议 | 高 | 实测 §8.C | 无 | 有（广播） | **无** | 任何本机进程可发同名通知；无回执；无点对点寻址 |
| notify(3) / `notify_post` | `[未验证]` | 低 | 未实测；`import Darwin` 不在白名单 | `Darwin`（白名单外） | 有（广播） | 无 | 与 DistributedNotificationCenter 同类问题 |

### 2.2 逐项说明

#### a) Unix domain socket

- `[可得]` 置信度高。`import Foundation` 单独即可使用 POSIX API：`socket/bind/listen/accept/read/write/unlink`、`sockaddr_un`。
  - 反向实测：删掉 `import Foundation` 后 `sockaddr_un` 报 "cannot find type 'sockaddr_un' in scope"（§8.E4/E5）。所以这些符号来自 Foundation，不额外引入依赖。
- 外部进程可直接连：`nc -U <path>` 完成 request/response（§8.A），返回 `{"v":1,"ok":true,"server":"island"}`。协议与语言无关。
- 服务端主动推送：同一条连接上多次 `write` 即可，客户端收到两条事件（§8.J）。
- 并发：一个 accept 循环 + 每连接一个处理线程，3 个并发订阅者各自收到两条事件（§8.J）。
- 权限可收紧：目录 0700 + socket 0600 实测生效（§8.G）。
- 对端身份可查：`getpeereid` 返回 `peer_uid=501`；`getsockopt(SOL_LOCAL=0, LOCAL_PEERPID=2)` 返回 `peer_pid`（§8.G）。
- 约束：
  - `sun_path` 容量 104 字节。路径 103/104 字节可 bind；105/110 字节会被**静默截断**并落到截断后的名字上；200 字节因撞名报 errno 48（§8.L）。建议路径 ≤103 字节。
  - 陈旧 socket 文件：进程被杀不会自动清理，重 bind 报 errno 48（EADDRINUSE），此时 `connect` 报 errno 61（ECONNREFUSED）（§8.A3/§8.I）。
  - 天真的"启动先 unlink 再 bind"会**偷走**在跑实例的路径：两个实例的 socket inode 从 100175494 变为 100175496，客户端只连到第二个（§8.H）。

#### b) 落盘收件箱 + 目录监听

- `[可得]` 置信度高。DispatchSource 目录监听在文件被外部进程写入后 **约 3ms** 内触发（三次实测：3.3ms / 2.8ms / 3.1ms，§8.F）。
- 与既有 VS Code 握手同构，实现成本最低（§1.5）。
- 与 socket 的取舍：
  - 文件方案优势：崩溃恢复天然幂等（文件留在盘上）；不需要常驻 fd；插件侧实现只需一次 `writeFileSync`；不需要长连接管理。
  - 文件方案劣势：**没有连接概念**，服务端无法知道谁在订阅、无法主动推给指定客户端；没有回执语义（写入成功 ≠ 被处理）；没有背压/流控；多写者会互相覆盖同一个请求文件；响应文件需要清理机制；目录默认权限 0755（实测 `FileManager.createDirectory` 默认 493 = 0755，配 umask 022），必须显式收紧。
  - 延迟：不改 island 轮询则上限 3s（`AgentMonitor.swift:32`）；加 DispatchSource 目录监听后 ~3ms。
- 结论：作为**兜底**合适；作为主方案会让"服务端主动推送 + 订阅 + 回执"三件事都退化成轮询。

#### c) CFMessagePort

- `[可得]` 置信度高，且不需要新 import。
  - 请求/响应：`CFMessagePortSendRequest` 返回 status=0，reply `{"v":1,"ok":true}`（§8.D）。
  - 服务端推送：客户端自建 port 并把名字发给服务端，服务端 `CFMessagePortCreateRemote` 反连，两次 push 都 status=0 且客户端收到（§8.K）。
  - 实现必须在 run loop 上：`CFMessagePortCreateRunLoopSource` + `CFRunLoopAddSource`（探针如此，island 有主 run loop）。
- 风险：同名重复注册不会干净失败。第二次 `CFMessagePortCreateLocal` 返回成功，随后远端 lookup `status=-2`（§8.K1）。即冲突检测不可靠。
- 另有：名字注册在 per-user bootstrap 命名空间，无法用文件权限表达"谁能连"；无内建鉴权。

#### d) NSXPCListener(machServiceName:)

- `[不可得]` 置信度高（对 island 现状）。
  - 纯 CLI 注册 `com.commallama.island.ipc`：listener `resume()` 成功，但客户端 lookup 失败：`Connection init failed at lookup with error 3 - No such process.`（§8.B）。
  - 打包成 `.app`（bundleID `com.commallama.island.probe`）再试，同样失败（§8.B3）。所以"非沙箱 app 就能注册任意 mach 名"不成立。
  - 只有由 **launchd job 声明 MachServices** 时才行：`launchctl bootstrap` 后 `state = running`，客户端拿到 `reply=pong`（§8.B4）。
- 对 island 的含义：现状不是 launchd job（`hai/CONTEXT.md:207`：登录项走 `SMAppService.mainApp`，不是 LaunchAgent plist）。要用 XPC 就得改部署形态。
  - `[未验证]` 置信度中：用 `SMAppService.agent(plistName:)` 带 MachServices 子进程的可能性未实测。

#### e) 本机 HTTP（NWListener / 127.0.0.1）

- `[可得]` 但有两个硬成本。
  - 成本 1（gate）：需要 `import Network`。删掉后编译报 "cannot find 'NWListener' in scope"（§8.E4/E5）；`scripts/check-layering.sh:27-28` 的白名单不含 `Network`，lint gate 会红。要引入就得改 gate 脚本（AGENTS.md `Ask first`）。
  - 成本 2（安全）：不设 `requiredLocalEndpoint` 时绑 `*.47781`（全接口，netstat 实测），局域网可达；设成 `127.0.0.1` 才是仅本机（`lsof` 实测 `TCP 127.0.0.1:47778 (LISTEN)`）。
- curl 直连会失败（exit 1）：不是 HTTP 响应时 curl 报 unsupported protocol。用 `nc` 则拿到 `{"v":1,"ok":true}`（§8.E）。
- 与 UDS 相比多出端口占用、防火墙、误绑全网卡三类问题，收益只有"可以用浏览器/curl 调试"。

#### f) URL scheme

- `[未验证]` 置信度中（无法在不改仓库的前提下测注册）。
- 现状 `[不可得]`：`build/Island.app/Contents/Info.plist` 没有 `CFBundleURLTypes`（实测 `plutil -p` 无 url 键），生成脚本也没有（`scripts/build-app.sh:41-76`）。即 island **当前不提供任何 scheme**。
- 仓库已有决策：不用 `vscode://`，因为"VS Code 每次都弹确认框"。出处：`hai/CONTEXT.md:223`；同样的理由写在 `vscode-extension/extension.js:5-6`。
- 反向事实：island 是 `codex://`、`claude://` 的**使用方**。出处：`hai/CONTEXT.md:233-234`。
- 要确认可否作传输，实验：给 `Info.plist` 加 `CFBundleURLTypes` + 重签 + `lsregister`，然后 `open "island://notify?..."`，观察是否弹确认框、能否回执。
- 即使可用，这条路径也只能单向拉起、无法回执、无法订阅，不适合当主传输。

#### g) DistributedNotificationCenter

- `[可得]` 置信度高，且不需要新 import。
  - 跨进程实测：watcher 收到 `name`、`object=probe-sender`、`userInfo={"hello": "world"}`（§8.C）。
- 但不建议作主传输：
  - 无回执、无点对点寻址、无连接状态。
  - **无鉴权**：通知名是全局的，任何本机进程都能发 `island.*` 同名通知，也能监听 island 发的通知。
  - 广播语义与"回答某个具体客户端"的需求不匹配。

---

## 3. 推荐方案与语义

### 3.1 主方案：Unix domain socket

- 路径：`~/Library/Application Support/island/ipc/island.sock`（与既有 `…/island/vscode` 同根，`TerminalTabFocuser.swift:17-18`）。
  - 长度：本机实测该路径 60 字节，远低于 103 字节上限。
- 目录 `island/ipc` 建为 0700；socket 文件显式 `chmod 0600`（bind 后，见 §8.G）。
- 监听：`bind` + `listen(fd, 16)`；accept 循环放专用 `DispatchQueue`（不要在 `RunLoop.main` 上阻塞）；每个连接一个 `DispatchSourceRead` + 一个写队列。实测 3 并发连接与推送正常（§8.J）。

**端口/命名冲突**

- 冲突单位是 socket 文件路径，不是端口。
- 必须按下面顺序"认领"，否则会偷走在跑实例的路径（§8.H）：
  1. `bind` 成功 → 自己持有。
  2. `bind` 报 errno 48（EADDRINUSE）→ `connect` 探一次。
     - `connect` 成功 → 已有实例活着，退出（island 本来就有单实例语义，`AppDelegate.swift:46-49`）。
     - `connect` 报 errno 61（ECONNREFUSED）→ 陈旧文件，`unlink` 后重新 `bind`。
     - `connect` 报 errno 2（ENOENT）→ 文件已消失，重新 `bind`。
  - 上述三步全部实测（§8.A3/§8.I）。
- 多用户：socket 在各自 home 下，天然按用户隔离。

**并发连接**

- 上限：例如 16 个订阅者 + 32 个短连接。超限时对 `hello` 前的连接直接拒绝（回 error 后关）。
- 每连接状态机单线程消费，避免锁。
- 实测：3 个并发订阅者 + 服务端推送，无交叉（§8.J）。

**断线**

- 客户端进程崩溃：`read` 返回 0/EPIPE，服务端清掉该连接的订阅登记。
- 服务端重启：所有连接失效，客户端按指数退避（200ms 起、上限 5s）重连并重放 `hello` + `subscribe(since: last_seq)`。
- 写失败不阻塞其他连接：每连接独立写队列 + 上限（例如 256 KiB 未发完就断开）。

**app 重启后的重连语义**

- island 退出时 `unlink` socket 文件（正常退出路径）；被 `pkill -9` 时文件残留，由 §3.1 的认领流程兜住。
- `SIGTERM` 正常退出应广播 `server.bye` 事件再 unlink，让客户端立刻知道要重连，而不是等 read EOF。
- 客户端不得缓存 fd；每次重连重新 `connect`。
- 订阅者语义：`seq` 只保证"服务端已分配过的序号单调"，不保证补发历史（无持久化队列）。要补发就得落盘，超出当前 POC 范围。

### 3.2 兜底方案：文件收件箱 + 目录监听

- 目录 `~/Library/Application Support/island/ipc/inbox`，0700。
- 客户端原子写：写 `tmp-<uuid>.json` 再 `rename` 成 `req-<uuid>.json`（避免半写文件被读到）。
- island 用 DispatchSource 目录监听（实测 ~3ms，§8.F），读到 `req-*.json` 后处理，再把结果写 `res-<uuid>.json`，然后删请求。
- 覆盖不到的能力：推送只能靠"客户端也监听自己的响应文件"，订阅退化为客户端定时拉取；无连接状态；无背压。
- 适用场景：插件进程不方便常驻连接、或主方案不可用（例如将来加了沙箱）时。

### 3.3 不推荐清单与理由

- NSXPC：需要 launchd job + MachServices，与现有登录项形态冲突（`hai/CONTEXT.md:207`）。
- loopback HTTP：`import Network` 触发 lint gate，且默认绑全网卡。
- URL scheme：单向下拉、可能弹确认框（`hai/CONTEXT.md:223`）。
- DistributedNotificationCenter：无鉴权、无回执，任何本机进程可伪造。

---

## 4. 协议草案（只写字段与语义）

### 4.1 帧格式

- 一行一个 JSON 对象，UTF-8，以 `\n` 结尾。单行上限 64 KiB，超限回 `too_large` 并关连接。
- 不用 length-prefix：NDJSON 可用 `nc` / `echo` 手测（§8.A 就是这么测的），也便于插件侧用一行 `writeFileSync` 复用同一套编解码。
- 顶层字段命名统一：请求用 `v/id/method/params`；回执用 `v/id/ok/error/result`；事件用 `v/event/seq/data`。

### 4.2 hello（必须第一个方法）

请求：
| 字段 | 类型 | 语义 |
|---|---|---|
| `v` | int | 协议主版本，当前 `1` |
| `method` | string | `"hello"` |
| `params.client` | string | 客户端名，例如 `island-vscode`、`plugin.demo` |
| `params.protocol` | int | 客户端支持的主版本 |
| `params.token` | string? | 可选共享 token（见 §5） |
| `params.pid` | int? | 客户端自报 pid，仅用于日志与限流，不作为身份 |

回执 `result`：
| 字段 | 类型 | 语义 |
|---|---|---|
| `server` | string | `"island"` |
| `version` | string | app 版本（`CFBundleShortVersionString`） |
| `protocol` | int | 服务端主版本 |
| `methods` | string[] | 允许的方法集合 |
| `events` | string[] | 允许订阅的事件名 |
| `session` | string | 本次连接的会话 id（日志关联用） |
| `limits` | object | `{max_frame_bytes, max_subscriptions, idle_timeout_seconds}` |

语义：`hello` 之前的任何方法一律 `unauthorized`；版本主号不同一律 `bad_version` 并关连接。

### 4.3 notify（单向通知 + 回执）

| 字段 | 类型 | 语义 |
|---|---|---|
| `v` | int | `1` |
| `id` | string | 请求 id，回执原样带回 |
| `method` | string | `"notify"` |
| `params.kind` | string | 事件类别，白名单枚举，例如 `task.finished` |
| `params.title` | string? | 展示用标题 |
| `params.client_event_id` | string | 由客户端生成的 UUID，用于幂等去重 |
| `params.payload` | object? | 只允许作为**数据**出现的字段，绝不解释为命令 |

回执：`ok:true` + `result.duplicate:true|false`（去重命中时为 true，不重复入库）。

### 4.4 query（读取 island 已知状态，只读）

| 字段 | 类型 | 语义 |
|---|---|---|
| `method` | string | `"query"` |
| `params.what` | string | 白名单枚举：`status`、`unread`、`tasks`、`capabilities` |
| `params.limit` | int? | 返回条数上限 |

回执 `result`：
| 字段 | 类型 | 语义 |
|---|---|---|
| `query` | string | 回显 `what` |
| `items` | object[] | 任务行：`id/agent/title/cwd/completed_at/host/resume_command`（`cwd` 与 `title` 视为敏感，见 §5） |
| `truncated` | bool | 是否被 `limit` 截断 |

语义：只读、无副作用；**不接受**路径、URL、shell 片段、bundle id 作为输入。

### 4.5 subscribe / unsubscribe（服务端推送）

请求：
| 字段 | 类型 | 语义 |
|---|---|---|
| `method` | string | `"subscribe"` 或 `"unsubscribe"` |
| `params.events` | string[] | 订阅的事件名（白名单） |
| `params.since_seq` | int? | 客户端已收到的最大 `seq`；仅用于让服务端判断是否发生丢弃，不保证补发 |

回执 `result`：`{subscribed:[...], max_subscriptions:int}`。

事件帧（服务端→客户端，无 `id`，不需要回执）：
| 字段 | 类型 | 语义 |
|---|---|---|
| `v` | int | `1` |
| `event` | string | `task.finished` / `task.read` / `task.removed` / `server.bye` |
| `seq` | int | 本连接内单调递增；客户端检测跳号即知有丢弃 |
| `data` | object | 事件负载，字段与 §4.4 的 `items` 同构 |

### 4.6 回调回执

- 请求-响应：`id` 配对，服务端必须回一帧（成功或错误），不能静默。
- 长任务：先回 `ok:true` + `result.pending:true`，完成后用事件帧 `event:"task.read"` 之类告知；**不引入第二套回调地址**。
- 客户端发 `subscribe` 后，服务端在同一连接推事件，不需要客户端再注册端口（这是 UDS 相对 CFMessagePort 的优势，后者需要客户端自建 port）。

### 4.7 鉴权（详见 §5）

- 传输层：`getpeereid` 校验 `peer_uid == getuid()`；不等直接关连接。
- 应用层：可选 token。island 首次启动生成 32 字节随机 token，写 `~/Library/Application Support/island/ipc/token`（0600）。`hello.params.token` 不匹配时只允许 `query(what:"status")`，其余回 `unauthorized`。
- 环境变量开关与仓库惯例一致（`hai/CONTEXT.md:191`：所有行为开关走 `ISLAND_*`）：`ISLAND_IPC=off|token|open`、`ISLAND_IPC_PATH=<path>`。

### 4.8 版本协商

- 主版本不同：拒绝（`bad_version`），并在 `error.detail` 里给服务端支持的版本号。
- 次版本差异通过 `hello.result.methods/events/limits` 表达能力，客户端只调用列出的方法。
- 服务端新增事件名时，旧客户端订阅不到不会报错（订阅白名单过滤）。

### 4.9 幂等与去重

- `notify` 必带 `client_event_id`。服务端保留最近 512 个（client + event_id）的 LRU 窗口，命中即 `duplicate:true` 且不再入库。
- `query` 天然幂等。
- `subscribe` 重复订阅同一事件名视为覆盖，不叠加计数。
- 重连重放：客户端重发未收到回执的请求（同 `id`、同 `client_event_id`）；服务端按 `id` + `client_event_id` 双重去重。

### 4.10 错误码

`bad_version` / `unauthorized` / `unknown_method` / `bad_params` / `too_large` / `rate_limited` / `not_subscribed` / `internal`。

---

## 5. 安全模型

### 5.1 路径与权限

- 目录 `~/Library/Application Support/island/ipc` → 0700。
- socket → 0600（bind 后显式 chmod；实测生效，§8.G）。
- token 文件 → 0600。
- 不要放 `/tmp`。对照：本机 `/tmp/aha-atrpc-<uuid>.sock` 是 mode 755（`lsof` 显示属 Feishu，pid 83508），其他本机用户可写。

### 5.2 谁能连

- 文件权限层面：0600 表示只有 owner 可写，`connect` 需要写权限 → 仅 owner。
  - `[未验证]` 置信度中：跨用户连接被拒未实测（需要第二个本机账号）。推断依据是 POSIX 的 `connect` 权限检查 + 实测 mode 0600。
- 进程层面：`getpeereid` 校验 `peer_uid`，双保险。
- pid（`SO_LOCAL_PEERPID`，实测可得）只用于日志/限流/审计，不作为授权依据（pid 可复用）。

### 5.3 token 还是 uid

- 两者都要，各有分工：
  - uid 挡的是"别的用户"。
  - token 挡的是"同一用户下的任意进程"——例如一个被下载的脚本、一个有漏洞的编辑器插件，都能以你的 uid 连上来。
- token 只在用户显式把路径告诉插件时使用（例如插件配置里填 token 文件路径）。

### 5.4 绝不放行的命令

- 任何形式的执行：`exec` / `shell` / `run` / `eval`。
- 任何"参数即目标"的动作：打开 URL、打开文件路径、`open -b <bundle>`、写 tty、发 AppleScript。这些在 island 里已经存在（`TerminalTabFocuser.swift:106-109`、`Subprocess.appleScript`），绝不能把这些能力暴露成 IPC 方法。
- 改设置里的可执行路径、改登录项、触发升级、退出/重启 app。
- 读任意文件：只允许 `query` 白名单里的 island 已知状态。

### 5.5 被恶意本地进程滥用的最坏影响

- 伪造 `notify(kind:"task.finished")` → 弹窗骚扰、菜单栏未读数虚增。用户可关弹窗（`hai/CONTEXT.md:244`），菜单栏未读数不可关。
- 伪造 `query(what:"tasks")` → 读到任务标题、cwd、agent 名。属中敏感（cwd 泄露目录结构）。
- 每个客户端开多个 `subscribe` → 占 fd/内存。靠每连接上限 + 总订阅上限 + `rate_limited` 兜住。
- 不会发生：任意命令执行、任意文件读写、提权。前提是 §5.4 的白名单被严格执行。

### 5.6 必须避免复制的既有弱点

- 现有 VS Code 握手把**响应文件里的路径**直接交给 `open -b com.microsoft.VSCode <path>`（`Sources/Island/TerminalTabFocuser.swift:106-109`），而那个目录是默认权限创建的（`FileManager.createDirectory` 默认 0755 实测；`umask` 022）。
  - 推断：任何本机同用户进程都能写一个 `focus-response-<id>.json` 诱导 island 执行 `open`。
  - 结论：新的 IPC 目录显式 0700/0600，且 IPC 参数一律当数据，不做"路径 → 动作"的转换。

---

## 6. 可测试性落点（IslandCore vs Sources/Island）

### 6.1 放 IslandCore（必须 100% 覆盖）

- NDJSON 编解码：一行 JSON ↔ 强类型信封。只用 `Foundation`，符合 `check-layering.sh:16`。
- 信封与枚举：`InboundRequest` / `Reply` / `Event` / `Method` / `EventName` / `ErrorCode`。
- 状态机：`idle → helloed → ready → subscribed → closed`，以及非法转移的拒绝。
- 幂等窗口：LRU 去重（输入是 `(client, event_id)`，纯值）。
- 版本协商：`negotiate(clientProtocol:serverProtocol:)`。
- 鉴权判定：输入是 `peerUID`、`selfUID`、`token`、`expectedToken`，输出是"允许的方法集合"。**uid/token 的读取（syscall、读文件）不在这一层**。
- 限流计数、帧大小校验、seq 分配。
- 理由：这些都是纯决策，与现有 `AgentInbox`、`TaskVisibility`、`AgentReopen` 的定位一致（`hai/CONTEXT.md:121-131`），且基线 100% 要求任何新增行都有测试。`hai/CONTEXT.md:98` 明确"任何决策逻辑都不该写在 Sources/Island"。

### 6.2 放 Sources/Island（整文件进 coverage.config）

- `socket/bind/listen/accept`、`unlink`、路径与权限设置、`chmod`。
- `getpeereid` / `getsockopt(LOCAL_PEERPID)` 的读取。
- `DispatchSourceRead` / 写队列 / accept 循环。
- 与 `AppDelegate` 的接线（启动时起监听、退出时 unlink + 广播 `server.bye`）。
- 理由：fd 与事件源无法在纯断言里稳定覆盖（要么 flaky，要么落进 AGENTS.md 的排除类）。
- 交付时必须同步做两件事：
  1. 新文件路径加进 `coverage.config`（`coverage.config:16`、`hai/CONTEXT.md:196`）。
  2. 不新增白名单外的 import（`check-layering.sh:27-28`）。

### 6.3 边界上的两个具体建议

- **不要为了"好测"把 fd 传进 IslandCore**。测试替身用"已解码的帧 + 已读到的 uid/token"驱动状态机，传输层自己用集成测试或 `nc` 手测。
- **不要新增 `import Network`**。若将来确实要 loopback HTTP，先改 `scripts/check-layering.sh`，这属于 AGENTS.md 的 `Ask first`。

---

## 7. 与既有生态的对照

### 7.1 Claude Code 的 `messagingSocketPath`

- 仓库依据：`hai/reference/agents/README.md:51` 的 session json 样本含 `"messagingSocketPath":"/tmp/cc-socks/83859.sock"`；那是**上游作者机器**（`/Users/binyanli/Repos/island`，见同文件 `:49`）的样本。
- 本机实测 `[不可得]` 置信度高：
  - `~/.claude` 不存在（`ls -la ~/.claude` 空）。
  - 无 claude 进程（`ps aux | grep claude` 空）。
  - `/tmp/cc-socks` 不存在。
  - 所以**无法**在本机验证"这个 socket 是否能被外部连接"。
- 可确认的仅限：该字段存在于该版本 Claude Code 的 session json 里，路径形态是 `/tmp/cc-socks/<pid>.sock`。
- `[未验证]` 要确认需要：本机安装 Claude Code、跑一个会话，然后 `ls -la /tmp/cc-socks/` + `nc -U` 试探。
- 对本方案的启示：agent 侧确实倾向"每进程一个 socket 文件，路径里带 pid"。island 作为 server 可以借鉴命名方式，但 island 只有一个实例，用固定路径更简单（冲突处理见 §3.1）。

### 7.2 本机其它 socket 先例

- `/tmp/aha-atrpc-317b2297-….sock`：mode 755，`lsof` 显示属 `Feishu`（pid 83508）。证明第三方 app 在 `/tmp` 放 UDS 是常见做法，但 755 是坏实践。
- `/var/folders/.../T/vscode-git-*.sock`：VS Code 的 git 集成 socket，同样在临时目录。
- cmux：`hai/CONTEXT.md:223` + `hai/issue/2026-09-25-15-43-43-reopen-precise-terminal-tab.md:26-31` 记录 cmux socket 默认只允许 cmux 内进程连接（island 实测 `Access denied`）。这是"UDS + 客户端白名单"的真实案例；反过来 island 当 server 时也必须自己做鉴权。

### 7.3 island 与插件/扩展的既有通道

- VS Code 扩展：目录 + 请求文件 + 响应文件（§1.5）。已是双向，但靠轮询 + 文件出现表达结果。
- 无 VS Code 的其它场景：island 只读别人的落盘文件（`Sources/Island/AgentMonitor.swift`），没有入站通道。
- 所以 task-2 的插件机制如果不复用本方案，就得重复一次"目录权限 + 轮询 + 无回执"的取舍。

### 7.4 URL scheme 对照

- island 使用别人的 scheme：`codex://threads/<id>`、`claude://claude.ai/chat/<uuid>`（`hai/CONTEXT.md:233-234`）。
- island 自己没注册：`build-app.sh:41-76` 无 `CFBundleURLTypes`，实测 `plutil -p` 无 url 键。

---

## 8. 实测命令与原始输出

全部原始输出：`.build/probe/ipc/RESULTS.log`（209 行，`bash .build/probe/ipc/run_all.sh` 可重放）。
探针源码：`.build/probe/ipc/*.swift`（每个都能用 `xcrun swiftc -O -o bin_X X.swift` 单独编译）。

### 8.A UDS：外部 `nc -U` 客户端往返

```
$ ./bin_uds_server run/a/island.sock &
-- socket file while listening:
srwxr-xr-x@ 1 boss  staff  0 … run/a/island.sock
$ printf '{"v":1,"method":"notify","id":"nc-1"}\n' | nc -U run/a/island.sock
{"v":1,"ok":true,"server":"island"}
nc exit=0
-- server:
listening path=…/run/a/island.sock mode=755
server read 38 bytes: {"v":1,"method":"notify","id":"nc-1"}
server replied
```

### 8.A3 陈旧 socket 与不存在路径

```
$ ./bin_uds_bindstrict run/a/stale.sock     # 服务端被 kill -9，文件残留
bind-without-unlink FAILED errno=48 (Address already in use)
$ ./bin_uds_client run/a/stale.sock
connect=-1 errno=61     # ECONNREFUSED
$ ./bin_uds_client run/a/nope.sock
connect=-1 errno=2      # ENOENT
```

### 8.E4/E5 import 依赖（gate 相关）

```
$ swiftc uds_noimport.swift        # 删掉 import Foundation
error: cannot find type 'sockaddr_un' in scope
$ swiftc nw_noimport.swift         # 删掉 import Network
error: cannot find 'NWListener' in scope
```

### 8.G 对端身份与显式权限

```
listening mode=600 dir_mode=700
getpeereid=0 peer_uid=501 peer_gid=20 self_uid=501
getsockopt(LOCAL_PEERPID)=0 peer_pid=82186 errno=3   # errno 是残留值，调用返回 0 即成功
```

### 8.H 命名冲突：天真 unlink 会偷走在跑实例的路径

```
$ ./bin_uds_server run/h/steal.sock &   # 第一个实例
$ ./bin_uds_server run/h/steal.sock &   # 第二个实例（启动时 unlink 再 bind）
socket inode first=100175494 second=100175496 (changed => the second instance stole the path)
$ printf 'to-whom\n' | nc -U run/h/steal.sock
{"v":1,"ok":true,"server":"island"}     # 只连到第二个实例
```

### 8.I 重启恢复流程

```
$ ./bin_uds_bindstrict run/i.sock       # 陈旧文件
bind-without-unlink FAILED errno=48 (Address already in use)
$ ./bin_uds_client run/i.sock
connect=-1 errno=61                     # 探测：无人监听
$ rm -f run/i.sock && ./bin_uds_server run/i.sock &
$ printf 'after-recovery\n' | nc -U run/i.sock
{"v":1,"ok":true,"server":"island"}
```

### 8.J 三并发订阅 + 服务端推送

```
-- client A:
[A] received: {"event":"task.finished","seq":1}
[A] received: {"event":"task.finished","seq":2}
-- server:
server got: {"v":1,"method":"subscribe"}   ×3
server pushed event 1 ×3 / event 2 ×3
```

### 8.F 目录监听延迟（三次）

```
wrote at 1792308720.866126
wrote at 1792308721.3085282
wrote at 1792308721.757032
fs event mask=FileSystemEvent(rawValue: 2) at 1792308720.869144   # +3.0ms
fs event mask=FileSystemEvent(rawValue: 2) at 1792308721.3115048  # +3.0ms
fs event mask=FileSystemEvent(rawValue: 2) at 1792308721.7606149  # +3.6ms
```

### 8.B / 8.B3 NSXPC 直接注册失败

```
xpc server: resumed machServiceName=com.commallama.island.probe.ipc bundleID=<none>
xpc client: proxy error: … "The connection to service named com.commallama.island.probe.ipc
  was invalidated: Connection init failed at lookup with error 3 - No such process."
xpc client: TIMEOUT waiting for reply (invalidated=true)
-- 打包成 .app 后（bundleID com.commallama.island.probe）同样失败
```

### 8.B4 NSXPC + launchd MachServices 成功

```
$ launchctl bootstrap gui/501 …/com.commallama.island.probe.xpc.plist
bootstrap exit=0
	state = running
	pid = 82657
$ ./bin_xpc_client com.commallama.island.probe.mach
xpc client: reply=pong
client exit=0
$ launchctl bootout gui/501/com.commallama.island.probe.xpc   # 实验后已清理
job removed
```

### 8.D / 8.K CFMessagePort

```
CFMessagePortSendRequest status=0
cfmp reply: {"v":1,"ok":true}
-- 服务端推送（客户端自建 port）:
server push 1 status=0 / server push 2 status=0
CLIENT got pushed: {"event":"task.finished","seq":1}
CLIENT got pushed: {"event":"task.finished","seq":2}
-- 同名重复注册:
first registration ok
second registration SUCCEEDED ({locked = Maybe, valid = Yes, remote = No, …})
lookup status=-2 answered_by=-      # 名字不可用了，且第二次注册没报错
```

### 8.E NWListener

```
$ lsof -nP -iTCP:47778     # 设了 requiredLocalEndpoint(127.0.0.1)
bin_nw_li 82337 boss    3u  IPv4 … TCP 127.0.0.1:47778 (LISTEN)
$ printf 'hello\n' | nc -w 2 127.0.0.1 47778
{"v":1,"ok":true}
-- 不设 requiredLocalEndpoint:
tcp46  0  0  *.47781  *.*  LISTEN      # 全接口
```

### 8.L 路径长度

```
-- requested path_len=103 → bind OK; file exists=true
-- requested path_len=104 → bind OK; file exists=true
-- requested path_len=105 → copied=104; bind OK; file exists=false   # 静默截断
-- requested path_len=110 → copied=104; bind OK; dir_entries=2       # 截断后与上一条同名
-- requested path_len=200 → bind FAILED errno=48 (Address already in use)
```
（`sun_path` 容量实测 104 字节；脚本每轮清理 socket 文件，输出可重放。）

### 8.C DistributedNotificationCenter

```
$ ./bin_distnote_watch com.commallama.island.probe.26744 &
watching com.commallama.island.probe.26744
$ ./bin_distnote_post com.commallama.island.probe.26744
posted com.commallama.island.probe.26744
distnote received name=com.commallama.island.probe.26744 object=Optional(probe-sender)
  userInfo=Optional([AnyHashable("hello"): world])
```

### 8.M 权限默认值（文件方案相关）

```
$ ./bin_fmtest run/fmtest     # FileManager.createDirectory(withIntermediateDirectories:)
created; mode=493             # 493 = 0o755
drwxr-xr-x run/fmtest
umask=0022
```

---

## 9. 不确定项清单

### `[不可得]`

| 项 | 被什么挡住 | 依据 |
|---|---|---|
| NSXPCListener(machServiceName:) 在非 launchd 进程直接对外注册 | 平台机制：名字必须由 launchd job 的 MachServices 声明 | §8.B/§8.B3 实测 lookup error 3 |
| 本机验证 Claude Code `messagingSocketPath` | 本机没装 Claude Code（无 `~/.claude`、无进程） | §7.1 |
| island 当前的 URL scheme | Info.plist 没注册 scheme | `build-app.sh:41-76` + `plutil` 实测 |

### `[未验证]`

| 项 | 要做什么实验才能确认 |
|---|---|
| Developer ID + hardened runtime 下 UDS/CFMessagePort/目录监听仍可用 | `ISLAND_SIGN_IDENTITY="Developer ID Application: …" ./scripts/build-app.sh` 后重跑 `run_all.sh` |
| 0600 socket 是否真的拒绝其它本机用户连接 | 建第二个本机账号，`su` 过去 `nc -U` 试探 |
| `SMAppService.agent(plistName:)` + MachServices 能否给 island 提供 XPC | 写一个 LaunchAgent plist 进 bundle，注册后 `launchctl print` 看 MachServices，再跑 `bin_xpc_client` |
| 自定义 URL scheme 是否弹确认框、能否回执 | 给 Info.plist 加 `CFBundleURLTypes`，`lsregister -f`，`open "island://…"` 观察 |
| 真实 island 进程里 DistributedNotificationCenter 的投递延迟 | 在 accessory app 内发/收一次并打时间戳（本次只在 CLI 进程间测过） |
| 长连接在 island 被 `pkill -9` 后客户端的重连时延 | 起真实监听后 kill，测客户端重连到新实例的耗时 |
| 速率限制阈值（多少 `notify`/秒算滥用） | 需要先有真实插件负载 |

### 仓库内无证据

- island 现有代码里没有任何 socket / XPC / DistributedNotification / NWListener 的使用（`grep -rn 'socket|XPC|DistributedNotification|CFMessagePort|NWListener|FSEvent|DispatchSource' Sources` 只命中 `AgentMonitor.swift:6` 的注释）。
- 没有 `docs/` 下的 IPC 设计文档（`docs/` 只有 `demo.gif`）。

---

## 10. 给 task-2（插件机制）的复用约定

已先行同步给 plugin-architect，正式版以此为准：

1. 传输：Unix domain socket，路径 `~/Library/Application Support/island/ipc/island.sock`（目录 0700、socket 0600）。
   - 插件若不能常驻连接，退到 §3.2 的文件收件箱，但必须用同一套 NDJSON 信封。
2. 信封：单行 JSON + `\n`。请求 `v/id/method/params`；回执 `v/id/ok/error/result`；事件 `v/event/seq/data`。
3. 方向：`hello` → `notify`（单向 + 回执）/ `query`（要 result）/ `subscribe`（同一条连接上收事件）。服务端不做反向拨号。
4. 插件侧字段名不得另起一套；新增方法/事件名要同时更新 `hello.result.methods/events` 白名单与 IslandCore 的枚举（100% 覆盖）。

---

## 附：本文件依据的仓库行号索引

| 事实 | 出处 |
|---|---|
| 双 target、IslandCore 纯逻辑 | `Package.swift:9-11` |
| IslandCore 禁 UI 框架 | `scripts/check-layering.sh:16` |
| Sources/Island import 白名单 | `scripts/check-layering.sh:27-28` |
| 覆盖率排除项逐个文件 + 新增文件必须登记 | `coverage.config:16-40`、`hai/CONTEXT.md:95-98`、`hai/CONTEXT.md:196` |
| 无 app-sandbox，只声明 apple-events | `scripts/Island.entitlements:1-11` |
| hardened runtime 只在 Developer ID 分支 | `scripts/build-app.sh:86`、`:90` |
| Info.plist 无 URL scheme | `scripts/build-app.sh:41-76` |
| accessory app / LSUIElement | `scripts/build-app.sh:65-66`、`Sources/Island/main.swift:163` |
| 主 run loop | `Sources/Island/main.swift:160-164` |
| 单实例语义 | `Sources/Island/AppDelegate.swift:46-49` |
| 轮询间隔 3s | `Sources/Island/AgentMonitor.swift:32` |
| 定时器挂主 run loop | `Sources/Island/AgentMonitor.swift:49-56` |
| monitor 构造（未覆盖间隔） | `Sources/Island/AppDelegate.swift:153-164` |
| 前台切换补一轮 | `Sources/Island/AppDelegate.swift:169-173` |
| VS Code 握手目录/请求/响应 | `Sources/Island/TerminalTabFocuser.swift:17-18`、`:93`、`:97` |
| 握手轮询 50ms / 1.0s 超时 | `Sources/Island/TerminalTabFocuser.swift:20-21`、`:102-118` |
| 扩展侧 fs.watch / 响应文件 | `vscode-extension/extension.js:64`、`:71-73` |
| 不用 URI 的决策 | `hai/CONTEXT.md:223`、`vscode-extension/extension.js:5-6` |
| 登录项走 SMAppService.mainApp | `hai/CONTEXT.md:207` |
| cmux socket 默认只许 cmux 内进程 | `hai/CONTEXT.md:223`、`hai/issue/2026-09-25-15-43-43-reopen-precise-terminal-tab.md:26-31` |
| Claude Code `messagingSocketPath` 样本 | `hai/reference/agents/README.md:49-51` |
| island 使用 codex:// / claude:// | `hai/CONTEXT.md:233-234` |
| BaseFile 环境变量开关惯例 | `hai/CONTEXT.md:191` |
| 决策逻辑不进 Sources/Island | `hai/CONTEXT.md:98` |
