import Testing
import Foundation
@testable import openOwl

@Suite("GitService Parsing")
struct GitServiceParsingTests {

    private let service = GitService(workingDirectory: URL(fileURLWithPath: "/tmp"))

    // MARK: - parseBranch

    @Test func parseBranch_simple() {
        let result = service.parseBranch(from: "## main")
        #expect(result.branch == "main")
        #expect(result.upstreamBranch == nil)
        #expect(result.trackingSummary == nil)
    }

    @Test func parseBranch_withUpstream() {
        let result = service.parseBranch(from: "## main...origin/main")
        #expect(result.branch == "main")
        #expect(result.upstreamBranch == "origin/main")
        #expect(result.trackingSummary == nil)
    }

    @Test func parseBranch_aheadBehind() {
        let result = service.parseBranch(from: "## feature...origin/feature [ahead 3, behind 1]")
        #expect(result.branch == "feature")
        #expect(result.upstreamBranch == "origin/feature")
        #expect(result.trackingSummary == "ahead 3, behind 1")
    }

    @Test func parseBranch_detachedHEAD() {
        let result = service.parseBranch(from: "## HEAD (no branch)")
        #expect(result.branch == "HEAD (no branch)")
        #expect(result.upstreamBranch == nil)
    }

    @Test func parseBranch_unbornBranch() {
        let result = service.parseBranch(from: "## No commits yet on trunk")
        #expect(result.branch == "trunk")
        #expect(result.upstreamBranch == nil)
        #expect(result.trackingSummary == nil)
    }

    // MARK: - parseAheadBehind

    @Test func parseAheadBehind_aheadOnly() {
        let result = service.parseAheadBehind(from: "ahead 5")
        #expect(result.ahead == 5)
        #expect(result.behind == 0)
    }

    @Test func parseAheadBehind_behindOnly() {
        let result = service.parseAheadBehind(from: "behind 2")
        #expect(result.ahead == 0)
        #expect(result.behind == 2)
    }

    @Test func parseAheadBehind_both() {
        let result = service.parseAheadBehind(from: "ahead 3, behind 1")
        #expect(result.ahead == 3)
        #expect(result.behind == 1)
    }

    @Test func parseAheadBehind_nil() {
        let result = service.parseAheadBehind(from: nil)
        #expect(result.ahead == 0)
        #expect(result.behind == 0)
    }

    // MARK: - parseStatus

    @Test func parseStatus_mixedChanges() throws {
        let output = """
        ## main...origin/main [ahead 1]
        M  file1.swift
         M file2.swift
        ?? newfile.txt
        """
        let snapshot = try service.parseStatus(output)
        #expect(snapshot.branch == "main")
        #expect(snapshot.aheadCount == 1)
        #expect(snapshot.staged.count == 1)
        #expect(snapshot.modified.count == 1)
        #expect(snapshot.untracked.count == 1)
        #expect(snapshot.staged.first?.path == "file1.swift")
        #expect(snapshot.untracked.first?.path == "newfile.txt")
    }

    @Test func parseStatus_empty() throws {
        let output = "## main"
        let snapshot = try service.parseStatus(output)
        #expect(snapshot.branch == "main")
        #expect(snapshot.staged.isEmpty)
        #expect(snapshot.modified.isEmpty)
        #expect(snapshot.untracked.isEmpty)
    }

    @Test func parseStatus_renamedFile() throws {
        let output = """
        ## main
        R  old.swift -> new.swift
        """
        let snapshot = try service.parseStatus(output)
        #expect(snapshot.staged.count == 1)
        #expect(snapshot.staged.first?.path == "new.swift")
    }

    @Test func parseStatus_conflictsAppearOnlyInChanges() throws {
        for status in ["UU", "AA", "DD", "AU", "UA", "DU", "UD"] {
            let snapshot = try service.parseStatus("## main\n\(status) conflict.txt")
            #expect(snapshot.staged.isEmpty, "\(status) must not appear as staged")
            #expect(snapshot.modified.count == 1)
            #expect(snapshot.modified[0].path == "conflict.txt")
            #expect(snapshot.modified[0].statusCode == status)
        }

        let modifiedInBoth = try service.parseStatus("## main\nMM regular.txt")
        #expect(modifiedInBoth.staged.count == 1)
        #expect(modifiedInBoth.modified.count == 1)
    }

    // MARK: - decodePath

    @Test func decodePath_plain() {
        #expect(service.decodePath("src/file.swift") == "src/file.swift")
    }

    @Test func decodePath_quoted() {
        #expect(service.decodePath("\"src/file name.swift\"") == "src/file name.swift")
    }

    @Test func decodePath_escaped() {
        #expect(service.decodePath("\"path\\\\to\\\"file\"") == "path\\to\"file")
    }

    @Test func decodePath_octalSingleByte() {
        // \101 = 'A' (octal 101 = decimal 65)
        #expect(service.decodePath("\"\\101.swift\"") == "A.swift")
    }

    @Test func decodePath_octalUTF8_chinese() {
        // "中" = UTF-8 bytes E4 B8 AD = octal 344 270 255
        let input = "\"\\344\\270\\255.swift\""
        #expect(service.decodePath(input) == "中.swift")
    }

    @Test func decodePath_octalMixed() {
        // Mix of ASCII and octal-encoded characters
        let input = "\"src/\\346\\226\\207\\344\\273\\266.swift\""
        #expect(service.decodePath(input) == "src/文件.swift")
    }

    // MARK: - parsePath

    @Test func parsePath_withArrow() {
        #expect(service.parsePath("old.swift -> new.swift") == "new.swift")
    }

    @Test func parsePath_withoutArrow() {
        #expect(service.parsePath("file.swift") == "file.swift")
    }

    @Test func parsePath_quotedRenameContainingArrows() {
        let rawPath = "\"a -> b.txt\" -> \"c -> d.txt\""
        #expect(service.decodePath(service.parsePath(rawPath)) == "c -> d.txt")
    }

    // MARK: - Repository operations

    @Test func unstageFiles_inUnbornRepositoryClearsIndexAndPreservesWorktree() async throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repository) }
        try write("one", to: repository.appendingPathComponent("one.txt"))
        try write("two", to: repository.appendingPathComponent("two.txt"))
        _ = try runGit(["add", "one.txt", "two.txt"], at: repository)

        try await GitService(workingDirectory: repository).unstage(files: ["one.txt"])

        #expect(try runGit(["diff", "--cached", "--name-only"], at: repository) == "two.txt\n")
        #expect(try String(contentsOf: repository.appendingPathComponent("one.txt"), encoding: .utf8) == "one")
        #expect(try String(contentsOf: repository.appendingPathComponent("two.txt"), encoding: .utf8) == "two")
    }

    @Test func unstageAll_inUnbornRepositoryClearsIndexAndPreservesWorktree() async throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repository) }
        let file = repository.appendingPathComponent("new.txt")
        try write("worktree", to: file)
        _ = try runGit(["add", "new.txt"], at: repository)

        try await GitService(workingDirectory: repository).unstageAll()

        #expect(try runGit(["diff", "--cached", "--name-only"], at: repository).isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try String(contentsOf: file, encoding: .utf8) == "worktree")
    }

    @Test func unstageAll_inRepositoryWithHeadRestoresIndexToHead() async throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repository) }
        let file = repository.appendingPathComponent("tracked.txt")
        let secondFile = repository.appendingPathComponent("second.txt")
        try write("base", to: file)
        try write("second base", to: secondFile)
        _ = try runGit(["add", "tracked.txt", "second.txt"], at: repository)
        _ = try runGit(["commit", "--quiet", "-m", "base"], at: repository)
        try write("changed", to: file)
        try write("second changed", to: secondFile)
        _ = try runGit(["add", "tracked.txt", "second.txt"], at: repository)

        try await GitService(workingDirectory: repository).unstageAll()

        #expect(try runGit(["diff", "--cached", "--name-only"], at: repository).isEmpty)
        #expect(try String(contentsOf: file, encoding: .utf8) == "changed")
        #expect(try String(contentsOf: secondFile, encoding: .utf8) == "second changed")
    }

    @Test func untrackedDiffAcceptsDifferenceAndRejectsExitCodeAboveOne() async throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repository) }
        try write("new content\n", to: repository.appendingPathComponent("new.txt"))
        let service = GitService(workingDirectory: repository)
        let change = GitFileChange(path: "new.txt", indexStatus: "?", workTreeStatus: "?", section: .untracked)

        let diff = try await service.diff(for: change)
        #expect(diff.contains("+new content"))

        let externalDiff = repository.appendingPathComponent("failing-diff.sh")
        try write("#!/bin/sh\nexit 2\n", to: externalDiff)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: externalDiff.path)
        _ = try runGit(["config", "diff.external", externalDiff.path], at: repository)
        do {
            _ = try await service.diff(for: change)
            Issue.record("Expected git diff to reject an exit code above 1")
        } catch let GitServiceError.commandFailed(_, exitCode, _) {
            #expect(exitCode > 1)
        }
    }

    @Test func discardAllResetsIndexAndRemovesEveryUntrackedPath() async throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repository) }
        let stagedFile = repository.appendingPathComponent("staged.txt")
        let modifiedFile = repository.appendingPathComponent("modified.txt")
        try write("base staged", to: stagedFile)
        try write("base modified", to: modifiedFile)
        try write("ignored.txt\n", to: repository.appendingPathComponent(".gitignore"))
        _ = try runGit(["add", "."], at: repository)
        _ = try runGit(["commit", "--quiet", "-m", "base"], at: repository)

        try write("staged content", to: stagedFile)
        _ = try runGit(["add", "staged.txt"], at: repository)
        try write("unstaged content", to: stagedFile)
        try write("modified content", to: modifiedFile)
        try write("ignored", to: repository.appendingPathComponent("ignored.txt"))
        let nestedRepository = repository.appendingPathComponent("nested-repository", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedRepository, withIntermediateDirectories: true)
        _ = try runGit(["init", "--quiet"], at: nestedRepository)
        try write("nested", to: nestedRepository.appendingPathComponent("nested.txt"))
        for index in 0..<501 {
            try write("untracked", to: repository.appendingPathComponent("untracked-\(index).txt"))
        }

        try await GitService(workingDirectory: repository).discardAll()

        // Discard now means discard: the staged revision is gone too, and the
        // index is empty. It used to restore the worktree *from* the index, so
        // anything staged survived a "discard all".
        #expect(try String(contentsOf: stagedFile, encoding: .utf8) == "base staged")
        #expect(try runGit(["diff", "--cached", "--name-only"], at: repository) == "")
        #expect(try String(contentsOf: modifiedFile, encoding: .utf8) == "base modified")
        // clean has no -x, so ignored files are still left alone.
        #expect(FileManager.default.fileExists(atPath: repository.appendingPathComponent("ignored.txt").path))
        #expect(!FileManager.default.fileExists(atPath: nestedRepository.path))
        for index in 0..<501 {
            #expect(!FileManager.default.fileExists(atPath: repository.appendingPathComponent("untracked-\(index).txt").path))
        }
    }

    @Test func commitAndDiscardAllRejectUnresolvedConflictsWithoutChangingThem() async throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repository) }
        let conflictedFile = repository.appendingPathComponent("conflicted.txt")
        try write("base\n", to: conflictedFile)
        _ = try runGit(["add", "conflicted.txt"], at: repository)
        _ = try runGit(["commit", "--quiet", "-m", "base"], at: repository)
        _ = try runGit(["switch", "--quiet", "-c", "other"], at: repository)
        try write("other\n", to: conflictedFile)
        _ = try runGit(["commit", "--quiet", "-am", "other"], at: repository)
        _ = try runGit(["switch", "--quiet", "trunk"], at: repository)
        try write("trunk\n", to: conflictedFile)
        _ = try runGit(["commit", "--quiet", "-am", "trunk"], at: repository)

        do {
            _ = try runGit(["merge", "other"], at: repository)
            Issue.record("Expected merge conflict")
        } catch GitServiceError.commandFailed(_, let exitCode, _) {
            #expect(exitCode != 0)
        }
        let conflictContents = try String(contentsOf: conflictedFile, encoding: .utf8)
        let service = GitService(workingDirectory: repository)

        do {
            try await service.commit(message: "must not commit", autoStageWhenNeeded: true)
            Issue.record("Expected commit to reject unresolved conflicts")
        } catch let GitServiceError.unresolvedConflicts(operation) {
            #expect(operation == "committing")
        }
        #expect(try runGit(["diff", "--name-only", "--diff-filter=U"], at: repository) == "conflicted.txt\n")
        #expect(try String(contentsOf: conflictedFile, encoding: .utf8) == conflictContents)

        do {
            try await service.discardAll()
            Issue.record("Expected discard all to reject unresolved conflicts")
        } catch let GitServiceError.unresolvedConflicts(operation) {
            #expect(operation == "discarding all changes")
        }
        #expect(try runGit(["diff", "--name-only", "--diff-filter=U"], at: repository) == "conflicted.txt\n")
        #expect(try String(contentsOf: conflictedFile, encoding: .utf8) == conflictContents)
    }

    private func makeRepository() throws -> URL {
        let repository = FileManager.default.temporaryDirectory
            .appendingPathComponent("openowl-git-service-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        _ = try runGit(["init", "--quiet", "--initial-branch=trunk"], at: repository)
        _ = try runGit(["config", "user.name", "openOwl Tests"], at: repository)
        _ = try runGit(["config", "user.email", "tests@openowl.local"], at: repository)
        return repository
    }

    private func write(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    @discardableResult
    private func runGit(_ arguments: [String], at repository: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = repository
        let stdout = Pipe()
        process.standardOutput = stdout
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw GitServiceError.commandFailed(
                command: (["git"] + arguments).joined(separator: " "),
                exitCode: process.terminationStatus,
                stderr: ""
            )
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

@Suite("Git command gate")
struct GitCommandGateTests {
    @Test func serializesCommandsAndRemovesCompletedTail() async throws {
        let gate = GitCommandGate()
        let key = UUID().uuidString
        let firstRelease = GitGateTestLatch()
        let secondRelease = GitGateTestLatch()
        let events = GitGateEventRecorder()

        let first = Task {
            try await gate.withLock(key) {
                await events.append("first-start")
                await firstRelease.wait()
                await events.append("first-end")
            }
        }
        await waitUntil { await events.values == ["first-start"] }

        let second = Task {
            try await gate.withLock(key) {
                await events.append("second-start")
                await secondRelease.wait()
                await events.append("second-end")
            }
        }
        try await Task.sleep(for: .milliseconds(30))
        #expect(await events.values == ["first-start"])

        await firstRelease.open()
        try await first.value
        await waitUntil { await events.values == ["first-start", "first-end", "second-start"] }
        #expect(gate.pendingCount(for: key) == 1)

        await secondRelease.open()
        try await second.value
        #expect(await events.values == ["first-start", "first-end", "second-start", "second-end"])
        #expect(gate.pendingCount(for: key) == 0)
    }

    @Test func timedOutProcessDoesNotBlockSuccessor() async throws {
        let gate = GitCommandGate()
        let key = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openowl-git-timeout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let childPIDMarker = directory.appendingPathComponent("child.pid")
        defer {
            if let contents = try? String(contentsOf: childPIDMarker, encoding: .utf8),
               let childPID = Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines)),
               kill(childPID, SIGKILL) != 0,
               errno != ESRCH {
                Issue.record("Failed to terminate fixture child PID \(childPID), errno=\(errno)")
            }
            try? FileManager.default.removeItem(at: directory)
        }
        let script = directory.appendingPathComponent("orphan-pipe-writer.sh")
        try "#!/bin/sh\nsleep 5 &\necho $! > child.pid\nwait\n"
            .write(to: script, atomically: true, encoding: .utf8)
        let events = GitGateEventRecorder()

        let hanging = Task {
            try await gate.withLock(key) {
                await events.append("hanging-start")
                _ = try GitService.launchGit(
                    [script.path],
                    workingDirectory: directory,
                    timeout: 0.5,
                    executableURL: URL(fileURLWithPath: "/bin/sh")
                )
            }
        }
        await waitUntil { await events.values == ["hanging-start"] }

        let clock = ContinuousClock()
        let start = clock.now
        let successor = Task {
            try await gate.withLock(key) {
                await events.append("successor")
                return "continued"
            }
        }

        do {
            try await hanging.value
            Issue.record("Expected the process to time out")
        } catch let error as GitServiceError {
            guard case .commandTimedOut = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }

        #expect(try await successor.value == "continued")
        #expect(start.duration(to: clock.now) < .seconds(1))
        let childPID = try String(contentsOf: childPIDMarker, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(Int32(childPID) != nil)
        #expect(await events.values == ["hanging-start", "successor"])
        #expect(gate.pendingCount(for: key) == 0)
    }

    private func waitUntil(
        _ condition: @escaping @Sendable () async -> Bool
    ) async {
        for _ in 0..<100 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Condition was not met before timeout")
    }
}

private actor GitGateTestLatch {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private actor GitGateEventRecorder {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}
