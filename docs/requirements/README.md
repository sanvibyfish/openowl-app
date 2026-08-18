# 需求文档索引

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
| 001 | libghostty 终端集成 | ✅ Done | [REQ-001-terminal.md](REQ-001-terminal.md) |
| 002 | Git 变更管理 | ✅ Done | [REQ-002-git-changes.md](REQ-002-git-changes.md) |
| 003 | 文件浏览器 | ✅ Done | [REQ-003-file-explorer.md](REQ-003-file-explorer.md) |
| 004 | 本地部署服务 | ⏸️ On Hold | [归档文档](../archive/REQ-004-local-deployment.md) |
| 005 | 终端 Pane 通知系统 | ⏸️ On Hold | [REQ-005-terminal-notifications.md](REQ-005-terminal-notifications.md) |
| 006 | Claude 状态 Sidebar 指示器 | ⏸️ On Hold | [REQ-006-claude-status-sidebar.md](REQ-006-claude-status-sidebar.md) |
| 007 | Right Dock + 独立 Terminals | ✅ Done | [REQ-007-right-dock.md](REQ-007-right-dock.md) |
| 008 | 终端 AppleScript 自动化 | ✅ Done | [008-terminal-applescript.md](008-terminal-applescript.md) |
| 009 | 跨 Agent 消息总线 (Message Bus) | ❌ 已删除 | [REQ-009-message-bus.md](REQ-009-message-bus.md)（存档，2026-08-18 删除） |

## 分类

### Terminal

- [REQ-001-terminal.md](REQ-001-terminal.md) — libghostty 渲染、PTY 与基础交互
- [REQ-005-terminal-notifications.md](REQ-005-terminal-notifications.md) — 已搁置的 Pane 通知方案
- [008-terminal-applescript.md](008-terminal-applescript.md) — 外部程序查询和控制原生 Tab / Pane

### Workspace

- [REQ-006-claude-status-sidebar.md](REQ-006-claude-status-sidebar.md) — 已搁置的 Claude 状态展示
- [REQ-007-right-dock.md](REQ-007-right-dock.md) — Terminal 主工作区与 Right Dock

### Git 与文件

- [REQ-002-git-changes.md](REQ-002-git-changes.md) — Git 变更管理
- [REQ-003-file-explorer.md](REQ-003-file-explorer.md) — 文件浏览器与编辑器

## 依赖关系

```text
008-terminal-applescript -> REQ-001-terminal
                         -> REQ-007-right-dock
```

## 更新记录

| 日期 | 说明 |
|------|------|
| 2026-08-09 | REQ-008 完成：Ghostty 风格终端 AppleScript 控制通过自动化测试与真实 `osascript` smoke 验收 |
| 2026-08-09 | 创建索引，加入 REQ-008 终端 AppleScript 自动化 |
