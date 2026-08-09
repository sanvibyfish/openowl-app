import AppKit
import Foundation
import Observation

enum FileGitState: String, Hashable {
    case added
    case modified
    case deleted
    case renamed
    case conflicted

    var priority: Int {
        switch self {
        case .conflicted:
            return 5
        case .deleted:
            return 4
        case .renamed:
            return 3
        case .modified:
            return 2
        case .added:
            return 1
        }
    }

    var shortCode: String {
        switch self {
        case .added:
            return "A"
        case .modified:
            return "M"
        case .deleted:
            return "D"
        case .renamed:
            return "R"
        case .conflicted:
            return "U"
        }
    }
}

struct FileExplorerNode: Identifiable, Hashable {
    let id: String
    let url: URL
    let name: String
    let isDirectory: Bool
    let gitState: FileGitState?
    let children: [FileExplorerNode]?
    // For directories: children == nil means "not yet scanned" (lazy)
    // children == [] means "scanned and empty"
    // For files: children is always nil
}

enum FilePreviewState {
    case none
    case directory(path: String, itemCount: Int)
    case text(content: String, truncated: Bool)
    case binary
    case unavailable(message: String)
}

struct FileQuickOpenMatch: Identifiable, Hashable {
    let node: FileExplorerNode
    let score: Int
    let matchedIndices: [Int] // character indices in node.name that matched the query

    var id: String { node.id }
}

@MainActor
@Observable
final class FileExplorerStore {
    private(set) var projectURL: URL?
    private(set) var rootNodes: [FileExplorerNode] = []
    private(set) var isRefreshing = false
    private var refreshRequestedWhileRefreshing = false
    private(set) var fileSystemRevision = 0
    var selectedNodeID: String?
    private(set) var previewState: FilePreviewState = .none
    var errorMessage: String?

    /// File names of editor tabs with unsaved edits, published by the editor
    /// view. The buffers themselves are `@State` inside that view, so this is
    /// the only handle `applicationShouldTerminate` has on them — without it,
    /// ⌘Q discarded unsaved work without asking.
    private var unsavedTabNamesByEditor: [UUID: [String]] = [:]
    var unsavedTabNames: [String] {
        unsavedTabNamesByEditor.values.flatMap { $0 }.sorted()
    }
    var isQuickOpenPresented = false
    var quickOpenQuery: String = "" {
        didSet {
            if quickOpenQuery != oldValue { updateQuickOpenResults() }
        }
    }
    var quickOpenSelectionID: String?

    private(set) var nodeIndex: [String: FileExplorerNode] = [:]
    private var searchableFileNodes: [FileExplorerNode] = []
    private var watcher: FileWatcher?

    func publishUnsavedTabNames(_ names: [String], for editorID: UUID) {
        if names.isEmpty {
            unsavedTabNamesByEditor.removeValue(forKey: editorID)
        } else {
            unsavedTabNamesByEditor[editorID] = names.sorted()
        }
    }

    func removeUnsavedTabNames(for editorID: UUID) {
        unsavedTabNamesByEditor.removeValue(forKey: editorID)
    }

    func setupQueryAutoSearch() {
        // No-op: quickOpenQuery.didSet now triggers updateQuickOpenResults() directly.
        // Kept for API compatibility with callers.
    }

    // Cache scan results per project to avoid re-scanning on switch.
    // Capped + LRU-ordered: a large nodeIndex (5k+ files) can cost tens of
    // megabytes, so unbounded growth across many opened projects masquerades
    // as a memory leak.
    private struct ProjectCache {
        let nodes: [FileExplorerNode]
        let index: [String: FileExplorerNode]
    }
    private static let maxProjectScanCacheEntries = 5
    private var projectScanCache: [String: ProjectCache] = [:]
    /// Project paths in LRU order; head = oldest, tail = most recently written.
    private var projectScanCacheOrder: [String] = []

    private func writeProjectScanCache(_ key: String, _ value: ProjectCache) {
        projectScanCache[key] = value
        projectScanCacheOrder.removeAll { $0 == key }
        projectScanCacheOrder.append(key)
        while projectScanCacheOrder.count > Self.maxProjectScanCacheEntries {
            let evict = projectScanCacheOrder.removeFirst()
            projectScanCache.removeValue(forKey: evict)
        }
    }

    var selectedNode: FileExplorerNode? {
        guard let selectedNodeID else { return nil }
        return nodeIndex[selectedNodeID]
    }

    private(set) var quickOpenResults: [FileQuickOpenMatch] = []
    private var quickOpenWorkItem: DispatchWorkItem?
    private var quickOpenGeneration: Int = 0

    var quickOpenMatches: [FileQuickOpenMatch] { quickOpenResults }

    func updateQuickOpenResults() {
        quickOpenWorkItem?.cancel()
        quickOpenWorkItem = nil

        let query = quickOpenQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let nodes = searchableFileNodes

        guard !nodes.isEmpty else {
            quickOpenResults = []
            return
        }

        guard !query.isEmpty else {
            quickOpenResults = Array(nodes.prefix(200).map { FileQuickOpenMatch(node: $0, score: 0, matchedIndices: []) })
            return
        }

        // Synchronous fuzzy search — fast enough for <20k nodes
        let results: [FileQuickOpenMatch] = nodes
            .compactMap { node -> FileQuickOpenMatch? in
                guard let result = FileExplorerStore.quickOpenScore(for: node, query: query) else { return nil }
                return FileQuickOpenMatch(node: node, score: result.score, matchedIndices: result.indices)
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.node.url.path.localizedStandardCompare(rhs.node.url.path) == .orderedAscending
            }
        quickOpenResults = Array(results.prefix(50))
    }

    func setProject(_ url: URL?) {
        let standardized = url?.standardizedFileURL
        guard projectURL != standardized else { return }

        // Save current project's state to cache
        if let oldURL = projectURL, !rootNodes.isEmpty {
            writeProjectScanCache(oldURL.path, ProjectCache(nodes: rootNodes, index: nodeIndex))
        }

        projectURL = standardized
        selectedNodeID = nil
        previewState = .none
        errorMessage = nil
        dismissQuickOpen()
        currentGitContext = .empty

        // Restore from cache if available (instant)
        let restoredFromCache: Bool
        if let standardized, let cached = projectScanCache[standardized.path] {
            rootNodes = cached.nodes
            nodeIndex = cached.index
            searchableFileNodes = cached.index.values
                .filter { !$0.isDirectory }
                .sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
            restoredFromCache = true
        } else {
            rootNodes = []
            nodeIndex = [:]
            searchableFileNodes = []
            restoredFromCache = false
        }

        configureWatcher()

        if restoredFromCache {
            // Cache provides the tree instantly. Run a background-only refresh
            // that skips the shallow phase and won't flash-replace the tree.
            Task { await refreshFullOnly() }
        } else {
            refreshNow()
        }
    }

    func refreshNow() {
        Task {
            if rootNodes.isEmpty {
                await refresh()        // First load: shallow + full (instant feedback)
            } else {
                await refreshFullOnly() // Subsequent: full only (preserves expanded tree)
            }
        }
    }

    /// Lazily scan a directory's children when user expands it
    func expandDirectory(_ dirPath: String) {
        guard let node = nodeIndex[dirPath], node.isDirectory, node.children == nil else { return }

        let gitContext = currentGitContext
        // Scan this directory synchronously (single directory is fast)
        let childURLs = Self.sortEntries(Self.directoryEntries(at: node.url))
        var newChildren: [FileExplorerNode] = []
        for url in childURLs {
            if Self.shouldIgnore(url: url, gitContext: gitContext) { continue }
            let path = url.standardizedFileURL.path
            // Do NOT call isGitIgnored here: gitignore filtering is the responsibility
            // of the initial tree scan (buildNode). expandDirectory is an explicit user
            // action — showing empty children for an ignored directory is a regression.
            let rv: URLResourceValues
            do {
                rv = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            } catch let error as NSError where error.code == NSFileNoSuchFileError {
                continue  // file removed between enumeration and stat — skip silently
            } catch {
                NSLog("openOwl: [FileExplorer] resourceValues failed for %@: %@",
                      url.path, error.localizedDescription)
                continue  // skip rather than misclassify as file
            }
            let isDir = rv.isDirectory ?? false
            let isSym = rv.isSymbolicLink ?? false

            // Compute git state from the cached context
            var gitState: FileGitState? = gitContext.statusByAbsolutePath[path]
            if isDir && !isSym {
                // Directory: infer from any status entries under this path
                let prefix = path + "/"
                for (statusPath, fileState) in gitContext.statusByAbsolutePath {
                    if statusPath.hasPrefix(prefix) {
                        gitState = Self.mergeGitState(gitState, fileState)
                    }
                }
            }

            let child = FileExplorerNode(
                id: path, url: url,
                name: Self.displayName(for: url),
                isDirectory: isDir && !isSym,
                gitState: gitState,
                children: (isDir && !isSym) ? nil : nil // lazy for subdirs too
            )
            nodeIndex[child.id] = child
            newChildren.append(child)
        }

        // Update the parent node with children
        let updated = FileExplorerNode(
            id: node.id, url: node.url, name: node.name,
            isDirectory: true, gitState: node.gitState,
            children: newChildren
        )
        nodeIndex[updated.id] = updated

        // Update in rootNodes tree
        rootNodes = Self.replaceNode(in: rootNodes, id: dirPath, with: updated)

        // Add new files to searchable list
        let newFiles = newChildren.filter { !$0.isDirectory }
        if !newFiles.isEmpty {
            searchableFileNodes.append(contentsOf: newFiles)
        }
    }

    private static func replaceNode(in nodes: [FileExplorerNode], id: String, with replacement: FileExplorerNode) -> [FileExplorerNode] {
        nodes.map { node in
            if node.id == id { return replacement }
            if let children = node.children {
                let updated = replaceNode(in: children, id: id, with: replacement)
                if updated != children {
                    return FileExplorerNode(id: node.id, url: node.url, name: node.name,
                                           isDirectory: node.isDirectory, gitState: node.gitState, children: updated)
                }
            }
            return node
        }
    }

    func selectNode(_ nodeID: String?) {
        selectedNodeID = nodeID
        loadPreviewForSelection()
    }

    func presentQuickOpen(projectURL fallback: URL? = nil) {
        // Lazy-load file index if not yet scanned (e.g. opened from terminal tab)
        if searchableFileNodes.isEmpty {
            if let url = self.projectURL ?? fallback {
                if self.projectURL == url.standardizedFileURL {
                    refreshNow()  // already set, just needs scan
                } else {
                    setProject(url)
                }
            }
        }
        guard !searchableFileNodes.isEmpty else { return }
        quickOpenGeneration += 1  // Invalidate any pending dismiss async block
        quickOpenQuery = ""
        isQuickOpenPresented = true
        syncQuickOpenSelection()
    }

    func dismissQuickOpen() {
        quickOpenWorkItem?.cancel()
        quickOpenGeneration += 1
        let gen = quickOpenGeneration
        // Defer to avoid "Publishing changes from within view updates"
        // when called from .onChange or other view-update contexts.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.quickOpenGeneration == gen else { return }
            self.isQuickOpenPresented = false
            self.quickOpenQuery = ""
            self.quickOpenResults = []
            self.quickOpenSelectionID = nil
        }
    }

    func syncQuickOpenSelection() {
        let matches = quickOpenMatches
        guard !matches.isEmpty else {
            quickOpenSelectionID = nil
            return
        }

        if let quickOpenSelectionID,
           matches.contains(where: { $0.id == quickOpenSelectionID }) {
            return
        }

        quickOpenSelectionID = matches[0].id
    }

    func isChangedFile(_ node: FileExplorerNode) -> Bool {
        !node.isDirectory && node.gitState != nil
    }

    func relativePath(for node: FileExplorerNode) -> String {
        guard let projectURL else { return node.url.path }
        let rootPath = projectURL.standardizedFileURL.path
        let filePath = node.url.standardizedFileURL.path

        if filePath == rootPath {
            return "."
        }
        if filePath.hasPrefix(rootPath + "/") {
            return String(filePath.dropFirst(rootPath.count + 1))
        }

        return filePath
    }

    func copyPath(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.path, forType: .string)
    }

    // MARK: - File Operations

    /// Copy file URLs to pasteboard (for Cmd+C)
    func copyFiles(_ urls: [URL]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        UserDefaults.standard.removeObject(forKey: "openowl.fileCutPending")
        guard pasteboard.writeObjects(urls as [NSURL]) else {
            errorMessage = "无法复制文件到剪贴板"
            return
        }
    }

    /// Cut files: copy to pasteboard and mark for move
    func cutFiles(_ urls: [URL]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.writeObjects(urls as [NSURL]) else {
            UserDefaults.standard.removeObject(forKey: "openowl.fileCutPending")
            errorMessage = "无法剪切文件到剪贴板"
            return
        }
        // Store cut state — on paste we move instead of copy
        UserDefaults.standard.set(true, forKey: "openowl.fileCutPending")
    }

    /// Paste files from pasteboard into target directory
    func pasteFiles(into targetDirectory: URL) {
        let pasteboard = NSPasteboard.general
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return }

        let isCut = UserDefaults.standard.bool(forKey: "openowl.fileCutPending")
        UserDefaults.standard.removeObject(forKey: "openowl.fileCutPending")

        let fm = FileManager.default
        for url in urls {
            let destURL = targetDirectory.appendingPathComponent(url.lastPathComponent)
            do {
                if isCut {
                    try fm.moveItem(at: url, to: destURL)
                } else {
                    try fm.copyItem(at: url, to: destURL)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        refreshNow()
    }

    /// Rename file/folder
    func renameNode(_ node: FileExplorerNode, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != node.name else { return }

        let newURL = node.url.deletingLastPathComponent().appendingPathComponent(trimmed)
        do {
            try FileManager.default.moveItem(at: node.url, to: newURL)
            refreshNow()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Delete files (move to Trash)
    func deleteNodes(_ urls: [URL]) {
        let pathsToRemove = Set(urls.map { $0.standardizedFileURL.path })

        // Immediately remove from UI
        func filterNodes(_ nodes: [FileExplorerNode]) -> [FileExplorerNode] {
            nodes.compactMap { node in
                if pathsToRemove.contains(node.url.standardizedFileURL.path) { return nil }
                if let children = node.children {
                    let filtered = filterNodes(children)
                    return FileExplorerNode(id: node.id, url: node.url, name: node.name,
                                            isDirectory: node.isDirectory, gitState: node.gitState,
                                            children: filtered)
                }
                return node
            }
        }
        rootNodes = filterNodes(rootNodes)

        for id in pathsToRemove {
            nodeIndex.removeValue(forKey: id)
            if selectedNodeID == id { selectedNodeID = nil; previewState = .none }
        }

        // Trash off the main actor (FileExplorerStore is @MainActor; a plain Task
        // would inherit it and block the UI). Task.detached runs on the cooperative
        // pool; we await its result back on the main actor to update state.
        Task {
            let failedNames: [String] = await Task.detached(priority: .userInitiated) {
                var failed: [String] = []
                for url in urls {
                    do {
                        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                    } catch {
                        NSLog("openOwl: [FileExplorer] trashItem failed for %@: %@",
                              url.path, error.localizedDescription)
                        failed.append(url.lastPathComponent)
                    }
                }
                return failed
            }.value
            if !failedNames.isEmpty {
                errorMessage = "无法删除：\(failedNames.joined(separator: "、"))"
                refreshNow()  // re-scan to restore failed items in the tree
            }
        }
    }

    private func refresh() async {
        guard !isRefreshing else {
            refreshRequestedWhileRefreshing = true
            return
        }
        guard let projectURL else {
            rootNodes = []
            nodeIndex = [:]
            previewState = .none
            return
        }

        isRefreshing = true
        defer {
            isRefreshing = false
            if refreshRequestedWhileRefreshing {
                refreshRequestedWhileRefreshing = false
                refreshNow()
            }
        }

        let capturedURL = projectURL
        let t0 = CFAbsoluteTimeGetCurrent()

        // Phase 1: Scan root level only (instant, ~1ms)
        let shallowResult = await Task.detached(priority: .userInitiated) {
            Self.scanProject(projectURL: capturedURL, gitContext: .empty, maxDepth: 1)
        }.value
        guard projectURL == capturedURL else { return }
        NSLog("FileExplorer: shallow scan %.0fms (%d nodes)", (CFAbsoluteTimeGetCurrent() - t0) * 1000, shallowResult.index.count)

        rootNodes = shallowResult.nodes
        nodeIndex = shallowResult.index
        searchableFileNodes = shallowResult.index.values
            .filter { !$0.isDirectory }
            .sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }

        // Phase 2: Full scan with gitignore + git status
        let t1 = CFAbsoluteTimeGetCurrent()
        async let ignoreCtx = loadIgnoreContext(for: capturedURL)
        async let statusMap = loadGitStatus(for: capturedURL)
        let (ignore, status) = await (ignoreCtx, statusMap)
        guard projectURL == capturedURL else { return }

        let gitContext = GitContext(
            statusByAbsolutePath: status,
            ignoredExactPaths: ignore.ignoredExactPaths,
            ignoredDirectoryPrefixes: ignore.ignoredDirectoryPrefixes
        )
        let (fullResult, sortedFiles) = await Task.detached(priority: .userInitiated) {
            let result = Self.scanProject(projectURL: capturedURL, gitContext: gitContext)
            let files = result.index.values
                .filter { !$0.isDirectory }
                .sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
            return (result, files)
        }.value
        guard projectURL == capturedURL else { return }
        NSLog("FileExplorer: full scan %.0fms (%d nodes)", (CFAbsoluteTimeGetCurrent() - t1) * 1000, fullResult.index.count)

        currentGitContext = gitContext
        rootNodes = fullResult.nodes
        nodeIndex = fullResult.index
        searchableFileNodes = sortedFiles

        if let selectedNodeID, nodeIndex[selectedNodeID] == nil {
            self.selectedNodeID = nil
        }
        syncQuickOpenSelection()
        loadPreviewForSelection()

        // Update cache
        writeProjectScanCache(capturedURL.path, ProjectCache(nodes: rootNodes, index: nodeIndex))
    }

    /// Background-only refresh: skip shallow scan, only update git status.
    /// Used when cache already provides the tree — avoids flashing the UI.
    private func refreshFullOnly() async {
        guard !isRefreshing else {
            refreshRequestedWhileRefreshing = true
            return
        }
        guard let projectURL else { return }

        isRefreshing = true
        defer {
            isRefreshing = false
            if refreshRequestedWhileRefreshing {
                refreshRequestedWhileRefreshing = false
                refreshNow()
            }
        }

        let capturedURL = projectURL
        let t1 = CFAbsoluteTimeGetCurrent()

        async let ignoreCtx = loadIgnoreContext(for: capturedURL)
        async let statusMap = loadGitStatus(for: capturedURL)
        let (ignore, status) = await (ignoreCtx, statusMap)
        guard self.projectURL == capturedURL else { return }

        let gitContext = GitContext(
            statusByAbsolutePath: status,
            ignoredExactPaths: ignore.ignoredExactPaths,
            ignoredDirectoryPrefixes: ignore.ignoredDirectoryPrefixes
        )
        let (fullResult, sortedFiles) = await Task.detached(priority: .userInitiated) {
            let result = Self.scanProject(projectURL: capturedURL, gitContext: gitContext)
            let files = result.index.values
                .filter { !$0.isDirectory }
                .sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
            return (result, files)
        }.value
        guard self.projectURL == capturedURL else { return }
        NSLog("FileExplorer: background refresh %.0fms (%d nodes)", (CFAbsoluteTimeGetCurrent() - t1) * 1000, fullResult.index.count)

        currentGitContext = gitContext
        rootNodes = fullResult.nodes
        nodeIndex = fullResult.index
        searchableFileNodes = sortedFiles

        if let selectedNodeID, nodeIndex[selectedNodeID] == nil {
            self.selectedNodeID = nil
        }
        syncQuickOpenSelection()
        loadPreviewForSelection()
        writeProjectScanCache(capturedURL.path, ProjectCache(nodes: rootNodes, index: nodeIndex))
    }

    private func configureWatcher() {
        watcher?.stop()
        watcher = nil

        guard let projectURL else { return }

        watcher = FileWatcher(directoryURL: projectURL) { [weak self] in
            guard let self else { return }
            fileSystemRevision &+= 1
            refreshNow()
        }
        if watcher == nil {
            NSLog("openOwl: [FileExplorer] FileWatcher init failed for %@ — auto-refresh unavailable",
                  projectURL.path)
        }
        watcher?.start()
    }

    private func loadPreviewForSelection() {
        guard let node = selectedNode else {
            previewState = .none
            return
        }

        if node.isDirectory {
            previewState = .directory(
                path: node.url.path,
                itemCount: node.children?.count ?? 0
            )
            return
        }

        previewState = Self.makePreviewState(for: node.url)
    }

    /// Most recent git context (status + ignore rules). Updated after each full scan.
    /// Used by expandDirectory so lazily-loaded children show correct git state.
    private var currentGitContext: GitContext = .empty

    private var cachedRepoRoot: [String: URL] = [:]

    private func repoRoot(for projectURL: URL) async -> URL? {
        let key = projectURL.path
        if let cached = cachedRepoRoot[key] { return cached }
        let probe = GitService(workingDirectory: projectURL)
        do {
            let root = try await probe.repositoryRoot()
            cachedRepoRoot[key] = root
            return root
        } catch GitServiceError.notGitRepository {
            return nil
        } catch {
            NSLog("openOwl: [FileExplorer] repoRoot failed for %@: %@",
                  projectURL.path, error.localizedDescription)
            return nil
        }
    }

    /// Fast: only gitignore list, no status
    private func loadIgnoreContext(for projectURL: URL) async -> GitContext {
        guard let repositoryRoot = await repoRoot(for: projectURL) else { return .empty }
        let gitService = GitService(workingDirectory: repositoryRoot)

        var ignoredExactPaths: Set<String> = []
        var ignoredDirectoryPrefixes: [String] = []

        do {
            let ignoredPaths = try await gitService.ignoredPaths()
            for ignoredPath in ignoredPaths {
                let normalized = ignoredPath.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalized.isEmpty else { continue }

                if normalized.hasSuffix("/") {
                    let directoryPath = String(normalized.dropLast())
                    let absolutePath = repositoryRoot
                        .appendingPathComponent(directoryPath)
                        .standardizedFileURL
                        .path
                    ignoredDirectoryPrefixes.append(absolutePath)
                } else {
                    let absolutePath = repositoryRoot
                        .appendingPathComponent(normalized)
                        .standardizedFileURL
                        .path
                    ignoredExactPaths.insert(absolutePath)
                }
            }
        } catch GitServiceError.notGitRepository {
            return .empty
        } catch {
            NSLog("openOwl: [FileExplorer] loadIgnoreContext failed for %@: %@",
                  projectURL.path, error.localizedDescription)
        }

        let compactedPrefixes = Self.compactDirectoryPrefixes(ignoredDirectoryPrefixes)
        let compactedExactPaths = Set(ignoredExactPaths.filter { ignoredPath in
            !compactedPrefixes.contains { prefix in
                ignoredPath == prefix || ignoredPath.hasPrefix(prefix + "/")
            }
        })

        return GitContext(
            statusByAbsolutePath: [:],
            ignoredExactPaths: compactedExactPaths,
            ignoredDirectoryPrefixes: compactedPrefixes
        )
    }

    /// Slower: git status for change markers (A/M/D)
    private func loadGitStatus(for projectURL: URL) async -> [String: FileGitState] {
        guard let repositoryRoot = await repoRoot(for: projectURL) else { return [:] }
        let gitService = GitService(workingDirectory: repositoryRoot)
        var statusMap: [String: FileGitState] = [:]

        do {
            let snapshot = try await gitService.status()
            let allChanges = snapshot.staged + snapshot.modified + snapshot.untracked
            for change in allChanges {
                let absolutePath = repositoryRoot
                    .appendingPathComponent(change.path)
                    .standardizedFileURL
                    .path
                let state = Self.classifyGitState(for: change)
                let existing = statusMap[absolutePath]
                statusMap[absolutePath] = Self.mergeGitState(existing, state)
            }
        } catch GitServiceError.notGitRepository {
            return [:]
        } catch {
            NSLog("openOwl: [FileExplorer] loadGitStatus failed for %@: %@",
                  projectURL.path, error.localizedDescription)
        }
        return statusMap
    }
}

extension FileExplorerStore {
    struct ScanResult {
        let nodes: [FileExplorerNode]
        let index: [String: FileExplorerNode]
    }

    struct GitContext {
        let statusByAbsolutePath: [String: FileGitState]
        let ignoredExactPaths: Set<String>
        let ignoredDirectoryPrefixes: [String]

        static let empty = GitContext(
            statusByAbsolutePath: [:],
            ignoredExactPaths: [],
            ignoredDirectoryPrefixes: []
        )
    }

    nonisolated static func classifyGitState(for change: GitFileChange) -> FileGitState {
        let index = change.indexStatus
        let workTree = change.workTreeStatus

        if isConflict(indexStatus: index, workTreeStatus: workTree) {
            return .conflicted
        }
        if index == "D" || workTree == "D" {
            return .deleted
        }
        if index == "R" || workTree == "R" || index == "C" || workTree == "C" {
            return .renamed
        }
        if index == "A" || workTree == "A" || index == "?" || workTree == "?" || change.section == .untracked {
            return .added
        }
        if index == "M" || workTree == "M" || index == "T" || workTree == "T" {
            return .modified
        }
        return .modified
    }

    nonisolated static func mergeGitState(_ lhs: FileGitState?, _ rhs: FileGitState?) -> FileGitState? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        return lhs.priority >= rhs.priority ? lhs : rhs
    }

    nonisolated static func isConflict(indexStatus: Character, workTreeStatus: Character) -> Bool {
        if indexStatus == "U" || workTreeStatus == "U" {
            return true
        }
        if indexStatus == "A" && workTreeStatus == "A" {
            return true
        }
        if indexStatus == "D" && workTreeStatus == "D" {
            return true
        }
        return false
    }

    nonisolated static func compactDirectoryPrefixes(_ prefixes: [String]) -> [String] {
        let sorted = Array(Set(prefixes)).sorted { lhs, rhs in
            if lhs.count != rhs.count {
                return lhs.count < rhs.count
            }
            return lhs < rhs
        }

        var compacted: [String] = []
        compacted.reserveCapacity(sorted.count)

        for prefix in sorted {
            if compacted.contains(where: { prefix == $0 || prefix.hasPrefix($0 + "/") }) {
                continue
            }
            compacted.append(prefix)
        }

        return compacted
    }

    /// Fuzzy match: query characters must appear in order but not contiguously.
    /// Returns (score, matchedIndices in name) or nil if no match.
    nonisolated static func fuzzyMatch(name: String, path: String, query: String) -> (score: Int, indices: [Int])? {
        let nameLower = name.lowercased()
        let pathLower = path.lowercased()
        let nameChars = Array(nameLower)
        let queryChars = Array(query)

        guard !queryChars.isEmpty else { return (0, []) }

        // Try matching against name first
        if let (nameScore, indices) = fuzzyScoreString(nameChars, query: queryChars) {
            var score = nameScore + 500
            if nameLower == query { score += 1000 }
            if nameLower.hasPrefix(query) { score += 600 }
            let depth = pathLower.split(separator: "/").count
            score += max(100 - depth * 3, 0)
            return (score, indices)
        }

        // Fallback: substring match against path (not fuzzy — avoids false positives)
        if pathLower.contains(query) {
            let depth = pathLower.split(separator: "/").count
            let score = 50 + max(100 - depth * 3, 0)
            return (score, [])
        }

        return nil
    }

    /// Score a fuzzy match of query against target characters.
    /// Returns (score, matched indices) or nil.
    private nonisolated static func fuzzyScoreString(_ target: [Character], query: [Character]) -> (Int, [Int])? {
        var queryIdx = 0
        var matchedIndices: [Int] = []
        var score = 0
        var prevMatchIdx = -1

        for (i, ch) in target.enumerated() {
            guard queryIdx < query.count else { break }
            if ch == query[queryIdx] {
                matchedIndices.append(i)
                // Consecutive match bonus
                if prevMatchIdx == i - 1 { score += 8 }
                // Start of word bonus (after separator or camelCase)
                if i == 0 || target[i - 1] == "/" || target[i - 1] == "." || target[i - 1] == "-" || target[i - 1] == "_"
                    || (target[i - 1].isLowercase && ch.isUppercase) {
                    score += 12
                }
                // Early match bonus
                score += max(10 - i, 0)
                score += 4 // base per-character match
                prevMatchIdx = i
                queryIdx += 1
            }
        }

        guard queryIdx == query.count else { return nil } // not all query chars matched
        return (score, matchedIndices)
    }

    nonisolated static func quickOpenScore(for node: FileExplorerNode, query: String) -> (score: Int, indices: [Int])? {
        fuzzyMatch(name: node.name, path: node.url.path.lowercased(), query: query)
    }

    nonisolated static func scanProject(projectURL: URL, gitContext: GitContext, maxDepth: Int = .max) -> ScanResult {
        var index: [String: FileExplorerNode] = [:]
        let topLevelURLs = directoryEntries(at: projectURL)
        let sortedURLs = sortEntries(topLevelURLs)

        let nodes = sortedURLs.compactMap { url in
            buildNode(url: url, gitContext: gitContext, index: &index, depth: 0, maxDepth: maxDepth)
        }

        return ScanResult(nodes: nodes, index: index)
    }

    nonisolated static func buildNode(
        url: URL,
        gitContext: GitContext,
        index: inout [String: FileExplorerNode],
        depth: Int = 0,
        maxDepth: Int = .max
    ) -> FileExplorerNode? {
        if shouldIgnore(url: url, gitContext: gitContext) {
            return nil
        }

        let path = url.standardizedFileURL.path
        let isDirectory: Bool
        let isSymbolicLink: Bool
        do {
            let rv = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            isDirectory = rv.isDirectory ?? false
            isSymbolicLink = rv.isSymbolicLink ?? false
        } catch let err as NSError
            where err.code == NSFileNoSuchFileError || err.code == NSFileReadNoSuchFileError {
            return nil  // Race condition: file disappeared between scan and build
        } catch {
            NSLog("openOwl: [FileExplorer] buildNode resourceValues failed for %@: %@",
                  url.path, error.localizedDescription)
            return nil
        }

        if isDirectory && !isSymbolicLink {
            // Show heavy or external directory boundaries as lazy nodes.
            // They remain visible and are scanned only when expanded.
            let isGitIgnored = Self.isGitIgnored(path: path, gitContext: gitContext)
            let children: [FileExplorerNode]?
            if shouldLoadDirectoryLazily(
                url: url,
                path: path,
                gitContext: gitContext,
                depth: depth,
                maxDepth: maxDepth,
                isGitIgnored: isGitIgnored
            ) {
                children = nil // lazy: will scan when user expands
            } else {
                let childURLs = sortEntries(directoryEntries(at: url))
                var built: [FileExplorerNode] = []
                built.reserveCapacity(childURLs.count)
                for childURL in childURLs {
                    if let childNode = buildNode(url: childURL, gitContext: gitContext, index: &index, depth: depth + 1, maxDepth: maxDepth) {
                        built.append(childNode)
                    }
                }
                children = built
            }

            var state = gitContext.statusByAbsolutePath[path]
            if let children {
                for child in children {
                    state = mergeGitState(state, child.gitState)
                }
            } else {
                // Lazy directory (not yet expanded): infer git state from
                // any status entries whose path starts with this directory.
                let prefix = path + "/"
                for (statusPath, fileState) in gitContext.statusByAbsolutePath {
                    if statusPath.hasPrefix(prefix) {
                        state = mergeGitState(state, fileState)
                    }
                }
            }

            let node = FileExplorerNode(
                id: path,
                url: url,
                name: displayName(for: url),
                isDirectory: true,
                gitState: state,
                children: children
            )
            index[node.id] = node
            return node
        }

        let node = FileExplorerNode(
            id: path,
            url: url,
            name: displayName(for: url),
            isDirectory: false,
            gitState: gitContext.statusByAbsolutePath[path],
            children: nil
        )
        index[node.id] = node
        return node
    }

    private static let alwaysIgnoredNames: Set<String> = [
        ".git", ".DS_Store", ".build", "DerivedData",
        "ghostty-resources", "GhosttyKit.xcframework"
    ]

    private static let alwaysLazyDirectoryNames: Set<String> = [
        "node_modules", ".pnpm", ".next", ".turbo", ".cache",
        "dist", "build", "coverage", ".expo", ".vercel", ".netlify",
        ".parcel-cache", ".svelte-kit", ".nuxt", "Pods", ".gradle", "target"
    ]

    nonisolated static func shouldIgnore(url: URL, gitContext: GitContext) -> Bool {
        alwaysIgnoredNames.contains(url.lastPathComponent)
    }

    nonisolated static func shouldLoadDirectoryLazily(
        url: URL,
        path: String,
        gitContext: GitContext,
        depth: Int,
        maxDepth: Int,
        isGitIgnored: Bool? = nil
    ) -> Bool {
        if depth >= maxDepth { return true }
        if isGitIgnored ?? Self.isGitIgnored(path: path, gitContext: gitContext) { return true }
        if alwaysLazyDirectoryNames.contains(url.lastPathComponent) { return true }

        // Treat nested repositories/worktrees like package directories: show the
        // root node, but do not index the whole repo when scanning a parent folder
        // such as ~/.openowl/workspace.
        let gitMarker = url.appendingPathComponent(".git").path
        return FileManager.default.fileExists(atPath: gitMarker)
    }

    nonisolated static func isGitIgnored(path: String, gitContext: GitContext) -> Bool {
        if gitContext.ignoredExactPaths.contains(path) { return true }
        for prefix in gitContext.ignoredDirectoryPrefixes {
            if path == prefix || path.hasPrefix(prefix + "/") { return true }
        }
        return false
    }

    nonisolated static func directoryEntries(at directoryURL: URL) -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsPackageDescendants]
            )
        } catch let err as NSError
            where err.code == NSFileReadNoSuchFileError || err.code == NSFileNoSuchFileError {
            return []  // Directory was deleted just before scan — expected, silent
        } catch {
            NSLog("openOwl: [FileExplorer] directoryEntries failed for %@: %@",
                  directoryURL.path, error.localizedDescription)
            return []
        }
    }

    nonisolated static func sortEntries(_ entries: [URL]) -> [URL] {
        // Pre-compute isDirectory once per URL (O(n)) rather than inside the
        // comparator (O(n log n)), and log failures instead of silently defaulting.
        var isDirectoryCache: [URL: Bool] = Dictionary(minimumCapacity: entries.count)
        for url in entries {
            do {
                let rv = try url.resourceValues(forKeys: [.isDirectoryKey])
                isDirectoryCache[url] = rv.isDirectory ?? false
            } catch {
                NSLog("openOwl: [FileExplorer] sortEntries resourceValues failed for %@: %@",
                      url.path, error.localizedDescription)
                isDirectoryCache[url] = false
            }
        }
        return entries.sorted { lhs, rhs in
            let lhsIsDirectory = isDirectoryCache[lhs] ?? false
            let rhsIsDirectory = isDirectoryCache[rhs] ?? false
            if lhsIsDirectory != rhsIsDirectory { return lhsIsDirectory }
            return displayName(for: lhs)
                .localizedStandardCompare(displayName(for: rhs)) == .orderedAscending
        }
    }

    nonisolated static func displayName(for url: URL) -> String {
        let name = url.lastPathComponent
        return name.isEmpty ? url.path : name
    }

    static func makePreviewState(for fileURL: URL) -> FilePreviewState {
        let maxPreviewBytes = 160_000

        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            let fileSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
            let data = try readPrefixData(from: fileURL, maxBytes: maxPreviewBytes)

            if data.firstIndex(of: 0) != nil {
                return .binary
            }

            let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)

            guard let text else {
                return .binary
            }

            let truncated = fileSize > data.count
            return .text(content: text, truncated: truncated)
        } catch {
            return .unavailable(message: error.localizedDescription)
        }
    }

    static func readPrefixData(from fileURL: URL, maxBytes: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer {
            try? handle.close()
        }

        return try handle.read(upToCount: maxBytes) ?? Data()
    }
}
