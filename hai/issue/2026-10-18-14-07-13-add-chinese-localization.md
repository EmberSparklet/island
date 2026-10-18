---
type: feat
name: add-chinese-localization
title: "界面支持中英双语"
status: solved
created_ts: 2026-10-18T14:07:13+08:00
updated_ts: 2026-10-18T14:30:26+08:00
---

> 总纲：[ISSUES.md](../ISSUES.md)

## 背景

界面文案全部硬编码在 Swift 源码里，CONTEXT.md § Conventions 还明确要求"菜单项等 UI 字符串同样用英文"。系统语言是简体中文的用户看到的是英文界面。

用户在本轮要求给 island 加中文版，并选定：跟随系统语言，同时在设置里提供语言选项（自动 / 中文 / English）。

## 期望结果

- `IslandCore` 新增本地化表：`AppLanguage`（system / english / simplifiedChinese）、90 个 `TextKey`、中英两张 `[TextKey: String]`、9 个 scenario 的三段文案，以及 `UserDefaultsLanguageStore`
- 读取统一走 `L10n.current`。`IslandCore` 默认英文、App 启动时按设置切一次，因此既有 356 个英文断言无需改动
- `Settings → Appearance` 增加 `Language` 下拉；切换后菜单栏与悬浮窗立即更新，设置窗口由 `AppDelegate.setLanguage` 重建
- `AgentScenario` 的 title / detection / jumpBack 改为按 scenario id 查表，`AgentProfile` 里不再残留英文句子

## 不做

- CLI 输出（`--print-config` / `--scan-agents` / `--reopen-plan` 等）保持英文：它们是诊断输出，AGENTS.md 要求 log / error message 用英文
- agent 品牌名（Claude Code / Codex / pi）与 `FeedbackReport` 的邮件主题不翻译
- 不做繁体表：`zh-Hant` 暂时落到简体表，已在 `AppLanguage.resolved` 用 `shortcut:` 注释标出

## Scope-check

PLAN 没提界面语言。本轮用户明确要求"给 island 加个中文版"并选定了跟随系统 + 设置项，按 AGENTS.md 的裁决顺序，用户明确指令优先于 PLAN 的沉默。

# History

## 2026-10-18T14:29:54+08:00: new -> solved

界面文案全部走 IslandCore 的本地化表（Localization.swift：AppLanguage + 90 个 TextKey + 中英两表 + 9 个 scenario 文案），读取统一用 L10n.current。语言跟随系统，也可在 Settings → Appearance → Language 固定；AppDelegate.setLanguage 负责重建菜单、悬浮窗与设置窗口。新增 24 个测试（378 全过，覆盖 100%），实测三种状态：显式 chinese、显式 english、删掉键走 system（本机 zh-Hans-CN）都渲染正确。
