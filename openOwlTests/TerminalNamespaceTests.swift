import Testing
import Foundation
@testable import openOwl

@Suite("TerminalWorkspaceStore Namespace")
struct TerminalNamespaceTests {

    // MARK: - newTab(for:)

    @Test @MainActor func newTab_forProjectNamespace_associatesTabWithProject() {
        let store = TerminalWorkspaceStore()
        let projectNS: TerminalNamespace = .project("proj-A")
        _ = store.newTab(for: projectNS)

        #expect(store.paneInfos(for: projectNS).count == 1)
        #expect(store.paneInfos(for: .freeTerminal(UUID())).isEmpty)
    }

    @Test @MainActor func newTab_forFreeTerminalNamespace_associatesTabWithFreeTerminal() {
        let store = TerminalWorkspaceStore()
        let termID = UUID()
        let termNS: TerminalNamespace = .freeTerminal(termID)
        _ = store.newTab(for: termNS)

        #expect(store.paneInfos(for: termNS).count == 1)
        #expect(store.paneInfos(for: .project("any-project")).isEmpty)
    }

    @Test @MainActor func newTab_acrossNamespaces_isolatesPanes() {
        let store = TerminalWorkspaceStore()
        let projectNS: TerminalNamespace = .project("proj-A")
        let termNS: TerminalNamespace = .freeTerminal(UUID())

        _ = store.newTab(for: projectNS)
        _ = store.newTab(for: projectNS)
        _ = store.newTab(for: termNS)

        #expect(store.paneInfos(for: projectNS).count == 2)
        #expect(store.paneInfos(for: termNS).count == 1)
    }

    // MARK: - switchNamespace

    @Test @MainActor func switchNamespace_seedsInitialTabIfEmpty() {
        let store = TerminalWorkspaceStore()
        let projectNS: TerminalNamespace = .project("proj-A")
        #expect(store.paneInfos(for: projectNS).isEmpty)

        store.switchNamespace(projectNS)

        #expect(store.paneInfos(for: projectNS).count == 1)
        #expect(store.activeNamespace == projectNS)
    }

    @Test @MainActor func switchNamespace_keepsExistingTabsIntact() {
        let store = TerminalWorkspaceStore()
        let projectNS: TerminalNamespace = .project("proj-A")
        let termNS: TerminalNamespace = .freeTerminal(UUID())

        store.switchNamespace(projectNS)
        let projectPanesAfterSeed = store.paneInfos(for: projectNS)

        store.switchNamespace(termNS)
        store.switchNamespace(projectNS)

        let projectPanesAfterReturn = store.paneInfos(for: projectNS)
        #expect(projectPanesAfterReturn.count == projectPanesAfterSeed.count)
    }

    @Test @MainActor func switchNamespace_visibleTabsReflectActive() {
        let store = TerminalWorkspaceStore()
        let projectNS: TerminalNamespace = .project("proj-A")
        let termNS: TerminalNamespace = .freeTerminal(UUID())

        _ = store.newTab(for: projectNS)
        _ = store.newTab(for: projectNS)
        _ = store.newTab(for: termNS)

        store.switchNamespace(projectNS)
        #expect(store.visibleTabs.count == 2)

        store.switchNamespace(termNS)
        #expect(store.visibleTabs.count == 1)
    }

    @Test @MainActor func switchNamespace_sameNamespace_preservesActiveTab() {
        // Regression: typing in a non-first tab fired updatePanePwd ->
        // onContextDidChange -> syncActiveProjectContext -> switchNamespace,
        // which unconditionally reset activeTabID to the first tab in the
        // namespace. The user's selection of a later tab must survive
        // re-entering the same namespace.
        let store = TerminalWorkspaceStore()
        let termNS: TerminalNamespace = .freeTerminal(UUID())
        _ = store.newTab(for: termNS)
        let tab2 = store.newTab(for: termNS)

        store.switchNamespace(termNS)
        store.selectTab(id: tab2)
        #expect(store.activeTabID == tab2)

        store.switchNamespace(termNS)
        #expect(store.activeTabID == tab2)
    }

    @Test @MainActor func switchNamespace_differentNamespace_resetsToFirstTab() {
        // The same-namespace guard must not block legitimate cross-namespace
        // switches: when activeTabID belongs to a different namespace, the
        // new namespace's first tab should take over.
        let store = TerminalWorkspaceStore()
        let projectNS: TerminalNamespace = .project("proj-A")
        let termNS: TerminalNamespace = .freeTerminal(UUID())

        let projectTab = store.newTab(for: projectNS)
        let termTab1 = store.newTab(for: termNS)
        _ = store.newTab(for: termNS)

        store.switchNamespace(projectNS)
        #expect(store.activeTabID == projectTab)

        store.switchNamespace(termNS)
        #expect(store.activeTabID == termTab1)
    }

    @Test @MainActor func switchNamespace_nil_clearsActive() {
        let store = TerminalWorkspaceStore()
        let projectNS: TerminalNamespace = .project("proj-A")
        store.switchNamespace(projectNS)
        #expect(store.activeNamespace != nil)

        store.switchNamespace(nil)
        #expect(store.activeNamespace == nil)
    }

    // MARK: - switchProject (legacy shim)

    @Test @MainActor func switchProject_id_sameAsSwitchNamespaceProject() {
        let store = TerminalWorkspaceStore()
        store.switchProject("proj-A")

        #expect(store.activeNamespace == .project("proj-A"))
        #expect(store.activeProjectID == "proj-A")
    }

    @Test @MainActor func switchProject_nil_clearsActiveNamespace() {
        let store = TerminalWorkspaceStore()
        store.switchProject("proj-A")
        store.switchProject(nil)

        #expect(store.activeNamespace == nil)
        #expect(store.activeProjectID == nil)
    }

    // MARK: - bellCount(for:)

    @Test @MainActor func bellCount_namespaceVariant_matchesProjectStringVariant() {
        let store = TerminalWorkspaceStore()
        _ = store.newTab(for: .project("proj-A"))

        #expect(store.bellCount(for: "proj-A") == store.bellCount(for: .project("proj-A")))
    }

    @Test @MainActor func bellCount_freeTerminalNamespace_isIsolated() {
        let store = TerminalWorkspaceStore()
        let termNS: TerminalNamespace = .freeTerminal(UUID())
        _ = store.newTab(for: termNS)

        #expect(store.bellCount(for: termNS) == 0)
        #expect(store.bellCount(for: "unrelated") == 0)
    }

    // MARK: - activeProjectID convenience

    @Test @MainActor func activeProjectID_isNilWhenFreeTerminalActive() {
        let store = TerminalWorkspaceStore()
        store.switchNamespace(.freeTerminal(UUID()))

        #expect(store.activeProjectID == nil)
    }

    // MARK: - hasTabs(for:) — sidebar inactive grouping

    @Test @MainActor func hasTabs_emptyStore_returnsFalse() {
        let store = TerminalWorkspaceStore()
        #expect(store.hasTabs(for: .project("proj-A")) == false)
    }

    @Test @MainActor func hasTabs_afterNewTab_returnsTrueForThatNamespaceOnly() {
        let store = TerminalWorkspaceStore()
        _ = store.newTab(for: .project("proj-A"))

        #expect(store.hasTabs(for: .project("proj-A")) == true)
        #expect(store.hasTabs(for: .project("proj-B")) == false)
        #expect(store.hasTabs(for: .freeTerminal(UUID())) == false)
    }

    @Test @MainActor func hasTabs_freeTerminalNamespace_isIsolated() {
        let store = TerminalWorkspaceStore()
        let termID = UUID()
        _ = store.newTab(for: .freeTerminal(termID))

        #expect(store.hasTabs(for: .freeTerminal(termID)) == true)
        #expect(store.hasTabs(for: .freeTerminal(UUID())) == false)
        #expect(store.hasTabs(for: .project("proj-A")) == false)
    }
}
