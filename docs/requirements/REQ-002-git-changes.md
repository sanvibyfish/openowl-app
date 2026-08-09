# REQ-002: Git 变更管理

## 概述

简易 Git 管理面板，支持查看变更、Stage/Unstage、提交、查看 Diff。

## 核心需求

### P0 — 基础 Git 操作

- [x] Git 状态获取：通过 `Process` 调用 `git status --porcelain=v1`
- [x] 变更分组：Staged Changes / Changes (Modified) / Untracked
- [x] Stage/Unstage：单文件和批量操作 (`git add` / `git restore --staged`)
- [x] 提交：多行 commit message，Cmd+Enter 快捷键
- [x] Auto-stage：如果没有 staged 文件，提交时自动 stage 所有变更
- [x] Stage All 必须使用 `git add -A` 覆盖完整仓库，不依赖当前展示或缓存的 status 列表
- [x] 未诞生分支取消暂存必须清空 index 并保留工作树；已有 HEAD 时恢复 index 到 HEAD
- [x] `UU/AA/DD/AU/UA/DU/UD` 冲突文件只进入 Changes，`MM` 同时按 index/worktree 两侧进入 Staged 与 Changes

### P0 — Diff 视图

- [x] Unified diff 渲染（绿色加/红色减）
- [x] 点击文件展开 diff
- [x] 文件内容预览（语法高亮）
- [x] 切换到 commit 时清空工作区多选与 range selection 锚点
- [x] Git status 更新后裁剪已不存在文件的选择与失效锚点
- [x] Commit diff 必须区分加载中、正常 patch、成功但无 patch、加载失败四种状态
- [x] Root commit 详情必须列出首次提交引入的文件并显示对应 patch，文件计数不得为 0
- [x] Commit 详情失败必须在 diff 区展示具体原因，不能与空 commit 共用空状态
- [x] 切换 commit、工作区文件或仓库时必须清理旧详情状态；旧任务结束不得关闭新 commit 的 loading
- [x] 切换 commit 时必须清空上一提交的文件折叠、侧栏文件选择与滚动位置，新 diff 从顶部开始
- [x] Commit diff 必须解析 Git C 风格 quoted header，并正确还原 UTF-8 八进制转义的中文/非 ASCII 文件路径
- [x] Commit 修改文件列表以 Git Log 的展开区域为唯一入口；右侧不得重复显示文件侧栏或 `Toggle file list` 控件，diff 使用全部可用宽度
- [x] 工作区 diff completion 必须同时校验 request revision、当前文件 selection 与 repository service/context；旧文件的成功或失败结果不得覆盖新选择
- [x] untracked diff 仅把 `git diff --no-index` 退出码 0/1 视为合法结果，大于 1 必须显示错误
- [x] quoted rename 路径即使文件名包含 ` -> ` 也必须正确解析 source/destination

Commit diff 验收文案：加载中为 `Loading commit diff`，空 patch 为 `No changes in this commit`，失败为 `Could not load commit diff`；header 分别显示 `Loading commit`、`No changes`、`Diff unavailable`。

自动化覆盖：`GitChangesStoreTests.repeatedLoadMoreRequestsDoNotDuplicateCommits` 选择 allow-empty commit 后断言 loading 正常结束、diff 为空且无详情错误；再选择不存在的 commit，断言 loading 结束并产生详情错误。

路径解析自动化覆盖：`SplitDiffByFileTests.quotedNonASCIIPath_parsedCorrectly` 模拟 `中文.swift` 的 UTF-8 八进制 quoted header，断言文件路径正确且不退化为 `unknown`。Debug UI 验收覆盖 commit A diff 滚动后切换 B/C，有 diff 的新提交滚动条回到顶部。

### P1 — 分支管理

- [x] 分支切换（dropdown selector）
- [x] 创建/删除分支
- [x] Pull / Push / Fetch
- [x] Ahead/Behind 显示
- [x] porcelain v1 的 unborn branch header `No commits yet on <branch>` 与旧 `Initial commit on <branch>` 必须解析为真实 `<branch>`；Right Dock 与状态栏不得显示整句 header
- [x] detached HEAD 的解析与显示行为保持不变

### P1 — Git Graph

- [x] 提交日志按每页 50 条分页加载
- [x] 点击 commit 必须在该行下展开其修改过的文件名及 M/A/D/R 状态，加载期间显示单行 loading；再次点击同一 commit 必须收起
- [x] 点击展开的文件名必须解除对应 diff 文件的折叠状态，并将右侧 commit diff 滚动到该文件
- [x] 移除右侧文件侧栏后，Git Log 中展开文件的点击定位能力必须保持不变
- [x] commit 文件展开区域必须计入 Graph Canvas 高度与后续节点坐标，泳道跨越展开区域后仍与后续 commit 节点对齐
- [x] commit 行右键菜单必须提供 `Copy Commit ID`，并复制完整 commit hash
- [x] 同一仓库的加载更多请求必须串行化；底部 sentinel 重复出现不得以相同 `skip` 重复追加 commit
- [x] 刷新/reset 后，较早 generation 的分页结果不得写回；刷新进行中不得启动加载更多
- [x] 仓库切换后，旧分页任务结束不得清除新仓库的分页互斥状态
- [x] Git 日志必须使用 `git log -z` + `%x00` 的 NUL 协议，每条提交固定解析 hash、abbrev、subject、author、date、refs、parents 7 个字段，不得使用可能与提交内容碰撞的可见文本作为 record separator
- [x] 合法提交标题即使完整等于旧分隔文本 `---OPENOWL-RECORD---` 也必须原样显示
- [x] 日志解析必须保留空 refs 与 root commit 的空 parents 字段，使没有 parent 的 root commit 仍出现在 Git Graph；分页不得造成字段错位、提交遗漏或重复
- [x] 尚无提交的仓库必须在 Git Graph 显示 `No commits yet` 空态，不得因日志为空产生 error banner
- [x] Git Graph 底部必须保留一行高度的空间，使最早一条提交完整可见且可点击

验收覆盖：`GitChangesStoreTests.repeatedLoadMoreRequestsDoNotDuplicateCommits` 创建含 55 个 commit 的临时仓库，初始加载 50 条后连续请求 3 次加载更多；最终日志必须恰好包含 55 条记录且 55 个 hash 全部唯一。该测试还用真实 `root.txt` 验证 root commit 未因空 parents 字段而被丢弃、文件列表为 `root.txt`，且 diff 包含 `+root content`。Debug UI 验收确认列表最后一条提交完整可见。

日志协议自动化覆盖：`GitCommitParsingTests.log_preservesSubjectMatchingPreviousRecordSeparator` 验证标题完整等于旧 marker 的提交仍保留原 subject，并覆盖 NUL 字段协议下的空 refs、root commit 空 parents 与分页行为。定向 `GitCommitParsingTests` + `GitChangesStoreTests` 共 18 tests / 2 suites、完整 XCTest 396 tests / 34 suites 通过；SPM patch 已应用，`git diff --check` 通过。

未诞生分支自动化覆盖：`GitServiceParsingTests.parseBranch_unbornBranch` 覆盖新版与旧版 porcelain header 的真实分支名提取，`GitChangesStoreTests.emptyRepositoryReportsUnbornBranchName` 使用空仓库验证分支名、`No commits yet` Graph 空态与无 error banner。定向 26 tests / 2 suites、完整 XCTest 398 tests / 34 suites 通过；SPM patch 已应用，`git diff --check` 通过。

文件展开与复制验收：定向 `GraphLayoutTests`、`GitChangesStoreTests` 共 11 tests / 2 suites 通过；Debug UI 确认首个 commit 展开 4 个文件，点击 `project.yml` 后右侧定位到对应 diff，再次点击 commit 收起，右键菜单显示并执行 `Copy Commit ID`；右侧无 `Toggle file list` 且 diff 使用全部可用宽度，展开后泳道视觉对齐。完整回归为 388 tests / 34 suites。

### P2 — 增强

- [x] AI commit message 生成（调用本地 claude CLI）；进程句柄需同步并按实例清理，旧 termination 不得清除新任务句柄
- [x] Discard changes（with confirmation）
- [x] Discard All 将 tracked 工作树恢复到当前 index，保留 staged 内容，删除全部非 ignored untracked 文件与目录，并保留 ignored 内容

## 技术要点

### Git CLI 封装

```swift
final class GitService {
    let workingDirectory: URL

    func status() async throws -> GitStatusSnapshot
    func stage(files: [String]) async throws
    func unstage(files: [String]) async throws
    func commit(message: String, autoStageWhenNeeded: Bool) async throws
    func diff(for change: GitFileChange) async throws -> String
    func branches() async throws -> [String]
    func checkout(branch: String) async throws
    func createBranch(name: String, checkout: Bool) async throws
    func deleteBranch(name: String, force: Bool) async throws
    func fetch() async throws
    func pull() async throws
    func push() async throws
}
```

通过 `Process` 执行 git 命令，解析 stdout/stderr 输出。继续维持 git CLI 路线，避免 libgit2 复杂度。

### 文件监听

当前使用 `FSEvents` 监听工作目录变化，
300ms 防抖后自动刷新 git 状态，并忽略 `.git/`、`node_modules/` 目录事件。
刷新进行中到达的新请求必须在当前轮完成后触发一次尾随刷新，不能因 `isRefreshing` 互斥而丢弃 watcher 事件。

### 仓库切换一致性

- [x] Right Dock Git 仓库身份必须以 `GitService.repositoryRoot()` / `git rev-parse --show-toplevel` 返回的真实 root 为准，不得仅因目标路径位于当前仓库目录内就判定为同一仓库
- [x] terminal cwd 或 Files 的 “Open Changes” 进入 submodule / 嵌套 Git repository 时必须切换到内层仓库
- [x] preferred directory 位于当前仓库的普通子目录且解析到相同 root 时必须快速返回，并保留现有文件选择与 diff
- [x] `openDiff` 必须先按 `repositoryCandidateURL` 解析真实 repository root，再在解析后的仓库中选择目标文件
- [x] 快速切换项目或 worktree 时，只有最新的仓库打开请求可以更新当前仓库；已取消或过期请求的成功、失败结果均不得提交
- [x] preferred directory 切换到另一仓库时，取消尚未完成的文件 diff 打开任务
- [x] status、log、工作区 diff 的异步结果只有在其 `GitService` 仍代表当前仓库时才能写入 Store
- [x] 快速切换完成后，仓库路径、当前分支、changes 列表与 diff 必须来自同一仓库
- [x] 新仓库服务生效时必须原子清空旧 status、log、选择与 commit 详情状态，不能在异步刷新返回前短暂保留旧仓库内容
- [x] 打开非 Git 目录失败时必须移除旧 `GitService` 并清空旧状态；此后调用 `refresh()` 不得恢复旧仓库数据
- [x] 仓库切换意图发生时必须立即使旧 command、AI 与 diff completion 失效，不能等待异步 root 解析完成
- [x] 不同 repository root 的 commit draft 必须独立保存并在切回时恢复；同一真实 root 的普通子目录同步不得清空当前状态
- [x] 选择新 commit 时立即清理上一详情请求产生的全局错误，且来源/revision 校验不得清除更新的错误

自动化覆盖：`GitChangesStoreTests.preferredDirectorySwitchesFromOuterToNestedRepository` 验证从外层仓库目录进入嵌套仓库时切换到内层 root；`GitChangesStoreTests.cancelledRepositoryOpenCannotReplaceCurrentRepository` 验证取消的旧仓库打开请求不能替换当前仓库；`GitChangesStoreTests.failedRepositoryOpenClearsPreviousRepositoryState` 验证打开非 Git 目录后仓库 URL、status、log 与分页状态清空，后续 refresh 不会恢复旧数据。运行时验收覆盖 Debug UI 快速切换 worktree 后项目、分支与 changes 一致。本批定向 `GitChangesStoreTests` 为 5 tests / 1 suite，完整 XCTest 为 395 tests / 34 suites；SPM patch 已应用，`git diff --check` 通过。

## 已落地实现

- `GitChangesView`：变更分组列表、Stage/Unstage、Stage All/Unstage All、Discard/Discard All（确认弹窗）、Diff 面板（含轻量语法高亮）、Commit 面板
- `GitChangesStore`：仓库选择、状态刷新、提交后回刷、branch create/delete/checkout、fetch/pull/push、discard、错误/提示状态管理
- `GitService`：新增 `discardModified` (`git restore --worktree`) 与 `discardUntracked` (`git clean -f -d`)
- `FileWatcher`：FSEvents 目录事件 -> 忽略规则过滤 -> 防抖刷新
- 侧边栏新增 `Git Changes` 面板入口

## 更新记录

| 日期 | 说明 |
|------|------|
| 2026-08-09 | 增加仓库级 commit draft、切仓意图 generation、diff revision/selection、commit error provenance 与 AI Process identity 验收；补齐 `git add -A` Stage All、保留 staged 的 Discard All、unborn unstage、冲突分组、quoted rename arrow 与 untracked diff exit-code 契约。关联 GitChangesStore 10 tests、GitService 40 tests、CommitMessageGenerator 2 tests；完整 XCTest 416 tests / 35 suites 通过 |
| 2026-08-09 | 增加 unborn branch 验收：porcelain v1 的新版 `No commits yet on <branch>` 与旧版 `Initial commit on <branch>` 均只解析出真实分支名，空仓库 Git Graph 显示 `No commits yet` 且不产生 error banner，detached HEAD 行为不变。关联 `parseBranch_unbornBranch`、`emptyRepositoryReportsUnbornBranchName`；定向 26 tests / 2 suites、完整 398 tests / 34 suites 通过 |
| 2026-08-09 | Git Graph 日志验收改为 `git log -z` + `%x00` 的 NUL 协议并固定解析 7 字段；要求保留与旧 marker 同名的合法 subject、空 refs 与 root parents，分页不得造成错位或遗漏。关联 `log_preservesSubjectMatchingPreviousRecordSeparator`；定向 18 tests / 2 suites、完整 396 tests / 34 suites 通过 |
| 2026-08-09 | 仓库身份改为以 `repositoryRoot()` / `git rev-parse` 的实际 root 判定；增加 terminal cwd / Files Open Changes 进入 submodule 或嵌套仓库、同仓库普通子目录保持选择与 diff，以及 `openDiff` 先解析候选仓库 root 的验收。关联 `preferredDirectorySwitchesFromOuterToNestedRepository`；定向 5 tests / 1 suite、完整 395 tests / 34 suites 通过 |
| 2026-08-09 | 增加仓库服务切换时原子清空旧 status/log/选择/详情、非 Git 目录打开失败时移除旧服务且 refresh 不得恢复旧数据的验收；Git Log 展开文件作为唯一文件入口，右侧移除重复文件侧栏与 Toggle 控件并保持文件点击定位。关联 `failedRepositoryOpenClearsPreviousRepositoryState`，定向 11 tests / 2 suites、完整 388 tests / 34 suites 与 Debug UI 验收通过 |
| 2026-08-09 | 增加 Git Graph commit 文件名展开/收起、文件点击定位、展开区域泳道对齐与右键复制完整 Commit ID 的验收要求；定向 10 tests / 2 suites、完整 387 tests / 34 suites 及 Debug UI 验收通过 |
| 2026-08-09 | 增加 commit 切换视图状态隔离与滚动归顶验收，并要求 commit diff quoted header 复用统一路径解码、正确还原中文/非 ASCII 文件名；关联 `SplitDiffByFileTests.quotedNonASCIIPath_parsedCorrectly` |
| 2026-08-09 | 增加 Git Graph 末行可见/可点击与 root commit 文件详情验收；`commitFiles()` 需通过 `git diff-tree --root` 返回首次提交文件和 patch，关联 `GitChangesStoreTests.repeatedLoadMoreRequestsDoNotDuplicateCommits` |
| 2026-08-09 | 增加 commit diff 四态验收：loading、正常 patch、空 patch、失败原因分别呈现；切换选择/仓库会清理旧状态，旧任务不得结束新 hash 的 loading；关联 `GitChangesStoreTests.repeatedLoadMoreRequestsDoNotDuplicateCommits` |
| 2026-08-09 | 增加 Git Graph 分页一致性验收：加载更多按服务实例串行化、刷新 generation 淘汰旧分页结果、仓库切换隔离任务身份，并保留 root commit 的空 parents 字段；关联 `GitChangesStoreTests.repeatedLoadMoreRequestsDoNotDuplicateCommits` |
| 2026-08-09 | 增加仓库切换一致性验收：仓库打开请求失效/取消、旧 diff 取消，以及 status/log/working-tree diff 的当前 `GitService` 提交门禁；关联 `GitChangesStoreTests.cancelledRepositoryOpenCannotReplaceCurrentRepository` |
