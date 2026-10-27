---
type: docs
name: zh-readme-launcher
title: "README.zh-CN 缺启动器一节、tab 数仍是六个"
status: solved
created_ts: 2026-10-19T01:26:06+08:00
updated_ts: 2026-10-27T23:55:17+08:00
---

> 总纲：[ISSUES.md](../ISSUES.md)

## 背景

`README.zh-CN.md` 从 P3a（启动器第一次落地）起就没有启动器一节，本轮 P3d 也没补：

- 第 26 行写「`Settings…` 分 `General` / `Appearance` / `Notifications` / `Agents` / `Updates` / `Feedback` 六个 tab」——P3c 起就是七个（缺 `Launcher`）。
- 第 128 行的设置页表格没有启动器一行。
- 英文 `README.md` 已有「Ask a chat agent from the panel」条目与 Launcher tab 说明（P3c 与 P3d 各更新过一次），中文版没有对应内容。

P3c 的 issue History 与 P3d 的 History 都记了这条缺口，但当时都没开 issue 追踪，所以单独记在这里。

## 期望结果

`README.zh-CN.md` 与英文 `README.md` 信息对等：tab 数是七个、设置页表格有一行启动器、功能列表有「从悬浮窗向 chat 站点提问」一条，并且与本轮 P3d 的行为一致（每行末尾启用勾选框、`Tab 键` 切换、内置 DeepSeek 与 Kimi、附加参数勾选后才写进网址）。

## 备注

- 纯文档改动，不涉及代码；`make verify` 的 build / coverage / cycles 门禁在此不适用（markdown lint 与链接检查仍要过）
- 只有真的动内容时才改，不做纯措辞润色

# History

## 2026-10-27T23:55:17+08:00: new -> solved

本轮文档整理一并补齐：`README.zh-CN.md` tab 数改为七个并含 `Launcher`，功能列表补「从悬浮窗向 chat 站点提问」与 `Settings…` → `Launcher` 两条，菜单表格的 `Settings…` 一行加上启动器模式环，与英文 `README.md` 信息对等。
