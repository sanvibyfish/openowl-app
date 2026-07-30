import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Private UTType for in-app pane rearrangement drag.
/// Using a dedicated type prevents TerminalScrollView (which accepts .string)
/// from intercepting pane drags, and allows the drop overlay to be
/// always-present without interfering with Finder file drops (.fileURL).
private let paneDragTypeID = "com.openowl.terminal.pane-drag"

struct TerminalWorkspaceView: View {
    let ghosttyApp: ghostty_app_t
    let isVisible: Bool

    @Environment(TerminalWorkspaceStore.self) private var workspace
    @Environment(GhosttyAppManager.self) private var ghosttyManager
    @Environment(ProjectStore.self) private var projectStore

    private var isFreeTerminalActive: Bool {
        if case .freeTerminal = projectStore.activeKind { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            // Free-terminal namespace gets a ghostty-style tab bar.
            // Project terminals don't — they use sidebar worktrees + split
            // panes (⌘D / ⇧⌘D) for layout instead.
            if isFreeTerminalActive {
                FreeTerminalTabBar()
            }

            ZStack {
                // Mount every visible tab — switching active is just an
                // opacity flip, so no SwiftUI dismantle and no
                // viewDidMoveToWindow nil/window thrashing on the inactive
                // tab's TerminalNSView. Each pane's metalLayer is hidden
                // when its tab isn't active, so background tabs don't
                // render but their surfaces stay alive (and OSC 7 still
                // updates their pwd).
                ForEach(workspace.visibleTabs) { tab in
                    let isActiveTab = tab.id == workspace.activeTabID
                    TerminalTabContentView(
                        ghosttyApp: ghosttyApp,
                        tab: tab,
                        isWorkspaceVisible: isVisible && isActiveTab,
                        projectPath: cwdForActiveKind()
                    )
                    .opacity(isActiveTab ? 1 : 0)
                    .allowsHitTesting(isActiveTab)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            workspace.focusPaneHandler = { [weak ghosttyManager] paneID in
                DispatchQueue.main.async {
                    _ = ghosttyManager?.focusPane(paneID)
                }
            }
            connectSearchCallbacks()
            workspace.ensureInitialTab()
            focusCurrentPaneIfPossible()
        }
        .onChange(of: workspace.activeTabID) { _, _ in
            focusCurrentPaneIfPossible()
        }
        .onChange(of: isVisible) { _, _ in
            focusCurrentPaneIfPossible()
        }
        .onReceive(NotificationCenter.default.publisher(for: .terminalSearch)) { notification in
            guard let paneID = notification.userInfo?["paneID"] as? UUID else { return }
            workspace.startSearch(paneID: paneID)
        }
    }

    private func connectSearchCallbacks() {
        ghosttyManager.onSearchEnd = { [weak workspace] paneID in
            workspace?.endSearch(paneID: paneID)
        }
        ghosttyManager.onSearchTotal = { [weak workspace] paneID, total in
            workspace?.paneSearchStates[paneID]?.total = total
        }
        ghosttyManager.onSearchSelected = { [weak workspace] paneID, selected in
            workspace?.paneSearchStates[paneID]?.selected = selected
        }
    }

    private func focusCurrentPaneIfPossible() {
        guard isVisible else { return }
        guard let activeTabID = workspace.activeTabID else { return }
        guard let tab = workspace.tabs.first(where: { $0.id == activeTabID }) else { return }
        guard let paneID = tab.focusedPaneID ?? tab.splitTree.firstPaneID else { return }

        DispatchQueue.main.async {
            _ = ghosttyManager.focusPane(paneID)
        }
    }

    /// Resolve the working directory for new panes based on what's selected in the
    /// sidebar — project-bound panes inherit the project URL, free terminals get
    /// the user's home directory (matching ghostty's default).
    private func cwdForActiveKind() -> String? {
        switch projectStore.activeKind {
        case .project:
            return projectStore.activeProjectURL?.path
        case .freeTerminal:
            return FileManager.default.homeDirectoryForCurrentUser.path
        case .none:
            return nil
        }
    }
}

/// Flat layout: all panes are positioned absolutely within a GeometryReader.
/// This prevents SwiftUI from destroying/recreating terminal views when the
/// split tree structure changes (add/remove/move splits).
private struct TerminalTabContentView: View {
    let ghosttyApp: ghostty_app_t
    let tab: TerminalTabState
    let isWorkspaceVisible: Bool
    let projectPath: String?

    @Environment(TerminalWorkspaceStore.self) private var workspace
    @Environment(GhosttyAppManager.self) private var ghosttyManager

    var body: some View {
        let paneIDs = tab.splitTree.allPaneIDs
        let isMultiPane = paneIDs.count > 1
        let isMaximized = workspace.maximizedPaneID != nil
            && paneIDs.contains(where: { $0 == workspace.maximizedPaneID })

        GeometryReader { geometry in
            let size = geometry.size
            let bounds = CGRect(origin: .zero, size: size)
            let frames = tab.splitTree.paneFrames(in: bounds)
            let dividers = tab.splitTree.dividerInfos(in: bounds)

            ZStack(alignment: .topLeading) {
                // All terminal panes with absolute positioning
                ForEach(paneIDs, id: \.self) { paneID in
                    let isMaximizedPane = isMaximized && paneID == workspace.maximizedPaneID
                    let isHiddenByMaximize = isMaximized && paneID != workspace.maximizedPaneID
                    let isPaneVisible = isWorkspaceVisible && !isHiddenByMaximize
                    // Maximized pane fills the entire bounds; others keep their normal frame
                    let frame = isMaximizedPane ? bounds : (frames[paneID] ?? .zero)

                    VStack(spacing: 0) {
                        if isMultiPane && !isMaximized {
                            PaneDragHandle(paneID: paneID)
                        }

                        TerminalPanel(
                            ghosttyApp: ghosttyApp,
                            paneID: paneID,
                            isVisible: isPaneVisible,
                            workingDirectory: projectPath,
                            onFocus: {
                                DispatchQueue.main.async {
                                    workspace.focusPane(paneID)
                                }
                            }
                        )
                    }
                    .frame(width: max(frame.width, 1), height: max(frame.height, 1))
                    .animation(.easeInOut(duration: 0.15), value: isMaximized)
                    .clipped()
                    // File drops are handled at the AppKit level by TerminalScrollView
                    // (registerForDraggedTypes + performDragOperation).
                    // A SwiftUI-level .onDrop + .contentShape(Rectangle()) here would
                    // create a full-pane hit target that blocks mouse events (selection,
                    // click-to-focus) from reaching the TerminalNSView below.
                    .opacity(isHiddenByMaximize ? 0 : 1)
                    .allowsHitTesting(!isHiddenByMaximize)
                    .overlay {
                        // 非聚焦 pane 仅做轻微弱化，不绘制焦点边框。
                        if isMultiPane && !isMaximized, !workspace.isFocusedPane(paneID, in: tab.id) {
                            Color.primary.opacity(0.04)
                                .allowsHitTesting(false)
                        }
                    }
                    .overlay {
                        if !isMaximized, workspace.dragOverPaneID == paneID, let zone = workspace.dropZone {
                            DropZoneHighlightView(zone: zone)
                                .allowsHitTesting(false)
                        }
                    }
                    .overlay {
                        // Only register drop target when a pane drag is actually in progress
                        // and this pane is not the drag source.
                        // Previously used `draggingPaneID != paneID` which is true even
                        // when draggingPaneID is nil — causing the contentShape overlay to
                        // block all mouse events at all times.
                        //
                        // Safe to use paneDragTypeID (private UTType) — TerminalScrollView
                        // only registers for .fileURL, so Finder drops reach AppKit unimpeded.
                        if !isMaximized,
                           let draggingID = workspace.draggingPaneID,
                           draggingID != paneID {
                            Color.clear
                                .contentShape(Rectangle())
                                .onDrop(
                                    of: [UTType(exportedAs: paneDragTypeID)],
                                    delegate: PaneDropDelegate(
                                        targetPaneID: paneID,
                                        workspace: workspace,
                                        viewSize: frame.size
                                    )
                                )
                        }
                    }
                    // Search overlay is the outermost overlay so it renders above
                    // the pane drop delegate (Color.clear.contentShape) and receives clicks.
                    .overlay(alignment: .topTrailing) {
                        let isFocused = workspace.isFocusedPane(paneID, in: tab.id)
                        TerminalSearchOverlay(paneID: paneID, isFocused: isFocused)
                    }
                    .position(x: frame.midX, y: frame.midY)
                    .zIndex(isMaximizedPane ? 2 : 0)
                }

                // Dividers (hidden when maximized)
                if !isMaximized {
                    ForEach(dividers) { divider in
                        let isH = divider.axis == .horizontal
                        SplitDividerView(axis: divider.axis, hitAreaThickness: 6)
                            .frame(
                                width: isH ? 6 : divider.frame.width,
                                height: isH ? divider.frame.height : 6
                            )
                            .position(x: divider.frame.midX, y: divider.frame.midY)
                            .zIndex(1)
                            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("splitContainer"))
                                .onChanged { value in
                                    let pos = isH ? value.location.x : value.location.y
                                    let origin = isH ? divider.splitRect.minX : divider.splitRect.minY
                                    let splitSize = isH ? divider.splitRect.width : divider.splitRect.height
                                    guard splitSize > 1 else { return }
                                    workspace.updateSplitRatio(
                                        firstPaneID: divider.firstPaneID,
                                        secondPaneID: divider.secondPaneID,
                                        newRatio: (pos - origin) / splitSize
                                    )
                                }
                            )
                            .onTapGesture(count: 2) {
                                workspace.equalizeSplits()
                            }
                    }
                }
            }
            .coordinateSpace(name: "splitContainer")
        }
    }

}

private struct SplitDividerView: View {
    let axis: TerminalSplitAxis
    let hitAreaThickness: CGFloat

    @State private var isHovered = false

    var body: some View {
        let isHorizontal = axis == .horizontal

        ZStack {
            // Hit area (invisible, wider for easier grabbing)
            Rectangle()
                .fill(Color.clear)
                .frame(
                    width: isHorizontal ? hitAreaThickness : nil,
                    height: isHorizontal ? nil : hitAreaThickness
                )
                .contentShape(Rectangle())

            // Visual line
            Rectangle()
                .fill(isHovered ? AppPalette.accent.opacity(0.7) : AppPalette.border)
                .frame(
                    width: isHorizontal ? 1 : nil,
                    height: isHorizontal ? nil : 1
                )
        }
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                NSCursor.setCursor(for: axis)
            } else {
                NSCursor.arrow.set()
            }
        }
    }
}

private extension NSCursor {
    static func setCursor(for axis: TerminalSplitAxis) {
        switch axis {
        case .horizontal:
            NSCursor.resizeLeftRight.set()
        case .vertical:
            NSCursor.resizeUpDown.set()
        }
    }
}

private struct DropZoneHighlightView: View {
    let zone: PaneDropZone

    var body: some View {
        switch zone {
        case .left:
            HStack(spacing: 0) {
                dropZoneContent
                Color.clear
            }
        case .right:
            HStack(spacing: 0) {
                Color.clear
                dropZoneContent
            }
        case .top:
            VStack(spacing: 0) {
                dropZoneContent
                Color.clear
            }
        case .bottom:
            VStack(spacing: 0) {
                Color.clear
                dropZoneContent
            }
        case .center:
            Color.accentColor.opacity(0.15)
        }
    }

    private var dropZoneContent: some View {
        Color.accentColor.opacity(0.2)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.accentColor.opacity(0.4), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .padding(4)
            )
    }
}

private struct PaneDragHandle: View {
    let paneID: UUID

    @State private var isHovered = false
    @Environment(TerminalWorkspaceStore.self) private var workspace

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle()
                        .fill(Color.secondary.opacity(isHovered ? 1 : 0.6))
                        .frame(width: 3, height: 3)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 12)
            .background(AppPalette.elevated)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .onDrag {
                workspace.draggingPaneID = paneID
                NSLog("openOwl: [PaneDrag] drag started pane=%@", paneID.uuidString)
                // Use private UTType — prevents TerminalScrollView (.string acceptor)
                // from intercepting this drag through the AppKit layer.
                let provider = NSItemProvider()
                let data = paneID.uuidString.data(using: .utf8)!
                provider.registerDataRepresentation(
                    forTypeIdentifier: paneDragTypeID,
                    visibility: .all
                ) { completion in completion(data, nil); return nil }
                return provider
            }

            // Bottom separator
            Rectangle()
                .fill(AppPalette.border)
                .frame(height: 1)
        }
    }
}

// Old recursive TerminalSplitNodeView and SplitContainerView removed.
// Replaced by flat layout in TerminalTabContentView above.

// MARK: - Pane Drop Delegate

private struct PaneDropDelegate: DropDelegate {
    let targetPaneID: UUID
    let workspace: TerminalWorkspaceStore
    let viewSize: CGSize

    func dropEntered(info: DropInfo) {
        NSLog("openOwl: [PaneDropDelegate] dropEntered target=%@ draggingPane=%@",
              targetPaneID.uuidString, workspace.draggingPaneID?.uuidString ?? "nil")
        workspace.dragOverPaneID = targetPaneID
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard workspace.draggingPaneID != nil,
              workspace.draggingPaneID != targetPaneID else {
            // No active pane drag or drag is over its own source — reject silently.
            // (overlay is always-present; this fires when cursor passes over non-drag drags)
            return DropProposal(operation: .cancel)
        }

        workspace.dragOverPaneID = targetPaneID
        let newZone = detectZone(at: info.location)
        if newZone != workspace.dropZone {
            NSLog("openOwl: [PaneDropDelegate] zone changed target=%@ zone=%@",
                  targetPaneID.uuidString, "\(newZone)")
            workspace.dropZone = newZone
        }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if workspace.dragOverPaneID == targetPaneID {
            NSLog("openOwl: [PaneDropDelegate] dropExited target=%@", targetPaneID.uuidString)
            workspace.dragOverPaneID = nil
            workspace.dropZone = nil
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let sourceID = workspace.draggingPaneID,
              sourceID != targetPaneID else {
            NSLog("openOwl: [PaneDropDelegate] performDrop SKIPPED target=%@ draggingPane=%@",
                  targetPaneID.uuidString, workspace.draggingPaneID?.uuidString ?? "nil")
            cleanup()
            return false
        }

        let zone = workspace.dropZone ?? .center
        NSLog("openOwl: [PaneDropDelegate] performDrop source=%@ target=%@ zone=%@",
              sourceID.uuidString, targetPaneID.uuidString, "\(zone)")
        workspace.movePaneToTarget(sourceID: sourceID, targetID: targetPaneID, zone: zone)
        cleanup()
        return true
    }

    /// Detect drop zone based on cursor position within the target pane.
    /// Edges (30% inset) → directional split. Center → swap.
    private func detectZone(at point: CGPoint) -> PaneDropZone {
        let w = viewSize.width
        let h = viewSize.height
        guard w > 0, h > 0 else { return .center }

        let relX = point.x / w  // 0..1
        let relY = point.y / h  // 0..1
        let edgeThreshold: CGFloat = 0.3

        // Check edges first
        if relX < edgeThreshold { return .left }
        if relX > 1 - edgeThreshold { return .right }
        if relY < edgeThreshold { return .top }
        if relY > 1 - edgeThreshold { return .bottom }

        return .center
    }

    private func cleanup() {
        workspace.draggingPaneID = nil
        workspace.dragOverPaneID = nil
        workspace.dropZone = nil
    }
}
