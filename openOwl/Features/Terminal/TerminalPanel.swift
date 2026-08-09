import SwiftUI

/// Bridges TerminalNSView (AppKit) into the SwiftUI view hierarchy,
/// wrapped in a TerminalScrollView to provide native macOS scrollbar support.
struct TerminalPanel: NSViewRepresentable {
    let ghosttyApp: ghostty_app_t
    let paneID: UUID
    let isVisible: Bool
    var workingDirectory: String? = nil
    var launchConfiguration: TerminalSurfaceConfiguration? = nil
    var onFocus: (() -> Void)? = nil
    @Environment(GhosttyAppManager.self) var appManager
    @Environment(RightDockStore.self) var rightDockStore
    @Environment(TerminalWorkspaceStore.self) var workspace

    func makeNSView(context: Context) -> TerminalScrollView {
        var surfaceConfiguration = launchConfiguration ?? TerminalSurfaceConfiguration()
        if surfaceConfiguration.workingDirectory == nil {
            surfaceConfiguration.workingDirectory = workingDirectory
        }

        // Reuse an existing TerminalScrollView if SwiftUI dismantled a previous
        // wrapper. This prevents the TerminalNSView from being reparented
        // (viewDidMoveToWindow nil→window thrash) on every SwiftUI re-evaluation.
        if let existing = appManager.scrollView(for: paneID) {
            existing.terminalView.onFocus = onFocus
            existing.terminalView.surfaceConfiguration = surfaceConfiguration
            existing.workspace = workspace
            existing.setTerminalVisibility(isVisible)
            return existing
        }

        // Reuse an existing TerminalNSView if only the scroll wrapper was lost.
        let terminalView: TerminalNSView
        if let existing = appManager.terminalView(for: paneID) {
            terminalView = existing
            terminalView.onFocus = onFocus
            terminalView.surfaceConfiguration = surfaceConfiguration
        } else {
            terminalView = TerminalNSView(ghosttyApp: ghosttyApp, paneID: paneID)
            terminalView.appManager = appManager
            terminalView.onFocus = onFocus
            terminalView.surfaceConfiguration = surfaceConfiguration
        }

        let scrollView = TerminalScrollView(terminalView: terminalView, paneID: paneID)
        scrollView.workspace = workspace
        scrollView.setTerminalVisibility(isVisible)
        appManager.registerScrollView(scrollView, for: paneID)
        return scrollView
    }

    func updateNSView(_ nsView: TerminalScrollView, context: Context) {
        nsView.terminalView.onFocus = onFocus
        nsView.workspace = workspace
        nsView.freezeTerminalWidth = rightDockStore.shouldFreezeTerminalResize && !rightDockStore.isFullscreen
        nsView.setTerminalVisibility(isVisible)
    }
}
