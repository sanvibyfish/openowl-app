import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(GhosttyAppManager.self) var ghosttyManager
    @Environment(FileExplorerStore.self) var fileExplorerStore
    @Environment(ProjectStore.self) var projectStore
    @Environment(RightDockStore.self) var rightDockStore

    /// Worktree + pane session list next to the icon rail (default on).
    @AppStorage("openowl.ui.sessionListVisible") private var isSessionListVisible = true

    var body: some View {
        GeometryReader { geo in
            let leftChrome = ProjectRail.width
                + (isSessionListVisible ? ProjectSessionList.width : 0)
            let hostWidth = max(0, geo.size.width - leftChrome)

            HStack(spacing: 0) {
                // Left: monogram rail + optional session list (worktrees / panes)
                ProjectRail(isSessionListVisible: $isSessionListVisible)

                if isSessionListVisible {
                    ProjectSessionList()
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }

                // Center + right dock
                HStack(spacing: 0) {
                    terminalContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .frame(width: rightDockStore.isFullscreen ? 0 : nil)
                        .clipped()

                    softVerticalDivider
                        .frame(width: rightDockStore.isExpanded ? 1 : 0)
                        .opacity(rightDockStore.isExpanded ? 1 : 0)

                    RightDockView(hostWidth: hostWidth)
                        .frame(
                            width: rightDockStore.isExpanded
                                ? rightDockStore.effectiveWidth(hostWidth: hostWidth)
                                : 0
                        )
                        .frame(maxHeight: .infinity)
                        .opacity(rightDockStore.isExpanded ? 1 : 0)
                        .disabled(!rightDockStore.isExpanded)
                        .allowsHitTesting(rightDockStore.isExpanded)
                        .accessibilityHidden(!rightDockStore.isExpanded)
                        .clipped()

                    if !rightDockStore.isExpanded {
                        RightDockRail()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .animation(.easeOut(duration: 0.15), value: isSessionListVisible)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                StatusBarView()
            }
            .background(AppPalette.base)
        }
        .navigationTitle("")
        .background {
            Button("") { fileExplorerStore.presentQuickOpen(projectURL: projectStore.activeProjectURL) }
                .keyboardShortcut("p", modifiers: [.command])
                .hidden()
        }
        .overlay {
            if fileExplorerStore.isQuickOpenPresented {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.001)
                        .onTapGesture { fileExplorerStore.dismissQuickOpen() }

                    QuickOpenPanel()
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                .zIndex(100)
            }
        }
        .animation(.easeOut(duration: 0.15), value: fileExplorerStore.isQuickOpenPresented)
        .onReceive(NotificationCenter.default.publisher(for: .quickOpen)) { _ in
            fileExplorerStore.presentQuickOpen(projectURL: projectStore.activeProjectURL)
        }
        .onChange(of: rightDockStore.activeTab) { _, _ in
            resignFirstResponderForTabSwitch()
        }
        .onChange(of: rightDockStore.isExpanded) { _, newValue in
            AppLogger.log("resize", "RightDock.isExpanded -> %@ activeTab=%@",
                          newValue ? "TRUE" : "FALSE", rightDockStore.activeTab.rawValue)
            resignFirstResponderForTabSwitch()
        }
        .onChange(of: rightDockStore.isFullscreen) { _, newValue in
            AppLogger.log("resize", "RightDock.isFullscreen -> %@ activeTab=%@",
                          newValue ? "TRUE" : "FALSE", rightDockStore.activeTab.rawValue)
        }
    }

    private var softVerticalDivider: some View {
        Rectangle()
            .fill(AppPalette.border)
            .frame(width: 1)
            .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private var terminalContent: some View {
        if ghosttyManager.isReady {
            TerminalWorkspaceView(
                ghosttyApp: ghosttyManager.app!,
                isVisible: !rightDockStore.isFullscreen
            )
        } else if let error = ghosttyManager.error {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("Terminal initialization failed")
                    .font(.headline)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView("Initializing terminal...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @MainActor
    private func resignFirstResponderForTabSwitch() {
        guard let window = NSApp.keyWindow else { return }
        window.endEditing(for: nil)
        window.makeFirstResponder(nil)
    }
}
