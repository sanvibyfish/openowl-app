# FEAT-008: Right Dock + 独立 Terminals

> 状态：✅ Done | 创建日期：2026-05-07 | 完成日期：2026-05-07

---

## 1. 功能概述

把"Toolbar 中央 4-tab 切换主区域"的旧布局重构为：

- **中间区永远是 Terminal**（除非 right dock 全屏时被隐藏）
- **右侧 Right Dock**：可折叠的 inspector，托管 Files / Git / Deploy 三个固定 tab
- **左侧 Sidebar 顶部**新增 "TERMINALS" 区段，提供独立于 project 的 free terminals（参考原生 ghostty）

详细需求与验收标准见 [REQ-007-right-dock.md](../requirements/REQ-007-right-dock.md)。

## 2. 用户流程

### 主流程：开发者写代码

1. 启动 → Sidebar 顶部 "TERMINALS" 区段含 1 个 free terminal（cwd=$HOME），中间区显示该终端
2. 在 Sidebar 选中某个 project / worktree → 中间区切换到该 project 的终端，free terminal 后台保留
3. dock 折叠时点 toolbar Git 按钮 → 右侧 dock 展开显示 Git changes，Terminal 仍可见
4. dock 展开后在 header 中切换 Files / Git / Deploy
5. 点 header 折叠按钮 → dock 折叠；toolbar 重新显示 Files / Git / Deploy 入口
6. 拖 dock 左缘调宽度 → 持久化到 UserDefaults
7. 关闭 app 重启 → dock 折叠/展开/tab/宽度恢复；free terminals 全部丢弃，重新创建一个 cwd=$HOME 的 terminal

### 辅助流程：临时跑命令

1. 点 Sidebar "TERMINALS" 区段 `+` 按钮 → 新增一个 free terminal（cwd=$HOME）
2. 跑完命令后 hover 该行点 `✕` 关闭
3. 当只剩 1 个 free terminal 时，所有 `✕` 自动隐藏（无法关闭最后一个）

## 3. 技术实现

### 3.1 新增模块

```
openOwl/
├── App/
│   └── RightDockStore.swift        # 管理 dock 状态
└── Features/
    ├── RightDock/
    │   └── RightDockView.swift     # tab bar + 内容 + 全屏/折叠/拖宽
    └── Sidebar/
        └── TerminalsSection.swift  # "TERMINALS" 区段视图
```

### 3.2 数据模型

```swift
// RightDockStore.swift
enum RightDockTab: String, CaseIterable, Hashable, Identifiable {
    case files, git, deploy
}

@MainActor @Observable
final class RightDockStore {
    var isExpanded: Bool        // persisted (openowl.rightDock.isExpanded)
    var activeTab: RightDockTab // persisted (openowl.rightDock.activeTab)
    var width: CGFloat          // persisted (openowl.rightDock.width)
    var isFullscreen: Bool = false  // session-only

    func toggle(tab: RightDockTab)
    func collapse()
    func expand(tab: RightDockTab)
    func toggleFullscreen()
    func setWidth(_ newWidth: CGFloat, maxWidth: CGFloat)
}

// ProjectStore.swift
enum ActiveKind: Hashable {
    case project(String)
    case freeTerminal(UUID)
}

struct FreeTerminalItem: Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
}

extension ProjectStore {
    var freeTerminals: [FreeTerminalItem]
    var activeFreeTerminalID: UUID?
    var activeKind: ActiveKind? { ... }  // computed

    func activate(_ kind: ActiveKind)
    func addFreeTerminal() -> FreeTerminalItem
    func removeFreeTerminal(id: UUID)  // refuses to remove last one
}

// TerminalWorkspaceStore.swift
typealias TerminalNamespace = ActiveKind  // 同形 enum，复用

extension TerminalWorkspaceStore {
    var activeNamespace: TerminalNamespace?
    func switchNamespace(_ ns: TerminalNamespace?)
    func newTab(for ns: TerminalNamespace? = nil)
    func paneInfos(for ns: TerminalNamespace) -> [PaneInfo]
    func bellCount(for ns: TerminalNamespace) -> Int
}
```

### 3.3 关键设计

**一、Surface 池保持扁平。** Tabs 通过 `tabNamespaceMap: [UUID: TerminalNamespace]` 索引到 namespace，但 ghostty surface 仍按 paneID 全局索引。namespace 只是分组维度，不影响 pane 生命周期。

**二、`activeProjectID` 兼容层。** 36 处调用方仍用 stored var `activeProjectID: String?`。新增 `didSet` 在切到 project 时清 `activeFreeTerminalID`，保证两者互斥。`activeKind` 是 computed，读优先级 project > freeTerminal。

**三、ContentView 三栏布局。** 旧 4-tab `ZStack` 删除，detail 区改为：

```swift
GeometryReader { geo in
    VStack {
        HStack(spacing: 0) {
            terminalContent
                .frame(width: dock.isFullscreen ? 0 : nil)
                .clipped()
            if dock.isExpanded {
                Divider()
                RightDockView(hostWidth: geo.size.width)
                    .frame(width: dock.isFullscreen ? geo.size.width : dock.width)
            }
        }
        Divider()
        StatusBarView()
    }
}
```

`hostWidth` 通过 GeometryReader 读取 detail 区当前宽度，传给 RightDockView，再用于 `setWidth(_:maxWidth:)` 的 50% 上限 clamp。

**四、Toolbar 改造。** 原 `ViewTabBar`（中央 4-tab）删除。`RightDockToolbarButtons` 只在 dock 折叠时显示，作为重新打开 Files / Git / Deploy 的入口；dock 展开时由 `RightDockView` header tab bar 承担 tab 切换，避免 toolbar 与 dock header 出现重复图标。

**五、AppNavigationStore 极简化。** 移除 `ViewTab` enum 和 `activeTab` 属性，仅保留 `openDeployment(...)` API（多了 `rightDockStore` 参数）。所有 navigate 调用方迁移到直接调 `RightDockStore.expand(tab:)`。

### 3.4 持久化

| 字段 | 持久化 | Key |
|------|-------|-----|
| `RightDockStore.isExpanded` | UserDefaults | `openowl.rightDock.isExpanded` |
| `RightDockStore.activeTab` | UserDefaults | `openowl.rightDock.activeTab` |
| `RightDockStore.width` | UserDefaults | `openowl.rightDock.width` |
| `RightDockStore.isFullscreen` | ❌ | — |
| `ProjectStore.freeTerminals` | ❌ | — |
| `ProjectStore.activeFreeTerminalID` | ❌ | — |

启动时若没有 active project（包括首次启动）→ 自动 activate 第一个 free terminal。

## 4. 注意事项

- **删除 ViewTab enum。** 以前调用 `navigationStore.activate(.terminal/.gitChanges/...)` 的代码全部迁移。如果新增功能要"切换主区域显示某 view"，请直接操作 `RightDockStore`。
- **Free Terminal 行的 title** 来自 ghostty surface 通过 OSC 0/2 设置的 pane title（与 ghostty quick terminal 一致）。shell 启动后 zsh 会自动设置 title 为 cwd 末段；初始显示 "Terminal"。
- **关闭最后一个 free terminal** 在 UI 层（hover button 不显示）和 model 层（`removeFreeTerminal` 早返回）双重保护。
- **Right Dock 全屏时 Terminal 仍后台运行。** Terminal 的 `frame(width: 0)` + `clipped()` 隐藏视图但不卸载 ghostty surface，shell 进程不受影响。隐藏期间不会把 0/1px 尺寸同步给 libghostty，pane 保留上一次可用 PTY 尺寸；退出全屏恢复显示时会按当前 bounds 强制重同步，避免 TUI 仍按旧列数绘制。
- **`activeKind` 和 `activeProjectID` 不要双向同步。** 内部代码读 `activeKind`，写优先用 `activate(_:)`。`activeProjectID` 的直接赋值仍兼容（didSet 自动清 `activeFreeTerminalID`），但不再推荐。

## 5. 相关需求

- [REQ-007-right-dock.md](../requirements/REQ-007-right-dock.md)

## 6. 更新记录

| 日期 | 变更 | 作者 |
|------|------|------|
| 2026-06-04 | 补充 Terminal 隐藏期间保留 PTY 尺寸、恢复显示时强制重同步的规则 | Codex |
| 2026-05-07 | 初稿 + 实现完成 | Lead |
| 2026-05-10 | Right Dock 展开时隐藏 toolbar 入口，避免与 header tab 重复 | Lead |
