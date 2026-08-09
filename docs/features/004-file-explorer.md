# FEAT-004: 文件浏览器

> 状态：✅ Done | 创建日期：2025-12-20 | 完成日期：2026-03-10

---

## 1. 功能概述

NSOutlineView 驱动的文件树 + 模糊搜索 Quick Open + 文件预览 + Git 状态标注 + 文件操作（复制/剪切/粘贴/删除/重命名）。

## 2. 用户流程

### 文件树
1. 项目切换时自动扫描（浅扫描 ~1ms，后台全量扫描带 gitignore）
2. 目录按需展开（lazy scan），避免初始加载大型项目卡顿
3. 文件名旁显示 Git 状态标记（A/M/D/R/U），目录继承最高优先级子文件状态

### Quick Open
1. Cmd+P 打开搜索面板
2. 输入关键字，模糊匹配文件名（支持路径回退搜索）
3. 方向键选择，Enter 打开文件

### 文件操作
- Cmd+C 复制 / Cmd+X 剪切 / Cmd+V 粘贴
- Delete 移入废纸篓
- 右键重命名

### 编辑器 Tab 恢复
1. 每个项目独立记录已打开文件 tab 路径与当前 active tab
2. App 重启或切回项目时按磁盘当前内容重新加载文件
3. 不持久化未保存的编辑缓冲区；项目/worktree/free terminal 上下文变更前同步执行 dirty tab auto-save
4. Right Dock 折叠时 `FileExplorerView` 仍常驻，当前 tabs、dirty buffer 与 editor session 不会因折叠销毁

## 3. 技术实现

### 3.1 数据结构

```swift
struct FileExplorerNode: Identifiable, Hashable {
    let id: String      // 绝对路径
    let url: URL
    let name: String
    let isDirectory: Bool
    let gitState: FileGitState?
    let children: [FileExplorerNode]?  // nil = 未扫描（lazy）
}
```

### 3.2 扫描策略

1. **浅扫描**（maxDepth=1）: 项目打开时立即执行，展示顶层目录结构
2. **全量扫描**: 后台线程递归扫描，注入 gitignore + git status
3. **扫描边界**: 嵌套 Git repo/worktree 与常见依赖/构建目录只保留目录节点，避免打开 `~/.openowl/workspace` 时递归索引所有子项目
4. **按需展开**: `expandDirectory()` 用户展开目录时单独扫描该目录
5. **缓存**: `projectScanCache` 按项目路径缓存，切换项目时即时恢复
6. **尾随刷新**: 扫描进行中再次收到 watcher 或手动刷新请求时记录一次待刷新；当前扫描结束后立即补跑，避免互斥窗口内的文件变化被丢弃
7. **项目切换隔离**: 切换项目时立即清空旧 `currentGitContext`；目标项目无缓存时同步清空 `searchableFileNodes`，Quick Open 在新项目扫描完成前不会展示或打开旧项目文件
8. **浅扫描提交门禁**: 浅层扫描结束、写入 `rootNodes` / `nodeIndex` 前核对启动扫描时捕获的 `projectURL`；切换项目后才结束的旧扫描不得覆盖新项目 UI

### 3.3 Git 状态映射

```
classifyGitState: GitFileChange → FileGitState
  U → conflicted | D → deleted | R/C → renamed
  A/?/untracked → added | M/T → modified
```

目录状态 = `mergeGitState` 递归合并子文件状态（取最高优先级）。

### 3.4 模糊搜索算法

`fuzzyMatch(name:path:query:)`:
1. 先对文件名做模糊匹配（字符按序出现即可）
2. 评分因子：精确匹配 +1000、前缀 +600、连续匹配 +8、词首 +12、早期位置 +10、深度惩罚 -3/层
3. 回退：文件名不匹配时尝试路径子串匹配（得分较低）
4. 返回 Top 50 结果

### 3.5 忽略规则

- **硬编码隐藏**: `.git`, `.DS_Store`, `.build`, `DerivedData`, `ghostty-resources`, `GhosttyKit.xcframework`
- **硬编码懒加载**: `node_modules`, `.pnpm`, `.next`, `.turbo`, `.cache`, `dist`, `build`, `coverage`, `.expo`, `.vercel`, `.netlify`, `.parcel-cache`, `.svelte-kit`, `.nuxt`, `Pods`, `.gradle`, `target`, 以及包含 `.git` 标记的嵌套 repo/worktree
- **gitignore**: 通过 `git ls-files --others --ignored` 获取，压缩冗余前缀（`compactDirectoryPrefixes`）

### 3.6 编辑器 Session 持久化

- 存储位置：`UserDefaults` key `openowl.fileExplorer.editorSessions.v1`
- 命名空间：项目根目录标准化绝对路径
- 内容：最多 10 个打开文件路径 + active file path
- 恢复：过滤不存在路径、目录、无法取得 size 的文件，以及不允许自动读取的文件。普通文本 `>= 50 MB` 不自动 restore/reload；图片 `> 50 MB` 不读取（恰好 50 MB 仍允许）
- `fileSize(for:)` 与磁盘签名中的 size 缺失时返回 `nil`，不再以 `0` 绕过大文件与图片上限
- 已打开 tab 记录磁盘签名（mtime + size + inode/fileIdentifier）；重复打开或切回 tab 时，非 dirty tab 会按磁盘当前内容刷新，dirty tab 不覆盖用户未保存编辑
- **所有读取失败走同一个收尾** `failFileRead(_:closingTab:reason:message:)`。open / restore / reload × 图片 / 文本共 8 条失败路径此前各写各的，已漂移出三种契约（一种报错、一种静默关 tab、一种让 spinner 永转）。统一后的规则：
  - open（`closingTab: true, persistRemoval: true`）：失败 tab 从内存和已保存 session 一并移除
  - restore（`closingTab: true, persistRemoval: false`）：失败 tab 只从本次内存恢复结果移除，保留已保存 session，供下次启动/切回项目重试
  - reload（`closingTab: false`）：tab 已有可用内容，只停止假装刷新成功
  - 失败 URL 持有 pending activation 时同时结束 `isEditorLoading`，避免现有编辑器被 overlay 持续遮挡
  - **所有读取失败都不推进 `tabDiskSignatures`** —— 推进等于标记「已与磁盘同步」，会让 `reloadOpenTabFromDiskIfNeeded` 永久跳过该 tab，一次瞬时解码失败会让文件到重启前都是陈旧的
- **打开失败不落地空缓冲区**：权限被拒、文件在 stat 后被删、内容非 UTF-8 都会关闭该 tab 并报错。若代之以空字符串，磁盘签名校验仍会通过（磁盘没变），用户会看到一个可编辑的空文档，首次 ⌘S 就把原文件截断
- **上下文变更先否决、后执行**：`ProjectStore` 在项目/worktree/free terminal 切换或删除的任何副作用前同步调用 editor preflight；auto-save 失败则整个 action 不发生，不会先切换 `activeProjectID` 或 terminal namespace 再恢复旧状态。`activeKind` 监听覆盖 free terminal A → B
- **异步 worktree 操作分阶段审批**：创建 worktree 在首个 Git 副作用前审批；Git 成功后先把新 worktree 登记为 inactive，实际激活时再次审批。归档 active worktree 则在任何 `await` / Git 副作用前审批并切到 parent，归档 in-flight 期间禁止重新激活
- **三个保存出口共享签名冲突否决**：⌘S、关闭 dirty tab、上下文变更前 save-all 都调用 `saveTab`；磁盘签名与打开时不一致或无法取得签名时拒绝覆盖，保留 dirty buffer
- **关闭 tab 时保存失败则不关闭**：dirty tab 的 buffer 是用户编辑的唯一副本，写盘失败或 storage 已被驱逐时弹窗并保留 tab。关闭 active tab A 后自动选择相邻 tab B，并通过正常 `switchToTab` / reload 流程核验 B 的磁盘内容
- **错误横幅在两种布局下都渲染**：`errorBanner` 同时挂在 tree panel 与 editor-only panel。此前它只在 tree panel 内，而 editor-only 恰是长时间编辑、最可能触发保存失败的模式，错误对用户完全不可见
- **未保存名称按 editor/window 隔离聚合**：每个 `FileExplorerView` 以自己的 token 发布 dirty tab 名称；view disappear 只移除该 token，不会清空其他窗口的数据。`AppDelegate` 读取 flattened、sorted 的计算结果，并与终端确认合并成一个退出提示；dock 折叠不会触发 view disappear
- 磁盘 reload 提交的是**新的** `NSTextStorage`，不改写编辑器持有的那个：直接 `replaceCharacters` 会绕过 `TextView.replaceCharacters`，让 `CEUndoManager` 保留指向旧内容的 range，后续 undo 会重放越界 range 抛出无法 catch 的 `NSRangeException`
- 编辑器的 SwiftUI identity 是 `ObjectIdentifier(storage)`——跟随 **storage 对象是否被替换**，而不是磁盘状态。**不要改回磁盘签名**：`write(to:atomically:true)` 会替换 inode，所以每次 ⌘S 签名都会变，编辑器会被重建、`setTextStorage` 随之 `clearStack()` 清空撤销历史（见测试 `fileEditorDiskSignature_changesForOwnAtomicSaveOfSameLengthContent`）。reload 换对象 → 重建（光标夹取后恢复）；save 不换对象 → 编辑器原地存活
- 每个 URL 的异步读取使用独立 request identity，并携带 project session generation 与读取前磁盘签名；提交结果前再次核验 request、session 与磁盘签名，过期读取不会覆盖较新内容
- 打开/恢复/reload 的 pending activation 与读取身份分离；一个文件的 reload 完成不会清除另一个文件的待激活状态
- 只有 reload（storage 对象被替换）才重建编辑器视图，光标位置按新 buffer 长度夹取后恢复；scroll 与 focus 不跨 reload 保留 —— 这是不触发 undo 越界崩溃的代价。保存不重建，编辑器交互状态完整保留
- 日志：`[file-editor-state]` 记录 `persist` / `restore` / `restore-skip` / `clear`

## 4. 注意事项

- NSOutlineView 比 SwiftUI List 性能好得多（支持 10k+ 节点零卡顿）
- 文件预览限制 160KB，检测二进制文件（null byte 检测）
- 剪切操作通过 UserDefaults flag 标记，粘贴时判断是复制还是移动
- 目录树变更通过 FileWatcher 自动刷新
- Editor tab session 只保存路径和 active tab，不持久化文件内容本身；内存中的 tab 内容通过磁盘签名判断是否需要刷新

## 5. 相关需求

- [REQ-003: 文件浏览器](../requirements/REQ-003-file-explorer.md)

## 6. 更新记录

| 日期 | 说明 |
|------|------|
| 2026-08-09 | 项目切换立即清理旧 Git context 与无缓存目标的 Quick Open 数据；浅扫描提交结果前核对 captured project URL，阻止旧项目扫描覆盖新项目 UI，并新增跨项目 Quick Open 回归测试 |
| 2026-08-09 | 文件树刷新采用尾随刷新语义：扫描进行中收到的新请求不会直接丢弃，而是在当前轮完成后立即补跑一次 |
| 2026-08-09 | FileWatcher 事件新增 editor revision 通知；所有已打开且未编辑的 tab 会按磁盘签名立即 reload，不再等切换 tab 才更新 |
| 2026-08-04 | 文件树/编辑器分隔条的 `DragGesture` 补上 `coordinateSpace: .global`。分隔条夹在两个面板之间，拖宽文件树会带着分隔条一起右移，`.local` 的坐标原点跟着走、每帧把 translation 抵消掉，拖动因此原地振荡。RightDock 的宽度手柄早修过同款问题并留了注释，这处漏改 |
| 2026-08-01 | `EditTracker.destroy()` 不再清空 `controller`——单个 tracker 被所有 tab 的编辑器共用，而 SwiftUI 在 `.id(storage)` 重建时先注册新 controller、后拆卸旧的，清空会把活着的实例置 nil，使 `relayout()` 此后永久静默失效（软换行宽度再也修不上）；`controller` 是 weak，无需手动清 |
| 2026-08-01 | 文件树 outline 选中改用 `AccentBarTableRowView`（accent 左竖条 + 浅色圆角底），与 SwiftUI `selectableRowChrome` 共用 `SelectableRowMetrics`，去掉系统蓝高亮 |
| 2026-07-31 | 上下文切换/删除改为副作用前同步 editor preflight；补齐 dock 折叠常驻、三保存出口签名冲突否决、tab 关闭后正常切换/reload、自动读取上限、open/restore 失败持久化差异与 unsaved names 生命周期 |
| 2026-07-31 | `fileSize(for:)` 改返回 `Int?`——`?? 0` 会同时废掉 large-mode、50MB 确认框和图片上限三道保护；未知大小改为按大文件保守处理 |
| 2026-07-31 | 8 条读取失败路径统一到 `failFileRead`（此前三种契约互不一致）；关 tab 保存失败不再销毁 buffer；错误横幅在 editor-only 模式也渲染；⌘Q 增加未保存守卫；`saveAllDirtyTabs` 元组改具名 `SaveFailure` |
| 2026-07-31 | 修 `6c52eda` 回归：编辑器 identity 从磁盘签名改为 `ObjectIdentifier(storage)`——原子保存会换 inode，旧写法导致每次 ⌘S 重建编辑器并清空撤销栈；补测试固化该事实 |
| 2026-07-31 | 打开失败不再折叠成空缓冲区（避免 ⌘S 截断原文件）；切项目保存失败时保留脏标记与 tab 并弹窗；磁盘 reload 改为提交新 `NSTextStorage` + 签名折进编辑器 identity，修复 undo 越界崩溃并保留光标 |
| 2026-07-30 | 编辑器异步读取增加 request/session/磁盘签名提交门禁，隔离 pending activation，并以原地刷新保留编辑器交互状态 |
| 2026-06-25 | 已打开 editor tab 增加磁盘签名刷新，修复外部修改后内容不更新 |
| 2026-06-05 | 新增按项目 editor tab session 持久化与 file-editor-state 日志 |
| 2026-05-07 | 全量扫描新增嵌套 repo 与依赖/构建目录懒加载边界，避免 workspace 级目录占用 GB 级内存 |
| 2026-03-16 | 创建文档 |
