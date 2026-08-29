# Postmortem: 文件树文字从左侧被裁掉（leading glyph / icon 不可见）

**Date**: 2026-08-27
**Severity**: P1 (核心 UI 缺陷，文件探险器首列无法阅读)
**Resolution time**: 定位 + 修复 + 验证
**影响范围**: FileExplorer — NSOutlineView 文件树

## Summary

文件树每一行的文本都从**左侧**被裁掉：只显示文件名结尾的若干字符（如 `…ents`、`…nce-page`、`…dules`、`…backup.md`），文件/文件夹图标完全看不见，同时在行的右侧留出一段空白。用户报告 "file explorer 显示有问题"。在选中一个嵌套较深的文件后必现，是最核心的浏览面板无法使用的程度。

## 关键观察 / 排查

1. 用 `screencapture` 抓正在运行的实例确认了症状：**左侧裁剪 + 右侧空白**是同时出现的。
2. 给 `OutlineTreeViewController` 和 `OutlineTreeCellView` 加临时几何诊断，抓到一手数据：

   ```
   clip.origin=(0.0,0.0) clip.size=(240.0,688.0)
   outline.frame={{0,0},{240,1086}} colW=208.0 contentSize=(240.0,688.0)
   ```

   关键两处：
   - **列宽 208 < 面板宽 240** → 列没有填满面板，右侧留 32pt 空白。
   - 初始状态下 `clip.origin.x = 0`，说明**左侧裁剪不是初始状态就有，而是某项交互触发后 clip view 被水平滚动导致的**。

## Root Cause

文件树的 cell 布局约束本身是健壮的：`iconView.leading = cell.leading + 2`、`nameField.leading = iconView.trailing + 4`，因此 cell 内部 text 永远在 `x >= 0`。而 NSOutlineView 对行的缩进 `indentationPerLevel * depth` 恒为非负。**所以 cell 在 outline view 里永远位于 `x >= 0`** —— 唯一能让首字符跑到面板左缘之后的方式是**把 clip view 水平向右滚动**（`clip.origin.x > 0`）。

触发路径：

1. `FileExplorerView.updateNSViewController` 在 `store.selectedNodeID` 非空时每次都调 `OutlineTreeViewController.selectAndReveal(nodeID:)`。
2. `selectAndReveal` 末尾调用 `outlineView.scrollRowToVisible(row)`。
3. 被选中的文件往往是嵌套较深的行，其 cell 起点在 `indentationPerLevel * depth`，宽度等于列宽，于是 cell 的右缘（`indent + columnWidth`）超出面板（`columnWidth`）——cell 在右侧溢出。
4. 为把该行的尾部露出，AppKit 把 clip view **向右**滚动；这一滚动把**所有更浅的行**整体向左推，首字符和图标因此被裁掉。

列宽 208 < 面板 240 是**第二个独立缺陷**，由既有机制造成：`autoresizesOutlineColumn = false`（为修 2026-03-18 的"列随目录展开无限撑宽"而保留）会让列宽不再跟随面板变化；而 `sizeLastColumnToFit()` 只在 `viewDidAppear` 调一次，且按 postmortem 记录它是"只扩张不收缩"——它在宿主 NavigationStack 尚未定型（列窄）时定的列宽，之后就卡在 208，面板变为 240 后不再修正。

## Timeline

- 发现：用户报告文件树显示异常，抓图确认左侧裁剪。
- 加诊断 → 抓到 `colW=208 < clipW=240` 且初始 `clip.origin.x=0`。
- 归因：cell 恒在 `x>=0`，左侧裁剪只能来自 clip view 水平滚动；`scrollRowToVisible` 对深层行会向右滚动导致。
- 定案：文件树应当**只截断名称、永不横向平移**（与 VS Code 一致）。横向平移既是错误行为也必然带来左侧裁剪。

## Fix

`openOwl/Features/FileExplorer/OutlineTreeViewController.swift`：

1. **新增 `TreeClipView: NSClipView`**，把水平滚动原点恒定为 0（不改纵轴）：
   - `constrainBoundsRect(_:)`、`setBoundsOrigin(_:)`、`scroll(to:)` 三处都把 `x` 压成 0。
   - 因为这已在"根因"上关闭了唯一的左侧裁剪通道，属于完整修复，而非打补丁。
2. **`loadView` 改用 `TreeClipView` 作为 scroll view 的 contentView**（`autoresizingMask = [.width, .height]`）。
3. **新增 `synchronizeOutlineColumnWidth()`** 并在 `viewDidLayout` 调用：让列宽跟随 outline view 实际宽度（`column.width = outlineView.bounds.width`），带 `>= 100` 与变化守卫，稳态零开销；按变更守卫只在真的变化时写，避免每帧副作用（回应 2026-03-18 postmortem 关于 `viewDidLayout` 的警告）。

保留 `autoresizesOutlineColumn = false` 与 `viewDidAppear` 里的 `sizeLastColumnToFit()`（两者与新的同步逻辑收敛到同一列宽，`sizeLastColumnToFit` 负责初始撑开，同步逻辑负责后续跟随与"只扩不缩"覆盖不到的收缩场景）。

## 验证

- Debug 构建成功。
- 重新加载项目后，几何诊断不再触发（即 `colW == clipW` 且 `clip.origin.x == 0`），左侧裁剪通道被物理关闭。
- FileExplorer 相关测试套件全绿：`FileExplorer Error Handling` / `FileExplorer Git Propagation` / `FileExplorer Parsing` / `FileGitState` / `FileIcons` 均 passed。
- 全套本分支 `426 tests / 36 suites` 仅 1 个失败，为无关的 worktree 临时目录清理 `Permission denied`（环境性、与本次改动无关）。

## Key Learnings

### 1. 先判断"逻辑上可能吗"，再定位

在深挖 AppKit 布局之前，先用一个不变量排除掉一大半可能：cell 内部 text/icon 由约束约束在 `cell.leading + 正偏移`，NSOutlineView 缩进恒为非负，所以 **cell 在 outline view 里恒在 `x >= 0`**。既然 cell 不可能在 `x < 0`，左侧裁剪的唯一通道就是 clip view 水平滚动。这个不变量把排查范围从"AutoLayout 崩了？"缩小到"谁把 clip view 向右滚了"。

### 2. 症状组合能拆出多个缺陷

"左侧裁剪 + 右侧空白" 其实是两个独立缺陷叠加：一个由水平滚动（左侧裁剪）造成、一个由列宽不跟随面板（右侧空白）造成。拆开各自修复，而不是用一个模糊改动去"能让它显示正常就行"。

### 3. 文件树的语义决定了横向滚动应该是禁用状态

对文件树而言，名称应当自动截断（`byTruncatingTail`），横向平移既不符合用户预期，也正是本 bug 的根源。与其事后把滚回去，不如在 clip view 层把横向滚动永久关掉——在语义层面解决，后面不会再被任何路径重新触发。
