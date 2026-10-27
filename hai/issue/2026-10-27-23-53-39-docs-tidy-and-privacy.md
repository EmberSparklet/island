---
type: docs
name: docs-tidy-and-privacy
title: "整理文档，清掉本地路径与个人标识"
status: solved
created_ts: 2026-10-27T23:53:39+08:00
updated_ts: 2026-10-27T23:56:01+08:00
---

> 总纲：[ISSUES.md](../ISSUES.md)

## 背景

push 之前把这一批（`origin/master..master`）连同仓库里的文档一起收一次口，发现三类问题：

- 与现状不符：两个 README 仍写「Liquid Glass 用 macOS 26 的系统材质」，而 2026-10-27 起所有主题都走毛玻璃；`README.zh-CN.md` 的设置页 tab 仍是六个（缺 `Launcher`）、没有启动器章节（见 `zh-readme-launcher`）；`hai/CONTEXT.md` 的设置窗口 tab 列表同样缺 `Launcher`；中文 README 的配置段被拆到「菜单栏」之后，还留了一行与配置表重复的任务条数说明。
- 不该入库：`hai/test.go`（162 行 Go 代码，本 repo 是 Swift，没有 Go 工具链，任何文件都没引用）；`hai/issue/2026-10-19-20-49-53-...md` 的「备注」逐字重复一遍。
- 本机痕迹：`/Users/boss/...`、`~/.dsh` 附件路径、`boss` 用户名，以及「boss 反馈 / 拍板」这类称呼。

Scope-check: PLAN 没有文档整理这一节，也没列为 non-goal；本次只动 markdown 与一个无人引用的 Go 文件，不碰 `Sources/`、`Tests/`、`hai/PLAN.md`。

## 期望结果

1. README（中英）与 CONTEXT 的描述与毛玻璃实现一致；中文 README 与英文信息对等（七个 tab、启动器两条、设置页表格含启动器）。
2. `hai/test.go` 删除；issue 里重复的「备注」合并成一条。
3. 树里不再出现 `/Users/boss`、`.dsh` 附件路径与 `boss` 称呼，改用「用户」「仓库根目录」等中性表述。
4. `make verify` 全过（本改动不涉及代码，build / coverage / cycles 沿用现有结果）。

## 备注

- 只整理当前树：`/Users/binyanli/...`（上游作者公开仓库里的路径）与 `lbyxiafei@gmail.com`（Feedback 收件人）保留，不算隐私泄露。
- 已 push 的历史里仍然留着本机路径；改写远端历史被 AGENTS.md / Never 第 1 条禁止，本次不处理。

- 全程在独立 worktree（`../.worktree/<repo>-<slug>`）中完成，合回 master 前 `make verify` 全过，流程见 AGENTS.md / Workflow / Worktree 与 Ship

# History

## 2026-10-27T23:55:16+08:00: new -> in-progress

开始整理：README（中英）与 CONTEXT 的毛玻璃/七 tab 描述、中文 README 补启动器两条并重排配置段、删 `hai/test.go` 与 issue 里重复的备注、清掉 `/Users/boss` 等本机路径与 `boss` 称呼。

## 2026-10-27T23:56:01+08:00: in-progress -> solved

按四条收口：README.md 与 README.zh-CN.md 的 Liquid Glass 描述改成毛玻璃；中文 README 补「从悬浮窗提问」与 `Settings…` → `Launcher` 两条、tab 数改成七个、设置页表格加启动器、配置段从菜单栏之后挪回配置一节并删掉重复的任务条数说明；CONTEXT 的设置窗口 tab 列表补 `Launcher`；删 `hai/test.go`（162 行、无人引用的 Go 文件）与 `overlay-shadow-square-corners` 里重复的「备注」；`/Users/boss/...`、`.dsh` 附件路径与 `boss` 用户名统一换成「用户」「仓库根目录」等中性表述。`zh-readme-launcher` 一并解决。验证：`make verify` 全绿（508 tests / 0 failures、coverage 100.00、58 issues consistent）。
