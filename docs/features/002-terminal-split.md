# FEAT-002: 终端分屏系统

> 状态：✅ Done | 创建日期：2025-12-01 | 完成日期：2026-03-10

---

## 1. 功能概述

多标签 + 二叉树分屏终端系统。每个标签页包含一棵 `TerminalSplitNode` 树，支持水平/垂直分屏、拖拽调整比例、四方向焦点导航、窗格拖拽重排。

## 2. 用户流程

1. **新建标签**: Cmd+T 创建新终端标签，**仅在 free terminal 下可用**（项目 namespace 不绘制 tab bar，标签没有可见入口，故菜单项置灰）
2. **分屏**: Cmd+D 水平分屏 / Cmd+Shift+D 垂直分屏
3. **切换焦点**: Cmd+Option+方向键 在窗格间导航
4. **调整大小**: 拖拽分割线，双击分割线均分所有窗格
5. **关闭窗格**: Cmd+W 关闭当前窗格（最后一个窗格时关闭标签）
6. **交换窗格**: 拖拽窗格到另一个窗格的边缘区域（左/右/上/下/中心）

## 3. 技术实现

### 3.1 数据结构

```swift
indirect enum TerminalSplitNode: Equatable {
    case leaf(UUID)                    // 单个终端窗格
    case split(axis, ratio, first, second) // 二叉分割
}
```

- `ratio` 范围 0.1–0.9（clamped），避免窗格被压缩到不可见
- `TerminalTabState` 持有 `splitTree` + `focusedPaneID`
- `TerminalWorkspaceStore` 管理所有标签 + 项目映射

### 3.2 渲染方式

采用 **flat 布局** 而非嵌套 View：`paneFrames(in:)` 递归计算每个 leaf 的绝对 CGRect，所有窗格用 `.frame()` + `.position()` 平铺在 GeometryReader 中。

优势：避免 SwiftUI 在树结构变更时销毁重建 NSView（会导致终端状态丢失）。

### 3.3 焦点导航

`nextPaneID(from:currentPaneID:frames:direction:)` 算法：
1. 过滤方向上的候选窗格（如 `.left` 只找 maxX ≤ 当前 minX 的窗格）
2. 多因子排序：距离 → 重叠度 → 横向偏移
3. 选择最优候选

### 3.4 窗格位置

每个 pane UUID 对应一个 `ghostty_surface_t`（由 GhosttyAppManager 管理）。

## 4. 注意事项

- 分割线宽度 1px，热区 8px（方便拖拽）
- 多窗格仅轻微弱化非 focused pane，不绘制焦点边框，避免分隔边缘出现突兀的 accent 高亮
- `TerminalNSView` 的焦点回调只同步 `focusedPaneID`；侧栏点击 pane 时先切换到所属 main/worktree namespace，再选中对应分屏并单次请求 first responder，避免跨 worktree 显示空白或焦点请求自循环造成终端闪屏
- Free Terminal 标签采用 28pt 平面连续 tab bar，active tab 通过背景层级与终端内容连接
- 关闭窗格后焦点转移到最近的邻居（Euclidean 距离）
- 标签按项目隔离：切换项目只显示该项目的标签

## 5. 相关需求

- [REQ-001: 终端](../requirements/REQ-001-terminal.md)

## 6. 更新记录

| 日期 | 说明 |
|------|------|
| 2026-08-01 | `closeCurrent()` 不再跨 namespace 兜底到 `tabs.last`：关掉某 namespace 最后一个 tab 会把活动槽交给另一个 namespace 的 tab，`activeTabID.didSet` 随即把那个 namespace 的记忆改写成用户从未打开过的 tab。现改为就地新建 tab，与 `switchNamespace` 对空 namespace 的处理一致 |
| 2026-08-01 | 移除 bell 生产端残留：`GhosttyConfig` 不再请求 `notify-on-command-finish`，`onPaneBell` 钩子删除，`RING_BELL` 显式吞掉以免落回系统 beep |
| 2026-08-01 | 项目 namespace 禁用 ⌘T（菜单项置灰 + 键盘监听一并拦截）——只有 free terminal 会绘制 tab bar，项目里建出的 tab 没有任何可见入口，切过去后只能靠侧栏 pane 行找回来。项目布局仍走 worktree + 分屏（⌘D / ⇧⌘D） |
| 2026-08-01 | 移除 bell 通知整条链路：`paneBellStates` / `handleBell` / `clearBell` / `bellCount`、侧栏 pane 行的铃铛与高亮、rail 与 session 行的未读角标、提示音与系统通知，以及设置里的 Notifications 分区。实现效果不佳，通知方案待重新设计。Ghostty 层的 `onPaneBell` 桥接与 `notify-on-command-finish-action` 配置保留，重做时可直接复用 |
| 2026-08-01 | 每个 namespace 记住各自最后活动的 tab：切到别的项目再切回来会落回原来那个 tab，而不是一律跳到第一个。记录挂在 `activeTabID` 的 `didSet`，恢复前校验该 tab 仍存在（已关闭则回落到第一个） |
| 2026-07-29 | 拆分 AppKit 焦点回报与侧栏主动聚焦；点击终端条目时同步切换 namespace 和具体分屏，修复闪屏与跨 worktree 空白 |
| 2026-07-24 | 统一终端工作区视觉：平面标签栏、语义分隔线和低干扰 pane 焦点提示 |
| 2026-03-16 | 创建文档 |
