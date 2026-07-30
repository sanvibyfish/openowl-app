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

## 分类

### 终端 (Terminal)

- [001-libghostty-integration.md](001-libghostty-integration.md) — libghostty 集成方式、C API 桥接、Metal 渲染
- [002-terminal-split.md](002-terminal-split.md) — 多标签 + 二叉树分屏、焦点导航、窗格拖拽

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
010-resource-monitor ──→ 009-app-logger
```

## 更新记录

| 日期 | 说明 |
|------|------|
| 2026-03-16 | 创建索引，补全 001–006 功能文档 |
| 2026-05-07 | 加入 008 Right Dock + 独立 Terminals（实现完成） |
| 2026-05-10 | v1.0.8 下架本地部署，005 文档归档至 docs/archive/ |
| 2026-05-30 | 加入 009 文件日志系统 (AppLogger) |
| 2026-07-16 | 加入 010 进程资源异常监控 |
| 2026-07-24 | 006 项目侧边栏增加失效 worktree 残留目录的安全归档流程 |
| 2026-07-28 | 006/008：左侧改为 Muxy 风格 Project Rail，移除宽 NavigationSplitView 侧栏 |
