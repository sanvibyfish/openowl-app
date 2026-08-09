import Foundation
import Testing
@testable import openOwl

@Suite("GitChangesStore")
struct GitChangesStoreTests {
    @Test @MainActor
    func openDiffKeepsSelectionWhenDockSyncsSameRepository() async throws {
        let repositoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openowl-git-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repositoryURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "init", "--quiet"]
        process.currentDirectoryURL = repositoryURL
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        let fileURL = repositoryURL.appendingPathComponent("new-file.txt")
        try "right dock diff\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let store = GitChangesStore(initialDirectory: repositoryURL)
        store.openDiff(forFileURL: fileURL, repositoryCandidateURL: repositoryURL)
        store.setPreferredDirectory(repositoryURL)

        for _ in 0..<100 where store.selectedDiffText.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(store.selectedChange?.path == "new-file.txt")
        #expect(store.selectedDiffText.contains("+right dock diff"))

        let loadedChange = try #require(store.selectedChange)
        store.selectCommit("missing-commit")
        #expect(store.selectedChange == nil)
        #expect(store.selectedDiffText.isEmpty)

        store.selectChange(loadedChange)
        for _ in 0..<100 where store.selectedDiffText.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!store.selectedDiffText.isEmpty)

        store.selectChange(GitFileChange(
            path: "another-file.txt",
            indexStatus: "?",
            workTreeStatus: "?",
            section: .untracked
        ))
        #expect(store.selectedDiffText.isEmpty)
    }

    @Test @MainActor
    func cancelledRepositoryOpenCannotReplaceCurrentRepository() async throws {
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openowl-git-switch-\(UUID().uuidString)", isDirectory: true)
        let firstRepositoryURL = baseURL.appendingPathComponent("first", isDirectory: true)
        let currentRepositoryURL = baseURL.appendingPathComponent("current", isDirectory: true)
        try FileManager.default.createDirectory(at: firstRepositoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: currentRepositoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseURL) }

        for repositoryURL in [firstRepositoryURL, currentRepositoryURL] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git", "init", "--quiet"]
            process.currentDirectoryURL = repositoryURL
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }

        let store = GitChangesStore(initialDirectory: currentRepositoryURL)
        await store.openRepository(at: currentRepositoryURL)

        let staleOpen = Task { @MainActor in
            await store.openRepository(at: firstRepositoryURL)
        }
        staleOpen.cancel()
        await staleOpen.value

        #expect(store.repositoryURL == currentRepositoryURL.standardizedFileURL)
    }

    @Test @MainActor
    func failedRepositoryOpenClearsPreviousRepositoryState() async throws {
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openowl-git-failed-switch-\(UUID().uuidString)", isDirectory: true)
        let repositoryURL = baseURL.appendingPathComponent("repository", isDirectory: true)
        let nonRepositoryURL = baseURL.appendingPathComponent("plain-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nonRepositoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseURL) }

        func runGit(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git"] + arguments
            process.currentDirectoryURL = repositoryURL
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }

        try runGit(["init", "--quiet"])
        try runGit(["config", "user.name", "openOwl Tests"])
        try runGit(["config", "user.email", "tests@openowl.local"])
        try "tracked\n".write(
            to: repositoryURL.appendingPathComponent("tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "tracked.txt"])
        try runGit(["commit", "--quiet", "-m", "Initial commit"])
        try "old repository\n".write(
            to: repositoryURL.appendingPathComponent("old-only.txt"),
            atomically: true,
            encoding: .utf8
        )

        let store = GitChangesStore(initialDirectory: repositoryURL)
        await store.openRepository(at: repositoryURL)
        #expect(store.repositoryURL == repositoryURL.standardizedFileURL)
        #expect(store.statusSnapshot?.untracked.map(\.path) == ["old-only.txt"])
        #expect(store.logEntries.count == 1)

        await store.openRepository(at: nonRepositoryURL)
        #expect(store.repositoryURL == nil)
        #expect(store.statusSnapshot == nil)
        #expect(store.logEntries.isEmpty)
        #expect(!store.hasMoreLog)

        await store.refresh()
        #expect(store.repositoryURL == nil)
        #expect(store.statusSnapshot == nil)
        #expect(store.logEntries.isEmpty)
    }

    @Test @MainActor
    func repeatedLoadMoreRequestsDoNotDuplicateCommits() async throws {
        let repositoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openowl-git-pagination-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repositoryURL) }

        func runGit(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git"] + arguments
            process.currentDirectoryURL = repositoryURL
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }

        try runGit(["init", "--quiet"])
        try runGit(["config", "user.name", "openOwl Tests"])
        try runGit(["config", "user.email", "tests@openowl.local"])
        try "root content\n".write(
            to: repositoryURL.appendingPathComponent("root.txt"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "root.txt"])
        try runGit(["commit", "--quiet", "-m", "Root commit"])
        for index in 0..<54 {
            try runGit(["commit", "--quiet", "--allow-empty", "-m", "Commit \(index)"])
        }

        let store = GitChangesStore(initialDirectory: repositoryURL)
        await store.openRepository(at: repositoryURL)
        #expect(store.logEntries.count == 50)

        store.loadMoreLog()
        store.loadMoreLog()
        store.loadMoreLog()

        for _ in 0..<100 where store.hasMoreLog {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(store.logEntries.count == 55)
        #expect(Set(store.logEntries.map(\.hash)).count == 55)

        let emptyCommit = try #require(store.logEntries.first)
        store.selectCommit(emptyCommit.hash)
        #expect(store.isLoadingCommitDetail)
        for _ in 0..<100 where store.isLoadingCommitDetail {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!store.isLoadingCommitDetail)
        #expect(store.selectedCommitHash == emptyCommit.hash)
        #expect(store.commitDiffText.isEmpty)
        #expect(store.commitDetailErrorMessage == nil)

        store.selectCommit("missing-commit")
        for _ in 0..<100 where store.isLoadingCommitDetail {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!store.isLoadingCommitDetail)
        #expect(store.commitDetailErrorMessage != nil)

        let rootCommit = try #require(store.logEntries.last)
        store.selectCommit(rootCommit.hash)
        for _ in 0..<100 where store.isLoadingCommitDetail {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!store.isLoadingCommitDetail)
        #expect(store.commitFiles.map(\.path) == ["root.txt"])
        #expect(store.commitDiffText.contains("+root content"))
        #expect(store.commitDetailErrorMessage == nil)
    }
}
