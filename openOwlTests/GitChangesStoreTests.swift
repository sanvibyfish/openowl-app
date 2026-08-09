import Foundation
import Testing
@testable import openOwl

@Suite("GitChangesStore")
struct GitChangesStoreTests {
    @Test @MainActor
    func commitDraftsAreIsolatedByRepository() async throws {
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openowl-git-drafts-\(UUID().uuidString)", isDirectory: true)
        let firstURL = baseURL.appendingPathComponent("first", isDirectory: true)
        let secondURL = baseURL.appendingPathComponent("second", isDirectory: true)
        let plainURL = baseURL.appendingPathComponent("plain", isDirectory: true)
        for directory in [firstURL, secondURL, plainURL] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: baseURL) }

        for repositoryURL in [firstURL, secondURL] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git", "init", "--quiet"]
            process.currentDirectoryURL = repositoryURL
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }

        let store = GitChangesStore(initialDirectory: firstURL)
        await store.openRepository(at: firstURL)
        store.commitMessage = "first draft"

        await store.openRepository(at: secondURL)
        #expect(store.commitMessage.isEmpty)
        store.commitMessage = "second draft"

        await store.openRepository(at: firstURL)
        #expect(store.commitMessage == "first draft")
        await store.openRepository(at: secondURL)
        #expect(store.commitMessage == "second draft")

        await store.openRepository(at: plainURL)
        #expect(store.repositoryURL == nil)
        #expect(store.commitMessage.isEmpty)
    }

    @Test @MainActor
    func stageAllIncludesFilesBeyondDisplayedSnapshot() async throws {
        let repositoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openowl-git-stage-all-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repositoryURL) }

        let initProcess = Process()
        initProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        initProcess.arguments = ["git", "init", "--quiet"]
        initProcess.currentDirectoryURL = repositoryURL
        try initProcess.run()
        initProcess.waitUntilExit()
        #expect(initProcess.terminationStatus == 0)

        for index in 0..<501 {
            try "\(index)\n".write(
                to: repositoryURL.appendingPathComponent("file-\(index).txt"),
                atomically: true,
                encoding: .utf8
            )
        }

        let store = GitChangesStore(initialDirectory: repositoryURL)
        await store.openRepository(at: repositoryURL)
        #expect(store.statusSnapshot?.untracked.count == 500)
        #expect(store.statusSnapshot?.untrackedTruncated == true)

        store.stageAll()
        for _ in 0..<200 where store.isRunningCommand {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!store.isRunningCommand)

        let stagedProcess = Process()
        let stdout = Pipe()
        stagedProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        stagedProcess.arguments = ["git", "diff", "--staged", "--name-only"]
        stagedProcess.currentDirectoryURL = repositoryURL
        stagedProcess.standardOutput = stdout
        try stagedProcess.run()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        stagedProcess.waitUntilExit()
        #expect(stagedProcess.terminationStatus == 0)
        let stagedPaths = String(decoding: output, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
        #expect(stagedPaths.count == 501)
    }

    @Test @MainActor
    func commandCompletionFromPreviousRepositoryDoesNotMutateCurrentUI() async throws {
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openowl-git-stale-command-\(UUID().uuidString)", isDirectory: true)
        let firstURL = baseURL.appendingPathComponent("first", isDirectory: true)
        let secondURL = baseURL.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseURL) }

        func runGit(_ arguments: [String], at repositoryURL: URL) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git"] + arguments
            process.currentDirectoryURL = repositoryURL
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }

        for repositoryURL in [firstURL, secondURL] {
            try runGit(["init", "--quiet"], at: repositoryURL)
            try runGit(["config", "user.name", "openOwl Tests"], at: repositoryURL)
            try runGit(["config", "user.email", "tests@openowl.local"], at: repositoryURL)
        }
        try "change\n".write(
            to: firstURL.appendingPathComponent("change.txt"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "change.txt"], at: firstURL)

        let hookURL = firstURL.appendingPathComponent(".git/hooks/pre-commit")
        try "#!/bin/sh\nsleep 0.4\nexit 1\n".write(to: hookURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookURL.path)

        let store = GitChangesStore(initialDirectory: firstURL)
        await store.openRepository(at: firstURL)
        store.commitMessage = "stale commit"
        store.commit()
        #expect(store.isRunningCommand)

        let switchTask = Task { @MainActor in
            await store.openRepository(at: secondURL)
        }
        await Task.yield()
        #expect(store.isRunningCommand)
        await switchTask.value
        #expect(store.isRunningCommand)
        store.commitMessage = "current draft"
        for _ in 0..<100 where store.isRunningCommand {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(store.repositoryURL == secondURL.standardizedFileURL)
        #expect(store.commitMessage == "current draft")
        #expect(store.infoMessage == nil)
        #expect(store.errorMessage == nil)
        #expect(!store.isRunningCommand)
    }

    @Test @MainActor
    func sameRepositoryOpenIntentKeepsCommandBusyUntilOperationCompletes() async throws {
        let repositoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openowl-git-command-lock-\(UUID().uuidString)", isDirectory: true)
        let subdirectoryURL = repositoryURL.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: subdirectoryURL, withIntermediateDirectories: true)
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
        try "change\n".write(
            to: repositoryURL.appendingPathComponent("change.txt"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "change.txt"])

        let hookURL = repositoryURL.appendingPathComponent(".git/hooks/pre-commit")
        try "#!/bin/sh\nsleep 0.4\nexit 1\n".write(to: hookURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookURL.path)

        let store = GitChangesStore(initialDirectory: repositoryURL)
        await store.openRepository(at: repositoryURL)
        store.commitMessage = "slow commit"
        store.commit()
        #expect(store.isRunningCommand)

        await store.openRepository(at: subdirectoryURL)
        #expect(store.repositoryURL == repositoryURL.standardizedFileURL)
        #expect(store.isRunningCommand)

        store.unstageAll()
        for _ in 0..<100 where store.isRunningCommand {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!store.isRunningCommand)

        let stagedProcess = Process()
        let stdout = Pipe()
        stagedProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        stagedProcess.arguments = ["git", "diff", "--staged", "--name-only"]
        stagedProcess.currentDirectoryURL = repositoryURL
        stagedProcess.standardOutput = stdout
        try stagedProcess.run()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        stagedProcess.waitUntilExit()
        #expect(stagedProcess.terminationStatus == 0)
        #expect(String(decoding: output, as: UTF8.self).contains("change.txt"))
        #expect(store.errorMessage == nil)
    }

    @Test @MainActor
    func staleWorkingTreeDiffCannotOverwriteCurrentSelection() async throws {
        let repositoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openowl-git-stale-diff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repositoryURL) }

        let initProcess = Process()
        initProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        initProcess.arguments = ["git", "init", "--quiet"]
        initProcess.currentDirectoryURL = repositoryURL
        try initProcess.run()
        initProcess.waitUntilExit()
        #expect(initProcess.terminationStatus == 0)

        let pipeURL = repositoryURL.appendingPathComponent("slow.pipe")
        let fifoProcess = Process()
        fifoProcess.executableURL = URL(fileURLWithPath: "/usr/bin/mkfifo")
        fifoProcess.arguments = [pipeURL.path]
        try fifoProcess.run()
        fifoProcess.waitUntilExit()
        #expect(fifoProcess.terminationStatus == 0)

        try "current\n".write(
            to: repositoryURL.appendingPathComponent("current.txt"),
            atomically: true,
            encoding: .utf8
        )

        let store = GitChangesStore(initialDirectory: repositoryURL)
        await store.openRepository(at: repositoryURL)
        let slowChange = GitFileChange(
            path: "slow.pipe",
            indexStatus: "?",
            workTreeStatus: "?",
            section: .untracked
        )
        let currentChange = GitFileChange(
            path: "current.txt",
            indexStatus: "?",
            workTreeStatus: "?",
            section: .untracked
        )
        store.selectChange(slowChange)
        try await Task.sleep(for: .milliseconds(100))
        store.selectChange(currentChange)
        for _ in 0..<100 where !store.selectedDiffText.contains("+current") {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.selectedChange?.id == currentChange.id)
        #expect(store.selectedDiffText.contains("+current"))

        let writer = Process()
        writer.executableURL = URL(fileURLWithPath: "/bin/sh")
        writer.arguments = ["-c", "printf stale > slow.pipe"]
        writer.currentDirectoryURL = repositoryURL
        try writer.run()
        writer.waitUntilExit()
        #expect(writer.terminationStatus == 0)
        try await Task.sleep(for: .milliseconds(200))

        #expect(store.selectedChange?.id == currentChange.id)
        #expect(store.selectedDiffText.contains("+current"))
        #expect(!store.selectedDiffText.contains("+stale"))
    }

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
    func emptyRepositoryReportsUnbornBranchName() async throws {
        let repositoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openowl-git-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repositoryURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "init", "--quiet", "--initial-branch=trunk"]
        process.currentDirectoryURL = repositoryURL
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        let store = GitChangesStore(initialDirectory: repositoryURL)
        await store.openRepository(at: repositoryURL)

        #expect(store.statusSnapshot?.branch == "trunk")
        #expect(store.logEntries.isEmpty)
        #expect(store.errorMessage == nil)
    }

    @Test @MainActor
    func preferredDirectorySwitchesFromOuterToNestedRepository() async throws {
        let outerRepositoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openowl-git-nested-\(UUID().uuidString)", isDirectory: true)
        let nestedRepositoryURL = outerRepositoryURL.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedRepositoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outerRepositoryURL) }

        for repositoryURL in [outerRepositoryURL, nestedRepositoryURL] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git", "init", "--quiet"]
            process.currentDirectoryURL = repositoryURL
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }

        try "nested change\n".write(
            to: nestedRepositoryURL.appendingPathComponent("nested.txt"),
            atomically: true,
            encoding: .utf8
        )

        let store = GitChangesStore(initialDirectory: outerRepositoryURL)
        await store.openRepository(at: outerRepositoryURL)
        #expect(store.repositoryURL == outerRepositoryURL.standardizedFileURL)

        store.setPreferredDirectory(nestedRepositoryURL)
        for _ in 0..<100 where store.statusSnapshot?.repositoryRoot.standardizedFileURL != nestedRepositoryURL.standardizedFileURL {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(store.repositoryURL == nestedRepositoryURL.standardizedFileURL)
        #expect(store.statusSnapshot?.untracked.map(\.path) == ["nested.txt"])
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
        #expect(store.errorMessage != nil)

        store.selectChange(GitFileChange(
            path: "root.txt",
            indexStatus: " ",
            workTreeStatus: "M",
            section: .modified
        ))
        #expect(store.commitDetailErrorMessage == nil)
        #expect(store.errorMessage == nil)

        let rootCommit = try #require(store.logEntries.last)
        store.selectCommit(rootCommit.hash)
        #expect(store.errorMessage == nil)
        for _ in 0..<100 where store.isLoadingCommitDetail {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!store.isLoadingCommitDetail)
        #expect(store.commitFiles.map(\.path) == ["root.txt"])
        #expect(store.commitDiffText.contains("+root content"))
        #expect(store.commitDetailErrorMessage == nil)
        #expect(store.errorMessage == nil)
    }
}
