# island 主动通知 / 插件机制 / 智能体快速切换 —— 需求规划与可行性方案

- 状态：已确认（2026-10-18）。综合稿经过一次对抗性复核，查出 3 高 / 9 中 / 8 低问题，已全部修掉。
- 一手输入：`ipc.md`（693 行）、`plugin.md`（475 行）、`panel.md`（419 行）。探针源码与原始输出在构建目录 `.build/probe/`，未入库；各文档的实测章节已抄录关键原始输出。
- 标记约定：`[可得]` / `[不可得]` / `[未验证]` + 置信度（高/中/低）；无出处判断标“推断:”
- 本机环境：macOS 27.0.1、Xcode 27.1、Swift 6.4、`swift build` 通过
- 本机正在跑的 `/Applications/Island.app` 是**本地构建的 0.0.0 版、ad-hoc 签名**（`plutil` 得 `CFBundleShortVersionString=0.0.0`；`codesign -dvvv` 得 `flags=0x2(adhoc)`、`TeamIdentifier=not set`；`brew info --cask island` 报 cask 不存在）。发布版 0.2.3（Developer ID + hardened runtime）只被静态检查过，未安装、未运行。

---

## 0. 结论摘要

1. 三条需求都能实现，且**不需要第三方依赖**；**不需要新 entitlements**（无 app-sandbox，`scripts/Island.entitlements:1-11` 只声明 apple-events）。`[可得]` 高
2. 三条需求分两条线：A 线（R1 入站通道）与 B 线（R2/R3 插件与面板）。**声明式插件与面板不依赖 A 线；进程插件依赖 A 线的 socket**，所以"只做 B 线"时要放弃进程插件那一段。`[可得]` 高（`plugin.md:13-14,114`）
3. 主通道 = **Unix domain socket + 行分隔 JSON**，路径 `~/Library/Application Support/island/ipc/island.sock`，目录 0700、socket 0600。`[可得]` 高（`.build/probe/ipc/RESULTS.log:21-30,75-98`）
4. **进程内 dylib 插件方案否决**：发布版是 Developer ID + hardened runtime，dlopen 异 Team ID 或 ad-hoc 的 dylib 必败。开发机是 ad-hoc 反而能加载，是"开发通过、发布失败"的陷阱。`[可得]` 高（`.build/probe/plugin/libval/`、`evidence-codesign.txt`）
5. 插件分两层：**声明式 manifest（无代码）** + **独立进程（回连同一 socket）**，共用一套发现/启用/生命周期。`[推断:]` 中（依据：`plugin.md` §2 的淘汰结果）
6. 第一个真实客户端已经存在：用户的 DSH 插件 `dsh-system-notify`，desktop 与 web 两个 profile 都已链接（`~/.dsh/profiles/{desktop,web}/node_modules/dsh-system-notify`），现在用 `execFile("terminal-notifier", …)`（`lib/index.js:159`）。改成调 island CLI（或直连 socket）即可端到端验证。`[可得]` 高
7. 三条需求**都没有 `hai/PLAN.md` 的 scope 依据**（`hai/PLAN.md:22-34` 只覆盖"检测本机 agent 完成任务 + 回到任务"）。改 PLAN 只有人能改，属 Ask first。这些需求属于 PLAN 未覆盖的新需求。

---

## 1. 需求拆解

| 编号 | 用户原话 | 拆成什么 | 依赖 |
|---|---|---|---|
| R1 | 其他应用主动通知 island，两者能相互通信；client-server，应用是 server | 入站通道：传输 + 协议 + 客户端门面（CLI / skill） | 无 |
| R2 | 内置功能以插件方式接入；规定插件样式/模式/接入方式；提供开发插件的 skill | 插件机制：manifest + 生命周期 + 权限模型 + 开发 skill | 与 A 线共享协议；只有进程插件依赖 A 线 |
| R2-例 | 悬浮窗快速输入 → 打开对应 chat 智能体（deepseek/kimi，可选可配） | 启动器：目标清单 + compose 输入 + URL 打开 | 依赖 R2 的目标数据模型 |
| R3 | 面板展示已安装智能体，快速切换，内部快捷键打开 | 目标探测 + 启动器 section + 每目标全局键 | 依赖 R2 的目标数据模型 |

**本次不做**（写清以免默认扩张）：

- 跨平台（PLAN § Non-goal，`hai/PLAN.md:18-20` 已定 macOS only）
- 给 island 加沙箱（会破坏现有 osascript / ps / lsof 能力）
- KMP 或其他架构重写
- 面向第三方开发者的插件市场 / 分发渠道
- 订阅事件的历史补发（需要落盘队列，POC 不做）
- 辅助功能（AX）注入粘贴（见 §2.3）
- 插件自带的全局快捷键（`plugin.json` 的 `hotkey` 字段只登记、不注册，见 `plugin.md:220`）。R3 的每目标快捷键是 island 原生功能，不走插件申请。

---

## 2. 可行性判定

### 2.1 R1 入站通道

| 候选 | 结论 | 置信度 | 依据 |
|---|---|---|---|
| Unix domain socket | `[可得]`，主方案 | 高 | `import Foundation` 即够，不需新依赖、不动 lint 白名单（`scripts/check-layering.sh:27-28`）；外部 `nc -U` 打通 request/response；3 并发订阅 + 服务端推送通过（`.build/probe/ipc/RESULTS.log:21-30,75-98`） |
| 落盘收件箱 + 目录监听 | `[可得]`，兜底 | 高 | 仓库已有同构先例（`Sources/Island/TerminalTabFocuser.swift:17-18,93,97`）；DispatchSource 目录监听延迟实测约 3 ms（`RESULTS.log:136-143`） |
| CFMessagePort | `[可得]`，不推荐 | 高 | 双向 + 推送可测（`RESULTS.log:105-123`）；同名重复注册不报错、随后 lookup status=-2 |
| NSXPC（直接注册 mach service） | `[不可得]` | 高 | CLI 与 .app 两种形态都 lookup error 3（`RESULTS.log:145-158`）；只有 launchd job 声明 MachServices 才通（`:161-170`） |
| loopback HTTP（NWListener） | 不推荐 | 高 | 需 `import Network`，破 lint 白名单；不设 requiredLocalEndpoint 实测绑全网卡 `*.47781`（`RESULTS.log:131-133`） |
| URL scheme | `[不可得]`（现状） | 高 | Info.plist 无 `CFBundleURLTypes`（`scripts/build-app.sh:41-76`）；且 `hai/CONTEXT.md:223` 已有"不用 URI"决策 |
| DistributedNotificationCenter | 不推荐 | 高 | 可跨进程投递（`RESULTS.log:103`），但无鉴权、无回执，任何本机进程可伪造同名通知 |

双向通信的两个方向都实测过：请求-响应靠 `id` 配对；服务端推送靠 `subscribe` 后在**同一条连接**上继续 write。`[可得]` 高

命名冲突有一条硬坑：启动时"先 unlink 再 bind"会偷走在跑实例的 socket（实测 inode 改变，客户端只连到第二个）。正确认领顺序：`bind` 失败 EADDRINUSE(48) → `connect` 探一次 → ECONNREFUSED(61) 判定陈旧再 unlink 重绑，成功则说明已有实例、直接退出。`[可得]` 高（`RESULTS.log:39-45,55-73`）

安全边界：`getpeereid` 拿 `peer_uid`、`getsockopt(LOCAL_PEERPID)` 拿 pid，实测均可得（`RESULTS.log:47-52`）；pid 只用于日志，不作授权依据。`[可得]` 高

签名影响：**没有**。无 app-sandbox，UDS 与文件 IO 不受 hardened runtime 约束。`[未验证]` 中：Developer ID 构建下重跑同一组探针才能确认（本机无法做，见 §8）。

### 2.2 R2 插件机制

| 形态 | 结论 | 依据 |
|---|---|---|
| 进程内 dylib | 否决 | 发布版 `flags=0x10000(runtime)` + `TeamIdentifier=C7QG7K23D7`；hardened 进程加载未签名/ad-hoc/异 Team ID 的 dylib 全部失败；`DYLD_*` 被忽略。`[可得]` 高（`.build/probe/plugin/libval/`、`evidence-codesign.txt`） |
| XPC service | 否决 | 同上 §2.1 NSXPC；内嵌 `Contents/XPCServices` 要改 `scripts/build-app.sh:32-39` 并整体重签 |
| 独立进程 + 同一 socket | 采用 | 崩溃/超时/卡死在 island 侧可兜；零依赖；不经 launchd |
| 纯声明式 manifest | 采用（范围受限） | 与既有 `AgentProfile`（`Sources/IslandCore/AgentProfile.swift:52-72`）同思路；但 `AgentKind` 是编译期 enum（`Sources/IslandCore/AgentTask.swift:5-10`）。`[推断:]` 高：声明式插件只能改既有行为，不能新增 agent 类型或新检测器 |
| JavaScriptCore 进程内 | 备选 | JSC 是系统框架，但 `Sources/Island` 的 import 白名单要改（`scripts/check-layering.sh:27-28`）——改白名单属 Ask first（`ipc.md:145,413`） |
| `jsc` 子进程 | 备选 | 零改动、零覆盖率影响 |
| WASM | 否决 | 无系统 runtime，必须引第三方，破"零第三方依赖"（`README.md:55`、`hai/CONTEXT.md:11`） |

补充：hardened 父进程用 `posix_spawn` 拉起 ad-hoc 子进程可正常执行（`.build/probe/plugin/` probe F）。`[可得]` 高 —— 这是"独立进程插件"可行的关键一环。

### 2.3 R2 举例：打开 chat 并带上问题

| 策略 | 结论 | 依据 |
|---|---|---|
| URL 模板 / 查询参数 | `[可得]`（静态源码级） | DeepSeek 网页主 bundle 读 `q`（`prompt` 兜底），另有 `mode`/`search`/`thinking`/`autosend`/`source`；`autoSend:"1"===e.get("autosend")&&r.length<=800`。置信度 高，但**是第三方 minified bundle 的静态读取，不是运行实测**（`.build/probe/panel/deepseek_main.js`，1.59 MB；`panel.md:232,241-260`） |
| 剪贴板兜底 | `[可得]` | island 已有 clipboard 语义（`AgentReopenAction.copyToClipboard`，`hai/CONTEXT.md:222`） |
| 辅助功能注入粘贴 | `[不可得]` | 仓库无任何 AX / CGEvent 代码（`.build/probe/panel/axcheck.out`）；需要新增辅助功能授权；与 `hai/CONTEXT.md:200` 的"Carbon 不需要任何授权"POC 结论冲突 |

本机实测：`chatgpt.com` 不可达（DNS 解析到 162.125.8.1，curl 20 s 超时），`claude.ai` 重定向到 `claude.com/app-unavailable-in-region`，两者 `[不可得]`；Kimi `[未验证]`。

### 2.4 R3 面板与快捷键

| 项 | 结论 | 依据 |
|---|---|---|
| 复用现有键盘模式做 compose | **不能直接复用**，需新增 compose 状态 | 搜索框是任务过滤器（`Sources/Island/OverlayContent.swift:352`）；`↩` 只在有选中行时动作，行空时被吞（`:367`、`Sources/Island/OverlaySelection.swift:74`）；输入框单行且截断（`:276-277`） |
| 保住"自动弹出绝不抢焦点" | 必须，三处守卫 | `OverlayPanel.swift:35`（`canBecomeKey` 读 `acceptsKeyboard`）、`:18`（`.nonactivatingPanel`）、`AppDelegate.swift:257`；自动弹出走 `AppDelegate.swift:162`，`interactive=false`（默认值在 `:251`） |
| 多全局键注册 | `[可得]` | 同进程注册 3 个不同组合返回 status=0；重复注册同一组合返回 -9878；"按 id 分发"由自造 `kEventHotKeyPressed` 合成事件验证，**不是真实按键**。出处 `.build/probe/panel/hotkey_probe.out:6-21`、`hotkey_probe.swift:61-79` |
| 检测跨 app 快捷键冲突 | `[不可得]` | Carbon 无查询 API；别的进程持有同一组合时 `RegisterEventHotKey` 仍返回 status=0（`.build/probe/panel/hotkey_dup.out:1-9`）。可支持的最强结论是：`HotkeySettings.swift:84-89` 的回滚分支**不会**因跨 app 占用进入。按键最终投递给谁 `[未验证]` |
| 已安装智能体探测 | `[可得]` | bundle id 两条 API 都可用（`.build/probe/panel/bundleid_probe.out`）；本机实际只装了 `pi`（`/opt/homebrew/bin/pi`、`~/.pi`）与 `codex` CLI（`~/.codex`）；claude CLI、`~/.claude`、Claude.app、ChatGPT.app 都不存在（`panel.md:195-200`）。**清单必须探测得出，不能写死 4 个 agent** |

需要改的代码面（`HotkeyRegistrar`）：目前只持 1 个 ref、`EventHotKeyID` 的 id 硬编码为 1、回调不读 id（`Sources/Island/HotkeyRegistrar.swift:30,47-50,72-79`）。多键与"按 id 分发"要在这里动，`HotkeySettingsCoordinator` 的"不会变成没有可用快捷键"不变量（`hai/CONTEXT.md:211`）要扩展到 N 个键。

探测实现取向：不要依赖登录项的 PATH，宜照 `Sources/Island/AgentReopenExecutor.swift:15-20` 用硬编码绝对路径。对应 `[未验证]`：开机自启实例的 PATH 是否含 `/opt/homebrew/bin`（`panel.md:216-224,411-414`）。

### 2.5 工程门禁约束（三条需求都受影响）

- `Sources/Island` 新增文件必须手工加进 `coverage.config`（逐文件，实测恰 24 条，`coverage.config:16-40`、`hai/CONTEXT.md:196`），否则 100 基线掉。
- 协议/状态机/manifest 解析/权限判定全部落 `IslandCore`（纯 Foundation），可达 100% 覆盖。`[可得]` 高
- 不新增白名单外的 import：白名单是 `AppKit|Foundation|Carbon.HIToolbox|ServiceManagement|IslandCore`（`scripts/check-layering.sh:27-28`）。UDS 用 `Foundation` 就够，`Network` 与 `Darwin` 会红。
- 行为开关按惯例走 `ISLAND_*` 环境变量；仓库刻意不引入配置文件（`hai/CONTEXT.md:191`）。插件的 `plugin.json` 是第一个真正的配置文件，与这条惯例冲突，需要你裁（见 §7-D3）。

---

## 3. 通知与插件的可选方案参考

### 3.1 通知 / 接入方式（业界对照）

| 方案 | 代表 | 适合 island 吗 | 原因 |
|---|---|---|---|
| 系统通知 | macOS UserNotifications、`osascript display notification`、terminal-notifier | 只能作 island 自己的提醒，**不能当 IPC** | 面向用户，无请求-响应，无回执 |
| 本地 socket + 行分隔 JSON | VS Code git、Feishu（`/tmp/aha-atrpc-*.sock`）、Claude Code `messagingSocketPath` | **采用** | 语言无关、双向、可推送、零依赖 |
| 进程外协议（自有分帧） | LSP（`Content-Length` 头分段，不是行分隔）、MCP stdio | 第二期可作为"面向智能体的门面" | 语义更丰富，但要多一层协议实现；本方案不用长度前缀（`ipc.md:231-232`） |
| 文件握手 | island ↔ 自带 VS Code 扩展（仓库既有） | 兜底 | 实现最省、幂等，但无连接状态、无推送、无回执 |
| 本机 HTTP webhook | ntfy、Home Assistant | 不推荐 | 需 `import Network`（破 gate）、默认绑全网卡、端口与 token 自建 |
| Distributed notification | `NSDistributedNotificationCenter` | 不用 | 广播、无鉴权、无回执 |
| XPC / Mach service | macOS 原生 | 不用 | 要改部署形态为 LaunchAgent，与 `SMAppService.mainApp`（`hai/CONTEXT.md:207`）冲突 |
| URL scheme | `island://notify?...` | 不用（已决策 D4） | 单向、可能弹确认框、无回执、易被滥用 |
| CLI 门面 | `island notify …` | **采用** | 复用现有 flag 模式（`Sources/Island/main.swift:4-46`），任何语言一行命令即可接入 |
| 声明式配置由宿主代执行 | 本仓库 `AgentProfile`、VS Code 的 `contributes` 段、LaunchAgent plist | **采用**（范围受限） | 不动宿主代码即可扩展；注意 Alfred workflow 与 Raycast 扩展**都含代码**，不是无代码声明式的代表 |

### 3.2 插件方案（业界对照）

| 方案 | 代表 | island 适配 |
|---|---|---|
| manifest + 宿主内 extension host | VS Code | 需要稳定 ABI 与沙箱宿主，island 没有 |
| manifest + 独立进程协议 | LSP、MCP、语言服务器 | **采用** |
| 纯声明式 manifest（无代码） | 本仓库 `AgentProfile`、VS Code `contributes` | **采用**（范围受限，见 §2.2） |
| 动态库 | Emacs、Vim、输入法 | 否决（hardened runtime library validation） |
| Wasm | Zed、Extism | 否决（无系统 runtime，要引第三方） |
| XPC service | macOS 原生 | 否决（部署形态） |
| AppleScript / shell | macOS 传统 | 只作为声明式插件里的"动作"，不作为插件运行时 |

---

## 4. 目标设计

### 4.1 四层，一套协议

```
L0 传输   UDS（主）/ 文件收件箱（兜底）/ CLI 门面（island notify …）
L1 协议   NDJSON 信封：请求 v/id/method/params；回执 v/id/ok/error/result；事件 v/event/seq/data
L2 网关   鉴权（uid+token）、方法/事件白名单、限流、幂等窗口、版本协商
L3 插件   声明式 manifest（island 执行动作）｜进程插件（回连同一 socket，hello 声明 role=plugin）
L4 UI     启动器 section、compose 输入、每目标全局键、已安装探测
```

关键设计判断：**插件不另造 stdio 协议**，回连同一条 socket。同一套双向信封已覆盖"调用 + 推送"，加第二套等于维护两份协议。`[推断:]` 中

### 4.2 协议字段（沿用 `ipc.md` §4）

| 方法 | 方向 | 语义 |
|---|---|---|
| `hello` | C→S | 必须第一个方法；带 `client`/`protocol`/可选 `token`；回执给 `methods`/`events`/`limits` |
| `notify` | C→S | 单向通知 + 回执；`kind` 白名单、`client_event_id` 去重 |
| `query` | C→S | 只读查询 island 已知状态（`status`/`unread`/`tasks`/`capabilities`） |
| `subscribe` / `unsubscribe` | C→S | 订阅事件；服务端在同一条连接推 `event` 帧 |
| `event` | S→C | `task.finished` / `task.read` / `task.removed` / `server.bye`，带单调 `seq` |

错误码：`bad_version` / `unauthorized` / `unknown_method` / `bad_params` / `too_large` / `rate_limited` / `not_subscribed` / `internal`。

**协议缺口（本稿新增，一手文件未覆盖）**：`ipc.md` §4 只定义了 S→C 的**事件帧**，没有 S→C 的**请求帧**。要做到"island 主动调用插件"，需要补一帧反向请求 + 反向回执，同样按 `id` 配对。这是"相互通信"的另一半，P4 之前必须先补进协议。`[推断:]` 中（依据：现有草案的帧类型只有 request/reply/event，其中 request 的方向被限定为 C→S）

### 4.3 安全模型

- 目录 0700、socket 0600（bind 后显式 chmod）、token 文件 0600。不放 `/tmp`。`[可得]` 高
- 双层：`getpeereid` 挡"别的用户"；token 挡"同用户下的任意进程"。
- **IPC 方法白名单里绝不放行**：任何 `exec`/`shell`/`eval`；任何"参数即目标"的动作（打开 URL、`open -b`、写 tty、AppleScript）——这些能力 island 内部已有（`Sources/Island/TerminalTabFocuser.swift:106-109`）；改设置里的路径、改登录项、触发升级、退出 app。
- 必须避免复制既有弱点：现有 VS Code 握手把响应文件里的路径直接交给 `open -b`（`Sources/Island/TerminalTabFocuser.swift:106-109`），而该目录按 `FileManager.createDirectory` 的 API 默认权限（实测 0755）创建。`[推断:]` 高：任何本机同用户进程都能写响应文件诱导 `open`。（实测记录：`RESULTS.log:205-208`；`~/Library/Application Support/island` 目录当前不存在，故属 API 默认值推断。）
- **插件动作与 IPC 的边界（本稿新增）**：§4.3 禁止的是"IPC 输入变成动作"。声明式插件声明的 `url` / `command` 由 island 主进程执行，这些动作来源于**用户自己放进插件目录、并经 manifest 校验过的本地文件**，不是 IPC 输入；两者必须分成两条路径，插件动作**不得**经由 IPC 触发。`plugin.md:166-169` 的插件侧方法表里有 `open.url`，实现时要按这条边界收敛：要么删掉该方法，要么把 `open.url` 的允许来源限定为"本地 manifest 声明的动作 id"而非任意 URL。

### 4.4 插件规范（草案）

字段表以 `plugin.md:205-222` 为准，摘要：

| 字段 | 必填 | 说明 |
|---|---|---|
| `manifestVersion` | 是 | 必须为 1；不认识即拒绝加载 |
| `id` | 是 | `[a-z0-9-]{3,64}`，必须等于目录名 |
| `name` / `version` | 是 | 展示名 / 语义化版本 |
| `kind` | 是 | `declarative` 或 `process` |
| `entry` | kind=process 时必填 | 相对路径，必须落在插件目录内，禁 `..`、绝对路径、符号链接逃逸 |
| `apiVersion` | 是 | 形如 `">=1.0 <2.0"` |
| `minIslandVersion` | 否 | 低于则禁用并提示 |
| `capabilities` | 是 | 未知值一律拒绝加载（fail closed） |
| `actions` | 声明式必填 | `{id, title, trigger, command?/url?, match?}` |
| `hotkey` / `icon` / `description` / `author` | 否 | `hotkey` 当前只登记、不注册 |

- 目录：`~/Library/Application Support/island/plugins/<id>/`，`plugin.json` 是唯一必需文件；日志另存 `~/Library/Logs/island-plugins/<id>.log`。
- 声明式插件可表达：做完任务后的动作（exec 命令模板、打开 URL）、筛选与静音规则、面板上的附加动作。命令模板必须直接 exec 不经 shell，`{title}`/`{cwd}` 属不可信输入，按 argv 边界传参（`plugin.md:232-238`）。
- 进程插件：由 island 拉起，启动后回连 socket 并 `hello(role=plugin)`；崩溃/超时由 island 兜；日志独立。
- 权限模型是"声明 + 代理 + 审计"，**不是强制隔离**：island 无 sandbox，插件进程拥有当前用户全部权限。`[可得]` 高
- 覆盖率落点：manifest 解析、状态机、capability 判定进 `IslandCore`；`Process`/`Pipe`/`Timer` 胶水进 `Sources/Island` 并登记 `coverage.config`。
- **启动器目标清单是本稿新增**：一手文件的字段表里没有 `targets`。目标 = `{id, 显示名, 类型(站点/应用), URL 模板 或 bundle id, 图标, 快捷键}`，来源 = 内置探测 + 声明式插件。该字段要么并入 `actions`，要么作为 `apiVersion` 的下一个次版本新增。

### 4.5 插件开发 skill

- 名称候选：`island-plugin`；触发条件：用户要"给 island 加功能 / 写 island 插件 / 把 X 接到 island"。
- 内容骨架：插件目录与 manifest 字段表、两类插件各自的最小可用样例、调用协议（CLI 优先）、错误码与调试方式（`nc -U` 手测、`--scan-agents`、日志位置）、提交前的验证清单（`make verify`、覆盖率登记、lint 白名单）。
- 写法参考本机 `~/.agents/skills/` 下的现成 skill（`plugin.md:389` 已列出具体文件）。

### 4.6 启动器（R2-例 + R3）

- 悬浮窗新增独立的 launcher section，**不与任务行混排**。影响面在 `OverlaySelection` 的行模型上（`panel.md:331-332`）；`AgentInbox` 只负责任务的增量/已读/排序/上限，与本功能无关。
- compose：在 keyboard 模式内新增 compose 状态，`↩` 在 compose 态走"提交到选中目标"，与现有"回车打开选中任务"分支互斥。
- 打开策略按目标配置：URL 模板优先，剪贴板兜底；AX 注入不做。
- **默认不带自动发送参数**：`autosend=1` 会在用户未确认时把问题发出去，默认路径只带 `q`，`autosend` 作为显式开关（决策点见 §7-D9）。

### 4.7 插件运行时路线（已确认）

"不做进程内 dylib 插件"指的是：插件不编译成 `.dylib` / `.bundle` 交给 island 用 `dlopen` 装进自己的进程。不是"插件不能有代码"。

代码插件有三条路线，对用户安装的影响完全不同：

| 路线 | island 侧成本 | 用户安装影响 | 沙箱强度 | 结论 |
|---|---|---|---|---|
| 独立进程插件（推荐） | 零新依赖；只需 spawn + 协议 | **零影响**。插件自己带运行时，island 不关心插件用 shell、Python、Node 还是编译好的可执行文件 | 进程级 | 采用 |
| island 内嵌 JavaScriptCore | 系统框架，零安装；但要改 `scripts/check-layering.sh:27-28` 白名单（Ask first） | 零影响（JSC 随系统走） | 同进程，弱 | 不用（已确认 D10） |
| island 内嵌 Wasm runtime | 必须引第三方 runtime；`du -sh /Applications/Island.app` 实测当前只有 1.8 MB，内嵌 wasmtime 量级的 runtime 会让体积涨一个数量级 | 见下方三种子路线 | 强 | 不推荐 |

Wasm 的三条子路线，用户安装影响各不同：

1. **插件自带 runtime**：插件目录里放自己的 wasmtime 可执行文件。island 与用户都零影响。这其实是"独立进程插件"的一个实例，不需要 island 做任何事。
2. **island 内置 runtime 二进制**：用户零安装，但安装包变大，且公证要覆盖这个嵌套可执行文件、签名必须同 Team ID（`scripts/release.sh` 的公证流程要重做）。
3. **依赖用户自己装**：用户要多一步 `brew install wasmtime`，对菜单栏小工具来说最差。

**Wasm 与 Node 无关**：Wasm 不需要 node。只有"插件写成 Node 脚本、由 island 直接执行"才需要用户有 node（本机 node v24.22.0 来自 Homebrew；`node -e` 实测 `WebAssembly` 可用，即 node 自带 wasm 运行时）。独立进程插件里语言由插件作者选，island 不要求任何环境。

**JIT 是额外的坑**：JIT 型 wasm runtime 在 hardened runtime 下需要 `com.apple.security.cs.allow-jit` 这类 entitlement，否则公证与运行都会出问题（[Apple 开发者论坛](https://developer.apple.com/forums/thread/805941)）。解释器型 runtime（如纯 Swift 的 [WasmKit](https://github.com/swiftwasm/WasmKit)）不走 JIT，但仍是一个 SwiftPM 依赖。

**"引入依赖就能做很多事情"不成立**：能力来自协议与 manifest，不来自运行时。引入 Wasm 只买到"沙箱 + 语言无关"，买不到新功能；而这两样，独立进程插件用零依赖就拿到了大部分。

**已确认（2026-10-18）**：island 不内嵌任何插件运行时，也不内嵌 JavaScriptCore。想要 Wasm 或 JS 的插件作者，自己在插件目录里带 runtime，island 照协议说话就行。

### 4.8 `plugin.json` 算不算“配置文件”（已确认）

`hai/CONTEXT.md:191` 的约定是"所有行为开关走 `ISLAND_*` 环境变量，不引入配置文件"，针对的是 **island 自身的行为开关**（热键、停留秒数、条数、agent home）。

已确认按“谁的行为”划线（2026-10-18）：

- **插件清单**：描述插件自身（身份、入口、声明能力、动作）。island 读这个文件是为了发现与校验插件，不是为了改自己的行为。这不算 island 的配置文件，与现状一致——island 本来就在读别人落盘的 JSON（`~/.claude`、`~/.codex`、VS Code 扩展写的 `window-<pid>.json`）。
- **island 的行为开关**：仍然只走 `ISLAND_*` 与 `UserDefaults`。manifest **不得**覆盖这些开关。
- **用户对插件的偏好**（启用/禁用、绑定的快捷键）：继续放 `UserDefaults`，不进 manifest。

边界一旦破了（例如 manifest 里出现"完成任务时默认弹窗 3 秒"），这份 manifest 就变成了应用配置，这条约定也就作废了。所以规则可以写成一句：manifest 只描述插件，不描述 island。

---

## 5. 分期建议

A 线（通道，对应 R1）与 B 线（面板与声明式插件，对应 R2/R3）没有相互依赖，可并行或只做一条；**进程插件（P4）依赖 A 线的 socket**。

| 期 | 线 | scope | 判据 |
|---|---|---|---|
| P0 | A | UDS server + `hello`/`notify`/`query` + CLI `island notify` + socket 认领流程 + 新增外部通知行（D11） | `nc -U` 手测拿到回执；`island notify` 后悬浮窗出现该行；重启/被 kill 后能重新认领 socket 路径 |
| P1 | A | `subscribe`/事件推送、限流、幂等窗口、目录权限 0700/0600、`server.bye`（token 暂缓，见 D12） | 3 客户端并发订阅各自收到事件；`ISLAND_IPC=off` 时 socket 文件不存在、`nc -U` 连接被拒 |
| P2 | A | skill（智能体接入指南）+ 自测探针客户端 | 探针按 skill 走能接入；真实客户端 `dsh-system-notify` 等基础功能完成后再谈（决策 D8） |
| P3a | B | launcher section + DeepSeek URL 模板 + compose 输入（**已实施**，issue `overlay-launcher-compose`） | 悬浮窗输入一句话 → 浏览器打开 `chat.deepseek.com/?q=…`（`autosend` 默认不带） |
| P3b | B | 多目标启动器（**已实施**，issue `launcher-targets`）：目标清单走 `ISLAND_LAUNCHER_TARGETS`，compose 态 `⇥` 循环目标；声明式 manifest（`plugin.json` 解析 + 启用/禁用 + `targets` 字段）**未做** | `ISLAND_LAUNCHER_TARGETS` 设两条目标后 `--print-config` 的 launcher 行列出两个名字，`⇥` 可切换；`make verify` 全绿 |
| P3c | B | 模式环可配（**已实施**，issue `launcher-modes`）：设置页 → 启动器（拖拽排序 / 增删改 / 逐模式附加参数开关）+ `UserDefaults` 载体 + `⇥` 走环；声明式 manifest（`plugin.json` 解析 + 启用/禁用 + `targets` 字段）**仍未做** | 设置页拖到一个自定义模式排第一，重启后 `⇥` 顺序与之一致；给 DeepSeek 勾上「自动发送」后 URL 带 `autosend=1`；`make verify` 全绿 |
| P4 | B（依赖 P0/P1） | 进程插件（回连 socket）+ 双向请求帧 + 多全局键 + 已安装智能体探测 | 插件按 id 收事件并能被 island 反向调用；同进程注册 3 键全成功；探测结果与本机实际装机一致 |

P0 为什么不先用文件收件箱：CLI 与协议编解码两边都要写，文件版会让传输层写两遍。文件收件箱保留为"主方案不可用时"的兜底，不单独做一期。`[推断:]` 中

P0 的展示形态（D11，已确认）：外部通知进悬浮窗时**新增一类行**，与任务行并列、单独计数，不伪装成 AgentTask。理由：任务行有未读与点击语义，`AgentInbox` 的去重与排序不该被外部进程左右。P0 里这一行只显示来源与标题，点击只做"标记已读"；触发动作要等 B 线的启动器与 manifest。影响面在 `OverlaySelection` 的行模型与悬浮窗渲染。

D11 落地后补充（issue `notification-list-scroll-clear`）：通知区标题行右侧有 `Clear all`；任务行与通知行共用一个滚动区，面板高度按屏幕封顶，内容超出时底部中间显示半透提示。通知不再按 N 截断，行数改由滚动区可视高度决定。

P3a 落地后补充（issue `overlay-launcher-compose`，2026-10-18 用户选定先做这一段的用户可见部分）：P3 拆成两段。compose 不另开一行/一区，而是把键盘模式的标题行输入框切换用途——`⇥` 在"筛选任务"与"提问"之间切换，`↩` 打开 `https://chat.deepseek.com/?q=<问题>`；目标清单本轮内置 DeepSeek 一条（`LauncherTarget` 已按多目标建模），`ISLAND_LAUNCHER=off` 关闭入口。于是 §4.6 里"launcher section 不与任务行混排"这条**没有按原设计实现**：不为它动 `OverlaySelection` 的行模型，代价是同一时刻只能有一个目标（多目标要等 P3b 的 manifest 与目标切换键）。Kimi 仍未加入：`?q=` 支持情况属 §8 `[未验证]`。

P3b 落地后补充（issue `launcher-targets`，2026-10-18）：开工前由用户回答三个问题，结论是**载体用 `ISLAND_LAUNCHER_TARGETS` 环境变量**（D13）、**compose 态按 `⇥` 循环目标**、**本轮不加 Kimi**。于是"多目标可选可配"落地了，载体不是 manifest：`LauncherTarget` 的四种字段照旧，清单解析、非法条目跳过、`⇥` 循环与开关优先级都在 `IslandCore`（100% 覆盖），AppKit 只渲染当前目标并 `NSWorkspace.open`。只有一个目标时 `⇥` 仍是"退回筛选"，与 P3a 等价。§4.4 的 `targets` 字段与 §4.8 的 manifest 边界都未改动；**声明式 manifest（`plugin.json` 解析 + 启用/禁用 + 字段校验）仍是 P3b 未做的部分，需另开 issue**。

P3c 落地后补充（issue `launcher-modes`，2026-10-18）：把"筛选 / 提问"两态泛化成**有序模式环**（`LauncherMode = 搜索任务 | 网页提问`），`⇥` 恒为"下一站并回绕"，**第一行就是热键召唤后直接进入的模式**（用户选定），`搜索任务` 恒在环里、可拖不可删（`esc` 的取消去处）。载体从"仅环境变量"扩到**设置页（`UserDefaults` 的 `IslandLauncherModes`，JSON）+ 环境变量 + 内置**，优先级 `ISLAND_LAUNCHER=off` > 设置页 > `ISLAND_LAUNCHER_TARGETS` > 内置（D14，与 `CONTEXT.md` 的"应用内设置 > 环境变量"一致；D13 只被扩展、未被推翻——环境变量通道与格式原样保留）。每个模式可挂**任意个可勾选的附加参数**（`LauncherOption`：键 / 值 / 用户起的标签 / 是否启用），DeepSeek 内置一个**默认不勾**的 `autosend=1`（标签「自动发送」）；这取代了 §4.6 的"默认只带 `q`"一刀切，D9 的"要给就给显式开关、默认不带"不变。**Kimi 不内置**：旧域名 `kimi.moonshot.cn/_prefill_chat?prefill_prompt=…&send_immediately=true` 现在只 302 到 `www.kimi.com/_prefill_chat`，而当前 `kimi-web-seo` bundle 里该路由是 `{path:'/_prefill_chat', redirect:'home'}`（参数被丢弃），`send_immediately` **0 命中** —— 旧域名的能力在新域名已不存在，属"未知能否支持"，按用户"只内置已知能支持的部分"的裁决不内置，交给自定义模式。§4.4 的 `targets` 字段与 §4.8 的 manifest 边界仍不变。

---

## 6. 每条需求的验证判据（可复现）

| 需求 | 怎么算做对了 | 怎么验 |
|---|---|---|
| R1 通道 | 外部进程能通知 island 并拿到回执 | `printf '{"v":1,"method":"hello","params":{"client":"probe","protocol":1}}\n' \| nc -U "$SOCK"` 有回执；再发 `notify`，悬浮窗出现行 |
| R1 双向 | 服务端能主动推 | 客户端发 `subscribe`，触发一次任务完成，连接上收到 `event:task.finished` |
| R2 插件 | 一个声明式插件不改 Swift 即可新增动作/目标 | 投放一个 `plugin.json`，重启 island 后该动作生效；`make verify` 全绿 |
| R2 skill | 按 skill 走能产出可加载插件 | 新会话只读 skill，产出目录被 island 加载，判据同上 |
| R3 探测 | 清单与实际装机一致 | 本机只应列出 `pi` 与 `codex`（无 claude / ChatGPT.app），可用 `ls /Applications` 与 `which` 对照 |
| R3 快捷键 | 多键可注册且可回滚 | 同进程注册 3 键全部 status=0；同进程重复注册（-9878）时回滚到旧键而不是变成无键。跨 app 占用不触发回滚（注册返回 noErr），故不能用这种占用构造回滚测试 |
| 全量 | 不破既有门禁 | `make verify` 全绿；`coverage.txt` 不低于 `coverage-baseline.txt`（100） |

---

## 7. 决策记录（2026-10-18）

| 编号 | 决策点 | 结论 | 对方案的影响 |
|---|---|---|---|
| D1 | 是否把 R1/R2/R3 写进 `hai/PLAN.md` 的 scope | 最终要写入，但不是现在 | 方案继续标注"超 scope"；动工前需先改 PLAN |
| D2 | 不做进程内 dylib 插件 | 已确认，见 §4.7 | 插件形态定为两层；island 不内嵌任何运行时 |
| D3 | `plugin.json` 算不算配置文件 | 不算。manifest 只描述插件，不描述 island | §4.8 的划线成立 |
| D4 | 是否注册自有 URL scheme | 不做 | §3.1 移除该候选 |
| D5 | `ISLAND_IPC` 默认值 | 默认 `token`；token 在设置界面可见 | P1 增加设置界面入口 |
| D6 | 方案是否保存进仓库 | 已落盘到 `hai/reference/extensions/` | 本文即入库版本 |
| D7 | 先投 A 线还是 B 线 | 先 A 线 | 实施顺序 A → B |
| D8 | 接入 `dsh-system-notify` | 基础功能完成后再谈 | P2 只交付 skill 与自测探针 |
| D9 | `autosend=1` 是否接受 | 默认不带 | P3 默认模板只带 `q` |
| D10 | JSC 与 `check-layering.sh` 白名单 | 不做内嵌 JSC，白名单不动 | 见 §4.7 |
| D11 | 外部通知在悬浮窗的展示形态 | 新增外部通知行，单独计数；P0 点击只标记已读 | 要动 `OverlaySelection` 的行模型 |
| D12 | token（D5）何时做 | 暂缓，先不做；P0/P1 靠同 uid + 0700/0600 + 方法白名单 | P1 去掉 token 与设置界面入口；同用户进程可发通知、可 `query tasks`，这是已知缺口 |
| D13 | P3b 目标清单的载体（2026-10-18 实施时由用户选定） | `ISLAND_LAUNCHER_TARGETS` 环境变量：`id\|显示名\|站点基址\|查询参数`，`;` 分隔，非法条目跳过；`ISLAND_LAUNCHER=off` 仍整体关闭且优先 | P3b 只做环境变量载体，不创建 `plugins/` 目录；§4.4 的 `targets` 字段与 §4.8 的 manifest 边界都不变，manifest 另开 issue |
| D14 | P3c 模式环的载体、顺序语义与 `autosend`（2026-10-18 实施时由用户选定） | ① 模式环由**设置页**配置，存 `UserDefaults` 的 `IslandLauncherModes`（JSON），优先级 `ISLAND_LAUNCHER=off` > 设置页 > `ISLAND_LAUNCHER_TARGETS` > 内置；② **第一行即热键召唤后直接进入的模式**，`搜索任务` 恒在环里可拖不可删；③ 附加参数逐模式**显式勾选、默认全不勾**（DeepSeek 预置 `autosend=1`，标签「自动发送」）；④ 只内置**已知能支持**的目标，即 DeepSeek 一条，Kimi 走自定义 | 扩展 D13 而不推翻它（环境变量通道与格式原样保留，仍是开发者覆盖通道）；D9"默认不带"不变，只是从"一刀切"变成"逐模式开关"；不引入配置文件，仍走 `UserDefaults`（§4.8）；`autosend` 从"永不出现"变成"用户勾了才出现" |

---

## 8. 未验证与不可得清单

`[未验证]`（写清要做什么实验才能确认）：

| 项 | 实验 |
|---|---|
| Developer ID + hardened runtime 下 UDS 仍可用 | 在**有 Developer ID 身份的机器**上用 `ISLAND_SIGN_IDENTITY` 构建一次并重跑 `.build/probe/ipc/run_all.sh`（本机 `security find-identity -v -p codesigning` 为 `0 valid identities found`，做不了） |
| 0600 socket 拒绝其他本机用户 | 建第二个账号，`su` 过去 `nc -U` 试探 |
| DeepSeek `?q=` / `autosend=1` 端到端生效 | **已实测（2026-10-18，用户在本机浏览器）**：`https://chat.deepseek.com/?q=测试&autosend=1` 可以自动触发问答。站点生产 bundle 里的实现（`open_in_deepseek` 埋点、`q`/`prompt` 白名单、`autosend=1 && length<=800`、仅站点根路径、需已登录）见 `launcher-modes.md` §2.1 |
| Kimi 是否支持带参预填/自动发送 | 旧域名 `kimi.moonshot.cn/_prefill_chat?prefill_prompt=…&send_immediately=true` 现在只 302 到 `www.kimi.com/_prefill_chat`，而当前 bundle 里该路由是 `{path:'/_prefill_chat', redirect:'home'}`、`send_immediately` 0 命中。仍缺一次**已登录浏览器**的实测才能说死（匿名 HTTP 路径已确认不支持） |
| 跨 app 热键冲突时按键投递给谁 | 需辅助功能授权投递真实按键（本机 `AXIsProcessTrusted()==false`） |
| 拼音输入法下 compose 提交行为 | 切到简体拼音，输入并回车 |
| 插件子进程的 TCC 归属、quarantine 二进制能否 spawn | 各起一次带 quarantine 属性的子进程观察 |
| 限流阈值 | 需要真实插件负载之后才谈得上定值 |
| 开机自启实例的 PATH 是否含 `/opt/homebrew/bin` | 以登录项方式启动后 `ps eww` 看环境 |
| `dsh://` 是否支持查询参数 | 读 DSH 的路由处理 |
| `.build/` 是否会被 `swift package clean` 整个删掉 | 实际执行一次（只在副本上做） |

`[不可得]`：

| 项 | 被什么挡住 |
|---|---|
| NSXPC 在非 launchd 进程直接对外注册 | 平台机制，名字必须由 launchd job 的 MachServices 声明 |
| 本机验证 Claude Code `messagingSocketPath` 能否被外部连接 | 本机没装 Claude Code（无 `~/.claude`、无进程、无 `/tmp/cc-socks`） |
| island 现状的 URL scheme | Info.plist 未注册 |
| 本机验证 ChatGPT / Claude 网页带参 | 区域与 DNS 双重阻挡 |
| 辅助功能注入粘贴 | 仓库无 AX 代码，且与既有"不需要授权"结论冲突 |

**仓库内无证据**：island 现有代码没有任何 socket / XPC / DistributedNotification / NWListener / FSEvent 用法（`grep` 只命中 `AgentMonitor.swift:6` 的注释）；`docs/` 下只有 `demo.gif`。

---

## 9. 顺带发现，建议一并修

1. `hai/CONTEXT.md:32` 说"开发机日常跑的是 brew 装的 `/Applications/Island.app`"——实测该 app 是 0.0.0 本地构建、ad-hoc 签名，`brew info --cask island` 报 cask 不存在。该描述已过期。
2. `hai/CONTEXT.md:211` 说"macOS 拒绝新键（被别的 app 占用）时会把旧键重新注册回来"。本机只测到**注册返回值**这一层：别的进程持有同一组合时仍返回 status=0（`.build/probe/panel/hotkey_dup.out:1-9`），按键实际归属谁 `[未验证]`。因此不能断言该文档描述错误，只能断言：多快捷键方案不能依赖"注册失败即冲突"。文档暂不改，待按键归属实验。
3. 现有 VS Code 握手目录按 API 默认权限创建，且响应文件里的路径会被直接 `open`（`Sources/Island/TerminalTabFocuser.swift:106-109`）。新增 IPC 时不要复制这个"参数即动作"模式。
4. 面板多屏行为未确认：`OverlayPanel.swift:54` 用 `NSScreen.main`。
