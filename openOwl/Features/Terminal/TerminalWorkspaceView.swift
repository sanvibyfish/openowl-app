import AppKit
import SwiftUI

/// Private pasteboard type for in-app pane rearrangement.
let paneDragPasteboardType = NSPasteboard.PasteboardType("com.openowl.terminal.pane-drag")

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
                // Mount every terminal tab across namespaces — switching tabs
                // or projects is just an opacity flip, so SwiftUI never detaches
                // the inactive TerminalNSView from its window. Each pane's
                // metalLayer is hidden when its tab isn't active, so background
                // tabs don't render but their surfaces stay alive (and OSC 7
                // still updates their pwd).
                ForEach(workspace.tabs) { tab in
                    let isActiveTab = tab.id == workspace.activeTabID
                    TerminalTabContentView(
                        ghosttyApp: ghosttyApp,
                        tab: tab,
                        isWorkspaceVisible: isVisible && isActiveTab,
                        projectPath: cwdForActiveKind()
                    )
                    .opacity(isActiveTab ? 1 : 0)
                    .allowsHitTesting(isActiveTab)
                    .accessibilityHidden(!isVisible || !isActiveTab)
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
                        // Kept while maximized: the handle is the only way back
                        // for the mouse. Reordering panes makes no sense with
                        // one on screen, so it drops the drag and keeps the
                        // double-click.
                        if isMultiPane {
                            PaneDragHandle(
                                paneID: paneID,
                                isMaximized: isMaximized,
                                isVisible: isPaneVisible
                            )
                        }

                        TerminalPanel(
                            ghosttyApp: ghosttyApp,
                            paneID: paneID,
                            isVisible: isPaneVisible,
                            workingDirectory: projectPath,
                            launchConfiguration: workspace.launchConfiguration(for: paneID),
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
                    .accessibilityHidden(isHiddenByMaximize)
                    .overlay {
                        // 非聚焦 pane 仅做轻微弱化，不绘制焦点边框。
                        if isMultiPane && !isMaximized, !workspace.isFocusedPane(paneID, in: tab.id) {
                            Color.primary.opacity(0.04)
                                .allowsHitTesting(false)
                        }
                    }
                    // Search overlay is the outermost overlay so it renders above
                    // terminal content and receives clicks.
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

                // Drop-zone highlight host — topmost, drawn directly by AppKit.
                // A SwiftUI overlay can't show it: view updates are frozen for
                // the whole NSDraggingSession, so dropEntered/dropUpdated writes
                // never re-render an overlay. Mutating this NSView's layers
                // bypasses SwiftUI and renders immediately.
                DragZoneHighlightHostView(tabID: tab.id)
                    .frame(width: bounds.width, height: bounds.height)
                    .allowsHitTesting(false)
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

/// AppKit-hosted drop-zone highlight for pane rearrangement.
///
/// SwiftUI overlays are frozen for the whole `NSDraggingSession`: state writes
/// from `DropDelegate` callbacks never reach the SwiftUI layer, so a SwiftUI
/// highlight can never appear mid-drag. This view sidesteps SwiftUI entirely —
/// the drag callbacks mutate its CALayers directly, which AppKit renders
/// immediately even while the dragging session owns the event loop.
final class DragZoneHighlightNSView: NSView {
    weak var workspace: TerminalWorkspaceStore?
    var tabID: UUID?

    private let fillLayer = CALayer()
    private let borderLayer = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        // Top-left origin, matching SwiftUI's paneFrames coordinates.
        wantsLayer = true

        fillLayer.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor
        fillLayer.cornerRadius = 6
        fillLayer.isHidden = true

        borderLayer.strokeColor = NSColor.controlAccentColor.withAlphaComponent(0.75).cgColor
        borderLayer.lineWidth = 2
        borderLayer.lineDashPattern = [6, 4]
        borderLayer.fillColor = nil
        borderLayer.isHidden = true

        layer?.addSublayer(fillLayer)
        layer?.addSublayer(borderLayer)
    }

    func show(zone: PaneDropZone, targetPaneID: UUID) {
        guard let workspace, let tabID,
              let tab = workspace.tabs.first(where: { $0.id == tabID }),
              let frame = tab.splitTree.paneFrames(in: bounds)[targetPaneID] else {
            hide()
            return
        }

        let rect: CGRect
        switch zone {
        case .left:   rect = CGRect(x: frame.minX, y: frame.minY, width: frame.width * 0.5, height: frame.height)
        case .right:  rect = CGRect(x: frame.midX, y: frame.minY, width: frame.width * 0.5, height: frame.height)
        case .top:    rect = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height * 0.5)
        case .bottom: rect = CGRect(x: frame.minX, y: frame.midY, width: frame.width, height: frame.height * 0.5)
        case .center: rect = frame.insetBy(dx: frame.width * 0.12, dy: frame.height * 0.12)
        }

        let inset = rect.insetBy(dx: 3, dy: 3)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillLayer.frame = inset
        borderLayer.frame = bounds
        borderLayer.path = CGPath(roundedRect: inset, cornerWidth: 6, cornerHeight: 6, transform: nil)
        fillLayer.isHidden = false
        borderLayer.isHidden = false
        CATransaction.commit()
    }

    func hide() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillLayer.isHidden = true
        borderLayer.isHidden = true
        CATransaction.commit()
    }

    /// Top-left origin, matching SwiftUI's paneFrames coordinates.
    override var isFlipped: Bool { true }

    /// Pure overlay — never intercept mouse events.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct DragZoneHighlightHostView: NSViewRepresentable {
    let tabID: UUID

    @Environment(TerminalWorkspaceStore.self) private var workspace

    func makeNSView(context: Context) -> DragZoneHighlightNSView {
        let view = DragZoneHighlightNSView()
        view.workspace = workspace
        view.tabID = tabID
        workspace.registerDropHighlight(view, forTab: tabID)
        return view
    }

    func updateNSView(_ nsView: DragZoneHighlightNSView, context: Context) {
        nsView.workspace = workspace
    }
}

/// Three-dot split handle: double-click maximizes/restores, drag rearranges.
///
/// Interaction lives in AppKit (`PaneHandleNSView`). SwiftUI's
/// `.onTapGesture(count: 2)` + `.onDrag` cannot coexist — the tap gesture
/// delays mouseDown and breaks the drag session. A plain NSView overlay with
/// `NSClickGestureRecognizer` also fails to receive clicks under SwiftUI's
/// hosting hit-testing. Owning mouseDown/mouseDragged ourselves (same pattern
/// as ghostty's SurfaceDragSource) gives reliable double-click and a proper
/// `NSDraggingSession` end callback so cancelled drags clear state.
private struct PaneDragHandle: View {
    let paneID: UUID
    let isMaximized: Bool
    let isVisible: Bool

    @State private var isHovered = false
    @Environment(TerminalWorkspaceStore.self) private var workspace

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                PaneHandleInteractionView(
                    paneID: paneID,
                    isMaximized: isMaximized,
                    isVisible: isVisible,
                    isHovered: $isHovered
                )

                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle()
                            .fill(Color.secondary.opacity(isHovered ? 1 : 0.6))
                            .frame(width: 3, height: 3)
                    }
                }
                .allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 12)
            .background(AppPalette.elevated)
            .help(isMaximized
                  ? "Double-click to restore split (⇧⌘↩)"
                  : "Double-click to maximize (⇧⌘↩) · drag to move pane")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(isMaximized ? "Restore split" : "Maximize pane")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                workspace.toggleMaximizeCurrentPane(paneID: paneID)
            }

            Rectangle()
                .fill(AppPalette.border)
                .frame(height: 1)
        }
    }
}

private struct PaneHandleInteractionView: NSViewRepresentable {
    let paneID: UUID
    let isMaximized: Bool
    let isVisible: Bool
    @Binding var isHovered: Bool

    @Environment(TerminalWorkspaceStore.self) private var workspace

    func makeNSView(context: Context) -> PaneHandleNSView {
        let view = PaneHandleNSView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: PaneHandleNSView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: PaneHandleNSView) {
        view.paneID = paneID
        view.isMaximized = isMaximized
        view.workspace = workspace
        view.setPaneDropEnabled(isVisible && !isMaximized)
        view.onHoverChanged = { hovering in
            isHovered = hovering
        }
    }
}

/// AppKit hit target for the split handle.
private final class PaneHandleNSView: NSView, NSDraggingSource {
    /// Ignore sub-threshold jitter so a double-click still registers.
    private static let dragThreshold: CGFloat = 4

    var paneID: UUID = UUID()
    var isMaximized: Bool = false
    weak var workspace: TerminalWorkspaceStore?
    var onHoverChanged: ((Bool) -> Void)?

    private var dragSessionActive = false
    private var paneDropEnabled = false
    private var mouseDownEvent: NSEvent?
    private var mouseDownLocation: NSPoint = .zero

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setPaneDropEnabled(_ enabled: Bool) {
        guard paneDropEnabled != enabled else { return }
        paneDropEnabled = enabled
        if enabled {
            registerForDraggedTypes([paneDragPasteboardType])
        } else {
            unregisterDraggedTypes()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            mouseDownEvent = nil
            AppLogger.log("pane-drag", "handle double-click pane=%@", paneID.uuidString)
            workspace?.toggleMaximizeCurrentPane(paneID: paneID)
            return
        }
        mouseDownEvent = event
        mouseDownLocation = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isMaximized, !dragSessionActive,
              let mouseDownEvent, let workspace else { return }

        let loc = event.locationInWindow
        let distance = hypot(loc.x - mouseDownLocation.x, loc.y - mouseDownLocation.y)
        guard distance >= Self.dragThreshold else { return }

        workspace.draggingPaneID = paneID
        AppLogger.log("pane-drag", "drag started pane=%@", paneID.uuidString)

        let pbItem = NSPasteboardItem()
        pbItem.setString(paneID.uuidString, forType: paneDragPasteboardType)
        let item = NSDraggingItem(pasteboardWriter: pbItem)
        item.setDraggingFrame(bounds, contents: nil)

        self.mouseDownEvent = nil
        dragSessionActive = true
        let session = beginDraggingSession(with: [item], event: mouseDownEvent, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = false
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownEvent = nil
    }

    // MARK: NSDraggingSource

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        dragSessionActive = false
        // Success path: TerminalScrollView already cleared state.
        // Cancel / outside / back-on-source: clear here so drop overlays unmount.
        workspace?.cancelDragIfActive()
    }

    // MARK: NSDraggingDestination

    private func canAcceptPaneDrop(_ sender: NSDraggingInfo) -> Bool {
        guard paneDropEnabled,
              sender.draggingPasteboard.types?.contains(paneDragPasteboardType) == true,
              let sourceID = workspace?.draggingPaneID else { return false }
        return sourceID != paneID
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard canAcceptPaneDrop(sender), let workspace else { return [] }
        workspace.dragOverPaneID = paneID
        workspace.dropZone = .center
        workspace.showDropHighlight(targetPaneID: paneID, zone: .center)
        return .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        canAcceptPaneDrop(sender) ? .move : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        guard let workspace, workspace.dragOverPaneID == paneID else { return }
        workspace.dragOverPaneID = nil
        workspace.dropZone = nil
        workspace.hideDropHighlight()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        canAcceptPaneDrop(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard canAcceptPaneDrop(sender), let workspace,
              let sourceID = workspace.draggingPaneID else { return false }
        AppLogger.log("pane-drag", "performDrop source=%@ target=%@ zone=center",
                      sourceID.uuidString, paneID.uuidString)
        workspace.movePaneToTarget(sourceID: sourceID, targetID: paneID, zone: .center)
        workspace.draggingPaneID = nil
        workspace.dragOverPaneID = nil
        workspace.dropZone = nil
        workspace.hideDropHighlight()
        return true
    }
}

// Old recursive TerminalSplitNodeView and SplitContainerView removed.
// Replaced by flat layout in TerminalTabContentView above.
