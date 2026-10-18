---
type: feat
name: add-liquid-glass-theme
title: "新增液态玻璃主题"
status: solved
created_ts: 2026-10-18T14:32:34+08:00
updated_ts: 2026-10-18T14:39:54+08:00
---

> 总纲：[ISSUES.md](../ISSUES.md)

## 背景

`OverlayTheme` 的五个主题都只换配色，背景一律是 `NSVisualEffectView` 的 vibrancy 加一层近乎不透明的 tint。用户要求增加一个"液态玻璃"主题，并选定：macOS 26 及以上调用系统的 Liquid Glass 材质，更旧的系统回退成同色系的半透明面板。

## 期望结果

- `OverlayTheme` 新增 `liquidGlass`，走本地化表取名（`Liquid Glass` / `液态玻璃`）
- macOS 26+ 走 `NSGlassEffectView`（本机 SDK 27 已验证该 API：`style` / `cornerRadius` / `tintColor`）；`#available(macOS 26.0, *)` 之外回退到原 vibrancy 路径，包体平台下限仍留在 macOS 13
- 面板内容不能住在背景视图里——现在 `blurView` 一起承载背景和内容，隐藏它就等于隐藏所有内容。改为玻璃层与 vibrancy 层并排放在最底层，内容挂在面板自身
- 形状：`NSGlassEffectView` 没法裁成"上平下圆"，所以 glass 主题下四角都圆，描边跟着走（否则描边与玻璃互相打脸）

## 不做

- 不开 `effectIsInteractive`（macOS 27+）：面板的 hover/点击反馈已由现有代码给出，先不加第二套
- 不做玻璃的 tint 强度设置项
- 不新增 `Sources/Island/` 下的文件，避免再动 `coverage.config`

## 备注

- 全程在独立 worktree（`../.worktree/<repo>-<slug>`）中完成，合回 master 前 `make verify` 全过，流程见 AGENTS.md / Workflow / Worktree 与 Ship

# History

## 2026-10-18T14:39:54+08:00: new -> solved

OverlayTheme 加 liquidGlass（tint alpha 0.22，accent 0x8FE3FF）；macOS 26+ 用 NSGlassEffectView（style .regular、cornerRadius 26），更旧的系统回退原 vibrancy 路径。为让隐藏背景不再连带隐藏内容，把 shape 与 header/list/footer 从 blurView 挪到面板自身，玻璃层与 vibrancy 层并排放在最底层；glass 主题四角圆角，描边同步。383 tests 全过、覆盖 100%，实机截图确认玻璃折射与文字可读。
