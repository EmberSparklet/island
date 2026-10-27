---
type: bug
name: glass-shadow-clipped-panel-edge
title: "悬浮窗四个圆角露出方形阴影（Liquid Glass 阴影被窗口矩形裁掉）"
status: solved
created_ts: 2026-10-19T21:47:53+08:00
updated_ts: 2026-10-27T23:56:30+08:00
---

> 总纲：[ISSUES.md](../ISSUES.md)

## 背景

`hasShadow = false` 修掉窗口阴影之后，用户反馈四个圆角外面还有一圈"漏出去的背景色"（截图
`1158×356@2x`，深色壁纸下看不清，浅色壁纸下尤其是底右角明显）。

复现与定位（2026-10-19 晚，master `31d053b`）：

- **交互态复现**：临时 worktree 里加 `ISLAND_PROBE_SUMMON=1` 钩子，直接调用
  `showOverlay(interactive: true)`（绕过 TCC 不允许的合成按键），窗口内是 520×134pt。
- **同背景对照**：先用一个自绘渐变窗口（渐变蓝→绿，level `.statusBar-1`）铺满屏幕顶部，
  再分别抓「无面板 / 交互态 / 被动弹出」三帧做 A/B。
- 结果：交互态（面板成为 key window）四个角的「矩形减圆角」区域被压上一层**方形**的暗色，
  底右角最明显；**同一背景下的被动弹出完全干净**（四角 diff 恰为 0）。

像素特征（判定为阴影而非填色）：

| 来源 | 角区像素 | 同位置壁纸 | 三通道比值 |
|---|---|---|---|
| 用户截图 底右角 | (138,180,132) | (155,200,146) | 0.89 / 0.90 / 0.90 |
| 复现 底右角 | (29,82,136) | (38,104,167) | 0.76 / 0.79 / 0.81 |

三通道等比例变暗、色相不变 = 乘性阴影；若是面板底色按 α 混合，色相会向蓝/绿偏。
且这层暗色**严格止于窗口矩形边**（矩形外一个像素的阶梯跳变，面板下方壁纸也没有被压暗），
说明它被窗口的绘制画布裁掉了，不是系统窗口阴影（那条 1px 硬线已由 `31d053b` 去掉）。

## 期望结果

四个圆角外面干净，没有任何方形底色或硬切线；面板视觉上仍是"挂在菜单栏下方的胶囊"。

## 根因

`NSGlassEffectView` 在**活跃外观**（active appearance，只有 key window 才拿得到）下会连同
镜面高光一起画一圈柔和阴影，且这圈阴影的扩散范围比视图本身大得多。当前面板窗口**恰好只有
胶囊大小**（520×134pt，见 `OverlayPanel.setContentSize` / `positionNearTopOfScreen`），
窗口外没有画布，阴影只能被裁在窗口矩形里——能落在窗口内、又不在胶囊内的区域，正好是
四个角上「矩形减 26pt 圆角」的四块小方块，于是呈现为方形直角。

两条外部依据（macOS 26 Liquid Glass 的实测规则集，来源
<https://skillsmp.com/creators/ahkohd/dotfiles/agents-agents-skills-liquid-glass-rim>）：

- Rule 1：玻璃默认渲染"扁平无高光的非活跃变体"，只有 key window 才有活跃外观（含高光与阴影）。
  这解释了为什么被动弹出干净、交互态有方形阴影。
- Rule 5："Give the shadow room to breathe"：玻璃自带阴影远大于布局 frame，任何裁切都会
  产生可见硬切；面板的画布边界是硬边界，需要在小控件四周留 40pt（toast 更大）边距，
  并把 frame 原点补偿回原来的位置。

## 最终修法（2026-10-27 收口）：换成毛玻璃

用户一句「就毛玻璃吧」拍板。改动（一个 commit）：

1. `OverlayContentView`：删掉 `OverlayGlassView` / `glassView` 与 `applyBackground()`；所有主题（含
   `liquidGlass`）统一走 `NSVisualEffectView`（`.behindWindow` + `hudWindow`/`popover` 材质）+
   `CapsuleShapeView.maskImage` 裁形。`liquidGlass` 保留「四角全圆」的形状与原取色/描边，只少掉那层
   镜面高光与折射。
2. `OverlayPanel`：窗口尺寸回到等于胶囊（`shadowInset`、`capsuleScreenRect` 一并删掉），内容直接铺满窗口。
3. 删 `Sources/Island/OverlayClickThrough.swift`（没有透明边距，也就不需要动态
   `ignoresMouseEvents`），`AppDelegate` 的启动/停止与属性同步移除，`coverage.config` 移除该文件。
4. `IslandCore.OverlayGeometry` 收敛到只剩 `windowOrigin(capsuleTop:centerX:content:)`；单测从 6 个改为 3 个，
   只断言「胶囊上沿 = capsuleTop」「水平居中」「没有边距」。

验证：`swift test` 508 tests / 0 failures，`make verify` 全绿；本机抓帧（临时钩子召唤态 + 被动弹出态）
四角外侧没有任何绘制，边界只剩毛玻璃自己的圆角轮廓。

为什么不再走「给玻璃留边距」：见下面方案 A 的实测——同一玻璃在窗口边距 32pt 与 120pt 下四角暗度
完全一致（143/144 对 143/144），说明那圈灰是玻璃画在形状**外侧**的，窗口大小只决定它「被切断」
还是「淡出」，消不掉。

## 试过的方案 A（2026-10-27，已放弃）

用户拍板：窗口四周留透明边距，让玻璃阴影有落点。实现：

1. `IslandCore.OverlayGeometry` 只放几何（纯函数、可单测）：`shadowInset = 32`、
   `windowSize(forContent:)` = 内容 + 2m、`contentFrame(forContent:)`、
   `windowOrigin(capsuleTop:centerX:content:)`、`capsuleRect(inWindowFrame:content:)`、
   `shouldIgnoreMouse(pointer:capsule:)`。六个单测覆盖数值与边界。
2. `OverlayPanel`：`contentView` 换成容器，胶囊内容按 m 内缩；窗口尺寸 = 内容 + 2m；
   顶边同样留 m（窗口顶边越过菜单栏下沿 m，菜单栏不足 m 时落到屏幕外），
   四个角都有画布，阴影自然淡出。
3. 点击穿透：`hitTest` 返回 nil 不够（事件仍归窗口），改由新增 `OverlayClickThrough`
   在面板可见时以 30Hz 轮询 `NSEvent.mouseLocation`，指针在胶囊外就
   `ignoresMouseEvents = true`。`AppDelegate` 在 `showOverlay` 启动，
   `hideOverlay` 与自动隐藏时停止。

未验证（需人工，锁屏状态下抓不到）：四角是否真的干净、边距内点击是否真的穿透、
指针进入胶囊到窗口恢复接收点击之间约 33ms 的误差是否会吞掉极快的一次点击。

**2026-10-27 复核结果：方案 A 无效，已推翻**。抓帧比对（召唤态 10x 放大 + 逐像素 diff）看到的四角
那圈灰与修前一致；再做隔离探针（自建窗口 + `NSGlassEffectView`，其余条件相同，只改窗口边距）：
边距 32pt 与 120pt 的四角暗度完全一致（143/144 对 143/144），边距外 6pt 起差异 0.0。结论：那圈灰
是玻璃自己画在形状外侧的，不是被窗口矩形裁出来的——边距只会改变「被切断」还是「淡出」。
另外实测被动弹出态的改变区域严格止于胶囊轮廓，边界是圆弧而不是直角，进一步印证上面这条。

## 备注

- 全程在独立 worktree（`../.worktree/<repo>-<slug>`）中完成，合回 master 前 `make verify` 全过，流程见 AGENTS.md / Workflow / Worktree 与 Ship
- 复现手段：临时 worktree + `ISLAND_PROBE_SUMMON` 钩子（只在本机、不入库），配合自绘背景窗口做
  A/B；面板窗口 id 用 `CGWindowListCopyWindowInfo`（owner 名为小写 `island`）取。
- 验证本 issue 的修复需要**显示器解锁并保持点亮**：`caffeinate -u -t 300` 之后才能抓屏比对；
  锁屏状态下所有抓屏都是锁屏画面，面板也拿不到 key 状态。

# History

## 2026-10-27T22:40:41+08:00: new -> in-progress

代码已按方案 A 落地（窗口四周 32pt 透明边距 + 内容内缩 + 原点补偿 + OverlayClickThrough 动态 ignoresMouseEvents），构建与单测已过；四角视觉与边距点击穿透待人工验收（需解锁屏幕 + caffeinate 抓帧）。

## 2026-10-27T23:26:02+08:00: in-progress -> solved

换成毛玻璃收口，方案 A 推翻。所有主题统一走 NSVisualEffectView + maskImage 裁形，删掉 OverlayGlassView、窗口 32pt 透明边距（shadowInset）、OverlayClickThrough 30Hz 轮询与 capsuleScreenRect；窗口尺寸回到等于胶囊，OverlayGeometry 只剩 windowOrigin（6 个单测 -> 3 个）。依据：隔离探针里边距 32pt 与 120pt 的四角暗度完全一致（143/144 对 143/144）、边距外差异 0.0，说明灰是玻璃自绘在形状外侧的，加边距消不掉。验证：swift test 508/0，make verify 全绿，本机抓帧四角外侧无任何绘制。
