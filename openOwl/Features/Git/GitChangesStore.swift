import Foundation
import Observation

@MainActor
@Observable
final class GitChangesStore {
    private(set) var repositoryURL: URL?
    private(set) var statusSnapshot: GitStatusSnapshot?
    var selectedChange: GitFileChange?
    private(set) var selectedDiffText: String = ""

    var commitMessage: String = "" {
        didSet {
            if let repositoryURL {
                commitDrafts[repositoryURL] = commitMessage
            }
        }
    }

    private(set) var isRefreshing = false
    private var refreshRequestedWhileRefreshing = false
    private(set) var isRunningCommand = false
    private(set) var errorMessage: String?
    var infoMessage: String?

    // Git Graph
    private(set) var logEntries: [GitLogEntry] = []
    var selectedCommitHash: String?
    private(set) var hasMoreLog = true
    private(set) var commitFiles: [GitFileChange] = []
    private(set) var commitDiffText: String = ""
    private(set) var isLoadingCommitDetail = false
    private(set) var commitDetailErrorMessage: String?
    private let logPageSize = 50

    private(set) var isGeneratingMessage = false

    private var gitService: GitService?
    private var watcher: FileWatcher?
    private let commitMessageGenerator = CommitMessageGenerator()
    private var generateTask: Task<Void, Never>?
    private var generateRequestID: UUID?
    private var commandTask: Task<Void, Never>?
    private var commandRequestID: UUID?
    private var commitDetailTask: Task<Void, Never>?
    private var openDiffTask: Task<Void, Never>?
    private var loadingMoreLogService: GitService?
    private var logGeneration = 0

    private var preferredDirectory: URL
    private var openingDirectory: URL?
    private var repositoryOpenRequestID: UUID?
    private var repositoryContextGeneration = 0
    private var diffRequestRevision = 0
    private var commitDrafts: [URL: String] = [:]
    private var errorRevision = 0
    private var commitDetailErrorRevision: Int?

    init(initialDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)) {
        self.preferredDirectory = initialDirectory.standardizedFileURL
    }

    func setPreferredDirectory(_ directoryURL: URL) {
        let standardized = directoryURL.standardizedFileURL
        preferredDirectory = standardized
        if openingDirectory != standardized {
            openDiffTask?.cancel()
            openDiffTask = nil
        }
        openPreferredDirectory(standardized)
    }

    private func openPreferredDirectory(_ directoryURL: URL) {
        guard openingDirectory != directoryURL else { return }
        openingDirectory = directoryURL

        Task {
            await openRepository(at: directoryURL)
            if openingDirectory == directoryURL {
                openingDirectory = nil
            }
        }
    }

    func openRepository(at candidateURL: URL) async {
        guard !Task.isCancelled else { return }
        let directoryURL = candidateURL.hasDirectoryPath ? candidateURL : candidateURL.deletingLastPathComponent()
        if repositoryURL == directoryURL.standardizedFileURL, gitService != nil {
            repositoryOpenRequestID = UUID()
            return
        }

        let requestID = UUID()
        repositoryOpenRequestID = requestID
        repositoryContextGeneration &+= 1
        invalidateRepositoryTasks()
        diffRequestRevision &+= 1
        let probeService = GitService(workingDirectory: directoryURL)

        do {
            let resolvedRoot = try await probeService.repositoryRoot()
            guard !Task.isCancelled, repositoryOpenRequestID == requestID else { return }
            let root = resolvedRoot.standardizedFileURL
            preferredDirectory = root
            if repositoryURL == root, gitService != nil { return }
            gitService = GitService(workingDirectory: root)
            loadingMoreLogService = nil
            logGeneration &+= 1
            repositoryURL = root
            commitMessage = commitDrafts[root] ?? ""
            statusSnapshot = nil
            logEntries = []
            hasMoreLog = true
            selectedChange = nil
            selectedDiffText = ""
            selectedCommitHash = nil
            commitFiles = []
            commitDiffText = ""
            isLoadingCommitDetail = false
            commitDetailErrorMessage = nil
            commitDetailErrorRevision = nil
            commitDetailTask?.cancel()
            commitDetailTask = nil
            clearError()
            infoMessage = nil

            configureWatcher(for: root)
            await refresh()
        } catch {
            guard !Task.isCancelled, repositoryOpenRequestID == requestID else { return }
            gitService = nil
            loadingMoreLogService = nil
            logGeneration &+= 1
            repositoryURL = nil
            commitMessage = ""
            statusSnapshot = nil
            logEntries = []
            hasMoreLog = false
            selectedChange = nil
            selectedDiffText = ""
            selectedCommitHash = nil
            commitFiles = []
            commitDiffText = ""
            isLoadingCommitDetail = false
            commitDetailErrorMessage = nil
            commitDetailErrorRevision = nil
            commitDetailTask?.cancel()
            commitDetailTask = nil
            watcher?.stop()
            watcher = nil
            setError(error)
        }
    }

    func refresh() async {
        guard !isRefreshing else {
            refreshRequestedWhileRefreshing = true
            return
        }
        guard let gitService else { return }

        isRefreshing = true
        defer {
            isRefreshing = false
            if refreshRequestedWhileRefreshing {
                refreshRequestedWhileRefreshing = false
                refreshNow()
            }
        }

        let capturedErrorRevision = errorRevision
        do {
            let snapshot = try await gitService.status()
            guard self.gitService === gitService else { return }
            statusSnapshot = snapshot
            clearError(ifRevision: capturedErrorRevision)

            await ensureSelectedDiffIsFresh(using: gitService)
            await loadLog(using: gitService, reset: true)
        } catch {
            guard self.gitService === gitService else { return }
            setError(error)
        }
    }

    func refreshNow() {
        Task {
            await refresh()
        }
    }

    // MARK: - Git Graph

    func loadMoreLog() {
        guard let gitService, hasMoreLog, !isRefreshing, loadingMoreLogService == nil else { return }
        loadingMoreLogService = gitService
        Task {
            defer {
                if loadingMoreLogService === gitService {
                    loadingMoreLogService = nil
                }
            }
            await loadLog(using: gitService, reset: false)
        }
    }

    func selectCommit(_ hash: String) {
        diffRequestRevision &+= 1
        commitDetailTask?.cancel()
        commitDetailTask = nil
        isLoadingCommitDetail = false
        if let detailErrorRevision = commitDetailErrorRevision,
           errorRevision == detailErrorRevision {
            clearError(ifRevision: detailErrorRevision)
        }
        commitDetailErrorRevision = nil
        commitDetailErrorMessage = nil
        selectedChange = nil
        selectedDiffText = ""

        if selectedCommitHash == hash {
            selectedCommitHash = nil
            commitFiles = []
            commitDiffText = ""
            return
        }
        selectedCommitHash = hash
        commitFiles = []
        commitDiffText = ""

        guard let gitService else { return }
        let capturedHash = hash
        let capturedErrorRevision = errorRevision
        isLoadingCommitDetail = true
        commitDetailTask = Task {
            defer {
                if selectedCommitHash == capturedHash {
                    isLoadingCommitDetail = false
                }
            }
            do {
                async let files = gitService.commitFiles(hash: capturedHash)
                async let diff = gitService.showCommit(hash: capturedHash)
                let f = try await files
                let d = try await diff
                guard !Task.isCancelled, self.gitService === gitService,
                      selectedCommitHash == capturedHash else { return }
                commitFiles = f
                commitDiffText = d
                clearError(ifRevision: capturedErrorRevision)
            } catch {
                guard !Task.isCancelled, self.gitService === gitService,
                      selectedCommitHash == capturedHash else { return }
                commitFiles = []
                commitDiffText = ""
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                commitDetailErrorMessage = message
                commitDetailErrorRevision = setError(message)
            }
        }
    }

    private func loadLog(using gitService: GitService, reset: Bool) async {
        if reset {
            logGeneration &+= 1
        }
        let capturedGeneration = logGeneration
        let skip = reset ? 0 : logEntries.count
        do {
            let entries = try await gitService.log(limit: logPageSize, skip: skip)
            guard self.gitService === gitService, logGeneration == capturedGeneration else { return }
            if reset {
                logEntries = entries
            } else {
                logEntries.append(contentsOf: entries)
            }
            hasMoreLog = entries.count >= logPageSize
        } catch {
            guard self.gitService === gitService, logGeneration == capturedGeneration else { return }
            if reset { logEntries = [] }
            hasMoreLog = false
            setError(error)
        }
    }

    func selectChange(_ change: GitFileChange) {
        diffRequestRevision &+= 1
        let requestRevision = diffRequestRevision
        // Cancel any in-flight commit detail loading
        commitDetailTask?.cancel()
        commitDetailTask = nil
        isLoadingCommitDetail = false
        if let detailErrorRevision = commitDetailErrorRevision,
           errorRevision == detailErrorRevision {
            clearError(ifRevision: detailErrorRevision)
        }
        commitDetailErrorRevision = nil
        commitDetailErrorMessage = nil

        // Clear commit selection so diff panel shows working tree diff
        selectedCommitHash = nil
        commitFiles = []
        commitDiffText = ""

        selectedChange = change
        selectedDiffText = ""

        Task {
            await loadDiff(for: change, requestRevision: requestRevision)
        }
    }

    func clearInfoMessage() {
        infoMessage = nil
    }

    func clearErrorMessage() {
        clearError()
    }

    func stage(_ change: GitFileChange) {
        stage(paths: [change.path])
    }

    func unstage(_ change: GitFileChange) {
        unstage(paths: [change.path])
    }

    func discard(_ change: GitFileChange) {
        discard(changes: [change])
    }

    func discard(_ changes: [GitFileChange]) {
        discard(changes: changes)
    }

    func stageAll() {
        runCommand(
            operation: { try await $0.stageAll() },
            success: { self.infoMessage = "Staged all files." }
        )
    }

    func unstageAll() {
        runCommand(
            operation: { try await $0.unstageAll() },
            success: { self.infoMessage = "Unstaged all files." }
        )
    }

    func generateCommitMessage() {
        guard let gitService else { NSLog("generateCommitMessage: no gitService"); return }
        guard !isGeneratingMessage else { NSLog("generateCommitMessage: already generating"); return }
        NSLog("generateCommitMessage: starting")
        let requestID = UUID()
        let contextGeneration = repositoryContextGeneration
        generateRequestID = requestID
        isGeneratingMessage = true

        generateTask = Task {
            defer {
                if generateRequestID == requestID, repositoryContextGeneration == contextGeneration,
                   self.gitService === gitService {
                    generateRequestID = nil
                    generateTask = nil
                    isGeneratingMessage = false
                }
            }
            do {
                let diff = try await gitService.diff(staged: true)
                try Task.checkCancellation()
                guard generateRequestID == requestID, repositoryContextGeneration == contextGeneration,
                      self.gitService === gitService else { return }
                guard !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    let allDiff = try await gitService.diff(staged: false)
                    try Task.checkCancellation()
                    guard generateRequestID == requestID, repositoryContextGeneration == contextGeneration,
                          self.gitService === gitService else { return }
                    guard !allDiff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        setError("No changes to generate message for.")
                        return
                    }
                    let message = try await commitMessageGenerator.generate(diff: allDiff)
                    try Task.checkCancellation()
                    guard generateRequestID == requestID, repositoryContextGeneration == contextGeneration,
                          self.gitService === gitService else { return }
                    if !message.isEmpty { commitMessage = message }
                    return
                }
                let message = try await commitMessageGenerator.generate(diff: diff)
                try Task.checkCancellation()
                guard generateRequestID == requestID, repositoryContextGeneration == contextGeneration,
                      self.gitService === gitService else { return }
                if !message.isEmpty { commitMessage = message }
            } catch is CancellationError {
                // cancelled by user
            } catch {
                guard generateRequestID == requestID, repositoryContextGeneration == contextGeneration,
                      self.gitService === gitService else { return }
                setError(error)
            }
        }
    }

    func cancelGenerateCommitMessage() {
        generateRequestID = nil
        generateTask?.cancel()
        generateTask = nil
        commitMessageGenerator.cancel()
        isGeneratingMessage = false
    }

    func commit() {
        let autoStage = !(statusSnapshot?.hasStagedChanges ?? false)
        let message = commitMessage

        runCommand(
            operation: { try await $0.commit(message: message, autoStageWhenNeeded: autoStage) },
            success: {
                self.commitMessage = ""
                self.infoMessage = autoStage ? "Committed (auto-staged all changes)." : "Committed."
            }
        )
    }

    func deleteBranch(name: String, force: Bool = false) {
        let targetBranch = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetBranch.isEmpty else { return }

        runCommand(
            operation: { try await $0.deleteBranch(name: targetBranch, force: force) },
            success: { self.infoMessage = force ? "Force deleted branch: \(targetBranch)" : "Deleted branch: \(targetBranch)" }
        )
    }

    func fetch() {
        runCommand(operation: { try await $0.fetch() }, success: { self.infoMessage = "Fetch completed." })
    }

    func pull() {
        runCommand(operation: { try await $0.pull() }, success: { self.infoMessage = "Pull completed." })
    }

    func push() {
        runCommand(operation: { try await $0.push() }, success: { self.infoMessage = "Push completed." })
    }

    func openDiff(forFileURL fileURL: URL, repositoryCandidateURL: URL) {
        let standardized = fileURL.standardizedFileURL
        let candidate = repositoryCandidateURL.standardizedFileURL
        openDiffTask?.cancel()
        openingDirectory = candidate

        openDiffTask = Task {
            defer {
                if openingDirectory == candidate {
                    openingDirectory = nil
                }
            }
            await openRepository(at: candidate)
            guard !Task.isCancelled else { return }

            guard statusSnapshot != nil else { return }
            if let change = changeForFileURL(standardized) {
                selectChange(change)
                return
            }

            await refresh()
            if let change = changeForFileURL(standardized) {
                selectChange(change)
                return
            }

            infoMessage = "No git diff for selected file."
        }
    }

    func stage(paths: [String]) {
        guard !paths.isEmpty else { return }

        runCommand(operation: { try await $0.stage(files: paths) }, success: { self.infoMessage = "Staged \(paths.count) file(s)." })
    }

    func discardByPath(_ relativePath: String) {
        guard !relativePath.isEmpty else { return }

        // Find the change to determine if it's modified or untracked
        let allChanges = (statusSnapshot?.modified ?? []) + (statusSnapshot?.untracked ?? [])
        guard let change = allChanges.first(where: { $0.path == relativePath }) else { return }

        runCommand(operation: { gitService in
            if change.section == .untracked {
                try await gitService.discardUntracked(paths: [relativePath])
            } else {
                try await gitService.discardModified(files: [relativePath])
            }
        }, success: { self.infoMessage = "Discarded changes for \(relativePath)." })
    }

    func unstage(paths: [String]) {
        guard !paths.isEmpty else { return }

        runCommand(operation: { try await $0.unstage(files: paths) }, success: { self.infoMessage = "Unstaged \(paths.count) file(s)." })
    }

    func discardAll() {
        runCommand(
            operation: { try await $0.discardAll() },
            success: { self.infoMessage = "Discarded all changes." }
        )
    }

    private func discard(changes: [GitFileChange]) {
        guard !changes.isEmpty else { return }

        let modifiedPaths = Array(
            Set(changes.filter { $0.section == .modified }.map(\.path))
        ).sorted()
        let untrackedPaths = Array(
            Set(changes.filter { $0.section == .untracked }.map(\.path))
        ).sorted()

        guard !modifiedPaths.isEmpty || !untrackedPaths.isEmpty else { return }

        runCommand(operation: { gitService in
            if !modifiedPaths.isEmpty {
                try await gitService.discardModified(files: modifiedPaths)
            }
            if !untrackedPaths.isEmpty {
                try await gitService.discardUntracked(paths: untrackedPaths)
            }

        }, success: {
            let total = modifiedPaths.count + untrackedPaths.count
            self.infoMessage = "Discarded \(total) change(s)."
        })
    }

    private func runCommand(
        operation: @escaping (GitService) async throws -> Void,
        success: @escaping () -> Void
    ) {
        guard !isRunningCommand else { return }
        guard let gitService else { return }
        let requestID = UUID()
        let contextGeneration = repositoryContextGeneration
        commandRequestID = requestID
        isRunningCommand = true

        commandTask = Task {
            defer {
                if commandRequestID == requestID {
                    commandRequestID = nil
                    commandTask = nil
                    isRunningCommand = false
                }
            }
            do {
                try await operation(gitService)
                guard !Task.isCancelled, commandRequestID == requestID,
                      repositoryContextGeneration == contextGeneration,
                      self.gitService === gitService else { return }
                success()
                await refresh()
            } catch {
                guard !Task.isCancelled, commandRequestID == requestID,
                      repositoryContextGeneration == contextGeneration,
                      self.gitService === gitService else { return }
                setError(error)
            }
        }
    }

    private func configureWatcher(for repositoryURL: URL) {
        watcher?.stop()
        watcher = FileWatcher(directoryURL: repositoryURL) { [weak self] in
            self?.refreshNow()
        }
        if watcher == nil {
            NSLog("openOwl: [GitChanges] FileWatcher init failed for %@ — auto-refresh unavailable",
                  repositoryURL.path)
        }
        watcher?.start()
    }

    private func loadDiff(for change: GitFileChange, requestRevision: Int) async {
        guard let gitService else { return }
        let capturedErrorRevision = errorRevision

        do {
            let diff = try await gitService.diff(for: change)
            if self.gitService === gitService, diffRequestRevision == requestRevision,
               selectedChange?.id == change.id {
                guard !diff.isEmpty else {
                    // git diff succeeded with empty output — the change is
                    // stale (committed/reverted externally while the status
                    // snapshot was in flight). Drop the selection and refresh
                    // the list instead of parking on a dead "No diff output".
                    selectedChange = nil
                    selectedDiffText = ""
                    refreshNow()
                    return
                }
                selectedDiffText = diff
                clearError(ifRevision: capturedErrorRevision)
            }
        } catch {
            if self.gitService === gitService, diffRequestRevision == requestRevision,
               selectedChange?.id == change.id {
                selectedDiffText = ""
                setError(error)
            }
        }
    }

    private func ensureSelectedDiffIsFresh(using gitService: GitService) async {
        guard let snapshot = statusSnapshot else {
            selectedChange = nil
            selectedDiffText = ""
            return
        }

        guard let selected = selectedChange else {
            selectedDiffText = ""
            return
        }

        diffRequestRevision &+= 1
        let requestRevision = diffRequestRevision
        let selectedID = selected.id
        let allChanges = snapshot.staged + snapshot.modified + snapshot.untracked
        guard let stillExisting = allChanges.first(where: { $0.id == selected.id }) else {
            selectedChange = nil
            selectedDiffText = ""
            return
        }

        let capturedErrorRevision = errorRevision
        do {
            let diff = try await gitService.diff(for: stillExisting)
            guard self.gitService === gitService, diffRequestRevision == requestRevision,
                  selectedChange?.id == selectedID else { return }
            guard !diff.isEmpty else {
                // Same stale-change handling as loadDiff: empty diff means the
                // file no longer has modifications, so the selected change is
                // gone from the working tree. Clear it and refresh the list.
                selectedChange = nil
                selectedDiffText = ""
                refreshNow()
                return
            }
            selectedDiffText = diff
            clearError(ifRevision: capturedErrorRevision)
        } catch {
            guard self.gitService === gitService, diffRequestRevision == requestRevision,
                  selectedChange?.id == selectedID else { return }
            selectedDiffText = ""
            setError(error)
        }
    }

    private func invalidateRepositoryTasks() {
        generateRequestID = nil
        generateTask?.cancel()
        generateTask = nil
        commitMessageGenerator.cancel()
        isGeneratingMessage = false

    }

    @discardableResult
    private func setError(_ error: Error) -> Int {
        setError((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
    }

    @discardableResult
    private func setError(_ message: String) -> Int {
        errorRevision &+= 1
        errorMessage = message
        return errorRevision
    }

    private func clearError(ifRevision revision: Int? = nil) {
        if let revision, errorRevision != revision { return }
        errorRevision &+= 1
        errorMessage = nil
    }

    private func changeForFileURL(_ fileURL: URL) -> GitFileChange? {
        guard let snapshot = statusSnapshot else { return nil }
        let absolutePath = fileURL.standardizedFileURL.path
        let allChanges = snapshot.staged + snapshot.modified + snapshot.untracked

        return allChanges.first { change in
            let changePath = snapshot.repositoryRoot
                .appendingPathComponent(change.path)
                .standardizedFileURL
                .path
            return changePath == absolutePath
        }
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}
