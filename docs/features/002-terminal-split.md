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
5. **放大/还原**: 双击窗格顶部的三点手柄，或 Cmd+Shift+Return（菜单 Terminal → Maximize Pane，标题随状态切换 Restore Pane）。放大态下手柄保留——那是鼠标唯一的返回入口——但不再可拖动
6. **关闭窗格**: Cmd+W 关闭当前窗格；最后一个窗格时关闭标签。关掉的是某个 namespace 的最后一个标签时按 namespace 分流——项目：先审批 context 切换，成功后留空并让项目变非激活（见 FEAT-006），审批失败则保持原 terminal；free terminal：关窗口
7. **交换窗格**: 拖拽窗格到另一个窗格的边缘区域（左/右/上/下/中心）

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

采用 **flat 布局** 而非嵌套 View：`paneFrames(in:)` 递归计算每个 leaf 的绝对 CGRect，所有窗格用 `.frame()` + `.position()` 平铺在 GeometryReader 中。所有 namespace 中已创建的 tab 保持挂载；切项目只切换 opacity / hit testing / accessibility，后台 pane 暂停 Metal 渲染，不再把 `TerminalNSView` 从 window 上拆下再插回。

优势：避免 SwiftUI 在树结构变更时销毁重建 NSView（会导致终端状态丢失）。

### 3.3 焦点导航

`nextPaneID(from:currentPaneID:frames:direction:)` 算法：
1. 过滤方向上的候选窗格（如 `.left` 只找 maxX ≤ 当前 minX 的窗格）
2. 多因子排序：距离 → 重叠度 → 横向偏移
3. 选择最优候选

### 3.4 窗格位置

每个 pane UUID 对应一个 `ghostty_surface_t`（由 GhosttyAppManager 管理）。

`ghostty_surface_new()` 返回 nil 时，`TerminalNSView` 在原 pane 内居中显示失败提示 `Terminal failed to start.` 并指向 `~/Library/Logs/openOwl/openowl.log`（ghostty 的具体错误只在日志中，提示本身重述失败没有价值），同时写入 `[terminal]` 日志。pane 保留在当前分屏树中，不会自动移除；失败状态会阻止 view 重新挂载时再次创建 surface 或叠加错误 UI。由于该状态按契约不可恢复，AppleScript 对该 pane 的 `input text` 返回终态失败而非 `notReady`。

### 3.5 放大 / 还原

`maximizedPaneID` 是独立于 `splitTree` 的一个字段——放大**不改动分割树**，只在渲染那一帧把该 pane 的 frame 换成整个 `bounds`，其余 pane `opacity 0` + `allowsHitTesting(false)`，分割线隐藏。因此：

- **surface 不销毁**：兄弟 pane 的 shell 进程照常运行，被盖住期间的输出还原后全部可见
- **PTY 尺寸保持**：隐藏 pane 不被缩到 0，vim/htop 这类尺寸敏感的 TUI 不会重排；重新可见时 `syncSurfaceSize(force:)` 强制重同步
- **辅助功能与可见性一致**：最大化隐藏的兄弟 pane 使用 `.accessibilityHidden(true)`，VoiceOver 不会聚焦到屏幕上看不见的手柄或 terminal
- **比例原样回来**：frame 每帧由 `splitTree.paneFrames(in:)` 现算，还原即换回，用户拖过的 ratio 不丢

`toggleMaximizeCurrentPane(paneID:)` 的参数区分两个入口：手柄双击传具体 pane（不一定是焦点所在），键盘/菜单传 nil 走焦点 pane。`switchNamespace` 会重置放大态——切项目再切回是还原态。

## 4. 注意事项

- 分割线宽度 1px，热区 8px（方便拖拽）
- 多窗格仅轻微弱化非 focused pane，不绘制焦点边框，避免分隔边缘出现突兀的 accent 高亮
- `TerminalNSView` 的焦点回调只同步 `focusedPaneID`；侧栏点击 pane 时先切换到所属 main/worktree namespace，再选中对应分屏并单次请求 first responder，避免跨 worktree 显示空白或焦点请求自循环造成终端闪屏
- 项目最后一个 terminal 的关闭是事务性操作：`closeCurrent` 在销毁 surface 前调用宿主审批 closure；如果 editor 无法保存 dirty tab 并拒绝 context 切换，tab、selection 和 surface 全部保持原状
- Free Terminal 标签采用 28pt 平面连续 tab bar，active tab 通过背景层级与终端内容连接
- 关闭窗格后焦点转移到最近的邻居（Euclidean 距离）
- 标签按项目隔离：切换项目只显示该项目的标签

## 5. 相关需求

- [REQ-001: 终端](../requirements/REQ-001-terminal.md)

## 6. 更新记录

| 日期 | 说明 |
|------|------|
| 2026-08-22 | 失败提示改为指向日志（原文案只是重述失败，不可操作），实现由手搓 NSBox + 8 条 AutoLayout 约束压缩为居中 autoresizing label；AppleScript 对失败 pane 的输入返回终态错误，避免脚本重试永不成功的目标。**「重新挂载不重试」的契约保持不变** |
| 2026-08-14 | `ghostty_surface_new()` 失败时在原 pane 显示可访问的原生错误卡片 `Terminal surface failed to initialize`；pane 不自动移除，失败状态阻止重新挂载时重试创建或重复添加 UI |
| 2026-08-09 | 修复嵌套分屏的 pane 拖拽只能命中部分窗格：pane 主体重排改由每个 `TerminalScrollView` 在 AppKit 层处理，与文件拖入共用原生拖放入口；`PaneHandleNSView` 同样在 AppKit 层接收手柄到手柄的中心交换。不在 `TerminalNSView` 上方挂 SwiftUI drop target。隐藏 tab/pane 同步注销拖放类型，避免不可见终端抢走文件或 pane 拖拽 |
| 2026-08-07 | 三点手柄改为 AppKit `PaneHandleNSView`：`mouseDown` 双击放大/还原，`mouseDragged` 自启 `NSDraggingSession`，结束走 `NSDraggingSource` 回调清状态。SwiftUI `.onTapGesture(count: 2)` + `.onDrag` 互相拆台（延迟 mouseDown 导致 drop 失败；空 NSView overlay 收不到点击），双击放大因此失效 |
| 2026-08-04 | 修复取消拖拽后终端失去响应：`draggingPaneID` 只在 `performDrop` 成功时清除，Esc 取消 / 拖到窗口外松手 / 拖回源窗格都会让它卡住，非源窗格的 `contentShape` drop overlay 随即永久吃掉点击与文本选择。现由手柄 `NSDraggingSource.draggingSession(_:endedAt:)` 统一清状态 |
| 2026-08-03 | 项目最后一个 terminal 改为「context 审批成功 → 销毁 surface」；审批失败不再先关 terminal 再留下空 namespace。最大化隐藏 pane 显式移出 accessibility 树 |
| 2026-08-03 | 三点手柄支持双击放大/还原——放大能力本就存在（`maximizedPaneID` + ⇧⌘↩），缺的只是鼠标入口。手柄改为在放大态也渲染（否则鼠标回不去）并在该态去掉 `.onDrag`；`toggleMaximizeCurrentPane` 加可选 `paneID`，因为手柄是 per-pane 的，点谁放大谁，而不是放大当前焦点 pane |
| 2026-08-01 | `closeCurrent()` 关掉项目最后一个 tab 时不再补新 tab，改为清空 `activeTabID` 并返回新的 `.projectEmptied`，由宿主把选中态切到 free terminal。上一条的「就地新建 tab」让 `hasTabs` 恒为 true，项目再也无法变成非激活。free terminal 的最后一个 tab 仍返回 `.closeWindow` |
| 2026-08-01 | `closeCurrent()` 不再跨 namespace 兜底到 `tabs.last`：关掉某 namespace 最后一个 tab 会把活动槽交给另一个 namespace 的 tab，`activeTabID.didSet` 随即把那个 namespace 的记忆改写成用户从未打开过的 tab。现改为就地新建 tab，与 `switchNamespace` 对空 namespace 的处理一致（当日被上一条取代） |
| 2026-08-01 | 移除 bell 生产端残留：`GhosttyConfig` 不再请求 `notify-on-command-finish`，`onPaneBell` 钩子删除，`RING_BELL` 显式吞掉以免落回系统 beep |
| 2026-08-01 | 项目 namespace 禁用 ⌘T（菜单项置灰 + 键盘监听一并拦截）——只有 free terminal 会绘制 tab bar，项目里建出的 tab 没有任何可见入口，切过去后只能靠侧栏 pane 行找回来。项目布局仍走 worktree + 分屏（⌘D / ⇧⌘D） |
| 2026-08-01 | 移除 bell 通知整条链路：`paneBellStates` / `handleBell` / `clearBell` / `bellCount`、侧栏 pane 行的铃铛与高亮、rail 与 session 行的未读角标、提示音与系统通知，以及设置里的 Notifications 分区。实现效果不佳，通知方案待重新设计。Ghostty 层的 `onPaneBell` 桥接与 `notify-on-command-finish-action` 配置保留，重做时可直接复用 |
| 2026-08-01 | 每个 namespace 记住各自最后活动的 tab：切到别的项目再切回来会落回原来那个 tab，而不是一律跳到第一个。记录挂在 `activeTabID` 的 `didSet`，恢复前校验该 tab 仍存在（已关闭则回落到第一个） |
| 2026-07-29 | 拆分 AppKit 焦点回报与侧栏主动聚焦；点击终端条目时同步切换 namespace 和具体分屏，修复闪屏与跨 worktree 空白 |
| 2026-07-24 | 统一终端工作区视觉：平面标签栏、语义分隔线和低干扰 pane 焦点提示 |
| 2026-03-16 | 创建文档 |
