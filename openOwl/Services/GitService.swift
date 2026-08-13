import Foundation

enum GitChangeSection: String, CaseIterable, Hashable {
    case staged = "Staged Changes"
    case modified = "Changes"
    case untracked = "Untracked"
}

struct GitFileChange: Identifiable, Hashable {
    let path: String
    let indexStatus: Character
    let workTreeStatus: Character
    let section: GitChangeSection

    var id: String {
        "\(section.rawValue)::\(path)::\(indexStatus)\(workTreeStatus)"
    }

    var statusCode: String {
        "\(indexStatus)\(workTreeStatus)"
    }
}

struct GitStatusSnapshot {
    let repositoryRoot: URL
    let branch: String
    let upstreamBranch: String?
    let branchTrackingStatus: String?
    let aheadCount: Int
    let behindCount: Int
    let staged: [GitFileChange]
    let modified: [GitFileChange]
    let untracked: [GitFileChange]
    let untrackedTruncated: Bool

    var hasStagedChanges: Bool { !staged.isEmpty }
    var hasAnyChanges: Bool { hasStagedChanges || !modified.isEmpty || !untracked.isEmpty }
}

struct GitLogEntry: Identifiable {
    let hash: String
    let abbreviatedHash: String
    let message: String
    let author: String
    let date: String        // ISO 8601 string
    let refs: String
    let parents: [String]

    var id: String { hash }
}

enum GitServiceError: LocalizedError {
    case notGitRepository
    case commandFailed(command: String, exitCode: Int32, stderr: String)
    case invalidCommitMessage
    case unresolvedConflicts(operation: String)

    var errorDescription: String? {
        switch self {
        case .notGitRepository:
            return "Selected directory is not a Git repository."
        case .commandFailed(let command, let exitCode, let stderr):
            let details = stderr.isEmpty ? "Unknown git error" : stderr
            return "`\(command)` failed (\(exitCode)): \(details)"
        case .invalidCommitMessage:
            return "Commit message cannot be empty."
        case .unresolvedConflicts(let operation):
            return "Resolve all merge conflicts before \(operation)."
        }
    }
}

enum WorktreeRemovalOutcome: Equatable {
    case removed
    case alreadyAbsent
    case unregisteredPath
}

/// Resolves the git binary once instead of relying on `/usr/bin/env git`.
/// GUI apps launched by launchd inherit a PATH that — on machines where
/// xcode-select points at Xcode — resolves `git` to Apple's (often old) git.
/// Pinning makes the binary deterministic and visible in the log.
///
/// Observed 2026-08-11: the app ran Apple git 2.50.1 (Xcode's) and a child
/// `git status` was SIGBUS'd mid-hash by a concurrently truncated file. The
/// version isn't the culprit (mmap semantics exist in every git), but the
/// binary choice should not be an accident of the environment.
enum GitExecutable {
    static let resolvedPath: String = {
        let candidates = [
            "/usr/bin/git",           // Apple git (CLT / active Xcode)
            "/opt/homebrew/bin/git",  // Apple Silicon homebrew
            "/usr/local/bin/git",     // Intel homebrew / manual installs
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return "git" // last resort: PATH lookup
    }()

    static func logChoice() {
        AppLogger.log("git", "using git binary: %@", resolvedPath)
    }
}

/// Serializes `git status` per working-directory key so two stores (e.g.
/// FileExplorer's status + the Git panel's refresh) never run `status`
/// concurrently on the same repo. Concurrent `git status` runs let a
/// truncating writer (build tools, agents writing .audit-cache, log rotation)
/// race git's mmap'd file hashing and SIGBUS the child — exactly what
/// happened 2026-08-11 (kernel: `cluster_pagein past EOF`).
private final class GitCommandGate: @unchecked Sendable {
    static let shared = GitCommandGate()

    private let lock = NSLock()
    private var tails: [String: Task<Void, Never>] = [:]

    func withLock<T: Sendable>(
        _ key: String,
        _ body: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            lock.lock()
            let previous = tails[key]
            let task = Task {
                if let previous {
                    _ = await previous.value
                }
                do {
                    continuation.resume(returning: try await body())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            tails[key] = task
            lock.unlock()
        }
    }
}

final class GitService {
    let workingDirectory: URL

    init(workingDirectory: URL) {
        self.workingDirectory = workingDirectory
    }

    /// Gate key: the standardized working directory. GitChangesStore and
    /// FileExplorer both pass the repository root, so their statuses
    /// serialize. Sibling instances using a subdirectory get their own lane
    /// (rev-parse/branch are cheap and don't hash worktree files).
    private static func gateKey(for directory: URL) -> String {
        directory.standardizedFileURL.path
    }

    func repositoryRoot() async throws -> URL {
        let root = try await runGit(["rev-parse", "--show-toplevel"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else {
            throw GitServiceError.notGitRepository
        }
        return URL(fileURLWithPath: root, isDirectory: true)
    }

    func status() async throws -> GitStatusSnapshot {
        // Serialized per-repo: FileExplorer's status and the Git panel's status
        // both call this on the repository root. Concurrent `git status` runs
        // let a truncating writer (build tools, agents writing .audit-cache,
        // log rotation) race git's mmap'd file hashing and SIGBUS the child
        // (observed 2026-08-11, kernel: `cluster_pagein past EOF`). diff/log
        // stay concurrent — they don't refresh the index and must not block
        // behind a slow peer.
        let key = Self.gateKey(for: workingDirectory)
        let output = try await GitCommandGate.shared.withLock(key) {
            try await self.runGit(
                ["status", "--porcelain=v1", "--branch", "--untracked-files=all"],
                retryOnSignalExit: true
            )
        }
        return try parseStatus(output)
    }

    func stage(files: [String]) async throws {
        guard !files.isEmpty else { return }
        _ = try await runGit(["add", "--"] + files)
    }

    func stageAll() async throws {
        _ = try await runGit(["add", "-A"])
    }

    func unstage(files: [String]) async throws {
        guard !files.isEmpty else { return }
        if try await hasHead() {
            _ = try await runGit(["restore", "--staged", "--"] + files)
        } else {
            _ = try await runGit(["rm", "--cached", "-r", "-f", "--"] + files)
        }
    }

    func unstageAll() async throws {
        if try await hasHead() {
            _ = try await runGit(["restore", "--staged", ":/"])
        } else {
            _ = try await runGit(["rm", "--cached", "-r", "-f", "--", ":/"])
        }
    }

    func discardModified(files: [String]) async throws {
        guard !files.isEmpty else { return }
        _ = try await runGit(["restore", "--worktree", "--"] + files)
    }

    func discardUntracked(paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        _ = try await runGit(["clean", "-f", "-d", "--"] + paths)
    }

    func discardAll() async throws {
        let unmergedPaths = try await runGit(["diff", "--name-only", "--diff-filter=U", "-z"])
        guard unmergedPaths.isEmpty else {
            throw GitServiceError.unresolvedConflicts(operation: "discarding all changes")
        }
        _ = try await runGit(["checkout-index", "--all", "--force"])
        _ = try await runGit(["clean", "-f", "-f", "-d"])
    }

    func commit(message: String, autoStageWhenNeeded: Bool) async throws {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw GitServiceError.invalidCommitMessage
        }

        let unmergedPaths = try await runGit(["diff", "--name-only", "--diff-filter=U", "-z"])
        guard unmergedPaths.isEmpty else {
            throw GitServiceError.unresolvedConflicts(operation: "committing")
        }

        if autoStageWhenNeeded {
            try await stageAll()
        }

        let fileURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("openowl-commit-\(UUID().uuidString).txt")

        try normalized.write(to: fileURL, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: fileURL)
        }

        _ = try await runGit(["commit", "--file", fileURL.path])
    }

    func diff(staged: Bool) async throws -> String {
        if staged {
            return try await runGit(["diff", "--staged"], retryOnSignalExit: true)
        } else {
            return try await runGit(["diff"], retryOnSignalExit: true)
        }
    }

    func diff(for change: GitFileChange) async throws -> String {
        switch change.section {
        case .staged:
            return try await runGit(["diff", "--staged", "--", change.path], retryOnSignalExit: true)

        case .modified:
            return try await runGit(["diff", "--", change.path], retryOnSignalExit: true)

        case .untracked:
            return try await runGit(
                ["diff", "--no-index", "--", "/dev/null", change.path],
                allowedExitCodes: [0, 1],
                retryOnSignalExit: true
            )
        }
    }

    func deleteBranch(name: String, force: Bool = false) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        _ = try await runGit(["branch", force ? "-D" : "-d", trimmed])
    }

    func fetch() async throws {
        _ = try await runGit(["fetch", "--all", "--prune"])
    }

    func pull() async throws {
        _ = try await runGit(["pull", "--rebase", "--autostash"])
    }

    func push() async throws {
        _ = try await runGit(["push"])
    }

    // MARK: - File Content at Commit

    /// Raw bytes of a file at a specific commit (for images, binary files).
    func fileData(at ref: String, path: String) async throws -> Data {
        let workingDirectory = self.workingDirectory
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: GitExecutable.resolvedPath)
                process.arguments = ["show", "\(ref):\(path)"]
                process.currentDirectoryURL = workingDirectory

                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr

                do {
                    try process.run()
                    // Read both pipes BEFORE waitUntilExit to avoid deadlock
                    // if pipe buffer (~64KB) fills.
                    let data = stdout.fileHandleForReading.readDataToEndOfFile()
                    let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()

                    if process.terminationStatus == 0 {
                        continuation.resume(returning: data)
                    } else {
                        continuation.resume(throwing: GitServiceError.commandFailed(
                            command: "git show \(ref):\(path)",
                            exitCode: process.terminationStatus,
                            stderr: String(data: stderrData, encoding: .utf8) ?? ""
                        ))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Commit Detail

    /// Files changed in a specific commit.
    func commitFiles(hash: String) async throws -> [GitFileChange] {
        let output = try await runGit(["diff-tree", "--root", "--no-commit-id", "-r", "--name-status", hash])
        return parseCommitFiles(output)
    }

    func parseCommitFiles(_ output: String) -> [GitFileChange] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "\t")
            guard parts.count >= 2 else { return nil }
            let status = parts[0].first ?? "M"
            // For renames (R100) and copies (C100), use the destination path (last field)
            let path = decodePath(String(parts.last!))
            return GitFileChange(path: path, indexStatus: status, workTreeStatus: " ", section: .staged)
        }
    }

    /// Full diff for a single commit.
    func showCommit(hash: String) async throws -> String {
        try await runGit(["show", "--format=", "--patch", hash])
    }

    // MARK: - Log

    func log(limit: Int = 50, skip: Int = 0) async throws -> [GitLogEntry] {
        let format = ["%H", "%h", "%s", "%aN", "%aI", "%D", "%P"].joined(separator: "%x00") + "%x00"
        let output = try await runGit([
            "log",
            "-z",
            "--format=\(format)",
            "-n", "\(limit)",
            "--skip=\(skip)",
            "--all"
        ], retryOnSignalExit: true)

        let fields = output.components(separatedBy: "\0")
        var entries: [GitLogEntry] = []
        var index = 0
        while index < fields.count {
            while index < fields.count, fields[index].isEmpty {
                index += 1
            }
            guard index + 6 < fields.count else { break }

            let parents = fields[index + 6].isEmpty
                ? []
                : fields[index + 6].split(separator: " ").map(String.init)
            entries.append(GitLogEntry(
                hash: fields[index],
                abbreviatedHash: fields[index + 1],
                message: fields[index + 2],
                author: fields[index + 3],
                date: fields[index + 4],
                refs: fields[index + 5],
                parents: parents
            ))
            index += 7
        }

        return entries
    }

    // MARK: - Worktree Management

    struct WorktreeInfo {
        let path: String
        let branch: String
        let head: String
    }

    /// Create a new git worktree. Returns the worktree filesystem path.
    func addWorktree(branch: String, dirName: String) async throws -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let projectName = workingDirectory.lastPathComponent
        let worktreeBase = "\(home)/.openowl/workspace/projects/\(projectName)"
        let strippedDir = dirName.components(separatedBy: "/").last ?? dirName
        let worktreePath = "\(worktreeBase)/\(strippedDir)"

        try FileManager.default.createDirectory(
            atPath: worktreeBase,
            withIntermediateDirectories: true
        )

        // Detect main branch (main or master)
        let mainBranch = await detectMainBranch()

        // Check if branch already exists
        let branchList = try await runGit(["branch", "--list", branch])
        let exists = !branchList.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if exists {
            _ = try await runGit(["worktree", "add", worktreePath, branch])
        } else {
            // Create new branch from main
            _ = try await runGit(["worktree", "add", "-b", branch, worktreePath, mainBranch])
        }

        return worktreePath
    }

    /// Detect whether the repo uses "main" or "master" as default branch.
    private func detectMainBranch() async -> String {
        // Check remote HEAD first
        if let symbolic = try? await runGit(["symbolic-ref", "refs/remotes/origin/HEAD"]),
           !symbolic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let ref = symbolic.trimmingCharacters(in: .whitespacesAndNewlines)
            // refs/remotes/origin/main → main
            return ref.components(separatedBy: "/").last ?? "main"
        }
        // Fallback: check if "main" branch exists
        let branches = (try? await runGit(["branch", "--list", "main"])) ?? ""
        if !branches.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "main"
        }
        return "master"
    }

    func listWorktrees() async throws -> [WorktreeInfo] {
        let raw = try await runGit(["worktree", "list", "--porcelain"])
        var worktrees: [WorktreeInfo] = []
        var currentPath: String?
        var currentBranch: String?
        var currentHead: String?

        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(line)
            if line.hasPrefix("worktree ") {
                currentPath = String(line.dropFirst(9))
            } else if line.hasPrefix("HEAD ") {
                currentHead = String(line.dropFirst(5))
            } else if line.hasPrefix("branch ") {
                currentBranch = String(line.dropFirst(7)).replacingOccurrences(of: "refs/heads/", with: "")
            } else if line.isEmpty {
                if let path = currentPath {
                    worktrees.append(WorktreeInfo(
                        path: path,
                        branch: currentBranch ?? "detached",
                        head: currentHead ?? ""
                    ))
                }
                currentPath = nil
                currentBranch = nil
                currentHead = nil
            }
        }
        return worktrees
    }

    func isRegisteredWorktree(path: String) async throws -> Bool {
        let targetPath = normalizedWorktreePath(path)
        return try await listWorktrees().contains {
            normalizedWorktreePath($0.path) == targetPath
        }
    }

    func removeWorktree(path: String) async throws -> WorktreeRemovalOutcome {
        guard try await isRegisteredWorktree(path: path) else {
            return FileManager.default.fileExists(atPath: path)
                ? .unregisteredPath
                : .alreadyAbsent
        }

        do {
            _ = try await runGit(["worktree", "remove", path, "--force"])
            return .removed
        } catch {
            // `git worktree remove` unregisters the worktree (deletes its
            // gitdir) *before* deleting the working directory. When the
            // directory removal then fails the folder is left behind already
            // orphaned. Failure modes on macOS: Finder dropping .DS_Store into
            // an emptied directory ("Directory not empty"), read-only files or
            // directories such as CocoaPods' Pods/ ("Permission denied"), and
            // huge untracked trees.
            //
            // First retry once after clearing Finder's .DS_Store litter. It is
            // dropped anywhere in the tree, not just at the root, and the
            // files are pure junk — removing them can never lose work.
            let worktreeURL = URL(fileURLWithPath: path)
            var clearedDSStores = false
            if let enumerator = FileManager.default.enumerator(
                at: worktreeURL,
                includingPropertiesForKeys: nil,
                options: []
            ) {
                for case let url as URL in enumerator where url.lastPathComponent == ".DS_Store" {
                    try? FileManager.default.removeItem(at: url)
                    clearedDSStores = true
                }
            }
            if clearedDSStores {
                AppLogger.log("worktree", "remove failed, retrying after clearing .DS_Store path=%@", path)
                do {
                    _ = try await runGit(["worktree", "remove", path, "--force"])
                    return .removed
                } catch {
                    // Fall through to the state check below.
                }
            }

            // If git still cannot delete the folder, decide by actual state
            // rather than by parsing git's stderr (which changes with version
            // and locale). If the worktree is still registered, git refused
            // before discarding anything — fail closed, the tree may hold work
            // worth recovering. If the registration is gone, git already
            // discarded the worktree state and the folder is orphaned junk;
            // report .unregisteredPath so the caller can offer to trash it.
            if try await isRegisteredWorktree(path: path) {
                throw error
            }
            let gitPointer = worktreeURL.appendingPathComponent(".git")
            if FileManager.default.fileExists(atPath: gitPointer.path) {
                try? FileManager.default.removeItem(at: gitPointer)
            }
            AppLogger.log("worktree", "remove left orphaned folder path=%@", path)
            return .unregisteredPath
        }
    }

    private func normalizedWorktreePath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    func renameBranch(from oldName: String, to newName: String) async throws {
        _ = try await runGit(["branch", "-m", oldName, newName])
    }

    static func hasUncommittedChanges(at path: URL) async throws -> Bool {
        let service = GitService(workingDirectory: path)
        let output = try await service.runGit(["status", "--porcelain"])
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Extract GitHub/GitLab username from remote origin URL.
    /// Supports: git@github.com:user/repo.git and https://github.com/user/repo.git
    func remoteUsername() async -> String? {
        guard let url = try? await runGit(["config", "--get", "remote.origin.url"])
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !url.isEmpty else { return nil }

        // SSH format: git@host:user/repo.git → extract "user"
        if let colonRange = url.range(of: ":"),
           url.contains("@"),
           !url.hasPrefix("http") {
            let afterColon = url[colonRange.upperBound...]
            if let slash = afterColon.firstIndex(of: "/") {
                let user = String(afterColon[afterColon.startIndex..<slash])
                if !user.isEmpty { return user }
            }
        }

        // HTTPS format: https://host/user/repo.git → extract "user"
        if url.hasPrefix("http"),
           let urlObj = URL(string: url) {
            let components = urlObj.pathComponents // ["/" , "user", "repo.git"]
            if components.count >= 2 {
                let user = components[1]
                if !user.isEmpty && user != "/" { return user }
            }
        }

        return nil
    }

    func ignoredPaths() async throws -> [String] {
        let output = try await runGit(["ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--directory"])
        return output
            .split(separator: "\0")
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

extension GitService {
    private func hasHead() async throws -> Bool {
        let output = try await runGit(
            ["rev-parse", "--verify", "--quiet", "HEAD"],
            allowedExitCodes: [0, 1]
        )
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func parseStatus(_ output: String) throws -> GitStatusSnapshot {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        var branch = "HEAD"
        var upstreamBranch: String?
        var branchStatus: String?
        var aheadCount = 0
        var behindCount = 0

        var staged: [GitFileChange] = []
        var modified: [GitFileChange] = []
        var untracked: [GitFileChange] = []
        var didTruncateUntracked = false

        for line in lines {
            if line.hasPrefix("## ") {
                let parsed = parseBranch(from: line)
                branch = parsed.branch
                upstreamBranch = parsed.upstreamBranch
                branchStatus = parsed.trackingSummary
                let counts = parseAheadBehind(from: parsed.trackingSummary)
                aheadCount = counts.ahead
                behindCount = counts.behind
                continue
            }

            if line.hasPrefix("?? ") {
                let rawPath = String(line.dropFirst(3))
                let path = decodePath(rawPath)
                if untracked.count >= 500 {
                    didTruncateUntracked = true
                    continue
                }
                untracked.append(
                    GitFileChange(path: path, indexStatus: "?", workTreeStatus: "?", section: .untracked)
                )
                continue
            }

            guard line.count >= 3 else { continue }

            let x = line[line.startIndex]
            let y = line[line.index(after: line.startIndex)]
            let rawPath = String(line.dropFirst(3))
            let path = decodePath(parsePath(rawPath))
            let isConflict = ["UU", "AA", "DD", "AU", "UA", "DU", "UD"].contains("\(x)\(y)")

            if x != " ", !isConflict {
                staged.append(
                    GitFileChange(path: path, indexStatus: x, workTreeStatus: y, section: .staged)
                )
            }

            if y != " " || isConflict {
                modified.append(
                    GitFileChange(path: path, indexStatus: x, workTreeStatus: y, section: .modified)
                )
            }
        }

        let root = workingDirectory.standardizedFileURL
        return GitStatusSnapshot(
            repositoryRoot: root,
            branch: branch,
            upstreamBranch: upstreamBranch,
            branchTrackingStatus: branchStatus,
            aheadCount: aheadCount,
            behindCount: behindCount,
            staged: staged.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending },
            modified: modified.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending },
            untracked: untracked.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending },
            untrackedTruncated: didTruncateUntracked
        )
    }

    func parseBranch(from line: String) -> (branch: String, upstreamBranch: String?, trackingSummary: String?) {
        let payload = line.replacingOccurrences(of: "## ", with: "")
        for prefix in ["No commits yet on ", "Initial commit on "] where payload.hasPrefix(prefix) {
            let branch = String(payload.dropFirst(prefix.count))
            return (branch: branch.isEmpty ? "HEAD" : branch, upstreamBranch: nil, trackingSummary: nil)
        }
        if let dotsRange = payload.range(of: "...") {
            let name = String(payload[..<dotsRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let trackingPayload = String(payload[dotsRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)

            if let bracketStart = trackingPayload.firstIndex(of: "["),
               let bracketEnd = trackingPayload.lastIndex(of: "]"),
               bracketStart < bracketEnd {
                let upstream = String(trackingPayload[..<bracketStart]).trimmingCharacters(in: .whitespacesAndNewlines)
                let summary = String(trackingPayload[trackingPayload.index(after: bracketStart)..<bracketEnd])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return (
                    branch: name.isEmpty ? "HEAD" : name,
                    upstreamBranch: upstream.isEmpty ? nil : upstream,
                    trackingSummary: summary.isEmpty ? nil : summary
                )
            }

            return (
                branch: name.isEmpty ? "HEAD" : name,
                upstreamBranch: trackingPayload.isEmpty ? nil : trackingPayload,
                trackingSummary: nil
            )
        }

        return (branch: payload.isEmpty ? "HEAD" : payload, upstreamBranch: nil, trackingSummary: nil)
    }

    func parseAheadBehind(from trackingSummary: String?) -> (ahead: Int, behind: Int) {
        guard let trackingSummary else { return (0, 0) }
        var ahead = 0
        var behind = 0

        let segments = trackingSummary.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }

        for segment in segments {
            if segment.hasPrefix("ahead ") {
                let number = segment.dropFirst("ahead ".count).trimmingCharacters(in: .whitespacesAndNewlines)
                ahead = Int(number) ?? 0
            } else if segment.hasPrefix("behind ") {
                let number = segment.dropFirst("behind ".count).trimmingCharacters(in: .whitespacesAndNewlines)
                behind = Int(number) ?? 0
            }
        }

        return (ahead, behind)
    }

    func parsePath(_ rawPath: String) -> String {
        var isQuoted = false
        var isEscaped = false
        var index = rawPath.startIndex

        while index < rawPath.endIndex {
            let character = rawPath[index]
            if isEscaped {
                isEscaped = false
            } else if character == "\\", isQuoted {
                isEscaped = true
            } else if character == "\"" {
                isQuoted.toggle()
            } else if !isQuoted, rawPath[index...].hasPrefix(" -> ") {
                let destinationStart = rawPath.index(index, offsetBy: 4)
                return String(rawPath[destinationStart...])
            }
            index = rawPath.index(after: index)
        }
        return rawPath
    }

    func decodePath(_ rawPath: String) -> String {
        Self.decodeGitPath(rawPath)
    }

    static func decodeGitPath(_ rawPath: String) -> String {
        guard rawPath.count >= 2, rawPath.first == "\"", rawPath.last == "\"" else {
            return rawPath
        }

        let body = rawPath.dropFirst().dropLast()
        var bytes: [UInt8] = []  // accumulate raw bytes for UTF-8 decode
        var iterator = body.makeIterator()

        // Flush accumulated octal bytes as UTF-8 string
        func flushBytes(_ output: inout String) {
            if !bytes.isEmpty {
                output += String(bytes: bytes, encoding: .utf8) ?? String(bytes.map { Character(Unicode.Scalar($0)) })
                bytes.removeAll()
            }
        }

        var output = ""

        while let char = iterator.next() {
            if char != "\\" {
                flushBytes(&output)
                output.append(char)
                continue
            }

            guard let escaped = iterator.next() else {
                flushBytes(&output)
                output.append("\\")
                break
            }

            switch escaped {
            case "\\": flushBytes(&output); output.append("\\")
            case "\"": flushBytes(&output); output.append("\"")
            case "n": flushBytes(&output); output.append("\n")
            case "t": flushBytes(&output); output.append("\t")
            case "r": flushBytes(&output); output.append("\r")
            case "0"..."7":
                // Octal escape: git encodes non-ASCII as \NNN byte sequences.
                // Accumulate bytes so consecutive octals decode as one UTF-8 string.
                var octal = String(escaped)
                var spillover: Character?
                for _ in 0..<2 {
                    guard let next = iterator.next() else { break }
                    if next >= "0" && next <= "7" {
                        octal.append(next)
                    } else {
                        spillover = next
                        break
                    }
                }
                if let byte = UInt8(octal, radix: 8) {
                    bytes.append(byte)
                } else {
                    // Invalid octal (>255): preserve original escape
                    flushBytes(&output)
                    output.append("\\")
                    output.append(contentsOf: octal)
                }
                if let s = spillover {
                    flushBytes(&output)
                    output.append(s)
                }
            default:
                flushBytes(&output)
                output.append(escaped)
            }
        }

        flushBytes(&output)
        return output
    }

    /// Serialized per-repo execution of a git command. `retryOnSignalExit`
    /// re-runs the command once if the child was killed by a signal — the
    /// signature of the mmap/truncation SIGBUS race (file shrank while git
    /// was hashing it) — which usually succeeds on the second attempt once
    /// the concurrent writer has moved on.
    ///
    /// Note: this is intentionally NOT gated per-repo. `status()` applies the
    /// gate itself; other read commands (diff/log) must stay concurrent so a
    /// blocking git call (e.g. reading a FIFO) can't stall the whole repo.
    func runGit(_ arguments: [String], allowedExitCodes: Set<Int32> = [0], retryOnSignalExit: Bool = false) async throws -> String {
        try await runGitSerialized(arguments, allowedExitCodes: allowedExitCodes, retryOnSignalExit: retryOnSignalExit)
    }

    private func runGitSerialized(_ arguments: [String], allowedExitCodes: Set<Int32>, retryOnSignalExit: Bool) async throws -> String {
        let workingDirectory = self.workingDirectory
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let maxAttempts = retryOnSignalExit ? 2 : 1
                var lastResult: (Data, Data, Int32, Process.TerminationReason)?

                for attempt in 1...maxAttempts {
                    do {
                        let (stdoutData, stderrData, status, reason) = try Self.launchGit(arguments, workingDirectory: workingDirectory)
                        lastResult = (stdoutData, stderrData, status, reason)

                        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

                        if allowedExitCodes.contains(status) {
                            continuation.resume(returning: stdout)
                            return
                        }

                        if reason == .uncaughtSignal, attempt < maxAttempts {
                            AppLogger.log(
                                "git",
                                "git %@ killed by signal while %@ (attempt %d/%d); retrying",
                                GitExecutable.resolvedPath,
                                arguments.joined(separator: " "),
                                attempt,
                                maxAttempts
                            )
                            // Give the concurrent writer a beat to finish.
                            Thread.sleep(forTimeInterval: 0.15)
                            continue
                        }

                        let command = (["git"] + arguments).joined(separator: " ")
                        if stderr.contains("not a git repository") {
                            continuation.resume(throwing: GitServiceError.notGitRepository)
                            return
                        }

                        continuation.resume(
                            throwing: GitServiceError.commandFailed(
                                command: command,
                                exitCode: status,
                                stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                            )
                        )
                        return
                    } catch {
                        continuation.resume(throwing: error)
                        return
                    }
                }

                // Unreachable: every iteration either returns or retries.
                continuation.resume(
                    throwing: GitServiceError.commandFailed(
                        command: (["git"] + arguments).joined(separator: " "),
                        exitCode: lastResult?.2 ?? 0,
                        stderr: ""
                    )
                )
            }
        }
    }

    /// Launches one git child and drains both pipes before waiting, so the
    /// 64KB pipe buffer can never fill and deadlock the child.
    private static func launchGit(
        _ arguments: [String],
        workingDirectory: URL
    ) throws -> (Data, Data, Int32, Process.TerminationReason) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: GitExecutable.resolvedPath)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // Read pipe data BEFORE waitUntilExit to avoid deadlock.
        // If the process fills the pipe buffer (~64KB), it blocks on write.
        // waitUntilExit would then wait forever for the blocked process.
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return (stdoutData, stderrData, process.terminationStatus, process.terminationReason)
    }
}
