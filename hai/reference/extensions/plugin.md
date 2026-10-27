# island 插件机制设计与插件规范草案（task-2）

调研对象：island 仓库（lbyxiafei/island），只读。本文原为只读调研交付稿，当时写在构建目录 `.build/plan/` 下（未入库）。

探针产物在 `.build/probe/plugin/`（**未入库**，`.build/` 被清理后失效）。结论引用的签名与加载实验结果已抄录在本文 §1.1 与 §2.1。

标记约定：每条结论后给 `[可得]` / `[不可得]` / `[未验证]`，再给置信度（高 / 中 / 低）。事实与推断分开，推断一律以“推断:”开头。

---

## 0. 结论摘要

1. **推荐分层：声明式 manifest（无代码）+ 独立进程插件（有代码）**。两层共用同一份 `plugin.json`，也共用同一套发现 / 启用 / 生命周期规则。[推断: 综合 §2 淘汰结果] 置信度 中。
2. **不采用进程内动态库**。发布版 island 是 Developer ID 签名 + hardened runtime（Team ID `C7QG7K23D7`），实测 hardened 进程 `dlopen` 异 Team ID 的 dylib 直接失败。[可得] 置信度 高。证据：`.build/probe/plugin/evidence-codesign.txt`、`.build/probe/plugin/libval/`。
3. **通信复用 T1（task-1，入站通知协议）已实测的信封**：Unix domain socket + NDJSON，顶层 `v` / `id` / `method` / `params`。插件进程是同一条 socket 的 client，`hello` 里声明 `role=plugin`。[可得：ipc-scout 实测回执] 置信度 中（ipc.md 定稿未落盘，见 §10）。
4. **插件进程由 island 拉起，通信走 socket 而不是 stdio**。原因是 T1 已确认 socket 天然双向、支持服务端推送 `event`，加一套 stdio 协议等于维护两套。[可得：ipc-scout 结论] 置信度 中。
5. **生产环境与开发机行为不一致，这是本方案最容易踩的坑**。本机 `build/Island.app` 与 `/Applications/Island.app` 都是 ad-hoc 签名且无 runtime（实测 `flags=0x2(adhoc)`），dylib 能加载；发出去的 0.2.3 带 runtime，加载不了。任何“插件做成 dylib”的方案只在开发机通过，用户机器上失败。[可得] 置信度 高。
6. **权限模型只能是“声明 + 代理 + 审计”，不是强制隔离**。island 无 app-sandbox entitlement，插件进程拿到的是当前用户的全部权限。想真正限制，只有沙箱化的独立签名 helper 一条路，代价是签名与公证复杂度。[可得] 置信度 高（无 sandbox 有证据）；权限的强制力只到代理执行一层 [推断:]。
7. **覆盖率不受威胁的做法**：协议 / manifest / 状态机 / 权限判定全部落 `Sources/IslandCore`（纯 Foundation），100% 覆盖；进程、Pipe、Timer、通知这些 wiring 落 `Sources/Island` 并加进 `coverage.config`。[可得] 置信度 高。

---

## 1. 仓库现状基线（全部本机可核对）

| 事实 | 出处 | 标记 | 置信度 |
|---|---|---|---|
| 两个 target：`IslandCore`（库）+ `Island`（可执行），另有 `IslandCoreTests` | `Package.swift:7-12` | [可得] | 高 |
| 零第三方依赖 | `README.md:55`；`hai/CONTEXT.md:11` | [可得] | 高 |
| 覆盖率基线 100，只覆盖 `IslandCore` | `coverage-baseline.txt`；`hai/CONTEXT.md:95` | [可得] | 高 |
| `Sources/Island` 逐文件排除，新增文件必须加进 `coverage.config` | `coverage.config:14-40`；`hai/CONTEXT.md:98,196` | [可得] | 高 |
| 排除项由 `llvm-cov -ignore-filename-regex` 生效 | `scripts/coverage.sh:37-48` | [可得] | 高 |
| lint gate 只检查依赖方向 | `makefile.local:67`；`scripts/check-layering.sh:1-35` | [可得] | 高 |
| `IslandCore` 不得 `import AppKit/SwiftUI/Carbon` | `scripts/check-layering.sh:16-23` | [可得] | 高 |
| `Sources/Island` 只允许 `AppKit/Foundation/Carbon.HIToolbox/ServiceManagement/IslandCore` | `scripts/check-layering.sh:27-33` | [可得] | 高 |
| `make verify` 是唯一门禁入口，6 个 gate 全配置 | `Makefile:45`；`hai/CONTEXT.md:82-91` | [可得] | 高 |
| 行为开关全走环境变量，仓库刻意不引入配置文件 | `hai/CONTEXT.md:191` | [可得] | 高 |
| 新增 agent = `AgentKind` 加 case + `profile` 加项 + 一个 source 并注册 | `Sources/IslandCore/AgentProfile.swift:52-55`；`hai/CONTEXT.md:192` | [可得] | 高 |
| `AgentKind` 是编译期 enum，只有 4 个 case | `Sources/IslandCore/AgentTask.swift:5-10` | [可得] | 高 |
| source 注册点是 `AgentActivityScanner.standard(home:sqlite:)` 的固定数组 | `Sources/IslandCore/AgentActivity.swift:29-39` | [可得] | 高 |
| 轮询每 3 s 一次，跑在 `MainActor` | `Sources/Island/AgentMonitor.swift:32,49-54` | [可得] | 高 |
| 已有子进程封装，但读到 EOF 才返回（阻塞至进程退出） | `Sources/Island/Subprocess.swift:7-39`（`readDataToEndOfFile` 在 :31-32，`waitUntilExit` 在 :33） | [可得] | 高 |
| 全局热键只有一个，`EventHotKeyID` 的 id 硬编码为 1 | `Sources/Island/HotkeyRegistrar.swift:47-50` | [可得] | 高 |
| 界面文案必须走 `TextKey` enum（120 个 case，编译期固定） | `Sources/IslandCore/Localization.swift:35`；`hai/CONTEXT.md:194` | [可得] | 高 |
| 已有文件式 IPC 先例：VS Code 握手的 `focus-request.json` | `hai/CONTEXT.md:223`；`Sources/Island/TerminalTabFocuser.swift:17-18` | [可得] | 高 |
| VS Code 扩展（JS）不在 Swift 覆盖率统计内 | `hai/CONTEXT.md:228` | [可得] | 高 |
| 仓库与 README 从未出现“plugin / 插件 / 扩展点”概念 | `grep -rn -i "plugin" README.md hai/CONTEXT.md` 无命中 | [可得] | 高 |
| 仓库没有任何 `NSXPC` / `dlopen` / `builtInPlugInsPath` 用法 | `grep -rn "NSXPC\|dlopen\|dylib\|PlugIns" Sources scripts` 无命中 | [可得] | 高 |
| 仓库完全不使用 `Codable` | `grep -rln Codable Sources/IslandCore` 无命中 | [可得] | 高 |

### 1.1 签名与权限基线（实测）

| 对象 | 实测结果 | 出处 | 标记 | 置信度 |
|---|---|---|---|---|
| 发布的 0.2.3 | `flags=0x10000(runtime)`，`Authority=Developer ID Application: Binyan Li (C7QG7K23D7)`，`TeamIdentifier=C7QG7K23D7` | `.build/probe/plugin/evidence-codesign.txt` | [可得] | 高 |
| 发布版 entitlements | 只有 `com.apple.security.automation.apple-events`，无 `app-sandbox`，无 `disable-library-validation` | 同上；`scripts/Island.entitlements:5-9` | [可得] | 高 |
| 本地构建产物 | ad-hoc，`flags=0x2(adhoc)`，**无 runtime** | `codesign -dvvv build/Island.app`；`/Applications/Island.app` 同 | [可得] | 高 |
| runtime 何时加 | 只在 Developer ID 分支加（`build-app.sh:86`）；ad-hoc 分支（`:90`）不加 | `scripts/build-app.sh:83-91` | [可得] | 高 |
| 本机有无可用签名身份 | `0 valid identities found` | `security find-identity -v -p codesigning` | [可得] | 高 |
| 发布版 bundle 结构 | 只有 `Contents/{MacOS,Resources,_CodeSignature,Info.plist,CodeResources}`，无 `Frameworks` / `XPCServices` / `PlugIns` | `.build/probe/plugin/evidence-codesign.txt` | [可得] | 高 |

**风险结论**：本地开发机能加载第三方 dylib，用户机器上的发布版不能。“进程内 dylib 插件”是一条只在开发机通过的路径。[可得] 置信度 高。

---

## 2. 候选形态对比与淘汰理由

实验原始产物：`.build/probe/plugin/`。复现命令见 §12。

| 形态 | 隔离性 | 发布版可用 | 新依赖 | 覆盖率影响 | 结论 |
|---|---|---|---|---|---|
| 进程内 dylib（`dlopen`） | 无 | **否** | 无（但要加库 target） | 插件代码不进统计，宿主胶水要排除 | 淘汰 |
| XPC service / Mach service | 强 | 要改 bundle 与签名 | 无 | 要加 `Sources/Island` 文件 | 淘汰 |
| 独立进程 + socket NDJSON | 强（进程级） | 是 | 无 | 逻辑入 IslandCore，wiring 排除 | **采用** |
| 纯声明式 manifest | 不适用 | 是 | 无 | 纯 IslandCore，可 100% 覆盖 | **采用（受限范围）** |
| JavaScriptCore 进程内脚本 | 弱（同进程） | 是 | 系统框架，但破层检查清单 | 要排除 JSC 胶水 | 备选 |
| `jsc` 子进程脚本 | 强 | 是 | 无 | 无（JS 不进统计） | 备选（见 §4.4） |
| AppleScript / shell | 弱 | 是 | 无 | 无 | 只作为声明式的“动作”，不作为插件运行时 |
| WASM | 强 | 否（无系统 runtime） | 必须引第三方 | 无 | 淘汰 |

### 2.1 进程内动态库

实测（`.build/probe/plugin/libval/`）：

1. hardened 进程加载**相对路径**的 dylib 直接失败：`relative path not allowed in hardened program`。[可得] 高。
2. hardened 进程用绝对路径加载未签名 dylib：`code signature ... not valid for use in process: mapping process and mapped file (non-platform) have different Team IDs`。[可得] 高。
3. hardened 进程加载 **ad-hoc 签名**的 dylib（同样 `TeamIdentifier=not set`）仍然失败，报错同上。[可得] 高。结论：ad-hoc 签名满足不了 library validation。
4. 加 `com.apple.security.cs.disable-library-validation` 后，同一进程加载未签名 dylib 成功。[可得] 高。这是唯一逃生口，代价是每个用户都失去 library validation。
5. 非 runtime 的 ad-hoc 进程加载未签名 dylib 成功。[可得] 高。开发机因此看不出问题。
6. hardened 进程忽略全部 `DYLD_*`：设 `DYLD_PRINT_LIBRARIES=1` 时输出里没有任何 `dyld[...]` 行，对照组正常打印。[可得] 高。结论：注入式加载在 hardened 下也不成立。

补充理由：

- 仓库没有库 target，也没有 library-evolution 产物。`Package.swift:7-12` 只有两个 target 加一个测试 target。[可得] 高。
- 进程内插件崩一次就把 island 打掉。该插件还继承 island 的 TCC 授权（Apple Events）。[推断: 无 sandbox 意味着同权限，见 §1.1] 置信度 高。
- Swift dylib 的 ABI 稳定需要 `-enable-library-evolution` 与 `.swiftinterface`，等于给 island 加一套公开 ABI 与版本策略。[推断:] 置信度 中。

**淘汰**：收益为零（独立进程同样能跑插件代码），代价是发布版不可用 + 无隔离 + 破仓库的安全基线。

### 2.2 XPC service / Mach service

实测（`.build/probe/plugin/xpc/`）：进程内 `NSXPCListener(machServiceName:)` 能 `resume` 不报错，但另一个进程用 `NSXPCConnection(machServiceName:)` 连接时**立刻 invalidated**。原因是该 mach service 没有在 launchd 注册。[可得] 高。

要让 XPC 成立，两条路都必须付代价：

- 内嵌 `Contents/XPCServices/*.xpc`：`build-app.sh:32-39` 只创建 `MacOS` 与 `Resources`，发布版实测也没有 `XPCServices`。[可得] 高。要改打包脚本，并让 helper 与 island 同 Team ID 签名后再整体重签。
- 装 LaunchAgent plist：用户机器上多一份系统状态，卸载变复杂。

对比之下，独立进程 + socket 不需要 launchd、不需要改 bundle、不需要额外签名。[推断: 由 §2.1 的 probe F 支持，hardened 父进程可正常 spawn ad-hoc 子进程] 置信度 高。

实测 probe F：hardened 父进程用 `posix_spawn` 拉起 ad-hoc 子进程，子进程成功 `dlopen` 未签名 dylib，退出码 0。[可得] 高。结论：子进程由自己的签名决定约束，不受父进程 library validation 影响。

**淘汰**：能力与独立进程重叠，成本更高。

### 2.3 独立进程 + NDJSON（采用）

- 与 T1 同一套传输与信封，不新造协议。见 §3.2。
- 崩溃、卡死、超时都能在 island 侧兜住，见 §5.4。
- 不引入任何依赖，不破 `check-layering.sh`。
- 唯一代价：跨进程序列化与生命周期管理，这部分是纯逻辑，覆盖率可达 100%。

### 2.4 纯声明式 manifest（采用，但范围受限）

`AgentProfile.swift:52-55` 已证明“声明式配置”是本仓库的既有模式。但 `AgentKind` 是编译期 enum（`AgentTask.swift:5-10`），运行期无法新增 case。

结论：**声明式插件只能改 island 已有行为，不能新增数据类型或新检测器**。[推断: 由 enum 的编译期性质推出] 置信度 高。

声明式插件可表达的范围（都由 island 执行）：

- 任务完成时的动作：执行命令模板、打开 URL。
- 筛选与静音规则：按 agent / scenario / cwd 的正则。
- 菜单与悬浮窗上的附加动作：对当前选中任务执行某个动作。

任何“读某个新格式的落盘文件来判断完成”的需求，都必须走独立进程。[推断:] 置信度 高。

### 2.5 WASM

- SDK frameworks 与 `/usr/lib` 均无 wasm runtime（`ls "$SDK/System/Library/Frameworks" | grep -i wasm` 无命中；`ls /usr/lib | grep -i wasm` 无命中）。[可得] 高。
- 引入 wasm3 / Wasmtime 会打破“零第三方依赖”（`README.md:55`），并触发 AGENTS.md `Ask first` 第 1 条。[可得] 高。

**淘汰**。

---

## 3. 推荐分层方案

### 3.1 两层

| 层 | 形态 | 能做什么 | 不能做什么 |
|---|---|---|---|
| A 声明式 | 只有 `plugin.json` | 命令 / URL 动作、筛选规则、附加菜单项 | 新增 agent、新增解析、任何代码 |
| B 进程 | `plugin.json` + 可执行 entry | 新增检测器、任意逻辑、与外部系统通信 | 进 island 进程、绕过声明直接拿 island 内部能力 |

两层共用：同一份 manifest、同一个安装目录、同一套启用状态、同一套协议、同一个失败兜底。

### 3.2 复用 T1 协议：信封与传输都不另造

ipc-scout 已实测的结论（task-1，原文回执；定稿后的 `ipc.md` 尚未落盘）：

- 传输：Unix domain socket，建议路径 `~/Library/Application Support/island/ipc/island.sock`。`AF_UNIX` 的 `sun_path` 上限 103 字节（macOS），该路径约 60 字符。默认文件权限 `0o755`（umask 022）。[可得：ipc-scout 实测] 置信度 中（未亲验，我方只复核了路径先例）。
- 信封：单行 JSON + `\n` 分隔（NDJSON）。请求 `{v, id, method, params}`；回执 `{v, id, ok, error, result}`。[可得：ipc-scout 实测] 置信度 中。
- 方向：双向不对等。client→server 有 `notify` / `query` / `subscribe`；server→client 只在已有连接上推 `event`，不反向拨号。`hello` 握手带协议版本与 client 名。[可得：ipc-scout 实测] 置信度 中。

插件侧的字段约定：

| 项 | 取值 | 说明 |
|---|---|---|
| 角色 | `hello.params.role = "plugin"` | 与外部通知 client 区分 |
| 身份 | `hello.params.pluginId` + 每次启动的 `token` | token 由 island 在 spawn 时通过环境变量给出，防止别的本机进程冒名 |
| 插件发出的 method | `tasks.report`（上报自身检测到的 run）、`ui.attention`、`open.url`、`log` | 与 T1 的 `notify` 同形状，走 island 的 `query` / `notify` 通道 |
| 插件收到的 method | `event`（`task.completed`、`plugin.shutdown`、`action.invoke`） | 复用 T1 的服务端推送 |
| 载体 | 只走 socket，不用 stdio | 理由：socket 已双向，加 stdio 等于两套协议 |

**为什么由 island spawn、插件回连 socket**：island 要能控制生命周期，包括禁用即杀、崩溃重启、退出清理。而 T1 的 server 不接受反向拨号。所以 spawn 由 island 做，通信由插件回连做。[推断: 由 ipc-scout 的“不反向拨号”与 §5.4 的隔离需求推出] 置信度 中。

时序：

```
island: 读 plugin.json -> 校验 -> spawn(entry, env: ISLAND_IPC_SOCKET, ISLAND_PLUGIN_ID, ISLAND_PLUGIN_TOKEN)
plugin: 连 socket -> hello(role=plugin, protocol, pluginId, token)
island: hello 回执(server 版本, 方法集) 或 直接断开
plugin: 订阅 / 上报
island: 每 3 s 的 poll 命中新任务时推 event(task.completed)
```

### 3.3 若 socket 路线被 T1 推翻

退路是 stdio NDJSON，信封字段名沿用 §3.2，只换载体。这条退路**不改变** manifest、权限模型、生命周期与覆盖率结论。[推断:] 置信度 高。

---

## 4. 插件形态细则

### 4.1 目录布局

```
~/Library/Application Support/island/plugins/<pluginId>/
  plugin.json          必须
  bin/<entry>          kind=process 时必须，Mach-O 或脚本（脚本需 shebang 且可执行）
  icon.png            可选，建议 64x64 与 128x128
  README.md           可选
```

同根先例：`Sources/Island/TerminalTabFocuser.swift:17-18` 已用 `~/Library/Application Support/island/vscode`。[可得] 高。

日志另存：`~/Library/Logs/island-plugins/<pluginId>.log`。理由：与配置分离，卸载插件不删日志。[推断:] 置信度 中。

### 4.2 `plugin.json` 字段表

| 字段 | 类型 | 必填 | 语义与校验 |
|---|---|---|---|
| `manifestVersion` | int | 是 | 必须等于 1；不等则拒绝加载 |
| `id` | string | 是 | `[a-z0-9-]{3,64}`；必须等于目录名；重复则后者标记 invalid |
| `name` | string | 是 | 展示名，1-64 字符 |
| `version` | string | 是 | 语义化版本 |
| `kind` | `"declarative"` \| `"process"` | 是 | 决定是否需要 `entry` |
| `entry` | string | kind=process 必填 | 相对路径，必须落在插件目录内（禁 `..`、禁绝对路径、禁符号链接逃逸） |
| `icon` | string | 否 | 相对路径 PNG |
| `apiVersion` | string | 是 | 形如 `">=1.0 <2.0"`；island 用该字段判断兼容 |
| `minIslandVersion` | string | 否 | 低于该版本时禁用并提示 |
| `capabilities` | string[] | 是 | 见 §6；未知值一律拒绝加载（fail closed） |
| `actions` | object[] | 声明式必填 | `{id, title, trigger, command?/url?, match?}` |
| `hotkey` | string | 否 | 插件请求的快捷键；当前只登记不支持，见 §7.4 |
| `description` | string | 否 | 展示用 |
| `author` | string | 否 | 展示用 |

版本兼容策略：

- `manifestVersion` 不认识 → 拒绝加载，菜单提示“插件需要更新版 island”。
- `apiVersion` 与 island 支持区间无交集 → 禁用并提示。
- `minIslandVersion` 高于当前版本 → 禁用并提示。
- 未知的**可选**字段 → 忽略。
- 未知的**能力**或未知的 `kind` → 拒绝加载。[推断: fail closed 更安全] 置信度 高。

### 4.3 命令模板的注入边界

声明式的 `command` 与 `url` 支持变量替换：`{agent}` `{scenario}` `{sessionID}` `{title}` `{cwd}` `{completedAt}`。

- 必须**直接 exec**，不经 shell。[推断: 需避免 shell 注入] 置信度 高。
- `{title}` / `{cwd}` 来自 agent 落盘数据，属不可信输入，替换时必须按 argv 元素边界传参，不做字符串拼接。[推断:] 置信度 高。
- 命令路径必须来自 manifest 的固定数组，不允许变量出现在可执行文件位置。[推断:] 置信度 高。

### 4.4 脚本类插件的落点

| 方式 | 可行性 | 结论 |
|---|---|---|
| 进程内 `JavaScriptCore` | 实测可编译运行：`xcrun swiftc` + `import JavaScriptCore` 1.3 s 编译、运行成功，链接 `/System/Library/Frameworks/JavaScriptCore.framework`。[可得] 高。但 `check-layering.sh:27-33` 的允许清单里没有 JavaScriptCore | 备选，需改清单 |
| 子进程 `jsc` | 系统自带 `/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/Helpers/jsc`，实测 `jsc hello.js` 正常输出。[可得] 高 | 备选，且是一条零依赖、零覆盖率影响的路径 |
| AppleScript | 已有基础设施（`Subprocess.appleScript`，`Sources/Island/Subprocess.swift:44-50`），但首次控制某 app 会弹授权且 `osascript` 阻塞到用户回答。[可得] 高（`hai/CONTEXT.md:224`） | 只作为 island 代执行的动作，不作为插件 runtime |
| shell | 同上，且无隔离 | 只作为动作 |

`jsc` 的路径稳定性 [未验证] 中：需要跨 macOS 版本确认该 helper 一直存在。实验：在最低支持版本 macOS 13 的机器上 `ls` 该路径。若不稳定，退到“插件自带 Node 等运行时，由用户负责”。

---

## 5. 发现、生命周期与隔离

### 5.1 发现与加载顺序

1. 扫描 `~/Library/Application Support/island/plugins/*/plugin.json`。
2. 按 `id` 字典序排序，顺序固定。[推断: 确定性优先] 置信度 高。
3. 逐个校验 §4.2；校验失败的插件进入 `invalid` 状态，保留在列表里并显示原因。
4. 已禁用的插件（见 5.2）不 spawn，不连接。
5. 需要 island 主动触发的插件在首次有事件时才 spawn（惰性启动）。[推断: 省资源] 置信度 中。

### 5.2 启用与禁用

复用 `AgentScenarioSettings` 的既有模式：**只存被关掉的 id**，新插件默认开。[可得: `Sources/IslandCore/AgentProfile.swift:110-132,155-171`] 置信度 高。

- 存储键：`IslandDisabledPlugins`（`UserDefaults`，字符串数组）。
- UI：`Settings…` 新增 `Plugins` tab（现有 tab 由 `NSTabViewItem` 装配，`Sources/Island/HotkeySettingsWindow.swift:35,145,152`）。[可得] 高。
- 禁用动作：先发 `plugin.shutdown`，再 `SIGTERM`，超时后 `SIGKILL`。删除已上屏的插件行。

### 5.3 崩溃与超时隔离

| 项 | 取值 | 理由 |
|---|---|---|
| 单行上限 | 1 MiB | 防止插件一行吃光内存 [推断:] |
| 连接内请求超时 | 10 s | [推断:] |
| spawn 到 `hello` 超时 | 5 s | [推断:] |
| 心跳 | 30 s 无任何消息视为死 | [推断:] |
| 重启退避 | 1 s / 5 s / 30 s | [推断:] |
| 隔离阈值 | 5 分钟内 3 次崩溃 → 隔离（禁用 + 提示） | [推断:] |
| 进程组 | 独立 session，退出时连同子进程清理 | 防止插件留下孤儿进程 [推断:] |

island 侧已有 `Process` + `Pipe` 封装，但该封装在 `readDataToEndOfFile` 后调用 `waitUntilExit`（`Sources/Island/Subprocess.swift:20-33`），是**一次性命令**模型，不能直接用于长驻插件。长驻插件需要新的 streaming 读法。[可得] 高。

### 5.4 日志

- 插件 stdout / stderr 全部捕获，按行写 `~/Library/Logs/island-plugins/<pluginId>.log`。
- 单文件上限 1 MiB，保留 1 份轮转。[推断:] 置信度 中。
- island 自己退出时的 CLI 输出仍走 stderr（`hai/CONTEXT.md:33`）。[可得] 高。

### 5.5 卸载与失败的用户可见行为

- 卸载 = 删除插件目录。island 下一轮扫描发现目录消失即停止插件，并从 `IslandDisabledPlugins` 里清掉孤儿 id。[推断:] 置信度 中。
- 失败的用户可见行为：
  - 校验失败 / 版本不兼容 / 被隔离 → `Plugins` tab 里该行标红并给原因；菜单栏出现一行提示（与 `AutomationDenials` 的既有做法一致，`hai/CONTEXT.md:224`）。[推断: 复用既有模式] 置信度 中。
  - 单次崩溃 → 不打扰用户，只在日志与 tab 里记录。
  - 插件不上屏任何 island 无权限做的操作，宁可什么都不做。[推断:] 置信度 高。

---

## 6. 权限模型

### 6.1 能声明什么

| capability | 含义 | 由谁执行 |
|---|---|---|
| `tasks.read` | 读取任务字段（`AgentTask` 全部字段） | island 推送 |
| `notify.command` | 用命令模板做动作 | island 代执行（直接 exec，不过 shell） |
| `notify.url` | 打开 URL | island 代执行 |
| `ui.attention` | 让 island 弹一次提醒 / 计数 | island 执行 |
| `tasks.report` | 上报插件自己检测到的 run | island 校验后入库 |
| `terminal.focus` | 回到某个终端 tab | island 代执行（用 island 的 Apple Events 授权） |
| `paths.watch` | 声明要监视的目录（供 island 推送变更） | island 执行 |
| `network` | 声明会自己联网 | 插件自己，island 无法约束 |
| `hotkey.claim` | 请求一个快捷键 | 见 §7.4，暂不支持 |

### 6.2 不能声明什么

以下能力**不得**出现在 manifest 里；出现即拒绝加载：

- 在 island 进程内执行代码（`dlopen` / 注入 / 动态 framework）。
- 读写 island 的 `UserDefaults`（`com.commallama.island` 域）。
- 代表 island 直接发 Apple Event（必须经 `terminal.focus` 代理）。
- 修改 island 的 bundle、entitlements、登录项。

### 6.3 强制力的诚实说明

- island 没有 `app-sandbox` entitlement（实测发布版只有 `apple-events`，见 §1.1），插件进程拿到的是当前用户的全部权限。[可得] 高。
- 因此 capability 的强制力只到三处：**island 侧的代理执行**、**安装时的用户确认**、**审计日志**。[推断:] 置信度 高。
- island **不能**阻止一个独立进程自己读 `~/.claude`、自己发 `osascript`、自己联网。[推断:] 置信度 高。
- 更严格的做法：把插件跑在沙箱化的 helper 里（helper 带 `com.apple.security.app-sandbox` + 显式 entitlement，且必须与 island 同 Team ID 签名）。代价是签名、公证、bundle 结构都要改。[推断:] 置信度 中。**本次不建议做。**

[未验证] 中：插件子进程通过 `osascript` 发 Apple Event 时，TCC 是否记在 island（责任进程）名下、能否复用 island 的自动化授权。实验：给一个 ad-hoc probe 加 `apple-events` entitlement，spawn 一个子进程发 Apple Event 给 Terminal，看系统提示里的责任 app 是谁。该实验会弹系统授权框，需用户在场，本次未做。

---

## 7. 覆盖率与门禁的连带影响

### 7.1 代码落点

| 逻辑 | 落点 | 覆盖率要求 |
|---|---|---|
| `plugin.json` 解析、校验、版本兼容 | `Sources/IslandCore/PluginManifest.swift` | 100% |
| NDJSON 信封编解码（与 T1 共用） | `Sources/IslandCore/IPCEnvelope.swift` | 100% |
| capability 判定、模板展开、argv 构造 | `Sources/IslandCore/PluginCapability.swift` | 100% |
| 生命周期状态机（发现/启用/spawn/退避/隔离） | `Sources/IslandCore/PluginSupervisor.swift` | 100%，注入 `PluginProcessControlling` 协议 |
| socket server（T1 的） | `Sources/IslandCore/` + `Sources/Island/` 胶水 | 见 ipc.md |
| `Process` / `Pipe` / `Timer` / socket 实作 | `Sources/Island/PluginProcessHost.swift` | 显式排除 |

原则来自仓库既有约定：`IslandCore` 只做纯逻辑，`Sources/Island` 只做 AppKit / 系统 wiring，且该目录新文件必须加进 `coverage.config`。[可得: `hai/CONTEXT.md:98,190-196`] 置信度 高。

### 7.2 需要改的仓库文件（本次不做，仅列出）

1. `coverage.config`：追加 `Sources/Island/PluginProcessHost\.swift`（以及 T1 的 socket 胶水文件）。依据 `coverage.config:14-16` 与 `hai/CONTEXT.md:196`。[可得] 高。
2. `Sources/Island/HotkeySettingsWindow.swift`：加 `Plugins` tab。该文件已排除在覆盖率外（`coverage.config:24`）。[可得] 高。
3. 若选 JSC 路线：`scripts/check-layering.sh:28` 的允许清单要加 `JavaScriptCore`，否则 lint gate 直接红。[可得] 高。这是本方案唯一会碰到 lint gate 的地方。
4. `Package.swift`：不需要新 target（除非要做 library-evolution 的 dylib 方案）。[可得] 高。

### 7.3 覆盖率不会掉的前提

新代码全部放 `IslandCore` 并用注入替身测（现有做法：`SQLiteQuerying` / `NoSQLiteQuerying`，`Sources/IslandCore/AgentActivity.swift:29-32`）。[可得] 高。

`Sources/Island` 里的文件一次写完就加进 `coverage.config`，否则基线 100 会掉。[可得: `hai/CONTEXT.md:196`] 置信度 高。

### 7.4 快捷键

现状：全局热键只有一个，`EventHotKeyID` 的 id 硬编码为 1（`Sources/Island/HotkeyRegistrar.swift:47-50`）。[可得] 高。

结论：manifest 的 `hotkey` 字段**本次不支持**，接受声明但一律忽略并提示。[推断:] 置信度 高。多快捷键可行性由 task-3（panel.md）负责，本文不重复验证。

---

## 8. 发布与签名影响

| 场景 | 是否需要改 island 签名 / entitlements | 依据 |
|---|---|---|
| 声明式插件（只有 JSON） | 不需要 | 无新代码入 bundle。[推断: 由 §2.4 范围推出] 置信度 高 |
| 独立进程插件（用户自己放目录） | 不需要 | 不 dlopen、不改 bundle；实测 hardened 父进程可 spawn ad-hoc 子进程。[可得: probe F] 置信度 高 |
| 插件带自己的 Mach-O 可执行 | island 不需要；插件作者需要自己签名 | [推断:] 置信度 中 |
| island 内嵌 helper（XPC service、jsc 兜底、内置脚本宿主） | 需要：与 island 同 Team ID 签名、bundle 布局要加目录、重签后整体公证 | `build-app.sh:32-39` 现在只建 `MacOS`/`Resources`；`build-app.sh:86-92` 在拷贝之后签名，所以新内容必须在签名前拷入。[可得] 高 |
| 引入 `disable-library-validation` | 不建议 | 会让所有用户失去 library validation；实测该 entitlement 确实能让 dylib 加载成功。[可得: probe E] 置信度 高 |

[未验证] 中：带 `com.apple.quarantine` 的插件可执行文件在 spawn 时是否被 Gatekeeper 拦。实验：从浏览器下载一个 zip 解出插件目录，直接 `posix_spawn` 其中的二进制并观察 exit code。本次未做。若被拦，插件安装流程宜引导用户用 island 自己的 UI 导入（由 island 拷贝并 `xattr -dr com.apple.quarantine`，与 `ApplicationsMover` 的既有做法一致，`hai/CONTEXT.md:227`）。

---

## 9. 插件开发 skill 纲要

参考本机既有 skill 的写法：YAML frontmatter（`name` + `description`，description 里带触发词）+ Markdown 正文分节。[可得: `~/.agents/skills/android-ui-verify/SKILL.md:1-16`、`~/.agents/skills/dsh-plugin-ui/SKILL.md:1-6`] 置信度 高。

### 9.1 名称与触发

- 名称：`island-plugin`
- 触发条件：用户说“给 island 写插件”“island 插件”“island plugin”“让 island 完成时做 X”，或提到 island 的 `plugin.json` / 插件目录。

### 9.2 目录结构

```
~/.agents/skills/island-plugin/
  SKILL.md                 主流程与决策表
  references/manifest.md   plugin.json 全字段与校验规则
  references/protocol.md   信封字段、hello 握手、method 清单（引 ipc.md）
  references/permissions.md capability 表与禁止项
  templates/plugin.json    声明式最小骨架
  templates/process/       kind=process 的最小骨架（entry + 一条 log 上报）
```

### 9.3 必须步骤（skill 正文的骨架）

1. 必须判定插件层级：只改行为 → 声明式；要读新格式文件或要新逻辑 → `kind=process`。判据见 §2.4。
2. 必须按 `templates/` 建目录，`id` 与目录名一致。
3. 必须只声明真正用到的 capability；未知 capability 会被拒绝加载。
4. `kind=process` 时必须发出 `hello` 握手，并在 5 s 内完成。
5. 必须把用户可见文案写进插件自己的资源，不得指望 island 的 `TextKey`（编译期固定，`Localization.swift:35`）。
6. 必须处理 island 断开连接：重连并退避，5 分钟内 3 次失败即被隔离。
7. 必须自测：`Island --plugin-check <dir>`（建议新增的只读校验子命令）+ 手动跑一遍触发路径。
8. 不得请求 `dlopen`、`UserDefaults`、直发 Apple Event 这三类能力。

### 9.4 示例流程：聊天目标启动器

目标：在悬浮窗里给出“回到某个聊天”的动作。

1. 判定：只读 island 已有任务数据 + 打开一个 URL → 声明式。
2. `plugin.json`：`id: chat-target-launcher`，`capabilities: ["tasks.read", "notify.url"]`，`actions: [{id: "open-chat", title: "Open chat", trigger: "task.action", url: "claude://claude.ai/chat/{sessionID}"}]`。
3. 校验 `{sessionID}` 只出现在 URL 模板里，且做百分号编码。[推断:] 置信度 高。
4. 自测：装进插件目录，用 `--scan-agents` 找一条已完成 run，在悬浮窗里点该动作，确认 `claude://` 打开正确会话。
5. 若还要“启动一个新聊天并带上当前 cwd”，则升级为 `kind=process`，用 `terminal.focus` 之外的自有能力完成。

### 9.5 验证方式

- 静态：`Island --plugin-check <dir>` 打印校验结果与解析出的 capability。
- 协议：`nc -U` 手连 socket，发一行 `hello`，核对回执（T1 已实测该手法可行）。
- 端到端：`./scripts/demo.sh --check` 造完成事件（`hai/CONTEXT.md:30`），观察插件是否收到 `event`。[可得] 高。
- 回归：插件代码不在仓库内，`make verify` 不受影响。[推断:] 置信度 高。

---

## 10. 未决与待补

| 项 | 状态 | 需要的动作 |
|---|---|---|
| `ipc.md` 定稿 | 阻塞中 | 等 task-1 落盘后核对字段名；本文按 ipc-scout 回执写，形状承诺不变 |
| socket 文件权限 `0o755` 是否可接受 | [未验证] 中 | 检查同机其他用户能否连接；能连则改成 `0o700` |
| `hello` 的 token 传递方式（env 是否够） | [未验证] 中 | 验证 `ps -E` 能否读到子进程 env（macOS 上通常不能），确认不可泄露 |
| `jsc` helper 跨版本存在性 | [未验证] 中 | macOS 13 机器上确认路径 |
| TCC 责任进程归属 | [未验证] 中 | 见 §6.3 |
| quarantine 二进制的 spawn 行为 | [未验证] 中 | 见 §8 |
| 多快捷键 | 交给 task-3 | 见 §7.4 |
| 插件 UI 的本地化来源 | 未定 | 建议插件自带 `strings.json`，由 island 只做展示 |

**不可得（被什么挡住）**：

- 无法在本机验证“Developer ID 同 Team ID 的 dylib 能被 hardened island 加载”：本机 `0 valid identities found`，无法签 Developer ID。[可得] 高。只能由“异 Team ID 必失败”的实测 + library validation 的语义外推。[推断:] 置信度 高。
- 无法验证真实用户机器上 island 的行为差异：本次只对发布版做了静态签名检查，未运行发布版。[可得] 高。

---

## 11. 与仓库既有约定的冲突提醒

`hai/CONTEXT.md:191` 明确“所有行为开关走环境变量，不引入配置文件”。插件 manifest 天然是配置文件。[可得] 高。

[推断:] 二者可共存，但必须在文档里写清边界：**island 自身行为仍只走 `ISLAND_*` 环境变量；`plugin.json` 只描述第三方插件的接口，不参与 island 自身行为配置**。置信度 中。这条边界宜写进 `hai/CONTEXT.md` 与 `PLAN.md`，但二者都不是本次可改的文件。[可得] 高。

---

## 12. 实验产物与复现命令

| 产物 | 内容 | 复现 |
|---|---|---|
| `.build/probe/plugin/evidence-codesign.txt` | 发布版 0.2.3 的签名、entitlements、bundle 结构 | 下载 `island-v0.2.3` dmg，`hdiutil attach -readonly -nobrowse`，`codesign -dvvv` / `-d --entitlements -`，用完 detach |
| `.build/probe/plugin/libval/` | 9 组实测组合：hardened/ad-hoc × 未签名/adhoc dylib、entitlement 逃生口、父进程 spawn、`DYLD_*` | `clang -shared -o libplugin.dylib plugin.c`；`clang -o host-runtime host.c`；`codesign --force --options runtime --sign - host-runtime`；`./host-runtime "$PWD/libplugin.dylib"` |
| `.build/probe/plugin/xpc/` | mach service listener 与 client 的连通性 | `./xpcserver &` 后 `./xpcclient`，观察 `CLIENT: invalidated` |
| `.build/probe/plugin/jsc/` | `import JavaScriptCore` 编译运行 + `jsc` 子进程 | `xcrun swiftc -o jsc jsc.swift && ./jsc`；`/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/Helpers/jsc hello.js` |

未跑 `swift build` / `swift test` / `make verify`。本次所有编译都用 `swiftc` 或 `clang` 单独完成，不触碰仓库 `.build` 里的构建产物。
