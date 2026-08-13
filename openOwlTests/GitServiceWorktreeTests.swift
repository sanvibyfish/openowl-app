import Foundation
import Testing
@testable import openOwl

@Suite("GitService Worktree Removal")
struct GitServiceWorktreeTests {
    @Test func registeredWorktree_isRemovedByGit() async throws {
        let fixture = try GitRepositoryFixture()
        defer { fixture.cleanUp() }

        let worktreeURL = fixture.root.appendingPathComponent("feature-worktree")
        try fixture.runGit(["worktree", "add", "-b", "feature/test", worktreeURL.path])

        let service = GitService(workingDirectory: fixture.repository)
        let outcome = try await service.removeWorktree(path: worktreeURL.path)

        #expect(outcome == .removed)
        #expect(!FileManager.default.fileExists(atPath: worktreeURL.path))
        let registeredPaths = try await service.listWorktrees().map(\.path)
        #expect(!registeredPaths.contains(worktreeURL.path))
    }

    @Test func missingUnregisteredPath_isAlreadyAbsent() async throws {
        let fixture = try GitRepositoryFixture()
        defer { fixture.cleanUp() }

        let missingPath = fixture.root.appendingPathComponent("missing-worktree").path
        let service = GitService(workingDirectory: fixture.repository)

        let outcome = try await service.removeWorktree(path: missingPath)

        #expect(outcome == .alreadyAbsent)
    }

    @Test func existingUnregisteredPath_isPreservedForConfirmation() async throws {
        let fixture = try GitRepositoryFixture()
        defer { fixture.cleanUp() }

        let residualURL = fixture.root.appendingPathComponent("residual-worktree")
        try FileManager.default.createDirectory(
            at: residualURL,
            withIntermediateDirectories: true
        )
        let retainedFile = residualURL.appendingPathComponent("untracked.txt")
        try "keep me".write(to: retainedFile, atomically: true, encoding: .utf8)

        let service = GitService(workingDirectory: fixture.repository)
        let outcome = try await service.removeWorktree(path: residualURL.path)

        #expect(outcome == .unregisteredPath)
        #expect(FileManager.default.fileExists(atPath: retainedFile.path))
    }

    @Test func unremovableDirectory_gitAlreadyUnregistered_returnsUnregisteredPath() async throws {
        let fixture = try GitRepositoryFixture()
        defer { fixture.cleanUp() }

        let worktreeURL = fixture.root.appendingPathComponent("locked-worktree")
        try fixture.runGit(["worktree", "add", "-b", "feature/locked", worktreeURL.path])

        // A read-only directory makes `git worktree remove --force` fail — but
        // only *after* git deleted the worktree registration (its gitdir). This
        // mirrors CocoaPods Pods/ directories in real trees. The folder must be
        // preserved and reported as unregistered so the caller can offer to
        // trash it, never deleted behind the user's back.
        let lockedDir = worktreeURL.appendingPathComponent("Pods", isDirectory: true)
        try FileManager.default.createDirectory(at: lockedDir, withIntermediateDirectories: true)
        try "pod".write(
            to: lockedDir.appendingPathComponent("file.m"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: lockedDir.path
        )

        let service = GitService(workingDirectory: fixture.repository)
        let outcome = try await service.removeWorktree(path: worktreeURL.path)

        #expect(outcome == .unregisteredPath)
        #expect(FileManager.default.fileExists(atPath: worktreeURL.path))
        // git discards the registration before failing on the folder; the stale
        // .git pointer must not survive so discovery ignores the orphan.
        #expect(!FileManager.default.fileExists(
            atPath: worktreeURL.appendingPathComponent(".git").path
        ))
        let registeredPaths = try await service.listWorktrees().map(\.path)
        #expect(!registeredPaths.contains(worktreeURL.path))
    }
}

private final class GitRepositoryFixture {
    let root: URL
    let repository: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openowl-worktree-tests-\(UUID().uuidString)")
        repository = root.appendingPathComponent("repository")

        try FileManager.default.createDirectory(
            at: repository,
            withIntermediateDirectories: true
        )
        try runGit(["init", "-b", "main"])
        try runGit(["config", "user.name", "OpenOwl Tests"])
        try runGit(["config", "user.email", "tests@openowl.local"])

        try "fixture".write(
            to: repository.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "README.md"])
        try runGit(["commit", "-m", "Initial fixture"])
    }

    func runGit(_ arguments: [String], at directory: URL? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = directory ?? repository

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown git error"
            throw NSError(
                domain: "openOwlTests.GitRepositoryFixture",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}
