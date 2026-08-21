# REQ-001: libghostty 终端集成

> 状态：✅ Done | 优先级：P0 | 创建日期：2026-03-14

## 概述

使用 libghostty 实现原生 Metal GPU 渲染终端，并提供多标签与分屏基础交互。

## 核心需求

### P0 — 基础终端

- [x] libghostty 集成：通过 C bridging header 导入，初始化 `ghostty_app_t`
- [x] 终端视图：AppKit NSView + CAMetalLayer，通过 NSViewRepresentable 桥接到 SwiftUI
- [x] PTY 管理：libghostty 内置，自动检测用户 shell (zsh/bash/fish)
- [x] 输入处理：键盘事件转换为 `ghostty_input_key_s`，鼠标事件处理
- [x] 终端配置：字体、字号、主题颜色由 libghostty 配置驱动
- [x] 读取 `~/.config/ghostty/config` 用户已有配置（含 recursive include）
- [x] `ghostty_surface_new()` 失败时必须在原 pane 显示可访问的失败提示（`Terminal failed to start.` + 指向 `~/Library/Logs/openOwl/openowl.log`——失败详情只在日志里）；pane 不得自动移除，view 重新挂载不得重试创建 surface 或重复叠加错误 UI。AppleScript 对该 pane 的输入必须返回终态错误而非 `notReady`，否则脚本会陷入永不成功的重试循环

### P0 — 多标签 + 分屏

- [x] 多标签页：Cmd+T 新建，Cmd+W 关闭，Cmd+1-9 切换
- [x] 分屏：Cmd+D 左右分屏，Cmd+Shift+D 上下分屏
- [x] 焦点切换：Cmd+Arrow 在分屏间移动焦点（边界无目标时 no-op）
- [x] 关闭优先级：`Cmd+W` = 关闭当前分屏 > 关闭当前标签 > 项目：清空并转为非激活 / free terminal：关闭窗口

### P1 — 增强

- [x] 终端标题追踪（OSC 0/2）
- [x] 拖拽文件到终端粘贴路径（shell-safe 路径转义）
- [x] URL 检测 + Cmd+Click 打开链接（路由规则见下方「已落地的关键规则」）
- [ ] 运行时 scrollback 调参 UI（底层配置已可生效）

## 已落地的关键规则

- shell 启动策略：
  - 优先使用用户 config 中的 `command`
  - 若未设置 `command`，fallback 检测顺序为：`$SHELL` 可执行 > `getpwuid` 登录 shell > `/bin/zsh`
- 主题/字体/scrollback：
  - 统一由 libghostty 读取 config 生效
  - Swift 侧记录 `command/font-family/font-size/theme/scrollback-limit` 快照用于诊断
- 标签与分屏：
  - 本阶段采用应用内 Tab Bar（非 macOS 原生 tab group）
  - 分屏支持多级嵌套，新分屏初始为 50/50；分隔线可拖拽调整比例，比例钳制在 0.1–0.9
- Cmd+Click URL 路由（产品决策）：
  - `http://` / `https://` 不截获，交由 ghostty 默认行为用系统浏览器打开
  - `file://`、绝对路径、以及相对于**当前焦点 pane cwd** 解析的相对路径：解析后确实是一个**存在的文件**时才截获，在 Right Dock 文件浏览器中打开；解析为目录或路径不存在时不截获，交回 ghostty 默认处理
  - 截获成功时向 ghostty 返回 `true`，避免它再触发一次 `NSWorkspace.open`
- 文件拖拽到终端：
  - 支持从 Finder/文件树拖拽文件或目录到 Terminal
  - 终端收到的是 shell-safe 转义路径，多个路径以空格拼接并自动补尾随空格
- 标题追踪：
  - 监听 libghostty `SetTitle/SetTabTitle` action 回调
  - 按目标 surface 映射到 pane，再更新应用内 tab 标题
- 退出保护：
  - `Cmd+Q` / App 菜单 Quit / 托盘 Quit 触发 app 退出前，先调用 `ghostty_app_needs_confirm_quit`
  - 若 libghostty 判断有仍在运行的终端任务，必须弹确认框；取消后 app 和终端任务继续运行
  - 用户确认 Quit 后才允许 app 退出，终端任务随 app 生命周期结束

## 技术要点

### libghostty 集成方式 (参考 cmux)

1. Ghostty 作为 git submodule 引入
2. 用 Zig 编译出 libghostty 静态库
3. 通过 bridging header 导入 `ghostty.h`
4. Swift 调用 C API：
   - `ghostty_init()` → 全局初始化
   - `ghostty_config_new()` → 创建配置
   - `ghostty_app_new()` → 创建 app 实例（需提供 runtime callbacks）
   - `ghostty_surface_new()` → 创建终端 surface（自动创建 PTY）
   - `ghostty_surface_key()` → 发送键盘事件
   - `ghostty_surface_set_size()` → 调整大小

### Runtime Callbacks

Swift 需要实现以下回调供 libghostty 调用：
- `wakeup_cb` — 通知主线程有更新
- `action_cb` — 处理终端动作（标题变更、铃声等）
- `read_clipboard_cb` / `write_clipboard_cb` — 剪贴板交互
- `close_surface_cb` — 终端关闭请求

### 渲染流程

1. libghostty 维护终端状态（网格、样式、scrollback）
2. Metal 渲染由 libghostty 内部完成，直接绘制到 CAMetalLayer
3. Swift 端通过 `wakeup_cb -> ghostty_app_tick` 驱动事件循环
4. 大小变更通过 `ghostty_surface_set_size()` 传递像素尺寸和 content scale

## 参考实现

- Ghostty macOS app: `macos/Sources/Ghostty/` 和 `macos/Sources/Features/Terminal/`
- cmux: `github.com/manaflow-ai/cmux` — 第三方 libghostty 集成参考

## 更新记录

| 日期 | 说明 |
|------|------|
| 2026-08-14 | 增加 terminal surface 创建失败验收：原 pane 内显示可访问错误卡片，保留 pane，并阻止重挂载重试与重复 UI |
