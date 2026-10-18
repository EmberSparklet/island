---
type: feat
name: launcher-mode-toggles
title: "启动器模式可停用、内置 Kimi、设置页文案与滚动"
status: in-progress
created_ts: 2026-10-19T00:52:28+08:00
updated_ts: 2026-10-19T00:53:02+08:00
---

> 总纲：[ISSUES.md](../ISSUES.md)

## 背景

P3c（`125207e`）让模式环可以在设置页配置，但人验收后提出五件事（原话见下），其中两件是缺陷级的：

1. `https://kimi.moonshot.cn/_prefill_chat?prefill_prompt=测试&send_immediately=true` 人实测可用 —— 上一轮因 `www.kimi.com` 新域名丢能力而没内置的判断，在 `.cn` 域名上不成立，要按可用参数内置 Kimi。
2. 「我的 deepseek 网页提问怎么没默认配置了？帮我加回来，并配置好默认信息」——根因是本机 `UserDefaults` 里 `IslandLauncherModes` 残留了上一轮做优先级探测时 `defaults write` 写入的环（`kimi|Kimi|https://www.kimi.com/|q`，无 options），保存值优先于内置，于是 DeepSeek 被顶掉。属探测残留污染，不是产品缺陷，但要修用户现场、并把「保存值会永久压住内置环」记进文档。
3. 启动器每一行末尾要有启用勾选框，没勾选的模式不能参与切换。
4. 设置页那段长文案要拆：默认只给一句「怎么配」，长的说明和 DeepSeek 这类站点细节放进 ⓘ 按钮；模式多时列表要滚动，「添加模式」按钮固定底部。
5. `⇥` 图标要带键名，改成 `Tab 键`。

## 期望结果

- 内置环 = 「搜索任务」+ DeepSeek + Kimi；Kimi 的站点基址 `https://kimi.moonshot.cn/_prefill_chat`、问题参数 `prefill_prompt`、附加参数 `send_immediately=true`（标签「自动发送」，默认不勾）。DeepSeek 的基址/参数/`autosend=1` 保持不变。
- 每个模式行有启用勾选框；未勾选的不参与 `Tab` 切换，也不能成为召唤后的入口模式；「搜索任务」始终启用（勾选框置灰 + 提示），全部未勾选时召唤仍进入「搜索任务」。
- 设置页：一句短说明 + 页面级 ⓘ（配置方法详情）+ 每个内置模式一个行内 ⓘ（站点限制详情）；列表区域滚动，「添加模式…」按钮固定在列表下方不随内容滚动。
- 悬浮窗与设置页的按键提示统一用「Tab 键」表述，不再只给符号。
- `README.md` / `hai/CONTEXT.md` / `hai/reference/extensions/README.md` 与新行为一致；`--print-config` 能看出哪个模式被停用。

## 备注

- 全程在独立 worktree（`../.worktree/<repo>-<slug>`）中完成，合回 master 前 `make verify` 全过，流程见 AGENTS.md / Workflow / Worktree 与 Ship
- 不发版（人要求先不发版），不跑 `./scripts/publish.sh`

## Decision

### 授权（2026-10-19，人）

人在会话中一次性提出上述五条，属于对 PLAN § Scope「扩展机制」#3「启动器：悬浮窗里输入一段话后打开指定 chat 智能体（可选可配）」范围内的明确指令。

- `Scope-check: hai/PLAN.md § Scope / 扩展机制 #3`
- 人的原话要点：「可以使用这些参数默认配置好启动器」「我的 deepseek 网页提问怎么没默认配置了？帮我加回来，并配置好默认信息」「启动器在最后都加一个勾选框，只有勾选了才能用」「这一段文案不行 …… 可以单独用一个信息图标按钮」「如果非常多启动器，则需要滚动启动器列表，"添加模式"按钮放在最底部不能滚动」「⇥ 图标要加按键名"Tab按键"」
- 人给的 Kimi 实测结论：`https://kimi.moonshot.cn/_prefill_chat?prefill_prompt=测试&send_immediately=true` 可以使用。

### 设计取舍

- **启用开关挂在 `LauncherTarget.isEnabled`，不引入条目包装类型。** 「搜索任务」没有可持久化的载荷，而它又是 island 自己的功能、不该被关掉，于是 `LauncherMode.isEnabled` 对筛选恒为 `true`。这样模式环的类型不变，`LauncherStore`、`HotkeySettingsWindow`、设置页的既有签名都不用动，改动面最小。
- **附加参数（`autosend` / `send_immediately`）默认不勾。** 沿用 D14：误按一次 `↩` 不会自己把消息发出去。人若要默认勾上，改一行即可。
- **`.cn` 域名与 `www.kimi.com` 是两条路。** 上一轮实测的是 `www.kimi.com` 的新 bundle（无 `send_immediately`）；人给的是 `kimi.moonshot.cn` 的旧深链，实测可用，因此内置按 `.cn` 写。

# History

## 2026-10-19T00:53:02+08:00: new -> in-progress

启动：Scope-check: hai/PLAN.md § Scope / 扩展机制 #3。五条要求（内置 Kimi、恢复 DeepSeek 默认、模式启用勾选框、设置页文案/滚动/ⓘ、Tab 键名）见正文 Decision。人在 2026-10-19 会话中明确要求。
