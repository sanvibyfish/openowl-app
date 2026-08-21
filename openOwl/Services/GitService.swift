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
    case commandTimedOut(command: String, seconds: TimeInterval)
    case invalidCommitMessage
    case unresolvedConflicts(operation: String)
    case pipeReadFailed(command: String, code: Int32)
    case gitNotInstalled(searched: [String])

    var errorDescription: String? {
        switch self {
        case .notGitRepository:
            return "Selected directory is not a Git repository."
        case .commandFailed(let command, let exitCode, let stderr):
            let details = stderr.isEmpty ? "Unknown git error" : stderr
            return "`\(command)` failed (\(exitCode)): \(details)"
        case .commandTimedOut(let command, let seconds):
            return "`\(command)` timed out after \(seconds.formatted()) seconds."
        case .invalidCommitMessage:
            return "Commit message cannot be empty."
        case .unresolvedConflicts(let operation):
            return "Resolve all merge conflicts before \(operation)."
        case .gitNotInstalled(let searched):
            return "Could not find a git binary. Install the Xcode Command Line Tools "
                + "(`xcode-select --install`) or Homebrew git. Looked in: "
                + searched.joined(separator: ", ")
        case .pipeReadFailed(let command, let code):
            let detail = String(cString: strerror(code))
            return "`\(command)` output could not be read (\(detail)), so the result would have been "
                + "incomplete and was discarded. Retry; if it persists, check this repository for a "
                + "hung git hook or a filesystem that stopped responding."
        }
    }
}

enum WorktreeRemovalOutcome: Equatable {
    case removed
    case alreadyAbsent
    case unregisteredPath
}

/// Drains a child process pipe without blocking. Shared by every child this app
/// spawns — a `readDataToEndOfFile()` on a live process deadlocks as soon as the
/// other pipe's 64KB buffer fills.
final class GitPipeDrain: @unchecked Sendable {
    /// How long `finish()` waits after the child has already exited. A dead
    /// child's pipe reaches EOF immediately; if it does not, a grandchild
    /// (hook, credential helper, fsmonitor daemon) inherited the write end and
    /// is still alive. Waiting unbounded there wedges the caller forever — and
    /// for `status()` that means the repo's whole gate lane never drains again.
    static let drainGracePeriod: TimeInterval = 5

    private let lock = NSLock()
    private let closeLock = NSLock()
    private var isChannelClosed = false
    private let completion = DispatchSemaphore(value: 0)
    private let channel: DispatchIO
    private var collectedData = Data()
    private var completed = false
    private var readErrorCode: Int32 = 0
    /// Set when *we* cancelled the channel (timeout path). The resulting
    /// ECANCELED is self-inflicted and must not be reported as a read failure.
    private var stopRequested = false

    init(fileHandle: FileHandle) throws {
        let descriptor = dup(fileHandle.fileDescriptor)
        guard descriptor >= 0 else {
            // Capture errno once: strerror and the logging call are both
            // allowed to clobber it, so reading it three times could log one
            // error and throw a different (or garbage) one.
            let code = errno
            let failedFD = fileHandle.fileDescriptor
            AppLogger.log(
                "git",
                "pipe setup failed (dup fd %d): %@ (errno %d)",
                failedFD,
                String(cString: strerror(code)),
                code
            )
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        fileHandle.closeFile()

        // libdispatch does NOT close the file descriptor of an fd-based
        // channel; the cleanup handler is its last lifecycle point and the
        // reliable place to release it. Leaving this out leaks the dup'd
        // read descriptor (verified 2026-08-19: ~2 fds per git launch)
        // until the process exhausts RLIMIT_NOFILE and every git child
        // then fails to launch with EBADF — the Git panel outage.
        channel = DispatchIO(
            type: .stream,
            fileDescriptor: descriptor,
            queue: DispatchQueue.global(qos: .userInitiated)
        ) { _ in
            close(descriptor)
        }
        channel.setLimit(lowWater: 1)
        channel.read(
            offset: 0,
            length: Int.max,
            queue: DispatchQueue.global(qos: .userInitiated)
        ) { [weak self] done, data, error in
            guard let self else { return }
            lock.withLock {
                if let data, !data.isEmpty {
                    self.collectedData.append(contentsOf: data)
                }
                // A read error means `collectedData` is truncated. Recording it
                // is the whole point: the caller checks exit status only, so a
                // silently short `git status` reads as a clean, complete repo.
                if error != 0, self.readErrorCode == 0 {
                    self.readErrorCode = error
                }
                guard (done || error != 0), !self.completed else { return }
                self.completed = true
                self.completion.signal()
            }
        }
    }

    deinit {
        closeChannel(flags: .stop)
    }

    func stop() {
        lock.withLock { stopRequested = true }
        closeChannel(flags: .stop)
    }

    /// Returns the drained bytes, or throws if the read genuinely failed.
    /// Never returns a partial buffer as if it were the whole output.
    ///
    /// A stall is not a read failure. The child has already exited by the time
    /// this is called, so everything it wrote has been delivered; the pipe
    /// staying open means a *grandchild* inherited the write end and is still
    /// alive — `git fsmonitor--daemon` does this on every status in a repo with
    /// core.fsmonitor enabled. Throwing there would discard a complete, correct
    /// result and leave such repos permanently broken.
    func finish(command: String) throws -> Data {
        let drained = completion.wait(timeout: .now() + Self.drainGracePeriod) == .success
        closeChannel(flags: drained ? [] : .stop)
        let (data, errorCode, wasStopped) = lock.withLock {
            (collectedData, readErrorCode, stopRequested)
        }
        if !drained {
            AppLogger.log(
                "git",
                "output pipe still held after exit; using %d bytes already read: %@",
                data.count,
                command
            )
        }
        // ECANCELED after our own stop() is self-inflicted, not a read failure.
        if errorCode != 0, !wasStopped {
            throw GitServiceError.pipeReadFailed(command: command, code: errorCode)
        }
        return data
    }

    /// Idempotent close. finish() and the timeout path both close the
    /// channel, and deinit runs afterwards — guarding keeps the dup'd fd's
    /// lifetime explicit and eliminates any double-close window between the
    /// two callers. The dup'd descriptor itself is released by the channel's
    /// cleanup handler (see init), which runs exactly once inside close().
    private func closeChannel(flags: DispatchIO.CloseFlags) {
        closeLock.lock()
        defer { closeLock.unlock() }
        guard !isChannelClosed else { return }
        isChannelClosed = true
        channel.close(flags: flags)
    }
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
    static let candidates = [
        "/usr/bin/git",           // Apple git (CLT / active Xcode)
        "/opt/homebrew/bin/git",  // Apple Silicon homebrew
        "/usr/local/bin/git",     // Intel homebrew / manual installs
    ]

    /// nil when no git binary exists.
    ///
    /// There is deliberately no PATH fallback: `Process` resolves a relative
    /// executable against the app's cwd, not PATH, so returning "git" never
    /// worked — it only turned "git is not installed" into an opaque launch
    /// error. But the absence of git is a condition of the user's machine, not
    /// a programmer error, and openOwl is a terminal as much as a Git client:
    /// it must surface this as an error the Git panel can show, not trap the
    /// process and take every terminal session down with it.
    static let resolvedPath: String? = candidates.first {
        FileManager.default.isExecutableFile(atPath: $0)
    }

    static func logChoice() {
        guard let resolvedPath else {
            AppLogger.log("git", "no git binary found in: %@", candidates.joined(separator: ", "))
            return
        }
        AppLogger.log("git", "using git binary: %@", resolvedPath)
    }
}

/// Serializes `git status` per working-directory key so two stores (e.g.
/// FileExplorer's status + the Git panel's refresh) never run `status`
/// concurrently on the same repo. Concurrent `git status` runs let a
/// truncating writer (build tools, agents writing .audit-cache, log rotation)
/// race git's mmap'd file hashing and SIGBUS the child — exactly what
/// happened 2026-08-11 (kernel: `cluster_pagein past EOF`).
final class GitCommandGate: @unchecked Sendable {
    static let shared = GitCommandGate()

    private let lock = NSLock()
    private var tails: [String: (token: UUID, task: Task<Void, Never>)] = [:]

    func withLock<T: Sendable>(
        _ key: String,
        _ body: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            lock.lock()
            let previous = tails[key]?.task
            let token = UUID()
            let task = Task {
                if let previous {
                    _ = await previous.value
                }
                let result: Result<T, Error>
                do {
                    result = .success(try await body())
                } catch {
                    result = .failure(error)
                }
                self.removeTail(for: key, token: token)
                continuation.resume(with: result)
            }
            tails[key] = (token, task)
            lock.unlock()
        }
    }

    func pendingCount(for key: String) -> Int {
        lock.withLock { tails[key] == nil ? 0 : 1 }
    }

    private func removeTail(for key: String, token: UUID) {
        lock.withLock {
            guard tails[key]?.token == token else { return }
            tails.removeValue(forKey: key)
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
                retryOnSignalExit: true,
                timeout: 30
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

    /// Discards everything: staged content, worktree edits and untracked files.
    ///
    /// This used to run `checkout-index --all --force`, which restores the
    /// worktree *from the index* — so anything already staged survived, and the
    /// UI's "Discard all tracked and untracked changes" was a lie whenever the
    /// index was dirty (the common case, since commit() auto-stages).
    /// `clean -f -f -d` still removes untracked nested Git repositories; that
    /// part is deliberate.
    func discardAll() async throws {
        let unmergedPaths = try await runGit(["diff", "--name-only", "--diff-filter=U", "-z"])
        guard unmergedPaths.isEmpty else {
            throw GitServiceError.unresolvedConflicts(operation: "discarding all changes")
        }
        if try await hasHead() {
            _ = try await runGit(["reset", "--hard", "HEAD"])
        } else {
            // HEAD does not resolve — but that has two causes, and only one of
            // them is safe here. A genuinely unborn branch (fresh `git init`)
            // has no commits anywhere, so emptying the index and letting clean
            // take the files is exactly "discard everything". A *broken* HEAD
            // (a ref that went missing after an interrupted checkout, a
            // truncated .git/refs write, packed-refs disagreeing with a loose
            // ref) looks identical to `rev-parse --verify HEAD` while the index
            // still holds the entire tracked tree — clearing it there would
            // hand `clean -f -f -d` every tracked file in the repository.
            let commitCount = try await runGit(["rev-list", "--all", "--count"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard commitCount == "0" else {
                throw GitServiceError.commandFailed(
                    command: "git reset --hard HEAD",
                    exitCode: 1,
                    stderr: "HEAD does not resolve to a commit, but this repository has commits. "
                        + "Refusing to discard, because the working tree may be recoverable. "
                        + "Repair HEAD first, e.g. `git symbolic-ref HEAD refs/heads/<branch>`."
                )
            }
            // `--ignore-unmatch` makes an already-empty index exit 0, so this
            // needs no exit-code allowance that could also mask a real fatal
            // (index.lock held, corrupt index, permission denied).
            _ = try await runGit(["rm", "-r", "--cached", "-q", "-f", "--ignore-unmatch", "--", ":/"])
        }
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
        let arguments = ["show", "\(ref):\(path)"]
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let (data, stderrData, status, _) = try Self.launchGit(
                        arguments,
                        workingDirectory: workingDirectory,
                        timeout: 30
                    )
                    guard status == 0 else {
                        continuation.resume(throwing: GitServiceError.commandFailed(
                            command: (["git"] + arguments).joined(separator: " "),
                            exitCode: status,
                            stderr: String(data: stderrData, encoding: .utf8) ?? ""
                        ))
                        return
                    }
                    continuation.resume(returning: data)
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

        let mainBranch = try await detectMainBranch()

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

    /// The repository's default branch, used as the base for new worktrees.
    ///
    /// Throws rather than guessing. The previous version fell through to a
    /// hardcoded "master": on a repo whose default is `develop`/`trunk` that
    /// produced "invalid reference: master", and on a repo with a stale local
    /// `master` it silently branched from the wrong baseline.
    private func detectMainBranch() async throws -> String {
        let symbolic = try await runGit(
            ["symbolic-ref", "refs/remotes/origin/HEAD"],
            allowedExitCodes: [0, 1, 128]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        if let name = symbolic.components(separatedBy: "/").last, !name.isEmpty {
            return name
        }

        // No remote HEAD to consult. Fall back to the branch that is currently
        // checked out — not to a guess. A local branch named `main` existing
        // does not make it the default (that guess is how the old hardcoded
        // "master" branched worktrees off the wrong baseline), but "the branch
        // the user is on right now" is a fact, and it is the baseline they
        // would expect a new worktree to start from.
        let current = try await runGit(
            ["symbolic-ref", "--short", "--quiet", "HEAD"],
            allowedExitCodes: [0, 1]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.isEmpty {
            return current
        }

        // Detached HEAD and no remote: there is no branch to base anything on.
        throw GitServiceError.commandFailed(
            command: "git symbolic-ref refs/remotes/origin/HEAD",
            exitCode: 1,
            stderr: "Could not determine a branch to base the worktree on: this repository has no "
                + "remote HEAD and is not on a branch. Check out a branch first, or set the remote "
                + "default with `git remote set-head origin -a`."
        )
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
        } catch let error as GitServiceError {
            // Only a command failure means "git ran and refused". A timeout, a
            // stalled pipe or notGitRepository must not be funnelled into the
            // orphan-recovery flow below — that would report a healthy worktree
            // as orphaned junk.
            guard case .commandFailed = error else { throw error }
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
                } catch let retryError {
                    AppLogger.log(
                        "worktree",
                        "remove retry failed path=%@ error=%@",
                        path,
                        retryError.localizedDescription
                    )
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
                do {
                    try FileManager.default.removeItem(at: gitPointer)
                } catch let pointerError {
                    AppLogger.log(
                        "worktree",
                        "could not remove stale .git pointer path=%@ error=%@",
                        gitPointer.path,
                        pointerError.localizedDescription
                    )
                }
            }
            // Carry the reason: it is the only thing that tells the user whether
            // this needs a permission change, a full disk cleared, or nothing.
            AppLogger.log(
                "worktree",
                "remove left orphaned folder path=%@ reason=%@",
                path,
                error.localizedDescription
            )
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
        // Routed through status() so it inherits the per-repo gate, the signal
        // retry and the timeout. Running a bare `git status` here reopened the
        // very SIGBUS window those three were added to close.
        let service = GitService(workingDirectory: path)
        let snapshot = try await service.status()
        return snapshot.hasAnyChanges
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
    func runGit(
        _ arguments: [String],
        allowedExitCodes: Set<Int32> = [0],
        retryOnSignalExit: Bool = false,
        timeout: TimeInterval? = nil
    ) async throws -> String {
        try await runGitSerialized(
            arguments,
            allowedExitCodes: allowedExitCodes,
            retryOnSignalExit: retryOnSignalExit,
            timeout: timeout
        )
    }

    private func runGitSerialized(
        _ arguments: [String],
        allowedExitCodes: Set<Int32>,
        retryOnSignalExit: Bool,
        timeout: TimeInterval?
    ) async throws -> String {
        let workingDirectory = self.workingDirectory
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let maxAttempts = retryOnSignalExit ? 2 : 1

                for attempt in 1...maxAttempts {
                    do {
                        let (stdoutData, stderrData, status, reason) = try Self.launchGit(
                            arguments,
                            workingDirectory: workingDirectory,
                            timeout: timeout
                        )

                        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

                        if reason == .uncaughtSignal, attempt < maxAttempts {
                            AppLogger.log(
                                "git",
                                "killed by signal: git %@ (attempt %d/%d); retrying",
                                arguments.joined(separator: " "),
                                attempt,
                                maxAttempts
                            )
                            // Give the concurrent writer a beat to finish.
                            Thread.sleep(forTimeInterval: 0.15)
                            continue
                        }

                        if reason == .exit, allowedExitCodes.contains(status) {
                            // git reports partial failure as "exit 0 + stderr
                            // warning" (a directory it could not read, a file it
                            // could not remove). Logging it is only half the
                            // fix — the UI still reports "Staged all files."
                            // because runGit returns stdout alone. Surfacing it
                            // needs a result type; TODO tracked in REQ-002.
                            let trimmedStderr = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmedStderr.isEmpty {
                                AppLogger.log(
                                    "git",
                                    "git %@ exited %d with stderr: %@",
                                    arguments.joined(separator: " "),
                                    status,
                                    trimmedStderr
                                )
                            }
                            continuation.resume(returning: stdout)
                            return
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
                        AppLogger.log(
                            "git",
                            "git %@ failed: %@",
                            arguments.joined(separator: " "),
                            error.localizedDescription
                        )
                        continuation.resume(throwing: error)
                        return
                    }
                }
            }
        }
    }

    /// How long a timed-out child gets to handle SIGTERM before it is killed.
    /// Long enough for git to drop its lockfiles, short enough that a wedged
    /// child cannot hold the calling thread.
    static let terminateGracePeriod: TimeInterval = 2

    /// Launches one git child and drains both pipes before waiting, so the
    /// 64KB pipe buffer can never fill and deadlock the child.
    static func launchGit(
        _ arguments: [String],
        workingDirectory: URL,
        timeout: TimeInterval? = nil,
        executableURL: URL? = nil
    ) throws -> (Data, Data, Int32, Process.TerminationReason) {
        guard let executableURL = try executableURL ?? {
            guard let path = GitExecutable.resolvedPath else {
                throw GitServiceError.gitNotInstalled(searched: GitExecutable.candidates)
            }
            return URL(fileURLWithPath: path)
        }() else {
            throw GitServiceError.gitNotInstalled(searched: GitExecutable.candidates)
        }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutDrain = try GitPipeDrain(fileHandle: stdoutPipe.fileHandleForReading)
        let stderrDrain = try GitPipeDrain(fileHandle: stderrPipe.fileHandleForReading)

        try process.run()

        let command = ([executableURL.lastPathComponent] + arguments).joined(separator: " ")
        let timeoutLock = NSLock()
        var didTimeOut = false
        let timeoutWorkItem = timeout.map { duration in
            let item = DispatchWorkItem {
                timeoutLock.withLock {
                    guard process.isRunning else { return }
                    didTimeOut = true
                    AppLogger.log("git", "hung for %.1fs; terminating: %@", duration, command)
                    // SIGTERM first, so git can release .git/index.lock —
                    // SIGKILL'ing a status mid index-refresh leaves a stale
                    // lock that wedges every later git command in the repo.
                    process.terminate()
                    stdoutDrain.stop()
                    stderrDrain.stop()
                }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + duration, execute: item)
            // Bounded escalation. `waitUntilExit()` below is unbounded, and it
            // runs *before* the drain deadline — so a child that ignores or
            // blocks SIGTERM would hang this thread forever, and for status()
            // that wedges the repo's whole gate lane. Termination has to be
            // guaranteed, not requested.
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + duration + Self.terminateGracePeriod
            ) {
                timeoutLock.withLock {
                    guard process.isRunning else { return }
                    AppLogger.log("git", "ignored SIGTERM; killing: %@", command)
                    kill(process.processIdentifier, SIGKILL)
                }
            }
            return item
        }

        process.waitUntilExit()
        // Cancel here, while the process is known dead: the work item's only job
        // is signalling a live child, and holding it open past this point widens
        // the window where its pid could already have been recycled.
        timeoutWorkItem?.cancel()

        let stdoutData = try stdoutDrain.finish(command: command)
        let stderrData = try stderrDrain.finish(command: command)

        // A timeout only wins when the child failed to deliver. The work item
        // can fire in the same instant the child exits normally — it checks
        // `isRunning`, which is still true while the child is on its way out —
        // and reporting a timeout then would throw away a complete, successful
        // result. A child we actually terminated exits via .uncaughtSignal.
        if timeoutLock.withLock({ didTimeOut }), process.terminationReason != .exit {
            throw GitServiceError.commandTimedOut(command: command, seconds: timeout ?? 0)
        }

        return (stdoutData, stderrData, process.terminationStatus, process.terminationReason)
    }
}
