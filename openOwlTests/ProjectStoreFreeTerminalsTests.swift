import Testing
import Foundation
@testable import openOwl

@Suite("ProjectStore Free Terminals")
struct ProjectStoreFreeTerminalsTests {

    // MARK: - Init

    @Test @MainActor func init_seedsAtLeastOneFreeTerminal() {
        let store = makeIsolatedProjectStore()
        #expect(store.freeTerminals.count >= 1)
    }

    @Test @MainActor func init_freeTerminalsHaveUniqueIDs() {
        let store = makeIsolatedProjectStore()
        _ = store.addFreeTerminal()
        _ = store.addFreeTerminal()
        let ids = Set(store.freeTerminals.map(\.id))
        #expect(ids.count == store.freeTerminals.count)
    }

    // MARK: - addFreeTerminal

    @Test @MainActor func addFreeTerminal_appendsItem() {
        let store = makeIsolatedProjectStore()
        let initialCount = store.freeTerminals.count

        let added = store.addFreeTerminal()

        #expect(store.freeTerminals.count == initialCount + 1)
        #expect(store.freeTerminals.contains(where: { $0.id == added.id }))
    }

    // MARK: - removeFreeTerminal

    @Test @MainActor func removeFreeTerminal_dropsItem_whenMoreThanOne() {
        let store = makeIsolatedProjectStore()
        let extra = store.addFreeTerminal()
        let countBefore = store.freeTerminals.count

        store.removeFreeTerminal(id: extra.id)

        #expect(store.freeTerminals.count == countBefore - 1)
        #expect(!store.freeTerminals.contains(where: { $0.id == extra.id }))
    }

    @Test @MainActor func removeFreeTerminal_lastOne_isNoOp() {
        let store = makeIsolatedProjectStore()
        // Reduce to a single free terminal first.
        while store.freeTerminals.count > 1 {
            if let last = store.freeTerminals.last {
                store.removeFreeTerminal(id: last.id)
            }
        }
        #expect(store.freeTerminals.count == 1)

        let lastID = store.freeTerminals[0].id
        store.removeFreeTerminal(id: lastID)

        #expect(store.freeTerminals.count == 1)
        #expect(store.freeTerminals[0].id == lastID)
    }

    @Test @MainActor func removeFreeTerminal_active_fallsBackToFirstRemaining() {
        let store = makeIsolatedProjectStore()
        let first = store.freeTerminals.first!
        let second = store.addFreeTerminal()
        store.activate(.freeTerminal(second.id))
        #expect(store.activeFreeTerminalID == second.id)

        store.removeFreeTerminal(id: second.id)

        #expect(store.activeFreeTerminalID == first.id)
    }

    @Test @MainActor func removeFreeTerminal_unknownID_isNoOp() {
        let store = makeIsolatedProjectStore()
        let countBefore = store.freeTerminals.count
        store.removeFreeTerminal(id: UUID())
        #expect(store.freeTerminals.count == countBefore)
    }

    // MARK: - activate / activeKind

    @Test @MainActor func activate_freeTerminal_clearsActiveProjectID() {
        let store = makeIsolatedProjectStore()
        let term = store.freeTerminals.first!
        store.activeProjectID = "fake-project-id"

        #expect(store.activate(.freeTerminal(term.id)))

        // activate is async — drive the runloop briefly
        let exp = Date().addingTimeInterval(1.0)
        while Date() < exp && (store.activeProjectID != nil || store.activeFreeTerminalID == nil) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }

        #expect(store.activeProjectID == nil)
        #expect(store.activeFreeTerminalID == term.id)
    }

    @Test @MainActor func activate_unknownFreeTerminal_isNoOp() {
        let store = makeIsolatedProjectStore()
        let originalActive = store.activeFreeTerminalID

        #expect(!store.activate(.freeTerminal(UUID())))

        // Wait briefly to ensure no async update sneaks in
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        #expect(store.activeFreeTerminalID == originalActive)
    }

    @Test @MainActor func activate_currentFreeTerminal_reportsSuccessWithoutChangingSelection() {
        let store = makeIsolatedProjectStore()
        let terminal = store.freeTerminals.first!
        #expect(store.activate(.freeTerminal(terminal.id)))

        #expect(store.activate(.freeTerminal(terminal.id)))
        #expect(store.activeFreeTerminalID == terminal.id)
    }

    @Test @MainActor func activate_freeTerminal_reportsVetoAndKeepsProjectSelection() {
        let store = makeIsolatedProjectStore()
        let projectURL = URL(
            fileURLWithPath: "/tmp/test-terminal-veto-project-\(UUID().uuidString)",
            isDirectory: true
        )
        store.addOrActivateProject(projectURL)
        let projectID = store.activeProjectID
        let terminal = store.freeTerminals.first!
        let approverID = UUID()
        store.registerActiveContextChangeApprover(id: approverID) { false }

        #expect(!store.activate(.freeTerminal(terminal.id)))
        #expect(store.activeProjectID == projectID)
        #expect(store.activeFreeTerminalID == nil)
    }

    @Test @MainActor func activeKind_reflectsProjectFirst() {
        let store = makeIsolatedProjectStore()
        store.activeProjectID = "proj-1"

        if case .project(let id) = store.activeKind {
            #expect(id == "proj-1")
        } else {
            Issue.record("Expected .project case")
        }
    }

    @Test @MainActor func activeKind_reflectsFreeTerminalWhenNoProject() {
        let store = makeIsolatedProjectStore()
        let term = store.freeTerminals.first!
        store.activeProjectID = nil
        store.activeFreeTerminalID = term.id

        if case .freeTerminal(let id) = store.activeKind {
            #expect(id == term.id)
        } else {
            Issue.record("Expected .freeTerminal case")
        }
    }

    @Test @MainActor func setActiveProjectID_clearsActiveFreeTerminal() {
        let store = makeIsolatedProjectStore()
        let term = store.freeTerminals.first!
        store.activeFreeTerminalID = term.id
        #expect(store.activeFreeTerminalID == term.id)

        store.activeProjectID = "some-project"

        #expect(store.activeFreeTerminalID == nil)
    }
}
