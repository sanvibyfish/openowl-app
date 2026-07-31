import SwiftUI

/// Soft hairline divider — quieter than system `Divider` so panel chrome
/// doesn't compete with terminal content.
struct PanelDivider: View {
    var body: some View {
        Rectangle()
            .fill(AppPalette.border)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }
}
