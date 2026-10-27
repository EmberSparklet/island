---
type: bug
name: overlay-shadow-square-corners
title: "悬浮窗阴影按窗口矩形绘制，底部圆角处露出直角黑线"
status: solved
created_ts: 2026-10-19T20:49:53+08:00
updated_ts: 2026-10-27T23:56:30+08:00
---

> 总纲：[ISSUES.md](../ISSUES.md)

## 背景

用户报告：Liquid Glass 主题下用 `⌃⌘,` 召唤悬浮窗，**底部左右两个圆角位置露出直角黑线**（用户原话：「底部左右就是两个黑色线条直角」）。

复现与定位（本机 macOS 27.0.1、2x 屏，dev build `build/Island.app`，主题 `liquidGlass`）：

1. 用户提供的截图（1158×356@2x）像素测量：
   - 玻璃胶囊本身的四个角都是 26pt 圆弧（底左圆弧拟合圆心 (120,238)、半径 52px，与 `CapsuleShapeView.bottomRadius = 26` 一致）；
   - 另有一条**深色 1px 线**贴着窗口 frame 矩形：左边缘 x=67–68、下边缘 y=291–292、上边缘 y=23，底左角在 (68,290) 处**直角相交**（顶左角则是圆弧）。frame 矩形 = 1041×269px = 520×134pt，与 `OverlayPanel` 的 frame 完全一致。
2. 探针复现（scratch worktree `/tmp/island-probe-overlay`，只加钩子，不进 master）：调用真实 `showOverlay(interactive: true)` 后整屏截图，在 frame 左边缘 x=2084 处同样量到 1–2 个近黑像素（L≈2，背景 L≈17–20）。
3. 逐层排除：`ISLAND_PROBE_NOSHADOW=1`（仅把 `panel.hasShadow` 置 false）后，该黑线**完全消失**（同一位置近黑像素计数 0）。玻璃/形状层未动。

结论：这条直角黑线来自 **`OverlayPanel.hasShadow = true` 在透明无边框窗口上生成的矩形阴影**。窗口 alpha 本身是 26pt 圆角（单独抓窗口验证），但系统给这个窗口画的投影按 frame 矩形计算：贴边的接触线是 1px 硬边，四个角同 frame 一样是直角。悬浮窗四角为圆角，于是角上的直角阴影从「矩形减去圆角」的缺口里露出来；壁纸越亮越明显。

## 期望结果

- 悬浮窗四角不再出现直角黑线；圆角轮廓与玻璃一致。
- 不引入新的视觉回归（描边、玻璃边缘、弹出/隐藏动画不变）。

## 方案

`Sources/Island/OverlayPanel.swift`：`hasShadow = true` → `false`，并写明原因（系统对透明无边框窗口按 frame 画矩形阴影，与胶囊圆角不符；要投影需自绘圆角阴影，窗口外扩另议）。

覆盖面：`Sources/Island/OverlayPanel.swift` 在 `coverage.config` 的排除项内（AppKit wiring），可测增量为 0，coverage 增量 gate 记 N/A；不新增测试。

## 验证

- `make verify` 全 gate 通过。
- 复现脚本：探针 worktree 里 `ISLAND_PROBE_SUMMON=1 ./build/Island.app/Contents/MacOS/Island`，`screencapture -x`，检查 frame 边缘近黑像素；修复后计数 0。

## 备注

- 全程在独立 worktree（`../.worktree/<repo>-<slug>`）中完成，合回 master 前 `make verify` 全过，流程见 AGENTS.md / Workflow / Worktree 与 Ship
- 遗留：若需要投影，应自绘圆角阴影（窗口外扩 + 内容内缩），属另一次改动

# History

## 2026-10-19T20:50:22+08:00: new -> in-progress

Scope-check: PLAN § Island 展示 UX（悬浮窗外观）。根因已由像素测量+探针逐层排除定位到 OverlayPanel.hasShadow 的矩形窗口阴影，开始改。

## 2026-10-19T20:52:17+08:00: in-progress -> solved

根因：透明无边框 NSPanel 的 hasShadow=true 让系统按 frame 矩形画投影，1px 硬接触线在胶囊圆角的缺口处露出直角黑线；用户截图像素测量 + 探针逐层排除（ISLAND_PROBE_NOSHADOW=1 后黑线消失）确认。改法：OverlayPanel.hasShadow=false，并在 CONTEXT Gotchas 记下原因。验证：make verify 全过（497 tests / 100.00% / cycles ok / issue-check ok），另附对比截图 /tmp/shadow-before-after.png。遗留：要投影需自绘圆角阴影，未做。
