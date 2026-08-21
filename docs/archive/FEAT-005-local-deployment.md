# FEAT-005: 本地部署服务

> 状态：✅ Done | 创建日期：2026-02-20 | 完成日期：2026-03-14

---

## 1. 功能概述

一键 clone + build + start 本地服务，带实时日志流、自动拉取更新重启、HTTP 健康检查、系统托盘菜单。支持纯远程健康监控模式。

## 2. 用户流程

### 创建部署
1. 填写名称、Git 仓库 URL、分支
2. 可选：install / build / start 命令、环境变量、端口、健康检查 URL
3. 创建后自动 clone 仓库

### 启动部署
1. 点击 Start → 依次执行 install → build → start
2. 日志实时流式输出到面板
3. 状态显示：Stopped → Building → Running / Error

### 自动更新
- 每 30s 轮询：`git fetch` + `git pull` + 检查 HEAD 变更
- HEAD 变化时自动重启（stop → build → start）

### 远程监控
- `isRemote = true` 模式：不做 git 操作，仅定期 HTTP 健康检查

### 系统托盘
- 托盘菜单显示所有部署状态
- 快速 Start / Stop 操作

## 3. 技术实现

### 3.1 架构

```
DeploymentStore (@MainActor)
  ├── DeploymentProcessManager (进程管理 + 日志流)
  ├── Persistence: UserDefaults JSON
  ├── Health Polling: URLSession + Timer
  └── Branch Polling: GitService + Timer
```

### 3.2 进程管理

```swift
DeploymentProcessManager:
  - start(deployment, env, onOutput, onExit) → Process + zsh login shell
  - 环境变量: parseEnvString() 解析 KEY=VALUE 格式（支持引号、注释）
  - 日志: stdout/stderr → readabilityHandler → 写入日志文件 + 主线程回调
  - 终止: SIGTERM → 5s grace → SIGKILL
```

Shell 启动使用 `zsh --login -c` 以继承用户环境（nvm/volta/homebrew PATH）。

### 3.3 健康检查

```swift
func checkHealth(deployment) async:
  - URLSession.shared.data(from: healthCheckURL)
  - 超时: 10s
  - 200–299 = healthy
  - 记录: lastChecked 时间戳 + error message
```

### 3.4 日志系统

- 路径: `~/.openowl/deployments/{safe-name}/logs/current.log`
- UI 显示最新 50KB（tail）
- 每 2s 轮询日志文件变更

### 3.5 数据模型

```swift
struct Deployment: Identifiable, Codable {
    let id, projectID: String
    var name, branch: String
    var isRemote: Bool        // 纯健康监控模式
    var installCommand, buildCommand, startCommand: String?
    var envVars: String?      // KEY=VALUE\nKEY2=VALUE2
    var port: Int?            // 自动注入 PORT 环境变量
    var healthCheckURL: String?
    var status: DeploymentStatus  // stopped/building/running/error
    var pid: Int32?
}
```

## 4. 注意事项

- Backward-compatible `init(from:)`: 新增字段使用 `decodeIfPresent` + 默认值，兼容旧 JSON
- 进程 PID 通过 `kill(pid, 0)` 验证存活状态
- Clone 使用 `--single-branch` 减少下载量
- 环境变量中 `PORT` 会被 port 字段覆盖（如果设置了 port）

## 5. 相关需求

- [REQ-004: 本地部署服务](./REQ-004-local-deployment.md)

## 6. 更新记录

| 日期 | 说明 |
|------|------|
| 2026-03-16 | 创建文档 |
