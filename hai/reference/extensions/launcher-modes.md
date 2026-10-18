# 启动器「模式」可配置化 —— 规划稿（P3c）

- 状态：**已确认并落地**（2026-10-18，issue `launcher-modes`）。四个决策点的答案见 §6，落地说明见同目录 `README.md` §5 的 P3c 段与决策 D14。
- 上游：本文档同目录 `README.md` §4.4 / §4.6 / §4.8 / §5 / §7；已落地的前两段 P3a（issue `overlay-launcher-compose`）、P3b（issue `launcher-targets`，commit `53705bb`）。
- 需求来源：用户 2026-10-18 第二轮原话（见 §1）。
- 标记约定同 README：`[可得]` / `[未验证]` / `[不可得]` + 置信度；无出处的判断标「推断:」。

---

## 1. 需求拆解（用户原话 → 可施工项）

| 编号 | 用户原话 | 拆成什么 |
|---|---|---|
| R4-1 | 「设置项可以配置输入框可以切换的模式，目前支持搜索任务和 deepseek 网页提问」 | 把"筛选任务 / 提问"从**硬编码的两态**改成**用户可配的模式清单** |
| R4-2 | 「当前默认模式是搜索任务，tab 按键后切换到 deepseek，需要改成拖拽式顺序切换」 | 顺序由用户在设置页拖拽决定；第一行 = 默认模式 |
| R4-3 | 「deepseek 这种搜索类型的还要可以勾选 autosend=1」 | 每个模式可带**有开关的附加参数**，`autosend` 只是第一个例子（Kimi 叫 `send_immediately`） |
| R4-4 | 「每一行一个模式，第一行是默认模式……'kimi 聊天 [自动发送]'，'codex 聊天 [自动发送]'」 | 设置页一行一个模式，行内直接显示选项标签 |
| R4-5 | 「支持用户添加和自定义：基础地址 `https://www.xxx.com/`，搜索参数 `q=`，支持其他参数定义……并给个名字，也就是标签」 | 增 / 删 / 改自定义模式；附加参数 = `键=值` + 用户起的标签 + 勾选框 |
| R4-6 | 「就算是已经配置的 deepseek 也可以增加自定义的选项」 | 内置模式与自定义模式**同一种数据结构**，内置的也可编辑 |
| R4-7 | 「可以调研下 deepseek、kimi、codex 自动发送是否支持」 | 见 §2 |

**术语固定**（下面统一用）：**模式（mode）** = 悬浮窗输入框的一种用途；分两类：`搜索任务`（内置，筛任务）与 `网页提问`（带站点基址 + 问题参数名的目标）。

---

## 2. 调研：各站点 URL 参数预填 / 自动发送

`autosend` 不是通用约定，是**每个站点自己的私有参数**（Kimi 就叫 `send_immediately`）。本节先给第一手证据，再列外部调研与它的冲突及裁决。

### 2.1 第一手证据：DeepSeek 的 URL 唤起是**有意实现的功能**（本稿核心结论）

`.build/probe/panel/deepseek_main.js`（1.5 MB，**2026-10-18 15:24 从站点现拉**，即当前生产 bundle）里，启动路径上有一段完整的 URL 参数入口：

```js
// 只在站点根路径生效
if(!(0,eX.B6)(e$.a$.ROOT,window.location.pathname))return;
let s=new URL(window.location.href),
a=(q?.trim()||prompt?.trim())
  ?{prompt:r, modelType:(mode∈["default","expert","vision"])||null,
    searchEnabled:e6(search), thinkingEnabled:e6(thinking),
    autoSend:"1"===e.get("autosend")&&r.length<=800,
    source:"landing"===e.get("source")?"landing":void 0}
  :null;
if(a){
  P.y.tracker.info({name:"open_in_deepseek",message:"通过 query 参数唤起网页",...});
  tr({status:"pending",intent:a});              // 写 sessionStorage["chat_url_prefill"]
  e5.forEach(p=>s.searchParams.delete(p));      // 消费后清掉这 7 个参数
  window.history.replaceState(window.history.state,"",s.toString());
}
P.y.getPersistedCurrentUser().token && to();     // ← 只有已登录才消费 intent
```

按这段代码可以直接读出四条事实，**都不是推测**：

| 事实 | 代码出处 |
|---|---|
| 站点**有意支持** query 参数唤起，且做了埋点：事件名 `open_in_deepseek`，消息原文「**通过 query 参数唤起网页**」 | 上面的 `tracker.info({...})` |
| 参数白名单 `q` / `prompt` / `mode` / `search` / `thinking` / `autosend` / `source`，消费后从地址栏删除 | `let e5=[...]` + `e5.forEach(...delete)` |
| `autosend=1` **且问题 ≤ 800 字**才自动发送 | `autoSend:"1"===e.get("autosend")&&r.length<=800` |
| **只在站点根路径**生效；且 intent 只在**已登录**（`getPersistedCurrentUser().token`）时才被消费 | 首行 guard + 末行 `&& to()` |

自动发送的落地路径也完整：`to()` 读到 `autoSend` 时**不立即应用**，而是挂成一个待认领的 intent（`te={intent,claimed:false}`），由聊天输入组件通过 `ti()` 取、`td(intent)` 认领并发送 —— 即"发出去"这一步由输入框组件完成，不是 URL 直接触发。

**结论：外部调研说「DeepSeek 原生不支持带参输入」是错的（至少对当前生产 bundle 是错的）。** 那些说法来自 2024 年的脚本文章与"把 AI 站变成搜索引擎"类 userscript —— 后者要的是**浏览器搜索框集成**，不是"带参唤起"，需求不同；且早于这个功能上线。这不改变一件事：**运行时行为仍未被人工确认**（见 §7）。

### 2.2 各站点对照

| 目标 | 预填参数 | 自动发送 | 出处 | 置信度 |
|---|---|---|---|---|
| **DeepSeek** `chat.deepseek.com` | `q`（`prompt` 兜底），**仅根路径** | **有**：`autosend=1`，问题 ≤ 800 字；且要已登录 | §2.1 生产 bundle 原文 | **高**（第一手源码）；运行时 `[未验证]` |
| 同上，其他可用参数 | — | `mode`（`default`/`expert`/`vision`）、`search`、`thinking`、`source` | 同上；布尔参数语法 `e6=e=>"1"===e||"0"!==e&&null`（**给了非 `0` 的值就算开**） | 高 |
| **Kimi** 旧域名 `kimi.moonshot.cn`（现 302 → `www.kimi.com`） | 旧域名有：`/_prefill_chat?prefill_prompt=<问题>` | 旧域名有：`send_immediately=true`；**新域名已不成立**（见下） | 旧域名：[知乎「做 Kimi 的朋友」](https://zhuanlan.zhihu.com/p/687953042)（2024-03）+ [社区实测](http://www.centbrowser.net/zh-cn/forum.php?mod=viewthread&action=printable&tid=15767)（2025-01-02）。新域名：**本稿实测** | 旧域名中高；**新域名 `[不可得]` 高** |
| **ChatGPT** `chatgpt.com` | `q`（前端改写成 `prompt`）、`temporary-chat`、`hints`、`model` | **已被修掉**：OpenAI 加了 `sec-fetch-site` 自动提交防护 | [Tenable TRA-2025-22](https://www.tenable.com/security/research/tra-2025-22)（原文确认 `?q=` 曾被自动提交、按 prompt injection 处理）；[参数整理](https://blog.poychang.net/chatgpt-url-query-parameters/)说明 OpenAI 从未发布参数规格 | 预填高；自动发送「曾经可以、现在不行」中 |
| **Claude** 桌面 | `claude://claude.ai/new?q=`（另有 `claude://code/new?q=&folder=`） | 否，只填输入框等用户发 | [Anthropic 官方帮助](https://support.claude.com/en/articles/14729294-open-claude-desktop-with-a-link) | 高（官方） |
| **Codex** 网页 `chatgpt.com/codex` | 未找到 | 未找到 | 只确认它是云端 coding agent；本机区域不可达 | 低（无证据） |

**Kimi 新域名的裁决（本稿实测）**：`curl -I 'https://kimi.moonshot.cn/_prefill_chat?prefill_prompt=测试&send_immediately=true'` 得 302 → `https://www.kimi.com/_prefill_chat?…`（**path 与参数都保留**，看着像还认识这个路由）；但该地址返回的文档与首页同一份，JS 是 `kimi-web-seo/index-DeZ5alHT.js`（2.0 MB），里面：

- `{path:'/_prefill_chat', redirect:'home'}` —— 该路由**只是跳回首页**，不读任何参数；
- `send_immediately` **0 命中**；`force_search` 0 命中；
- `prefill_prompt` 只有 1 处，是站内 onboarding 自己 `router.push({name:HOME, query:{prefill_prompt:…}})` 写进去的，**没有任何地方读它**。

所以旧域名那套"预填 + 直接作答"的能力，在迁移后的新域名上**不成立**（至少匿名路径是这样；已登录是否会换成另一份 bundle 未验证）。按用户「只内置已知能支持的部分」，Kimi 不进内置。

**本机装机实测（2026-10-18 22:1x）**：`ls /Applications | grep -iE 'codex|chatgpt|claude|kimi|deepseek|island'` 只命中 `DeepSeek Harness.app`（DSH 自己，URL scheme 为 `dsh`）与 `Island.app`；`which` 得 `codex`（`/opt/homebrew/bin/codex`）、`pi`，且 `~/.codex` 存在。所以本机**没有** Codex / ChatGPT / Claude / Kimi 的图形聊天客户端，"codex 聊天"这一项不是"参数没查清"，是**没有可带参打开的 URL 目标**。

### 2.3 对设计的三条约束

1. **`autosend` 必须逐模式、显式、默认关**：DeepSeek 有（还叠加"已登录 + ≤800 字"两个前提）、Kimi 有（换个名字）、Claude 没有、ChatGPT 被官方关掉。做成全局开关或默认打开，等于在用户没确认时把话发出去，还可能踩在站点刚修过的安全面上（与 README §7-D9、§4.6 一致）。
2. **每个站点是"路径 + 自己的参数名"**，不是一个统一的 `q`：Kimi 是 `/_prefill_chat` + `prefill_prompt` + `send_immediately`；DeepSeek 是 `/` + `q` + `autosend`。所以设置页字段应为 **站点基址（可含路径）/ 问题参数名（不限 `q`）/ 附加参数列表**，模型见 §3.1 —— Kimi 那条能被同一模型原样表达，不需要加特例。
3. **站点私有约束不进代码，只进文案**：DeepSeek 的「≤800 字」「必须根路径」「需已登录」，Kimi 的「新域名未验证」。island 不猜测语义，只在设置页脚注与 §7 里写明。


---

## 3. 设计

### 3.1 数据模型（`IslandCore`，纯 Foundation，TDD 100%）

```swift
/// 一个可选附加查询参数：键、值、用户在设置页看到的名字、是否生效。
public struct LauncherOption: Equatable, Sendable {
    public var key: String      // "autosend"
    public var value: String    // "1"
    public var label: String    // "自动发送"（纯 UI 文案，不参与 URL 构造）
    public var isEnabled: Bool  // 勾选框
}

public struct LauncherTarget: Equatable, Sendable {   // 在 P3b 的四个字段上 +1
    public var id: String
    public var name: String
    public var baseURL: URL
    public var queryItem: String          // "q"
    public var options: [LauncherOption]  // 新增，默认 []
}

/// 模式环的一个元素。搜索任务是内置模式，与网页提问同列，用户可拖拽排序。
public enum LauncherMode: Equatable, Sendable {
    case searchTasks
    case target(LauncherTarget)
}
```

要点：

- `id` 由 `name` 生成 slug + 去重后缀，用户不可见；`id` 唯一是既有约束（`parseTargets` 已按 id 去重）。
- `searchTasks` **恒在环里恰一次**：可拖动、不可删除。理由：`esc` 要有一个恒定的"取消去处"，删掉它会让 `esc` 无处可回；且筛选任务是 island 的主功能，不该被配置动作弄丢。
- `Launcher.url(for:query:)` 扩展：非空问题 → 先按现规则写 `queryItem`，再按 `options` 顺序追加**已启用**的项；空问题 → 仍直接返回 `baseURL`（附加参数不追加，避免打开一个带死参数的首页）。
- 保持"永远不隐式加 autosend"：`autosend` 只在用户勾选后才出现。
- **内置清单建议**：`[搜索任务, DeepSeek]` 两条，`Launcher.deepSeek` 的四个字段不变，只预置一个**默认不勾**的选项 `autosend=1`（标签「自动发送」）。Kimi 不进内置 —— 新域名的 `_prefill_chat` 未验证（§7），而"用户自定义"已经能把它一行填出来：

  | 字段 | 值 |
  |---|---|
  | 名称 | `Kimi` |
  | 站点基址 | `https://kimi.moonshot.cn/_prefill_chat` |
  | 问题参数名 | `prefill_prompt` |
  | 附加参数 | 键 `send_immediately` / 值 `true` / 标签「自动发送」 |

### 3.2 模式环与按键语义（把 P3a/P3b 的两态泛化）

现在：keyboard 模式下 `⇥` 在「筛选」与「提问」之间切，提问态再 `⇥` 走目标列表；单目标时 `⇥` 退回筛选。

改成：**一个有序环 `[LauncherMode]` + 当前下标 `modeIndex`，`⇥` 恒为"下一个模式并回绕"**。

| 按键 | 语义 | 与现状的关系 |
|---|---|---|
| `⇥` | `modeIndex = (modeIndex + 1) % count` | 环 = `[searchTasks, deepseek]` 时与 P3a/P3b 完全等价 |
| `↩` | 当前模式是 `searchTasks` → 打开选中任务（不变）；是 `target` → 打开 URL（不变） | 不变 |
| `esc` | 当前不是 `searchTasks` → 回到 `searchTasks` 并清空草稿；已经是 → 收起悬浮窗 | 语义不变（现状的"回到筛选"就是回到 `searchTasks`） |
| 打字 | 进 `searchTasks` 即筛任务，进 `target` 即提问 | 不变 |

收益：`ComposeTabAction`（`.begin/.moveToTarget/.end`）这套"三态 + 特例"整个消失，换成 `nextModeIndex(from:count:)` 一个纯函数；P3b 那三个复核修（`esc` 不再走目标游走、`⇥` 保住草稿）在新模型里是**结构性成立**的，不是两条特判。

### 3.3 持久化与优先级

新增 `UserDefaultsLauncherStore`（照 `UserDefaultsHotkeyStore` / `UserDefaultsPopupStore` 的形状，把 `[LauncherMode]` 编成 JSON `Data` 存进 `UserDefaults` 的 `IslandLauncherModes`；**没有版本字段**——落地时按最省的做法没加，将来真要改形状就换 key，另配一次迁移。解析失败回落内置，并在 `--print-config` 打 warning，不与"从未保存"混为一谈）。

优先级（与 `hai/CONTEXT.md:44` 的既有约定一致：**应用内设置 > 环境变量 > 内置默认**）：

1. `ISLAND_LAUNCHER=off` → 关闭（硬开关，保持 P3b 契约，`--print-config` 与既有测试依赖它）
2. `UserDefaults` 里存了模式清单 → 用它（设置页写的就是这里）
3. `ISLAND_LAUNCHER_TARGETS` → 解析（P3b 的开发者覆盖通道，格式不变）
4. 内置：`[searchTasks, DeepSeek 网页提问]`

设置页脚注显示**当前生效来源**（照 `ResolvedConfiguration.sourceNote` 的做法），避免"我改了环境变量怎么没用"的困惑。

### 3.4 设置页 UI

落点：`HotkeySettingsWindow` 的 `NSTabView` 新增一个 tab（与 Agents / Updates / Feedback 并列），新文件 `Sources/Island/LauncherSettingsView.swift`（**必须手工登记进 `coverage.config`**，README §2.5）。

- `NSTableView` 单列自定义 cell，一行一个模式；行内：名称 + 类型徽标（搜索任务 / 网页提问）+ 选项勾选框（如 `☑ 自动发送`）+ 编辑 / 删除。**整行可拖**（`pasteboardWriterForRow`），没有单独的拖拽把手。
- 拖拽排序用 `NSTableViewDataSource` 的 `pasteboardWriterForRow` + `validateDrop` + `acceptDrop`（纯 AppKit，无新依赖）。
- 首行加一个 `默认` 标记，与"第一行是默认模式"对应。
- `+` 新增 / 双击编辑 → sheet：名称、站点基址（可含路径）、**问题参数名**（`q` / `prefill_prompt` / …）、附加参数列表（键 / 值 / 标签 / 启用，可增删行）。
- 校验结果（见 §3.6）就地红字 + 禁用保存，**不**静默丢弃用户输入。
- 所有判定逻辑（模型 ↔ JSON 往返、校验、slug 生成、增删改排序后的不可变更新）都在 `IslandCore`，视图只做镜像与回调 —— 与 `AgentSettingsView` 同构。

### 3.5 悬浮窗渲染

- `setLauncher(_ modes:)` 替 `setLauncher(_ targets:)`；`modeIndex` 替 `targetIndex`。
- 标题行胶囊：显示当前模式名（`搜索任务` / `DeepSeek`）。**只在提问态显示**，与 P3a/P3b 一致——落地时决定不改这条：在筛选态，放大镜图标与任务占位符已经说明了当前模式，再加一个胶囊是噪音。
- 占位文案：`搜索任务` → 现有 `searchPlaceholder`；`target` → `问 %@…`（复用 `.launcherAsk`）。
- 脚注：
  - 当前是 `target` 且环里还有其他模式 → `↩ 发送到 %@   ⇥ 切换模式   esc 取消`
  - 当前是 `searchTasks` 且环里有 `target` → 现有 `overlayHintsWithLauncher`（已含 `⇥ 提问`）
  - 当前是 `target` 且环里**只有它一个** → 无 `⇥` 项（现在的行为是不给"切换目标"）
- 文案改动落在 `Localization.swift`（`launcherHintsNextTarget` 由"切换目标"改"切换模式"），中英同步，`LocalizationTests` 管一致性。若 `esc` 语义按 §3.2 改，`.launcherHints`（现为 `⇥ 返回筛选`）要跟着改。

### 3.6 校验规则（全部纯函数，可 100% 覆盖）

| 字段 | 规则 | 违反时 |
|---|---|---|
| 名称 | 非空（trim 后；不设长度上限） | 标红，禁保存 |
| 基础地址 | `http`/`https` + 非空 host | 标红，禁保存 |
| 问题参数名 | 非空、不含空白与 `&=?#`（沿用 P3b 的 `isUsableQueryItem`） | 标红，禁保存 |
| 附加参数键 | 非空、不含 `&=?#`、不与问题参数同名 | 标红，禁保存 |
| id | slug 化（小写、非字母数字→`-`）+ 去重后缀 | 自动生成，用户不可见 |

环境变量通道（`ISLAND_LAUNCHER_TARGETS`）保持 P3b 的"非法条目跳过并计数 + warning"不变，与设置页的"拒绝保存"是两条不同的路径：前者是开发者通道，静默不得；后者是用户输入，必须当场拦住。

### 3.7 不做（防扩张）

- 不做剪贴板兜底动作（README §4.6 提过；本轮只做 URL，不新增动作类型）。
- 不做 AX / CGEvent 注入按键（PLAN § Scope 边界、README §7-D10 已否）。
- 不做站点类型的特殊分支（不 hardcode "deepseek 才能 autosend"）。
- 不做插件 manifest 的 `targets` 字段（README §4.4 遗留项，属另一条 issue）。
- 不做每模式全局快捷键（那是 R3 / P4）。
- 不引入配置文件：用户偏好走 `UserDefaults`（README §4.8 的划线：manifest 不描述 island，island 自己的开关走 `UserDefaults` / `ISLAND_*`）。

---

## 4. 影响面清单

| 文件 | 改动 |
|---|---|
| `Sources/IslandCore/Launcher.swift` | `LauncherOption`；`LauncherTarget.options`；`LauncherMode`；`url(for:query:)` 追加启用项；`nextModeIndex`；`LauncherSettings.resolve(environment:stored:)` |
| `Sources/IslandCore/LauncherStore.swift`（新） | `UserDefaultsLauncherStore` + JSON 编解码 + schema 版本 |
| `Sources/IslandCore/Localization.swift` | 设置页新文案 + 脚注改动（中英） |
| `Sources/Island/OverlayContent.swift` | 模式环渲染、胶囊、占位、脚注、`⇥`/`esc` 接线 |
| `Sources/Island/LauncherSettingsView.swift`（新） | 设置页 tab；**加进 `coverage.config`** |
| `Sources/Island/HotkeySettingsWindow.swift` | 挂新 tab |
| `Sources/Island/AppDelegate.swift` | `setLauncher(modes)`、设置变更回调、`--print-config` 摘要 |
| `Sources/Island/ResolvedConfiguration.swift` | `launcher` 行列出模式名（含 `搜索任务`）；来源标注；env 解析前的 store |
| Tests | `LauncherTests` 扩展 + 新 `LauncherStoreTests`；`ResolvedConfiguration` 无测试（已排除） |

---

## 5. 分期与验收判据

一段落地（见 §6-Q3）：

| 步 | 内容 | 判据 |
|---|---|---|
| 1 | 模型 + `url` 附加参数 + `nextModeIndex` + store | 单测：选项开关影响 URL；环回绕；JSON 往返；坏 JSON 回落 |
| 2 | `LauncherSettings` 优先级 + 摘要/来源 | `--print-config` 在四种组合下分别输出 store / env / 内置 / off |
| 3 | 设置页列表（排序 + 选项勾选） | 拖拽后重启，`⇥` 顺序与列表一致 |
| 4 | 增 / 删 / 改 + 校验 | 非法输入红字且不落盘；合法输入重启后仍在 |
| 5 | 悬浮窗模式环渲染 + 文案 | 环 = `[搜索任务, DeepSeek]` 时与 `53705bb` 行为逐条对齐（回归） |
| 全量 | `make verify` | 全绿：覆盖率不低于 100 基线，issue-check 一致 |

---

## 6. 待用户决策（动工前必须回答）

- **Q0 唯一要你在浏览器里做的 10 秒实测**（决定整个启动器是否成立）：打开 `https://chat.deepseek.com/?q=测试&autosend=1`，看「测试」是否出现在输入框、以及是否被自动发出。代码层面已确认支持（§2.1），但运行时行为本机无法自动验证（TCC `-25211` 挡 GUI 自动化）。
- **Q1 环的语义**：第一行是"默认模式" —— 热键召唤时**直接进入**第一行的模式，还是始终先进 `搜索任务`、第一行只决定 `⇥` 的下一站？（`搜索任务` 建议恒在环里、可拖不可删，见 §3.1）
- **Q2 "codex 聊天"指什么**：本机没有 Codex 图形客户端（§2.2），只有 `codex` CLI。默认本轮**不内置** codex/kimi，改为"你自定义填地址与参数"。若你指的是 `chatgpt.com/codex` 网页，可内置但要标 `[未验证]`。
- **Q3 范围**：一步到位（排序 + 选项 + 增删改）还是拆成两个 issue（先"排序 + 内置模式选项"，再"自定义模式"）？

### 答案（2026-10-18，用户在本机会话中给出）

| 问 | 用户原话 | 落地 |
|---|---|---|
| Q0 | 「`https://chat.deepseek.com/?q=测试&autosend=1` 可以自动触发问答」 | DeepSeek 的预填与自动发送**端到端已实测**（§7 对应行随之更新） |
| Q1 | 「是」 | 第一行 = 热键召唤后直接进入的模式；`搜索任务` 恒在环里、可拖不可删 |
| Q2 | 「如果已知能支持就走内置支持已知的部分」 | 内置 `[搜索任务, DeepSeek]`，DeepSeek 预置**默认不勾**的 `autosend=1`；Kimi/Codex **不内置**（Kimi 本轮实测新域名是死跳转，见 §2.2），都走自定义 |
| Q3 | 「一次落地」 | 一个 issue（`launcher-modes`）做完模型、存储、设置页、悬浮窗与文档 |

---

## 7. 未验证

第一手源码证据（§2.1）与运行时行为是两件事：前者已确认，后者全在下面。

| 项 | 要做什么实验 |
|---|---|
| **DeepSeek 预填 + 自动发送** | **已实测（2026-10-18，用户在本机已登录浏览器）**：`https://chat.deepseek.com/?q=测试&autosend=1` 可以自动触发问答。仍未被机器复现的原因是 TCC `-25211` 挡 GUI 自动化 |
| DeepSeek 800 字上限 | 999 字的问题 + `autosend=1`，看是否只填不发（代码路径已确认，未单独实测） |
| DeepSeek 非根路径 | 代码里的 JS 解释了老的「按 table 回车没反应」现象：**只在根路径生效**，所以基址必须填 `https://chat.deepseek.com/`，不能带子路径 |
| Kimi 新域名是否仍实现 `_prefill_chat` | 匿名 HTTP 路径已确认不支持：旧域名只 302 到 `www.kimi.com/_prefill_chat`，而当前 `kimi-web-seo` bundle 里该路由是 `{path:'/_prefill_chat', redirect:'home'}`（参数被丢弃），`send_immediately` 0 命中。仍缺**已登录浏览器**那一次实测 |
| ChatGPT / Codex 网页 | 本机区域与 DNS 阻挡（README §2.3 已记）；且 ChatGPT 的自动发送已被官方 `sec-fetch-site` 防护关掉 |
| 真人按键下的模式环 | TCC `-25211` 挡自动化，只能人工按 |
