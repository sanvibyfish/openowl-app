import Testing
import Foundation
@testable import openOwl

@Suite("TerminalSearchState")
@MainActor
struct TerminalSearchStateTests {

    // MARK: - matchDisplay

    @Test func matchDisplay_noTotal_returnsEmpty() {
        let state = TerminalSearchState()
        state.total = nil
        state.selected = nil
        #expect(state.matchDisplay == "")
    }

    @Test func matchDisplay_totalKnown_noSelection_returnsZeroSlashTotal() {
        let state = TerminalSearchState()
        state.total = 10
        state.selected = nil
        #expect(state.matchDisplay == "0/10")
    }

    @Test func matchDisplay_ghosttySelected0Based_displayIs1Based() {
        // ghostty reports selected as 0-based; UI should show 1-based
        let state = TerminalSearchState()
        state.total = 15
        state.selected = 0   // first match from ghostty
        #expect(state.matchDisplay == "1/15")
    }

    @Test func matchDisplay_lastMatch() {
        let state = TerminalSearchState()
        state.total = 5
        state.selected = 4  // last match (0-based index 4 → display "5")
        #expect(state.matchDisplay == "5/5")
    }

    @Test func matchDisplay_midMatch() {
        let state = TerminalSearchState()
        state.total = 20
        state.selected = 9  // 0-based 9 → display "10"
        #expect(state.matchDisplay == "10/20")
    }
}

// MARK: - endSearch (Esc path)

@Suite("TerminalWorkspaceStore — endSearch")
@MainActor
struct EndSearchTests {

    @Test func endSearch_resetsAllState() {
        let store = TerminalWorkspaceStore()
        let paneID = UUID()
        store.startSearch(paneID: paneID)
        let state = store.paneSearchStates[paneID]!
        state.needle = "hello"
        state.total = 10
        state.selected = 3

        store.endSearch(paneID: paneID)

        #expect(!state.isSearching)
        #expect(state.needle == "")
        #expect(state.total == nil)
        #expect(state.selected == nil)
    }

    /// Esc ghost-command regression test.
    ///
    /// When the user types 1-2 chars and presses Esc within 300ms, the debounce
    /// task would previously fire a real ghostty `search:X` command ~300ms after
    /// the bar visually closed. endSearch() must cancel it before it fires.
    @Test func endSearch_cancelsPendingDebounceTask() async throws {
        let store = TerminalWorkspaceStore()
        let paneID = UUID()
        store.startSearch(paneID: paneID)
        let state = store.paneSearchStates[paneID]!

        var ghostCommandFired = false
        state.debounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            ghostCommandFired = true
        }

        // Esc path: AppDelegate calls workspaceStore.endSearch directly
        store.endSearch(paneID: paneID)

        // Wait beyond the 50ms window; if the task wasn't cancelled it would fire here
        try await Task.sleep(for: .milliseconds(150))

        #expect(!ghostCommandFired, "endSearch must cancel the pending debounce task")
    }

    @Test func endSearch_noop_forUnknownPane() {
        // Should not crash when no search state exists for the pane
        let store = TerminalWorkspaceStore()
        store.endSearch(paneID: UUID())
    }
}

// MARK: - switchProject drag state

@Suite("TerminalWorkspaceStore — switchProject drag state")
@MainActor
struct SwitchProjectDragTests {

    @Test func switchProject_clearsDragState() {
        let store = TerminalWorkspaceStore()
        store.draggingPaneID = UUID()
        store.dragOverPaneID = UUID()
        store.dropZone = .center

        store.switchProject("project-abc")

        #expect(store.draggingPaneID == nil)
        #expect(store.dragOverPaneID == nil)
        #expect(store.dropZone == nil)
    }

    @Test func switchProject_clearsDragState_whenNilProjectID() {
        // Switching to nil project (e.g. no projects) also clears drag state
        let store = TerminalWorkspaceStore()
        store.draggingPaneID = UUID()
        store.dragOverPaneID = UUID()

        store.switchProject(nil)

        #expect(store.draggingPaneID == nil)
        #expect(store.dragOverPaneID == nil)
    }

    @Test func switchProject_sameProject_keepsActiveDrag() {
        let store = TerminalWorkspaceStore()
        store.switchProject("project-abc")
        let source = UUID()
        let target = UUID()
        store.draggingPaneID = source
        store.dragOverPaneID = target
        store.dropZone = .right

        store.switchProject("project-abc")

        #expect(store.draggingPaneID == source)
        #expect(store.dragOverPaneID == target)
        #expect(store.dropZone == .right)
    }

    @Test func switchProject_alsoResetMaximize() {
        let store = TerminalWorkspaceStore()
        store.maximizedPaneID = UUID()
        store.draggingPaneID = UUID()

        store.switchProject("project-xyz")

        #expect(store.maximizedPaneID == nil)
        #expect(store.draggingPaneID == nil)
    }
}

// MARK: - drag cancel

@Suite("TerminalWorkspaceStore — drag cancel")
@MainActor
struct PaneDragCancelTests {

    @Test func cancelDragIfActive_noop_whenNoActiveDrag() {
        let store = TerminalWorkspaceStore()
        store.draggingPaneID = nil

        store.cancelDragIfActive()

        #expect(store.draggingPaneID == nil)
        #expect(store.dragOverPaneID == nil)
        #expect(store.dropZone == nil)
    }

    @Test func cancelDragIfActive_clearsAllDragState() {
        let store = TerminalWorkspaceStore()
        let paneA = UUID()
        let paneB = UUID()
        store.draggingPaneID = paneA
        store.dragOverPaneID = paneB
        store.dropZone = .center

        store.cancelDragIfActive()

        #expect(store.draggingPaneID == nil)
        #expect(store.dragOverPaneID == nil)
        #expect(store.dropZone == nil)
    }

    @Test func cancelDragIfActive_clearsOrphanedDropTargetState() {
        let store = TerminalWorkspaceStore()
        store.dragOverPaneID = UUID()
        store.dropZone = .left

        store.cancelDragIfActive()

        #expect(store.dragOverPaneID == nil)
        #expect(store.dropZone == nil)
    }

    @Test func cancelDragIfActive_idempotent() {
        let store = TerminalWorkspaceStore()
        store.draggingPaneID = UUID()

        store.cancelDragIfActive()
        store.cancelDragIfActive()  // second call should be a no-op

        #expect(store.draggingPaneID == nil)
    }

    @Test func cancelDragIfActive_doesNotClearWhenAlreadyClearedByPerformDrop() {
        // Simulate: TerminalScrollView completed the drop and cleared draggingPaneID.
        // cancelDragIfActive fires next from the NSDraggingSource end callback.
        // dragOverPaneID should also be nil — not touched by a spurious cancel.
        let store = TerminalWorkspaceStore()
        let pane = UUID()
        store.draggingPaneID = pane
        store.dragOverPaneID = pane

        // Simulate cleanup() from performDrop
        store.draggingPaneID = nil
        store.dragOverPaneID = nil
        store.dropZone = nil

        // Then cancelDragIfActive fires — should be a no-op
        store.cancelDragIfActive()

        #expect(store.draggingPaneID == nil)
        #expect(store.dragOverPaneID == nil)
    }
}
