import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(GhosttyAppManager.self) var ghosttyManager
    @Environment(FileExplorerStore.self) var fileExplorerStore
    @Environment(ProjectStore.self) var projectStore
    @Environment(RightDockStore.self) var rightDockStore

    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 250, max: 500)
        } detail: {
            GeometryReader { geo in
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        // Terminal — center area. Hidden when the right dock is
                        // fullscreen but kept mounted (no surface destroy) so its
                        // shell processes keep running in the background.
                        terminalContent
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .frame(width: rightDockStore.isFullscreen ? 0 : nil)
                            .clipped()

                        if rightDockStore.isExpanded {
                            Divider()

                            RightDockView(hostWidth: geo.size.width)
                                .frame(
                                    width: rightDockStore.effectiveWidth(
                                        hostWidth: geo.size.width,
                                        railWidth: RightDockRail.width
                                    )
                                )
                                .frame(maxHeight: .infinity)
                        }

                        Divider()

                        RightDockRail()
                    }

                    Divider()

                    StatusBarView()
                }
                .background(AppPalette.base)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle("")
        .background {
            Button("") { fileExplorerStore.presentQuickOpen(projectURL: projectStore.activeProjectURL) }
                .keyboardShortcut("p", modifiers: [.command])
                .hidden()
        }
        .overlay {
            if fileExplorerStore.isQuickOpenPresented {
                ZStack(alignment: .top) {
                    // Click outside to dismiss
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
            AppLogger.log("resize-diag", "=== RightDock.isExpanded -> %@ activeTab=%@ ===",
                          newValue ? "TRUE" : "FALSE", rightDockStore.activeTab.rawValue)
            resignFirstResponderForTabSwitch()
        }
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
