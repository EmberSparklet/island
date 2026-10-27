# 面板快速启动与多快捷键可行性调研

> 调研需求 2 的举例：悬浮窗快速输入一段话，然后打开指定 chat 智能体。
> 调研需求 3：面板展示已安装智能体、快速切换、内部快捷键。
> 工作目录为 island 仓库根目录，只读调研，未改动仓库内任何 tracked 文件（`git status --porcelain` 为空）。
> 实测产物在 `.build/probe/panel/`（**未入库**，`.build/` 被清理后失效）。本机：macOS 27.0.1，Xcode 27.1 / Swift 6.4。

## 0. 结论摘要

1. 现有键盘模式可以承载“输入一段话”，但不能承载“打开 chat”。搜索框是任务过滤器，不是输入框：`OverlaySelection.setQuery` 只做过滤，`↩` 只对已选中的任务行生效。
2. 现有全局快捷键架构是“一个进程一个键”。`HotkeyRegistrar` 只持有 1 个 `EventHotKeyRef`，注册新键前先 `unregister()`。多键需要改造，但 Carbon 本身支持，已实测。
3. 跨 app 的快捷键冲突 **不会** 报错。实测 `RegisterEventHotKey` 在别的 app 已占用同一组合时仍返回 `noErr`。CONTEXT.md:211 描述的“macOS 拒绝新键”只对同进程重复注册成立（返回 `-9878`）。
4. 本机 chat 目标可用性差异极大。`chat.deepseek.com` 原生支持 `?q=` 且带 `autosend` 参数，[可得]；`chatgpt.com` 本机网络不可达，`claude.ai` 本机区域受限，两者都 [不可得]。
5. 覆盖率排除是**逐文件列表**，不是整目录。`coverage.config` 现在列了 `Sources/Island/` 下全部 24 个文件。新增文件必须同步加入，否则 100 的基线会掉。

## 1. 悬浮窗现状

### 1.1 两种模式的差异

| 维度 | 键盘模式（召唤） | 被动模式（自动弹出） |
|---|---|---|
| 触发 | 全局快捷键、菜单 `Summon overlay` | 一轮 agent 任务跑完 |
| 拿键盘 | 是 | 否 |
| 标题行 | 整行搜索框 + `N new` 胶囊 | `● N new` + 快捷键键帽 |
| 收场 | 失焦即收起，无计时 | `IslandPopupSeconds` 秒后自动隐藏，hover 暂停 |

出处：

- 两种模式的分支在 `Sources/Island/AppDelegate.swift:251` 的 `showOverlay(interactive:)`。
- `Sources/Island/AppDelegate.swift:257` 设 `panel.acceptsKeyboard = interactive`；`:258` 调 `content.setKeyboardMode(interactive)`。
- `Sources/Island/AppDelegate.swift:260`-`262` 键盘模式走 `makeKeyAndOrderFront` + `focusQuery()`；`:265` 被动模式走 `orderFrontRegardless()`。
- 标题行切换在 `Sources/Island/OverlayContent.swift:174`-`181`。
- 模式语义的注释在 `Sources/Island/OverlayContent.swift:8`-`12` 与 `Sources/Island/OverlayPanel.swift:6`-`9`。
- 被动模式不降级键盘模式的判断在 `Sources/Island/AppDelegate.swift:253`。
- 两种模式的完整说明在 `hai/CONTEXT.md:232`。

[可得] 置信度：高。

### 1.2 “自动弹出绝不抢焦点”这条不变量

不变量由 3 处代码共同保证：

1. `Sources/Island/OverlayPanel.swift:35`：`override var canBecomeKey: Bool { acceptsKeyboard }`。`acceptsKeyboard` 为 false 时窗口不能成为 key window。
2. `Sources/Island/OverlayPanel.swift:18`：styleMask 含 `.nonactivatingPanel`。成为 key 也不激活 island 进程。
3. `Sources/Island/AppDelegate.swift:257`：`acceptsKeyboard` 只在 `interactive == true` 时为 true。

自动弹出的路径是 `Sources/Island/AppDelegate.swift:162`（`alerted` 为真时调 `showOverlay()`，用默认参数 `interactive: false`），`Sources/Island/AppDelegate.swift:144` 的启动首弹同理。

[可得] 置信度：高。出处另有 `hai/CONTEXT.md:202`。

### 1.3 失焦行为

- `Sources/Island/OverlayPanel.swift:38`-`41`：`resignKey()` 转发给 `onResignKey`。
- `Sources/Island/AppDelegate.swift:78`-`82`：回调里先判断 `acceptsKeyboard == true`，再 `hideOverlay`。这层判断是防重入的，注释写在 `:79`。
- `Sources/Island/AppDelegate.swift:389`-`396`：`hideOverlay` 先清 `acceptsKeyboard` 再 `orderOut`。

[可得] 置信度：高。

### 1.4 搜索框现在做什么

搜索框是**任务过滤器**，不是文本输入：

- `Sources/Island/OverlayContent.swift:351`-`354`：`controlTextDidChange` → `selection.setQuery(searchField.stringValue)`。
- `Sources/IslandCore/OverlaySelection.swift:42`-`45`：`setQuery` 只改 `query` 再 `refilter`。
- `Sources/IslandCore/OverlaySelection.swift:69`-`76`：`refilter` 用 `TaskFilter.matches` 过滤标题、目录名、agent 名（`Sources/IslandCore/OverlaySelection.swift:7`-`14`）。
- `Sources/Island/OverlayContent.swift:366`-`367`：`↩` 调 `onSelect?(selection.selected)`。`selection.selected` 在 `rows` 为空时是 nil（`Sources/IslandCore/OverlaySelection.swift:74`），此时 `↩` 被吞掉、什么都不发生。
- 输入框是单行：`Sources/Island/OverlayContent.swift:276` 设 `usesSingleLineMode = true`，`:277` 设 `lineBreakMode = .byTruncatingTail`。

[可得] 置信度：高。

### 1.5 “快速输入一段话然后打开目标 chat”能否复用键盘模式

结论：**不能直接复用，需要新增一层“compose 模式”**。

可以复用 3 项：

- 拿键盘的整套机制（`acceptsKeyboard`、`makeKeyAndOrderFront`、`focusQuery`）现成，出处见 1.1。
- 面板尺寸随内容变化：`Sources/Island/AppDelegate.swift:71`-`73` 的 `onHeightChange` → `panel.setContentSize`。
- 键帽控件 `KeycapView`（`Sources/Island/OverlayContent.swift:527`）可直接用于“目标 chat 的选择键”。

差在哪（缺口）：

| 缺口 | 现状出处 | 需要新增 |
|---|---|---|
| 没有“自由文本”概念 | `OverlayContent.swift:352` 输入即过滤 | 一个 compose 状态，与 filter 状态互斥 |
| `↩` 不提交自由文本 | `OverlayContent.swift:367` 只在有选中行时动作 | 无匹配行时把 query 当问题提交 |
| 输入框单行、会截断 | `OverlayContent.swift:276`-`277` | 多行或至少不截断的输入控件 |
| 没有“目标 chat”列表 | 行模型只有 `AgentInbox.Entry`（`Sources/IslandCore/AgentInbox.swift:20`） | 目标清单的数据模型 |
| 没有提交动作 | `OverlayContent` 只有 `onSelect`/`onDismiss`/`onOpenSettings`（`:24`-`30`） | `onSubmit(question, target)` 回调 |

推断: 最小改动是在 `OverlayContentView` 加一个 compose 状态；`isKeyboardMode` 为真且 query 非空且 `selection.rows` 为空时，`↩` 走提交而不是选择。改动面集中在 `OverlayContent.swift` 与 `OverlaySelection.swift`。

置信度：中。依据是上述 5 处代码事实；未做原型验证。

## 2. 全局快捷键现状与多快捷键可行性

### 2.1 现在能注册几个键

**一个**。

- `Sources/Island/HotkeyRegistrar.swift:30`：只持有 1 个 `private var hotKeyRef: EventHotKeyRef?`。
- `Sources/Island/HotkeyRegistrar.swift:42`-`57`：`register` 第一行就 `unregister()`，然后注册 1 个键。
- `Sources/Island/HotkeyRegistrar.swift:50`：`EventHotKeyID(signature: 'ISLN', id: 1)`，id 写死为 1。
- `Sources/Island/HotkeyRegistrar.swift:72`-`79`：事件回调**不读** `EventHotKeyID`，直接调 `handler()`。多键时无法区分是哪一个被按。

[可得] 置信度：高。

### 2.2 Carbon 多次注册的可行性（实测）

实测脚本：`.build/probe/panel/hotkey_probe.swift`，输出 `.build/probe/panel/hotkey_probe.out`。

| 实验 | 结果 | 结论 |
|---|---|---|
| 一个进程注册 3 个不同组合（id 1/2/3） | 全部 `status=0`，都拿到 ref | 多键注册 [可得] |
| 回调里用 `GetEventParameter(kEventParamDirectObject, typeEventHotKeyID)` 读 id | `status=0`，id 分别读出 1/2/3 | 按 id 分发 [可得] |
| 同进程重复注册同一组合，id 不同 | `status=-9878`（`eventHotKeyExistsErr`） | 冲突按组合判定，不按 id 判定 |
| 注销 id=2 后再发 id=1/2 | 回调仍触发 2 次 | 逐个注销不破坏其他键 |

原始输出：

```
-- B. three distinct hotkeys in one process
register ctrl+cmd+, (id=1): status=0 gotRef=true
register ctrl+cmd+. (id=2): status=0 gotRef=true
register ctrl+opt+/ (id=3): status=0 gotRef=true
-- D. synthesizing kEventHotKeyPressed for each id
  handler: GetEventParameter status=0 id=1 sig=1230195790
  handler: GetEventParameter status=0 id=2 sig=1230195790
  handler: GetEventParameter status=0 id=3 sig=1230195790
-- C. registering ctrl+cmd+, a second time in the same process
register ctrl+cmd+, again (id=91): status=-9878 gotRef=false
```

[可得] 置信度：高（本机实测）。

### 2.3 键冲突的报错与回滚路径

**跨 app 冲突不报错。** 实测：island 正在运行（pid 59924，`IslandHotkeyText=cmd+z`），此时另一个进程注册 `cmd+z`，`status=0`、拿到 ref。

第二个实验更直接：`.build/probe/panel/hotkey_dup.swift`，holder 进程先注册 `ctrl+opt+9` 并保持 4 秒，另两个进程随后注册同一组合，全部 `status=0`。

```
hold key=25 mods=6144 id=7 status=0 gotRef=true
try key=25 mods=6144 id=8 status=0 gotRef=true
try key=25 mods=6144 id=9 status=0 gotRef=true
```

这意味着：

- `hai/CONTEXT.md:211` 写的“macOS 拒绝新键（被别的 app 占用）时会把旧键重新注册回来”在本机**无法复现**。能触发 `HotkeyApplyOutcome.registrationFailed`（`Sources/IslandCore/HotkeySettings.swift:23`）的只有同进程重复注册（`-9878`）这类情况。
- 回滚代码本身在 `Sources/IslandCore/HotkeySettings.swift:85`-`89`，逻辑正确，只是覆盖不到跨 app 冲突。

[不可得] 置信度：高（本机实测）。被挡住的是：Carbon 没有“查询某组合被谁占用”的 API，注册成功也不代表这个键真的会送到本进程。

[未验证] 同一组合被两个 app 注册时，实际按键送到哪一个。要确认需要：让 holder 与 challenger 各自把回调写进文件，再用一次真实按键触发；真实按键需要辅助功能授权，而本机探测进程 `AXIsProcessTrusted() == false`（`.build/probe/panel/axcheck.out`），无法投递合成按键。置信度：高（未验证原因清楚）。

### 2.4 为每个智能体注册独立全局键的最小新增面

复用点：

- `HotkeySpec`（`Sources/IslandCore/HotkeySpec.swift:5`）已经是通用值类型，含 `keyCode`、`modifiers`、`specText`（`:39`）、`displayString`（`:45`），可直接复用，不必新建类型。
- 键位表 `virtualKeyCodes`（`Sources/IslandCore/HotkeySpec.swift:132`）覆盖 a–z、0–9、常用符号与 return/tab/space/escape。
- 持久化约定：`UserDefaultsHotkeyStore` 的 key 是 `IslandHotkeyText` / `IslandHotkeyEnabled`（`Sources/IslandCore/HotkeySettings.swift:123`-`124`）。按 `hai/CONTEXT.md:238`，应用内改键立即写 `UserDefaults`。
- 录键控件 `HotkeyRecorderView`（`Sources/Island/HotkeyRecorderView.swift:13`）可复用。录键控件与 `HotkeySpec.captured` 的映射在 `Sources/Island/HotkeyRecorderView.swift:98`-`117`。
- 换绑不变量（app 不会没有可用快捷键）的守卫在 `Sources/IslandCore/HotkeySettings.swift:35`-`38` 与 `:80`-`90`。多键方案必须保住这条，只作用于“召唤键”。

需要新增（最小面）：

1. `HotkeyRegistrar` 改为持有 `[UInt32: EventHotKeyRef]`，按 `EventHotKeyID.id` 分发；回调签名从 `() -> Void` 变为 `(UInt32) -> Void`。
2. `HotkeyRegistering` 协议（`Sources/IslandCore/HotkeySettings.swift:5`）加一个按 id 注册/注销的方法。协议在 IslandCore，测试里的假注册器要同步改。
3. 一个 per-agent 键位存储：新 `UserDefaults` key，例如 `IslandAgentHotkeys`，值是 `agent -> specText` 的字典。
4. 冲突处理：同进程重复注册返回 `-9878` 时，per-agent 键应放弃并提示；召唤键保持 2.3 的回滚路径不变。

推断: 改动量约 3 个文件 + 1 个新存储类型。键位解析与冲突判定可放 IslandCore，保持 100% 覆盖。置信度：中。

## 3. “已安装智能体”的判定手段

### 3.1 两类清单必须分开

- **A 类：island 已支持的 agent**。由 `AgentKind`（`Sources/IslandCore/AgentTask.swift:5`-`10`）定义，共 4 个：`claude-code`、`claude-desktop`、`pi`、`codex`。
- **B 类：可作为 chat 目标的应用或网站**。仓库内**无证据**，没有任何类型或常量描述这类目标。

### 3.2 探测口径与实测结果

| 口径 | 命令或 API | 本机实测结果 |
|---|---|---|
| 已安装 app 的 bundle id | 读 `/Applications/*/Contents/Info.plist` 的 `CFBundleIdentifier` | 见 `.build/probe/panel/bundleid_probe.out`，33 个 app |
| 按 bundle id 找 app | `NSWorkspace.urlForApplication(withBundleIdentifier:)` | 可用；未安装返回 nil |
| 按 bundle id 找全部副本 | `LSCopyApplicationURLsForBundleIdentifier` | 可用；返回 `[URL]`，未安装 count=0 |
| 注册的 URL scheme | `lsregister -dump` 的 `bindings:` 行 | 125 个 scheme，见 `.build/probe/panel/schemes.txt` |
| CLI 是否安装 | `command -v` / 进程表 | 见下 |

A 类 4 个 agent 的本机状态（实测）：

| agent | 判据 | 结果 |
|---|---|---|
| `claude-code` | `command -v claude`（含 `zsh -lc`）、`~/.claude`、`com.anthropic.claudefordesktop` | 三项都无 → 未安装 |
| `claude-desktop` | `com.anthropic.claudefordesktop` | 未安装 |
| `pi` | `/opt/homebrew/bin/pi`、`~/.pi` | 已安装 |
| `codex` | `/opt/homebrew/bin/codex`、`~/.codex`；桌面场景要 `com.openai.codex` | CLI 已安装；`ChatGPT.app` 未安装 |

B 类候选（chat 目标）实测：

| 目标 | 判据 | 结果 |
|---|---|---|
| DeepSeek Harness.app | `com.deepseek.dsh`，scheme `dsh:` | 已安装 |
| `chat.deepseek.com` | curl HTTP 200 | 可达 |
| `www.kimi.com` | curl HTTP 200 | 可达 |
| `chatgpt.com` | DNS 解析到 162.125.8.1，curl 20 秒超时 | 不可达 |
| `claude.ai` | curl 跟随重定向到 `claude.com/app-unavailable-in-region` | 区域受限 |

[可得] 置信度：高（本机实测）。

说明：`AgentIcon.bundleIDs(for:)`（`Sources/IslandCore/OverlayTheme.swift:179`）就是 `agent.profile.appBundleIDs`，`AgentProfile.appBundleIDs` 在 `Sources/IslandCore/AgentProfile.swift:62`。现有写法只有 bundle id，没有 CLI 判据。

### 3.3 CLI 探测的坑

`Sources/Island/Subprocess.swift:17`-`19` 用 `Process` 且不设 `environment`，子进程继承 island 的 PATH。island 由 launchd 启动（pid 59924 的 ppid 是 1），PATH 不一定等于用户登录 shell 的 PATH。

实测当前实例 `ps eww -p 59924` 的 PATH **含** `/opt/homebrew/bin`，所以 `pi` / `codex` 能被找到。

[未验证] 开机自启（`SMAppService.mainApp`，`hai/CONTEXT.md:207`）启动的实例是否也有同样的 PATH。要确认需要：注销当前实例，重启登录后重新读 `ps eww` 的 PATH。

推断: 不应依赖 PATH。仓库自己的先例是硬编码绝对路径：`Sources/Island/AgentReopenExecutor.swift:15`-`20` 的 `tmuxCandidates` 逐个探测 `/opt/homebrew/bin/tmux`、`/usr/local/bin/tmux` 等。新代码宜照此写法。置信度：中。

## 4. “打开并带上问题”三策略可得性

### 4.1 策略一：URL 模板 / 查询参数

| 目标 | 形式 | 结论 | 依据 |
|---|---|---|---|
| DeepSeek 网页 | `https://chat.deepseek.com/?q=<问题>` | [可得] 高 | 读站点 bundle 源码 |
| DeepSeek 网页附加参数 | `mode` / `search` / `thinking` / `autosend` / `source` | [可得] 高 | 同上 |
| ChatGPT 网页 | `https://chatgpt.com/?q=` 或 `?prompt=` | [不可得] 高（本机） | 本机网络不可达；另 OpenAI 无官方参数文档 |
| Claude 桌面 | `claude://claude.ai/new?q=<问题>` | [可得] 高（协议层） | Anthropic 官方帮助中心；本机未安装 Claude.app |
| Claude 网页 | `https://claude.ai/new?q=` | [不可得] 高（本机） | 本机区域受限 |
| Kimi 网页 | `https://www.kimi.com/?q=` | [未验证] 中 | SEO bundle 里没有 `q` 参数处理 |

仓库已有深链先例：`AgentReopenAction.openURL`（`Sources/IslandCore/AgentReopen.swift:110`）在 `:182` 被选为桌面 agent 的首选动作，执行在 `Sources/Island/AgentReopenExecutor.swift:61`-`66`，打不开再激活 app。Claude 桌面版走的就是 `claude://claude.ai/chat/<uuid>`（`hai/reference/agents/README.md:112`）。

DeepSeek 的原始证据（`chat.deepseek.com` 主 bundle，`.build/probe/panel/deepseek_main.js`）：

```js
let s=new URL(window.location.href),
a=(null==(r=(null==(n=(e=s.searchParams).get("q"))?void 0:n.trim())?n:e.get("prompt"))?void 0:r.trim())
  ?{prompt:r,
    modelType:(t=e.get("mode"),e8.find(e=>e===t)||null),
    searchEnabled:e6(e.get("search")),
    thinkingEnabled:e6(e.get("thinking")),
    autoSend:"1"===e.get("autosend")&&r.length<=800,
    source:"landing"===e.get("source")?"landing":void 0}
  :null;
```

要点：

- `q` 优先，`prompt` 兜底。
- `autosend=1` 且文本不超过 800 字时**自动发送**。不带 `autosend` 时只填入、等用户确认。
- 该逻辑有前置判断 `if(!(0,eX.B6)(e$.a$.ROOT,window.location.pathname))return;`，只在站点根路径上生效。
- 触发后会从地址栏删掉 `q` / `prompt`。

ChatGPT 的第三方依据：[ChatGPT 網站的 Query String 參數](https://blog.poychang.net/chatgpt-url-query-parameters/) 记录 `prompt` 与 `q`（`q` 是 `prompt` 的兼容形式），并明确 OpenAI 没有公开这套参数的规格。[Simon Willison 的说明](https://simonwillison.net/2025/Apr/14/llms-as-the-first-line-of-support/) 补充：`https://chatgpt.com/?q=` 会**直接执行**提示词，不等用户编辑。

Claude 的官方依据：[Open Claude Desktop with a link](https://support.claude.com/en/articles/14729294-open-claude-desktop-with-a-link) 记录 `claude://claude.ai/new?q=`，`q` 填入输入框等用户发送，文本截断到约 14000 字。同一页面还记录 `claude://code/new?q=&folder=` 与 `claude://cowork/new?q=`。

Kimi 的实测：`https://www.kimi.com/` 返回的 142 KB 页面来自 `kimi-web-seo` 包（`.build/probe/panel/kimi_index.js`，2.0 MB），其中 6 处 `searchParams` 全部与 `q`/`prompt` 无关，只读 `inviteType`/`roomId`/`ticket`/`source`。该 bundle 是站点首页，不是聊天主体。

[未验证] Kimi 网页是否支持 `?q=`。要确认需要：打开 `https://www.kimi.com/?q=测试` 一次，看输入框是否预填。本机网络可达，成本低。

### 4.2 策略二：剪贴板兜底

[可得] 置信度：高。现成代码：

- `Sources/Island/AgentReopenExecutor.swift:204`-`209`：`NSPasteboard.general.clearContents()` + `setString`。
- 调用点在 `Sources/Island/AgentReopenExecutor.swift:196`-`202` 与 `:67`-`68`。
- 决策层 `AgentReopenAction.copyToClipboard` 在 `Sources/IslandCore/AgentReopen.swift:111`，触发条件在 `:186`-`188`。

局限：只把文本放进剪贴板，用户还要自己粘贴。对新需求来说，剪贴板是“问题已就绪”的兜底，不是“打开并带上问题”。

### 4.3 策略三：辅助功能注入粘贴

[不可得]（当前仓库范围内）置信度：高。

事实：

- 仓库内**没有任何**辅助功能或合成事件的代码。`grep -rn "AXUIElement|AXIsProcessTrusted|CGEvent" Sources/` 无结果。
- island 现在只需要一种授权：自动化（Apple Events），用于控制终端 app。出处 `hai/CONTEXT.md:224`，代码在 `Sources/Island/Subprocess.swift:44`-`50` 与 `Sources/IslandCore/AutomationPermission.swift:16`。entitlements 只有 `com.apple.security.automation.apple-events` 一项（`scripts/Island.entitlements`），Info.plist 只有 `NSAppleEventsUsageDescription` 一项（`scripts/build-app.sh:70`）。
- 注入粘贴需要的是**辅助功能**授权，是另一项授权。`AXIsProcessTrustedWithOptions`、`AXUIElementCopyAttributeValue`、`AXUIElementSetAttributeValue`、`CGEvent.postToPid` 在本机 SDK 中都存在（`.build/probe/panel/api_typecheck.swift`，`swiftc -typecheck` 通过）。
- 本机探测进程 `AXIsProcessTrusted() == false`（`.build/probe/panel/axcheck.out`）。

代价：

- 新增一项授权弹窗，与 `hai/CONTEXT.md:200` 记录的“Carbon 不需要任何授权”这一 POC 结论冲突。
- `hai/CONTEXT.md:246` 记录了一条既有约定：可见性判断绝不弹授权框。注入粘贴无法遵守这条。

推断: 若要做，宜作为可选增强，默认关闭。置信度：中。

### 4.4 汇总表

| 策略 | 结论 | 置信度 | 被什么挡住 / 要做什么实验 |
|---|---|---|---|
| URL 参数（DeepSeek） | [可得] | 高 | 无 |
| URL 参数（ChatGPT） | [不可得] | 高 | 本机网络不可达；且无官方参数规格 |
| URL 参数（Claude 桌面 `claude://`） | [可得]（协议层） | 高 | 本机未安装 Claude.app，无法端到端验证 |
| URL 参数（Claude 网页） | [不可得] | 高 | 本机区域受限 |
| URL 参数（Kimi 网页） | [未验证] | 中 | 打开一次 `www.kimi.com/?q=测试` 看是否预填 |
| 剪贴板兜底 | [可得] | 高 | 无 |
| 辅助功能注入 | [不可得]（现有范围内） | 高 | 需新增辅助功能授权，与既有约定冲突 |

## 5. 与 TaskRow / task 列表 UI 的耦合

### 5.1 现状结构

- 列表是**扁平的 `NSStackView`**，没有 section 概念。出处 `Sources/Island/OverlayContent.swift:53`（`private let list = NSStackView()`）与 `:294`-`297`。
- 每行是 `OverlayTaskRowView`，构造于 `Sources/Island/OverlayContent.swift:117`-`120`，类型定义在 `:572`。
- 行高固定 52pt（`Sources/Island/OverlayContent.swift:16`），面板高度按行数算（`:72`-`76`）。
- 行数据来源唯一：`OverlaySelection.rows`，类型 `[AgentInbox.Entry]`（`Sources/IslandCore/OverlaySelection.swift:21`）。
- `OverlaySelection` 提供 `entry(forShortcut:)`（`:60`）与 `keycapLabel(row:)`（`:65`），都建立在“行就是任务”这个前提上。

### 5.2 新增“启动器行”的两种做法

| 做法 | 改动面 | 风险 |
|---|---|---|
| 新增 section | `OverlayContent.render()` 要分两段渲染；`preferredHeight` 要加段间距；`OverlaySelection` 要区分段 | 改动分散在 3 处；`OverlaySelection` 的 100% 覆盖测试要重写 |
| 新增 row kind | `OverlaySelection.rows` 从 `[Entry]` 变成枚举数组；`entry(forShortcut:)`、`keycapLabel`、`refreshHighlight`、`onSelect` 全部要改类型 | 改动集中在 IslandCore，测试集中；但 `AgentInbox.Entry` 的用法散在 `AppDelegate`、`StatusItemController` |

推断: 第三种更省的做法是让启动器**不进 `OverlaySelection`**，而是作为键盘模式下的一个独立模式（见 1.5）。此时 `OverlaySelection`、`AgentInbox` 一行不改，`AgentInbox.Entry` 也不动。置信度：中。

### 5.3 纯逻辑模型的影响面

- `AgentInbox`（`Sources/IslandCore/AgentInbox.swift:19`）：只负责任务增量、已读、排序、上限。启动器与 `AgentInbox` 无关。**影响面为零**。
- `OverlaySelection`（`Sources/IslandCore/OverlaySelection.swift:19`）：只负责过滤与高亮。若启动器独立成模式，**影响面为零**；若混进同一个列表，影响面为整个文件。
- `TaskFilter`（`Sources/IslandCore/OverlaySelection.swift:4`）：只匹配任务字段。启动器若要走搜索框，需要扩展匹配范围。
- `Localization`：新增文案 = `TextKey` 加 case + `englishTexts` + `chineseTexts` 各一条（`hai/CONTEXT.md:194`）。现有 120 个 case，`overlayHints` 在 `Sources/IslandCore/Localization.swift:44`。`LocalizationTests` 强制两张表 key 集合一致。
- 覆盖率：`IslandCore` 新增文件自动进统计，基线是 100（`coverage-baseline.txt`），必须写满测试。`Sources/Island/` 的新文件必须手工加进 `coverage.config`，否则基线掉。出处 `hai/CONTEXT.md:196`。

说明：任务书写“`Sources/Island`（AppKit wiring，整目录从覆盖率排除）”。实际机制是**逐文件**列表。`coverage.config` 现在列了该目录下全部 24 个文件，与磁盘文件一一对应（已核对，无遗漏、无多余）。结论不变。新增文件时**必须手工加一行**。

## 6. 风险清单

| 风险 | 现状依据 | 影响 | 缓解 |
|---|---|---|---|
| 抢焦点 | `OverlayPanel.swift:35`、`AppDelegate.swift:257` | 破坏核心不变量 | compose 模式只允许在 `interactive == true` 下进入；不得改 `showOverlay()` 的默认参数 |
| 快捷键被其他 app 占用，且无法检测 | 实测见 2.3 | per-agent 键可能静默失效 | 不做“注册成功即可用”的假设；提供面板内键位选择作为主路径，全局键作为可选增强 |
| 同进程重复注册 | `hotkey_probe.out`，返回 `-9878` | 两个 agent 绑同一组合时第二个失败 | 注册前查重，失败时提示并保留原键 |
| 中文输入法下取键 | `hai/CONTEXT.md:204`，`OverlayShortcut.swift:15` | 全角字符导致匹配失败 | 复用 `OverlayShortcut.parse` 的 `fullwidthToHalfwidth` 归一；新增组合键时同样归一 |
| 输入法组合中的 `↩` | `OverlayContentView.control(_:textView:doCommandBy:)`（`OverlayContent.swift:356`）只在文本视图提交后触发 | 中文候选未上屏时按 `↩` 的语义与英文不同 | [未验证]：需要在拼音输入法下实测 compose 提交行为 |
| 多屏 | `OverlayPanel.swift:54` 用 `NSScreen.main` | 面板总是出现在一个屏幕上 | 现有行为，本次不改；若要做启动器，保持同一位置逻辑 |
| 启动器行与任务行的视觉冲突 | 行高 52pt（`OverlayContent.swift:16`），`⌘1`–`⌘9` 已被任务行占用（`OverlayContent.swift:377`-`392`） | 键位与视觉都会撞 | 启动器用不同修饰键（如 `⌘⌥1`–`⌘⌥9`）；或启动器独立成模式后各自占用 `⌘N` |
| 输入框单行截断 | `OverlayContent.swift:276`-`277` | 长问题看不全 | compose 模式改用多行控件 |
| ChatGPT `?q=` 会直接发送 | 见 4.1 外部依据 | 用户没确认就发出问题 | 该目标本机不可达；若将来支持，默认不带“自动发送”类参数 |
| 新增文件漏加覆盖率排除 | `coverage.config`、`hai/CONTEXT.md:196` | `make verify` 的 coverage gate 失败 | 新增 `Sources/Island/` 文件时同步加一行 |

## 7. 可复用点清单

| 可复用点 | 位置 |
|---|---|
| 拿键盘的整套机制 | `OverlayPanel.swift:35`、`AppDelegate.swift:257`-`262` |
| 键帽控件 | `OverlayContent.swift:527` |
| 面板随内容改高 | `AppDelegate.swift:71`-`73` |
| 快捷键值类型与解析 | `HotkeySpec.swift:5`、`:76`、`:110` |
| 录键控件 | `HotkeyRecorderView.swift:13` |
| 换绑回滚不变量 | `HotkeySettings.swift:80`-`90` |
| 全角归一 | `OverlayShortcut.swift:15` |
| 剪贴板写入 | `AgentReopenExecutor.swift:204`-`209` |
| 打开 URL | `AgentReopenExecutor.swift:61`-`66` |
| bundle id 探测 | `OverlayTheme.swift:179`、`AgentProfile.swift:62` |
| 绝对路径探测 CLI 的写法 | `AgentReopenExecutor.swift:15`-`20` |
| 菜单兜底入口 | `StatusItemController.swift:110`-`113`、`:160`-`170` |
| 本地化表 | `Localization.swift:44`，约定见 `hai/CONTEXT.md:194` |

## 8. 缺口清单

1. 没有“自由文本提交”路径。`↩` 在无匹配行时被吞掉（`OverlayContent.swift:367`）。
2. 没有“chat 目标”数据模型。仓库内无证据。
3. 没有多键注册能力。`HotkeyRegistrar` 单 ref、单 id（`HotkeyRegistrar.swift:30`、`:50`）。
4. 没有按 id 分发的事件处理。回调忽略 `EventHotKeyID`（`HotkeyRegistrar.swift:72`-`79`）。
5. 没有 per-agent 键位持久化。现有只有单个 `IslandHotkeyText`（`HotkeySettings.swift:123`）。
6. 没有辅助功能授权路径。仓库内无 AX 代码。
7. 跨 app 快捷键冲突不可检测（实测 2.3）。
8. 没有多行输入控件。搜索框是单行（`OverlayContent.swift:276`）。
9. 新增 `Sources/Island/` 文件要手工加 `coverage.config`，没有自动化（`hai/CONTEXT.md:196`）。

## 9. 实测命令与原始输出

产物目录：`.build/probe/panel/`。

| 文件 | 内容 |
|---|---|
| `hotkey_probe.swift` / `hotkey_probe.out` | 多键注册、按 id 分发、同进程重复注册 |
| `hotkey_dup.swift` / `hotkey_dup.out` | 跨进程重复注册 |
| `bundleid_probe.swift` / `bundleid_probe.out` | `NSWorkspace.urlForApplication`、`LSCopyApplicationURLsForBundleIdentifier`、`/Applications` 清单 |
| `api_typecheck.swift` | SDK API 存在性（`swiftc -typecheck` 通过） |
| `axcheck.swift` / `axcheck.out` | `AXIsProcessTrusted() == false` |
| `schemes.txt` | 系统注册的 125 个 URL scheme |
| `deepseek_main.js` | DeepSeek 网页主 bundle，含 `q` 参数处理源码 |
| `kimi_index.js` | Kimi 首页 bundle |
| `lsregister.txt` | 空文件（`lsregister -dump` 被 timeout 截断），未采用 |

复现命令：

```bash
cd .build/probe/panel
swiftc -o hotkey_probe hotkey_probe.swift && ./hotkey_probe
swiftc -o hotkey_dup hotkey_dup.swift
swiftc -o bundleid_probe bundleid_probe.swift && ./bundleid_probe
swiftc -o axcheck axcheck.swift && ./axcheck
swiftc -typecheck api_typecheck.swift
```

## 10. 未确认的点

1. 同一快捷键被两个 app 注册时，按键实际送到哪一个。[未验证]
2. 开机自启的 island 实例是否有完整的 PATH。[未验证]
3. Kimi 网页是否原生支持 `?q=`。[未验证]
4. 拼音输入法下 compose 模式按 `↩` 的行为。[未验证]
5. `dsh://` scheme 是否支持带查询参数。[未验证]
6. `claude://` 深链在本机的端到端行为（未安装 Claude.app）。[未验证]
7. compose 模式与搜索框模式互斥的具体交互设计，未做原型。[推断，未验证]
