# openOwl — macOS 原生 Git GUI + Terminal

## 项目定位

openOwl 是一个面向开发者的 macOS 原生桌面应用，定位为 **Terminal + 简易 Git 管理 + 文件浏览器**。

核心理念：**不内建 AI，开放 Terminal 让用户自由选择工具。**

用户可以在原生终端中运行 Claude Code 等 AI CLI 工具，同时通过可视化界面管理 Git 操作和浏览文件。

## 技术栈

| 层级 | 选型 | 理由 |
|------|------|------|
| 语言 | Swift | macOS 原生开发首选 |
| UI 框架 | SwiftUI + AppKit | SwiftUI 做布局，AppKit 做终端视图 |
| 终端引擎 | libghostty | Ghostty 核心库，Metal GPU 渲染，原生级终端质量 |
| Git 后端 | git CLI (Process) | 零依赖、最可靠、支持所有 git 功能 |
| 文件监听 | DispatchSource / FSEvents | macOS 原生文件系统事件 |
| 构建 | Xcode | macOS app 标准构建工具 |

## 与 Electron 版的对比

| 维度 | Electron 版 | macOS 原生版 |
|------|------------|-------------|
| 终端渲染 | Canvas 2D (ghostty-web) | Metal GPU (libghostty) |
| PTY 管理 | node-pty + IPC | libghostty 内置 |
| 进程模型 | 3 进程 (Main/Preload/Renderer) | 单进程 |
| 包体积 | ~200MB+ (含 Chromium) | ~20MB |
| 内存占用 | 高 (Chromium) | 低 |
| 启动速度 | 慢 | 快 |
| 跨平台 | ✅ | ❌ macOS only |

## 架构概览

```
┌─────────────────────────────────────┐
│         SwiftUI App                 │
│  ┌──────────┐ ┌──────────────────┐  │
│  │ Sidebar  │ │   Content Area   │  │
│  │ Projects │ │ ┌──────────────┐ │  │
│  │ Files    │ │ │  Terminal    │ │  │
│  │          │ │ │ (libghostty) │ │  │
│  │          │ │ │  Metal GPU   │ │  │
│  │          │ │ └──────────────┘ │  │
│  │          │ │ ┌──────────────┐ │  │
│  │          │ │ │  Git Panel   │ │  │
│  │          │ │ │  (git CLI)   │ │  │
│  │          │ │ └──────────────┘ │  │
│  └──────────┘ └──────────────────┘  │
└─────────────────────────────────────┘
       零 IPC，零桥接，零 WASM
```

## 与 cmux 的关系

cmux (manaflow-ai/cmux) 是同样基于 libghostty 的 macOS 终端应用，是我们的主要参考。

| 维度 | cmux | openOwl |
|------|------|---------|
| 定位 | Terminal + Agent 通知 | Terminal + Git GUI + 文件浏览器 |
| Git | 只显示 branch + dirty 状态 | **完整 Git 管理**（stage/commit/diff/branch） |
| 文件浏览器 | ❌ 没有 | ✅ 有 |
| 浏览器面板 | ✅ WKWebView | ❌ 不需要 |
| 分屏 | bonsplit (自定义库) | 待定（可参考 bonsplit 或自实现） |
| 状态管理 | TabManager (ObservableObject) | 待定 |
| CLI/Socket API | ✅ 完整 | 后续考虑 |

### 我们可以从 cmux 学习的

1. **libghostty 集成流程**: xcframework 构建 + 缓存策略 + setup.sh 自动化
2. **SwiftUI + AppKit 混合模式**: NSViewRepresentable 桥接终端视图
3. **Panel 协议抽象**: 统一不同面板类型的接口
4. **Workspace 模型**: ZStack + visibility 保持实例存活
5. **Session 持久化**: 窗口布局保存/恢复

### 我们的差异化

- **Git 是一等公民**: cmux 几乎没有 git 功能，我们提供完整的 Git 变更管理面板
- **文件浏览器**: cmux 没有，我们有 git-status-aware 的文件树
- **更面向日常开发**: cmux 偏向 AI agent workflow，我们偏向传统开发工作流

## 文档索引

- [需求文档](./requirements/)
  - [REQ-001: libghostty 终端集成](./requirements/REQ-001-terminal.md)
  - [REQ-002: Git 变更管理](./requirements/REQ-002-git-changes.md)
  - [REQ-003: 文件浏览器](./requirements/REQ-003-file-explorer.md)
  - [REQ-004: 本地部署服务](./archive/REQ-004-local-deployment.md)
  - [REQ-005: 终端 Pane 通知系统](./requirements/REQ-005-terminal-notifications.md)
  - [REQ-006: Claude 状态 Sidebar 指示器](./requirements/REQ-006-claude-status-sidebar.md)
- [里程碑计划](./milestones/)
  - [M1: 骨架应用 + libghostty 终端](./milestones/M1-skeleton-terminal.md)
  - [M2: Git 变更管理](./milestones/M2-git-changes.md)
  - [M3: 文件浏览器 + 侧边栏](./milestones/M3-file-explorer.md)
