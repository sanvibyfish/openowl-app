# openOwl 发布记录

> 状态说明：🟢 Ready 表示发布说明已完成、等待最终构建与发布；✅ Done 表示对应 Git tag 与 GitHub Release 已发布；⤴️ Merged 表示该版本未单独发布，内容并入后续版本。

---

## 文档列表

| 版本 | 状态 | 发布日期 | 文档 |
|------|------|----------|------|
| v1.1.6 | ✅ Done | 2026-08-24 | [Release Notes](v1.1.6.md) |
| v1.1.5 | ⤴️ Merged | — | [Release Notes](v1.1.5.md)（未单独发布，并入 v1.1.6） |
| v1.1.4-2 | ✅ Done | 2026-08-09 | [Release Notes](v1.1.4-2.md) |
| v1.1.4 | ✅ Done | 2026-08-05 | [Release Notes](v1.1.4.md)（含 v1.1.4-1 patch tag，2026-08-08） |
| v1.1.3 | ✅ Done | 2026-08-03 | [Release Notes](v1.1.3.md) |
| v1.1.2 | ✅ Done | 2026-08-01 | [Release Notes](v1.1.2.md) |
| v1.1.1 | ✅ Done | 2026-07-30 | [Release Notes](v1.1.1.md) |
| v1.1.0 | ✅ Done | 2026-06-16 | [Release Notes](v1.1.0.md) |
| v1.0.9 | ✅ Done | 2026-05-30 | [Release Notes](v1.0.9.md) |
| v1.0.8 | ✅ Done | 2026-05-10 | [Release Notes](v1.0.8.md) |
| v1.0.7 | ✅ Done | 2026-05-03 | [Release Notes](v1.0.7.md) |
| v1.0.6 | ✅ Done | 2026-04-24 | [Release Notes](v1.0.6.md) |
| v1.0.5 | ✅ Done | 2026-03-23 | [Release Notes](v1.0.5.md) |
| v1.0.3 | ✅ Done | 2026-03-19 | [Release Notes](v1.0.3.md) |
| v1.0.2 | ✅ Done | 2026-03-18 | [Release Notes](v1.0.2.md) |
| v1.0.1 | ✅ Done | 2026-03-18 | [Release Notes](v1.0.1.md) |

## 分类

- **1.1.x**：工作区 UI、编辑器与终端稳定性
- **1.0.x**：基础终端、Git 与文件管理能力

## 依赖关系

- Release Notes 对应同版本 Git tag、DMG 与 GitHub Release。
- 功能行为以 `docs/features/` 中相应文档为准。

## 更新记录

| 日期 | 说明 |
|------|------|
| 2026-08-24 | 发布 v1.1.6：并入原定 v1.1.5 的 Right Dock 与 Terminal AppleScript 内容，新增终端 surface 重挂载重试与侧边栏 header 对齐修复；v1.1.5 标记为 ⤴️ Merged，从未单独发布 |
| 2026-08-21 | v1.1.6 发布说明就绪：git 子进程管道层加固（读错误不再被吞、等待有界、超时改用 SIGTERM）、Discard All 契约修正为真正的全部丢弃、⌘Q 编辑内容丢失修复；移除三处兜底与 `AppExitMonitor`。同时更正了先前「v1.1.6 已于 2026-08-17 发布」的错误记录——该版本从未发布，且原发布说明的头号功能从未实现 |
| 2026-08-10 | v1.1.5 发布说明就绪：新增 Terminal AppleScript 自动化，修复 Right Dock 文件即时 reload、Git diff/Graph 状态隔离、Git 边界场景与 File Explorer 文件操作生命周期；DMG 签名、公证、staple 与 Gatekeeper 验证完成，等待 tag、上传与发布 |
| 2026-08-09 | 发布 v1.1.4-2：pane 与 Finder 拖放统一迁到 AppKit，修复嵌套分屏命中、终端输入阻塞和隐藏 pane 抢拖放事件 |
| 2026-08-08 | v1.1.4 发布说明定稿并补登索引；新增 v1.1.4-1 patch tag（AppKit `PaneHandleNSView` + `[terminal-drop]` 日志） |
| 2026-08-01 | v1.1.2 统一选中态、unified diff、终端 tab 记忆、bell 移除、Debug bundle ID 分离 |
| 2026-07-31 | v1.1.1 补充稳定性修复、365 tests / 33 suites 验证结果及当前 GUI 未验证范围 |
| 2026-07-30 | 建立发布文档索引并登记 v1.1.1 |
