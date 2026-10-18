---
type: feat
name: notification-list-scroll-clear
title: "外部通知行：全部清除 + 列表滚动与翻页提示"
status: solved
created_ts: 2026-10-18T18:11:51+08:00
updated_ts: 2026-10-18T18:19:14+08:00
---

> 总纲：[ISSUES.md](../ISSUES.md)

## 背景

P0 的外部通知行（issue `island-ipc-p0`，D11）只能逐条点击标已读，没有清除入口；未读胶囊会一直挂着。另外通知只显示 `ISLAND_TASK_LIMIT`（缺省 10）条，多余的行既看不到也没有提示。

用户原话（2026-10-18）：

1. 悬浮窗需要增加一个全部清除的按钮，放在通知列表的右上角；当出现至少 1 个通知时可以清除所有通知。
2. 现在只显示 10 条通知，当多于 10 条时，在悬浮窗内底部中间、列表的上层显示一个半透图标，表达还有内容可以滑动查看更多；列表支持滚动。

## 范围

- `ExternalInbox.clear()`：清掉全部外部通知行（含已读）；**保留** `client_event_id` 去重窗口，重发同一 id 不会复活。
- 通知区标题行（`N notifications` + 右侧 `Clear all`）；有通知时才出现。
- 悬浮窗列表改为滚动：任务行与通知行同一个滚动区，可视高度按屏幕高度封顶，超过时底部中间显示半透 chevron 提示。
- 通知不再截断到 10 条：`ExternalInbox` 去掉 `limit` / `visibleEntries`（截断改为排版问题，行数由滚动区可视高度决定）。
- 键盘模式下选中行 `scrollToVisible`，避免选中行滚出视野。
- 文档：`hai/CONTEXT.md` 的 D11 段、`hai/reference/extensions/README.md` 决策记录（token 暂缓 D12）。

不做：散列滚动条（用提示图标代替）、任务的清除（任务只标已读，PLAN § Design 不变）、键盘快捷键清除。

## 期望结果

- 有通知时，通知区标题行右上角出现 `Clear all`，点击后所有通知行消失、未读数归零；同一 `client_event_id` 再发不复活。
- 通知多于可视行数时，底部中间出现半透提示，向上滚动到底后提示消失；鼠标/触控板滚动可用。
- 行数超过屏幕可视高度时，面板高度封顶，不再撑出屏幕。
- `make verify` 全绿，`IslandCore` 覆盖率保持 100%。

## Decision

- 2026-10-18，用户确认做这两项，并追加"多余 10 条时显示半透提示、列表支持滚动"。
- 2026-10-18，用户确认 token 暂缓（D12），本 issue 不涉及。

## 备注

- 全程在独立 worktree（`../.worktree/<repo>-<slug>`）中完成，合回 master 前 `make verify` 全过，流程见 AGENTS.md / Workflow / Worktree 与 Ship

# History

## 2026-10-18T18:12:03+08:00: new -> in-progress

Scope-check: PLAN § Scope / 扩展机制 R1（外部通知）；在 worktree notification-list 开工。

## 2026-10-18T18:19:14+08:00: in-progress -> solved

通知区的清除与滚动已实现。

- `ExternalInbox.clear()` 清空全部行、保留去重窗口；去掉 `limit` / `visibleEntries`（截断改为排版问题）。
- 悬浮窗：通知区标题行（条数 + `Clear all`）；任务行与通知行共用一个 `NSScrollView`（flipped document view），面板高度按屏幕封顶，内容超出时底部中间显示半透 chevron（判定逻辑 `OverlayScrollHint`，有测试）；键盘选中行 `scrollToVisible`；原来的头部队列胶囊换成这一节标题。
- 文案：新增 `noticeClear`（中英各一条）。
- 证据：`make verify` 全绿（425 测试、覆盖率 100）；截图确认 35 条通知时"35 条外部通知 + 全部清除 + 底部半透提示"，2 条通知时无提示。
- 未自动验证：点击 `Clear all`（终端没有辅助功能授权，`osascript` 报 -25211）；`clear()` 与去重窗口有单测，按钮到 `clearNotifications()` 的连线是 3 行 wiring。
