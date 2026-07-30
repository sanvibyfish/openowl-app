import SwiftUI

/// Tab bar shown above the standalone terminal — mirrors ghostty's
/// multi-tab UX for the free-terminal namespace. Project terminals don't
/// use this bar (they use rail worktrees and split panes for layout).
struct FreeTerminalTabBar: View {
    @Environment(TerminalWorkspaceStore.self) private var workspace

    var body: some View {
        // Keep `+` OUTSIDE the ScrollView. Inside a horizontal ScrollView on
        // macOS the plus often loses hit-testing (clicks appear dead). The
        // scroll area only hosts tab pills; + is a fixed trailing control.
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(workspace.visibleTabs) { tab in
                        FreeTerminalTabButton(
                            tab: tab,
                            isActive: workspace.activeTabID == tab.id,
                            canClose: workspace.visibleTabs.count > 1
                        )
                    }
                }
                .padding(.leading, 8)
                .padding(.trailing, 4)
            }

            Button(action: addTab) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppPalette.textSecondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New tab (⌘T)")
            .accessibilityLabel("New tab (⌘T)")
            .padding(.trailing, 6)
        }
        .frame(height: AppSpacing.editorTabBarHeight)
        .background(AppPalette.elevated)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(RailChrome.hairline)
                .frame(height: 1)
        }
    }

    private func addTab() {
        // Explicit free-terminal namespace when possible — falls back to
        // activeNamespace inside newTab if nil.
        if case .freeTerminal(let id) = workspace.activeNamespace {
            _ = workspace.newTab(for: .freeTerminal(id))
        } else {
            _ = workspace.newTab()
        }
        workspace.notifyContextChange()
    }
}

private struct FreeTerminalTabButton: View {
    let tab: TerminalTabState
    let isActive: Bool
    let canClose: Bool

    @Environment(TerminalWorkspaceStore.self) private var workspace
    @State private var hovering = false

    private var displayTitle: String {
        if let pid = tab.focusedPaneID ?? tab.splitTree.firstPaneID,
           let title = workspace.paneTitles[pid], !title.isEmpty {
            return title
        }
        return tab.title
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(displayTitle)
                .font(AppFonts.secondaryLabel.weight(isActive ? .medium : .regular))
                .foregroundStyle(isActive ? AppPalette.textPrimary : AppPalette.textSecondary)
                .lineLimit(1)

            if canClose && (hovering || isActive) {
                Button {
                    workspace.closeTab(id: tab.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(AppFonts.tinyIcon.weight(.semibold))
                        .foregroundStyle(AppPalette.textTertiary)
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close tab")
                .accessibilityLabel("Close tab")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: AppSpacing.editorTabBarHeight - 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isActive
                      ? AppPalette.base
                      : (hovering ? AppPalette.surface : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(isActive ? RailChrome.hairline : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            workspace.selectTab(id: tab.id)
        }
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}
