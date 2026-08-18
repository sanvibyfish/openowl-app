# Progress

## In Progress

- M2: Git 变更管理（主体完成，待运行时手测）
- M3: 文件浏览器 + 侧边栏（已完成 T3.1-T3.7 主体实现，待运行时手测）
- REQ-004: 本地部署服务（主体实现完成，待运行时手测）
- UI review 后续：DeploymentStore 拆分（P3，分离健康检查/日志/进程管理）
- Git 和 File 模块化拆分（待下个 session 开始，预估 3-4 天）
- [ ] .dic 单击 1GB+ 内存暴涨根因定位（已加 DIAG-MEM 诊断日志，待用户实测回贴）
- [x] 2026-07-28 UI：左侧宽项目树 → Muxy 风格 `ProjectRail`（48pt）；`ContentView` 去掉 NavigationSplitView
- [x] 2026-08-11 git SIGBUS crash 修复：固定 git 路径 + status 串行化 + 信号退出重试 + `AppExitMonitor`（atexit/信号 handler 写 exit.log 定位 exit(1) 来源）
- [x] 2026-08-14 C-6 退出监控加固：致命信号路径移入纯 C，预打开 fd 并仅写固定消息；正常 `atexit` 保留时间戳与回溯，两类 handler 独立安装且部分信号安装可回滚
- [x] 2026-08-14 C-9 Git status 超时加固：仅 status 限制 30 秒，超时强制结束真实进程并停止 pipe 排空；gate 在正常/错误/超时后回收 tail
- [x] 2026-08-14 C-12 Terminal surface 失败态：原 pane 显示可访问错误卡片，保留 pane，并阻止重挂载重试与重复 UI
- [x] 2026-08-11 REQ-009 跨 Agent 消息总线 Phase 1 ➜ **2026-08-18 已整体删除**（含 codex hooks / pi 扩展适配器），详见 [REQ-009](../requirements/REQ-009-message-bus.md)
- [x] 2026-08-11 REQ-009 Phase 2 （MessageBusService / Bus tab / 互操作测试）➜ 同上，已删除
- [x] 2026-08-15 REQ-009 可测试性与写入安全 ➜ 同上，已删除
- [x] 2026-08-15 Git Discard All 契约恢复：`git clean -f -f -d` 删除非 ignored untracked（含嵌套 Git repository），保留 staged/ignored。全量 430 tests / 37 suites / 0 failures，Debug build 成功

## Release & Distribution

- [x] v1.0.0 发布 — OpenOwl-1.0.0.dmg (40MB) 签名 + 公证，上传到 GitHub Releases
- [x] v1.0.1 — Sidebar pane 行 UI 优化、分屏拖拽稳定性修复、FileExplorer MinimapView crash 修复
- [x] d5fb73a — REQ-006 Claude 状态 incident banner + Sidebar PaneStatusRow UI 优化
- [x] 361972c — Pane 拖拽稳定性修复、TerminalSearchOverlay 位置修复、搜索快捷键修复
- [x] v1.0.2 — Deployment 100% CPU 修复 + 侧边栏分支空白页修复 + 终端拖拽 opacity(0) 修复
- [x] v1.0.3 — surface 泄漏修复 + 项目 Tab 关闭/拖拽 + Worktree 自动发现 + Debug 诊断系统
- [x] v1.0.4 — Deployment removeItem 误删用户目录修复
- [x] v1.0.7 测试版 — 退出保护 + libghostty 默认回退 ReleaseFast

## Done

- [x] M1: 骨架应用 + libghostty 终端
- [x] T1.1 项目脚手架 — xcodegen + SwiftUI 三栏布局 + entitlements
- [x] T1.2 Ghostty 集成 — submodule + setup.sh (zig build + SHA 缓存) + xcframework 链接
- [x] T1.3 终端视图 — GhosttyApp/Config/Input/Terminal + TerminalPanel (NSViewRepresentable)
- [x] T1.4 终端功能增强 — shell fallback、recursive config、配置快照与 diagnostics
- [x] T1.5 多标签 + 分屏 — 应用内 tabs、多级分屏、Cmd+T/W/1-9/D/Shift+D/Arrow
- [x] T1.P1 终端标题追踪 — 监听 `SetTitle/SetTabTitle` action 并更新 Tab 标题
- [x] M2-T2.1 GitService — porcelain 解析 + add/unstage/commit/diff/checkout
- [x] M2-T2.2 Changes Panel — 分组列表 + 单文件/批量 stage 操作 + commit 输入区
- [x] M2-T2.3 Diff View — unified diff + 加减行着色 + 轻量语法高亮
- [x] M2-T2.4 FileWatcher — 目录监听 + 300ms 防抖自动刷新
- [x] M2-T2.5 Branch/Remote — ahead/behind + create/delete + fetch/pull/push
- [x] M2-T2.6 Discard Changes — 单文件/批量丢弃 + 确认弹窗（modified/untracked）
- [x] M3-T3.1 文件树 — 递归树、目录优先排序、图标映射、git ignored 过滤
- [x] M3-T3.2 Git 状态着色 — 文件颜色标注 + 父目录递归传播
- [x] M3-T3.3 文件交互 — 右键菜单、变更文件跳转 Diff、普通文件只读预览
- [x] M3-T3.4 项目管理 — 项目列表持久化、打开/切换项目、上下文联动 Git/File 面板
- [x] M3-T3.5 预览与搜索增强 — Cmd+P 快速查找 + 轻量语法高亮
- [x] M3-T3.6 文件拖拽 — 文件树拖拽到 Terminal 粘贴路径
- [x] M3-T3.7 状态优化 — A/M/D/R/U 细粒度状态 + ignored 前缀压缩
- [x] App branding — 猫头鹰 icon 全尺寸 (16-1024) + 菜单栏 template icon + display name "OpenOwl"
- [x] 开源发布 — GitHub 仓库 sanvibyfish/openowl-app, GPL-3.0, README (EN + CN)
- [x] 版本更新检查器 — UpdateChecker (GitHub Releases API) + CheckForUpdatesButton + UpdateAlertView
- [x] 构建 & 发布流水线 — scripts/build-dmg.sh (xcodegen → archive → sign → DMG → notarize → staple)
- [x] 自动签名配置 — CODE_SIGN_STYLE=Automatic, DEVELOPMENT_TEAM, HARDENED_RUNTIME
- [x] 终端分屏分隔线稳定性 — SplitDividerInfo tree-path ID
- [x] Git 变更视图改进 — Animation.identity → .default, git graph 增强
- [x] .gitignore 加固 — *.cer, *.key, *.p12, *.pfx, *.dmg, build/
- [x] 编译验证通过 (`xcodebuild -scheme openOwl -configuration Debug build`)
- [x] docs/features/ 全套功能文档 — 001-006 编号文档 + README 索引
- [x] Swift Testing 基础设施 — openOwlTests target，149 个测试全部通过（14 suites）
- [x] ProjectStore 持久化迁移 — UserDefaults → `~/.openowl/openowl.json` + 一次性迁移
- [x] GitService / FileExplorerStore 可见性调整 — private → internal 支持测试访问
- [x] Cmd+P Quick Open 修复 — 终端 performKeyEquivalent 拦截问题，通过 Notification 触发
- [x] 文件切换缓存优化 — setProject() 有缓存时跳过浅扫描，避免闪烁
- [x] 文件浏览器 3 bug 修复 — lazy 展开 / Git 状态目录传播 / ESC 退出重命名
- [x] 目录树自动收缩 bug — 移除 outlineViewSelectionDidChange 的 toggle 逻辑
- [x] Git badge 布局溢出 — cell 右对齐 + nameField compression resistance = low
- [x] 文件目录面板可拖拽 — @State + DragGesture，150-500px 范围
- [x] 编辑器 tab close 按钮修复 — Image + onTapGesture 避免手势冲突
- [x] 编辑器内容溢出修复 — SourceEditor 加 .clipped()
- [x] Git Graph commit diff 完整实现 — 按文件分 section、文件列表 sidebar、图片 diff、颜色区分
- [x] MenuBar icon 处理 — 裁剪/反色/缩放到 18x18 + 36x36 template image
- [x] Sidebar 展开/收缩修复 — 文件夹行不参与 selection，点击只做展开/收缩
- [x] 项目切换性能优化 — syncActiveProjectContext 只刷新当前可见 tab 的 store
- [x] QuickOpen (Cmd+P) 修复 — firstResponder guard / ESC 关闭 / 点击外部关闭 / lazy-load
- [x] SwiftUI "publishing changes from within view updates" 修复 — DispatchQueue.main.async 延迟
- [x] 编辑器 tab 切换/关闭修复 — Button 替代 onTapGesture，去掉 ScrollView
- [x] 编辑器 SourceEditor frame 填满修复
- [x] Sidebar BranchRow 交互 — hover 复制路径 + 右键菜单
- [x] 内联重命名 Finder 风格 — plain textFieldStyle + 淡蓝背景
- [x] SidebarExpandCollapseTests (7 tests) 全部通过
- [x] 上游 PR: CodeEditTextView Typesetter CJK bug (#122)
- [x] 上游 PR: CodeEditSourceEditor MinimapView hitTest bug (#370/#371)
- [x] REQ-004-T1 DeploymentProcessManager — Process 生命周期、SIGTERM→SIGKILL、日志流式写入
- [x] REQ-004-T2 DeploymentStore — 创建/启动/停止/重启/删除、UserDefaults 持久化、分支轮询、PID 恢复
- [x] REQ-004-T3 ViewTab + ContentView 集成 — `.deployments` tab + DeploymentPanelView
- [x] REQ-004-T4 DeploymentPanelView — 左侧列表 + 右侧详情（状态/按钮/配置/实时日志）
- [x] REQ-004-T5 DeploymentRow + SidebarView — Sidebar 状态行 + 右键菜单 + 点击跳转 Deploy tab
- [x] REQ-004-T6 CreateDeploymentSheet — 创建部署表单 + 自动获取 remote URL + Deploy 按钮
- [x] REQ-004-T7 MenuBarExtra 系统托盘 — 托盘图标 + 部署状态菜单 + Start/Stop 操作
- [x] REQ-004-T8 AppDelegate — 有运行中部署时关闭窗口不退出 app
- [x] UI 审计 — 3 并行 agent 审计（架构/性能/导航），发现 2C+7H+9M+5L 问题
- [x] 性能修复 Phase 1 — ISO8601DateFormatter static 缓存、VStack→LazyVStack、Tab 状态 UserDefaults 持久化
- [x] 性能修复 Phase 2 — loadFileIfNeeded 异步化、computeGraphLayout @State+onChange 缓存
- [x] @Observable 全量迁移 — 7 个 Store 从 ObservableObject 迁移到 @Observable，去 Combine 化，16/16 测试通过
- [x] 拖入文件单引号修复 — shellEscapedPath 对齐 Ghostty 反斜杠转义，替代单引号包裹
- [x] Cmd+V 粘贴文件路径修复 — pasteFromClipboard() 优先读 fileURL（对齐 Ghostty getOpinionatedStringContents）
- [x] 导航 API 统一 — AppNavigationStore 新增 navigate(to:)/openDeployment(id:...)，8 处调用替换，Git/Files/Deploy tab 包裹 NavigationStack
- [x] FileIcons 提取 + 语义色 — Shared/FileIcons.swift 消除 3 处重复 icon 映射，AppPalette 改用系统语义色，支持亮色/暗色模式
- [x] 测试补充 — FileIconsTests (15)、AppNavigationStoreTests (8)、GraphLayoutTests (8)
- [x] Liquid Glass 扩展 — EditorTabBar glassEffect + 选中 tab glassEffectWithTint、Deploy ActionButton glassEffectWithTint
- [x] Graph Layout 测试 — computeGraphLayout/GraphNode/GraphLayout 从 private 提升为 internal 以支持测试
- [x] Sidebar bellCount 缓存 — TerminalWorkspaceStore.bellCount(for:) 轻量方法，减少 sidebar 观察依赖
- [x] Terminal Search (Cmd+F) — TerminalSearchState (@Observable) + TerminalSearchOverlay (SwiftUI 浮层) + per-pane 独立搜索状态 + GhosttyApp 搜索回调 + debounce 策略 (>=3字符立即, <3字符 300ms)
- [x] REQ-006 Claude 异常提醒 — 仅异常时显示可关闭提醒卡片（history.rss 轮询），关闭后忽略当前 incident，失败静默保留状态
- [x] Cmd+F 菜单拦截修复 — 将 Cmd+F 处理移到 AppDelegate.handleLocalKeyDown（NSEvent local monitor 最高优先级），Terminal 菜单添加 "Find..." 菜单项
- [x] 搜索框快捷键放行 — handleLocalKeyDown 添加 `firstResponder is TerminalNSView` guard，非终端焦点时放行所有快捷键
- [x] Cmd+arrow 单 pane 冲突修复 — 仅 isMultiPane 时拦截方向键做 pane 导航，单 pane 时放行给 ghostty
- [x] Sidebar PaneStatusRow UI 优化 — 字体 10→11pt、圆点 5→7px、纵向 padding 1→4pt、hover 背景 `.quaternary`、点击聚焦 pane、accessibility 支持
- [x] Pane 拖拽稳定性修复 — 自定义 UTType `com.openowl.terminal.pane-drag` 避免 TerminalScrollView 拦截；移除 `draggingPaneID != nil` 条件解决时序竞争；全路径拖拽日志覆盖
- [x] FileExplorer crash 修复 — fork CodeEditSourceEditor，修复 MinimapView `brightnessComponent` 对 catalog color 直接调用 crash，切换依赖指向 fork fix branch
- [x] TerminalSearchOverlay 位置修复 — 从 topTrailing overlay 移入 pane content 内部，修复 padding（horizontal 12pt, vertical 4pt）和宽度对齐
- [x] 搜索框 Return/Shift+Return/Esc 快捷键 — AppDelegate handleLocalKeyDown 在 command guard 前处理搜索态快捷键
- [x] FileExplorerView defer 修复 — openFileInTab 改用 defer 延迟，避免 view update 期间改状态
- [x] 文件编辑器刷新/遮挡修复 — editor tab 按磁盘签名刷新、dirty tab 不覆盖、Right Dock resize 暂停 PTY resize 但裁剪 Metal view，terminal no-op layout 日志降噪
- [x] 搜索框全面修复 — overlay 移到最外层避免 drop delegate 拦截点击；AppDelegate Return 拦截加 terminalHasFocus 判断修复 IME Enter；TerminalSearchOverlay 加 isFocused 参数失焦自动关闭
- [x] 搜索框 Enter 阻挡修复 — .onKeyPress(.return) 替换为 .onSubmit（修复 @FocusState 与 AppKit firstResponder 失同步），删除 SwiftUI 层冗余 .contentShape+.onDrop 文件拖拽处理
- [x] 搜索匹配计数修复 — ghostty selected 0-based → 显示 1-based（selected + 1）
- [x] Search overlay 布局调整 — 从 overlay 改为 VStack 内元素
- [x] "Modifying state during view update" 修复 — isProgrammaticSelection flag + updateData 全块保护
- [x] UTType 声明 — Info.plist 添加 com.openowl.terminal.pane-drag
- [x] Dev 图标修复 — runtime NSApp.applicationIconImage 设置 + 大号 DEV 横幅（actool 对非 AppIcon 命名的 appiconset 只生成部分 icns）
- [x] FileExplorer expandDirectory git status — 使用 currentGitContext 代替 .empty
- [x] syncData 机制 — 展开目录时同步 controller 本地数据
- [x] refreshNow 优化 — 已有数据时跳过 shallow phase，用 refreshFullOnly()
- [x] autoresizesOutlineColumn = false — 防止列宽超过 clip view
- [x] updateNSViewController 条件性跳过 — controller.rootNodes != store.rootNodes 才 updateData（@Observable 迁移时序变化适配）
- [x] FileExplorer workspace 内存修复 — 全量扫描遇到嵌套 repo/worktree、node_modules、.next 等目录时只保留目录节点不递归，避免打开 `~/.openowl/workspace` 占用 GB 级内存
- [x] Worktree 归档反馈与失败保护 — 点击后显示进度并禁用重复触发；`git worktree remove` 失败时不再从项目列表移除，并弹窗显示错误
- [x] Deployment 100% CPU 修复 — EOF readabilityHandler nil-out + appendLog 200ms buffer 节流 + activeStreamIDs 去重
- [x] 侧边栏分支点击空白页修复 — listSelection setter 加 activeTab = .terminal；PaneStatusRow 移除 onTapGesture 变纯展示组件
- [x] 终端文件拖拽错误修复 — TerminalScrollView 拖拽方法加 isEffectivelyVisible 检查，拒绝 opacity=0 终端接收拖拽
- [x] DeploymentLogThrottleTests — 12 个测试覆盖 buffer 累积/flush/100KB cap/activeStreamIDs 生命周期
- [x] WindowServer 压垮修复 — 只渲染 activeTabID + metalLayer.isHidden 双重保护，消除不可见 Metal surface 持续提交 drawables
- [x] Code Review 修复 — 删除 updateVisiblePanes 死代码、setSurfaceVisibility guard 去重、makeBackingLayer 立即应用 hostVisible、viewDidMoveToWindow focus 保护
- [x] Health check 指数退避 — 连续失败 30s→5min 退避，恢复后回到 30s，减少无效 TCP 连接
- [x] Code Review 三轮并行修复 — consecutiveHealthFailures 清理、layout() 冗余、task_info 错误提示、health state 清理
- [x] @ObservationIgnored 修复 surface 泄漏 — GhosttyAppManager 内部字典标记 @ObservationIgnored，防止级联 re-evaluation 创建幽灵 surface
- [x] Debug 诊断系统 — ⌘⇧I 一键复制诊断信息 + StatusBarView Metal X/Y 指标（仅 DEBUG）
- [x] 项目 Tab 关闭 + 拖拽排序 — hover ✕ 按钮 + onDrag/onDrop + ProjectTabDropDelegate + moveRootProject
- [x] Worktree 自动发现 — addOrActivateProject 时自动 git worktree list，已存在 worktree 自动添加
- [x] CodeEditSourceEditor fork 修复 — project.yml 指向 fork，修复 MinimapView crash，xcodegen 不再重置依赖
- [x] v1.0.3 发布 — 版本 1.0.3 build 4，DMG + Apple 公证 + Gatekeeper 通过 + GitHub Release
- [x] Mori 项目分析 — 对比架构差异，评估 6 个借鉴方向适用性
- [x] 菜单栏快捷键发现性 — Terminal + View 菜单栏，快捷键可见
- [x] Git 角标初始加载位置修复 — 首次打开文件浏览器时 git status badge 位置正确
- [x] Metal visibility fix — WindowServer CPU 修复已合入 v1.0.3，metalLayer.isHidden 双重保护
- [x] 三个 per-click 内存累积路径修复（menuNeedsUpdate / tab LRU / projectScanCache LRU），已合入 v1.0.8

## Pending Issues

- M2 运行时手测待完成（Xcode Cmd+R）：
  - 选择仓库后的状态刷新
  - Stage/Unstage/Commit/Checkout 行为
  - watcher 触发自动刷新
- M2 剩余增强：
  - 运行时手测覆盖与交互细节打磨
- M3 运行时手测待完成（Xcode Cmd+R）：
  - 项目切换后 File Tree / Git Repo 同步
  - 变更文件点击跳转 Diff
  - Cmd+P 快速查找与回车打开
  - 文件拖拽到 Terminal 粘贴路径
  - 右键菜单动作（Reveal / Open in Terminal / Copy Path）
  - 大文件与二进制文件预览体验

## REQ-007: Right Dock + 独立 Terminals (2026-05-07)

实现完成 ✅。详见 [FEAT-008](features/008-right-dock.md)。

- 中间区永远是 Terminal（dock 全屏除外）
- Files / Git / Deploy 改为右侧 Right Dock 内的固定 tab，可折叠 / 全屏 / 拖拽宽度
- Right Dock 展开时隐藏 toolbar 的 Files / Git / Deploy 重复入口；折叠时才显示 toolbar 入口用于重新打开
- Sidebar 顶部新增 "TERMINALS" 区段：独立 free terminals（cwd=$HOME，不持久化）
- 数据层：`RightDockStore`、`ActiveKind`、`FreeTerminalItem`、`TerminalNamespace` 全部带单测覆盖
- 测试结果：339 测试全部通过
- 待人工 E2E 验收：REQ-007 第 6 节列出的 20 条验收项目

## Notes

- **v1.1.6 发布 (2026-08-17)** — `build/OpenOwl-1.1.6.dmg` (35MB)，签名 + 公证 + staple + Gatekeeper 通过。内容：分屏 pane 消息总线命名入口（三点手柄右键，REQ-009，**2026-08-18 已随 REQ-009 整体删除**）、Git 面板 EBADF 修复（启动失败自动重试 + `[git]` 日志诊断 + pipe 关闭幂等化）、terminal surface 失败占位提示、buslib ID 时间戳 UTC 化。详情：`docs/releases/v1.1.6.md`

> **2026-08-18 更新**：本版本中的消息总线功能（分屏 pane 命名 / `openowl bus-send` 路由）已随 REQ-009 整体删除。本条为已发布版本的档案记录。
- 从 Electron 版迁移到 macOS 原生 (Swift + libghostty)
- 产品需求基本不变，技术栈完全重写
- 参考实现：Ghostty macOS app (macos/Sources/), cmux (manaflow-ai/cmux)
- GhosttyKit xcframework 按 commit SHA 缓存在 `~/.cache/openowl/ghosttykit/`
- Ghostty submodule pinned at commit `04fa71e2`
- 链接 libghostty 需要额外框架：Carbon, IOKit, UniformTypeIdentifiers
- actool 对非 AppIcon 命名的 appiconset 只生成部分 icns → Dev 图标改用 runtime NSApp.applicationIconImage 方案
- @Observable 迁移导致 updateNSViewController 调用时序变化 → 需要 rootNodes 比较条件性跳过 updateData
