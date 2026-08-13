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
                .fill(AppPalette.border)
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
    @Environment(MessageBusService.self) private var bus
    @State private var hovering = false

    private var paneID: String? {
        (tab.focusedPaneID ?? tab.splitTree.firstPaneID)?.uuidString
    }

    private var displayTitle: String {
        // An explicit message-bus name (right-click → Set Message Bus Name)
        // becomes the tab label so you can see where messages are routed.
        if let pid = paneID, let busName = bus.paneName(for: pid) {
            return busName
        }
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
                .strokeBorder(isActive ? AppPalette.border : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            workspace.selectTab(id: tab.id)
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Set Message Bus Name…") { promptForBusName() }
            if let pid = paneID, bus.paneName(for: pid) != nil {
                Button("Clear Message Bus Name") {
                    if let pid = paneID { bus.setPaneName(paneID: pid, name: nil) }
                }
            }
        }
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private func promptForBusName() {
        guard let pid = paneID else { return }
        let alert = NSAlert()
        alert.messageText = "Message Bus Name"
        alert.informativeText = "Name this terminal on the message bus. Others can send to it with:\nopenowl bus-send <name> \"…\" — e.g. codex-a, pi-main, keen-pine."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "e.g. codex-a"
        field.stringValue = bus.paneName(for: pid) ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            bus.setPaneName(paneID: pid, name: field.stringValue)
        }
    }
}
