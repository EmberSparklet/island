---
type: feat
name: launcher-targets
title: "启动器目标可选可配"
status: solved
created_ts: 2026-10-18T21:09:09+08:00
updated_ts: 2026-10-18T21:19:15+08:00
---

> 总纲：[ISSUES.md](../ISSUES.md)

## 背景

方案 `hai/reference/extensions/README.md` §5 的 P3b（启动器第二段）。P3a 已落地（issue `overlay-launcher-compose`）：`⇥` 进 compose → `↩` 打开 DeepSeek，目标清单只有内置一条。`hai/PLAN.md` § Scope / 扩展机制 第 3 条的用户原话是"打开指定 chat 智能体（可选可配）"，本轮补上"可选可配"。

## 范围

- `IslandCore`（纯逻辑，TDD，100% 覆盖）：
  - 目标清单从 `ISLAND_LAUNCHER_TARGETS` 解析，条目格式 `id|显示名|站点基址|查询参数`，条目之间用 `;` 分隔；非法条目跳过（不崩、不静默）。
  - `LauncherSettings` 持有 `[LauncherTarget]`；`ISLAND_LAUNCHER=off` 仍整体关闭，且优先于清单。
  - `Launcher.nextTargetIndex(current:count:)`：compose 态 `⇥` 的目标推进，首尾回绕；只有一个目标时返回 `nil`（按键退回筛选，与 P3a 行为一致）。
- 悬浮窗（AppKit 只做渲染与 `NSWorkspace.open`）：compose 态显示当前目标（沿用目标名胶囊、占位符、footer 提示），`⇥` 切换目标，`↩` 打开所选目标，`esc` 退出。
- 文档：`hai/CONTEXT.md`（env 表 / Layout / Gotchas）、`hai/reference/extensions/README.md`（P3b 落地说明 + 决策行）。

不做（写清以免默认扩张）：

- manifest 的 `targets` 字段与 `plugin.json` 解析（§4.4 原文标注"本稿新增"）：载体选了环境变量，manifest 另开 issue。
- 进程插件（P4）、`subscribe` 事件推送（P1）、token（D12）、已安装智能体探测与多全局键（R3）。
- `autosend`（D9 默认不带）、剪贴板兜底、AX 注入。
- Kimi：需真人先验证 `?q=`（方案 §8 `[未验证]`）。

## 期望结果

- `⇥` 进 compose → 输入一句话 → `⇥` 循环目标（界面显示当前目标）→ `↩`：浏览器打开所选站点，问题在输入框里、**不自动发送**。
- `ISLAND_LAUNCHER=off` 时入口消失（`⇥` 保持默认行为）；`--print-config` 的 `launcher` 行反映当前配置。
- `make verify` 全绿（432+ 测试、覆盖率 100）；新增 `IslandCore` 逻辑有单测：URL 转义（含 CJK / 空格 / `&`=`#`）、空问题、开关解析、多目标选择与循环边界（首尾回绕、单目标）。

## Decision

2026-10-18 用户在本机会话中回答开工前的三个问题，逐条记录授权范围：

1. **配置载体：`ISLAND_LAUNCHER_TARGETS` 环境变量**（选 (b)）。理由：随 repo 既有 `ISLAND_*` 约定，不引入第一份配置文件；两种载体以后都映射到同一个 `LauncherTarget`，manifest 另开 issue。授权范围：本轮只做环境变量载体，不写 `~/Library/Application Support/island/plugins/`。
2. **切换键：compose 态按 `⇥` 循环目标、`esc` 退出**（选 (a)）。
3. **现在不加 Kimi**（选"先不加"）：`?q=` 行为需真人先开一次浏览器验证，未确认就不加。

此外，用户上一轮明确"先不发版"，本轮不跑 `./scripts/publish.sh`。

## 备注

- 目标清单格式：`ISLAND_LAUNCHER_TARGETS="deepseek|DeepSeek|https://chat.deepseek.com/|q"`；多个目标用 `;` 分隔，值与两端的空白忽略。字段非法（条数不是 4、id 非法、站点不是 http(s)、查询参数为空等）的条目跳过，`--print-config` 会打印 warning。整个变量缺失或为空时用内置目标。
- 全程在独立 worktree（`../.worktree/<repo>-<slug>`）中完成，合回 master 前 `make verify` 全过，流程见 AGENTS.md / Workflow / Worktree 与 Ship
- 方案第 6 节列出的 `[未验证]` 项本轮不改结论：DeepSeek `?q=` 是否进输入框仍需真人开一次浏览器确认；Kimi 未验证，故不加。

# History

## 2026-10-18T21:09:59+08:00: new -> in-progress

Scope-check: PLAN § Scope / 扩展机制 第 3 条（启动器，可选可配）；用户已选定载体为 ISLAND_LAUNCHER_TARGETS 环境变量、⇥ 循环目标、本轮不加 Kimi

## 2026-10-18T21:19:15+08:00: in-progress -> solved

P3b 的'可选可配'已实现：IslandCore 新增 ISLAND_LAUNCHER_TARGETS 解析（id|显示名|基址|查询参数，; 分隔，非法条目跳过并在 --print-config 报警告）、LauncherSettings 持有 [LauncherTarget] 且 ISLAND_LAUNCHER=off 优先、Launcher.composeTabAction（⇥ 进入/循环/单目标退出，首尾回绕）；OverlayContent compose 态显示当前目标（胶囊/占位符/footer），单目标时 ⇥ 仍退回筛选，与 P3a 等价；AppKit 不变的部分只有 NSWorkspace.open。证据：swift test --filter LauncherTests 22/22；make verify 全绿（447 测试、覆盖率 100 不低于基线 100、49 个 issue 一致）；真机 --print-config 六种取值实测（默认 DeepSeek / 两条 DeepSeek, Kimi / off / 混入坏条目打 warning / 全坏回落内置 / off 压过清单）；四张截图（单目标 / 两条目标选中第二条 / ISLAND_LAUNCHER=off / 切目标时问题保留）。未验证：真人按键路径与 DeepSeek/Kimi 的 ?q= 浏览器行为（TCC 挡 GUI 自动化，Kimi 未验证故未加入内置）。

独立复核（verifier 子代理在同一 commit 上跑 make verify + 九组 --print-config + 克隆内真实 URL 打印）发现并已修的 4 处：（1）目标 ≥2 时 compose 态 `esc` 误走 ⇥ 的切换分支而不退出——现在 `esc` 恒定 leaveComposing，⇥ 的判定移进 `IslandCore.Launcher.composeTabAction`（有测试，不再躲在覆盖率排除的 AppKit 层）；（2）⇥ 切目标会清空已输入问题——现在保留草稿（截图 D）；（3）`Launcher.url` 丢 baseURL 的端口与自带 query——现在两者都保留（P3a 遗留，本轮可配置后可达）；（4）`hai/CONTEXT.md` 的回落描述补齐"条目全非法也回落内置并打 warning"。
