import CoreGraphics
import Foundation
import Observation

struct TerminalTabState: Identifiable, Equatable {
    let id: UUID
    var title: String
    var splitTree: TerminalSplitNode
    var focusedPaneID: UUID?
}

enum TerminalSplitAxis: String, Equatable {
    /// Left-right layout
    case horizontal
    /// Top-bottom layout
    case vertical
}

enum TerminalFocusDirection {
    case left
    case right
    case up
    case down
}

struct SplitDividerInfo: Identifiable {
    /// Stable tree-path ID (e.g. "0", "1.0", "1.1") — doesn't change when panes are added
    let id: String
    let axis: TerminalSplitAxis
    let ratio: Double
    let frame: CGRect
    let firstPaneID: UUID
    let secondPaneID: UUID
    /// The pixel rect of the split node owning this divider (for drag ratio computation)
    let splitRect: CGRect
}

enum PaneDropZone: Equatable {
    case left, right, top, bottom, center
}

enum TerminalCloseAction {
    case none
    case closeWindow
}

struct PaneInfo: Identifiable {
    let paneID: UUID
    let tabID: UUID
    let title: String
    let bellTime: Date?   // nil = running, non-nil = bell received
    var id: UUID { paneID }
    var hasBell: Bool { bellTime != nil }
}

indirect enum TerminalSplitNode: Equatable {
    case leaf(UUID)
    case split(
        axis: TerminalSplitAxis,
        ratio: Double,
        first: TerminalSplitNode,
        second: TerminalSplitNode
    )

    var leafCount: Int {
        switch self {
        case .leaf:
            return 1
        case .split(_, _, let first, let second):
            return first.leafCount + second.leafCount
        }
    }

    var firstPaneID: UUID? {
        switch self {
        case .leaf(let paneID):
            return paneID
        case .split(_, _, let first, _):
            return first.firstPaneID
        }
    }

    func containsPane(_ paneID: UUID) -> Bool {
        switch self {
        case .leaf(let id):
            return id == paneID
        case .split(_, _, let first, let second):
            return first.containsPane(paneID) || second.containsPane(paneID)
        }
    }

    /// Update the ratio of the nearest split ancestor containing `targetPaneID` in its first child.
    func updatingRatio(forPaneID targetPaneID: UUID, newRatio: Double) -> TerminalSplitNode {
        switch self {
        case .leaf:
            return self
        case .split(let axis, let ratio, let first, let second):
            // If the first child contains the target pane, this is the split to update
            if first.containsPane(targetPaneID) && !second.containsPane(targetPaneID) {
                // But first, recurse into the first child to see if there's a deeper match
                let updatedFirst = first.updatingRatio(forPaneID: targetPaneID, newRatio: newRatio)
                if updatedFirst != first {
                    return .split(axis: axis, ratio: ratio, first: updatedFirst, second: second)
                }
                // This is the closest split — update ratio
                let clamped = min(max(newRatio, 0.1), 0.9)
                return .split(axis: axis, ratio: clamped, first: first, second: second)
            }
            // If the second child contains it, check if there's a deeper split to update
            if second.containsPane(targetPaneID) {
                let updatedSecond = second.updatingRatio(forPaneID: targetPaneID, newRatio: newRatio)
                return .split(axis: axis, ratio: ratio, first: first, second: updatedSecond)
            }
            return self
        }
    }

    /// Update the ratio of the split node that directly contains `firstPaneID` in its first subtree.
    /// This variant is used by the divider drag, where we know which split to target.
    func updatingSplitRatio(whereFirstContains firstPaneID: UUID, andSecondContains secondPaneID: UUID, newRatio: Double) -> TerminalSplitNode {
        switch self {
        case .leaf:
            return self
        case .split(let axis, let ratio, let first, let second):
            if first.containsPane(firstPaneID) && second.containsPane(secondPaneID) {
                // Check if a deeper split matches
                let updatedFirst = first.updatingSplitRatio(whereFirstContains: firstPaneID, andSecondContains: secondPaneID, newRatio: newRatio)
                if updatedFirst != first {
                    return .split(axis: axis, ratio: ratio, first: updatedFirst, second: second)
                }
                let updatedSecond = second.updatingSplitRatio(whereFirstContains: firstPaneID, andSecondContains: secondPaneID, newRatio: newRatio)
                if updatedSecond != second {
                    return .split(axis: axis, ratio: ratio, first: first, second: updatedSecond)
                }
                // This is the target split
                let clamped = min(max(newRatio, 0.1), 0.9)
                return .split(axis: axis, ratio: clamped, first: first, second: second)
            }
            // Recurse
            let updatedFirst = first.updatingSplitRatio(whereFirstContains: firstPaneID, andSecondContains: secondPaneID, newRatio: newRatio)
            let updatedSecond = second.updatingSplitRatio(whereFirstContains: firstPaneID, andSecondContains: secondPaneID, newRatio: newRatio)
            if updatedFirst != first || updatedSecond != second {
                return .split(axis: axis, ratio: ratio, first: updatedFirst, second: updatedSecond)
            }
            return self
        }
    }

    /// Swap two leaf panes in the tree.
    func swappingPanes(_ a: UUID, _ b: UUID) -> TerminalSplitNode {
        switch self {
        case .leaf(let id):
            if id == a { return .leaf(b) }
            if id == b { return .leaf(a) }
            return self
        case .split(let axis, let ratio, let first, let second):
            return .split(
                axis: axis,
                ratio: ratio,
                first: first.swappingPanes(a, b),
                second: second.swappingPanes(a, b)
            )
        }
    }

    /// Reset all ratios to 0.5 recursively.
    func equalized() -> TerminalSplitNode {
        switch self {
        case .leaf:
            return self
        case .split(let axis, _, let first, let second):
            return .split(axis: axis, ratio: 0.5, first: first.equalized(), second: second.equalized())
        }
    }

    /// Insert newPaneID beside targetPaneID. If `newPaneFirst`, the new pane is the first child.
    func insertingPaneBeside(_ targetPaneID: UUID, newPaneID: UUID, axis: TerminalSplitAxis, newPaneFirst: Bool) -> TerminalSplitNode? {
        switch self {
        case .leaf(let id):
            guard id == targetPaneID else { return nil }
            let first: TerminalSplitNode = newPaneFirst ? .leaf(newPaneID) : .leaf(id)
            let second: TerminalSplitNode = newPaneFirst ? .leaf(id) : .leaf(newPaneID)
            return .split(axis: axis, ratio: 0.5, first: first, second: second)

        case .split(let currentAxis, let ratio, let first, let second):
            if let updatedFirst = first.insertingPaneBeside(targetPaneID, newPaneID: newPaneID, axis: axis, newPaneFirst: newPaneFirst) {
                return .split(axis: currentAxis, ratio: ratio, first: updatedFirst, second: second)
            }
            if let updatedSecond = second.insertingPaneBeside(targetPaneID, newPaneID: newPaneID, axis: axis, newPaneFirst: newPaneFirst) {
                return .split(axis: currentAxis, ratio: ratio, first: first, second: updatedSecond)
            }
            return nil
        }
    }

    func insertingSplit(at paneID: UUID, newPaneID: UUID, axis: TerminalSplitAxis) -> TerminalSplitNode? {
        switch self {
        case .leaf(let id):
            guard id == paneID else { return nil }
            return .split(
                axis: axis,
                ratio: 0.5,
                first: .leaf(id),
                second: .leaf(newPaneID)
            )

        case .split(let currentAxis, let ratio, let first, let second):
            if let updatedFirst = first.insertingSplit(at: paneID, newPaneID: newPaneID, axis: axis) {
                return .split(axis: currentAxis, ratio: ratio, first: updatedFirst, second: second)
            }
            if let updatedSecond = second.insertingSplit(at: paneID, newPaneID: newPaneID, axis: axis) {
                return .split(axis: currentAxis, ratio: ratio, first: first, second: updatedSecond)
            }
            return nil
        }
    }

    func removingPane(_ paneID: UUID) -> TerminalSplitNode? {
        switch self {
        case .leaf(let id):
            return id == paneID ? nil : self

        case .split(let axis, let ratio, let first, let second):
            let updatedFirst = first.removingPane(paneID)
            let updatedSecond = second.removingPane(paneID)

            if let updatedFirst, let updatedSecond {
                return .split(axis: axis, ratio: ratio, first: updatedFirst, second: updatedSecond)
            }
            if let updatedFirst {
                return updatedFirst
            }
            if let updatedSecond {
                return updatedSecond
            }
            return nil
        }
    }

    /// All leaf pane IDs in tree order.
    var allPaneIDs: [UUID] {
        switch self {
        case .leaf(let id): return [id]
        case .split(_, _, let first, let second):
            return first.allPaneIDs + second.allPaneIDs
        }
    }

    func normalizedPaneFrames() -> [UUID: CGRect] {
        paneFrames(in: CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// Calculate pane frames in actual pixel coordinates.
    func paneFrames(in rect: CGRect) -> [UUID: CGRect] {
        switch self {
        case .leaf(let paneID):
            return [paneID: rect]

        case .split(let axis, let ratio, let first, let second):
            let (firstRect, secondRect) = splitRects(rect: rect, axis: axis, ratio: ratio)
            var output = first.paneFrames(in: firstRect)
            output.merge(second.paneFrames(in: secondRect)) { _, new in new }
            return output
        }
    }

    /// Info about each divider in the tree for flat rendering.
    func dividerInfos(in rect: CGRect) -> [SplitDividerInfo] {
        dividerInfosRecursive(in: rect, path: "")
    }

    private func dividerInfosRecursive(in rect: CGRect, path: String) -> [SplitDividerInfo] {
        switch self {
        case .leaf:
            return []
        case .split(let axis, let ratio, let first, let second):
            let (firstRect, secondRect) = splitRects(rect: rect, axis: axis, ratio: ratio)
            let clampedRatio = min(max(ratio, 0.1), 0.9)

            let dividerFrame: CGRect
            switch axis {
            case .horizontal:
                let x = rect.minX + rect.width * clampedRatio
                dividerFrame = CGRect(x: x - 0.5, y: rect.minY, width: 1, height: rect.height)
            case .vertical:
                let y = rect.minY + rect.height * clampedRatio
                dividerFrame = CGRect(x: rect.minX, y: y - 0.5, width: rect.width, height: 1)
            }

            let dividerID = path.isEmpty ? "d" : path
            let info = SplitDividerInfo(
                id: dividerID,
                axis: axis,
                ratio: clampedRatio,
                frame: dividerFrame,
                firstPaneID: first.firstPaneID ?? UUID(),
                secondPaneID: second.firstPaneID ?? UUID(),
                splitRect: rect
            )

            let prefix = path.isEmpty ? "" : "\(path)."
            return [info]
                + first.dividerInfosRecursive(in: firstRect, path: "\(prefix)0")
                + second.dividerInfosRecursive(in: secondRect, path: "\(prefix)1")
        }
    }

    private func splitRects(rect: CGRect, axis: TerminalSplitAxis, ratio: Double) -> (CGRect, CGRect) {
        let clampedRatio = min(max(ratio, 0.1), 0.9)
        switch axis {
        case .horizontal:
            let w = rect.width * clampedRatio
            return (
                CGRect(x: rect.minX, y: rect.minY, width: w, height: rect.height),
                CGRect(x: rect.minX + w, y: rect.minY, width: rect.width - w, height: rect.height)
            )
        case .vertical:
            let h = rect.height * clampedRatio
            return (
                CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: h),
                CGRect(x: rect.minX, y: rect.minY + h, width: rect.width, height: rect.height - h)
            )
        }
    }
}

/// Terminal tabs and panes are grouped by namespace — either a project (worktree)
/// or a free terminal. Same shape as `ActiveKind` from the sidebar layer; the
/// alias keeps the meaning explicit at the terminal-store boundary while sharing
/// the underlying enum so callers can pass values across both layers cleanly.
typealias TerminalNamespace = ActiveKind

@MainActor
@Observable
final class TerminalWorkspaceStore {
    private(set) var tabs: [TerminalTabState] = []
    var activeTabID: UUID?

    /// Set by the host app to request first responder hand-off to a pane's NSView.
    var focusPaneHandler: ((UUID) -> Void)?

    /// Set by the host app to destroy a pane's ghostty surface when it's permanently closed.
    var destroyPaneHandler: ((UUID) -> Void)?

    /// Fired whenever the active terminal context changes — active tab
    /// switches or the focused pane's reported pwd updates. Used by the
    /// host to refresh non-terminal panels (file explorer / git changes)
    /// that depend on which directory the active terminal is sitting in.
    /// More reliable than relying on SwiftUI's `.onChange(of:)` against
    /// these store properties because the host view doesn't always
    /// otherwise observe them.
    var onContextDidChange: (() -> Void)?

    /// Drag-to-reposition state
    var draggingPaneID: UUID?
    var dragOverPaneID: UUID?
    var dropZone: PaneDropZone?

    /// Maximize/restore: when set, this pane fills the tab area; others are hidden but kept alive
    var maximizedPaneID: UUID?

    // Per-pane search state (paneID → search state, lazily created)
    private(set) var paneSearchStates: [UUID: TerminalSearchState] = [:]

    // Per-pane title tracking (paneID → title)
    private(set) var paneTitles: [UUID: String] = [:]

    // Per-pane working directory (paneID → absolute path), reported by
    // ghostty via GHOSTTY_ACTION_PWD whenever shell integration emits OSC 7
    // or the shell `cd`s. Used to drive file explorer / git changes when the
    // free-terminal namespace is active.
    private(set) var panePwds: [UUID: String] = [:]

    // Pane bell notification state (paneID → last bell time)
    private(set) var paneBellStates: [UUID: Date] = [:]


    // Per-namespace terminal tracking. A namespace is either a project (worktree)
    // or a free terminal — see ProjectStore.ActiveKind for the same idea at the
    // sidebar layer. Surfaces themselves remain flat (paneID-keyed).
    private(set) var activeNamespace: TerminalNamespace?
    private var tabNamespaceMap: [UUID: TerminalNamespace] = [:]

    /// Backwards-compatible accessor: returns the active project id, or nil when a
    /// free terminal namespace is active.
    var activeProjectID: String? {
        if case .project(let id) = activeNamespace { return id }
        return nil
    }

    /// Switch to a project namespace by id. nil clears the active namespace.
    /// Convenience wrapper; equivalent to `switchNamespace(.project(id))` for non-nil ids.
    func switchProject(_ projectID: String?) {
        if let id = projectID {
            switchNamespace(.project(id))
        } else {
            switchNamespace(nil)
        }
    }

    /// Switch the visible namespace. Drops drag state and creates an initial tab if needed.
    func switchNamespace(_ namespace: TerminalNamespace?) {
        activeNamespace = namespace
        maximizedPaneID = nil  // Reset maximize when switching namespaces
        // Clear stale drag state: dragging a pane then switching namespace would leave
        // the ContentShape overlay on every non-source pane in the new namespace's tab.
        draggingPaneID = nil
        dragOverPaneID = nil
        dropZone = nil

        // Create initial tab if namespace has none.
        // Intentionally does NOT fire `onContextDidChange` — the host's
        // sync function is what calls switchNamespace in the first place,
        // so notifying back would cause infinite recursion. The host
        // already knows the namespace just changed.
        guard let namespace else { return }
        let nsTabs = tabs.filter { tabNamespaceMap[$0.id] == namespace }
        if nsTabs.isEmpty {
            _ = newTab(for: namespace)
            return
        }
        // Preserve the user's tab selection when re-entering the same namespace.
        // Without this guard, every `syncActiveProjectContext` (fired by OSC 7
        // pwd reports on each shell command) would reset activeTabID to the
        // first tab — making any non-first tab impossible to stay on while typing.
        if let currentID = activeTabID, tabNamespaceMap[currentID] == namespace {
            return
        }
        activeTabID = nsTabs.first?.id
    }

    /// Tabs for the currently active namespace
    var visibleTabs: [TerminalTabState] {
        guard let activeNamespace else { return tabs }
        return tabs.filter { tabNamespaceMap[$0.id] == activeNamespace }
    }

    /// True if the given namespace owns at least one tab. Used by the sidebar
    /// to split projects into "active" (have a live terminal session) vs
    /// "inactive" (added but never opened) groups.
    func hasTabs(for namespace: TerminalNamespace) -> Bool {
        tabNamespaceMap.values.contains(namespace)
    }

    /// Working directory of the currently focused pane in the active tab,
    /// or nil if pwd hasn't been reported yet. Drives the file explorer /
    /// git changes panels when running in a non-project namespace.
    var activePaneWorkingDirectory: URL? {
        guard let activeTabID,
              let tab = tabs.first(where: { $0.id == activeTabID }),
              let paneID = tab.focusedPaneID ?? tab.splitTree.firstPaneID,
              let pwd = panePwds[paneID]
        else { return nil }
        return URL(fileURLWithPath: pwd)
    }

    func updatePanePwd(paneID: UUID, pwd: String) {
        let normalized = pwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, panePwds[paneID] != normalized else { return }
        panePwds[paneID] = normalized
        // Only fire when the pwd belongs to the currently focused pane —
        // background pane pwd changes don't affect file explorer / git.
        if let activeTabID,
           let tab = tabs.first(where: { $0.id == activeTabID }),
           paneID == (tab.focusedPaneID ?? tab.splitTree.firstPaneID) {
            onContextDidChange?()
        }
    }

    /// Switch the active tab by id. Refreshes focus and notifies host of the
    /// context change (so file explorer / git follow the new tab's pwd).
    func selectTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        guard activeTabID != id else { return }
        activeTabID = id
        if tabs[index].focusedPaneID == nil {
            tabs[index].focusedPaneID = tabs[index].splitTree.firstPaneID
        }
        if let paneID = tabs[index].focusedPaneID {
            requestFocus(for: paneID)
        }
        onContextDidChange?()
    }

    /// Check if a tab belongs to the active namespace
    func isTabVisible(_ tabID: UUID) -> Bool {
        guard let activeNamespace else { return true }
        return tabNamespaceMap[tabID] == activeNamespace
    }

    func ensureInitialTab() {
        guard tabs.isEmpty else { return }
        _ = newTab()
    }

    /// Legacy convenience overload — wraps the namespace-based variant for callers
    /// that still think in terms of project ids.
    @discardableResult
    func newTab(makeActive: Bool = true, forProject projectID: String) -> UUID {
        newTab(makeActive: makeActive, for: .project(projectID))
    }

    @discardableResult
    func newTab(makeActive: Bool = true, for namespace: TerminalNamespace? = nil) -> UUID {
        let paneID = UUID()
        let tabID = UUID()
        let owner = namespace ?? activeNamespace

        // Number tabs per namespace: Tab 1, Tab 2, etc.
        let nsTabCount = tabs.filter { tabNamespaceMap[$0.id] == owner }.count
        let tab = TerminalTabState(
            id: tabID,
            title: "Tab \(nsTabCount + 1)",
            splitTree: .leaf(paneID),
            focusedPaneID: paneID
        )

        tabs.append(tab)
        if let owner {
            tabNamespaceMap[tabID] = owner
        }

        if makeActive {
            activeTabID = tabID
            requestFocus(for: paneID)
        }

        return tabID
    }

    /// Public hook for callers that just performed a state change which the
    /// host should sync against (e.g. + button creating a new tab). Avoids
    /// firing the callback inside store-internal mutations like
    /// switchNamespace / newTab, which would cause sync recursion.
    func notifyContextChange() {
        onContextDidChange?()
    }

    func selectTab(index: Int) {
        guard tabs.indices.contains(index) else { return }
        activeTabID = tabs[index].id

        if tabs[index].focusedPaneID == nil {
            tabs[index].focusedPaneID = tabs[index].splitTree.firstPaneID
        }

        if let paneID = tabs[index].focusedPaneID {
            requestFocus(for: paneID)
        }
    }

    func splitCurrent(axis: TerminalSplitAxis) {
        guard let index = activeTabIndex else { return }
        var tab = tabs[index]

        guard let currentPane = tab.focusedPaneID ?? tab.splitTree.firstPaneID else { return }
        let newPane = UUID()

        guard let newTree = tab.splitTree.insertingSplit(at: currentPane, newPaneID: newPane, axis: axis) else { return }

        tab.splitTree = newTree
        tab.focusedPaneID = newPane
        tabs[index] = tab

        requestFocus(for: newPane)
    }

    /// Close a tab by id (for tab-bar X button). Unlike `closeCurrent`,
    /// this doesn't require the tab to be active — but if the closed tab
    /// was active, focus rolls over to the next tab in the same namespace.
    /// Returns true if the tab was found and removed.
    @discardableResult
    func closeTab(id: UUID) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return false }

        let removed = tabs[index]
        for pID in removed.splitTree.allPaneIDs {
            destroyPaneHandler?(pID)
            paneTitles.removeValue(forKey: pID)
            panePwds.removeValue(forKey: pID)
            paneBellStates.removeValue(forKey: pID)
            paneSearchStates.removeValue(forKey: pID)
        }
        let removedNamespace = tabNamespaceMap[removed.id]
        tabNamespaceMap.removeValue(forKey: removed.id)
        tabs.remove(at: index)

        // If we just closed the active tab, fall back to the next visible
        // one (same namespace) — leave activeTabID untouched if a different
        // tab was closed.
        if activeTabID == id {
            let next = tabs.first { tabNamespaceMap[$0.id] == removedNamespace }
            activeTabID = next?.id
            if let fb = next, let paneID = fb.focusedPaneID ?? fb.splitTree.firstPaneID {
                requestFocus(for: paneID)
            }
            onContextDidChange?()
        }
        return true
    }

    func closeCurrent() -> TerminalCloseAction {
        guard let index = activeTabIndex else { return .closeWindow }
        var tab = tabs[index]

        if tab.splitTree.leafCount > 1 {
            closeFocusedPane(in: &tab)
            tabs[index] = tab
            return .none
        }

        if tabs.count > 1 {
            let removedTab = tabs[index]
            for pID in removedTab.splitTree.allPaneIDs {
                destroyPaneHandler?(pID)
                paneTitles.removeValue(forKey: pID)
            panePwds.removeValue(forKey: pID)
                paneBellStates.removeValue(forKey: pID)
                paneSearchStates.removeValue(forKey: pID)
            }
            tabNamespaceMap.removeValue(forKey: removedTab.id)
            tabs.remove(at: index)

            // Switch to next visible tab for this project
            let visible = visibleTabs
            let fallback = visible.first ?? tabs.last
            activeTabID = fallback?.id

            if let fbID = activeTabID, let fbIdx = tabs.firstIndex(where: { $0.id == fbID }) {
                if tabs[fbIdx].focusedPaneID == nil {
                    tabs[fbIdx].focusedPaneID = tabs[fbIdx].splitTree.firstPaneID
                }
                if let paneID = tabs[fbIdx].focusedPaneID {
                    requestFocus(for: paneID)
                }
            }
            return .none
        }

        return .closeWindow
    }

    func focusNeighbor(_ direction: TerminalFocusDirection) {
        guard let index = activeTabIndex else { return }
        var tab = tabs[index]

        guard let currentPane = tab.focusedPaneID ?? tab.splitTree.firstPaneID else { return }
        let frames = tab.splitTree.normalizedPaneFrames()
        guard let currentFrame = frames[currentPane] else { return }

        let candidate = nextPaneID(from: currentFrame, currentPaneID: currentPane, frames: frames, direction: direction)
        guard let candidate else { return }

        tab.focusedPaneID = candidate
        tabs[index] = tab
        requestFocus(for: candidate)
    }

    func updateSplitRatio(firstPaneID: UUID, secondPaneID: UUID, newRatio: Double) {
        guard let index = activeTabIndex else { return }
        var tab = tabs[index]
        let newTree = tab.splitTree.updatingSplitRatio(
            whereFirstContains: firstPaneID,
            andSecondContains: secondPaneID,
            newRatio: newRatio
        )
        tab.splitTree = newTree
        tabs[index] = tab
    }

    func swapPaneWithNeighbor(_ direction: TerminalFocusDirection) {
        guard let index = activeTabIndex else { return }
        var tab = tabs[index]
        guard let currentPane = tab.focusedPaneID ?? tab.splitTree.firstPaneID else { return }
        let frames = tab.splitTree.normalizedPaneFrames()
        guard let currentFrame = frames[currentPane] else { return }

        guard let neighborID = nextPaneID(from: currentFrame, currentPaneID: currentPane, frames: frames, direction: direction) else { return }

        tab.splitTree = tab.splitTree.swappingPanes(currentPane, neighborID)
        // Focus follows the original pane
        tab.focusedPaneID = currentPane
        tabs[index] = tab
        requestFocus(for: currentPane)
    }

    func movePaneToTarget(sourceID: UUID, targetID: UUID, zone: PaneDropZone) {
        guard sourceID != targetID else { return }
        guard let index = activeTabIndex else { return }
        var tab = tabs[index]

        if zone == .center {
            // Swap: tree shape stays the same, just swap leaf IDs
            tab.splitTree = tab.splitTree.swappingPanes(sourceID, targetID)
        } else {
            // Edge drop: use a placeholder to avoid removing sourceID from the tree,
            // which would destroy the terminal surface.
            let placeholderID = UUID()
            let axis: TerminalSplitAxis
            let sourceFirst: Bool

            switch zone {
            case .left:   axis = .horizontal; sourceFirst = true
            case .right:  axis = .horizontal; sourceFirst = false
            case .top:    axis = .vertical;   sourceFirst = true
            case .bottom: axis = .vertical;   sourceFirst = false
            case .center: return
            }

            // Step 1: Replace source with placeholder (keeps tree structure valid)
            var tree = tab.splitTree.swappingPanes(sourceID, placeholderID)
            // Step 2: Insert sourceID beside targetID
            guard let withSplit = tree.insertingPaneBeside(targetID, newPaneID: sourceID, axis: axis, newPaneFirst: sourceFirst) else { return }
            tree = withSplit
            // Step 3: Remove the placeholder
            guard let final = tree.removingPane(placeholderID) else { return }
            tab.splitTree = final
        }

        tab.focusedPaneID = sourceID
        tabs[index] = tab
        requestFocus(for: sourceID)
    }

    func swapPanes(_ a: UUID, _ b: UUID) {
        guard a != b else { return }
        guard let index = activeTabIndex else { return }
        var tab = tabs[index]
        tab.splitTree = tab.splitTree.swappingPanes(a, b)
        tabs[index] = tab
    }

    func equalizeSplits() {
        guard let index = activeTabIndex else { return }
        var tab = tabs[index]
        tab.splitTree = tab.splitTree.equalized()
        tabs[index] = tab
    }

    /// Toggle maximize for the focused pane. If already maximized, restore.
    func toggleMaximizeCurrentPane() {
        guard let index = activeTabIndex else { return }
        let tab = tabs[index]
        guard tab.splitTree.leafCount > 1 else { return }

        if let current = maximizedPaneID, tab.splitTree.containsPane(current) {
            maximizedPaneID = nil
        } else if let focusedPane = tab.focusedPaneID ?? tab.splitTree.firstPaneID {
            maximizedPaneID = focusedPane
        }
    }

    func updateTitle(for paneID: UUID, title: String) {
        let normalized = normalizeTabTitle(title)
        guard !normalized.isEmpty else { return }

        paneTitles[paneID] = normalized

        for index in tabs.indices {
            guard tabs[index].splitTree.containsPane(paneID) else { continue }
            tabs[index].title = normalized
            return
        }
    }

    /// Called from TerminalNSView focus changes.
    func focusPane(_ paneID: UUID) {
        clearBell(paneID: paneID)

        for index in tabs.indices {
            guard tabs[index].splitTree.containsPane(paneID) else { continue }
            let targetTabID = tabs[index].id
            if activeTabID == targetTabID && tabs[index].focusedPaneID == paneID {
                return
            }

            activeTabID = targetTabID
            tabs[index].focusedPaneID = paneID

            return
        }
    }

    // MARK: - Drag

    /// Called when a pane drag ends without a valid drop target (drag cancelled).
    /// In the success path, `PaneDropDelegate.cleanup()` clears state first and
    /// this becomes a no-op.
    func cancelDragIfActive() {
        guard draggingPaneID != nil else { return }
        NSLog("openOwl: [PaneDrag] drag cancelled (no performDrop) — clearing state")
        draggingPaneID = nil
        dragOverPaneID = nil
        dropZone = nil
    }

    // MARK: - Search

    func searchState(for paneID: UUID) -> TerminalSearchState {
        if let existing = paneSearchStates[paneID] { return existing }
        let state = TerminalSearchState()
        paneSearchStates[paneID] = state
        return state
    }

    func startSearch(paneID: UUID) {
        let state = searchState(for: paneID)
        state.isSearching = true
    }

    func endSearch(paneID: UUID) {
        guard let state = paneSearchStates[paneID] else { return }
        state.debounceTask?.cancel()
        state.debounceTask = nil
        state.isSearching = false
        state.needle = ""
        state.total = nil
        state.selected = nil
    }

    func handleBell(paneID: UUID, isTerminalVisible: Bool) {
        // Only suppress if user is actually looking at the terminal AND this pane is focused
        if isTerminalVisible,
           let activeTabID,
           let tab = tabs.first(where: { $0.id == activeTabID }),
           tab.focusedPaneID == paneID {
            return
        }
        paneBellStates[paneID] = Date()
    }

    func clearBell(paneID: UUID) {
        paneBellStates.removeValue(forKey: paneID)
    }

    /// Pane info for a specific project (used by Sidebar).
    func paneInfos(for projectID: String) -> [PaneInfo] {
        paneInfos(for: .project(projectID))
    }

    func paneInfos(for namespace: TerminalNamespace) -> [PaneInfo] {
        let nsTabs = tabs.filter { tabNamespaceMap[$0.id] == namespace }
        return nsTabs.flatMap { tab in
            tab.splitTree.allPaneIDs.map { paneID in
                PaneInfo(
                    paneID: paneID,
                    tabID: tab.id,
                    title: paneTitles[paneID] ?? tab.title,
                    bellTime: paneBellStates[paneID]
                )
            }
        }
    }

    /// Bell count for a project — lightweight alternative to paneInfos(for:).filter(\.hasBell).count.
    /// Only reads tabs and paneBellStates (not paneTitles), reducing observation dependencies.
    func bellCount(for projectID: String) -> Int {
        bellCount(for: .project(projectID))
    }

    func bellCount(for namespace: TerminalNamespace) -> Int {
        let nsTabs = tabs.filter { tabNamespaceMap[$0.id] == namespace }
        var count = 0
        for tab in nsTabs {
            for paneID in tab.splitTree.allPaneIDs where paneBellStates[paneID] != nil {
                count += 1
            }
        }
        return count
    }

    func isPaneVisible(_ paneID: UUID, in tabID: UUID) -> Bool {
        guard activeTabID == tabID else { return false }
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return false }
        return tab.splitTree.containsPane(paneID)
    }

    func isFocusedPane(_ paneID: UUID, in tabID: UUID) -> Bool {
        guard activeTabID == tabID else { return false }
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return false }
        return tab.focusedPaneID == paneID
    }

    private var activeTabIndex: Int? {
        guard let activeTabID else { return nil }
        return tabs.firstIndex(where: { $0.id == activeTabID })
    }

    private func closeFocusedPane(in tab: inout TerminalTabState) {
        guard let currentPane = tab.focusedPaneID ?? tab.splitTree.firstPaneID else { return }

        let oldFrames = tab.splitTree.normalizedPaneFrames()
        guard let oldFrame = oldFrames[currentPane] else { return }
        guard let newTree = tab.splitTree.removingPane(currentPane) else { return }

        destroyPaneHandler?(currentPane)
        paneTitles.removeValue(forKey: currentPane)
        panePwds.removeValue(forKey: currentPane)
        paneBellStates.removeValue(forKey: currentPane)
        paneSearchStates.removeValue(forKey: currentPane)

        tab.splitTree = newTree

        let newFrames = newTree.normalizedPaneFrames()
        tab.focusedPaneID = nearestPaneID(to: oldFrame, in: newFrames) ?? newTree.firstPaneID

        if let nextPane = tab.focusedPaneID {
            requestFocus(for: nextPane)
        }
    }

    private func requestFocus(for paneID: UUID) {
        focusPaneHandler?(paneID)
    }

    private func normalizeTabTitle(_ rawTitle: String) -> String {
        let trimmed = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return String(trimmed.prefix(120))
    }

    private func nextPaneID(
        from currentFrame: CGRect,
        currentPaneID: UUID,
        frames: [UUID: CGRect],
        direction: TerminalFocusDirection
    ) -> UUID? {
        let epsilon = 0.0001
        let currentCenter = CGPoint(x: currentFrame.midX, y: currentFrame.midY)

        let candidates: [(paneID: UUID, distance: CGFloat, overlap: CGFloat, crossDelta: CGFloat)] = frames.compactMap { paneID, frame in
            guard paneID != currentPaneID else { return nil }

            let isDirectionalMatch: Bool
            let distance: CGFloat
            let overlap: CGFloat
            let crossDelta: CGFloat

            switch direction {
            case .left:
                isDirectionalMatch = frame.maxX <= currentFrame.minX + epsilon
                distance = currentFrame.minX - frame.maxX
                overlap = currentFrame.intersection(frame).height
                crossDelta = abs(currentCenter.y - frame.midY)

            case .right:
                isDirectionalMatch = frame.minX >= currentFrame.maxX - epsilon
                distance = frame.minX - currentFrame.maxX
                overlap = currentFrame.intersection(frame).height
                crossDelta = abs(currentCenter.y - frame.midY)

            case .up:
                isDirectionalMatch = frame.maxY <= currentFrame.minY + epsilon
                distance = currentFrame.minY - frame.maxY
                overlap = currentFrame.intersection(frame).width
                crossDelta = abs(currentCenter.x - frame.midX)

            case .down:
                isDirectionalMatch = frame.minY >= currentFrame.maxY - epsilon
                distance = frame.minY - currentFrame.maxY
                overlap = currentFrame.intersection(frame).width
                crossDelta = abs(currentCenter.x - frame.midX)
            }

            guard isDirectionalMatch else { return nil }
            return (paneID, max(distance, 0), max(overlap, 0), crossDelta)
        }

        guard !candidates.isEmpty else { return nil }

        let sorted = candidates.sorted { lhs, rhs in
            if lhs.distance != rhs.distance {
                return lhs.distance < rhs.distance
            }
            if lhs.overlap != rhs.overlap {
                return lhs.overlap > rhs.overlap
            }
            return lhs.crossDelta < rhs.crossDelta
        }

        return sorted.first?.paneID
    }

    private func nearestPaneID(to previousFrame: CGRect, in frames: [UUID: CGRect]) -> UUID? {
        let previousCenter = CGPoint(x: previousFrame.midX, y: previousFrame.midY)

        return frames.min { lhs, rhs in
            let leftDistance = hypot(lhs.value.midX - previousCenter.x, lhs.value.midY - previousCenter.y)
            let rightDistance = hypot(rhs.value.midX - previousCenter.x, rhs.value.midY - previousCenter.y)
            return leftDistance < rightDistance
        }?.key
    }
}
