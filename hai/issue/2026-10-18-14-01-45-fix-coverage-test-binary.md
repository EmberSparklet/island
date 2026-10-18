---
type: bug
name: fix-coverage-test-binary
title: "coverage 脚本在新 SwiftPM 布局下找不到测试二进制"
status: solved
created_ts: 2026-10-18T14:01:45+08:00
updated_ts: 2026-10-18T14:05:16+08:00
---

> 总纲：[ISSUES.md](../ISSUES.md)

## 背景

`make verify` 的 coverage gate 在本机必然失败。根因是脚本对 SwiftPM 构建布局的两处过时假设：

1. `scripts/coverage.sh:20` 用 `-path '*/debug/*'` 找测试包，并把可执行文件写死为 `IslandPackageTests`。启用 Xcode 工具链后实际路径是 `.build/out/Products/Debug/IslandCoreTests.xctest`：目录名是 `Debug`（大写），可执行文件等于 target 名。两个假设都不成立，脚本直接报 `coverage: test binary not found at /Contents/MacOS/IslandPackageTests`。
2. `coverage.config` 排除的是 `\.derived/runner\.swift`。新布局生成的入口是 `.build/out/Intermediates.noindex/Island.build/Debug/IslandCoreTests-p.build/DerivedSources/test_entry_point.swift`，没有匹配上，于是这段自动生成的代码计入了总分。

实测：手工跑 `llvm-cov export` 得 99.49%（2350/2362 行），未覆盖的 12 行全部来自 `test_entry_point.swift`，`Sources/IslandCore/` 为 100%。据此判断基线 100 是脚本问题，不是代码退步。

## 期望结果

- `./scripts/coverage.sh` 不再写死包名与 `debug` 大小写，从 xctest 包自身推导可执行文件
- `coverage.config` 同时覆盖新旧两种 SwiftPM 入口文件名
- `make verify` 六个 gate 全绿，`coverage.txt` 为 100

## 不做

- 不动覆盖率基线（保持 100）
- 不动 `Sources/Island/*.swift` 的既有排除项
- 不加脚本测试框架：shell 脚本不在覆盖率统计内，本次增量覆盖率记 N/A

## Scope-check

用户在本轮明确指令「先修 coverage 环境适配，再动功能」。PLAN 未涉及构建脚本，以用户指令为准。

# History

## 2026-10-18T14:02:52+08:00: new -> in-progress

开工：改 scripts/coverage.sh 从 xctest 包推导可执行路径，改 coverage.config 覆盖新布局的 test_entry_point.swift。

## 2026-10-18T14:05:16+08:00: in-progress -> solved

根因两处：coverage.sh 用 -path '*/debug/*' 找 xctest 包并把可执行文件写死为 IslandPackageTests（实际是 Products/Debug/IslandCoreTests.xctest，可执行文件等于 target 名）；coverage.config 排的是 \.derived/runner\.swift，实际生成的是 DerivedSources/test_entry_point.swift。改成从 xctest 包推导路径，排除项覆盖两种布局。verify 全绿：356 tests / 0 failures，coverage 100.00 >= 100.00，issue-check ok。
