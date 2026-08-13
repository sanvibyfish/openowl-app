# REQ-009: 跨 Agent 消息总线 (Message Bus)

> 状态：🟡 In Progress（Phase 1 ✅，Phase 2 实现中）| 优先级：P1 | 预估：Phase 1 一天 + Phase 2 两三天 | 创建日期：2026-08-11

---

## 1. 需求概述

openOwl / codex / claude / pi 四方之间互发消息：任意一方可以向任意另一方投递消息，接收方**自动**（或半自动）把消息注入自己的对话循环并处理，处理后按需回执。参考 Claude Code cross-session SendMessage 的 actor/mailbox 设计，但不复制上下文——只传递消息正文。

## 2. 背景与动机

- 用户同时运行多个 agent 工作流：pi（本对话）、codex（交互 + `codex exec`）、claude（Claude Code）、以及 openOwl 里承载这些终端的多个 pane。
- 现状：agent 之间互相隔离，消息靠人复制粘贴；「派活 → 执行 → 回报」的协作链路没有通道。
- Claude Code 2.1.224+ 已实现同款能力（session 注册表 + 邮箱 + 唤醒），本需求将其**通用化**：一套总线协议 + 每方一个适配器，不绑定任何单一 harness。
- 技术背景（2026-08-11 已核实）：
  - pi：RPC 模式 `prompt` 命令（`streamingBehavior: steer`）+ 扩展 API `sendMessage(..., {triggerTurn})` + `before_agent_start` 注入 + `session_start` 起后台 timer/文件监听 → **原生接收通道可用**
  - codex 0.147.0：hooks 支持 `SessionStart` / `UserPromptSubmit` / `Stop` 等，hook stdout 作为附加 context 拼入 prompt → **回合前注入可用**
  - claude：原生 cross-session SendMessage（官方 changelog）
  - openOwl：拥有全部终端 pane 的 PTY，`TerminalPane.id` 提供寻址，FileWatcher 提供事件

## 3. 用户故事

- **US-1**：codex 给正在运行的 pi 对话发消息，pi 自动收到并作为新回合处理。
- **US-2**：pi 给 codex 派活（`codex exec` 模式），codex 启动时自动带上积压消息，处理完回报。
- **US-3**：给交互式 codex 的消息，在 codex 下一个回合开始前自动注入（`UserPromptSubmit` hook），无需人粘贴。
- **US-4**：任意 agent 能查询注册表（谁在线、谁能收、heartbeat）。
- **US-5**：消息可回复（`replyTo` 路由），处理结果可回执。

## 4. 功能描述

### 4.1 总线协议（`~/.openowl/bus/`）

```
~/.openowl/bus/
├── agents.json              # 注册表
├── inboxes/{agent}.jsonl    # 每 agent 消息队列（追加写 + flock）
└── replies/{agent}.jsonl    # 回执队列（可选，v1 用 inbox 里的 replyTo 即可）
```

**agents.json 注册表**：

```json
{
  "agents": {
    "pi-main":  { "kind": "pi",     "sessionId": null, "cwd": "...", "heartbeat": "ISO8601" },
    "codex-a":  { "kind": "codex",  "cwd": "...", "heartbeat": "ISO8601" },
    "claude-1": { "kind": "claude", "cwd": "...", "heartbeat": "ISO8601" },
    "openowl":  { "kind": "openowl","paneId": null, "heartbeat": "ISO8601" }
  }
}
```

**消息格式**（JSONL 一行一条）：

```json
{"id":"...","from":"codex-a","to":"pi-main","ts":"2026-08-11T04:00:00Z","kind":"message","body":"...","replyTo":null,"meta":{}}
```

**id 规则（实现决策 2026-08-11）**：`YYYYMMDDHHMMSSffffff + pid(4hex) + 进程内计数器(4hex)`。原因：水位 = max(id) 字符串比较，随机 id 在同一微秒内不保证时间序，会静默丢消息（实测复现：同微秒第二条的随机后缀小于第一条 → 水位卡死 → 新消息永不返回）。微秒 + pid + 计数器保证全局唯一且时间单调。

写入规则：flock 串行化追加。读取规则：每个接收方维护**已读水位**（cursor 文件），只处理水位之后的消息；消息不删除（审计 + 断点恢复）。回执：`bus-ack <id>` 按 id 定位所属 inbox 并推进该 agent 水位（`buslib.ack_by_id`）；`bus-ack --agent <name>` 整体清空。

### 4.2 注入格式约定

hook / 扩展向对话注入时用固定包裹：

```
<inbox-message from="codex-a" ts="..." id="...">消息正文</inbox-message>
```

配合系统指令：「这些是其他 agent 发给你的待处理消息；处理完调用 `bus-ack <id>` 标记已办，需要回复时用 `bus-send`」。

**Token 控制**（硬约束）：
- 只注入未读消息
- 单次注入条数上限：5
- 单条长度上限：2000 字符，超长截断并附 `<truncated>` 标记
- 注入块总长上限：8000 字符

### 4.3 适配器职责

| 参与方 | 发送 | 接收 |
|---|---|---|
| **codex** | bash 调 `bus-send`（零开发） | `SessionStart` hook（exec 每次启动注入积压）；`UserPromptSubmit` hook（交互回合前注入）；`Stop` hook（回合结束回执/已读） |
| **pi** | bash 调 `bus-send` | TypeScript 扩展：`session_start` 起 timer 轮询 inbox → `ctx.sendMessage(..., {triggerTurn:true})` 注入 |
| **claude** | bash 调 `bus-send`；v2 用原生 SendMessage | v1：`SessionStart`-类 hook 或任务开头轮询；v2：原生 SendMessage |
| **openOwl** | 消息中心 UI / AppleScript（v2） | FileWatcher 监听 inbox → 系统通知 + 目标 pane 预填输入行（v2） |

### 4.4 安全与边界（v1）

- 单机全信任：只有用户自己的 agent，无跨机、无权限分级
- inbox 目录权限 700，文件 600（用户可写可读）
- 注入语义：**提示 agent 处理消息**，不自动执行任何命令；消息正文视为不可信输入（agent 需谨慎处理）
- `bus-send` 不做鉴权（v1），任何本机进程可投递——文档明示风险
- **已知限制（多 pi session）**：pi 扩展的 agent 名解析顺序为 `BUS_AGENT` env → session 名 → `pi`；未设 `BUS_AGENT` 的多个 pi session 会共用 `pi.jsonl` 收件箱与同一水位，先轮询到的 session 会消费消息。需要多 pi 接收时各自设 `BUS_AGENT`（v2 由 openOwl 注册表统一管理）

## 5. 非目标（v1）

- 跨机器投递（Claude Remote Control 类）— v2
- 消息加密 / 权限分类器（Claude 的 permission classifier 类）— v2
- openOwl 消息中心 UI / 注册表可视化 — v2
- 已读回执 UI — v2

## 6. 技术方案

### 6.1 CLI 与脚本

- **统一入口 `~/.openowl/bin/openowl`**（子命令分发）：
  - `openowl bus-send <to> "<body>" [--from <agent>] [--kind message|task] [--reply-to <id>]`
  - `openowl bus-ack <id>...`（按 id 定位推进）或 `openowl bus-ack --agent <name>`（清空）
  - `openowl bus-list [--online]`
- 设计决策（2026-08-11）：总线 CLI 独立于 GUI app 进程——agent 从 bash 调用时 app 可能未运行；`openowl` 统一入口避免散落脚本，`bus-send`/`bus-ack`/`bus-list` 保留为内部可执行体
- 源码在 openOwl 仓库 `scripts/message-bus/`（`buslib.py` 协议核心 + `openowl` 分发器 + 三个命令 + `codex-hook.js`），`install.sh` 复制到 `~/.openowl/bin/` 并在 `~/.zshrc` 追加 PATH

### 6.2 codex 适配器

- 脚本：`scripts/message-bus/codex-hook.js`（读 inbox → 未读 → 输出 `<inbox-message>` 块 → 更新水位）
- 注册：`~/.codex/hooks.json` 追加 `SessionStart` / `UserPromptSubmit` / `Stop`（保留现有 confirmo hooks）
- 验证：写测试消息 → `codex exec "查看收件箱"` → 确认输出包含注入内容

### 6.3 pi 适配器

- 扩展：`~/.pi/agent/extensions/message-bus/`（TypeScript）
  - `session_start`：启动 timer（间隔可配，默认 3s）轮询 `~/.openowl/bus/inboxes/<本session>.jsonl`
  - 有新消息 → `ctx.sendMessage(..., {triggerTurn:true})` 注入
  - `session_shutdown`：清理 timer
- 验证：写测试消息 → 运行中 pi 会话收到新回合（独立 `pi --mode rpc` 实例测试加载，再真人实测）

### 6.4 openOwl 集成（Phase 2）

- **注册表维护**：`MessageBusService`（Swift，`openOwl/Services/`）在 app 启动时把 `openowl` 注册进 `agents.json`，监听 `workspaceStore` 的 pane 生命周期把每个终端 pane 注册为 `pane-{id}`（kind=`openowl-pane`，带 `paneId`），周期性刷新 heartbeat
- **pane 总线命名（地址 ≠ 路由键）**：总线地址必须是人类可读的，pane UUID 只作内部路由键。命名优先级：**右键显式名 > pane 标题（OSC）> `pane-N` 序号**。Free Terminal 顶部 tab pill 右键 → 「Set Message Bus Name…」弹窗输入（NSAlert），命名后 tab 标签直接显示总线名，注册表条目保留 `paneId` 供路由。显式名存 `~/.openowl/bus/pane-names.json`（按 pane UUID，会话级——重启后重设）
- **消息中心 UI**：Right Dock 新增 `.bus` tab（`BusCenterView`）：在线 agent 列表 + 发给 openowl 的消息流 + 发送框（to + body）；复用 flock/JSONL 协议，与 `buslib.py` 完全兼容
- **新消息通知**：`MessageBusService` 监听 `inboxes/` 目录（FSEventStream）→ 系统通知（含“交互式 codex 有新消息”的触发提示，REQ-009 用例 US-3 的补全）
- **数据通路**：Swift 直接读写 bus 文件（flock + JSONL），不依赖 python3 运行时

## 7. 验收标准

- [ ] `bus-send` 四方互发：codex → pi、pi → codex、claude → codex、任意 → openowl（Phase 1 内）
- [ ] codex exec 模式：写 inbox + 触发 exec → codex 回合包含 `<inbox-message>` 内容，且不重复注入（水位正确）
- [ ] 交互式 codex：`UserPromptSubmit` hook 注入生效（spike 实测确认 stdout 语义）
- [ ] pi 扩展：外部写 inbox → 运行中 pi 收到新回合并触发处理
- [ ] 回执：`bus-ack` 后消息不再注入（水位推进）
- [ ] token 上限生效：超量/超长消息截断
- [ ] 与现有 hooks（confirmo）共存，不破坏

## 8. 里程碑

- **Phase 1（本次）**：bus 协议 + `openowl` CLI + codex hooks 适配器 + pi 扩展适配器 + 验收 ✅ 2026-08-11
- **Phase 2（进行中）**：
  - ✅ `MessageBusService`（Swift，`openOwl/Services/`）：注册 `openowl` + 每个 pane（`pane-{id}`）+ heartbeat + inbox 轮询 + 发送/水位；与 `buslib.py` 字节级互通（`MessageBusServiceTests` 三个跨实现测试验证）
  - ✅ Right Dock `.bus` tab（`BusCenterView`）：在线 agent chips + 消息流 + 发送框
  - ✅ pane 总线命名：tab pill 右键设置名字（override > pane 标题 > 序号），tab 标签显示总线名
  - ⬜ 新消息系统通知（app 已轮询 inbox，通知接入待做）
  - ⬜ 交互式 codex 触发提示
- **Phase 2 已搁置项**：claude 原生 SendMessage 适配（v1 用 `openowl bus-send` 已满足）、多 pi session 的 BUS_AGENT 自动管理（文档已有手动方案）

## 9. 相关文档

- 调研记录：`docs/memory/2026-08-11.md`
- Claude Code SendMessage 设计（参考）：https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md
