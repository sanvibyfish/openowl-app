# FEAT-011: Ghostty 风格终端 AppleScript 控制

> 状态：✅ Done | 创建日期：2026-08-09 | 完成日期：2026-08-09

---

## 1. 功能概述

openOwl 通过 macOS Cocoa Scripting 暴露 Ghostty 1.3 术语兼容子集，让 `osascript`、启动器和其他外部程序直接查询并操控 openOwl 原生 Tab 与 Pane。调用方可以使用稳定 ID 创建 Tab、四向分屏、聚焦、输入和关闭终端，不需要在原生 Pane 内再嵌套 tmux。

openOwl 使用自己的应用名与 bundle identity，不冒充 Ghostty。`openOwl.sdef`、Cocoa Scripting wrapper 与保留的 Ghostty MIT 许可随应用一同打包。

## 2. 用户流程

### 2.1 查询并操控 Pane

```applescript
tell application "openOwl"
    set sourceTerminal to focused terminal of selected tab of front window
    set sourceID to id of sourceTerminal

    set createdTerminal to split sourceTerminal direction right
    set createdID to id of createdTerminal

    focus createdTerminal
    input text ("pwd" & linefeed) to createdTerminal
    close createdTerminal
end tell
```

`window`、`tab` 和 `terminal` 都返回稳定 object specifier。Tab ID 和 Terminal ID 分别对应 `TerminalTabState` UUID 与 Pane UUID；脚本可保存 ID，并通过 `terminal id ...` 再次取得任一 namespace 中仍存活的 Pane。`tab id ...` lookup 受当前 active namespace 边界约束。

不传 configuration 的 `split` 会继承目标 Pane 最近通过 shell integration 上报的 working directory（若已有上报）。显式指定的 working directory 优先。

### 2.2 使用 surface configuration 创建 Pane

```applescript
tell application "openOwl"
    set sourceTerminal to focused terminal of selected tab of front window
    set agentConfig to new surface configuration from {¬
        initial working directory:"/tmp", ¬
        command:"/bin/zsh", ¬
        initial input:"printf 'ready\\n'", ¬
        wait after command:true, ¬
        environment variables:{"OPENOWL_TEAM=review"}, ¬
        font size:14}

    set agentTerminal to split sourceTerminal direction right with configuration agentConfig
end tell
```

`new tab in front window with configuration ...` 使用同一配置结构，但只允许在 free-terminal namespace 中调用。项目 namespace 的并行布局继续使用 worktree 与 split。

## 3. 技术实现

### 3.1 对象模型与命令

```text
application openOwl
└── window id "main"
    ├── selected tab
    └── tabs[]
        └── terminals[]
```

| 对象 | 稳定 ID | 查询范围 | 主要属性 |
|------|---------|----------|----------|
| application | macOS 应用对象 | 全局 | `front window`、`windows`、`terminals` |
| window | 固定为 `main` | 当前 active namespace | `name`、`selected tab`、`tabs`、`terminals` |
| tab | Tab UUID | 当前 active namespace | `name`、1-based `index`、`selected`、`focused terminal` |
| terminal | Pane UUID | Tab、window 或 application | `name`、`working directory` |

第一版只暴露一个逻辑 window。它代表 openOwl 当前终端工作区，不等同于 AppKit `NSWindow` 枚举：`window.tabs` 与 `window.terminals` 只返回 active namespace 的内容；`application.terminals` 和 application 级 UUID lookup 遍历所有仍存活的 namespace，因此后台 Pane 仍可通过已保存的 UUID 定位。

| 命令 | 目标 | 行为 |
|------|------|------|
| `new surface configuration` | application | 校验并返回可复用的 surface configuration record |
| `new tab` | application/window | 在 free-terminal namespace 创建并选中新 Tab |
| `split` | terminal | 在目标左、右、上、下创建 Pane，并返回新 terminal |
| `focus` | terminal | 聚焦目标 Pane，必要时切换 namespace 与 Tab |
| `input text` | terminal | 直接向已就绪的 libghostty surface 注入文本 |
| `select tab` | tab | 切换到目标 namespace 与 Tab |
| `close` / `close tab` | terminal/tab | 定向关闭，但不允许自动化关闭 Tab 的最后一个 Pane或 namespace 的最后一个 Tab |

### 3.2 控制链路与状态归属

```text
openOwl.sdef
    -> Cocoa Scripting wrapper
    -> AppDelegate 自动化协调层
       -> ProjectStore：namespace 激活与 editor veto
       -> TerminalWorkspaceStore：Tab、split tree、稳定 Pane 位置与启动配置
       -> GhosttyAppManager / TerminalNSView：surface 就绪、焦点与文本输入
```

AppleScript wrapper 只负责对象转换、参数校验与 Apple event 错误映射。`TerminalWorkspaceStore` 仍是布局和 Pane 生命周期的 SSOT；跨 namespace 操作沿用 `ProjectStore.activate`，因此不会绕过未保存编辑器的 context change 审批。

### 3.3 Surface configuration

`TerminalSurfaceConfiguration` 按新 Pane UUID 在 `TerminalWorkspaceStore` 中登记，并在 SwiftUI 挂载 Pane 之前完成。`TerminalPanel` 将配置交给 `TerminalNSView`，后者在 `ghostty_surface_new` 时一次性填入 `ghostty_surface_config_s`。

| 字段 | 映射 | 校验与语义 |
|------|------|------------|
| `initial working directory` | `working_directory` | 必须是已存在的绝对目录；显式值优先于目标 Pane cwd 与宿主 cwd |
| `command` | `command` | 可选文本，不允许 U+0000 |
| `initial input` | `initial_input` | 可选文本，不允许 U+0000 |
| `wait after command` | `wait_after_command` | boolean，默认 `false` |
| `environment variables` | `env_vars` | `KEY=VALUE` 文本列表，key 不得为空且不得包含 U+0000 |
| `font size` | `font_size` | 有限数值，范围 1–255 pt |

openOwl 先注入宿主所需的 `TERMINFO_DIRS` 与 `GHOSTTY_SHELL_FEATURES`，再应用调用方环境变量；相同 key 以调用方的值为准。Pane 销毁时，title、pwd、搜索状态和启动配置一并清理，surface 只销毁一次。

### 3.4 Runtime registry 与 suite registry

- `OpenOwlScriptRuntime` 保存弱引用 `AppDelegate`，在应用启动完成时绑定；自动化命令由此进入当前正在运行的 workspace、project store 与 Ghostty manager，不创建第二套状态。
- `GhosttyAppManager` 以 Pane UUID 注册实际的 `ghostty_surface_t`、`TerminalNSView` 与 scroll view。`focus` 和 `input text` 只对该 runtime registry 中已经挂载的 surface 成功；布局中存在但 surface 尚未就绪时返回错误。
- `NSScriptSuiteRegistry.shared()` 从 app bundle 加载 `openOwl.sdef`，再按 Apple event class code 取得 application/window class description。window、tab、terminal 的 `NSUniqueIDSpecifier` 由该 suite registry 构造，保证 `osascript` 收到可再次解析的稳定 object specifier。

### 3.5 错误语义

自动化不会在目标失效时回退到当前 Pane，也不会静默丢弃尚未就绪的操作。

| 场景 | Apple event error |
|------|-------------------|
| UUID 未知或对象已销毁 | `errAENoSuchObject` |
| editor veto、关闭最后一个 Pane/Tab、项目 namespace 新建 Tab | `errAEEventNotPermitted` |
| workspace/runtime/window/surface 尚未就绪，或操作执行失败 | `errAEEventFailed` |
| 缺少必要参数 | `errAEParamMissed` |
| 参数类型或配置值非法 | `errAECoercionFail` |

### 3.6 异步 context 通知

关闭 active Tab 中当前 focused Pane 后，store 先完成 split tree 折叠、邻居选择和 Pane 状态清理，再通过主队列异步触发一次 `onContextDidChange`。这样 Files/Git 等依赖活动终端 cwd 的面板只会看到完整的新上下文，也避免在当前状态变更栈内重入同步逻辑。

关闭 background Pane 不改变活动上下文，因此不发送通知。AppleScript 新建 active Tab 会显式触发 context 通知；跨 namespace 的选择继续由 `ProjectStore` 的宿主同步链路处理。

## 4. 注意事项

- 当前只支持一个逻辑 window 与 active namespace 视图，不提供多个原生窗口的 AppleScript 管理。
- `split`、`focus` 与 `input text` 要求目标 Pane 的 AppKit view/surface 已挂载；未知 ID 与尚未就绪是不同错误。
- `input text` 是直接文本注入，不模拟全局键盘或鼠标事件。
- 自动化不能关闭 Tab 的最后一个 Pane，也不能关闭 namespace 的最后一个 Tab；这些操作继续由现有宿主关闭事务与 editor 审批负责。
- 本功能不包含 `openowl` CLI、Unix socket、Claude Code display/provider 适配、Agent 状态识别、tmux 协议兼容或 session 持久化。
- 当前也不暴露鼠标、滚轮和任意 Ghostty action 转发。

## 5. 测试与验收

`openOwlTests/AppleScriptTerminalControlTests.swift` 现有 14 项 Swift Testing 用例已覆盖：

| 范围 | 用例数 | 覆盖内容 |
|------|--------|----------|
| Scripting bundle 与对象 | 4 | Info.plist/sdef、运行时 selector、window/tab/terminal 稳定 unique-ID specifier、terminal title/pwd |
| Split 与启动配置 | 4 | 左右上下、surface 创建前登记配置、无显式 cwd 时继承目标 Pane pwd、未知 Pane 不改变布局 |
| 定位、焦点与关闭 | 3 | 跨 namespace 稳定定位、目标焦点、关闭清理与单次 surface 销毁、active/background context 通知差异 |
| 配置解析 | 3 | font size 边界、C string 的 U+0000、working directory 合法性 |

2026-08-09 的真实 app `osascript` smoke 已通过：稳定 object specifier、无 configuration split 的 cwd 继承、带 configuration split、focus、input、close，以及 unknown ID 错误。`agent-device` UI walkthrough 因已有外部 automation session 占用未执行；真实 app 的 `osascript` 端到端链路已完成验收。

## 6. 相关需求

- [REQ-008: 终端 AppleScript 自动化](../requirements/008-terminal-applescript.md)
- [REQ-001: libghostty 终端集成](../requirements/REQ-001-terminal.md)
- [REQ-007: Right Dock + 独立 Terminals](../requirements/REQ-007-right-dock.md)
- [FEAT-001: libghostty 集成指南](001-libghostty-integration.md)
- [FEAT-002: 终端分屏系统](002-terminal-split.md)
- [FEAT-008: Right Dock + 独立 Terminals](008-right-dock.md)

## 7. 更新记录

| 日期 | 说明 |
|------|------|
| 2026-08-09 | 完成 Ghostty 风格 AppleScript 控制面、14 项自动化测试与真实 `osascript` smoke 验收 |
