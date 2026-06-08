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
3. 不持久化未保存的编辑缓冲区；切项目/视图卸载前仍沿用现有 dirty tab auto-save

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
- 恢复：过滤不存在路径、目录、超过图片解码上限的图片；普通大文件按 large-file mode 恢复
- 日志：`[file-editor-state]` 记录 `persist` / `restore` / `restore-skip` / `clear`

## 4. 注意事项

- NSOutlineView 比 SwiftUI List 性能好得多（支持 10k+ 节点零卡顿）
- 文件预览限制 160KB，检测二进制文件（null byte 检测）
- 剪切操作通过 UserDefaults flag 标记，粘贴时判断是复制还是移动
- 目录树变更通过 FileWatcher 自动刷新
- Editor tab session 只保存路径和 active tab，不保存文件内容本身

## 5. 相关需求

- [REQ-003: 文件浏览器](../requirements/REQ-003-file-explorer.md)

## 6. 更新记录

| 日期 | 说明 |
|------|------|
| 2026-06-05 | 新增按项目 editor tab session 持久化与 file-editor-state 日志 |
| 2026-05-07 | 全量扫描新增嵌套 repo 与依赖/构建目录懒加载边界，避免 workspace 级目录占用 GB 级内存 |
| 2026-03-16 | 创建文档 |
