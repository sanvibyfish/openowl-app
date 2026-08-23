# FEAT-009: 文件日志系统 (AppLogger)

> 状态：✅ Done | 创建日期：2026-05-30 | 完成日期：2026-05-30

---

## 1. 功能概述

统一的文件日志工具，将应用运行日志写入 `~/Library/Logs/openOwl/openowl.log`。打包分发后用户和开发者可直接读取日志文件，无需连接 Xcode 或 Console.app。

## 2. 用户流程

1. 应用运行过程中，诊断日志自动写入 `~/Library/Logs/openOwl/openowl.log`
2. 用户遇到问题时，在 Finder 中 `⌘⇧G` 前往 `~/Library/Logs/openOwl/` 即可找到日志文件
3. 日志文件超过 10 MB 自动轮转为 `openowl.1.log`，最多保留 1 个旧文件

## 3. 技术实现

### 3.1 模块位置

```
openOwl/
└── Shared/
    └── AppLogger.swift             # 文件日志工具
```

### 3.2 API

```swift
// 简单字符串
AppLogger.log("resize-diag", "dock expanded")

// 格式化参数（CVarArg）
AppLogger.log("resize-diag", "frame=%.1fx%.1f", width, height)
```

### 3.3 设计决策

| 决策 | 选择 | 原因 |
|------|------|------|
| 日志位置 | `~/Library/Logs/openOwl/` | macOS 标准日志目录，Console.app 和 Finder 均可访问 |
| 线程安全 | `DispatchQueue(label:, qos: .utility)` 串行队列 | 防止多线程写入交错，`.utility` QoS 不阻塞主线程 |
| 双写策略 | 同时调用 `NSLog` + 写文件 | 开发时 Xcode 控制台可见，打包后文件也有 |
| 文件轮转 | 10 MB 上限，保留 1 个旧文件 | 防止日志无限增长占用磁盘 |
| 类型 | `enum`（不可实例化） | 纯静态工具，无需实例化 |

### 3.4 日志格式

```
2026-05-30 22:30:15.123 [resize-diag] ScrollView.layout pane=A1B2C3D4 bounds=800.0x600.0
2026-06-04 14:12:22.125 [resize-diag] syncSurfaceSize pane=A1B2C3D4 reason=scroll-layout pts=800.0x600.0 px=1600x1200 cols=120 rows=40 window=set
2026-06-05 18:40:10.012 [file-editor-state] restore project=/repo reason=appear saved=3 restored=3 active=/repo/App.swift
```

每行包含：时间戳（毫秒精度）+ `[tag]` + 消息内容。

> **注意**：`[resize-diag]` 与 `[keyboard-routing]` 两个高噪声 tag **默认关闭**，需显式开启后才会落盘：
>
> ```bash
> defaults write com.openowl.app.dev log.resizeDiag -bool YES
> defaults write com.openowl.app.dev log.keyboardRouting -bool YES
> ```
>
> `.dev` 后缀不能省：Debug 构建的 bundle ID 是 `com.openowl.app.dev`，有独立的 UserDefaults domain；Release 构建读 `com.openowl.app`。上面示例中的 `[resize-diag]` 行只有在开启后才会出现。

## 4. 注意事项

- 日志目录在首次写入时自动创建，无需手动创建
- `FileHandle` 在 app 生命周期内保持打开，避免频繁 open/close
- 当前 `[resize-diag]` 与 `[file-editor-state]` 相关日志使用 `AppLogger`，其他模块的 `NSLog` 可按需逐步迁移
- `TerminalScrollView.layout` 只记录尺寸发生变化的 layout；无尺寸变化的 terminal layout 不落盘，避免 terminal 输出热路径被诊断日志拖慢
- `syncSurfaceSize skipped ... hostVisible=false/tiny ...` 表示 pane 当前隐藏或尺寸未稳定，openOwl 会保留上一次可用 PTY 尺寸，恢复显示后再同步
- `[file-editor-state] restore-skip ...` 表示 editor tab session 恢复时跳过不存在文件、目录或超过图片解码上限的图片
- `[pane-drag]` 记录窗格拖拽重排全链路：`drag started` → `dropEntered` / `zone changed` / `dropExited` → `performDrop` 或 `drag cancelled`。非 opt-in（拖拽是低频操作），落盘后可脱离 Xcode 排查拖拽状态残留
- `[git]` 记录 git 二进制选择、子进程失败、命令超时终止，以及**成功但 stderr 非空**的调用（git 常以 exit 0 + stderr 警告表达部分失败）。按 [REQ-002](../requirements/REQ-002-git-changes.md) 属关键路径日志，非 opt-in
- `[worktree]` 记录 worktree 移除失败、清理 `.DS_Store` 后的重试，以及残留孤儿目录及其原因
- `[terminal-drop]` 记录 Finder/文件拖进终端链路的每次判定：`entered`（含 pasteboard types 与返回的 op）、`reject: not effectively visible`、`reject: no accepted type`、`perform`（含 ok 结果）。此前 `TerminalScrollView` 拖放方法完全无日志、`TerminalNSView` 走裸 `NSLog`（Release 不持久化），拖图片失败查无痕迹

## 5. 相关需求

无独立需求文档。此功能是终端 resize 问题诊断的基础设施。

## 6. 更新记录

| 日期 | 说明 |
|------|------|
| 2026-08-21 | 移除 `AppExitMonitor` 与 `AppExitSignalHandler.c`（含 exit.log）。它用 `signal()` 而非 `sigaction()`：不保存原 handler，因此会被随后安装的 libghostty(Zig) panic handler 覆盖；没有 `SA_ONSTACK`/`sigaltstack`，栈溢出型 SIGSEGV 根本进不了 handler；安装部分失败只写 NSLog 而 `install()` 返回 Void，调用方无从得知。即最需要它时最可能是空的。它服务的 2026-08-11 exit(1) 排查为一次性诊断，不对应任何用户需求，却常驻改写了进程的 SIGTERM/SIGABRT 语义 |
| 2026-08-14 | 致命信号路径移入纯 C：Swift 正常上下文预打开 `exit.log` fd，handler 仅以有界 partial-write / `EINTR` 循环写固定消息，不再错误地于信号上下文调用 `backtrace_symbols_fd`。正常 `atexit` 仍保留 Foundation 时间戳与回溯；两类 handler 独立安装，信号安装部分失败会回滚 |
| 2026-08-08 | 新增 `[terminal-drop]` 拖放链路日志：`TerminalScrollView` 与 `TerminalNSView` 的 `draggingEntered` / `draggingUpdated` / `prepareForDragOperation` / `performDragOperation` 从裸 `NSLog` 或无日志迁移到 `AppLogger`，Release 也落盘。排查拖图片"放不进来"时第一次有据可查 |
| 2026-08-06 | `emit()` 的 `dateFormatter.string(from:)` 从调用者线程移入 serial queue：`DateFormatter` 非线程安全，并发调用会产生非法 UTF-8，`data(using: .utf8)` 返回 nil 导致整行日志被静默吞掉；还会丢失 `\n`，后续行直接拼在前一行末尾 |
| 2026-08-04 | 窗格拖拽埋点从裸 `NSLog` 迁到 `AppLogger`（tag `pane-drag`）。之前拖拽日志只进系统日志不落盘，导致排查拖拽 bug 时日志文件里查无此事 |
| 2026-06-25 | `resize-diag` layout 日志降噪，只记录尺寸变化，避免终端输出热路径重复写日志 |
| 2026-06-05 | 新增 file-editor-state 示例与恢复跳过语义 |
| 2026-06-04 | resize-diag 示例更新为 `syncSurfaceSize`，补充隐藏 pane 尺寸跳过语义 |
| 2026-05-30 | 初始实现，覆盖 resize-diag 日志 |
