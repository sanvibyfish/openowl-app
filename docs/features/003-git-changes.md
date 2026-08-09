# FEAT-003: Git 变更面板

> 状态：✅ Done | 创建日期：2025-12-15 | 完成日期：2026-03-10

---

## 1. 功能概述

完整的 Git 工作流面板：文件变更列表、暂存/取消暂存、提交、Diff 查看、分支管理、远程操作（fetch/pull/push）、Git Graph 日志。

## 2. 用户流程

### 暂存与提交
1. 查看 Staged / Changes / Untracked 三个分区的文件列表
2. 点击文件查看 diff
3. Stage / Unstage 单个文件或全部
4. 输入 commit message（或点击 AI 生成）
5. 点击 Commit（未暂存时自动 stage all）

### 分支管理
1. 下拉切换分支（checkout）
2. 输入名称创建新分支
3. 删除分支（支持 force）

### 远程操作
- Fetch / Pull（rebase + autostash）/ Push

### Git Graph
- 分页加载提交日志（每页 50 条）
- 显示 hash、message、author、date、refs
- 点击 commit 会在该行下展开本次修改的文件名，并显示 M/A/D/R 状态；再次点击同一 commit 收起
- 点击展开的文件名会在右侧 commit diff 中定位并展开对应文件
- 修改文件列表以 Git Graph 的 commit 展开区域为唯一入口；右侧仅显示全宽 commit diff，不再重复占用空间显示文件侧栏或 `Toggle file list` 控件
- 右键 commit 可通过 `Copy Commit ID` 复制完整 commit hash
- 列表底部保留一行高度的留白，使历史最后一条（包括 root commit）完整可见且可点击
- 选中 commit 后，右侧 diff 明确区分加载中、正常 patch、空 patch 与加载失败

## 3. 技术实现

### 3.1 架构

```
GitChangesStore (@MainActor)
  ├── GitService (async git CLI wrapper)
  ├── FileWatcher (监听 .git 目录变更)
  └── CommitMessageGenerator (AI 生成 commit message)
```

### 3.2 Git CLI 封装

`GitService` 通过 `Process` 调用 `/usr/bin/env git`，关键细节：
- **管道读取顺序**: 先读 stdout/stderr 再 `waitUntilExit()`，避免 64KB 管道缓冲区满导致死锁
- **状态解析**: `git status --porcelain=v1 --branch` → `parseStatus()` 解析分支、upstream、ahead/behind、文件变更
- **路径解码**: `GitService.decodeGitPath()` 统一处理 Git C 风格 quoted path（引号、反斜杠与 UTF-8 八进制转义）；status 与 commit diff 文件拆分复用同一逻辑，中文/非 ASCII 路径不会退化为 `unknown`

### 3.3 实时刷新

`FileWatcher` 监听项目目录（FSEvents），0.3s debounce 后触发 `refresh()` → 重新加载 status + diff + branches + log。

- 刷新进行中收到的新请求会被合并为一次尾随刷新：当前刷新完成后立即再执行一次，避免 watcher 事件落在互斥窗口内而丢失
- 快速切换项目或 worktree 时，仓库打开请求以 request ID 标识；新请求会使旧请求失效，已取消或过期的 `repositoryRoot()` 结果不得替换当前仓库
- 切换到新仓库时，旧仓库的 status、log、工作区/commit 选择与详情状态会在新服务生效时原子清空；打开非 Git 目录失败时同时移除旧 `GitService` 与上述状态，后续 `refresh()` 不得恢复旧仓库数据
- `setPreferredDirectory()` 切换到当前仓库之外的目标时会取消旧的 “Open Changes” diff 任务，避免旧文件选择在新项目中继续执行
- status、log 与工作区 diff 的异步结果写入状态前，必须确认发起请求的 `GitService` 仍是当前实例，防止旧仓库结果覆盖新项目的分支、changes 或 diff
- status 列表更新后，工作区多选集合会裁剪到仍存在的 change ID；range selection 的锚点失效时同步清空
- 从工作区 diff 切换到 commit 时清空工作区多选与 range selection 锚点，避免隐藏选择在返回工作区后继续影响批量操作

### 3.4 Git Graph 分页一致性

- 同一 `GitService` 同时只允许一个加载更多任务；`LazyVStack` 底部 sentinel 连续触发 `onAppear` 时，后续相同 `skip` 请求直接忽略，避免重复追加同一批 commit
- 仓库切换会重置分页任务的服务身份；旧任务结束时只清理自己的身份，不得解除新仓库的分页互斥
- 刷新/reset 会递增 log generation，旧 generation 的分页成功或失败结果均不得写回；刷新期间不启动加载更多，避免 reset 与分页交错造成错页或缺页
- `GitService.log()` 只移除 record 前导空行，不裁剪尾部字段；root commit 的空 `%P`（parents）仍保留为第七字段并解析为 `[]`
- `GitGraphContentView` 在列表末尾增加一个 `graphRowHeight` 的底部 padding，避免最早一条提交被面板底边裁掉或无法点击
- 选中的 commit 行下使用 `commitFiles` 展开 M/A/D/R 状态与 `lastPathComponent` 文件名；详情加载期间仅显示一行 `Loading changed files…`，`CommitRow` 的 chevron 表示展开状态
- 展开区域的高度同时计入 Canvas 总高度及后续 commit 节点的纵坐标偏移，泳道跨过文件行后仍与下一节点对齐
- 点击展开文件会设置 `selectedCommitFilePath`、解除该文件的折叠状态并更新 `scrollTarget`，使右侧 commit diff 滚动到对应文件
- 右侧 commit diff 不再渲染重复的文件侧栏与显隐按钮，按文件拆分的 diff 使用全部可用宽度；Graph 中的文件点击仍沿用 `selectedCommitFilePath` 与 `scrollTarget` 定位右侧 section
- `CommitRow` 的右键菜单将完整 `entry.hash` 写入系统剪贴板

回归覆盖：`GitChangesStoreTests.repeatedLoadMoreRequestsDoNotDuplicateCommits` 在含 55 个 commit 的临时仓库中连续触发 3 次加载更多，最终必须得到恰好 55 个唯一 hash，并同时覆盖 root commit 未被日志解析遗漏；测试仓库的 root commit 新增 `root.txt`，选择该提交后还会验证文件列表为 `root.txt` 且 patch 包含 `+root content`。

交互验收：定向 `GraphLayoutTests` 与 `GitChangesStoreTests` 共 11 tests / 2 suites 通过；Debug UI 确认首个 commit 展开 4 个文件、点击 `project.yml` 后右侧定位到该文件、再次点击 commit 收起、右键执行 `Copy Commit ID`，且右侧不再出现 `Toggle file list`、diff 使用全部可用宽度，展开区域内泳道与后续节点保持对齐。完整回归为 388 tests / 34 suites。

### 3.5 Diff 展示

选中文件后异步加载 diff：
- Staged: `git diff --staged -- <path>`
- Modified: `git diff -- <path>`
- Untracked: `git diff --no-index -- /dev/null <path>`

Commit diff 使用独立的详情状态，不以空字符串同时表示“尚未返回”“没有变更”和“加载失败”：

- `GitService.commitFiles()` 使用 `git diff-tree --root`，使无 parent 的 root commit 也能返回首次提交引入的文件、文件计数与 patch
- `isLoadingCommitDetail` 为 true 时，header 显示 `Loading commit`，内容区显示 spinner 与 `Loading commit diff`
- 请求成功且 patch 非空时，显示按文件拆分的正常 diff
- 请求成功但 patch 为空时，header 显示 `No changes`，内容区显示 `No changes in this commit`
- 请求失败时，`commitDetailErrorMessage` 保存失败原因；header 显示 `Diff unavailable`，内容区显示 `Could not load commit diff` 与具体原因
- 选择 commit、切回工作区文件或切换仓库时会清理上一请求的 loading / error；旧 commit 任务的 `defer` 仅能结束自身 hash 的 loading，不能提前结束新选择的加载态
- `selectedCommitHash` 变化时清空上一提交的文件折叠集合、侧栏文件选择与滚动目标，并以 commit hash 标识 diff 容器；新提交的 diff 从顶部开始，不沿用上一提交的折叠、选中或滚动位置
- `splitDiffByFile()` 支持 `diff --git "a/..." "b/..."` 形式的 quoted header，并通过 `GitService.decodeGitPath()` 还原 UTF-8 八进制转义后的文件路径

回归覆盖：`GitChangesStoreTests.repeatedLoadMoreRequestsDoNotDuplicateCommits` 在分页断言之后选择空 commit，验证 loading 结束、patch 为空且无错误；随后选择不存在的 commit，验证 loading 结束并记录详情错误。

路径解析回归覆盖：`SplitDiffByFileTests.quotedNonASCIIPath_parsedCorrectly` 使用八进制 UTF-8 编码的 `中文.swift` quoted header，验证 commit diff 能按正确文件名拆分。Debug UI 验收还确认 commit A 滚动后切换到 B/C，有 diff 的新提交滚动条回到顶部。

仓库失效回归覆盖：`GitChangesStoreTests.failedRepositoryOpenClearsPreviousRepositoryState` 先打开含 status 与 log 的真实 Git 仓库，再打开非 Git 目录，验证仓库 URL、status、log 与分页状态被清空；随后再次调用 `refresh()`，旧仓库数据仍不得恢复。

## 4. 注意事项

- `runCommand()` 包装所有异步操作，确保 `isRunningCommand` 互斥锁防止并发冲突
- Discard 操作区分 modified（git restore）和 untracked（git clean）
- Commit 使用临时文件传递 message（`--file`），避免 shell 转义问题

## 5. 相关需求

- [REQ-002: Git 变更](../requirements/REQ-002-git-changes.md)

## 6. 更新记录

| 日期 | 说明 |
|------|------|
| 2026-08-09 | 切换新仓库时原子清除旧 status/log/选择/详情，打开非 Git 目录失败时移除旧 `GitService`，防止后续 refresh 恢复旧数据；Git Log 展开文件名作为唯一文件入口，右侧移除重复文件侧栏与 Toggle 控件并改为全宽 diff。新增失败仓库切换回归；定向 11 tests / 2 suites、完整 388 tests / 34 suites 与 Debug UI 验收通过 |
| 2026-08-09 | Git Graph 支持点击 commit 展开 M/A/D/R 文件名、再次点击收起，点击文件定位右侧 commit diff，并可从右键菜单复制完整 Commit ID；Canvas 高度与后续节点坐标同步避让展开区域。定向 10 tests / 2 suites、完整 387 tests / 34 suites 与 Debug UI 交互验收通过 |
| 2026-08-09 | commit 切换会重置文件折叠、侧栏选择和滚动目标，并以 commit hash 重建 diff 容器，避免沿用上一提交的视图状态；commit diff 文件拆分复用 `GitService.decodeGitPath()`，正确解析 quoted UTF-8 八进制路径。新增 `quotedNonASCIIPath_parsedCorrectly`；定向 31 tests / 2 suites、完整 385 tests / 34 suites 与 Debug UI 滚动归顶验收通过 |
| 2026-08-09 | Git Graph 列表增加一行高度的底部留白，确保最后的 root commit 完整可见且可点击；`commitFiles()` 的 `git diff-tree` 增加 `--root`，root commit 文件列表、计数和 patch 正确返回。扩展真实 root commit 回归断言；定向测试 3/3、完整测试 384 tests / 34 suites 通过，并完成 Debug UI 验收 |
| 2026-08-09 | commit diff 增加独立 loading/error 状态：右侧 header 与内容区明确区分加载中、正常 patch、空 commit 和加载失败；选择变化与仓库切换会清理旧状态，旧任务只能结束自身 hash 的 loading。扩展 `repeatedLoadMoreRequestsDoNotDuplicateCommits` 覆盖空 commit 成功与 missing commit 失败 |
| 2026-08-09 | Git Graph 加载更多按 `GitService` 串行化，刷新/reset 通过 generation 使旧分页结果失效且刷新期间禁止分页；日志 record 保留 root commit 的空 parents 字段。新增 55 commits / 连续 3 次加载更多回归测试，验收结果为 55 个唯一 hash |
| 2026-08-09 | 仓库切换增加异步所有权门禁：request ID 与 Task cancellation 阻止旧 `openRepository` 提交，目标目录变化会取消旧 `openDiff`；status、log、工作区 diff 仅允许当前 `GitService` 写入，保证快速切换项目/worktree 后项目、分支、changes 与 diff 一致 |
| 2026-08-09 | 刷新互斥改为尾随刷新语义，刷新期间到达的 watcher/手动请求会在当前轮结束后立即补跑一次；status 更新会裁剪失效的工作区多选，切到 commit 时清空工作区多选与 range selection 锚点 |
| 2026-08-09 | 切换变更文件或从工作区 diff 切到 commit 时立即清空上一份 diff，避免新标题下短暂或永久展示旧内容 |
| 2026-08-09 | Files 的 “Open Changes” 将仓库初始化与目标文件选择合并为一次操作；切换到 Git tab 随后触发的同仓库同步不再清空已选 diff |
| 2026-08-01 | 「展开未修改行」限定到工作区 section：`.staged` 的 diff 是 HEAD vs index，而上下文从磁盘读取——磁盘副本可能领先于 index，会把未暂存的改动当作已暂存的上下文呈现在用户决定提交内容的地方。`.untracked` 无基线可展开 |
| 2026-08-01 | commit diff 恢复 hunk 分隔条：此前「禁用展开」误把分隔条一起去掉，两个 hunk 上下紧贴、行号突然跳跃却无任何提示。现在不可展开时渲染为静态条 |
| 2026-08-01 | 磁盘副本短于 diff 预期时明确提示「文件已变化」，不再逐行填空字符串（会渲染成带真实行号的空行，与文件里真正的空行无法区分）；`.failed` 携带具体错误并就地渲染为可重试行，不再借用会被 `refresh()` 清空的全局 error banner；过期的异步读取直接返回，不再把新选择的 `.loading` 覆盖成 `.idle` |
| 2026-08-01 | **commit diff 不再提供「展开未修改行」**：该功能从磁盘读当前工作区文件填充上下文，对历史提交是错误的数据源（正确来源是 `git show <hash>:<path>`），且 `hunkIndex` 每个文件从 0 重数会与共享的 `expandedHunks` 串台，删除文件的 hunk 还会让 `ForEach(1..<0)` 崩溃。工作区 diff 的展开不受影响 |
| 2026-08-01 | `parseUnified` 三处解析修正：diff 尾部换行不再产生幽灵空 context 行；`\ No newline at end of file` 不再当正文渲染（它此前还推高 `prevNewEnd`，使后续 hunk 少算一行）；展开行的旧行号改由 hunk 的 old/new 起点偏移推算，不再直接复用新行号 |
| 2026-08-01 | Right dock Diff 改为默认 **unified（单栏）+ 长行 wrap**（对齐 VS Code / GitHub 窄栏惯例）；去掉 side-by-side 半宽与按最长行撑开的横向滚动 |
| 2026-03-16 | 创建文档 |
