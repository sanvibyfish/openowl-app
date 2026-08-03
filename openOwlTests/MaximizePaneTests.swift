import Testing
import Foundation
@testable import openOwl

@Suite("Maximize Pane")
struct MaximizePaneTests {

    // MARK: - Initial state

    @Test @MainActor func maximizedPaneID_initiallyNil() {
        let store = TerminalWorkspaceStore()
        #expect(store.maximizedPaneID == nil)
    }

    // MARK: - toggleMaximizeCurrentPane

    @Test @MainActor func toggle_singlePane_doesNothing() {
        let store = TerminalWorkspaceStore()
        store.ensureInitialTab()

        store.toggleMaximizeCurrentPane()

        // Single pane — maximize has no effect
        #expect(store.maximizedPaneID == nil)
    }

    @Test @MainActor func toggle_multiPane_maximizesFocused() {
        let store = TerminalWorkspaceStore()
        store.ensureInitialTab()

        // Split to create 2 panes
        store.splitCurrent(axis: .horizontal)

        guard let tab = store.tabs.first(where: { $0.id == store.activeTabID }) else {
            Issue.record("No active tab")
            return
        }
        let focusedPane = tab.focusedPaneID

        store.toggleMaximizeCurrentPane()

        #expect(store.maximizedPaneID == focusedPane)
    }

    @Test @MainActor func toggle_twice_restores() {
        let store = TerminalWorkspaceStore()
        store.ensureInitialTab()
        store.splitCurrent(axis: .horizontal)

        store.toggleMaximizeCurrentPane()
        #expect(store.maximizedPaneID != nil)

        store.toggleMaximizeCurrentPane()
        #expect(store.maximizedPaneID == nil)
    }

    // MARK: - switchProject resets maximize

    @Test @MainActor func switchProject_resetsMaximize() {
        let store = TerminalWorkspaceStore()
        store.switchProject("project-a")
        store.splitCurrent(axis: .horizontal)
        store.toggleMaximizeCurrentPane()
        #expect(store.maximizedPaneID != nil)

        store.switchProject("project-b")
        #expect(store.maximizedPaneID == nil)
    }

    // MARK: - Maximize persists across focus changes within same tab

    @Test @MainActor func maximize_persistsOnFocusChange() {
        let store = TerminalWorkspaceStore()
        store.ensureInitialTab()
        store.splitCurrent(axis: .horizontal)

        guard let tab = store.tabs.first(where: { $0.id == store.activeTabID }) else {
            Issue.record("No active tab")
            return
        }

        let paneIDs = tab.splitTree.allPaneIDs
        #expect(paneIDs.count == 2)

        // Maximize first pane
        store.focusPane(paneIDs[0])
        store.toggleMaximizeCurrentPane()
        #expect(store.maximizedPaneID == paneIDs[0])

        // Focus second pane (via code) — maximize should still be set
        store.focusPane(paneIDs[1])
        #expect(store.maximizedPaneID == paneIDs[0])
    }

    // MARK: - Explicit pane target (drag-handle double click)

    /// The handle that was double-clicked belongs to a specific pane, which is
    /// not necessarily the focused one.
    @Test @MainActor func toggle_withPaneID_maximizesThatPaneNotTheFocusedOne() {
        let store = TerminalWorkspaceStore()
        store.ensureInitialTab()
        store.splitCurrent(axis: .horizontal)

        guard let tab = store.tabs.first(where: { $0.id == store.activeTabID }) else {
            Issue.record("No active tab")
            return
        }
        let paneIDs = tab.splitTree.allPaneIDs
        #expect(paneIDs.count == 2)

        store.focusPane(paneIDs[0])
        store.toggleMaximizeCurrentPane(paneID: paneIDs[1])

        #expect(store.maximizedPaneID == paneIDs[1])
    }

    /// Restoring works from any pane's handle — while maximized only one handle
    /// is on screen, but the toggle must not depend on which id it carries.
    @Test @MainActor func toggle_withPaneID_restoresRegardlessOfTarget() {
        let store = TerminalWorkspaceStore()
        store.ensureInitialTab()
        store.splitCurrent(axis: .horizontal)

        guard let tab = store.tabs.first(where: { $0.id == store.activeTabID }) else {
            Issue.record("No active tab")
            return
        }
        let paneIDs = tab.splitTree.allPaneIDs

        store.toggleMaximizeCurrentPane(paneID: paneIDs[0])
        #expect(store.maximizedPaneID == paneIDs[0])

        store.toggleMaximizeCurrentPane(paneID: paneIDs[0])
        #expect(store.maximizedPaneID == nil)
    }

    /// The split tree is untouched by maximize — restoring brings back the exact
    /// ratios the user dragged, and every pane survives.
    @Test @MainActor func maximize_leavesSplitTreeIntact() {
        let store = TerminalWorkspaceStore()
        store.ensureInitialTab()
        store.splitCurrent(axis: .horizontal)

        guard let before = store.tabs.first(where: { $0.id == store.activeTabID })?.splitTree else {
            Issue.record("No active tab")
            return
        }

        store.toggleMaximizeCurrentPane()
        let during = store.tabs.first(where: { $0.id == store.activeTabID })?.splitTree
        store.toggleMaximizeCurrentPane()
        let after = store.tabs.first(where: { $0.id == store.activeTabID })?.splitTree

        #expect(during == before)
        #expect(after == before)
    }

    // MARK: - Maximize only activates in multi-pane

    @Test @MainActor func maximize_requiresMultiplePanes() {
        let store = TerminalWorkspaceStore()
        store.ensureInitialTab()

        // Single pane — toggle should do nothing
        store.toggleMaximizeCurrentPane()
        #expect(store.maximizedPaneID == nil)

        // Add a split
        store.splitCurrent(axis: .vertical)

        // Now toggle should work
        store.toggleMaximizeCurrentPane()
        #expect(store.maximizedPaneID != nil)
    }
}
