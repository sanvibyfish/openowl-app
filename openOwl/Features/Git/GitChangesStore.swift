import Foundation
import Observation

@MainActor
@Observable
final class GitChangesStore {
    private(set) var repositoryURL: URL?
    private(set) var statusSnapshot: GitStatusSnapshot?
    var selectedChange: GitFileChange?
    private(set) var selectedDiffText: String = ""

    var commitMessage: String = ""

    private(set) var isRefreshing = false
    private var refreshRequestedWhileRefreshing = false
    private(set) var isRunningCommand = false
    var errorMessage: String?
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
    private var commitDetailTask: Task<Void, Never>?
    private var openDiffTask: Task<Void, Never>?
    private var loadingMoreLogService: GitService?
    private var logGeneration = 0

    private var preferredDirectory: URL
    private var openingDirectory: URL?
    private var repositoryOpenRequestID: UUID?

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
        let requestID = UUID()
        repositoryOpenRequestID = requestID
        let directoryURL = candidateURL.hasDirectoryPath ? candidateURL : candidateURL.deletingLastPathComponent()
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
            commitDetailTask?.cancel()
            commitDetailTask = nil
            errorMessage = nil
            infoMessage = nil

            configureWatcher(for: root)
            await refresh()
        } catch {
            guard !Task.isCancelled, repositoryOpenRequestID == requestID else { return }
            gitService = nil
            loadingMoreLogService = nil
            logGeneration &+= 1
            repositoryURL = nil
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
            commitDetailTask?.cancel()
            commitDetailTask = nil
            watcher?.stop()
            watcher = nil
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
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

        do {
            let snapshot = try await gitService.status()
            guard self.gitService === gitService else { return }
            statusSnapshot = snapshot
            errorMessage = nil

            await ensureSelectedDiffIsFresh(using: gitService)
            await loadLog(using: gitService, reset: true)
        } catch {
            guard self.gitService === gitService else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
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
        commitDetailTask?.cancel()
        commitDetailTask = nil
        isLoadingCommitDetail = false
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
                guard !Task.isCancelled, selectedCommitHash == capturedHash else { return }
                commitFiles = f
                commitDiffText = d
            } catch {
                guard !Task.isCancelled, selectedCommitHash == capturedHash else { return }
                commitFiles = []
                commitDiffText = ""
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                commitDetailErrorMessage = message
                errorMessage = message
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
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func selectChange(_ change: GitFileChange) {
        // Cancel any in-flight commit detail loading
        commitDetailTask?.cancel()
        commitDetailTask = nil
        isLoadingCommitDetail = false
        commitDetailErrorMessage = nil

        // Clear commit selection so diff panel shows working tree diff
        selectedCommitHash = nil
        commitFiles = []
        commitDiffText = ""

        selectedChange = change
        selectedDiffText = ""

        Task {
            await loadDiff(for: change)
        }
    }

    func clearInfoMessage() {
        infoMessage = nil
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
        guard let snapshot = statusSnapshot else { return }
        let paths = Set(snapshot.modified.map(\.path) + snapshot.untracked.map(\.path))
        stage(paths: Array(paths).sorted())
    }

    func unstageAll() {
        guard let gitService else { return }

        runCommand {
            try await gitService.unstageAll()
            self.infoMessage = "Unstaged all files."
        }
    }

    func generateCommitMessage() {
        guard let gitService else { NSLog("generateCommitMessage: no gitService"); return }
        guard !isGeneratingMessage else { NSLog("generateCommitMessage: already generating"); return }
        NSLog("generateCommitMessage: starting")
        isGeneratingMessage = true

        generateTask = Task {
            defer { isGeneratingMessage = false }
            do {
                let diff = try await gitService.diff(staged: true)
                try Task.checkCancellation()
                guard !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    let allDiff = try await gitService.diff(staged: false)
                    try Task.checkCancellation()
                    guard !allDiff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        errorMessage = "No changes to generate message for."
                        return
                    }
                    let message = try await commitMessageGenerator.generate(diff: allDiff)
                    try Task.checkCancellation()
                    if !message.isEmpty { commitMessage = message }
                    return
                }
                let message = try await commitMessageGenerator.generate(diff: diff)
                try Task.checkCancellation()
                if !message.isEmpty { commitMessage = message }
            } catch is CancellationError {
                // cancelled by user
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    func cancelGenerateCommitMessage() {
        generateTask?.cancel()
        generateTask = nil
        commitMessageGenerator.cancel()
        isGeneratingMessage = false
    }

    func commit() {
        guard let gitService else { return }
        let autoStage = !(statusSnapshot?.hasStagedChanges ?? false)
        let message = commitMessage

        runCommand {
            try await gitService.commit(message: message, autoStageWhenNeeded: autoStage)
            self.commitMessage = ""
            self.infoMessage = autoStage ? "Committed (auto-staged all changes)." : "Committed."
        }
    }

    func deleteBranch(name: String, force: Bool = false) {
        guard let gitService else { return }
        let targetBranch = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetBranch.isEmpty else { return }

        runCommand {
            try await gitService.deleteBranch(name: targetBranch, force: force)
            self.infoMessage = force ? "Force deleted branch: \(targetBranch)" : "Deleted branch: \(targetBranch)"
        }
    }

    func fetch() {
        guard let gitService else { return }
        runCommand {
            try await gitService.fetch()
            self.infoMessage = "Fetch completed."
        }
    }

    func pull() {
        guard let gitService else { return }
        runCommand {
            try await gitService.pull()
            self.infoMessage = "Pull completed."
        }
    }

    func push() {
        guard let gitService else { return }
        runCommand {
            try await gitService.push()
            self.infoMessage = "Push completed."
        }
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
        guard let gitService else { return }
        guard !paths.isEmpty else { return }

        runCommand {
            try await gitService.stage(files: paths)
            self.infoMessage = "Staged \(paths.count) file(s)."
        }
    }

    func discardByPath(_ relativePath: String) {
        guard let gitService else { return }
        guard !relativePath.isEmpty else { return }

        // Find the change to determine if it's modified or untracked
        let allChanges = (statusSnapshot?.modified ?? []) + (statusSnapshot?.untracked ?? [])
        guard let change = allChanges.first(where: { $0.path == relativePath }) else { return }

        runCommand {
            if change.section == .untracked {
                try await gitService.discardUntracked(paths: [relativePath])
            } else {
                try await gitService.discardModified(files: [relativePath])
            }
            self.infoMessage = "Discarded changes for \(relativePath)."
        }
    }

    func unstage(paths: [String]) {
        guard let gitService else { return }
        guard !paths.isEmpty else { return }

        runCommand {
            try await gitService.unstage(files: paths)
            self.infoMessage = "Unstaged \(paths.count) file(s)."
        }
    }

    private func discard(changes: [GitFileChange]) {
        guard let gitService else { return }
        guard !changes.isEmpty else { return }

        let modifiedPaths = Array(
            Set(changes.filter { $0.section == .modified }.map(\.path))
        ).sorted()
        let untrackedPaths = Array(
            Set(changes.filter { $0.section == .untracked }.map(\.path))
        ).sorted()

        guard !modifiedPaths.isEmpty || !untrackedPaths.isEmpty else { return }

        runCommand {
            if !modifiedPaths.isEmpty {
                try await gitService.discardModified(files: modifiedPaths)
            }
            if !untrackedPaths.isEmpty {
                try await gitService.discardUntracked(paths: untrackedPaths)
            }

            let total = modifiedPaths.count + untrackedPaths.count
            self.infoMessage = "Discarded \(total) change(s)."
        }
    }

    private func runCommand(_ operation: @escaping () async throws -> Void) {
        guard !isRunningCommand else { return }
        isRunningCommand = true

        Task {
            defer { isRunningCommand = false }
            do {
                try await operation()
                await refresh()
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
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

    private func loadDiff(for change: GitFileChange) async {
        guard let gitService else { return }

        do {
            let diff = try await gitService.diff(for: change)
            if self.gitService === gitService, selectedChange?.id == change.id {
                selectedDiffText = diff
            }
        } catch {
            if self.gitService === gitService, selectedChange?.id == change.id {
                selectedDiffText = ""
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
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

        let allChanges = snapshot.staged + snapshot.modified + snapshot.untracked
        guard let stillExisting = allChanges.first(where: { $0.id == selected.id }) else {
            selectedChange = nil
            selectedDiffText = ""
            return
        }

        do {
            let diff = try await gitService.diff(for: stillExisting)
            guard self.gitService === gitService else { return }
            selectedDiffText = diff
        } catch {
            guard self.gitService === gitService else { return }
            selectedDiffText = ""
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
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
