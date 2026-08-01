# FEAT-008: Right Dock + 独立 Terminals

> 状态：✅ Done | 创建日期：2026-05-07 | 完成日期：2026-05-07

---

## 1. 功能概述

把"Toolbar 中央 4-tab 切换主区域"的旧布局重构为：

- **中间区永远是 Terminal**（除非 right dock 全屏时被隐藏）
- **右侧 Right Dock**：可折叠的 inspector，托管 Files / Git 两个固定 tab
- **左侧 Project Rail**（2026-07-28）：48pt 窄图标轨，入口含 free terminal + 项目 monogram（见 [FEAT-006](006-project-sidebar.md)）；不再使用宽项目树

详细需求与验收标准见 [REQ-007-right-dock.md](../requirements/REQ-007-right-dock.md)。

## 2. 用户流程

### 主流程：开发者写代码

1. 启动 → 左 rail 顶部 free terminal（cwd=$HOME），中间区显示该终端
2. 点左 rail 项目 monogram / popover 内 worktree → 中间区切换到该 project 的终端，free terminal 后台保留
3. dock 折叠时点右侧 rail 的 Git 按钮 → 右侧 dock 展开显示 Git changes，Terminal 仍可见
4. dock 展开后在顶部平面 tab header 中切换 Files / Git
5. 点 header 折叠按钮 → dock 折叠；右侧 rail 重新显示 Files / Git 入口
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
    └── RightDock/
        ├── RightDockView.swift     # tab bar + 内容 + 全屏/折叠/拖宽
        └── RightDockRail.swift     # 折叠态窄图标条
```

### 3.2 数据模型

```swift
// RightDockStore.swift
enum RightDockTab: String, CaseIterable, Hashable, Identifiable {
    case files, git
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
            Divider()
                .frame(width: dock.isExpanded ? 1 : 0)
                .opacity(dock.isExpanded ? 1 : 0)
            RightDockView(hostWidth: geo.size.width)
                .frame(width: dock.isExpanded
                    ? dock.effectiveWidth(hostWidth: geo.size.width)
                    : 0)
                .opacity(dock.isExpanded ? 1 : 0)
                .disabled(!dock.isExpanded)
                .allowsHitTesting(dock.isExpanded)
                .accessibilityHidden(!dock.isExpanded)
            if !dock.isExpanded {
                Divider()
                RightDockRail()
            }
        }
        Divider()
        StatusBarView()
    }
}
```

`hostWidth` 通过 GeometryReader 读取 detail 区当前宽度。`RightDockStore.effectiveWidth(hostWidth:)` 会在每次布局时按当前窗口重新 clamp：普通 dock 不超过可用宽度的 50%，避免持久化宽度或窗口缩窄把 Terminal 挤成极窄列；展开态不显示 rail，因此全屏 dock 可占满 detail 区。

`RightDockView` 不再由 `if isExpanded` 条件创建/销毁。折叠态仅将宽度设为 0，并组合 opacity、disabled、hit testing 与 accessibility hidden 隐藏交互；内部 `FileExplorerView` / `GitChangesView` 因此持续挂载，tabs、dirty buffer 与其他 view state 保留。

**四、Inspector 外壳。** 原 `ViewTabBar`（中央 4-tab）删除。dock 折叠时只显示 36pt 右侧 rail，作为重新打开 Files / Git 的入口；rail 使用 15pt 图标和 2pt 活动色条标识上次选中的 tab。展开后 rail 隐藏，由 `RightDockView` 的 28pt 平面 tab header 承担切换，active tab 以背景色阶和 2pt 底边标识。

项目上下文不再独占一行：active project 名称直接排在 tab 右侧，缩写路径降级为它的 tooltip，Finder 入口与全屏、折叠三个图标按钮固定在 header 右端。项目名使用 `layoutPriority(-1)` + 中部截断，dock 拖窄时优先让位给 tab 和图标按钮。dock 外壳因此从 104pt（32 tab + 40 项目条 + 32 面板 header）压到 57pt（28 + 1 分隔线 + 28）。

面板 header 统一使用 `AppSpacing.headerHeight`，该常量与 `editorTabBarHeight` 同为 28pt——两者不等时，Files tab 左栏工具栏（32pt）与右栏编辑器 tab 栏（28pt）之间的分隔线会出现可见台阶。Files / Git 面板的工具栏不再显示 "EXPLORER" / "CHANGES" 标题，面板身份已由上方 tab 标注。

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
- **Right Dock 宽度是持久化偏好，不是无条件布局宽度。** 启动或窗口变窄后，`effectiveWidth` 会按当前窗口重新限制普通 dock 宽度，保证 Terminal 不会被历史宽度挤到只剩几列。
- **Right Dock 展开/收起动画、手动调宽与窗口 live resize 期间暂停 PTY resize，但 Terminal view 仍裁到当前 bounds。** 这样避免多次 SIGWINCH 破坏 scrollback，同时防止 Metal 层继续按旧宽度绘制到 Files/Git 面板背后。freeze 期间 `TerminalNSView.setFrameSize` 的自动 sync 也会被 suppress，直到动画或拖拽结束后强制同步最终尺寸。
- **手动调宽被折叠或进入 dock fullscreen 打断时立即结束 interactive resize。** 这两种状态都会移除/隐藏 resize handle，`RightDockStore` 同步清除交互 flag；正常 drag end 仍立即清除，不依赖 timeout。
- **Right Dock 全屏时 Terminal 仍后台运行。** Terminal 的 `frame(width: 0)` + `clipped()` 隐藏视图但不卸载 ghostty surface，shell 进程不受影响。隐藏期间不会把 0/1px 尺寸同步给 libghostty，pane 保留上一次可用 PTY 尺寸；退出全屏恢复显示时会按当前 bounds 强制重同步，避免 TUI 仍按旧列数绘制。
- **`activeKind` 和 `activeProjectID` 不要双向同步。** 内部代码读 `activeKind`，写优先用 `activate(_:)`。`activeProjectID` 的直接赋值仍兼容（didSet 自动清 `activeFreeTerminalID`），但不再推荐。

## 5. 相关需求

- [REQ-007-right-dock.md](../requirements/REQ-007-right-dock.md)

## 6. 更新记录

| 日期 | 变更 | 作者 |
|------|------|------|
| 2026-07-31 | `ContentView` 以 width 0 + opacity/disabled/hit-testing/accessibility hidden 保持 `RightDockView` 常驻；折叠或进入 fullscreen 时结束 interactive resize freeze | Codex |
| 2026-07-28 | 左侧宽 Sidebar 换为 `ProjectRail`；ContentView 去掉 NavigationSplitView，三栏变为 左 rail + Terminal + 右 dock | Lead |
| 2026-07-25 | 项目上下文条并入 tab header（路径降为 tooltip）、删除 EXPLORER/CHANGES 重复标题、`headerHeight` 32→28 对齐编辑器 tab 栏、文件树背景从 `.regularMaterial` 改回语义色；dock 外壳 104pt→57pt | Lead |
| 2026-07-24 | 采用终端工作区的平面视觉语言：36pt precision rail、32pt tab header、40pt 项目上下文条，并以细活动线替代胶囊式 segmented control | Codex |
| 2026-07-18 | Right Dock 展开态改为顶部 Files/Git segmented header + 项目上下文架；竖 rail 仅在折叠态显示，视觉层级对齐终端伴随式 inspector | Codex |
| 2026-06-25 | Right Dock 展开/收起动画、手动调宽与窗口 live resize 期间改为暂停 PTY resize 而非扩大 Terminal view，并 suppress `setFrameSize` 自动 sync，避免 Files/Git 面板遮挡与拖拽调宽导致 terminal 反复重排 | Codex |
| 2026-06-17 | 普通 dock effectiveWidth 增加运行时上限，避免持久化宽度挤压 Terminal | Codex |
| 2026-06-04 | 补充 Terminal 隐藏期间保留 PTY 尺寸、恢复显示时强制重同步的规则 | Codex |
| 2026-05-07 | 初稿 + 实现完成 | Lead |
| 2026-05-10 | Right Dock 展开时隐藏 toolbar 入口，避免与 header tab 重复 | Lead |
| 2026-07-31 | `effectiveWidth` / `maxNormalWidth` 去掉恒为 0 的 `railWidth` 参数（展开态不显示 rail，该参数在生产环境无效果） |
| 2026-07-31 | `GitChangesView` 提交 diff 的文件侧栏分隔线改回竖向实现——`PanelDivider` 本分支从 `Divider()` 改成写死横向 + `maxWidth: .infinity`，在 `HStack` 内会渲染成 1pt 高的横条并挤占 diff 区宽度 |
| 2026-08-01 | Right Dock 视觉对齐主设计（Muxy / ProjectSessionList）：统一 `panelToolHeader`、列表行 `selectableRowChrome`（accent 左竖条 + 圆角选中）、去掉 content 区 `.regularMaterial`、Git/Files 工具栏与 empty state 走 `AppPalette` token |
| 2026-08-01 | resize handle 的拖拽基准从 `dock.width` 改为 `effectiveWidth(hostWidth:)`——`width` 是存储偏好、可能被 `effectiveWidth` 上调（旧版本持久化的 420 会渲染成 520），锚在过时值上会让升级后第一次「拖窄」全程无响应 |
| 2026-08-01 | `currentMinWidth` 的 list-only 分支改回 `listOnlyWidth`（原为 `minWidth`，与 `effectiveWidth` 实际渲染的 280 自相矛盾） |
