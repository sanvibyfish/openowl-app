# REQ-007: Right Dock 重构 + 独立 Terminals

> 状态：🔵 Draft | 优先级：P1 | 预估工时：2-3 天 | 创建日期：2026-05-07

---

## 1. 需求概述

把当前「Toolbar 中央 4-tab 切换主区域内容」的布局改为「中间永远是 Terminal + 右侧可折叠 Right Dock 面板」，同时在 Sidebar 顶部新增「Terminals」区段，提供脱离 project 的独立终端能力（参考原生 ghostty）。

## 2. 背景与动机

- **Terminal 是用户主战场**：当前用户在 Files/Git 之间切换会丢失 Terminal 视觉焦点，需要 cmd+T 切回；但 Terminal 是日常使用频率最高的视图。
- **辅助视图按需调出**：Files/Git 是「查看/操作」性质的辅助视图，更适合 inspector 模式。
- **独立终端的缺口**：当前每个 Terminal 都强绑定到某个 project/worktree，用户无法在「不打开任何项目」的情况下随手开一个 shell（比如临时 `ssh` 一台机器、跑系统命令）。
- 参考产品：Codex、Zed、Cursor 都采用「中间编辑器主区 + 右侧 inspector」的布局。

## 3. 用户故事

- **US-1**：作为开发者，我打开 openOwl 时希望第一眼看到 Terminal，不需要点任何按钮就能输入命令。
- **US-2**：作为开发者，我希望在没有打开任何项目时也能用 openOwl 跑命令（比如临时 `htop`、`ssh` 远程机器）。
- **US-3**：作为开发者，我点 Git 按钮时希望右侧弹出变更面板，Terminal 仍然可见，能边看 diff 边在 Terminal 跑 `git log`。
- **US-4**：作为开发者，我希望 Right Dock 状态在重启后保留（折叠/展开、上次选中的 tab、宽度），但独立 Terminals 不需要持久化（重启重新开一个）。

## 4. 功能描述

### 4.1 核心功能

**4.1.1 Sidebar 重构**

```
┌────────────────────────┐
│ ▼ TERMINALS         +  │
│   ▶_ Terminal          │
│   ▶_ Terminal 2     ✕  │  (hover 显示 ✕，仅当数量 > 1)
│ ─────────────────────  │
│ ▼ PROJECTS          +  │
│   ▼ 📁 wise-glow       │
│      ⌥ main            │
│      ⌥ feature/x       │
└────────────────────────┘
```

- Terminals 区段固定置顶，标题旁有 `+` 按钮新增独立 terminal
- 行 title 跟随 ghostty surface OSC 设置的 title 动态更新（与 ghostty quick terminal 一致）；初始为 "Terminal"
- 行 hover 时显示关闭按钮 `✕`，点击销毁该 terminal 及其 surface
- 当独立 terminals 只剩 1 个时，关闭按钮不显示（无法关闭最后一个）
- 区段可折叠（点击 `▼`/`▶` 标题）
- Projects 区段保持原行为，紧随 Terminals 之下

**4.1.2 中间区**

- 永远是 `TerminalWorkspaceView`
- 根据 sidebar 当前选中项决定显示哪一组 panes：
  - 选中 project / worktree → 该 project 的 panes（含 cwd=project.url）
  - 选中独立 terminal → 该独立 terminal 的 panes（cwd=$HOME）
- 切换 active 时不销毁背后的 surface，pane 状态保留（shell 历史、滚动位置、bell 计数）

**4.1.3 Right Dock**

```
┌──────────────────────────────────────┐
│          Files | Git         ↗  ⟩  │
│ project-name                     ↗  │
│ ~/path/to/project                    │
├──────────────────────────────────────┤
│                                       │
│  (FileExplorerView /                  │
│   GitChangesView 之一)                │
│                                       │
└──────────────────────────────────────┘
```

- 默认折叠（首次启动时不可见）
- 36pt 右侧 rail 的两个按钮（Files/Git）仅在 panel 折叠时显示，作为重新打开入口；15pt 图标配合 2pt 活动色条标识上次选中的 tab：
  - panel 折叠时点击 → 展开并切到该 tab
  - panel 展开后隐藏，避免与 panel 顶部 tab bar 重复
- 展开后 rail 隐藏；顶部 28pt 平面 tab bar 可点击切换 Files/Git，active tab 使用背景色阶与 2pt 底边标识。active project 名称紧随 tab 排在同一行（不再独占一行），完整路径作为它的 tooltip；dock 拖窄时项目名先于 tab 与图标按钮被截断。右上角三个图标：
  - `↗` Finder：在访达中显示当前项目（无 active project 时不显示）
  - `⤢` 全屏：panel 拓展到「占满中间+右侧空间」（Sidebar 仍可见，Terminal 隐藏）；再次点击恢复
  - `›` 折叠：关闭 panel
- 左缘可拖拽调宽度，最小 320pt，最大 = 主窗口宽度 × 50%
- 两个内容视图全部 mount（opacity + allowsHitTesting 切换），保留各自 state（沿用现有 4-tab 的做法）

**4.1.4 Toolbar 调整**

- 移除中央 `ViewTabBar`
- panel 折叠时显示右侧 rail：folder（Files）、git branch（Git）
- panel 展开时隐藏 rail，Files / Git 切换改由 panel header segmented control 承担

### 4.2 用户流程

**主流程：开发者写代码**

1. 启动 app → Sidebar 顶部出现 1 个独立 Terminal（cwd=$HOME），中间区显示该终端
2. 用户在 Sidebar 选择某个 project → 中间区切换到 project 终端，独立 terminal 后台保留
3. panel 折叠时用户点右侧 rail 的 Git 图标 → 右侧 panel 展开显示 Git changes
4. panel 展开后用户点 header Files tab → panel 不动，tab 切到 Files
5. 用户点 panel header 折叠图标 → panel 折叠，右侧 rail 重新出现
6. 用户拖拽 panel 左缘调整宽度 → 状态保留到 UserDefaults
7. 用户关闭 app → 重启后：右侧 dock 折叠/展开/tab/宽度恢复；独立 terminals 全部丢弃，重新创建一个 cwd=$HOME 的 Terminal

**辅助流程：临时跑命令**

1. 用户点 Sidebar 顶部 `+` 按钮新增独立 Terminal
2. 中间区切换到新 terminal（cwd=$HOME，shell 启动）
3. 用户跑完命令后 hover 该行点 `✕` 关闭
4. 当只剩 1 个独立 terminal 时，所有 `✕` 按钮自动隐藏

### 4.3 边界情况

- **关闭最后一个独立 terminal**：禁止（UI 层不显示 `✕` 按钮）
- **删除最后一个 project**：sidebar 仍显示 Terminals 区段，独立 terminal 仍可用
- **首次启动 + 没有任何 project + 没有任何独立 terminal**：自动创建 1 个 cwd=$HOME 的独立 terminal
- **Right Dock 全屏 + 切 sidebar 选项**：Terminal 在背后切换 namespace 不可见但保持运行；退出全屏后恢复显示
- **Right Dock 全屏时 ghostty 焦点**：focus 留在 panel 内部子视图（如 git diff 编辑器）；Terminal 不抢焦点
- **Cmd+T 等终端快捷键**：始终激活 Terminal（即使 Terminal 当前不可见，也回到 Terminal 视图并退出 panel 全屏）
- **Dock tab 切换**：展开态只由 header segmented control 切换 Files/Git，避免与项目快捷键冲突
- **窗口宽度 < 800pt**：panel 最大宽度仍为窗口 50%；用户可拖更窄但不低于 320pt

## 5. 技术方案

### 5.1 架构设计

新增模块：

```
openOwl/
├── App/
│   ├── ContentView.swift           # 三栏布局重构
│   ├── AppNavigationStore.swift    # 移除 ViewTab 概念，仅保留导航语义
│   └── RightDockStore.swift        # 新建：管理 dock 状态
└── Features/
    ├── Sidebar/
    │   ├── SidebarView.swift       # 顶部插 TerminalsSection
    │   ├── ProjectStore.swift      # 增加 freeTerminals + ActiveKind
    │   └── TerminalsSection.swift  # 新建
    ├── RightDock/
    │   └── RightDockView.swift     # 新建：tab bar + 内容 + 折叠/全屏
    └── Terminal/
        ├── TerminalWorkspaceStore.swift  # 索引改为 TerminalNamespace
        └── TerminalWorkspaceView.swift   # 跟随 ActiveKind 取 cwd
```

### 5.2 数据模型

```swift
enum RightDockTab: String, CaseIterable, Hashable {
    case files, git, deploy
}

@MainActor @Observable
final class RightDockStore {
    var isExpanded: Bool        // persisted
    var activeTab: RightDockTab // persisted
    var isFullscreen: Bool      // not persisted
    var width: CGFloat          // persisted preference; effective width clamps to current host

    func toggle(tab: RightDockTab) { ... }
    func collapse() { ... }
    func toggleFullscreen() { ... }
}

enum ActiveKind: Equatable {
    case project(String)         // projectID
    case freeTerminal(UUID)      // freeTerminalID
}

struct FreeTerminalItem: Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
}

// TerminalWorkspaceStore 内部索引键
enum TerminalNamespace: Hashable {
    case project(String)
    case freeTerminal(UUID)
}
```

### 5.3 关键 API 变更

```swift
// ProjectStore（新增）
var freeTerminals: [FreeTerminalItem]
var activeKind: ActiveKind?
func activate(_ kind: ActiveKind)
func addFreeTerminal() -> FreeTerminalItem
func removeFreeTerminal(id: UUID)  // 强制保留至少 1 个

// TerminalWorkspaceStore（重命名 / 重载）
func paneInfos(for ns: TerminalNamespace) -> [PaneInfo]
func bellCount(for ns: TerminalNamespace) -> Int
func ensureInitialTab(for ns: TerminalNamespace, cwd: String)
```

### 5.4 第三方依赖

无新增。复用现有：
- libghostty（surface 池保持扁平）
- SwiftUI NavigationSplitView（双栏不变，detail 内部自管理三栏）
- UserDefaults（持久化 dock 状态）

## 6. 验收标准

```
1. 启动 app，左侧 Sidebar 顶部有 "TERMINALS" 区段，包含 1 个名为 "Terminal" 的行
2. 中间区显示该 terminal，cwd=$HOME，prompt 正常工作
3. 点击 Terminals 区段右侧 + 按钮，新增第二个独立 terminal，行 title 跟随 shell 自动更新
4. 切换到 Projects 里某个 worktree，中间显示该 worktree 的项目终端，独立 terminal 在沙箱中保留运行
5. 切回独立 Terminal，shell 历史和滚动位置保留
6. 当独立 terminal 数量 = 1 时，hover 该行不显示关闭按钮
7. 当独立 terminal 数量 ≥ 2 时，hover 任意行显示关闭按钮，点击关闭对应 terminal
8. Toolbar 中央 4-tab 消失；panel 折叠时右侧出现 2 个 rail 图标按钮（Files/Git）
9. 启动时右侧 panel 折叠不可见
10. 点击右侧 rail 的 Git 按钮 → 右侧 panel 展开，显示 GitChangesView，tab bar 高亮 Git
11. Tab bar 切换 Files → 显示 FileExplorerView，state（如折叠状态）保留
12. 点击 panel 右上角折叠按钮 → panel 关闭；再次点击右侧 rail 的 Files 按钮 → panel 打开，回到 Files tab
13. panel 展开时 Files/Git rail 隐藏，避免与 header tab bar 重复
14. 点击 panel 右上角 ↗ 全屏按钮 → Sidebar 仍可见，中间 Terminal 隐藏，panel 占满右侧；再次点击 ↗ → 恢复
15. 切 project：右侧项目名称、路径与 Files/Git 内容同步切换
16. 拖拽 panel 左边缘可调宽度，最小 320pt，最大 = 主窗口宽度 50%
17. 关闭 app 重启：独立 terminals 不保留（全部丢弃，重新开一个 cwd=$HOME 的 Terminal）；right dock 折叠/展开状态保留；上次选中 tab 保留；上次宽度保留
18. Right dock 展开时平面 tab header 可切换 Files/Git，切换后子视图 state 保留
19. 性能：toggle right dock 动画 < 200ms 无明显卡顿
20. Right dock 全屏时 Terminal 后台保持运行（shell 进程不被 SIGTSTP）
```

## 7. 优先级与排期

| Phase | 任务 | 预估 |
|-------|------|------|
| P0 | 模型层（T1-T4）：RightDockStore + AppNavigationStore + ProjectStore + TerminalWorkspaceStore | 0.5 天 |
| P0 | Sidebar（T5-T6）：TerminalsSection + 集成 | 0.5 天 |
| P0 | Right Dock（T7）：RightDockView 含全屏/折叠/拖宽 | 0.5 天 |
| P0 | 集成（T8-T9）：ContentView 重构 + Toolbar | 0.5 天 |
| P0 | 测试 + 文档（T10） | 0.5 天 |

总计：2-3 天（solo 模式）。

## 8. 相关文档

- 现有 4-tab 实现：`openOwl/App/ContentView.swift:20-47`
- Sidebar 现有结构：`openOwl/Features/Sidebar/SidebarView.swift:49-117`
- Terminal cwd 注入：`openOwl/Features/Terminal/TerminalWorkspaceView.swift:24-32`
- Pane 状态指示：`openOwl/Features/Sidebar/SidebarView.swift:497-525`
- 项目侧边栏功能文档：`docs/features/006-project-sidebar.md`
- libghostty 集成：`docs/features/001-libghostty-integration.md`

## 9. 更新记录

| 日期 | 变更 | 作者 |
|------|------|------|
| 2026-07-25 | 项目上下文条并入 28pt tab header（路径改为 tooltip、Finder 入口移到右上角），面板 header 高度与编辑器 tab 栏对齐 | Lead |
| 2026-07-24 | Right Dock 外壳统一为平面终端工作区视觉：36pt rail、32pt tab header、40pt 项目上下文条及细活动线 | Codex |
| 2026-07-18 | 展开态采用 Files/Git segmented header 与项目上下文架；右侧 rail 仅在折叠态作为入口 | Codex |
| 2026-05-07 | 初稿 | Lead |
