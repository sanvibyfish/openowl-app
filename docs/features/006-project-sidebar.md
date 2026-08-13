# FEAT-006: 项目管理侧边栏（Project Rail）

> 状态：✅ Done | 创建日期：2026-01-10 | 完成日期：2026-03-14 | 布局改版：2026-07-28

---

## 1. 功能概述

项目导航 + free terminal 入口。**2026-07-28 起 UI 改为 Muxy 风格窄 icon rail**（`ProjectRail`，宽 48pt），不再使用宽 `NavigationSplitView` 项目树。

能力不变：添加/移除项目、切换活跃项目、Git Worktree 管理、分支前缀自动检测、持久化 `~/.openowl/openowl.json`、Claude incident 指示。

## 2. 用户流程

1. **添加项目**: 点 rail 底部 `+` 打开文件夹选择器
2. **切换项目**: 点项目 monogram，终端 / Git / 文件浏览器同步切换
3. **Free terminal**: rail 顶部 terminal 图标；中间区显示 standalone shell（tab bar 在内容区顶）
4. **Worktree**: 再次点击**已选中**的项目图标 → 弹出 popover，可切 main / worktree、创建 worktree
5. **移除项目**: popover → Remove（只从列表移除，不删磁盘文件）
6. **归档 worktree**: popover 内 worktree 行右键 → Archive Worktree
7. **状态感知**: Claude incident 时 rail 底部黄三角；点击打开 status 页，右键可 dismiss
8. **关闭项目**: `Cmd+W` 关掉项目最后一个终端 → 该项目变为非激活，从 rail 消失、回到 `+` 菜单列表，选中态切回 free terminal

## 3. 技术实现

### 3.1 数据模型

```swift
struct ProjectItem: Identifiable, Hashable, Codable {
    let id: String           // UUID
    let path: String         // 标准化绝对路径
    var name: String         // 显示名（目录名）
    var worktreeOf: String?  // 父项目 ID（nil = 根项目）
    var worktreeBranch: String?
    var lastBranch: String?  // 最后已知分支
    var branchPrefix: String? // GitHub 用户名 / 自定义前缀
}
```

### 3.2 持久化

```json
// ~/.openowl/openowl.json
{
  "projects": [ ... ],
  "activeProjectId": "..."
}
```

- Pretty-printed + sorted keys，方便人工查看和调试
- Atomic 写入防止损坏
- 启动时从 UserDefaults 一次性迁移（旧版兼容）
- 路径验证: `isReasonableProjectPath()` 要求 ≥3 个路径组件
- 去重: `uniqued()` 基于标准化路径
- `openowl.json` 无法读取/解码时先改名隔离；隔离成功后异步提示备份路径，并以空项目列表继续启动
- 隔离失败时异步告警，将本 session 的 `ProjectStore` 标记为只读；后续 `persist()` 全部拒绝，原始 `openowl.json` 保持不变
- 测试宿主的默认 store 路径位于独立临时目录，避免单元测试读写真实 `~/.openowl/openowl.json`

### 3.3 Worktree 支持

```
ProjectStore
  ├── addWorktreeProject(parentID, path, branch)
  ├── removeWorktreeProject(id)  → 回退到父项目
  └── renameWorktreeProject(id, newBranch)

GitService
  ├── addWorktree(branch, dirName)  → ~/.openowl/workspace/projects/{name}/{slug}
  ├── listWorktrees()
  └── removeWorktree(path)
```

Worktree 目录统一存放在 `~/.openowl/workspace/projects/` 下。

归档 worktree 会先进入进度态并禁用重复点击。openOwl 先以父仓库的 `git worktree list --porcelain` 判断当前登记状态：

- 仍登记为 worktree **且目录仍存在**：检查未提交修改，再执行 `git worktree remove --force`。**未提交检查本身失败时 fail-closed** —— 提示用户并取消归档，绝不在「不知道有没有脏改动」的状态下走 `--force`（git 超时、`index.lock` 被占用、仓库损坏都会走到这条路径）。目录存在性是检查的前置条件：git 无法在不存在的工作目录下运行，少了这个前置判断，抛错会落进 fail-closed 分支，让下面那条「路径已不存在」的清理路径永远无法到达
- `git worktree remove --force` 本身失败时：git 会**先删除 worktree 登记（gitdir）再删目录**，所以目录删不掉时 worktree 实际已注销、只剩一个孤儿文件夹。openOwl 先清掉整棵目录树下 Finder 随手丢的 `.DS_Store`（不只根目录，`--force` 也会因它们失败）并重试一次；仍失败则**以实际登记状态而非 git stderr 文案为准**（文案随版本/语言变化）判断：若登记仍在说明 git 在丢弃任何东西之前就拒绝了，保持 fail-closed 抛出错误；若登记已消失说明 worktree 状态已被 git 丢弃，按下方「路径存在但未登记」路径处理，由用户决定是否移入废纸篓——绝不静默删整棵树。目录内只读文件/目录（如 CocoaPods `Pods/`）是常见触发原因
- 路径已经不存在：直接清理侧边栏中的失效记录
- 路径存在但未登记：不再调用 `git worktree remove`；提示用户选择将残留目录移到废纸篓或保留

Project Rail popover 与 Project Session List 的归档入口共享 `ProjectStore` 中按 worktree ID 记录的 in-flight guard。相同 worktree 的重复归档会在业务入口拒绝，菜单显示 `Archiving...` 并禁用；不同 worktree 可独立归档。成功、失败或用户取消后都会释放 guard，允许后续重试。

若归档目标是当前 active worktree，会在任何 `await`、创建 `GitService`、执行 Git 命令或移动文件前先调用 editor context preflight，并同步切到 parent。dirty buffer 保存失败时归档直接取消，不产生 Git/文件副作用；归档 in-flight 期间该 worktree 不可重新激活。

只有 Git 删除成功、路径确认不存在，或用户明确将残留目录移到废纸篓后，才会从 openOwl 项目列表移除。失败或选择保留时继续保留侧边栏条目，避免界面状态与磁盘/Git 状态不一致。

### 3.4 分支前缀

`branchPrefix` 用于 `BranchNameGenerator` 生成分支名（如 `sanvi/calm-vale`）。
- 自动检测: 解析 `git remote get-url origin` 提取 GitHub 用户名
- 回退: `NSFullUserName()` 转小写去空格
- 缓存在 ProjectItem 上，persist 后不再重复检测
- **触发点是 `activeProjectID` 的 `didSet`，不是各个调用点**。全类共 13 处赋值，其中最要紧的是隐式的那几处——删除项目会回落到另一个 root、删除 worktree 会回落到父项目。挂在调用点上必然漏掉它们，那些路径到达的项目会保持 `branchPrefix == nil`，「Create Worktree」永久禁用

### 3.5 项目隔离

切换 `activeProjectID` 时触发全局状态同步：
- 终端：只显示该项目的标签
- Git：切换到该项目的仓库
- 文件浏览器：切换到该项目的目录

### 3.6 Claude 异常提醒

- 位置：Project Rail 底部图标（仅异常时显示）
- 数据源：`https://status.claude.com/history.rss`
- 判定：存在未 `Resolved` incident 即显示异常（包括 `Monitoring`）
- 刷新：启动立即拉取，之后每 5 分钟轮询
- 容错：拉取失败时静默保留当前显示，等待下一次轮询
- 关闭行为：右键 Dismiss 后忽略当前 incident，仅新 incident 再次弹出

### 3.7 布局（Project Rail）

```
openOwl/Features/Sidebar/
├── ProjectRail.swift        # 窄 rail UI（主入口）+ WorktreeArchive / WorktreeAlert
├── ProjectSessionList.swift # 当前项目的分支 / worktree / pane 列表
├── ProjectStore.swift       # 数据 / 持久化 + worktree 创建与归档的进行中状态
└── BookmarkStore.swift
```

worktree 的创建与归档流程都住在 `ProjectStore`，rail 和 session list 只调用它 —— 两处都提供同一操作，各自持有进行中状态会让并发的 `git worktree add` 撞上 `index.lock`。异步创建在首个 Git 副作用前执行 editor context preflight；Git 成功后先将新 worktree 登记为 inactive，真正激活时再次审批。任何 pane/context veto 都保持当前项目与 terminal namespace 不变。

窗口结构（`ContentView`）：

```
┌──────┬──────────────────────────┬─────┐
│ Rail │  Terminal (主舞台)        │Dock │
│ 48pt │  (+ FreeTerminalTabBar)  │/rail│
├──────┴──────────────────────────┴─────┤
│ StatusBar                              │
└────────────────────────────────────────┘
```

- 不再使用 `NavigationSplitView` 左栏
- 选中态：左 2px accent 竖条 + monogram 填充色
- monogram 颜色 hash 使用 `magnitude` 计算 palette 索引，`Int.min` 也不会触发 `abs` 溢出
- 有 terminal bell 时 monogram 角标显示未读数
- rail 只列「激活」的 root：本 session 有 terminal tab 的，加上当前选中的那个（选中态先于 tab 创建生效，不带这一条会闪一下）

## 4. 注意事项

- **激活 = 有终端**：`ProjectRail.isProjectActive` 实时查 `TerminalWorkspaceStore.hasTabs`，没有独立的持久化字段。项目自身或其任一 worktree 有 tab 即算激活
- 关掉项目最后一个终端前，`TerminalWorkspaceStore` 通过 `AppDelegate` 提供的 closure 先请求 `ProjectStore` 切到 free terminal。只有 editor context 审批成功才销毁 terminal；审批失败时选中态与 session 都不变。留在已空项目上会让下一次 `syncActiveProjectContext` 经 `switchNamespace` 给它补一个 tab，所以这两个状态必须一次提交
- 项目顺序：root 保持 `ProjectStore` 持久化顺序，rail 不重排
- 从 Project Rail 切回某个 root 时，恢复该 root 最近一次选中的 main/worktree；用户明确切回 main 后，后续继续保持 main
- 删除根项目时同时移除所有子 worktree

## 5. 相关需求

- [REQ-006: Claude 状态 Sidebar 指示器](../requirements/REQ-006-claude-status-sidebar.md)
- [FEAT-008: Right Dock](008-right-dock.md) — 右侧 inspector，与左 rail 对称

## 6. 更新记录

| 日期 | 说明 |
|------|------|
| 2026-08-03 | 项目失活改为事务性顺序：先完成 editor context 审批并切到 free terminal，再删除项目最后一个 terminal；审批失败时不再产生空 namespace 或销毁 surface |
| 2026-08-01 | 恢复「关掉项目最后一个终端 → 项目变非激活」：`closeCurrent` 不再给空掉的项目 namespace 补 tab，改为返回 `.projectEmptied`，由 `AppDelegate` 把选中态切到 free terminal。`82a8a8c` 的补 tab 兜底把这条路堵死了，`hasTabs` 恒为 true |
| 2026-08-01 | 侧栏与 rail 去掉 bell 驱动的未读角标（`SessionRow.unread`、`RailStripButton.badge`、pane 行铃铛）——随通知链路一并移除，详见 FEAT-002 |
| 2026-08-01 | `SessionRow` / pane 行 / rail popover 行迁到共享 `selectableRowChrome`；session list header 用 `panelToolHeader` 与 right dock 对齐 |
| 2026-07-31 | `openowl.json` 隔离失败时本 session 改为只读且异步告警；active worktree 归档在 Git/文件副作用前执行 editor preflight；monogram hash 改用 magnitude |
| 2026-07-31 | `openowl.json` 解码失败改为先隔离备份再继续（此前落到迁移分支后 `projects` 为空，第一次 `persist()` 就永久覆盖用户项目列表）；`removeWorktree` 不再按 git stderr 子串分类并递归删整棵工作树，改为只删 `.DS_Store` 后重试 git；两文件 NSLog 全部改 AppLogger |
| 2026-08-12 | `removeWorktree` 的 `.DS_Store` 清理改为覆盖整棵目录树（Finder 会随手丢到任意子目录）；重试仍失败时不再直接报错，而是检查 worktree 实际登记状态——登记已被 git 丢弃（git 先删 gitdir 再删目录）则按「路径存在但未登记」路径交给用户决定是否移入废纸篓，登记仍在才 fail-closed 报错。修复归档含 CocoaPods `Pods/` 等只读文件/目录的 worktree 时报 `Directory not empty`、残留孤儿目录、侧边栏条目无法清理的问题 |
| 2026-07-31 | `detectBranchPrefix` 收进 `activeProjectID.didSet`——此前只挂在 4 个调用点，删除项目/worktree 后回落的 5 条路径漏掉，那些项目的 worktree 按钮永久禁用 |
| 2026-07-31 | 修 `6c52eda` 回归：归档的未提交检查加目录存在性前置，恢复「目录已删除但 git 仍登记」的清理路径；删除零调用且策略相反的死属性 `ProjectStore.branchPrefix`；`branchPrefix` 检测改为在 `init`/`addOrActivateProject` 也触发，避免新加或恢复的项目 worktree 按钮永久禁用 |
| 2026-03-16 | 创建文档 |
| 2026-03-18 | 新增 Claude 异常提醒卡片（RSS 轮询 + 可关闭忽略） |
| 2026-05-10 | 修复 worktree 归档无进度反馈、可重复点击、失败仍从项目列表移除的问题 |
| 2026-07-24 | 归档前校验 Git worktree 登记状态；失效残留目录需确认后才移到废纸篓 |
| 2026-07-28 | UI 改为 Muxy 风格 `ProjectRail`（48pt）；宽 `SidebarView` 下线；worktree 经 popover/右键管理 |
| 2026-07-29 | Project Rail 切回项目时恢复该 root 最近选择的 main/worktree |
| 2026-07-30 | Project Rail 与 Project Session List 共用按 worktree ID 的归档 in-flight guard，阻止同一 worktree 重复归档 |
| 2026-07-31 | worktree 创建上移 `ProjectStore.createWorktree`（rail / session list 共用同一 in-flight guard 与失败弹窗）；`branchPrefix` 缺失时禁用入口而非回落 `dev`；删除已下线的 `SidebarView` / `ProjectsSection` / `TerminalsSection`；分支行与 worktree 行合并为单个 `SessionRow` |
| 2026-07-31 | 归档 worktree 时未提交检查失败改为 fail-closed（取消归档并提示），不再在未知状态下执行 `git worktree remove --force` |
| 2026-07-31 | 删除项目 monogram 的右键菜单——它是从旧宽侧边栏沿用的交互，与 rail popover 重复承载同一批动作（Open Main / Worktrees / Create Worktree / Reveal / Remove），popover 已全部覆盖。代价：对未选中的项目需先点选再点开 popover，不能一步右键直达 |
