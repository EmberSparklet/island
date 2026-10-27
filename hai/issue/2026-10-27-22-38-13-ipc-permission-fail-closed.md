---
type: bug
name: ipc-permission-fail-closed
title: "IPC 目录与 socket 权限收紧失败被静默吞掉"
status: solved
created_ts: 2026-10-27T22:38:13+08:00
updated_ts: 2026-10-27T22:42:28+08:00
---

> 总纲：[ISSUES.md](../ISSUES.md)

## 背景

P0 入站通道（issue `island-ipc-p0`）按 D12 暂缓 token，`hai/reference/extensions/ipc.md` § 3 因此把「目录 0700、socket 0600」当作唯一的访问控制。但 `Sources/Island/IPCServer.swift` 的两处收紧都是尽力而为：

- `:71-73`：`createDirectory` 的 `attributes` 只在目录**新建**时生效，已存在的目录靠一次 `try? FileManager.default.setAttributes(0700)`，失败被吞。
- `:99-100`：`bind()` 之后 `chmod(path, 0o600)` 的返回值直接丢弃。

两处失败时 server 照常 `listen`，socket 就可能停在 umask 派生的权限（本机 umask `0022`，即 `srwxr-xr-x`），同机其他本地用户仍能连进来发 `notify`。这是安全相关的静默失败，且没有 issue 跟踪（2026-10-27 代码侧遗留盘点）。

盘点同批标出的另外三处「丢返回值」的静默失败也一并修，共用本 issue 与同一个 worktree：它们都是「失败信号被丢掉，排障时无从下手」的同一类，改法都只是补日志 / fail closed，不改控制流。

## 期望结果

- 目录或 socket 权限收紧失败时：入站通道不启动（fail closed），失败原因出现在启动日志（`ipc failed: …`）。
- sqlite3 非零退出时把它的 stderr 打到 stderr；正常 SELECT 的返回值不变。
- VS Code 扩展安装、复制到 /Applications 后去 quarantine 失败时有日志，控制流不变。
- Warp（没有 tab 定位手段）的降级在代码里写明是有意为之。
- `make verify` 全绿。

## 本次改动

1. `Sources/Island/IPCServer.swift` —— fail closed：
   - 目录 `setAttributes(0o700)` 改为 `do/catch`，失败 `return .failed("cannot tighten … to 0700: …")`，不再 `try?`。
   - `chmod(path, 0o600)` 检查返回值；非 0 时 `close(fd)` + `unlink(path)` 后 `return .failed("chmod(…) to 0600 failed: <errno>")`。
   - 失败原因经 `StartResult.failed` 由 `AppDelegate.startIPC` 的 `log("ipc failed: …")`（`Sources/Island/AppDelegate.swift:214-215`）落日志，没有在 IPCServer 里重复再记一条。
2. `Sources/Island/ProcessSQLite.swift` —— `standardError` 从 `FileHandle.nullDevice` 改为 `Pipe`：起不来（`Process.run` 抛错）与非零退出都把原因写 stderr（`FileHandle.standardError.write`，前缀 `[island]`，与现有日志一致，之后可由 lead 统一接 IslandLog）。先排空 stdout 再排空 stderr（sqlite3 的 stderr 只有一条错误，不会顶满管道）。
3. `Sources/Island/VSCodeExtensionInstaller.swift` —— `_ = Subprocess.run(…)` 改为判 `nil`（CLI 起不来）并写 stderr；安装结果的判断与流程不变。
4. `Sources/Island/ApplicationsMover.swift` —— `copy` 接收 `log` 闭包；清 quarantine 的 `runWithStatus` 结果判 `nil` / `status != 0` 后记日志；复制与重开流程不变。
5. `Sources/IslandCore/TerminalFocus.swift` —— `plan` 的 `default:` 分支补注释：Warp 等没有 terminal scripting 句柄的宿主只能激活 app、不能定位 tab，是有意降级而非漏写分支。只加注释，不动逻辑。

注：盘点清单写的是 `Sources/Island/TerminalFocus.swift`，实际文件在 `Sources/IslandCore/TerminalFocus.swift`；第 5 项只加注释（无逻辑改动、不影响测试与覆盖率）。

## 验证

- `make verify` 全绿（尾部输出见 History）。
- fail closed 手测：在 `/tmp` 用 `swiftc` 单独编译 `IPCServer.swift` + `UnixSocket.swift` + `IslandCore` 做探针，不碰本机正在跑的 island：
  - `chflags uchg` 让目录无法 chmod：`start -> failed("cannot tighten /tmp/island-perm-probe to 0700: You don’t have permission …")`，且目录里没有生成 socket（没有 listen）。
  - 正常路径：`start -> running(…)`，目录 `drwx------`、socket `srw-------`；`stop()` 后 socket 文件被 unlink。
- sqlite3 stderr 手测（同样探针方式）：坏库 `query -> nil`，stderr 出现 `[island] sqlite3 exited 1 on island-broken.sqlite: Parse error … file is not a database (26)`；正常库 `query -> non-nil`。
- 未验证项：socket 的 `chmod` 失败分支在真实机器上构造不出来（要 bind 成功后 chmod 又失败，例如只读文件系统），只做代码核对；VS Code 安装器与 ApplicationsMover 的日志分支需要「缺 CLI 的 VS Code」「从 dmg 启动并点 Move」这类环境，本次也只做代码核对。

## 备注

- `Sources/Island` 被 coverage 排除、没有测试目标，所以这里以可核对的最小改动 + 日志为准，没有为凑覆盖率把逻辑搬进 IslandCore。
- 全程在独立 worktree（`../.worktree/z-island-chore-silent-failures`，分支 `chore-silent-failures`）中完成，只 commit 不 push。

# History

## 2026-10-27T22:41:57+08:00: new -> in-progress

Scope-check: PLAN § Scope / 扩展机制（入站通知 P0，2026-10-18 人确认）。修盘点出的静默失败，begin in worktree chore-silent-failures。

## 2026-10-27T22:42:28+08:00: in-progress -> solved

IPC 权限收紧改为 fail closed，并补回三处被丢弃的失败信号（sqlite3 stderr、VS Code 安装器、去 quarantine），Warp 的降级补注释。验证：用 /tmp 独立探针（不碰本机正在跑的 island）证实目录无法 chmod 时 `start()` 返回 failed 且不 listen（没有生成 socket）、正常路径目录 0700 / socket 0600；坏库时 sqlite3 的 stderr 现在出现在 stderr；`make verify` 全绿（497 tests / coverage 100 / 57 issues consistent）。未覆盖：socket 的 chmod 失败分支、VS Code 安装器与 ApplicationsMover 的日志分支没有可构造的运行环境，只做代码核对。
