import Testing
import Foundation
@testable import openOwl

@MainActor
func makeIsolatedProjectStore() -> ProjectStore {
    let storeURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("openowl-project-store-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent("openowl.json")
    return ProjectStore(storeURL: storeURL, unreadableStoreAlertPresenter: { _ in })
}

@Suite("ProjectStore Persistence")
struct ProjectStorePersistenceTests {

    // MARK: - ProjectItem Codable

    @Test func projectItem_roundTrip() throws {
        let item = ProjectItem(
            path: "/Users/dev/project",
            name: "project",
            worktreeOf: "parent-123",
            worktreeBranch: "feature/x"
        )

        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(ProjectItem.self, from: data)

        #expect(decoded.name == "project")
        #expect(decoded.worktreeOf == "parent-123")
        #expect(decoded.worktreeBranch == "feature/x")
        #expect(decoded.isWorktree == true)
    }

    @Test func projectItem_minimalJSON() throws {
        // Old JSON without optional fields
        let json = """
        {"id": "abc", "path": "/tmp/p", "name": "p"}
        """
        let decoded = try JSONDecoder().decode(ProjectItem.self, from: Data(json.utf8))
        #expect(decoded.id == "abc")
        #expect(decoded.worktreeOf == nil)
        #expect(decoded.worktreeBranch == nil)
        #expect(decoded.lastBranch == nil)
        #expect(decoded.branchPrefix == nil)
        #expect(decoded.isWorktree == false)
    }

    @Test func projectItem_withBranchPrefix() throws {
        let json = """
        {"id": "x", "path": "/tmp/p", "name": "p", "branchPrefix": "sanvi"}
        """
        let decoded = try JSONDecoder().decode(ProjectItem.self, from: Data(json.utf8))
        #expect(decoded.branchPrefix == "sanvi")
    }

    // MARK: - ProjectItem identity

    @Test func projectItem_pathNormalization() {
        let item1 = ProjectItem(url: URL(fileURLWithPath: "/Users/dev/project/"))
        let item2 = ProjectItem(url: URL(fileURLWithPath: "/Users/dev/project"))
        #expect(item1.path == item2.path)
    }

    @Test func projectItem_displayName_fromPath() {
        let item = ProjectItem(url: URL(fileURLWithPath: "/Users/dev/my-project"))
        #expect(item.displayName == "my-project")
    }

    // MARK: - openowl.json format

    @Test func storeFileFormat_matchesExpected() throws {
        // Simulate what ProjectStore writes
        let items = [
            ProjectItem(url: URL(fileURLWithPath: "/tmp/project1")),
            ProjectItem(url: URL(fileURLWithPath: "/tmp/project2")),
        ]

        struct StoreFile: Codable {
            var projects: [ProjectItem]
            var activeProjectId: String?
        }

        let store = StoreFile(projects: items, activeProjectId: items[0].id)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(store)
        let json = String(data: data, encoding: .utf8)!

        #expect(json.contains("\"projects\""))
        #expect(json.contains("\"activeProjectId\""))
        #expect(json.contains(items[0].id))

        // Verify round-trip
        let decoded = try JSONDecoder().decode(StoreFile.self, from: data)
        #expect(decoded.projects.count == 2)
        #expect(decoded.activeProjectId == items[0].id)
    }

    @Test @MainActor func unreadableStore_quarantinesOriginalAndAllowsPersistence() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openowl-quarantine-success-\(UUID().uuidString)", isDirectory: true)
        let storeURL = directory.appendingPathComponent("openowl.json")
        let corruptData = Data("{not-json".utf8)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try corruptData.write(to: storeURL)
        defer { try? FileManager.default.removeItem(at: directory) }

        var presentedNotice: UnreadableProjectStoreNotice?
        let store = ProjectStore(
            storeURL: storeURL,
            unreadableStoreAlertPresenter: { notice in
                presentedNotice = notice
            }
        )

        let backups = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("openowl.json.corrupt-") }
        #expect(backups.count == 1)
        #expect(try Data(contentsOf: backups[0]) == corruptData)
        if case .quarantined(_, let backupURL) = presentedNotice {
            #expect(backupURL.standardizedFileURL == backups[0].standardizedFileURL)
        } else {
            Issue.record("Expected a quarantined-store notice")
        }
        #expect(!store.isStoreUnreadable)

        let projectURL = directory.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        store.addOrActivateProject(projectURL)

        #expect(try Data(contentsOf: storeURL) != corruptData)
    }

    @Test @MainActor func unreadableStore_quarantineFailureVetoesLaterPersistence() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openowl-quarantine-failure-\(UUID().uuidString)", isDirectory: true)
        let storeURL = directory.appendingPathComponent("openowl.json")
        let corruptData = Data("{still-not-json".utf8)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try corruptData.write(to: storeURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }

        var presentedNotice: UnreadableProjectStoreNotice?
        let store = ProjectStore(
            storeURL: storeURL,
            unreadableStoreAlertPresenter: { notice in
                presentedNotice = notice
            }
        )
        #expect(store.isStoreUnreadable)
        if case .quarantineFailed(_, let originalURL, _) = presentedNotice {
            #expect(originalURL.standardizedFileURL == storeURL.standardizedFileURL)
        } else {
            Issue.record("Expected a quarantine-failed notice")
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let projectURL = directory.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        store.addOrActivateProject(projectURL)

        #expect(try Data(contentsOf: storeURL) == corruptData)
    }

    @Test @MainActor func contextChangePreflight_vetoesAddBeforeStateOrPersistenceChanges() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openowl-preflight-veto-\(UUID().uuidString)", isDirectory: true)
        let storeURL = directory.appendingPathComponent("openowl.json")
        let baselineProjectURL = directory.appendingPathComponent("baseline-project", isDirectory: true)
        try FileManager.default.createDirectory(at: baselineProjectURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ProjectStore(
            storeURL: storeURL,
            unreadableStoreAlertPresenter: { _ in }
        )
        store.addOrActivateProject(baselineProjectURL)
        let projectsBefore = store.projects
        let activeBefore = store.activeKind
        let persistedBefore = try Data(contentsOf: storeURL)
        let approverID = UUID()
        store.registerActiveContextChangeApprover(id: approverID) { false }

        let newProjectURL = directory.appendingPathComponent("vetoed-project", isDirectory: true)
        try FileManager.default.createDirectory(at: newProjectURL, withIntermediateDirectories: true)
        store.addOrActivateProject(newProjectURL)

        #expect(store.projects == projectsBefore)
        #expect(store.activeKind == activeBefore)
        #expect(try Data(contentsOf: storeURL) == persistedBefore)
    }

    @Test @MainActor func activateProject_reportsVetoWithoutPersisting() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openowl-activate-veto-\(UUID().uuidString)", isDirectory: true)
        let storeURL = directory.appendingPathComponent("openowl.json")
        let firstURL = directory.appendingPathComponent("first", isDirectory: true)
        let secondURL = directory.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ProjectStore(
            storeURL: storeURL,
            unreadableStoreAlertPresenter: { _ in }
        )
        store.addOrActivateProject(firstURL)
        let firstID = try #require(store.projects.first(where: { $0.path == firstURL.path })?.id)
        store.addOrActivateProject(secondURL)
        let activeBefore = store.activeKind
        let persistedBefore = try Data(contentsOf: storeURL)
        let approverID = UUID()
        store.registerActiveContextChangeApprover(id: approverID) { false }

        #expect(!store.activateProject(id: firstID))
        #expect(store.activeKind == activeBefore)
        #expect(try Data(contentsOf: storeURL) == persistedBefore)
    }

    @Test @MainActor func contextChangeApprovers_requireEveryRegisteredEditorToApprove() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openowl-approver-registry-\(UUID().uuidString)", isDirectory: true)
        let firstURL = directory.appendingPathComponent("first", isDirectory: true)
        let secondURL = directory.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ProjectStore(
            storeURL: directory.appendingPathComponent("openowl.json"),
            unreadableStoreAlertPresenter: { _ in }
        )
        store.addOrActivateProject(firstURL)
        let firstID = try #require(store.projects.first(where: { $0.path == firstURL.path })?.id)
        store.addOrActivateProject(secondURL)
        let secondID = try #require(store.projects.first(where: { $0.path == secondURL.path })?.id)

        let approvingEditorID = UUID()
        let vetoingEditorID = UUID()
        store.registerActiveContextChangeApprover(id: approvingEditorID) { true }
        store.registerActiveContextChangeApprover(id: vetoingEditorID) { false }

        #expect(!store.activateProject(id: firstID))
        #expect(store.activeProjectID == secondID)

        store.unregisterActiveContextChangeApprover(id: vetoingEditorID)

        #expect(store.activateProject(id: firstID))
        #expect(store.activeProjectID == firstID)
    }

    @Test @MainActor func unregisterActiveContextChangeApprover_removesOnlyMatchingToken() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openowl-approver-unregister-\(UUID().uuidString)", isDirectory: true)
        let firstURL = directory.appendingPathComponent("first", isDirectory: true)
        let secondURL = directory.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ProjectStore(
            storeURL: directory.appendingPathComponent("openowl.json"),
            unreadableStoreAlertPresenter: { _ in }
        )
        store.addOrActivateProject(firstURL)
        let firstID = try #require(store.projects.first(where: { $0.path == firstURL.path })?.id)
        store.addOrActivateProject(secondURL)
        let secondID = try #require(store.projects.first(where: { $0.path == secondURL.path })?.id)

        let firstVetoID = UUID()
        let secondVetoID = UUID()
        store.registerActiveContextChangeApprover(id: firstVetoID) { false }
        store.registerActiveContextChangeApprover(id: secondVetoID) { false }
        store.unregisterActiveContextChangeApprover(id: firstVetoID)

        #expect(!store.activateProject(id: firstID))
        #expect(store.activeProjectID == secondID)

        store.unregisterActiveContextChangeApprover(id: secondVetoID)
        #expect(store.activateProject(id: firstID))
    }

    @Test @MainActor func defaultStoreUnderXCTest_persistsOnlyToProcessTemporaryStore() throws {
        let sentinelURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "openowl-default-store-sentinel-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: sentinelURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sentinelURL) }

        let store = ProjectStore(unreadableStoreAlertPresenter: { _ in })
        store.addOrActivateProject(sentinelURL)

        let processStoreURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "openowl-project-store-test-host-\(ProcessInfo.processInfo.processIdentifier)",
                isDirectory: true
            )
            .appendingPathComponent("openowl.json")
        let processStoreData = try Data(contentsOf: processStoreURL)
        let processStoreObject = try #require(
            JSONSerialization.jsonObject(with: processStoreData) as? [String: Any]
        )
        let processProjectPaths = (processStoreObject["projects"] as? [[String: Any]])?
            .compactMap { $0["path"] as? String } ?? []
        #expect(processProjectPaths.contains(sentinelURL.standardizedFileURL.path))

        let productionStoreURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".openowl/openowl.json")
        if FileManager.default.fileExists(atPath: productionStoreURL.path) {
            let productionStoreData = try Data(contentsOf: productionStoreURL)
            let productionStoreObject = try #require(
                JSONSerialization.jsonObject(with: productionStoreData) as? [String: Any]
            )
            let productionProjectPaths = (productionStoreObject["projects"] as? [[String: Any]])?
                .compactMap { $0["path"] as? String } ?? []
            #expect(!productionProjectPaths.contains(sentinelURL.standardizedFileURL.path))
        }
    }
}
