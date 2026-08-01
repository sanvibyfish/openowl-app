import SwiftUI

/// Quiet empty-state placeholder for inspector panels.
///
/// Intentionally **does not** use `NSApp.applicationIconImage` — Debug builds
/// stamp a DEV badge on the app icon, which reads as a half-opaque product
/// logo sitting on top of the panel (and obscures the real empty message).
/// Prefer a light SF Symbol + two lines of text.
struct EmptyStateView: View {
    enum Density {
        /// Dock sub-panel: small icon over a tight text stack.
        case compact
        /// Inline list filler: text only, no icon.
        case quiet
    }

    let title: String
    var subtitle: String?
    var systemImage: String?
    var density: Density

    init(
        _ title: String,
        subtitle: String? = nil,
        systemImage: String? = nil,
        density: Density = .compact
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.density = density
    }

    var body: some View {
        VStack(spacing: density == .quiet ? 4 : 6) {
            if density == .compact, let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(AppPalette.textTertiary)
                    .symbolRenderingMode(.hierarchical)
            }

            Text(title)
                .font(AppFonts.secondaryLabel.weight(.medium))
                .foregroundStyle(AppPalette.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)

            if let subtitle {
                Text(subtitle)
                    .font(AppFonts.caption)
                    .foregroundStyle(AppPalette.textTertiary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
        }
        .frame(maxWidth: density == .quiet ? .infinity : 240)
        .padding(.horizontal, density == .quiet ? 8 : 12)
        .padding(.vertical, density == .quiet ? 8 : 4)
        .accessibilityElement(children: .combine)
    }
}
