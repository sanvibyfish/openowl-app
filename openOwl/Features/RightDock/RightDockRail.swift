import SwiftUI

/// Collapsed vertical icon strip on the far right of the detail area.
///
/// Entry point only. Once expanded, `RightDockView` presents the horizontal
/// tab switcher and panel actions inside the inspector header.
struct RightDockRail: View {
    @Environment(RightDockStore.self) private var dock

    static let width: CGFloat = RailChrome.rightWidth

    var body: some View {
        VStack(spacing: 2) {
            ForEach(RightDockTab.allCases) { tab in
                RailStripButton(
                    width: Self.width,
                    isSelected: false, // collapsed rail is entry-only; nothing "active" until expanded
                    help: tab.title,
                    action: { dock.expand(tab: tab) }
                ) {
                    Image(systemName: tab.systemImage)
                        .font(.system(size: 15, weight: .medium))
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(AppPalette.elevated)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(AppPalette.border)
                .frame(width: 1)
        }
    }
}
