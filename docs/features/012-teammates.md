# FEAT-012: Teammates 面板（Claude swarm 实时视图）

> 状态：✅ Done | 创建日期：2026-08-30 | 完成日期：2026-08-30

---

## 1. 功能概述

在 Right Dock 增加 **Teammates** tab，实时展示正在运行的 **Claude Code Team / swarm 多智能体会话**（即 CLI 里打印 `View teammates: tmux -L claude-swarm-<pid> a` 的那一类），并可一键在 openOwl 内置终端里 attach 到对应 swarm 视图。

设计定位（对比同类产品）：

- **C 类（状态面板）**：`ps` + `tmux` 枚举出每个 teammate 的名字、颜色、role、model，按 swarm 会话分组 —— 元数据层信息。
- **B 类（tmux attach）**：openOwl 是终端 app，点一行就在新终端 tab 里执行 `tmux -L claude-swarm-<pid> a`，直接看到 Claude 官方的多分屏实时视图 —— 这是 Cursor / Continue 等非终端工具做不到的。

## 2. 用户流程

1. 用 Claude Code 起一个 Team / swarm 会话（父进程打印 `View teammates: …`）
2. 在 openOwl Right Dock 切换到 **Teammates** tab
3. 面板每 5s 轮询，列出每个 live swarm：socket 名、pane 数、每个 pane 对应的 agent（色点 + 名字 + role + model）、第一 pane 的最近输出尾部
4. 点某 swarm 的 attach 按钮 → openOwl 在中间终端区新建一个 tab，执行 `tmux -L claude-swarm-<pid> a`，并折叠 dock 让终端可见
5. 会话结束 → 该 swarm 从列表消失（socket 失活）

## 3. 技术实现

### 3.1 数据源（两路交叉）

| 源 | 命令 | 拿到的信息 |
|----|------|-----------|
| tmux socket | 扫描 `/private/tmp/tmux-<uid>/claude-swarm-*`；`tmux -L <s> ls` 探活；`tmux -L <s> list-panes -a -F "#{pane_index}\t#{pane_pid}\t#{pane_title}"` | swarm 会话、pane 数、pane 标题 |
| pane 进程 | 对每个 `pane_pid` 跑 `ps -p <pid> -o args=` | `--agent-id/name/color/type/model`（**确定性映射**，不靠标题模糊匹配） |

- 关键：**tmux `pane_pid` = 该 pane 里跑的 claude agent 进程**，直接用它把 pane ↔ agent 绑定，避开了 pane 标题（可能是 `✳ general-purpose`、`✳ Thai-learn-web 复杂度简化`……）与 agent 名字不一致的问题。
- socket 名 `claude-swarm-<pid>` 里的 pid 就是父 `claude --dangerously-skip-permissions` 进程。
- tmux 二进制用绝对路径探测（`/opt/homebrew/bin/tmux` → `/usr/local/bin/tmux` → `/usr/bin/tmux`）——GUI 启动的 app PATH 里没有 Homebrew，不能依赖 `/usr/bin/env`。

### 3.2 扫描器 `ClaudeSwarmScanner`

`openOwl/Features/Teammates/ClaudeSwarmScanner.swift`

- 纯函数式解析，可单测：`parseAgent(args:pid:)`、`parsePanesOutput(_:)`
- 所有子进程调用带 3s 超时（`DispatchGroup` + terminate），防止挂起
- 模型：`TeammateAgent`（pid/id/name/team/colorName/type/model）、`TeammatePane`（index/title/agent）、`ClaudeSwarmSession`（socketName/ownerPID/panes/outputTail）

### 3.3 Store `TeammatesStore`

`openOwl/Features/Teammates/TeammatesStore.swift`

- `@MainActor @Observable`，镜像 `ClaudeStatusStore` 的轮询模式：`startPollingIfNeeded()` / `stopPolling()`，5s 间隔
- 扫描在 `Task.detached(priority: .utility)` 里跑，主线程只接收结果
- `lastError`：tmux 缺失时提示原因（GUI PATH 无 Homebrew 的常见坑）

### 3.4 视图 `TeammatesView`

`openOwl/Features/Teammates/TeammatesView.swift`

- 每个 live swarm 一张卡片：socket 名 + pane 数 + attach 按钮 + 每 pane 一行（色点按 `--agent-color` 映射）+ 第一 pane 输出尾部（等宽 3 行）
- attach：`workspace.newTab(for: nil, configuration: TerminalSurfaceConfiguration(command: "tmux -L <socket> a"))` → `notifyContextChange()` → `dock.collapse()`（让终端可见）

### 3.5 集成

- `RightDockTab` 新增 `.teammates`（title "Teammates"，icon `person.2`），`showsDetailForActiveTab = false`（列表型，dock 用窄宽 280）
- `RightDockView.contentArea` 常驻挂载（与 Files/Git 一样 opacity + allowsHitTesting 切换，保留状态）
- `openOwlApp` 注入 store，与 `ClaudeStatusStore` 同生命周期启停轮询
- `StatusBarView.visibleArea` 与 `openOwlApp.syncActiveProjectContext` 补 `.teammates` 分支（teammates 与项目上下文无关 → break）

## 4. 注意事项

- 只展示 **live** 的 swarm（socket 探活）；已结束的会话立即消失
- 只解析 `--agent-id` 的 claude 进程（`claude/versions/*`），不会误伤其它 claude CLI
- 不修改 Claude 侧任何状态——只读 `ps` / `tmux`，attach 执行官方命令
- 面板不跟随项目上下文（swarm 是 workspace 级的）

## 5. 相关需求

- [REQ-007-right-dock.md](../requirements/REQ-007-right-dock.md)

## 6. 测试

`openOwlTests/ClaudeSwarmScannerTests.swift` — 7 个单测（Swift Testing）：

- `parseAgent_*`：全字段、`model=opus[1m]` 带括号、缺 color 拒绝、非 agent 命令行拒绝、未知 flag（`--parent-session-id`）不干扰后续解析
- `parsePanesOutput_*`：按 index 排序、未知 pid 不丢 pane、坏行跳过好行保留

## 7. 更新记录

| 日期 | 说明 |
|------|------|
| 2026-08-30 | 首版：扫描器 + store + 面板 + attach；7 个单测通过；Debug 构建通过 |