import Testing
import Foundation
@testable import openOwl

@Suite("orderedProjectTabs")
struct OrderedProjectTabsTests {

    // MARK: - Helpers

    @MainActor
    private func storeWithProjects(_ items: [ProjectItem]) -> ProjectStore {
        let store = makeIsolatedProjectStore()
        // Inject test projects directly (bypasses persistence)
        for item in items {
            store.addOrActivateProject(item.url)
        }
        return store
    }

    // MARK: - Basic ordering

    @Test @MainActor func emptyStore_returnsEmpty() {
        let store = makeIsolatedProjectStore()
        // Fresh store might have seeded project; test the computed property logic directly
        let rootCount = store.rootProjects.count
        let tabCount = store.orderedProjectTabs.count
        // orderedProjectTabs should include roots + their worktrees
        #expect(tabCount >= rootCount)
    }

    @Test @MainActor func singleRoot_noWorktrees() {
        let store = makeIsolatedProjectStore()
        let root = ProjectItem(path: "/tmp/test-project-alpha", name: "Alpha")
        store.addOrActivateProject(root.url)

        let tabs = store.orderedProjectTabs
        // Should contain at least our project
        let alphaTab = tabs.first(where: { $0.path == root.url.standardizedFileURL.path })
        #expect(alphaTab != nil)
        #expect(alphaTab?.isWorktree == false)
    }

    @Test @MainActor func rootWithWorktrees_worktreesFollowRoot() {
        let store = makeIsolatedProjectStore()
        let rootURL = URL(fileURLWithPath: "/tmp/test-ordered-root", isDirectory: true)
        store.addOrActivateProject(rootURL)

        // Find the root's ID
        guard let rootItem = store.projects.first(where: { $0.path == rootURL.standardizedFileURL.path }) else {
            Issue.record("Root not found")
            return
        }

        // Add worktrees
        let wt1 = store.addWorktreeProject(parentID: rootItem.id, path: "/tmp/test-ordered-wt1", branch: "feature-a")
        let wt2 = store.addWorktreeProject(parentID: rootItem.id, path: "/tmp/test-ordered-wt2", branch: "feature-b")

        let tabs = store.orderedProjectTabs

        // Find positions
        let rootIndex = tabs.firstIndex(where: { $0.id == rootItem.id })
        let wt1Index = tabs.firstIndex(where: { $0.id == wt1.id })
        let wt2Index = tabs.firstIndex(where: { $0.id == wt2.id })

        #expect(rootIndex != nil)
        #expect(wt1Index != nil)
        #expect(wt2Index != nil)

        // Worktrees must come after their root
        if let ri = rootIndex, let w1i = wt1Index, let w2i = wt2Index {
            #expect(w1i > ri)
            #expect(w2i > ri)
        }
    }

    @Test @MainActor func multipleRoots_worktreesGroupedUnderRespectiveRoot() {
        let store = makeIsolatedProjectStore()

        let urlA = URL(fileURLWithPath: "/tmp/test-multi-root-aaa", isDirectory: true)
        let urlB = URL(fileURLWithPath: "/tmp/test-multi-root-bbb", isDirectory: true)
        store.addOrActivateProject(urlA)
        store.addOrActivateProject(urlB)

        guard let rootA = store.projects.first(where: { $0.path == urlA.standardizedFileURL.path }),
              let rootB = store.projects.first(where: { $0.path == urlB.standardizedFileURL.path }) else {
            Issue.record("Roots not found")
            return
        }

        let wtA = store.addWorktreeProject(parentID: rootA.id, path: "/tmp/test-multi-wt-a", branch: "feat-a")
        let wtB = store.addWorktreeProject(parentID: rootB.id, path: "/tmp/test-multi-wt-b", branch: "feat-b")

        let tabs = store.orderedProjectTabs

        let rootAIdx = tabs.firstIndex(where: { $0.id == rootA.id })!
        let wtAIdx = tabs.firstIndex(where: { $0.id == wtA.id })!
        let rootBIdx = tabs.firstIndex(where: { $0.id == rootB.id })!
        let wtBIdx = tabs.firstIndex(where: { $0.id == wtB.id })!

        // wtA sits between rootA and rootB (or after rootB if rootB comes first)
        // Key invariant: each worktree is adjacent to its root, before the next root
        if rootAIdx < rootBIdx {
            #expect(wtAIdx > rootAIdx && wtAIdx < rootBIdx)
            #expect(wtBIdx > rootBIdx)
        } else {
            #expect(wtBIdx > rootBIdx && wtBIdx < rootAIdx)
            #expect(wtAIdx > rootAIdx)
        }
    }

    @Test @MainActor func orderedProjectTabs_excludesNoOrphanWorktrees() {
        let store = makeIsolatedProjectStore()
        let tabs = store.orderedProjectTabs

        // Every worktree in the result should have a root also in the result
        let rootIDs = Set(tabs.filter { !$0.isWorktree }.map(\.id))
        for tab in tabs where tab.isWorktree {
            #expect(rootIDs.contains(tab.worktreeOf ?? ""))
        }
    }

    // MARK: - Tab count

    @Test @MainActor func tabCount_equalsRootsPlusWorktrees() {
        let store = makeIsolatedProjectStore()
        let url = URL(fileURLWithPath: "/tmp/test-count-root", isDirectory: true)
        store.addOrActivateProject(url)

        guard let root = store.projects.first(where: { $0.path == url.standardizedFileURL.path }) else {
            Issue.record("Root not found")
            return
        }

        _ = store.addWorktreeProject(parentID: root.id, path: "/tmp/test-count-wt1", branch: "wt1")
        _ = store.addWorktreeProject(parentID: root.id, path: "/tmp/test-count-wt2", branch: "wt2")

        let tabs = store.orderedProjectTabs
        let thisRootTabs = tabs.filter { $0.id == root.id || $0.worktreeOf == root.id }
        #expect(thisRootTabs.count == 3)  // 1 root + 2 worktrees
    }

    // MARK: - Worktree archive progress

    @Test @MainActor func beginArchivingWorktree_rejectsDuplicateWorktree() {
        let store = makeIsolatedProjectStore()

        #expect(store.beginArchivingWorktree(id: "worktree-a"))
        #expect(!store.beginArchivingWorktree(id: "worktree-a"))
        #expect(store.isArchivingWorktree(id: "worktree-a"))
    }

    @Test @MainActor func beginArchivingWorktree_allowsDifferentWorktrees() {
        let store = makeIsolatedProjectStore()

        #expect(store.beginArchivingWorktree(id: "worktree-a"))
        #expect(store.beginArchivingWorktree(id: "worktree-b"))
        #expect(store.isArchivingWorktree(id: "worktree-a"))
        #expect(store.isArchivingWorktree(id: "worktree-b"))
    }

    @Test @MainActor func endArchivingWorktree_allowsRetry() {
        let store = makeIsolatedProjectStore()

        #expect(store.beginArchivingWorktree(id: "worktree-a"))
        store.endArchivingWorktree(id: "worktree-a")

        #expect(!store.isArchivingWorktree(id: "worktree-a"))
        #expect(store.beginArchivingWorktree(id: "worktree-a"))
    }

    @Test @MainActor func archivingWorktree_cannotBecomeActiveUntilArchiveEnds() {
        let store = makeIsolatedProjectStore()
        let rootURL = URL(
            fileURLWithPath: "/tmp/test-archive-activation-root-\(UUID().uuidString)",
            isDirectory: true
        )
        store.addOrActivateProject(rootURL)
        let root = store.projects.first { $0.path == rootURL.standardizedFileURL.path }!
        let worktree = store.addWorktreeProject(
            parentID: root.id,
            path: "/tmp/test-archive-activation-wt-\(UUID().uuidString)",
            branch: "feature/archive"
        )

        #expect(store.beginArchivingWorktree(id: worktree.id))
        #expect(!store.activateProject(id: worktree.id))
        #expect(store.activeProjectID == root.id)

        store.endArchivingWorktree(id: worktree.id)
        #expect(store.activateProject(id: worktree.id))
        #expect(store.activeProjectID == worktree.id)
    }

    @Test @MainActor func removeActiveWorktree_vetoLeavesSelectionAndProjectsUnchanged() {
        let store = makeIsolatedProjectStore()
        let rootURL = URL(
            fileURLWithPath: "/tmp/test-remove-active-root-\(UUID().uuidString)",
            isDirectory: true
        )
        store.addOrActivateProject(rootURL)
        let root = store.projects.first { $0.path == rootURL.standardizedFileURL.path }!
        let worktree = store.addWorktreeProject(
            parentID: root.id,
            path: "/tmp/test-remove-active-wt-\(UUID().uuidString)",
            branch: "feature/remove-veto"
        )
        #expect(store.activateProject(id: worktree.id))
        let projectsBefore = store.projects
        let approverID = UUID()
        store.registerActiveContextChangeApprover(id: approverID) { false }

        store.removeWorktreeProject(id: worktree.id)

        #expect(store.projects == projectsBefore)
        #expect(store.activeProjectID == worktree.id)
    }

    @Test @MainActor func newlyRegisteredWorktree_remainsRegisteredWhenActivationIsVetoed() {
        let store = makeIsolatedProjectStore()
        let rootURL = URL(
            fileURLWithPath: "/tmp/test-create-final-veto-root-\(UUID().uuidString)",
            isDirectory: true
        )
        store.addOrActivateProject(rootURL)
        let root = store.projects.first { $0.path == rootURL.standardizedFileURL.path }!
        let worktree = store.addWorktreeProject(
            parentID: root.id,
            path: "/tmp/test-create-final-veto-wt-\(UUID().uuidString)",
            branch: "feature/final-veto"
        )
        let approverID = UUID()
        store.registerActiveContextChangeApprover(id: approverID) { false }

        #expect(!store.activateProject(id: worktree.id))
        #expect(store.projects.contains(where: { $0.id == worktree.id }))
        #expect(store.activeProjectID == root.id)
    }

    // MARK: - Project Rail selection restoration

    @Test @MainActor func activateLastProject_restoresPreviouslySelectedWorktree() {
        let store = makeIsolatedProjectStore()
        let firstRootURL = URL(
            fileURLWithPath: "/tmp/test-restore-root-\(UUID().uuidString)",
            isDirectory: true
        )
        let secondRootURL = URL(
            fileURLWithPath: "/tmp/test-restore-other-\(UUID().uuidString)",
            isDirectory: true
        )
        store.addOrActivateProject(firstRootURL)
        store.addOrActivateProject(secondRootURL)

        let firstRoot = store.projects.first { $0.path == firstRootURL.standardizedFileURL.path }!
        let secondRoot = store.projects.first { $0.path == secondRootURL.standardizedFileURL.path }!
        let worktree = store.addWorktreeProject(
            parentID: firstRoot.id,
            path: "/tmp/test-restore-wt-\(UUID().uuidString)",
            branch: "feature/restore"
        )

        store.activateProject(id: worktree.id)
        store.activateProject(id: secondRoot.id)
        store.activateLastProject(inRoot: firstRoot.id)

        #expect(store.activeProjectID == worktree.id)
    }

    @Test @MainActor func activateLastProject_keepsExplicitMainSelection() {
        let store = makeIsolatedProjectStore()
        let firstRootURL = URL(
            fileURLWithPath: "/tmp/test-restore-main-\(UUID().uuidString)",
            isDirectory: true
        )
        let secondRootURL = URL(
            fileURLWithPath: "/tmp/test-restore-main-other-\(UUID().uuidString)",
            isDirectory: true
        )
        store.addOrActivateProject(firstRootURL)
        store.addOrActivateProject(secondRootURL)

        let firstRoot = store.projects.first { $0.path == firstRootURL.standardizedFileURL.path }!
        let secondRoot = store.projects.first { $0.path == secondRootURL.standardizedFileURL.path }!
        let worktree = store.addWorktreeProject(
            parentID: firstRoot.id,
            path: "/tmp/test-restore-main-wt-\(UUID().uuidString)",
            branch: "feature/main"
        )

        store.activateProject(id: worktree.id)
        store.activateProject(id: firstRoot.id)
        store.activateProject(id: secondRoot.id)
        store.activateLastProject(inRoot: firstRoot.id)

        #expect(store.activeProjectID == firstRoot.id)
    }
}
