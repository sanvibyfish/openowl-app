# M2: Git 变更管理

## 目标

实现 Git 变更面板，支持查看状态、Stage/Unstage、提交、Diff 查看。

## 任务

### T2.1 Git Service ✅
- [x] GitService.swift — Process 封装调用 git CLI
- [x] git status 解析 (`--porcelain=v1 --branch`)
- [x] git diff 获取 (staged / unstaged / untracked)
- [x] git add / restore --staged / commit / checkout

### T2.2 Changes Panel ✅
- [x] SwiftUI List 展示 Staged / Modified / Untracked 分组
- [x] 单文件 Stage/Unstage 按钮
- [x] Stage All / Unstage All
- [x] Commit message textarea + Cmd+Enter 提交

### T2.3 Diff View ✅
- [x] Unified diff 渲染（monospace + 按行着色）
- [x] 绿色加行 / 红色减行高亮
- [x] 文件头信息展示（选中文件路径）
- [x] 文件内容语法高亮（轻量关键词/注释/字符串高亮）

### T2.4 文件监听 ✅
- [x] `FSEvents` 监听工作目录变化
- [x] 防抖 (300ms) 自动刷新 git status
- [x] 忽略 `.git/`、`node_modules/` 等目录

### T2.5 分支与远程操作 ✅
- [x] ahead/behind 展示
- [ ] 创建分支并切换 — **未实现**：`GitService` 无 `createBranch`/`checkout`/`branches`
- [ ] 删除分支（普通删除 / 强制删除）— **未接入**：service 与 store 方法存在，但 `GitConfirmationAction.deleteBranch` 从未被构造，无可达 UI 路径
- [x] Pull / Push 操作入口（**Fetch 未接入**：`GitChangesStore.fetch()` 零调用点）

### T2.6 Discard Changes ✅
- [x] 单文件 Discard（modified/untracked）
- [x] Discard All（modified + untracked）
- [x] 执行前确认弹窗

## 本次实现说明

- 新增 `GitService`：
  - `status/stage/unstage/stageAll/unstageAll/commit/diff/branches/checkout`
  - `deleteBranch/fetch/pull/push/discardModified/discardUntracked`（`createBranch` 未实现；`deleteBranch` 与 `fetch` 无 UI 调用点）
  - 支持 porcelain v1 状态解析与 branch 信息读取
  - 支持 upstream + ahead/behind 解析
- 新增 `GitChangesStore`：
  - 仓库选择、状态刷新、文件选择 diff、提交 auto-stage
  - 分支创建/删除与远程操作编排、discard 命令编排
  - 结合 `FileWatcher` 做目录变化自动刷新（忽略 `.git/`、`node_modules/`）
- 新增 `GitChangesView`：
  - 左侧变更分组列表 + 操作按钮（含 Discard/Discard All）
  - 右侧 unified diff 视图
  - diff 行内语法高亮（按文件扩展名匹配关键词/注释/字符串）
  - 底部 commit 输入区（Cmd+Enter）
  - Header 增加 branch/remote 操作与 tracking 信息
- 新增 `AppNavigationStore` + 侧边栏选择：
  - 在 Terminal 与 Git Changes 面板间切换
  - Terminal 快捷键仅在 Terminal 面板激活

## 验证

- [x] `xcodebuild -scheme openOwl -configuration Debug build` 通过
- [ ] 运行时手测待完成：
  - 选择 repo 后状态刷新
  - Stage/Unstage/Commit 行为
  - Branch create/delete/checkout + ahead/behind 显示
  - Fetch/Pull/Push
  - watcher 触发自动刷新

## 完成标准

- [x] 侧边栏可进入 Git Changes 面板
- [x] 能 Stage/Unstage 文件并提交
- [x] 能查看文件 diff
- [ ] 运行时手测矩阵全部通过
