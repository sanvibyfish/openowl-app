# FEAT-003: Git 变更面板

> 状态：✅ Done | 创建日期：2025-12-15 | 完成日期：2026-03-10

---

## 1. 功能概述

完整的 Git 工作流面板：文件变更列表、暂存/取消暂存、提交、Diff 查看、分支管理、远程操作（fetch/pull/push）、Git Graph 日志。

## 2. 用户流程

### 暂存与提交
1. 查看 Staged Changes 与 Changes 两个分区的文件列表（Changes 合并了 modified 与 untracked，untracked 以状态字母 `U` 区分）
2. 点击文件查看 diff
3. Stage / Unstage 单个文件或全部
4. 输入 commit message（或点击 AI 生成）
5. 点击 Commit（未暂存时自动 stage all）

### 分支管理（未实现）

Git Graph 工具栏当前只显示只读的分支名与 ahead/behind。切换分支、创建分支均无实现；删除分支的 service 与 store 方法存在，但确认动作 `GitConfirmationAction.deleteBranch` 从未被构造，没有可达的 UI 路径。

### 远程操作
- Pull（rebase + autostash）/ Push。Fetch 的 store 方法存在但未接入工具栏

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

`GitService` 通过 `Process` 调用固定解析的 git 二进制（`GitExecutable.resolvedPath`，候选顺序 `/usr/bin/git` → `/opt/homebrew/bin/git` → `/usr/local/bin/git`，启动时选择一次并写日志；三者都不可执行时 `resolvedPath` 为 nil，git 命令抛 `gitNotInstalled` 并提示安装 CLT，终端功能不受影响；不再回落 PATH），关键细节：
- **固定 git 路径**: 不再用 `/usr/bin/env git`——GUI 应用由 launchd 启动时的 PATH 不可控，可能解析到 Apple 旧版 git；固定路径保证行为可预期（2026-08-11 事故中实际跑的是 Apple Git 2.50.1）
- **status 串行化**: `git status` 按标准化 working directory 加锁（`GitCommandGate`），FileExplorer 与 Git 面板对同一仓库的 status 不会并发执行；diff/log 保持并发（它们不刷新 index，且必须避免被慢命令阻塞，如 FIFO 测试模式）
- **超时边界**: `git status` 与 `git show`（`fileData`）设置 30 秒超时；超时时先向真实 `Process` 发送 `SIGTERM` 并停止并发排空 stdout/stderr 的 `DispatchIO`，2 秒宽限后仍存活则 `SIGKILL`。diff/log/fetch/push 不套用该 30 秒上限
  - 升级不可省略：`waitUntilExit()` 位于 drain 的宽限期**之前**，子进程若忽略 SIGTERM 就会永久阻塞调用线程，对 `status()` 而言会连带锁死该仓库 gate lane 的全部后续请求
  - 后代 helper（`git fsmonitor--daemon`、hook、credential helper）继承管道写端并长期存活时，drain 等满宽限期后**返回已读数据并记日志**，不作为失败——子进程已退出，它写的内容均已送达
- **gate 回收**: `GitCommandGate` 以 token 确认当前 tail 所有权，正常返回、命令错误和超时都会清除完成的 tail，不在每仓库门禁中留下已结束任务
- **信号退出重试**: status/diff/log 如果被信号杀死（如并发写入者截断文件导致的 SIGBUS，内核报 `cluster_pagein past EOF`），自动重试一次（间隔 150ms），第二次通常成功；写操作（add/commit 等）不重试
- **管道读取**: stdout/stderr 通过 `DispatchIO` 并发排空，避免任一管道的缓冲区写满后阻塞子进程
- **DispatchIO fd 所有权（2026-08-19 修复）**: libdispatch 对 fd-based 通道**不会**在 `dispatch_io_close` 时自动关闭文件描述符——fd 由调用方持有，必须在通道的 cleanup handler 中显式 `close(descriptor)`。此前每次 git 启动泄漏 2 个 dup 读端 fd（独立复现 50 次启动 = 100 fd），应用连续运行约 37 小时后 fd 表耗尽（~10K fd，软上限 10240），此后**所有** git 子进程启动即 `Bad file descriptor`（EBADF），重试换新 pipe 无效——这是 Git 面板反复报该错误的根因。修复后独立复现 200 次启动 0 泄漏
- **状态解析**: `git status --porcelain=v1 --branch --untracked-files=all` → `parseStatus()` 解析分支、upstream、ahead/behind、文件变更
  - `--untracked-files=all` 会把未跟踪目录展开为逐个文件，这是 untracked 数量可能极大、进而触发下述 500 条上限的原因
  - untracked 超过 500 条时**静默截断**，`GitStatusSnapshot.untrackedTruncated` 置位，列表顶部显示常驻提示行。注意 Stage All 走 `git add -A`，作用于全部 untracked 而非仅列出的 500 条
- **未诞生分支**: porcelain v1 的 `## No commits yet on <branch>` 与旧版 Git 的 `## Initial commit on <branch>` 都解析为真实 `<branch>`；Right Dock 与状态栏只显示分支名，不显示整句 header。detached HEAD 继续沿用原有解析与显示行为
- **路径解码**: `GitService.decodeGitPath()` 统一处理 Git C 风格 quoted path（引号、反斜杠与 UTF-8 八进制转义）；status 与 commit diff 文件拆分复用同一逻辑，中文/非 ASCII 路径不会退化为 `unknown`
- **冲突分组**: `UU/AA/DD/AU/UA/DU/UD` 统一只进入 Changes，避免同一冲突文件同时出现在 Staged；`MM` 仍按 index/worktree 两侧分别进入 Staged 与 Changes
- **冲突操作保护**: commit（包括未暂存时的 auto-stage）与 Discard All 执行任何变更前，先通过 unmerged paths 检测拒绝未解决冲突；拒绝后 conflict markers、index 与冲突 status 保持不变
- **重命名路径**: quoted rename 按完整的两个 Git path 字段解析，文件名自身包含 ` -> ` 时不会被误切分
- **批量暂存**: Stage All 直接执行 `git add -A`，不受当前 status 快照或列表过滤影响
- **未诞生分支取消暂存**: 没有 HEAD 时通过清空 index 取消暂存，工作树文件保持不变；已有 HEAD 时仍恢复 index 到 HEAD
- **未跟踪文件 Diff**: `git diff --no-index` 只接受退出码 0（无差异）与 1（有差异），大于 1 的执行错误必须向 UI 暴露
- **Discard All**: `git reset --hard HEAD` 将 tracked 内容恢复到 HEAD（staged 与 unstaged 一并丢弃、index 清空），并通过 double-force `git clean -ffd` 删除所有未忽略的 untracked 文件、目录及嵌套 Git repository；ignored 内容不受影响
  - HEAD 无法解析时**必须区分两种成因**：仅当 `git rev-list --all --count` 为 0（仓库确实没有任何 commit）才走 `git rm -r --cached --ignore-unmatch` 清空索引；若仓库有 commit 而 HEAD 指向缺失的 ref（checkout 中断、ref 写入被截断、packed-refs 与 loose ref 不一致），必须拒绝操作并提示修复 HEAD——此时索引持有完整的已跟踪树，清空它会让随后的 `clean` 删掉整个工作区

### 3.3 实时刷新

`FileWatcher` 监听项目目录（FSEvents），0.3s debounce 后触发 `refresh()` → 重新加载 status + diff + branches + log。

- 刷新进行中收到的新请求会被合并为一次尾随刷新：当前刷新完成后立即再执行一次，避免 watcher 事件落在互斥窗口内而丢失
- 快速切换项目或 worktree 时，仓库打开请求以 request ID 标识；新请求会使旧请求失效，已取消或过期的 `repositoryRoot()` 结果不得替换当前仓库
- 切换到新仓库时，旧仓库的 status、log、工作区/commit 选择与详情状态会在新服务生效时原子清空；打开非 Git 目录失败时同时移除旧 `GitService` 与上述状态，后续 `refresh()` 不得恢复旧仓库数据
- `setPreferredDirectory()` 切换到当前仓库之外的目标时会取消旧的 “Open Changes” diff 任务，避免旧文件选择在新项目中继续执行
- status、log 与工作区 diff 的异步结果写入状态前，必须确认发起请求的 `GitService` 仍是当前实例，防止旧仓库结果覆盖新项目的分支、changes 或 diff
- 用户发起仓库切换时立即递增仓库上下文 generation，不等待 `repositoryRoot()` 返回；旧 command、AI 生成和 diff completion 从切换意图发生起即失效。同一真实 repository root 的子目录同步完成后保留当前状态
- 仓库切换意图只淘汰旧 command 的 UI completion，不提前释放 command mutex；无论切向同一 root 的子目录还是另一 root，底层 Git operation 实际退出前 `isRunningCommand` 始终为 true，第二个 stage/commit 等命令不得启动
- 工作区 diff 同时使用 request revision、`GitService` 身份和当前 selection identity 校验；较早文件的成功或失败结果都不能覆盖后来选择
- commit message draft 以标准化 repository root 为命名空间保存，切换仓库时恢复各自草稿，不跨仓库串用
- status 列表更新后，工作区多选集合会裁剪到仍存在的 change ID；range selection 的锚点失效时同步清空
- 从工作区 diff 切换到 commit 时清空工作区多选与 range selection 锚点，避免隐藏选择在返回工作区后继续影响批量操作

仓库身份与 preferred directory 切换统一以 `GitService.repositoryRoot()`（`git rev-parse --show-toplevel`）返回的真实仓库根目录为准，不再通过“目标路径位于当前仓库目录内”推断两者属于同一仓库：

- terminal cwd 或 Files 的 “Open Changes” 进入 submodule / 嵌套 Git repository 时，即使目标路径仍位于外层仓库目录下，也必须切换到内层仓库
- preferred directory 只是同一仓库内的普通子目录、解析结果仍为当前 root 时快速返回，保留现有工作区文件选择与 diff
- `openDiff` 总是先将 `repositoryCandidateURL` 解析为真实 repository root，再在该仓库中选择目标文件，避免先按路径包含关系错误复用外层仓库

回归覆盖：`GitChangesStoreTests.preferredDirectorySwitchesFromOuterToNestedRepository` 从外层仓库切换到其目录中的嵌套仓库，验证当前仓库身份更新为内层 root；本批定向 `GitChangesStoreTests` 为 5 tests / 1 suite，完整 XCTest 为 395 tests / 34 suites。SPM patch 已应用，`git diff --check` 通过。

**2026-08-19 追加 — Git 面板 EBADF 根因（fd 泄漏）**：老版本将管道 fd 交给 `DispatchIO` 后从未回收（libdispatch 不关闭 fd-based 通道的 fd）。每次 git 启动泄漏 2 fd，约 37 小时连续运行后填满 fd 表，随后所有 git 命令启动失败 EBADF——日志 2026-08-19 07:39 起连续 2461 次。诊断链：`lsof` 见 10.9K 无主 pipe fd → `sample` 无阻塞读取线程 → 独立 Swift 复现定位 `DispatchIO.close()` 后 fd 仍 open → 修复（cleanup handler 中 `close(descriptor)`）后 200 次启动 0 泄漏 → Debug 构建通过。修复同时消除反复横跳的“重试一次”逻辑依赖：EBADF 现在只可能是真·瞬时抖动。运行中的 1.1.6 实例需重启才能恢复（重启即释放全部 fd）。

### 3.4 Git Graph 分页一致性

- 同一 `GitService` 同时只允许一个加载更多任务；`LazyVStack` 底部 sentinel 连续触发 `onAppear` 时，后续相同 `skip` 请求直接忽略，避免重复追加同一批 commit
- 仓库切换会重置分页任务的服务身份；旧任务结束时只清理自己的身份，不得解除新仓库的分页互斥
- 刷新/reset 会递增 log generation，旧 generation 的分页成功或失败结果均不得写回；刷新期间不启动加载更多，避免 reset 与分页交错造成错页或缺页
- `GitService.log()` 使用 `git log -z --all` 与 `%x00` 输出 NUL 分隔协议，每条提交固定解析 hash、abbrev、subject、author、date、refs、parents 7 个字段；不再依赖可与提交标题碰撞的可见文本 `---OPENOWL-RECORD---` 切分 record。`--all` 使 Git Graph 呈现全部 ref 而非仅当前分支
- subject 即使完整等于旧 record marker `---OPENOWL-RECORD---` 也必须原样显示；空 refs 与 root commit 的空 parents 字段必须保留，parents 解析为 `[]`，且分页边界不能改变字段归属或遗漏提交
- 仓库尚无提交时，Git Graph 保持 `No commits yet` 空态，不因 `git log` 无记录产生 error banner；未诞生分支的真实名称仍由 status 提供给 Right Dock 与状态栏
- `GitGraphContentView` 在列表末尾增加一个 `graphRowHeight` 的底部 padding，避免最早一条提交被面板底边裁掉或无法点击
- 选中的 commit 行下使用 `commitFiles` 展开 M/A/D/R 状态与 `lastPathComponent` 文件名；详情加载期间仅显示一行 `Loading changed files…`，`CommitRow` 的 chevron 表示展开状态
- 展开区域的高度同时计入 Canvas 总高度及后续 commit 节点的纵坐标偏移，泳道跨过文件行后仍与下一节点对齐
- 点击展开文件会设置 `selectedCommitFilePath`、解除该文件的折叠状态并更新 `scrollTarget`，使右侧 commit diff 滚动到对应文件
- 右侧 commit diff 不再渲染重复的文件侧栏与显隐按钮，按文件拆分的 diff 使用全部可用宽度；Graph 中的文件点击仍沿用 `selectedCommitFilePath` 与 `scrollTarget` 定位右侧 section
- `CommitRow` 的右键菜单将完整 `entry.hash` 写入系统剪贴板

回归覆盖：`GitChangesStoreTests.repeatedLoadMoreRequestsDoNotDuplicateCommits` 在含 55 个 commit 的临时仓库中连续触发 3 次加载更多，最终必须得到恰好 55 个唯一 hash，并同时覆盖 root commit 未被日志解析遗漏；测试仓库的 root commit 新增 `root.txt`，选择该提交后还会验证文件列表为 `root.txt` 且 patch 包含 `+root content`。

日志协议回归覆盖：`GitCommitParsingTests.log_preservesSubjectMatchingPreviousRecordSeparator` 创建标题完整等于旧 marker 的合法提交，验证 subject 原样保留，同时覆盖空 refs、root commit 空 parents 与分页解析。定向 `GitCommitParsingTests` + `GitChangesStoreTests` 共 18 tests / 2 suites、完整 XCTest 396 tests / 34 suites 通过；SPM patch 已应用，`git diff --check` 通过。

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
- 选择另一 commit 时立即清除上一 commit 产生的全局详情错误；清理按错误来源/revision 校验，不得误删随后产生的新错误
- 从失败的 commit 详情切回工作区文件时也立即按 error provenance/revision 清除该详情写入的全局错误，不等待新的工作区 diff 返回
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
- Commit message 生成进程句柄通过锁同步；旧进程 termination 只可清理自身句柄，cancel 会原子取出并清空当前句柄后终止进程，避免快速切仓或连续生成时漏取消新进程

## 5. 相关需求

- [REQ-002: Git 变更](../requirements/REQ-002-git-changes.md)

## 6. 更新记录

| 日期 | 说明 |
|------|------|
| 2026-08-14 | `git status` 增加专属 30 秒超时：超时 `SIGKILL` 真实 `Process`，并停止并发 `DispatchIO` 排空，避免后代 helper 占用 pipe 阻塞后续 status；diff/log/fetch/push 无统一 30 秒限制。`GitCommandGate` 以 token 清理正常/错误/超时 tail。`GitCommandGateTests` 覆盖串行、tail 回收及后代进程超时后 successor 继续执行 |
| 2026-08-09 | commit auto-stage 与 Discard All 在变更前拒绝 unresolved conflicts 并保留 markers/status；Discard All 以 double-force clean 删除非 ignored 嵌套 Git repository，同时保留 ignored/staged。仓库切换立即淘汰旧 UI completion，但 command mutex 延续到底层 operation 退出；选择工作区 change 时按来源即时清理旧 commit-detail 全局错误。定向 GitService 28 tests、GitChangesStore 11 tests，完整 XCTest 419 tests / 35 suites 通过；SPM patch 已应用且 `git diff --check` 通过 |
| 2026-08-09 | Right Dock Git 状态按真实 repository root 隔离 commit draft；仓库切换意图立即淘汰旧 command/AI/diff completion，工作区 diff 增加 revision + selection 门禁，commit 详情错误按来源即时清理。Stage All 改用 `git add -A`；Discard All 保留 index/staged、恢复 tracked 工作树并清除全部非 ignored untracked；补齐 unborn unstage、7 类冲突分组、quoted rename 内含箭头、untracked diff 退出码以及 commit message 进程句柄并发契约。定向 GitChangesStore 10 tests、GitService 40 tests、CommitMessageGenerator 2 tests，完整 XCTest 416 tests / 35 suites 通过；SPM patch 已应用且 `git diff --check` 通过 |
| 2026-08-09 | Git porcelain v1 的 unborn branch header 同时支持 `No commits yet on <branch>` 与旧 `Initial commit on <branch>`，仅向 Right Dock/状态栏暴露真实分支名；空仓库 Git Graph 保持 `No commits yet` 空态且不显示 error banner，detached HEAD 行为不变。新增 `GitServiceParsingTests.parseBranch_unbornBranch`、`GitChangesStoreTests.emptyRepositoryReportsUnbornBranchName`；定向 26 tests / 2 suites、完整 398 tests / 34 suites 通过，SPM patch 已应用且 `git diff --check` 通过 |
| 2026-08-09 | Git Graph 日志由可碰撞的 `---OPENOWL-RECORD---` 可见文本分隔改为 `git log -z` + `%x00` 的 NUL 字段协议，固定解析 7 个字段并保留空 refs/root parents；合法提交标题等于旧 marker 时仍完整显示。新增 `log_preservesSubjectMatchingPreviousRecordSeparator`；定向 18 tests / 2 suites、完整 396 tests / 34 suites 通过，SPM patch 已应用且 `git diff --check` 通过 |
| 2026-08-09 | Right Dock Git 仓库身份改以 `repositoryRoot()` / `git rev-parse` 的实际 root 判定；terminal cwd 与 Files Open Changes 可从外层仓库切换到 submodule/嵌套仓库，同仓库普通子目录则保留当前选择与 diff；`openDiff` 先解析候选路径的真实 root。新增 `preferredDirectorySwitchesFromOuterToNestedRepository`；定向 5 tests / 1 suite、完整 395 tests / 34 suites 通过，SPM patch 已应用且 `git diff --check` 通过 |
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
