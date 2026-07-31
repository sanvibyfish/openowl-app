# libghostty 集成指南

## 概述

libghostty 是 Ghostty 终端模拟器的核心库，提供完整的终端功能：VT 解析、PTY 管理、Metal GPU 渲染。

## 集成方式 (参考 cmux 实践)

### 1. 添加 Ghostty 为 git submodule

```bash
git submodule add https://github.com/ghostty-org/ghostty.git ghostty
```

### 2. 编译 GhosttyKit xcframework

需要 Zig 编译器 (`brew install zig`)。

```bash
cd ghostty
zig build -Demit-xcframework=true -Dxcframework-target=universal -Doptimize=ReleaseFast
# 输出: macos/GhosttyKit.xcframework
```

cmux 的做法：
- `scripts/setup.sh` 自动化子模块初始化 + xcframework 构建
- 构建产物按 ghostty commit SHA 缓存到 `~/.cache/cmux/ghosttykit/`
- 项目根目录创建 symlink: `ln -sfn <cached_path> GhosttyKit.xcframework`

### 3. Xcode 配置

- Bridging Header: 只需一行 `#import "ghostty.h"`
- 链接: GhosttyKit.xcframework + 系统框架 (Metal, MetalKit, AppKit)
- 资源: 打包 `ghostty-resources` 到 app `Contents/Resources`，并在 `ghostty_init` 前设置 `GHOSTTY_RESOURCES_DIR`
- 设置 `TERM=xterm-ghostty` 环境变量

### 4. 初始化流程

```
ghostty_init(argc, argv)
  ↓
ghostty_config_new() → ghostty_config_load_default_files() → ghostty_config_finalize()
  ↓
ghostty_app_new(&runtime_cfg, config)    ← 需要提供 runtime callbacks
  ↓
ghostty_surface_new(app, &surface_cfg)   ← 创建终端 surface（自动启动 PTY + shell）
```

### 5. Runtime Callbacks (Swift → C function pointers)

```swift
var runtime = ghostty_runtime_config_s()
runtime.wakeup_cb = { userdata in ... }           // 通知主线程更新
runtime.action_cb = { userdata, action in ... }    // 处理终端动作
runtime.read_clipboard_cb = { userdata, ... }      // 读剪贴板
runtime.write_clipboard_cb = { userdata, ... }     // 写剪贴板
runtime.close_surface_cb = { userdata in ... }     // 关闭请求
```

### 6. 渲染

- libghostty 内部使用 Metal 渲染，直接绘制到 CAMetalLayer
- Swift 端只需提供 NSView + CAMetalLayer
- 不需要 app-level display link — 依赖 Ghostty renderer 自己的 wakeup
- `ghostty_surface_draw()` 触发渲染
- `ghostty_surface_set_size(surface, width, height)` 处理 resize

### 7. 输入

键盘事件通过 `ghostty_surface_key(surface, &event)` 传递，但要按 cmux / Ghostty AppKit 的输入链路处理，避免 IME 乱码：
- `keyDown` 不直接把 `event.characters` 写入 PTY，而是先 `interpretKeyEvents`
- `insertText` 在 `keyDown` 期间只做累积；有累积文本时直接走 `ghostty_surface_text` 写入 PTY，避免 modifier 状态污染文本输入
- `setMarkedText / unmarkText` 同步 `ghostty_surface_preedit`，并维护 `hasMarkedText`
- `flagsChanged` 在 preedit 阶段跳过，避免组合输入被 modifier 中断
- `ghostty_input_key_s.consumed_mods` 需要基于 translation mods 计算，避免 Option/布局翻译错误

openOwl 当前实现已按以上流程修复（参考 `openOwl/Ghostty/GhosttyTerminal.swift` 与 `openOwl/Ghostty/GhosttyInput.swift`）。

**ESC fallback 路由**

Right Dock 切换或 SwiftUI 重建后，first responder 可能暂时落在 `NSHostingView` 或普通容器视图，而不是可见的 `TerminalNSView`。此时 AppDelegate 的 local monitor 可以把 ESC 转发到当前 workspace 的 focused pane，但必须遵循 responder 分类：

- 当前可见 Terminal 已是 first responder 时，local monitor 直接调用 Terminal 的 ESC key-equivalent 入口，避免事件随后被 `NavigationSplitView` 抢先消费
- 当前可见且仍挂在 key window 上的 `NSTextField`、field editor / `NSTextView`、`NSOutlineView` / `NSTableView` / `NSCollectionView` 后代属于真实输入区域，阻止 terminal fallback
- 普通命令按钮、`NSHostingView`、非交互容器后代、window、空 first responder，以及已经隐藏或从 key window 拆卸的旧 responder 允许 terminal fallback
- 转发前仍需确认目标 pane 可见且可接受终端键盘输入，避免隐藏或 stale terminal 收到按键

该策略由 `TerminalFallbackResponderPolicy` 集中实现，并由 `TerminalKeyboardRoutingTests` 覆盖。
ESC/Ctrl+C 的 fallback 结果以及 terminal 原生 ESC 路径会写入 `openowl.log` 的 `keyboard-routing` 标签，便于定位间歇性焦点漂移。

**Kitty keyboard 协议状态恢复**

TUI 可通过 Kitty keyboard protocol 启用增强按键编码。若前台程序异常退出而没有 pop 模式，遗留的 flag stack 会让 shell 后续按键显示为 `9;1:3u` 一类 CSI-u 文本。

Ghostty shell integration 收到明确的 `prompt_start` 时，会重置当前 active screen 的整个 Kitty keyboard flag stack。该边界表示 shell 已重新开始绘制 prompt；清理不发生在 `end_command`、focus 切换或 pane reattach 时，避免仍在输出或仍活跃的 TUI 被提前关闭增强键盘模式。此操作不会清屏、清除 scrollback 或重启 shell。

### 8. 剪贴板 (Copy/Paste)

终端的复制粘贴需要处理 macOS 事件路由和 ghostty 内部状态的交互：

**事件路由**

macOS 有两条路径将 Cmd+C/V 送到终端视图：

1. **`performKeyEquivalent`** — NSView hierarchy 深度优先遍历，所有子视图都会被调到
2. **Edit 菜单** — key equivalent 匹配后通过 responder chain 发送 `copy:` / `paste:` action

关键注意点：
- `performKeyEquivalent` 遍历所有 NSView，包括 `opacity(0)` 的隐藏视图。多个 TerminalNSView（分屏/多 tab）都会被调到，必须用 `activeSurface` + `isEffectivelyVisible` 过滤
- 非终端 tab（如 Deployment 的 TextField）时，终端视图必须 return false 放行事件
- 不能在 `performKeyEquivalent` 中调 `makeFirstResponder` — 会触发 `onFocus` → `@Published` 状态变更 → SwiftUI 重建视图
- Right Dock / SwiftUI 状态切换可能临时清空 firstResponder。ESC 与 Ctrl+C 在没有文本输入控件占焦点、且当前 firstResponder 为空或是 stale TerminalNSView 时，由 AppDelegate local monitor 转发给 workspace 当前 focused pane；若 TextField/TextView/OutlineView 占焦点则必须放行

**粘贴实现**

使用 `ghostty_surface_text(surface, ptr, len)` 直接向 PTY 注入文本。不能使用 `ghostty_surface_binding_action("paste_from_clipboard")` 因为它触发 `read_clipboard_cb`，其 async 延迟会导致 `state` 指针 use-after-free。

```swift
// 粘贴：直接读剪贴板 → ghostty_surface_text
ghostty_surface_set_focus(surface, true)
let value = NSPasteboard.general.string(forType: .string) ?? ""
value.withCString { ptr in
    ghostty_surface_text(surface, ptr, UInt(value.utf8.count))
}
```

**复制实现**

使用 `ghostty_surface_binding_action(surface, "copy_to_clipboard", len)` 触发 ghostty 内部复制流程，ghostty 通过 `write_clipboard_cb` 回调将选中文本写入 NSPasteboard。

```swift
// 复制：ghostty binding → write_clipboard_cb → NSPasteboard
let action = "copy_to_clipboard"
ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
```

注意：第三个参数是 action 字符串的**字节长度**，不是 0。

**Runtime Callbacks**

```swift
// 读剪贴板（ghostty 请求粘贴时调用）
runtime.read_clipboard_cb = { userdata, clipboard, state in
    // 异步完成以避免 ghostty_surface_key 重入
    // 但必须在 async 块内重新验证 surface（可能已被释放）
    DispatchQueue.main.async {
        guard let surface = manager.activeSurface else { return }
        // ... ghostty_surface_complete_clipboard_request(surface, ptr, state, false)
    }
    return true
}

// 写剪贴板（ghostty 执行复制时调用）
runtime.write_clipboard_cb = { _, clipboard, content, count, _ in
    // 查找 text/plain MIME → NSPasteboard.general.setString
}
```

### 9. 配置

读取 `~/.config/ghostty/config`（用户已有的 Ghostty 配置），支持：
- font-family, font-size
- theme, palette (16 色)
- background-opacity
- scrollback-limit
- cursor-style, cursor-color

## cmux 架构学习要点

### 项目结构
```
Sources/
  cmuxApp.swift                 # @main SwiftUI App 入口
  AppDelegate.swift             # AppKit delegate, 键盘路由, 分屏处理
  ContentView.swift             # 主窗口 (sidebar + workspace)
  TabManager.swift              # 中央状态管理 (ObservableObject)
  Workspace.swift               # 单个工作区 (panels + 分屏布局)
  GhosttyTerminalView.swift     # NSViewRepresentable 包装 ghostty surface
  GhosttyConfig.swift           # 读取 ghostty 配置
  Panels/
    Panel.swift                 # Panel 协议 (所有面板类型的抽象)
    TerminalPanel.swift         # 终端面板
    BrowserPanel.swift          # 浏览器面板 (WKWebView)
vendor/
  bonsplit/                     # 自定义分屏布局库
ghostty/                        # Ghostty 子模块
scripts/
  setup.sh                     # 构建自动化
```

### 关键设计模式

1. **SwiftUI + AppKit 混合架构**
   - SwiftUI 做声明式布局 (@main App, ContentView)
   - AppKit 做终端托管、键盘路由、窗口管理 (NSViewRepresentable)
   - 终端视图必须用 AppKit — 需要低级别 NSView 控制

2. **Panel 协议抽象**
   - 所有内容面板 (终端/浏览器/Markdown) 统一实现 Panel 协议
   - 属性: id, panelType, displayTitle
   - 方法: focus(), close()
   - 允许混合不同类型面板在同一分屏布局中

3. **Workspace 模型**
   - 每个 Workspace 包含 panels + bonsplit 布局 + git 状态 + 端口信息
   - TabManager (ObservableObject) 管理所有 workspace
   - ContentView 用 ZStack + visibility 保持所有 workspace 存活（类似 Electron 版的 display:none/block）

4. **Git 集成（浅层）**
   - 只显示 branch name + dirty 状态在侧边栏
   - 不执行 git 操作（commit/diff/merge 等）
   - Git 状态通过 shell 获取，存为 SidebarGitBranchState

5. **Session 持久化**
   - 退出时保存窗口/workspace/pane 布局和 cwd
   - 重启恢复布局但不恢复进程状态

6. **CLI/Socket API**
   - Unix socket 服务器，支持外部控制
   - 可通过 CLI 创建 workspace、发送按键、查询状态

## 关键文件参考

| cmux 文件 | 作用 | openOwl 对标 |
|-----------|------|-------------|
| `GhosttyTerminalView.swift` | NSViewRepresentable 终端 | Ghostty/GhosttyTerminal.swift |
| `GhosttyConfig.swift` | 读 ghostty 配置 | Ghostty/GhosttyConfig.swift |
| `TabManager.swift` | 中央状态 | 待定 (可能用 SwiftUI @Observable) |
| `Workspace.swift` | 工作区模型 | Features/Sidebar/ProjectStore |
| `ContentView.swift` | 主布局 | App/ContentView.swift |
| `Panel.swift` | 面板协议 | 可借鉴做 Terminal/Git/Files 面板 |
| `vendor/bonsplit/` | 自定义分屏 | 可直接用或参考实现 |
| `scripts/setup.sh` | 构建自动化 | scripts/setup.sh |

## 注意事项

- libghostty 的 C API 目前不是公开稳定 API，可能随 Ghostty 版本变化
- 需要 Zig 编译器来构建（不需要 Zig 开发经验，只是构建工具）
- cmux 使用 Ghostty fork (manaflow-ai/ghostty)，可能需要我们也 fork 一份
- 性能敏感路径不要加额外 allocation（cmux 特别强调 typing latency）
- Kitty keyboard 状态只能在 shell integration 的明确 `prompt_start` 边界恢复；不要在 focus、隐藏/显示或 reattach 生命周期中重置
