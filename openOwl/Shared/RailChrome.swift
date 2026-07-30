import SwiftUI

/// Shared chrome tokens for the left ProjectRail and right RightDockRail —
/// keeps both edges of the window visually paired (Muxy-style quiet rails).
enum RailChrome {
    static let leftWidth: CGFloat = 48
    static let rightWidth: CGFloat = 40
    static let iconRowHeight: CGFloat = 40
    static let accentBarWidth: CGFloat = 2
    static let iconCornerRadius: CGFloat = 8

    /// Softer than system separator — rails should recede, not frame the app.
    static var hairline: Color { Color.primary.opacity(0.08) }

    static var background: Color { AppPalette.elevated }
}

/// Vertical icon strip button used by both left and right rails.
struct RailStripButton<Label: View>: View {
    let width: CGFloat
    let isSelected: Bool
    let help: String
    var badge: Int = 0
    /// When true, accent bar sits on the trailing edge (right dock).
    var accentOnTrailing: Bool = false
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    RoundedRectangle(cornerRadius: RailChrome.iconCornerRadius, style: .continuous)
                        .fill(rowBackground)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)

                    label()
                        .foregroundStyle(isSelected ? AppPalette.accent : AppPalette.textSecondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .overlay(alignment: accentOnTrailing ? .trailing : .leading) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(isSelected ? AppPalette.accent : Color.clear)
                        .frame(width: RailChrome.accentBarWidth, height: 18)
                        .padding(accentOnTrailing ? .trailing : .leading, 3)
                }
                .frame(width: width, height: RailChrome.iconRowHeight)

                if badge > 0 {
                    Text(badge > 9 ? "9+" : "\(badge)")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(AppPalette.accent))
                        .offset(x: -6, y: 4)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var rowBackground: Color {
        if isSelected { return AppPalette.accent.opacity(0.12) }
        if hovering { return AppPalette.surface }
        return .clear
    }
}

/// Rail-sized chrome for controls that are not plain `Button`s (e.g. `Menu` labels).
struct RailMenuLabel<Label: View>: View {
    let width: CGFloat
    @ViewBuilder let label: () -> Label

    @State private var hovering = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: RailChrome.iconCornerRadius, style: .continuous)
                .fill(hovering ? AppPalette.surface : Color.clear)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)

            label()
                .foregroundStyle(AppPalette.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: width, height: RailChrome.iconRowHeight)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
