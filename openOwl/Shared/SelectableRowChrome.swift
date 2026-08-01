import AppKit
import SwiftUI

// MARK: - Geometry tokens (SwiftUI + AppKit share these)

/// Shared metrics for list-row selection chrome across SwiftUI panels and
/// the AppKit file-tree outline. Keep fill opacity / bar size here so both
/// sides cannot drift apart.
enum SelectableRowMetrics {
    static let cornerRadius: CGFloat = AppSpacing.cornerRadius
    static let accentBarWidth: CGFloat = 2
    static let accentBarHeight: CGFloat = 14
    static let accentBarLeading: CGFloat = 2
    /// Inset of the rounded fill relative to the full row bounds (AppKit).
    static let fillInsetX: CGFloat = 2
    static let fillInsetY: CGFloat = 1
    static let selectedFillOpacity: CGFloat = 0.12
}

// MARK: - SwiftUI

/// Shared list-row selection chrome — soft accent fill + 2pt leading bar when
/// selected, quiet hover surface otherwise. Used by session list, Git rows,
/// Quick Open, and other SwiftUI lists.
struct SelectableRowChrome: ViewModifier {
    let isSelected: Bool
    var isHovering: Bool = false
    var cornerRadius: CGFloat = SelectableRowMetrics.cornerRadius
    var accentBarHeight: CGFloat = SelectableRowMetrics.accentBarHeight

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(rowFill)
            )
            .overlay(alignment: .leading) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(AppPalette.accent)
                        .frame(width: SelectableRowMetrics.accentBarWidth, height: accentBarHeight)
                        .padding(.leading, SelectableRowMetrics.accentBarLeading)
                }
            }
    }

    private var rowFill: Color {
        if isSelected { return AppPalette.accent.opacity(SelectableRowMetrics.selectedFillOpacity) }
        if isHovering { return AppPalette.surface }
        return .clear
    }
}

extension View {
    func selectableRowChrome(
        isSelected: Bool,
        isHovering: Bool = false,
        cornerRadius: CGFloat = SelectableRowMetrics.cornerRadius,
        accentBarHeight: CGFloat = SelectableRowMetrics.accentBarHeight
    ) -> some View {
        modifier(SelectableRowChrome(
            isSelected: isSelected,
            isHovering: isHovering,
            cornerRadius: cornerRadius,
            accentBarHeight: accentBarHeight
        ))
    }

    /// Flat panel tool header: fixed height + hairline bottom edge.
    func panelToolHeader(
        height: CGFloat = AppSpacing.headerHeight,
        background: Color = AppPalette.elevated
    ) -> some View {
        self
            .frame(height: height)
            .background(background)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(AppPalette.border)
                    .frame(height: 1)
            }
    }
}

// MARK: - AppKit (file tree outline)

/// `NSTableRowView` that paints the same accent-bar selection as
/// `SelectableRowChrome`, so the outline tree doesn't fall back to system blue.
final class AccentBarTableRowView: NSTableRowView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("AccentBarTableRowView")

    /// Keep cell labels at normal contrast — our fill is only 12% accent,
    /// not a solid system highlight that would need inverted content.
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }

        let accent = AppPalette.ns.accent
        let fill = accent.withAlphaComponent(SelectableRowMetrics.selectedFillOpacity)

        let bgRect = bounds.insetBy(
            dx: SelectableRowMetrics.fillInsetX,
            dy: SelectableRowMetrics.fillInsetY
        )
        guard bgRect.width > 0, bgRect.height > 0 else { return }

        let path = NSBezierPath(
            roundedRect: bgRect,
            xRadius: SelectableRowMetrics.cornerRadius,
            yRadius: SelectableRowMetrics.cornerRadius
        )
        fill.setFill()
        path.fill()

        let barHeight = min(SelectableRowMetrics.accentBarHeight, bgRect.height - 2)
        let barY = bounds.midY - barHeight / 2
        let barRect = NSRect(
            x: SelectableRowMetrics.accentBarLeading + SelectableRowMetrics.fillInsetX,
            y: barY,
            width: SelectableRowMetrics.accentBarWidth,
            height: barHeight
        )
        let barPath = NSBezierPath(roundedRect: barRect, xRadius: 1, yRadius: 1)
        accent.setFill()
        barPath.fill()
    }

    override func drawBackground(in dirtyRect: NSRect) {
        // Transparent — the outline scroll view sits on AppPalette.base.
        // Avoid painting the default alternating/slab background.
    }
}
