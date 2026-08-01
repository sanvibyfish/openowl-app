# FEAT-003: Git 变更面板

> 状态：✅ Done | 创建日期：2025-12-15 | 完成日期：2026-03-10

---

## 1. 功能概述

完整的 Git 工作流面板：文件变更列表、暂存/取消暂存、提交、Diff 查看、分支管理、远程操作（fetch/pull/push）、Git Graph 日志。

## 2. 用户流程

### 暂存与提交
1. 查看 Staged / Changes / Untracked 三个分区的文件列表
2. 点击文件查看 diff
3. Stage / Unstage 单个文件或全部
4. 输入 commit message（或点击 AI 生成）
5. 点击 Commit（未暂存时自动 stage all）

### 分支管理
1. 下拉切换分支（checkout）
2. 输入名称创建新分支
3. 删除分支（支持 force）

### 远程操作
- Fetch / Pull（rebase + autostash）/ Push

### Git Graph
- 分页加载提交日志（每页 50 条）
- 显示 hash、message、author、date、refs

## 3. 技术实现

### 3.1 架构

```
GitChangesStore (@MainActor)
  ├── GitService (async git CLI wrapper)
  ├── FileWatcher (监听 .git 目录变更)
  └── CommitMessageGenerator (AI 生成 commit message)
```

### 3.2 Git CLI 封装

`GitService` 通过 `Process` 调用 `/usr/bin/env git`，关键细节：
- **管道读取顺序**: 先读 stdout/stderr 再 `waitUntilExit()`，避免 64KB 管道缓冲区满导致死锁
- **状态解析**: `git status --porcelain=v1 --branch` → `parseStatus()` 解析分支、upstream、ahead/behind、文件变更
- **路径解码**: 处理 git 的 quoted path（`"path with space"`, `\\` 转义）

### 3.3 实时刷新

`FileWatcher` 监听项目目录（FSEvents），0.3s debounce 后触发 `refresh()` → 重新加载 status + diff + branches + log。

### 3.4 Diff 展示

选中文件后异步加载 diff：
- Staged: `git diff --staged -- <path>`
- Modified: `git diff -- <path>`
- Untracked: `git diff --no-index -- /dev/null <path>`

## 4. 注意事项

- `runCommand()` 包装所有异步操作，确保 `isRunningCommand` 互斥锁防止并发冲突
- Discard 操作区分 modified（git restore）和 untracked（git clean）
- Commit 使用临时文件传递 message（`--file`），避免 shell 转义问题

## 5. 相关需求

- [REQ-002: Git 变更](../requirements/REQ-002-git-changes.md)

## 6. 更新记录

| 日期 | 说明 |
|------|------|
| 2026-08-01 | Right dock Diff 改为默认 **unified（单栏）+ 长行 wrap**（对齐 VS Code / GitHub 窄栏惯例）；去掉 side-by-side 半宽与按最长行撑开的横向滚动 |
| 2026-03-16 | 创建文档 |
