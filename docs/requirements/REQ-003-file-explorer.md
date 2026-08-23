# REQ-003: 文件浏览器

> 状态：✅ Done | 优先级：P0 | 创建日期：2026-03-14

## 概述

目录树浏览器，支持文件导航和 Git 状态着色。

## 核心需求

### P0 — 基础文件树

- [x] 递归目录树展示，点击展开/折叠
- [x] `.gitignore` 过滤（默认隐藏被忽略的文件）
- [x] 目录优先 + 字母序排序
- [x] 文件图标（按扩展名映射）

### P0 — Git 状态着色

- [x] 绿色 = 新增，黄色 = 修改，红色 = 删除，蓝色 = 重命名
- [x] 冲突状态高亮（粉色，状态码 `U`）
- [x] 颜色从子文件递归传播到父目录

### P1 — 交互

- [x] 右键菜单：在终端中打开、在 Finder 中显示、复制路径
- [x] 点击变更文件 → 打开 Diff 视图
- [x] 点击普通文件 → 只读预览（含轻量语法高亮）
- [x] rename/cut-move 成功后原子迁移全部 URL-keyed editor state；目录操作覆盖所有已打开后代，复制与失败操作不迁移
- [x] 多文件 cut/move 部分失败后，pasteboard 只保留失败 URL 且 cut pending 不清除；重试必须继续 move，不能退化为 copy
- [x] pending initial read 遇 rename/move 时必须将 activation 映射到新 URL，并以新 URL 重启完整首次打开流程，最终结束 pending/loading
- [x] rename/move 前检测目标与既有 open tab 的 URL 映射碰撞；碰撞时阻止文件系统操作并显示错误
- [x] 删除成功后立即从 tree/index/search/selection/preview/Quick Open 裁剪目标及后代，不依赖下一次 watcher refresh
- [x] App 内删除 dirty tab 或其父目录必须被阻止；删除 clean 文件关闭 tab
- [x] 外部删除 clean 文件关闭 tab；dirty 文件保留内存 buffer 并显示 backing file missing 错误

### P2 — 增强

- [x] 文件搜索（Cmd+P 快速查找）
- [x] 拖拽文件到终端

## 已落地实现要点

- `ProjectStore`：
  - 项目列表持久化与 active project 管理
  - 顶部项目区支持打开/切换/删除
- `FileExplorerStore`：
  - 递归扫描文件树（目录优先 + 名称排序）
  - Git 状态映射与父目录状态聚合（A/M/D/R/U 细粒度）
  - ignored 路径过滤（git ignored 列表 + 目录前缀压缩优化）
  - 文件预览（文本/二进制判定 + 截断）
  - 刷新进行中收到的新 watcher/手动请求时，当前轮完成后立即执行一次尾随刷新，避免文件变化事件丢失
  - 切换项目时立即清空旧 `currentGitContext`；目标项目没有扫描缓存时同时清空 `searchableFileNodes`，保证 Quick Open 不泄漏旧项目文件
  - 浅层扫描写入 `rootNodes` / `nodeIndex` 前核对 captured `projectURL`，丢弃项目切换后才返回的旧扫描结果
- `FileExplorerView`：
  - `OutlineGroup` 树视图 + 文件图标 + 状态标记
  - `Cmd+P` 快速查找弹层（关键字检索 + 回车打开）
  - 文件/目录可拖拽到终端（传递文件 URL）
  - 右键菜单（Reveal / Open in Terminal / Copy Path）
  - 变更文件点击后切换到 Git 面板并打开 diff
  - 普通文件预览语法高亮（轻量关键词/注释/字符串）
  - rename/cut-move 将 open/active/pending/heavy tab、storage、image、signature、read request 与 dirty/large/huge 集合按 URL 映射一次提交
  - delete completion 只按实际成功 URL 裁剪编辑器状态；dirty/missing 处理遵循上述交互契约

## 回归验收

- `fileEditorURLMutation_remapsFileAndDirectoryDescendantState`：文件与目录后代的 URL-keyed editor state 必须随 move 映射
- `cutPaste_partialFailureKeepsOnlyFailedURLsPendingForMove`：部分 move 成功后 pasteboard 只保留失败项，解除目标冲突后的第二次 paste 继续移动该项并清除 cut pending
- `fileEditorURLMutation_detectsExactAndDirectoryDescendantCollisions`、`renameNode_rejectedEditorMoveDoesNotTouchDisk`：目标碰撞必须在磁盘操作前被拒绝
- `fileEditorURLMutation_dirtyDeleteGuardIncludesDirectoryDescendants`：目录删除必须识别后代 dirty tab
- `pruningNodes_removesDeletedDirectoryDescendants`：删除后 tree/index/search/selection/preview/Quick Open 立即裁剪目标后代
- `switchingToUncachedProjectClearsPreviousQuickOpenFiles`：从已有 Quick Open 索引的项目切换到无缓存项目时，旧文件列表必须立即清空
- `FileExplorerErrorHandlingTests`：35 tests / 1 suite 通过
- 完整 XCTest：419 tests / 35 suites 通过
- `git diff --check` 通过；SPM patch 已应用

## 更新记录

| 日期 | 说明 |
|------|------|
| 2026-08-09 | 增加 cut/move 部分失败只保留失败 URL 与 cut pending、重试仍执行 move，以及 rename/move 后按新 URL 重启 pending initial activation 并结束 loading 的验收。关联 FileExplorer 35 tests；完整 XCTest 419 tests / 35 suites 通过 |
| 2026-08-09 | 增加 rename/cut-move 的 editor URL state 原子迁移与目标碰撞前置拒绝；删除立即裁剪文件树和 Quick Open 状态，区分 clean/dirty 与 App 内/外部删除。关联 FileExplorer 34 tests；完整 XCTest 416 tests / 35 suites 通过 |
