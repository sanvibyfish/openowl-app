# FEAT-012: Teammates 面板（Claude / Codex / Pi 会话实时视图）

> 状态：⏸️ Archived（已移除）| 创建日期：2026-08-30 | 完成日期：2026-08-30 | 移除日期：2026-10-06
>
> **2026-10-06 整体移除**：Right Dock 的 Teammates tab、`TeammatesStore`、`TeammatesView`
> 与三个会话扫描器（`ClaudeSwarmScanner` / `CodexSessionScanner` / `PiSessionScanner`）
> 及对应单测已从代码库删除；`RightDockTab` 回到 `files` / `git` 两个 tab。
> 本文档仅作历史存档，方便未来重新评估该功能。

---

## 1. 功能概述

在 Right Dock 增加 **Teammates** tab，实时展示正在运行的**多智能体会话**，并在终端/编辑器里一键 attach：

| 源 | 基底 | 展示内容 | attach |
|----|------|---------|--------|
| **Claude** | tmux swarm（CLI 打印 `View teammates: tmux -L claude-swarm-<pid> a`） | 每个 pane 一个 agent：色点 + 名字 + role + model + 输出尾部 | `tmux -L <socket> a` → 新终端 tab |
| **Codex** | app-server daemon + 本地 `session_index.jsonl` / archived rollouts | 最近会话：标题 + 更新时间 + cwd | `codex resume <id>` → 新终端 tab |
| **Pi** | `~/.pi/agent/sessions/<项目>/<ts>_<id>.jsonl` 转录 | 最近会话：首条用户消息 + 项目 + model，**当前对话即是 live** | 打开转录文件 → 编辑器 |

设计定位：**C 类（状态面板）+ B 类（attach）** —— 面板给元数据列表，attach 直达官方视图（Claude/Codex 的 tmux/CLI，Pi 的 transcript），这是纯非终端工具做不到的。

## 2. 用户流程

1. 任一生态起会话（Claude Team/swarm、codex 会话、pi 对话）
2. Right Dock → **Teammates** tab，面板每 5s 轮询
3. 每个会话一张卡片：源徽标（Claude 紫 / Codex 青 / Pi 蓝）+ 名字 + 状态点 + detail + 各 agent 行
4. attach：Claude/Codex → 终端新 tab 执行命令并折叠 dock；Pi → 编辑器打开转录并切到 Files tab

## 3. 技术实现

### 3.1 数据源

**Claude（`ClaudeSwarmScanner`）**：扫描 `/private/tmp/tmux-<uid>/claude-swarm-*`（`tmux -L <s> ls` 探活）→ `list-panes -a -F "#{pane_index}\t#{pane_pid}\t#{pane_title}"` → 对每个 `pane_pid` 跑 `ps -o args=` 拿 `--agent-id/name/color/type/model`。**pane→agent 用 `pane_pid` 确定性映射**，不做标题模糊匹配；`capture-pane` 取第一 pane 输出尾部。

**Codex（`CodexSessionScanner`）**：读 `~/.codex/session_index.jsonl`（`{id, thread_name, updated_at}`，按 updated_at 排序取最近 15 条）；cwd 从匹配的 `archived_sessions/rollout-*.jsonl` 首行 `session_meta` 按需读取（≤15 个文件）。live 判定 = `updated_at` 在 10 分钟内。

**Pi（`PiSessionScanner`）**：扫描 `~/.pi/agent/sessions/*/*.jsonl` 按 mtime 取最近 12 条；解析头部行取 cwd（session 记录）、model（`model_change`）、标题（首条用户文本，换行折叠 + 72 字截断）。live = mtime 10 分钟内（当前对话即 live）。

### 3.2 通用模型（`TeammateModels.swift`）

- `TeammateSource`：`.claude` / `.codex` / `.pi`
- `TeammateAgent`：pid(Claude 专属)/id/name/team/colorName/type/model
- `TeammateSession`：source/id/name/detail/agents/outputTail/attach/timestamp，`isLive` 计算属性（claude 恒 live）
- `TeammateAttach`：`.command(String)`（终端 tab）或 `.openFile(String)`（编辑器）

### 3.3 Store `TeammatesStore`

- `@MainActor @Observable`，5s 轮询；三个 `Task.detached` 并行扫描后合并
- 排序：live 优先，再按 timestamp 降序；上限 25 条
- `notice`：tmux 缺失时提示（GUI PATH 无 Homebrew 的坑），不影响 Codex/Pi 展示

### 3.4 视图 `TeammatesView`

- 卡片头：源徽标（徽标颜色=源类别）+ 名字 + live 点 + detail + attach 按钮
- agent 行：色点（`--agent-color`，或 live 绿点）+ 名字 + role + model
- attach 分发：`.command` → `workspace.newTab(for: nil, configuration: TerminalSurfaceConfiguration(command:))` + `dock.collapse()`；`.openFile` → post `.openFileFromTerminal` 通知 + `dock.activeTab = .files`

### 3.5 集成

- `RightDockTab` 新增 `.teammates`（title "Teammates"，icon `person.2`），列表型（dock 窄宽 280）
- `RightDockView.contentArea` 常驻挂载（opacity + allowsHitTesting 切换）
- `openOwlApp` 注入 store，与 `ClaudeStatusStore` 同生命周期启停轮询
- `StatusBarView.visibleArea` 与 `syncActiveProjectContext` 补 `.teammates` 分支

## 4. 注意事项

- Claude 只展示 **live** swarm（socket 探活）；Codex/Pi 按 recency 展示（"正在运行"由 10 分钟窗口推断，无 claude 那种 pane 级硬状态）
- Pi 源展示的是 pi 会话本身（包括正在进行的对话），subagent run 落盘（`run-history.jsonl`）只有 `worker` + 打码任务，暂无可展示元数据
- `~/.codex/session_index.jsonl` 含全部历史会话 → 取最近条数上限，面板有界
- 不修改任何生态的数据 —— 只读状态、attach 走官方命令/文件

## 5. 相关需求

- [REQ-007-right-dock.md](../requirements/REQ-007-right-dock.md)

## 6. 测试

`openOwlTests/ClaudeSwarmScannerTests.swift`（7）+ `TeammateOtherScannersTests.swift`（10）：

- Claude：`parseAgent`（全字段、`opus[1m]`、缺 color 拒绝、非 agent 拒绝、未知 flag 不干扰）、`parsePanesOutput`（排序、未知 pid 不丢、坏行跳过）
- Codex：`parseIndexLine`（全字段/缺省/malformed）、rollout 文件名→uuid、首行→cwd
- Pi：头部解析（cwd/model/标题、最后 model 胜出、首条标题、换行折叠截断、非 user 忽略、空输入）

全套 443 tests / 39 suites 通过。

## 7. 更新记录

| 日期 | 说明 |
|------|------|
| 2026-08-30 | 增加 Codex 与 Pi 两个源：三源通用模型（`TeammateModels`）、`CodexSessionScanner`（session_index + rollout cwd）、`PiSessionScanner`（转录头部解析）；store 并行合并、视图按源徽标分组；新增 10 个单测（总计 17） |
| 2026-08-30 | 首版（仅 Claude）：扫描器 + store + 面板 + attach；7 个单测 |