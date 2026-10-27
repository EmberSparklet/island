---
type: bug
name: overlay-edit-shortcuts
title: "悬浮窗输入框不支持 ⌘C / ⌘V / ⌘Z"
status: solved
created_ts: 2026-10-19T23:54:58+08:00
updated_ts: 2026-10-20T00:01:27+08:00
---

> 总纲：[ISSUES.md](../ISSUES.md)

## 背景

用户反馈（原话）："输入框中 ctrl + c , ctrl + v, ctrl + z. 这种常用的命令不支持。需要支持的"。

悬浮窗召唤后可以正常打字，但今天上屏、粘贴、撤销全部没反应：输入框里选中文字按 ⌘C 剪贴板不变，按 ⌘V 什么都不插入，按 ⌘Z 回退不了。同一个 bug 影响全 App 的输入框（设置页的反馈文本框、启动器编辑 sheet、快捷键输入框）。

## 根因

island 是 accessory app（`LSUIElement=true` + `setActivationPolicy(.accessory)`），从来没有 `NSApp.mainMenu`，代码里也搜不到任何 `mainMenu` 赋值。

macOS 上标准编辑命令是 **菜单的 key equivalent**，不是文本控件自己处理的：`NSTextView` / field editor 只实现 `copy:` `paste:` `undo:` `selectAll:` 这些 action，触发它们的是 Edit 菜单里 `⌘C` / `⌘V` / `⌘Z` 的 `keyEquivalent`，沿 responder chain 派发。没有菜单，就没有人发这个 action，按键被静默吞掉。

实测（不是推测）：在真实 app 里注入一段临时探针，唤醒悬浮窗后合成 ⌘V / ⌘C / ⌘Z：

```
# 修复前（工作树 .build 构建，AppDelegate 未挂菜单）
menu=nil active=true key=true
before-paste active=true key=true
after-paste field=                       # ⌘V 没有任何效果
after-copy pasteboard=PROBE-CLIP         # ⌘C 没有覆盖剪贴板

# 挂上 Edit 菜单后
menu=set active=true key=true editor=true
after-paste field=MARKER-ONE canUndo=true undoManager=true
after-undo-paste field=                  # ⌘Z 撤销掉粘贴
after-copy pasteboard=MARKER-ONE         # ⌘C 把选中文字放进剪贴板（原值是 MARKER-TWO）
```

## 修复

`AppDelegate.installEditMenu()`：启动第一件事挂一个最小的 Edit 菜单，含 Undo / Redo / Cut / Copy / Paste / Select All 六项，`target = nil`（走 responder chain），key equivalent 用系统标准的 `z / Z / x / c / v / a`。accessory app 不画菜单栏，所以文案用英文硬编码、不进 L10n。

顺带修好了设置页里所有输入框的同一问题。

## 备注

- Scope-check: PLAN § Island 展示 UX / 下拉框 UX（悬浮窗交互），属于既定 scope，不触发 Ask first
- 验证用的探针（`Sources/Island/KeyProbe.swift` + 两处 hook）在提交前已删除，不在本次 diff 里
- 探针存放与结果见 `/tmp/keyprobe-*.txt`（临时文件，不进仓库）
- 全程在独立 worktree（`../.worktree/z-island-overlay-edit-shortcuts`）中完成，合回 master 前 `make verify` 全过，流程见 AGENTS.md / Workflow / Worktree 与 Ship

# History

## 2026-10-20T00:00:37+08:00: new -> in-progress

Scope-check: PLAN § Island 展示 UX / 下拉框 UX。根因已定位：accessory app 没有 Edit 菜单，标准编辑快捷键是菜单 key equivalent。已加不可见 Edit 菜单，待 verify。

## 2026-10-20T00:01:27+08:00: in-progress -> solved

根因：island 是 LSUIElement，没有 App 菜单，而 ⌘C/⌘V/⌘X/⌘Z/⌘A 是菜单的 key equivalent，所以全 App 文本框的复制粘贴撤销全选一直静默失效。修法：启动时挂不可见 Edit 菜单（target=nil，走 responder chain）。

验证：真实 app 内临时探针合成 ⌘V/⌘C/⌘Z。修复前 menu=nil，⌘V 后 field 仍为空、⌘C 没覆盖剪贴板；修复后 field=MARKER-ONE、canUndo=true、⌘Z 撤销回空、⌘C 把选中文字写进剪贴板。探针提交前已删除。make verify 全过（497 tests，coverage 100.00，56 issues consistent）。
