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
| 2026-08-01 | 「展开未修改行」限定到工作区 section：`.staged` 的 diff 是 HEAD vs index，而上下文从磁盘读取——磁盘副本可能领先于 index，会把未暂存的改动当作已暂存的上下文呈现在用户决定提交内容的地方。`.untracked` 无基线可展开 |
| 2026-08-01 | commit diff 恢复 hunk 分隔条：此前「禁用展开」误把分隔条一起去掉，两个 hunk 上下紧贴、行号突然跳跃却无任何提示。现在不可展开时渲染为静态条 |
| 2026-08-01 | 磁盘副本短于 diff 预期时明确提示「文件已变化」，不再逐行填空字符串（会渲染成带真实行号的空行，与文件里真正的空行无法区分）；`.failed` 携带具体错误并就地渲染为可重试行，不再借用会被 `refresh()` 清空的全局 error banner；过期的异步读取直接返回，不再把新选择的 `.loading` 覆盖成 `.idle` |
| 2026-08-01 | **commit diff 不再提供「展开未修改行」**：该功能从磁盘读当前工作区文件填充上下文，对历史提交是错误的数据源（正确来源是 `git show <hash>:<path>`），且 `hunkIndex` 每个文件从 0 重数会与共享的 `expandedHunks` 串台，删除文件的 hunk 还会让 `ForEach(1..<0)` 崩溃。工作区 diff 的展开不受影响 |
| 2026-08-01 | `parseUnified` 三处解析修正：diff 尾部换行不再产生幽灵空 context 行；`\ No newline at end of file` 不再当正文渲染（它此前还推高 `prevNewEnd`，使后续 hunk 少算一行）；展开行的旧行号改由 hunk 的 old/new 起点偏移推算，不再直接复用新行号 |
| 2026-08-01 | Right dock Diff 改为默认 **unified（单栏）+ 长行 wrap**（对齐 VS Code / GitHub 窄栏惯例）；去掉 side-by-side 半宽与按最长行撑开的横向滚动 |
| 2026-03-16 | 创建文档 |
