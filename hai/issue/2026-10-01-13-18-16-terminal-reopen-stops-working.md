---
type: bug
name: terminal-reopen-stops-working
title: "长时间运行后点击终端任务不再跳转（Claude 桌面版正常）"
status: solved
created_ts: 2026-10-01T13:18:16-07:00
updated_ts: 2026-10-27T22:47:16+08:00
---

> 总纲：[ISSUES.md](../ISSUES.md)

## 背景

2026-10-01 用户反馈：正在运行的 brew 版 island 0.2.3（pid 2174，09:55 左右随登录启动），下拉框里点 Claude 桌面版的行能跳转，点终端（Claude Code in tmux / cmux）的行不跳转。此前用户刚在 Settings → Notifications 把完成弹出关掉（`IslandPopupEnabled = 0`）。

## 排查记录

- 代码层面：`PopupSettings` 只影响自动弹出（`AppDelegate.showOverlay` 的两处 `popup.isEnabled`），不参与 `selectTask` → `reopenQueue` → `AgentReopenExecutor.perform`，判断与弹出开关无关
- 同一二进制 CLI 复现：`Island --reopen-plan 11407 --perform` → `focusTmux(chore:2.1)`，tmux client 切换成功，cmux tab 也聚焦成功
- 杀掉旧进程、用 `nohup /Applications/Island.app/Contents/MacOS/Island > scratchpad/island.log` 重启后，用户在 GUI 里点终端行**跳转正常**（日志：`tmux client /dev/ttys000 -> job:2.1` + `focused scriptable(com.cmuxterm.app ...)`）
- 旧进程由 launchd 启动，stderr 无处可去，点击时走了哪条路径**没有留下证据**；进程已被杀，现场丢失。**根因未定位**

## 可能方向（未验证）

1. `reopenQueue` 是串行队列，`Subprocess.run` 没有超时：某次 osascript / tmux 卡住会让之后所有 reopen 排队不动。但 Claude 桌面版的 openURL 也在同一队列，与"桌面版正常"矛盾，除非桌面版的点击发生在卡住之前
2. 旧进程里点击前的 `pruneClosed` 把行判为已关闭（但这会让行消失，用户应能察觉）
3. 长时间运行后 tmux / cmux 状态与 island 缓存不一致（tmux server 12:04 才启动，晚于 island）

## 期望结果

- 复现时能拿到证据：GUI 运行时的日志要落盘（例如 `~/Library/Logs/island.log`），否则下次仍然无从判断
- 定位根因后修复，并补上能覆盖该路径的 `IslandCore` 测试

## 备注

- 当前（2026-10-01）island 由 Agent 以 nohup 方式前台启动，日志在会话 scratchpad；用户再遇到时先别重启，直接看日志
- 全程在独立 worktree（`../.worktree/<repo>-<slug>`）中完成，合回 master 前 `make verify` 全过，流程见 AGENTS.md / Workflow / Worktree 与 Ship

## 方案（2026-10-27）

三处改动都不改变「点终端行就跳转」的意图，只补可观测性与失败降级；判定逻辑放进 `IslandCore` 以便单测。

1. **日志落盘**：新增 `Sources/Island/IslandLog.swift`，每行同时写 stderr 与 `~/Library/Logs/island.log`（追加；这次写入会超过 1 MB 时先截断再写）。`AppDelegate.log` / `AgentReopenExecutor.log` / `StatusItemController.log` 与 `selectTask` 里那行 `selected …` 全部改走它。由此 launchd 启动、stderr 无处可去的实例也有证据。
2. **子进程超时**：`Subprocess.runWithStatus` 默认 10s（新增带默认值的 `timeout:` 参数，原有调用签名与 `run` / `appleScript` 行为不变）；超时先 `terminate()`，2s 内没死再 SIGKILL，返回 status `124`（`timeout(1)` 的约定）与已读到的输出。两个管道在子进程运行期间持续 drain，超时或大输出都不会再卡在读管道上。osascript 走同一条路径，因此同样受限。
3. **tmux 失败降级**：`focusTmux` 开始检查 `select-window` / `select-pane` / `switch-client` 的退出码。判定收在 `IslandCore.TmuxFocus` 的纯函数（`firstFailure(in:)` / `fallbackReason(_:)`，有单测）；任一非 0 → 记 `WARN tmux <cmd> failed (status N)` 并 `activateAnyTerminal()` 降级，不再无条件打成功日志。

## 已验证 / 未验证（2026-10-27）

已验证：

- `TmuxFocus` 7 个单测：全成功、空列表、三个命令各失败、只报第一个失败、命令无法启动（-1）算失败
- 用真实 `Subprocess.swift` 源码 + 临时 harness 实测：正常命令 status/stdout/stderr 全部保留；`sleep 30` 配 1s 超时 → 1.01s 返回 124；不存在的可执行文件 → nil；stdout/stderr 各 200 KB 无死锁、无截断
- 用真实 `IslandLog.swift` + 临时 harness 实测：追加生效；文件涨到 1048604 字节后下一次写入截断（1048604 → 34 字节，只留新行）；同一行同时进 stderr；测试文件为新建，跑完删除，恢复测试前状态
- `make verify` 全绿：511 tests / 0 failures（本改动新增 7 个）、coverage 100.00 >= 100、fmt / lint / cycles / issue-check 全过；rebase 到最新 master（ab02eea）之后重跑过一遍

未验证：

- 真机 GUI 复现路径：本机跑的是 brew 版 `/Applications/Island.app`，本次改动未重新打包安装；下次复现时需要换成新构建产物，确认点终端行后 `~/Library/Logs/island.log` 里有 `selected …` / `tmux` / `WARN` 行
- 10s 超时对首次自动化授权弹窗的影响：AppleScript 首次控制某终端要等用户在系统弹窗里点允许，超过 10s 会被判超时（status 124）。这是刻意取舍（宁可放弃这一次跳转，也不让串行 reopen 队列永久卡住），但没有实测慢速点允许的情况
- 根因仍未证实：本改动只让下次复现可取证、并给子进程加了超时兜底；没有复现现场，不能断言「某次子进程卡住」就是 2026-10-01 的直接原因
- tmux 失败降级没有在真实 tmux 上构造失败复现（例如 stale target）：只验证了纯函数判定，执行层降级路径是代码审查

# History

## 2026-10-27T22:44:20+08:00: new -> in-progress

Scope-check: PLAN § Scope（回到任务）+ § Design / Agents 交互 interface #3；本改动只补日志落盘、子进程超时与 tmux 失败降级，不触发 Ask first，开始动工。

## 2026-10-27T22:45:03+08:00: in-progress -> solved

修 `terminal-reopen-stops-working` 的可观测性与降级三件套：新增 `IslandLog`（stderr + `~/Library/Logs/island.log`，1 MB 截断）、`Subprocess` 加 10s 超时（超时 terminate，2s 未死则 SIGKILL，返回 124）、`focusTmux` 检查三条 tmux 命令退出码并在失败时 WARN + `activateAnyTerminal()` 降级（判定收在 `IslandCore.TmuxFocus`，7 个单测）。`make verify` 全绿：504 tests / coverage 100 / issue-check 56。根因仍未证实，但下次复现有日志可查，且有超时兜底；验证与未验证范围见正文。
