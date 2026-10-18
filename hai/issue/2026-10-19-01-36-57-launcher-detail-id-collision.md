---
type: bug
name: launcher-detail-id-collision
title: "启动器 ⓘ 详情只按 id 匹配内置站点，自建同 id 站点会看到错误文案"
status: new
created_ts: 2026-10-19T01:36:57+08:00
updated_ts: 2026-10-19T01:36:57+08:00
---

> 总纲：[ISSUES.md](../ISSUES.md)

## 背景

P3d 独立复核（commit `913346b`）的提示条之一：

`Launcher.detail(for:)`（`Sources/IslandCore/Launcher.swift:289`）只按 `target.id` 命中内置站点。而 `uniqueID(from:taken:)` 是从名字生成 slug，用户自己加一个叫 “Kimi” 的模式也会得到 id `kimi`（前提：内置 Kimi 那一行已先被删掉；否则会拿到 `kimi-2`，不触发）。这时这一行会显示「自动发送在 kimi.moonshot.cn 的预填链接上有效，需要已登录。」——而用户的站点可能是 `www.kimi.com`，正是 island 实测**不可用**的那个域名。

最小复现：设置页 → 启动器 → 删掉内置 `Kimi` 行 → `添加模式…`，名称 `Kimi`、基址 `https://www.kimi.com/`、问题参数 `q` → 该行出现 ⓘ，点开是 `.launcherDetailKimi`。

纯文案问题，无功能影响；`Launcher.detail(for:)` 的返回值只进 popover。

## 期望结果

ⓘ 只在真的指向内置站点时出现：匹配条件从「id 相同」收紧成「id 与 host 都相同」（或直接与 `Launcher.kimi` / `Launcher.deepSeek` 比较 host）。`IslandCore` 侧改一处 + 单测补一个「同 id 不同 host → `nil`」的用例，`make verify` 全绿即可。

## 同时发现的相邻问题（不同性质，记录备查，不要求在本 issue 内处理）

- `hai/CONTEXT.md:64` 的 `ISLAND_LAUNCHER` 行仍写「（`⇥` 输入一段话打开 chat 站点）」，而界面与同文件 §Gotchas 已统一成 `Tab 键`。
- `Launcher.sanitized` 对同 id 去重时保留第一条（`Launcher.swift:302`，P3c 起的行为、有意为之）。手改 JSON 造出「第一行未勾选、第二行勾选」的同 id 两行时，勾选的那行会被丢掉。UI 生成不出同 id，只有手改 `UserDefaults` 可达。
- `LauncherTarget.init(from:)` 把 `options` 当必填（`Launcher.swift:49`）。手写一个缺 `options` 的目标会让**整个环**判为 unreadable 并回落内置，而不是把该目标读成「没有附加参数」。P3c 起编码必带该字段，正常升级不触发。

## 备注

- 本 issue 不在 P3d 的提审范围内，P3d 按复核结论原样 ship（`913346b`），此条留给后续判断
- 全程在独立 worktree（`../.worktree/<repo>-<slug>`）中完成，合回 master 前 `make verify` 全过，流程见 AGENTS.md / Workflow / Worktree 与 Ship

# History
