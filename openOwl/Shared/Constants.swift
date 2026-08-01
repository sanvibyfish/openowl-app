import Foundation
import SwiftUI

enum AppConstants {
    static let appName = "openOwl"

    // Ghostty
    static let termEnv = "xterm-ghostty"
    static let ghosttyResourcesDirEnv = "GHOSTTY_RESOURCES_DIR"

    // Layout
    static let contentMinWidth: CGFloat = 400
    static let windowMinWidth: CGFloat = 800
    static let windowMinHeight: CGFloat = 500
}

// MARK: - Design System

/// 语义调色盘 — 自适应亮/暗模式，尊重用户系统设置
enum AppPalette {
    // 背景 4 层（system semantic colors adapt to light/dark mode）
    static let base      = Color(nsColor: .windowBackgroundColor)
    static let surface   = Color(nsColor: .controlBackgroundColor)
    static let elevated  = Color(nsColor: .underPageBackgroundColor)
    static let overlay   = Color(nsColor: .controlBackgroundColor)

    // 文字 3 层
    static let textPrimary: Color   = .primary
    static let textSecondary: Color = .secondary
    static let textTertiary  = Color(nsColor: .tertiaryLabelColor)

    // 边框 — hairline-soft so chrome recedes (Muxy-style); hover still a bit stronger
    static let border      = Color.primary.opacity(0.08)
    static let borderHover = Color.primary.opacity(0.14)

    // 强调色（respects user's system accent color）
    static let accent: Color = .accentColor

    // NSColor 变体 — 供 CodeEditSourceEditor 等需要 NSColor 的 API 使用
    enum ns {
        static let surface: NSColor   = .controlBackgroundColor
        static let elevated: NSColor  = .underPageBackgroundColor
        static let textPrimary: NSColor = .labelColor
        static let accent: NSColor    = .controlAccentColor
    }
}

enum AppFonts {
    // MARK: - Semantic fonts (macOS 26+ scales with Dynamic Type, older macOS keeps fixed size)

    static var title: Font {
        if #available(macOS 26, *) { return .headline }
        return .system(size: 16, weight: .semibold)
    }
    static var sectionHeader: Font {
        if #available(macOS 26, *) { return .caption.weight(.semibold) }
        return .system(size: 10, weight: .semibold)
    }
    static let sectionTracking: CGFloat = 1.5
    static var primaryLabel: Font {
        if #available(macOS 26, *) { return .callout.weight(.medium) }
        return .system(size: 12, weight: .medium)
    }
    static var secondaryLabel: Font {
        if #available(macOS 26, *) { return .subheadline }
        return .system(size: 11)
    }
    static var body: Font {
        if #available(macOS 26, *) { return .callout }
        return .system(size: 12)
    }
    static var mono: Font {
        if #available(macOS 26, *) { return .system(.subheadline, design: .monospaced) }
        return .system(size: 11, design: .monospaced)
    }
    static var caption: Font {
        if #available(macOS 26, *) { return .caption }
        return .system(size: 10)
    }
    static var statusBar: Font {
        if #available(macOS 26, *) { return .subheadline }
        return .system(size: 11)
    }

    // Intentionally fixed: 9pt badge is too small for any semantic font
    static let badge = Font.system(size: 9, weight: .medium)

    // MARK: - Fixed-size fonts (alignment-critical, always monospaced)

    static let diffCode   = Font.system(size: 11, design: .monospaced)
    static let diffMeta   = Font.system(size: 9, weight: .bold, design: .monospaced)

    // MARK: - Icon sizing (used for SF Symbol sizing in toolbars/buttons)

    static let toolbarIcon = Font.system(size: 10)
    static let smallIcon   = Font.system(size: 9)
    static let tinyIcon    = Font.system(size: 8)
}

enum AppSpacing {
    static let cornerRadius: CGFloat = 6
    static let cornerRadiusSmall: CGFloat = 4
    static let itemGap: CGFloat = 6
    static let panelPadding: CGFloat = 12
    /// Matches `editorTabBarHeight` so a panel's tool header and the editor /
    /// diff tab bar beside it sit on the same baseline — a 32/28 mismatch put
    /// a visible step in the divider between the two columns.
    static let headerHeight: CGFloat = 28
    static let statusBarHeight: CGFloat = 28
    static let editorTabBarHeight: CGFloat = 28
    static let listRowHeight: CGFloat = 26
}

// MARK: - Editor Theme Colors (syntax highlighting — precise values, not semantic)

enum AppEditorTheme {
    static let selection  = NSColor(calibratedRed: 0.25, green: 0.35, blue: 0.5, alpha: 0.4)
    static let keyword    = NSColor(calibratedRed: 0.8, green: 0.4, blue: 0.8, alpha: 1.0)
    static let command    = NSColor(calibratedRed: 0.4, green: 0.7, blue: 0.9, alpha: 1.0)
    static let type       = NSColor(calibratedRed: 0.4, green: 0.8, blue: 0.7, alpha: 1.0)
    static let attribute  = NSColor(calibratedRed: 0.7, green: 0.6, blue: 0.4, alpha: 1.0)
    static let variable   = NSColor(calibratedRed: 0.5, green: 0.7, blue: 0.9, alpha: 1.0)
    static let value      = NSColor(calibratedRed: 0.9, green: 0.7, blue: 0.4, alpha: 1.0)
    static let number     = value
    static let string     = NSColor(calibratedRed: 0.9, green: 0.5, blue: 0.5, alpha: 1.0)
    static let character  = string
    static let comment    = NSColor(calibratedRed: 0.5, green: 0.6, blue: 0.5, alpha: 1.0)
    static let invisibles = NSColor(white: 0.5, alpha: 0.3)
}

// MARK: - Git Graph Lane Colors (data visualization palette)

enum AppGraphColors {
    static let lanes: [Color] = [
        Color(red: 0.31, green: 0.79, blue: 0.69),  // teal
        Color(red: 0.81, green: 0.57, blue: 0.47),  // salmon
        Color(red: 0.34, green: 0.61, blue: 0.84),  // blue
        Color(red: 0.86, green: 0.86, blue: 0.67),  // yellow
        Color(red: 0.77, green: 0.52, blue: 0.75),  // magenta
        Color(red: 0.61, green: 0.86, blue: 0.99),  // light blue
        Color(red: 0.84, green: 0.73, blue: 0.49),  // gold
        Color(red: 0.71, green: 0.81, blue: 0.66),  // green
        Color(red: 0.82, green: 0.41, blue: 0.41),  // red
        Color(red: 0.38, green: 0.55, blue: 0.31),  // dark green
    ]
}
