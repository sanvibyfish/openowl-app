# REQ-003: 文件浏览器

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

## 回归验收

- `switchingToUncachedProjectClearsPreviousQuickOpenFiles`：从已有 Quick Open 索引的项目切换到无缓存项目时，旧文件列表必须立即清空
- `FileExplorerErrorHandlingTests`：29 tests / 1 suite 通过
- 完整 XCTest：394 tests / 34 suites 通过
- `git diff --check` 通过；SPM patch 已应用
