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
    └── AppLogger.swift     # 文件日志工具
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
2026-05-30 22:30:15.125 [resize-diag] setFrameSize pane=A1B2C3D4 pts=800.0x600.0 cols=120 rows=40
```

每行包含：时间戳（毫秒精度）+ `[tag]` + 消息内容。

## 4. 注意事项

- 日志目录在首次写入时自动创建，无需手动创建
- `FileHandle` 在 app 生命周期内保持打开，避免频繁 open/close
- 当前仅 `[resize-diag]` 相关日志使用 `AppLogger`，其他模块的 `NSLog` 可按需逐步迁移

## 5. 相关需求

无独立需求文档。此功能是终端 resize 问题诊断的基础设施。

## 6. 更新记录

| 日期 | 说明 |
|------|------|
| 2026-05-30 | 初始实现，覆盖 resize-diag 日志 |
