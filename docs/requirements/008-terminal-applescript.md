# REQ-008: 终端 AppleScript 自动化

> 状态：✅ Done | 优先级：P1 | 预估工时：1周 | 创建日期：2026-08-09 | 完成日期：2026-08-09

---

## 1. 需求概述

为 openOwl 的原生 Terminal Tab 与 Pane 提供 macOS AppleScript 控制面，使 Claude Code、Codex、启动器和用户脚本可以查询并操控 openOwl 已有的终端布局，而不需要在原生 Pane 内再嵌套 tmux。

本能力保持工具中立，不内建任何 AI，也不负责 Agent 编排。

## 2. 背景与动机

openOwl 已有原生 Tab、递归分屏、焦点和 Pane 生命周期管理，但这些能力只能由应用 UI 和快捷键调用。外部 CLI 看不到 openOwl 的 Pane，因此多 Agent 工具只能使用单终端模式，或在 openOwl 内再运行一层 tmux。

Ghostty 1.3 在 macOS 上通过 AppleScript 暴露 `application -> windows -> tabs -> terminals` 对象模型。openOwl 使用 libghostty，但 Tab 与 Pane 属于 openOwl 自己的应用层，必须在宿主应用中实现相同语义。

## 3. 用户故事

- 作为 CLI 工具，我希望取得当前窗口、Tab 和 Pane 的稳定 ID，以便后续命令继续引用同一个目标。
- 作为 Agent orchestrator，我希望在指定 Pane 的左、右、上、下创建新 Pane，并在 surface 创建时直接指定 command、cwd 和环境变量。
- 作为用户脚本，我希望聚焦、关闭或向指定 Pane 输入文本，而不是模拟全局鼠标和键盘操作。
- 作为 openOwl 用户，我希望自动化仍遵守项目切换和未保存编辑器审批，不能绕过现有数据保护规则。

## 4. 功能描述

### 4.1 核心功能

第一版提供 Ghostty 1.3 术语兼容的 AppleScript 子集：

- 对象查询：`front window`、`windows`、`tabs`、`selected tab`、`terminals`、`focused terminal`
- 稳定属性：window/tab/terminal `id`，标题、索引、选中态、working directory
- 创建：free-terminal namespace 中新建 Tab；指定 Pane 的四方向 Split
- 启动配置：initial working directory、command、initial input、wait after command、environment variables、font size
- 控制：focus terminal、select tab、close terminal、close tab、input text

不在第一版范围：

- 新建或管理多个原生 openOwl Window
- Unix socket、`openowl` CLI 包装
- Agent 状态识别或 Claude Code 专用逻辑
- tmux session 持久化或 tmux 协议兼容
- 鼠标事件、滚轮事件和任意 Ghostty action 转发

### 4.2 用户流程

1. 外部脚本从 `front window -> selected tab -> focused terminal` 取得当前 Pane。
2. 脚本对目标 terminal 执行 `split ... direction right with configuration ...`。
3. openOwl 在修改分屏树前记录新 Pane 的启动配置。
4. SwiftUI 挂载新 Pane 时，TerminalNSView 将配置一次性传入 `ghostty_surface_config_s`。
5. 返回的 terminal 使用 Pane UUID 作为稳定 ID，可继续被查询、聚焦、输入或关闭。

### 4.3 边界情况

- 未知或已销毁的 ID 必须返回 AppleScript error，不得转而操作当前 Pane。
- App 尚未完成 workspace/ghostty 绑定时必须返回明确错误，不缓存或静默丢弃命令。
- 跨 namespace 聚焦前必须通过 `ProjectStore.activate`；编辑器 veto 时不切换、不分屏。
- `window.tabs` 只暴露当前 active namespace；`application.terminals` 可按 UUID 查询仍存活的后台 Pane。
- Project namespace 不开放 new tab；其并行布局继续使用 worktree + split。
- 第一版只允许定向关闭多 Pane Tab 中的某个 Pane。最后一个 Pane 或整个 Tab 的关闭继续走现有宿主事务，自动化不得绕过退出/编辑器审批。
- `input text` 只对已经创建 surface 的 Pane 成功；surface 尚未就绪时返回错误。首次命令应使用 surface configuration 原子传入。

## 5. 技术方案

### 5.1 架构设计

```text
AppleScript / osascript
        |
        v
openOwl.sdef + NSObject scripting wrappers
        |
        v
AppDelegate coordination
        |
        +--> ProjectStore activation / editor veto
        +--> TerminalWorkspaceStore tab + split tree
        +--> GhosttyAppManager / TerminalNSView input + focus
```

AppleScript wrapper 只做 Cocoa Scripting 对象转换和错误映射。Pane 布局与启动配置仍以 `TerminalWorkspaceStore` 为 SSOT。

### 5.2 API 设计

Store 增加面向目标 ID 的最小接口：

```swift
func location(of paneID: UUID) -> TerminalPaneLocation?
func split(paneID: UUID, direction: TerminalSplitDirection,
           configuration: TerminalSurfaceConfiguration?) -> UUID?
func closePane(_ paneID: UUID) -> Bool
func launchConfiguration(for paneID: UUID) -> TerminalSurfaceConfiguration?
```

AppleScript 使用 Ghostty 1.3 的对象名与命令语义，但应用名为 `openOwl`，不冒充 Ghostty bundle ID。

### 5.3 数据模型

`TerminalSurfaceConfiguration` 按 Pane UUID 保存，仅用于 surface 首次创建：

- `workingDirectory: String?`
- `command: String?`
- `initialInput: String?`
- `waitAfterCommand: Bool`
- `environmentVariables: [String]`，格式为 `KEY=VALUE`
- `fontSize: Float?`

Pane 销毁时必须同步移除配置。

### 5.4 第三方依赖

- Cocoa Scripting / AppleScript：macOS 系统能力
- libghostty `ghostty_surface_config_s`：已有依赖
- Ghostty 1.3 AppleScript 契约：MIT 许可；若复制实质源码或 sdef 内容，发行物保留对应许可声明

不增加第三方运行时依赖。

## 6. 验收标准

1. 构建产物声明 `NSAppleScriptEnabled` 与 `OSAScriptingDefinition=openOwl.sdef`，`sdef` 可从 app bundle 提取。
2. window/tab/terminal 均能用稳定 ID 查询；未知 ID 失败且不改变状态。
3. 对任意存活 Pane 可向四个方向分屏，返回的新 Pane ID 与分屏树一致。
4. command、cwd、initial input、wait、env 和 font size 在 surface 创建前按新 Pane ID 保存，并传入 libghostty。
5. 聚焦后台 Pane 会先切换其 namespace/tab，再把焦点交给对应 TerminalNSView；审批失败时状态不变。
6. 关闭多 Pane 中的指定 Pane会折叠分屏树、销毁一次 surface 并清理 title/pwd/launch config。
7. `input text` 路由到指定 Pane；未知 Pane或 surface 未就绪时报告错误。
8. 原有快捷键创建的 Tab/Pane、项目切换、退出保护和 Pane 拖拽行为保持不变。

## 7. 优先级与排期

P1。先完成 AppleScript 控制面；CLI 包装与 Claude Code provider 适配分别立项，不与本需求捆绑。

## 8. 相关文档

- [REQ-001: libghostty 终端集成](REQ-001-terminal.md)
- [REQ-007: Right Dock + 独立 Terminals](REQ-007-right-dock.md)
- [FEAT-001: libghostty 集成指南](../features/001-libghostty-integration.md)
- [FEAT-002: 终端分屏系统](../features/002-terminal-split.md)
- [FEAT-011: Ghostty 风格终端 AppleScript 控制](../features/011-terminal-applescript.md)
- [AppleScriptTerminalControlTests](../../openOwlTests/AppleScriptTerminalControlTests.swift)
- [Ghostty AppleScript](https://ghostty.org/docs/features/applescript)

## 9. 更新记录

| 日期 | 说明 |
|------|------|
| 2026-08-09 | 完成 Ghostty 风格对象模型、surface configuration、定向控制、错误映射、14 项自动化测试与真实 `osascript` smoke 验收 |
| 2026-08-09 | 用户确认采用 Ghostty 风格的通用 Pane 自动化方向，进入开发 |
