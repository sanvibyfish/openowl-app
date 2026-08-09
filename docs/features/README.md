# 功能文档索引

## 状态说明

| 状态 | 标识 | 说明 |
|------|------|------|
| 待评审 | 🔵 Draft | 初稿，待讨论确认 |
| 已确认 | 🟢 Ready | 已确认，可进入开发 |
| 进行中 | 🟡 In Progress | 正在开发中 |
| 已完成 | ✅ Done | 已上线（需添加完成日期） |
| 已搁置 | ⏸️ On Hold | 暂时搁置 |

## 文档列表

| 编号 | 名称 | 状态 | 链接 |
|------|------|------|------|
| 001 | libghostty 集成指南 | ✅ Done | [001-libghostty-integration.md](001-libghostty-integration.md) |
| 002 | 终端分屏系统 | ✅ Done | [002-terminal-split.md](002-terminal-split.md) |
| 003 | Git 变更面板 | ✅ Done | [003-git-changes.md](003-git-changes.md) |
| 004 | 文件浏览器 | ✅ Done | [004-file-explorer.md](004-file-explorer.md) |
| 005 | 本地部署服务 | ⏸️ Archived | [archive/FEAT-005-local-deployment.md](../archive/FEAT-005-local-deployment.md) |
| 006 | 项目管理侧边栏（Project Rail） | ✅ Done | [006-project-sidebar.md](006-project-sidebar.md) |
| 007 | UI 设计系统 | ✅ Done | [007-ui-design-system.md](007-ui-design-system.md) |
| 008 | Right Dock + 独立 Terminals | ✅ Done | [008-right-dock.md](008-right-dock.md) |
| 009 | 文件日志系统 (AppLogger) | ✅ Done | [009-app-logger.md](009-app-logger.md) |
| 010 | 进程资源异常监控 | 🟡 In Progress | [010-resource-monitor.md](010-resource-monitor.md) |
| 011 | Ghostty 风格终端 AppleScript 控制 | ✅ Done | [011-terminal-applescript.md](011-terminal-applescript.md) |

## 分类

### 终端 (Terminal)

- [001-libghostty-integration.md](001-libghostty-integration.md) — libghostty 集成方式、C API 桥接、Metal 渲染
- [002-terminal-split.md](002-terminal-split.md) — 多标签 + 二叉树分屏、焦点导航、窗格拖拽
- [011-terminal-applescript.md](011-terminal-applescript.md) — Ghostty 风格对象模型、稳定 ID、surface configuration 与原生 Pane 自动化

### Git

- [003-git-changes.md](003-git-changes.md) — 暂存/提交/Diff/分支管理/远程操作/Git Graph

### 文件系统 (File System)

- [004-file-explorer.md](004-file-explorer.md) — NSOutlineView 文件树、模糊搜索、Git 状态标注

### 部署 (Deployment) — 已下架

- v1.0.8 移除本地部署功能。设计文档归档于 [archive/FEAT-005-local-deployment.md](../archive/FEAT-005-local-deployment.md)，方便未来恢复参考。

### 基础设施 (Infrastructure)

- [006-project-sidebar.md](006-project-sidebar.md) — Project Rail（窄图标轨）、Worktree popover、持久化
- [008-right-dock.md](008-right-dock.md) — 右侧可折叠 inspector + free terminals + ContentView（左 rail / 终端 / 右 dock）
- [009-app-logger.md](009-app-logger.md) — 文件日志系统，写入 ~/Library/Logs/openOwl/，打包后可查看
- [010-resource-monitor.md](010-resource-monitor.md) — 当前用户进程的内存与 CPU 异常采样、系统通知和告警冷却

## 依赖关系

```
006-project-sidebar ──→ 002-terminal-split
                    ──→ 003-git-changes
                    ──→ 004-file-explorer

002-terminal-split ──→ 001-libghostty-integration
011-terminal-applescript ──→ 001-libghostty-integration
                         ──→ 002-terminal-split
                         ──→ 008-right-dock
010-resource-monitor ──→ 009-app-logger
```

## 更新记录

| 日期 | 说明 |
|------|------|
| 2026-08-09 | 003/004：Git 阻止 unresolved conflicts 进入 commit/discard-all，Discard All 覆盖非 ignored 嵌套仓库，并保持仓库切换期间 command mutex 与详情错误 provenance；Files 保留部分 cut 失败项的移动语义，并在 rename/move 后重启 pending initial activation。完整 XCTest 419 tests / 35 suites 通过 |
| 2026-08-09 | 003/004：Right Dock Git 增加仓库级 draft 与异步 request ownership，修正 Stage/Discard/Unstage、冲突与路径解析边界；文件 rename/move/delete 与 editor URL state 原子同步，并保护 dirty/missing/collision 场景。完整 XCTest 416 tests / 35 suites 通过 |
| 2026-08-09 | 003：正确解析 Git porcelain v1 新旧 unborn branch header，仅显示真实分支名；空仓库 Git Graph 保持 `No commits yet` 空态且不产生 error banner，detached HEAD 行为不变 |
| 2026-08-09 | 003：Git Graph 改用 `git log -z` + `%x00` 的 7 字段 NUL 协议，避免合法提交标题与旧可见 record marker 碰撞，并保持空 refs、root parents 与分页解析正确 |
| 2026-08-09 | 003：Right Dock Git 以 `git rev-parse` 的真实 root 识别仓库，支持 terminal cwd / Files Open Changes 从外层仓库切换到 submodule 或嵌套仓库，同仓库普通子目录保持当前选择与 diff |
| 2026-08-09 | 004：项目切换同步清理旧 Git/Quick Open 数据，并以 captured project URL 门禁浅扫描提交，防止旧项目结果覆盖新项目 UI |
| 2026-03-16 | 创建索引，补全 001–006 功能文档 |
| 2026-05-07 | 加入 008 Right Dock + 独立 Terminals（实现完成） |
| 2026-05-10 | v1.0.8 下架本地部署，005 文档归档至 docs/archive/ |
| 2026-05-30 | 加入 009 文件日志系统 (AppLogger) |
| 2026-07-16 | 加入 010 进程资源异常监控 |
| 2026-07-24 | 006 项目侧边栏增加失效 worktree 残留目录的安全归档流程 |
| 2026-07-28 | 006/008：左侧改为 Muxy 风格 Project Rail，移除宽 NavigationSplitView 侧栏 |
| 2026-07-30 | 004/006：强化编辑器异步读取提交门禁与交互状态保持，并统一 worktree 归档并发 guard |
| 2026-07-31 | 004/006/008：同步 editor context preflight、持久化保护、Right Dock 常驻与 resize 中断语义 |
| 2026-08-09 | 003：补充 Git Graph 分页串行化、刷新 generation 隔离、末行可点击空间、root commit 日志与文件详情，以及 commit diff 加载/空 patch/失败状态契约 |
| 2026-08-09 | 003：补充 commit 切换时折叠/文件选择/滚动状态隔离，以及 quoted UTF-8 路径的统一解码与回归验收 |
| 2026-08-09 | 003：Git Graph 支持展开 commit 修改文件、点击文件定位 diff、展开区域泳道对齐，以及右键复制完整 Commit ID |
| 2026-08-09 | 003：仓库切换原子清理旧 Git 状态，非 Git 目录失败后 refresh 不再恢复旧数据；Git Log 展开文件作为唯一入口，右侧 commit diff 移除重复文件侧栏并使用全宽布局 |
| 2026-08-09 | 加入 011 Ghostty 风格终端 AppleScript 控制（实现与验收完成） |
