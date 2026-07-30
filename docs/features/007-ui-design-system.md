# FEAT-007: UI 设计系统升级

> 状态：🔵 Draft | 创建日期：2026-03-16

---

## 1. 现状审查

### 1.1 对比分析（openOwl vs Seedex AI）

| 维度 | Seedex AI | openOwl 现状 | 差距 |
|------|-----------|-------------|------|
| **背景层次** | 3 层深色（base/surface/elevated），卡片浮起感 | 单一 windowBackgroundColor，全部平铺 | 缺少层次感 |
| **侧边栏** | 深色毛玻璃 `.behindWindow`，透出壁纸 | NavigationSplitView 默认样式 | 缺少材质感 |
| **排版** | 大标题衬线体 + 正文无衬线 + SMALL CAPS 分区标签 | 全局 system font 11-12pt，无层次 | 字体单调 |
| **选中态** | accent 左竖条 + 圆角浅色背景 | 系统蓝色高亮行 | 缺少品牌感 |
| **留白** | 大量呼吸空间，行高宽松 | 信息密度高，22px 行高无间距 | 拥挤 |
| **Tab 栏** | 顶部简洁文字 + 选中下划线 | Toolbar pill 按钮 | 不够简洁 |
| **分区标题** | `SUMMARY` / `OUTLINE` 小型大写 + 间距 | `EXPLORER` / `CHANGES` 直接 semibold | 缺少设计感 |

### 1.2 Apple HIG 审查

根据 Apple Human Interface Guidelines：

- **Materials**: 应使用系统材质创建深度和层次，同时保持清晰度 → openOwl 侧边栏已用 `EffectView(.sidebar, .behindWindow)` 但内容区无层次
- **Color**: 颜色应表达交互性和视觉连续性 → openOwl 缺少统一的调色盘，颜色分散在各处硬编码
- **Layout**: 一致的布局让用户更自信 → openOwl 各面板内边距不一致（有的 8px、有的 10px、有的 12px）
- **Custom Interfaces**: 自定义界面应与平台惯例保持一致 → Tab 栏风格偏移了 macOS 原生感

---

## 2. 设计方案

### Phase 1: 调色盘 + 侧边栏（最高优先）

#### 2.1 暗色调色盘

```swift
enum AppPalette {
    // 背景 4 层（从深到浅）
    static let base      = Color(nsColor: NSColor(red: 0.078, green: 0.078, blue: 0.086, alpha: 1)) // #141416
    static let surface   = Color(nsColor: NSColor(red: 0.110, green: 0.110, blue: 0.122, alpha: 1)) // #1c1c1f
    static let elevated  = Color(nsColor: NSColor(red: 0.141, green: 0.141, blue: 0.157, alpha: 1)) // #242428
    static let overlay   = Color(nsColor: NSColor(red: 0.173, green: 0.173, blue: 0.192, alpha: 1)) // #2c2c31

    // 文字 3 层
    static let textPrimary   = Color(nsColor: NSColor(white: 0.91, alpha: 1))  // #e8e8ed
    static let textSecondary = Color(nsColor: NSColor(white: 0.56, alpha: 1))  // #8e8e93
    static let textTertiary  = Color(nsColor: NSColor(white: 0.35, alpha: 1))  // #5a5a5f

    // 边框
    static let border     = Color.white.opacity(0.06)
    static let borderHover = Color.white.opacity(0.12)

    // 强调色（柔和蓝）
    static let accent = Color(nsColor: NSColor(red: 0.42, green: 0.71, blue: 0.93, alpha: 1)) // #6cb4ee
}
```

HIG 依据：macOS Dark Mode 推荐使用有深度的暗色层次，而非纯黑。纯黑 #000000 在 OLED 上可以，但在 LCD 上显得"洞"一样。暖灰色底（#141416 偏蓝灰）更柔和。

#### 2.2 侧边栏选中样式

当前选中项用系统默认蓝色高亮行。改为 accent 左竖条 + 浅色圆角背景：

```swift
// 选中行
HStack(spacing: 0) {
    RoundedRectangle(cornerRadius: 1)
        .fill(AppPalette.accent)
        .frame(width: 3)
        .padding(.vertical, 4)

    content
        .padding(.leading, 8)
}
.background(
    RoundedRectangle(cornerRadius: 6)
        .fill(AppPalette.accent.opacity(0.12))
)
```

#### 2.3 分区标题样式

```swift
// 当前
Text("EXPLORER").font(.system(size: 11, weight: .semibold))

// 改为 small caps + tracking
Text("EXPLORER")
    .font(.system(size: 10, weight: .semibold))
    .tracking(1.5)
    .foregroundStyle(AppPalette.textTertiary)
```

### Phase 2: Tab 栏 + 内容层次

#### 2.4 Tab 栏下划线式

从 pill 按钮改为底部线条指示器：

```swift
// 当前
.background(RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.15)))

// 改为
VStack(spacing: 0) {
    Text(tab.title).font(.system(size: 13, weight: .medium))
    if isActive {
        Capsule()
            .fill(AppPalette.accent)
            .frame(height: 2)
            .matchedGeometryEffect(id: "tabIndicator", in: tabNamespace)
    }
}
```

`matchedGeometryEffect` 让下划线在 Tab 切换时平滑滑动。

#### 2.5 面板内边距统一

| 位置 | 当前 | 统一后 |
|------|------|--------|
| 面板头部 horizontal | 8/10/12 不一 | 12 |
| 面板头部 vertical | 4-6 | 8 |
| 面板头部高度 | 28px | 32px |
| 列表行高 | 22px | 26px |
| 列表行内边距 | 8 | 10 |

### Phase 3: 排版 + 微交互

#### 2.6 字体层次

```swift
enum AppFonts {
    // 面板大标题（文件名、commit 标题等）
    static let title = Font.system(size: 16, weight: .semibold)

    // 分区标题（CHANGES, STAGED, EXPLORER 等）
    static func sectionHeader() -> Font {
        .system(size: 10, weight: .semibold)
    }
    static let sectionTracking: CGFloat = 1.5

    // 正文
    static let body = Font.system(size: 12)

    // 辅助标签
    static let caption = Font.system(size: 10)

    // 代码/路径
    static let mono = Font.system(size: 11, design: .monospaced)

    // Badge
    static let badge = Font.system(size: 9, weight: .medium)
}
```

#### 2.7 微交互

| 交互 | 实现 |
|------|------|
| Tab 切换 | `matchedGeometryEffect` 下划线滑动 |
| 侧边栏 hover | `overlay` 背景 `.animation(.easeIn(duration: 0.1))` |
| 面板折叠 | `spring(duration: 0.25, bounce: 0.1)` |
| Git badge 出现 | `.transition(.scale.combined(with: .opacity))` |
| Quick Open 弹出 | `.transition(.move(edge: .top).combined(with: .opacity))` （已有） |

#### 2.8 空状态设计

```swift
VStack(spacing: 12) {
    Image("MenuBarIcon")  // 猫头鹰 icon
        .resizable()
        .frame(width: 40, height: 40)
        .opacity(0.3)

    Text("No commits yet")
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(AppPalette.textSecondary)

    Text("Make your first commit to see the graph")
        .font(.system(size: 11))
        .foregroundStyle(AppPalette.textTertiary)
}
```

---

## 3. 实施计划

| 阶段 | 改动 | 影响文件 | 预估 |
|------|------|---------|------|
| **P1-1** | AppPalette 调色盘 | Constants.swift | 小 |
| **P1-2** | 分区标题 tracking + textTertiary | 所有面板 header | 小 |
| **P1-3** | 侧边栏选中竖条 | SidebarView.swift | 中 |
| **P2-1** | Tab 栏下划线 + matchedGeometryEffect | ContentView.swift | 中 |
| **P2-2** | 面板内边距统一 32px header + 26px 行高 | 所有面板 | 中 |
| **P2-3** | 内容区背景层次 (surface vs base) | ContentView.swift | 小 |
| **P3-1** | 微交互动画 | 各处 | 小 |
| **P3-2** | 空状态猫头鹰 | Git/FileExplorer | 小 |

---

## 4. 设计原则

1. **层次优先于装饰**: 用背景色深浅区分层级，不用线框
2. **呼吸感**: 宁可留白多一点，不要信息挤在一起
3. **统一 token**: 所有颜色/字体/间距都从 AppPalette/AppFonts 取，不硬编码
4. **动画克制**: 只在状态切换时加动画，不加无意义的装饰动画
5. **macOS 原生**: 侧边栏用系统材质，不自造 blur

## 5. 相关需求

- 无独立需求文档（属于全局设计改进）

## 6. 更新记录

| 日期 | 说明 |
|------|------|
| 2026-03-16 | 创建设计方案 |
| 2026-07-28 | 信息架构对齐 Muxy：左栏改为 `ProjectRail`（见 FEAT-006）；调色盘/选中竖条等 Phase 1 token 部分落地 |
