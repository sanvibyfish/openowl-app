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
4. **Worktree**: 再次点击**已选中**的项目图标 → 弹出 popover，可切 main / worktree、创建 worktree；或右键菜单
5. **移除项目**: 右键 / popover → Remove（只从列表移除，不删磁盘文件）
6. **归档 worktree**: popover 内 worktree 行右键 → Archive Worktree
7. **状态感知**: Claude incident 时 rail 底部黄三角；点击打开 status 页，右键可 dismiss

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
- 路径已经不存在：直接清理侧边栏中的失效记录
- 路径存在但未登记：不再调用 `git worktree remove`；提示用户选择将残留目录移到废纸篓或保留

Project Rail popover 与 Project Session List 的归档入口共享 `ProjectStore` 中按 worktree ID 记录的 in-flight guard。相同 worktree 的重复归档会在业务入口拒绝，菜单显示 `Archiving...` 并禁用；不同 worktree 可独立归档。成功、失败或用户取消后都会释放 guard，允许后续重试。

只有 Git 删除成功、路径确认不存在，或用户明确将残留目录移到废纸篓后，才会从 openOwl 项目列表移除。失败或选择保留时继续保留侧边栏条目，避免界面状态与磁盘/Git 状态不一致。

### 3.4 分支前缀

`branchPrefix` 用于 `BranchNameGenerator` 生成分支名（如 `sanvi/calm-vale`）。
- 自动检测: 解析 `git remote get-url origin` 提取 GitHub 用户名
- 回退: `NSFullUserName()` 转小写去空格
- 缓存在 ProjectItem 上，persist 后不再重复检测

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

worktree 的创建与归档流程都住在 `ProjectStore`，rail 和 session list 只调用它 —— 两处都提供同一操作，各自持有进行中状态会让并发的 `git worktree add` 撞上 `index.lock`。

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
- 有 terminal bell 时 monogram 角标显示未读数
- 有 open tab 的 root 排在前面；未打开的 root 半透明

## 4. 注意事项

- 项目顺序：root 保持 `ProjectStore` 持久化顺序；rail 仅把「本 session 有 tab 的 root」提到前面
- 从 Project Rail 切回某个 root 时，恢复该 root 最近一次选中的 main/worktree；用户明确切回 main 后，后续继续保持 main
- 删除根项目时同时移除所有子 worktree

## 5. 相关需求

- [REQ-006: Claude 状态 Sidebar 指示器](../requirements/REQ-006-claude-status-sidebar.md)
- [FEAT-008: Right Dock](008-right-dock.md) — 右侧 inspector，与左 rail 对称

## 6. 更新记录

| 日期 | 说明 |
|------|------|
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
