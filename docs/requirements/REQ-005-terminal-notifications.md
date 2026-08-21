# REQ-005: 终端 Pane 通知系统

> 状态：⏸️ On Hold | 优先级：P2 | 预估工时：1周 | 创建日期：2026-03-17

---

## 1. 需求概述

在 Sidebar 的分支/worktree 行下方展示各 Terminal pane 的运行状态，当 pane 内任务完成（bell 信号）时提供视觉通知，让用户无需切回 Terminal tab 也能感知哪个分屏需要关注。

## 2. 背景与动机

openOwl 支持多项目 + 分屏终端。典型场景：4 个分屏分别跑构建、测试、部署、AI agent。用户切到 Git 或 File Explorer tab 后无法知道哪个任务完成了。

参考：cmux 的 TerminalNotificationStore 实现了 per-pane 通知 + 系统通知 + Dock badge。openOwl 采用更轻量的方案 —— 将通知直接集成到 Sidebar。

## 3. 用户故事

- 作为开发者，我在 main 分支开了 3 个分屏分别跑 build / test / claude code，然后切到 Git tab 看 diff。当 build 完成时，我希望在 Sidebar 的 main 分支下看到对应 pane 的状态变化，知道该回去看结果了。
- 作为开发者，我同时在 main 和 feature/auth 两个项目工作。我想一眼看到哪个项目的终端需要关注。

## 4. 功能描述

### 4.1 核心功能

**Sidebar 分支行扩展**：将单行分支显示扩展为可展示 pane 子行的结构。

当前：
```
▼ 📁 openowl-app
    🔀 main
    🔀 feature/auth
```

扩展后：
```
▼ 📁 openowl-app
    ▼ 🔀 main
        ● zsh: ~/src              🔄
        ● xcodebuild              ✅ 0:32
        ● npm test                ✅ 0:15
        ● claude code             ⚠️
    ▶ 🔀 feature/auth            ● 2
        (收起时右侧显示未读通知数)
```

每个 pane 子行显示：
- 终端标题（shell 通过 OSC 序列设置的 title，已有 `onPaneTitleChanged` 支持）
- 状态指示器：
  - 🔄 运行中（默认状态，无 bell）
  - ✅ 完成（收到 bell 信号）
  - ⚠️ 需要输入（可选：区分 bell 类型或来源）

### 4.2 信号源

**Terminal Bell（`\a` / BEL）**：
- Ghostty 的 `GHOSTTY_ACTION_RING_BELL` 回调
- 触发场景：命令完成（shell prompt bell）、CI 失败、AI agent 等待输入
- 在 `GhosttyAppManager.handleAction()` 中新增 `GHOSTTY_ACTION_RING_BELL` case，通过 surface → paneID 映射推送通知

### 4.3 数据流

```
GHOSTTY_ACTION_RING_BELL
  → GhosttyAppManager.handleAction()
  → 通过 paneSurfaceMap 查找 paneID
  → 调用 onPaneBell?(paneID)
  → TerminalWorkspaceStore 记录通知
  → Sidebar 的 BranchRow/WorktreeRow 读取并显示
```

### 4.4 通知生命周期

| 事件 | 状态变化 |
|------|---------|
| Pane 创建 | 状态 = running（默认） |
| 收到 bell | 状态 = bell，记录时间 |
| 用户点击 pane 子行 | 跳转到该 pane + 清除 bell 状态 |
| 用户聚焦该 pane | 自动清除 bell 状态 |
| Pane 关闭 | 移除通知记录 |

### 4.5 Sidebar 交互

- **点击 pane 子行**：切到 Terminal tab + 聚焦对应 pane
- **分支收起时**：右侧显示未读通知数 badge（如 `● 2`）
- **分支展开时**：显示每个 pane 的详细状态

### 4.6 边界情况

- 单 pane 项目：仍显示一个 pane 子行（保持一致性），或内联到分支行
- Bell 防抖：短时间内多次 bell 只记一次（100ms 内合并）
- 分支无 pane：不显示子行（项目刚添加，还没打开 Terminal）

## 5. 技术方案

### 5.1 数据模型

```swift
// 新增到 TerminalWorkspaceStore 或独立 Store
struct PaneNotification {
    let paneID: UUID
    var bellCount: Int = 0
    var lastBellTime: Date?
    var isRead: Bool = true
}
```

### 5.2 GhosttyAppManager 改动

```swift
// handleAction() 新增:
case GHOSTTY_ACTION_RING_BELL:
    guard let paneID = paneID(for: target) else { return false }
    DispatchQueue.main.async { [weak self] in
        self?.onPaneBell?(paneID)
    }
    return true
```

新增回调：
```swift
var onPaneBell: ((UUID) -> Void)?
```

### 5.3 TerminalWorkspaceStore 改动

新增 pane 通知状态管理：
```swift
@Published private(set) var paneNotifications: [UUID: PaneNotification] = [:]

func handleBell(paneID: UUID) {
    // 防抖 + 聚焦抑制
    if isFocusedPane(paneID, in: activeTabID) { return }
    paneNotifications[paneID, default: PaneNotification(paneID: paneID)].markBell()
}

func clearNotification(paneID: UUID) {
    paneNotifications[paneID]?.isRead = true
}

// pane 关闭时清理
// 聚焦 pane 时自动清除
```

### 5.4 SidebarView 改动

扩展 `BranchRow` 和 `WorktreeRow`：
- 从 TerminalWorkspaceStore 读取该项目下所有 pane 的标题和通知状态
- 需要 projectID → tabIDs → paneIDs 的映射链
- 展开/收起交互（DisclosureGroup 或自定义）

### 5.5 查询路径

```
projectID
  → TerminalWorkspaceStore.tabProjectMap 找到所有 tabID
  → 每个 tab 的 splitTree.allPaneIDs 找到所有 paneID
  → paneNotifications[paneID] 获取状态
  → GhosttyAppManager.onPaneTitleChanged 获取标题
```

## 6. 验收标准

- [ ] Sidebar 分支行可展开显示该项目下所有 terminal pane
- [ ] 每个 pane 显示终端标题和运行状态
- [ ] Terminal bell 触发后，对应 pane 子行显示 ✅ 状态
- [ ] 点击 pane 子行跳转到对应终端分屏
- [ ] 聚焦 pane 时自动清除通知状态
- [ ] 分支收起时显示未读通知数
- [ ] 编译通过，现有测试不受影响

## 7. 优先级与排期

- P2：提升多分屏工作流效率
- 依赖：无新外部依赖
- 前置：无（现有 Ghostty 回调机制 + Sidebar 结构足够）

## 8. 相关文档

- REQ-001: 终端需求
- cmux TerminalNotificationStore（参考实现）

## 9. 更新记录

| 日期 | 变更 |
|------|------|
| 2026-03-17 | 初稿 |
