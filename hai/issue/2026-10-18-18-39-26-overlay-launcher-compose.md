---
type: feat
name: overlay-launcher-compose
title: "悬浮窗启动器：输入一段话打开 DeepSeek"
status: in-progress
created_ts: 2026-10-18T18:39:26+08:00
updated_ts: 2026-10-18T18:39:59+08:00
---

> 总纲：[ISSUES.md](../ISSUES.md)

## 背景

方案 `hai/reference/extensions/README.md` §5 的 P3（启动器），对应用户需求 R2-例："悬浮窗快速输入 → 打开对应 chat 智能体（deepseek/kimi，可选可配）"。P0 的入站通道与通知行已落地（`island-ipc-p0`），P1/P2（`subscribe` 事件推送、接入 skill）本轮不做。

`2026-10-18` 用户原话选定的下一步："P3：启动器 + 悬浮窗输入 —— 跳过通道，先做用户看得见的功能：悬浮窗输一句话打开 DeepSeek chat。"

## 范围

- `IslandCore` 新增启动器模型：目标（id / 显示名 / 站点基址 / 查询参数名）+ URL 构造（`URLComponents` 编码，空问题只开站点）+ compose 状态机（进入/退出/重置）+ `ISLAND_LAUNCHER=off` 开关。全部纯逻辑，带测试。
- 悬浮窗键盘模式新增 compose 态：`⇥` 在"筛选任务"与"提问"之间切换；compose 态下输入框不再过滤任务，占位符与右下 pill 显示目标名，底部提示行换成 compose 提示；`↩` 打开 `https://chat.deepseek.com/?q=<问题>` 并收起悬浮窗；compose 态按 `esc` 退回筛选（不清空列表），再按 `esc` 才收起。
- 目标清单本轮**内置** DeepSeek 一条（`LauncherTarget` 已按多目标建模，Kimi 等待 `?q=` 实测后再加）。
- 本地化：中英各新增 compose 相关文案，`LocalizationTests` 的 parity 继续生效。
- 文档：`hai/CONTEXT.md`（env 表、Layout、Gotchas）、`hai/reference/extensions/README.md`（P3 落地说明与决策记录）。

不做（写清以免默认扩张）：

- 声明式 manifest（`plugin.json` 解析、启用/禁用、`actions`）：字段表里连启动器要用的 `targets` 都还没有（方案 §4.4 已标注"本稿新增"），留作 P3 的第二段，另开 issue。本 issue 只交付内置目标。
- 已安装智能体探测、面板 section、每目标全局键（R3）。
- `autosend=1`（方案 D9：默认不带）、剪贴板兜底、AX 注入。
- token（D12）、`subscribe` 事件推送（P1）。

## 期望结果

- 热键调出悬浮窗 → 按 `⇥` → 输入"帮我看下这个报错" → `↩`：浏览器打开 `chat.deepseek.com/?q=…`，问题在输入框里，**不自动发送**；悬浮窗收起。
- 不开 compose 时，原有筛选、↑↓、`↩` 打开任务、`⌘1–9`、`⌘,`、`esc` 行为不变。
- `ISLAND_LAUNCHER=off` 时不出现提问入口，`⇥` 不改变行为。
- `make verify` 全绿，`IslandCore` 覆盖率保持 100%。

## Decision

- 2026-10-18，用户选定下一步做 P3 启动器（跳过 A 线 P1/P2）。授权范围：悬浮窗输入 → 打开 chat 站点；不含 manifest 与探测。

## 备注

- 全程在独立 worktree（`../.worktree/<repo>-<slug>`）中完成，合回 master 前 `make verify` 全过，流程见 AGENTS.md / Workflow / Worktree 与 Ship
- 方案第 6 节列出的 `[未验证]` 项在本文不改结论：DeepSeek `?q=` 是否进输入框仍需真人开一次浏览器确认；Kimi 的支持情况未验证，故本轮不加 Kimi。

# History

## 2026-10-18T18:39:59+08:00: new -> in-progress

Scope-check: PLAN § Scope / 扩展机制 第 3 条（启动器：悬浮窗输入一段话后打开指定 chat 智能体）；用户 2026-10-18 选定先做 P3。在 worktree overlay-launcher-compose 开工。
