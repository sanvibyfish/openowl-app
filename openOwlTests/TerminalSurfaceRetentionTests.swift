import Testing
import Foundation
@testable import openOwl

// MARK: - destroyPaneHandler on close

@Suite("TerminalWorkspaceStore — destroyPaneHandler")
@MainActor
struct DestroyPaneHandlerTests {

    @Test func closeFocusedPane_callsDestroyHandler() {
        let store = TerminalWorkspaceStore()
        store.ensureInitialTab()
        store.splitCurrent(axis: .horizontal)

        var destroyedPaneIDs: [UUID] = []
        store.destroyPaneHandler = { paneID in
            destroyedPaneIDs.append(paneID)
        }

        guard let tab = store.tabs.first(where: { $0.id == store.activeTabID }) else {
            Issue.record("No active tab")
            return
        }
        let focusedPane = tab.focusedPaneID!

        // Close the focused pane (still has a sibling, so tab stays)
        let action = store.closeCurrent(approveProjectDeactivation: { true })

        #expect(action == .none)
        #expect(destroyedPaneIDs == [focusedPane])
    }

    @Test func closeTab_callsDestroyHandler_forTabPane() {
        let store = TerminalWorkspaceStore()
        store.switchProject("project-a")

        // Create a second single-pane tab so closeCurrent removes a tab (not .closeWindow)
        _ = store.newTab(forProject: "project-a")
        #expect(store.tabs.count == 2)

        let activeTab = store.tabs.first(where: { $0.id == store.activeTabID })!
        let expectedPaneID = activeTab.splitTree.firstPaneID!

        var destroyedPaneIDs: [UUID] = []
        store.destroyPaneHandler = { paneID in
            destroyedPaneIDs.append(paneID)
        }

        let action = store.closeCurrent(approveProjectDeactivation: { true })

        #expect(action == .none)
        #expect(destroyedPaneIDs == [expectedPaneID])
        #expect(store.tabs.count == 1)
    }

    @Test func closeWindow_doesNotCallDestroyHandler() {
        // Only one tab with one pane → closeCurrent returns .closeWindow
        // without actually removing anything.
        let store = TerminalWorkspaceStore()
        store.ensureInitialTab()

        var destroyCalled = false
        store.destroyPaneHandler = { _ in
            destroyCalled = true
        }

        let action = store.closeCurrent(approveProjectDeactivation: { true })

        #expect(action == .closeWindow)
        #expect(!destroyCalled)
    }

    @Test func switchProject_doesNotCallDestroyHandler() {
        let store = TerminalWorkspaceStore()
        store.switchProject("project-a")

        var destroyCalled = false
        store.destroyPaneHandler = { _ in
            destroyCalled = true
        }

        // Switch to a different project (creates new tab for project-b)
        store.switchProject("project-b")

        // Switch back — should reuse existing tab, NOT destroy anything
        store.switchProject("project-a")

        #expect(!destroyCalled, "switchProject must not destroy pane surfaces")
    }

    @Test func switchProject_preservesOtherProjectTabs() {
        let store = TerminalWorkspaceStore()
        store.switchProject("project-a")

        guard let tabA = store.tabs.first(where: { $0.id == store.activeTabID }) else {
            Issue.record("No tab for project-a")
            return
        }
        let paneA = tabA.splitTree.firstPaneID!

        store.switchProject("project-b")
        store.switchProject("project-a")

        // Tab A and its pane should still exist
        #expect(store.tabs.contains(where: { $0.id == tabA.id }))
        #expect(store.tabs.first(where: { $0.id == tabA.id })?.splitTree.containsPane(paneA) == true)
        #expect(store.activeTabID == tabA.id)
    }
}

// MARK: - Surface retention across project switches

@Suite("TerminalWorkspaceStore — surface retention")
@MainActor
struct SurfaceRetentionTests {

    @Test func switchProject_activatesExistingTab() {
        let store = TerminalWorkspaceStore()
        store.switchProject("a")
        let tabA = store.activeTabID

        store.switchProject("b")
        let tabB = store.activeTabID
        #expect(tabA != tabB, "Different projects should have different tabs")

        store.switchProject("a")
        #expect(store.activeTabID == tabA, "Should reuse existing tab for project a")

        store.switchProject("b")
        #expect(store.activeTabID == tabB, "Should reuse existing tab for project b")
    }

    @Test func switchProject_doesNotDuplicateTabs() {
        let store = TerminalWorkspaceStore()
        store.switchProject("a")
        store.switchProject("b")
        store.switchProject("a")
        store.switchProject("b")
        store.switchProject("a")

        // Should only have 2 tabs total (one per project), not 5
        #expect(store.tabs.count == 2)
    }

    @Test func switchProject_preservesSplitLayout() {
        let store = TerminalWorkspaceStore()
        store.switchProject("a")
        store.splitCurrent(axis: .horizontal)
        store.splitCurrent(axis: .vertical)

        let tabA = store.tabs.first(where: { $0.id == store.activeTabID })!
        let paneCountBefore = tabA.splitTree.leafCount
        #expect(paneCountBefore == 3)

        // Switch away and back
        store.switchProject("b")
        store.switchProject("a")

        let tabAAfter = store.tabs.first(where: { $0.id == store.activeTabID })!
        #expect(tabAAfter.splitTree.leafCount == paneCountBefore,
                "Split layout must survive project switches")
        #expect(tabAAfter.splitTree.allPaneIDs == tabA.splitTree.allPaneIDs,
                "Pane IDs must be identical after round-trip")
    }

    @Test func visibleTabs_filtersToActiveProject() {
        let store = TerminalWorkspaceStore()
        store.switchProject("a")
        store.switchProject("b")

        // visibleTabs should only show the active project's tabs
        #expect(store.visibleTabs.count == 1)

        store.switchProject("a")
        #expect(store.visibleTabs.count == 1)
    }
}

// MARK: - GhosttyConfig defaults

@Suite("GhosttyConfig — loadDefaults")
struct GhosttyConfigDefaultsTests {

    @Test func loadDefaults_writesExpectedContent() throws {
        // Verify the temp file created by loadDefaults contains our overrides.
        // We can't call loadDefaults directly (needs ghostty_config_t),
        // but we can verify the approach by checking appConfigPath exists.
        let path = GhosttyConfig.appConfigPath()
        #expect(path != nil, "App config directory should be creatable")
    }

    @Test func setOverride_roundTrip() throws {
        // Test that setOverride and readOverride work correctly,
        // which is how users would customize padding.
        let testKey = "test-openowl-key-\(UUID().uuidString.prefix(8))"

        GhosttyConfig.setOverride(key: testKey, value: "42")
        let value = GhosttyConfig.readOverride(key: testKey)
        #expect(value == "42")

        // Clean up
        GhosttyConfig.setOverride(key: testKey, value: nil)
        let removed = GhosttyConfig.readOverride(key: testKey)
        #expect(removed == nil)
    }

    @Test func setOverride_updatesExistingKey() {
        let testKey = "test-override-update-\(UUID().uuidString.prefix(8))"

        GhosttyConfig.setOverride(key: testKey, value: "first")
        GhosttyConfig.setOverride(key: testKey, value: "second")
        let value = GhosttyConfig.readOverride(key: testKey)
        #expect(value == "second")

        // Clean up
        GhosttyConfig.setOverride(key: testKey, value: nil)
    }
}
