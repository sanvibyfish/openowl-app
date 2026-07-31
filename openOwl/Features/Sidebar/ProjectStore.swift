import AppKit
import Foundation
import Observation

struct ProjectItem: Identifiable, Hashable, Codable {
    let id: String
    let path: String
    var name: String
    var worktreeOf: String?       // parent project id
    var worktreeBranch: String?   // worktree branch name
    var lastBranch: String?       // last known branch (persisted for non-active projects)
    var branchPrefix: String?     // GitHub username or custom prefix for worktree branches
    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
    var displayName: String { name }
    var isWorktree: Bool { worktreeOf != nil }

    init(url: URL, id: String = UUID().uuidString) {
        let normalized = url.standardizedFileURL
        self.id = id
        self.path = normalized.path
        self.name = normalized.lastPathComponent.isEmpty ? normalized.path : normalized.lastPathComponent
    }

    init(path: String, name: String, id: String = UUID().uuidString, worktreeOf: String? = nil, worktreeBranch: String? = nil) {
        let normalized = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        self.id = id
        self.path = normalized.path
        self.name = name
        self.worktreeOf = worktreeOf
        self.worktreeBranch = worktreeBranch
    }
}

/// What is currently selected in the sidebar — either a project (or worktree) or a free terminal.
/// Doubles as the namespace key in `TerminalWorkspaceStore` (via `TerminalNamespace` typealias),
/// so it must be Hashable for dictionary use.
enum ActiveKind: Hashable {
    case project(String)
    case freeTerminal(UUID)
}

/// A free terminal — not tied to any project. Lives only for the current process lifetime.
struct FreeTerminalItem: Identifiable, Equatable {
    let id: UUID
    let createdAt: Date

    init(id: UUID = UUID(), createdAt: Date = Date()) {
        self.id = id
        self.createdAt = createdAt
    }
}

enum WorktreeCreationError: LocalizedError {
    case missingBranchPrefix

    var errorDescription: String? {
        switch self {
        case .missingBranchPrefix:
            return "This project has no branch prefix yet — openOwl reads it from the repository's git config."
        }
    }
}

enum UnreadableProjectStoreNotice {
    case quarantined(reason: String, backupURL: URL)
    case quarantineFailed(reason: String, storeURL: URL, error: String)
}

@MainActor
@Observable
final class ProjectStore {
    private(set) var projects: [ProjectItem] = []
    private var lastActiveProjectIDByRoot: [String: String] = [:]
    private let storeURL: URL
    private let unreadableStoreAlertPresenter: (UnreadableProjectStoreNotice) -> Void
    private(set) var isStoreUnreadable = false
    private var archivingWorktreeIDs: Set<String> = []
    private var creatingWorktreeRootIDs: Set<String> = []

    @ObservationIgnored
    private var activeContextChangeApprovers: [UUID: () -> Bool] = [:]

    /// Setting `activeProjectID` to a non-nil value implicitly clears any active
    /// free terminal (project selection takes priority over free-terminal selection).
    ///
    /// Branch-prefix detection hangs off this rather than off the call sites:
    /// there are thirteen assignments, and the ones that matter most are the
    /// implicit ones (removing a project falls back to another root, removing a
    /// worktree falls back to its parent). A project reached that way used to
    /// keep a nil prefix, which left "Create Worktree" permanently disabled.
    var activeProjectID: String? {
        didSet {
            if let activeProjectID {
                activeFreeTerminalID = nil
                rememberProjectSelection(activeProjectID)
                detectBranchPrefix(for: activeProjectID)
            }
        }
    }

    /// Free terminals are session-scoped — never persisted, recreated on launch.
    private(set) var freeTerminals: [FreeTerminalItem] = []

    /// The currently selected free terminal, if any. Mutually exclusive with activeProjectID.
    /// Setter exposed for @testable test access; production code should use `activate(_:)`.
    var activeFreeTerminalID: UUID?

    let bookmarkStore: BookmarkStore

    private static let productionStoreURL: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".openowl/openowl.json")
    }()

    private static var defaultStoreURL: URL {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil else {
            return productionStoreURL
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "openowl-project-store-test-host-\(ProcessInfo.processInfo.processIdentifier)",
                isDirectory: true
            )
            .appendingPathComponent("openowl.json")
    }

    private struct StoreFile: Codable {
        var projects: [ProjectItem]
        var activeProjectId: String?
    }

    // MARK: - Computed

    var rootProjects: [ProjectItem] {
        projects.filter { !$0.isWorktree }
    }

    /// Flat ordered list: each root project followed by its worktrees.
    /// Used as the data source for the global tab bar and Cmd+N shortcuts.
    var orderedProjectTabs: [ProjectItem] {
        var result: [ProjectItem] = []
        for root in rootProjects {
            result.append(root)
            result.append(contentsOf: worktrees(for: root.id))
        }
        return result
    }

    func worktrees(for projectID: String) -> [ProjectItem] {
        projects.filter { $0.worktreeOf == projectID }
    }

    var activeProjectURL: URL? {
        guard let activeProjectID else { return nil }
        return projects.first(where: { $0.id == activeProjectID })?.url
    }

    /// Root project the current selection belongs to — a worktree resolves to
    /// its parent. nil when a free terminal is active. Single source for "which
    /// project is selected" so the rail and the session list cannot disagree.
    var activeRootProject: ProjectItem? {
        guard let activeProjectID,
              let active = projects.first(where: { $0.id == activeProjectID }) else {
            return nil
        }
        guard let parentID = active.worktreeOf else { return active }
        return projects.first(where: { $0.id == parentID })
    }

    /// Computed view of the active selection. nil only during early init.
    var activeKind: ActiveKind? {
        if let id = activeProjectID { return .project(id) }
        if let id = activeFreeTerminalID { return .freeTerminal(id) }
        return nil
    }

    func isArchivingWorktree(id: String) -> Bool {
        archivingWorktreeIDs.contains(id)
    }

    @discardableResult
    func beginArchivingWorktree(id: String) -> Bool {
        archivingWorktreeIDs.insert(id).inserted
    }

    func endArchivingWorktree(id: String) {
        archivingWorktreeIDs.remove(id)
    }

    func isCreatingWorktree(rootID: String) -> Bool {
        creatingWorktreeRootIDs.contains(rootID)
    }

    /// Creates a worktree off `project` and activates it.
    ///
    /// Lives here rather than in the rail / session list because both offer the
    /// action against the same repository: two concurrent `git worktree add`
    /// runs collide on `index.lock`, and per-view in-flight state cannot see
    /// the other view's request.
    func createWorktree(for project: ProjectItem) async throws {
        // Read this root's own prefix, not the active project's, so create works
        // from the rail while a different project is selected.
        guard let prefix = project.branchPrefix else {
            throw WorktreeCreationError.missingBranchPrefix
        }
        guard !creatingWorktreeRootIDs.contains(project.id) else { return }
        guard permitsActiveContextChange() else { return }
        guard creatingWorktreeRootIDs.insert(project.id).inserted else { return }
        defer { creatingWorktreeRootIDs.remove(project.id) }

        let generated = BranchNameGenerator.generate(prefix: prefix)
        let git = GitService(workingDirectory: project.url)

        let worktreePath = try await git.addWorktree(
            branch: generated.branchName,
            dirName: generated.dirName
        )
        let worktree = insertWorktreeProject(
            parentID: project.id,
            path: worktreePath,
            branch: generated.branchName,
            activate: false
        )
        _ = activateProject(id: worktree.id)
    }

    // MARK: - Init

    init(
        storeURL: URL? = nil,
        unreadableStoreAlertPresenter: ((UnreadableProjectStoreNotice) -> Void)? = nil
    ) {
        let resolvedStoreURL = (storeURL ?? Self.defaultStoreURL).standardizedFileURL
        self.storeURL = resolvedStoreURL
        self.unreadableStoreAlertPresenter = unreadableStoreAlertPresenter
            ?? Self.presentUnreadableStoreAlert
        bookmarkStore = BookmarkStore(
            storeURL: resolvedStoreURL == Self.productionStoreURL
                ? nil
                : resolvedStoreURL
                    .deletingLastPathComponent()
                    .appendingPathComponent("bookmarks.plist")
        )

        load()
        if !isStoreUnreadable {
            seedDefaultProjectIfNeeded()
        }
        seedDefaultFreeTerminalIfNeeded()

        // If no project was restored (fresh install or all projects pruned),
        // default the selection to the first free terminal so the center view
        // shows a usable shell.
        if activeProjectID == nil, let first = freeTerminals.first {
            activeFreeTerminalID = first.id
        }
    }

    // MARK: - Project Management

    func openProjectPicker() {
        let panel = NSOpenPanel()
        panel.title = "Open Project"
        panel.message = "Choose a project folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let selected = panel.url else { return }
        addOrActivateProject(selected)
    }

    func addOrActivateProject(_ url: URL) {
        let normalized = url.standardizedFileURL.path
        if let existing = projects.first(where: { $0.path == normalized }) {
            _ = activateProject(id: existing.id)
            return
        }

        guard permitsActiveContextChange() else { return }

        let item = ProjectItem(url: url)
        projects.append(item)
        activeProjectID = item.id
        bookmarkStore.save(projectID: item.id, url: url)
        bookmarkStore.startAccessing(projectID: item.id)
        persist()

        // Auto-discover existing worktrees on disk
        Task { await discoverWorktrees(for: item) }
    }

    /// Scan git worktrees and add any that aren't already tracked.
    private func discoverWorktrees(for project: ProjectItem) async {
        let git = GitService(workingDirectory: project.url)
        do {
            let worktrees = try await git.listWorktrees()
            let mainRepoPath = project.url.standardizedFileURL.path
            for wt in worktrees {
                let wtPath = URL(fileURLWithPath: wt.path).standardizedFileURL.path
                // Skip the main repo itself
                guard wtPath != mainRepoPath else { continue }
                // Skip if already tracked
                guard !projects.contains(where: { $0.path == wtPath }) else { continue }
                // Skip if directory no longer exists
                guard FileManager.default.fileExists(atPath: wtPath) else { continue }

                let _ = addWorktreeProject(
                    parentID: project.id,
                    path: wtPath,
                    branch: wt.branch
                )
            }
        } catch {
            // Not a git repo or no worktrees — fine, skip silently
        }
    }

    @discardableResult
    func activateProject(id: String) -> Bool {
        guard projects.contains(where: { $0.id == id }) else { return false }
        guard !archivingWorktreeIDs.contains(id) else { return false }
        guard activeProjectID != id || activeFreeTerminalID != nil else { return true }
        guard permitsActiveContextChange() else { return false }

        activeProjectID = id
        persist()
        return true
    }

    /// Restores the most recently selected main/worktree namespace for a root project.
    func activateLastProject(inRoot rootID: String) {
        guard let root = projects.first(where: { $0.id == rootID && !$0.isWorktree }) else { return }
        let rememberedID = lastActiveProjectIDByRoot[rootID]
        let targetID: String
        if let rememberedID,
           projects.contains(where: {
               $0.id == rememberedID && ($0.id == rootID || $0.worktreeOf == rootID)
           }) {
            targetID = rememberedID
        } else {
            targetID = root.id
        }
        activateProject(id: targetID)
    }

    private func rememberProjectSelection(_ projectID: String) {
        guard let project = projects.first(where: { $0.id == projectID }) else { return }
        let rootID = project.worktreeOf ?? project.id
        lastActiveProjectIDByRoot[rootID] = projectID
    }

    // MARK: - Active Kind / Free Terminals

    /// Unified entry point for activating either a project or a free terminal.
    /// Caller must already be on the main thread.
    @discardableResult
    func activate(_ kind: ActiveKind) -> Bool {
        switch kind {
        case .project(let id):
            return activateProject(id: id)
        case .freeTerminal(let id):
            guard freeTerminals.contains(where: { $0.id == id }) else { return false }
            guard activeProjectID != nil || activeFreeTerminalID != id else { return true }
            guard permitsActiveContextChange() else { return false }

            activeProjectID = nil
            activeFreeTerminalID = id
            // Free terminals are session-scoped; nothing to persist.
            return true
        }
    }

    func registerActiveContextChangeApprover(
        id: UUID,
        _ approver: @escaping () -> Bool
    ) {
        activeContextChangeApprovers[id] = approver
    }

    func unregisterActiveContextChangeApprover(id: UUID) {
        activeContextChangeApprovers.removeValue(forKey: id)
    }

    @discardableResult
    func addFreeTerminal() -> FreeTerminalItem {
        let item = FreeTerminalItem()
        freeTerminals.append(item)
        return item
    }

    /// Refuses to remove the last remaining free terminal (UI never shows the
    /// close button in that case, but guard at the model layer too).
    func removeFreeTerminal(id: UUID) {
        guard freeTerminals.count > 1 else { return }
        guard freeTerminals.contains(where: { $0.id == id }) else { return }
        if activeFreeTerminalID == id {
            guard permitsActiveContextChange() else { return }
        }

        freeTerminals.removeAll { $0.id == id }
        if activeFreeTerminalID == id, let next = freeTerminals.first {
            activeFreeTerminalID = next.id
        }
    }

    private func seedDefaultFreeTerminalIfNeeded() {
        if freeTerminals.isEmpty {
            _ = addFreeTerminal()
        }
    }

    private func detectBranchPrefix(for projectID: String) {
        guard let project = projects.first(where: { $0.id == projectID }) else { return }
        // Find root project
        let rootID = project.isWorktree ? (project.worktreeOf ?? projectID) : projectID
        guard let rootIndex = projects.firstIndex(where: { $0.id == rootID }) else { return }

        // Already detected
        if projects[rootIndex].branchPrefix != nil { return }

        let rootURL = projects[rootIndex].url
        Task {
            let git = GitService(workingDirectory: rootURL)
            let username = await git.remoteUsername()
                ?? NSFullUserName().lowercased().replacingOccurrences(of: " ", with: "")

            await MainActor.run {
                guard let idx = self.projects.firstIndex(where: { $0.id == rootID }) else { return }
                self.projects[idx].branchPrefix = username
                self.persist()
            }
        }
    }

    func removeProject(id: String) {
        guard projects.contains(where: { $0.id == id }) else { return }
        let childIDs = worktrees(for: id).map(\.id)
        if activeProjectID == id || childIDs.contains(activeProjectID ?? "") {
            guard permitsActiveContextChange() else { return }
        }

        projects.removeAll { $0.id == id || childIDs.contains($0.id) }

        if activeProjectID == id || childIDs.contains(activeProjectID ?? "") {
            activeProjectID = projects.first?.id
        }
        bookmarkStore.remove(projectID: id)
        childIDs.forEach { bookmarkStore.remove(projectID: $0) }
        persist()
    }

    // MARK: - Branch Tracking

    func updateProjectBranch(_ id: String, branch: String) {
        guard let index = projects.firstIndex(where: { $0.id == id }),
              projects[index].lastBranch != branch else { return }
        projects[index].lastBranch = branch
        persist()
    }

    // MARK: - Worktree Management

    func addWorktreeProject(parentID: String, path: String, branch: String) -> ProjectItem {
        if let existing = projects.first(where: { $0.path == path }) {
            return existing
        }

        return insertWorktreeProject(
            parentID: parentID,
            path: path,
            branch: branch,
            activate: false
        )
    }

    private func insertWorktreeProject(
        parentID: String,
        path: String,
        branch: String,
        activate: Bool
    ) -> ProjectItem {
        let item = ProjectItem(
            path: path,
            name: branch,
            worktreeOf: parentID,
            worktreeBranch: branch
        )
        projects.append(item)
        if activate {
            activeProjectID = item.id
        }
        let worktreeURL = URL(fileURLWithPath: path, isDirectory: true)
        bookmarkStore.save(projectID: item.id, url: worktreeURL)
        bookmarkStore.startAccessing(projectID: item.id)
        persist()
        return item
    }

    func removeWorktreeProject(id: String) {
        guard let worktree = projects.first(where: { $0.id == id }) else { return }
        if activeProjectID == id {
            guard permitsActiveContextChange() else { return }
        }

        let parentID = worktree.worktreeOf
        bookmarkStore.remove(projectID: id)
        projects.removeAll { $0.id == id }
        if activeProjectID == id {
            if let parentID, let parent = projects.first(where: { $0.id == parentID }) {
                activeProjectID = parent.id
            } else {
                activeProjectID = projects.first?.id
            }
        }
        persist()
    }

    /// Rename a worktree's local branch via `git branch -m`, then update the
    /// in-memory display name. Throws if git rejects the rename (name already
    /// exists, invalid characters, etc.) so the UI can surface the error
    /// instead of leaving the sidebar inconsistent with the repo.
    func renameWorktreeProject(id: String, newBranch: String) async throws {
        guard let project = projects.first(where: { $0.id == id }),
              project.isWorktree,
              let oldBranch = project.worktreeBranch else {
            throw NSError(
                domain: "openOwl.ProjectStore", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Not a worktree project, or branch unknown"]
            )
        }

        guard newBranch != oldBranch else { return }

        // Run `git branch -m` in the worktree's own checkout so git updates
        // the worktree's HEAD pointer atomically with the rename.
        let git = GitService(workingDirectory: URL(fileURLWithPath: project.path))
        try await git.renameBranch(from: oldBranch, to: newBranch)

        // Apply UI state only after git succeeded.
        if let index = projects.firstIndex(where: { $0.id == id }) {
            projects[index].name = newBranch
            projects[index].worktreeBranch = newBranch
            persist()
        }
    }

    // MARK: - Persistence

    private func load() {
        // 1) Try ~/.openowl/openowl.json
        if FileManager.default.fileExists(atPath: storeURL.path) {
            do {
                let data = try Data(contentsOf: storeURL)
                let store = try JSONDecoder().decode(StoreFile.self, from: data)
                projects = store.projects
                    .filter { Self.isReasonableProjectPath(URL(fileURLWithPath: $0.path)) }
                    .uniqued()
                if let activeID = store.activeProjectId,
                   projects.contains(where: { $0.id == activeID }) {
                    activeProjectID = activeID
                } else {
                    activeProjectID = projects.first?.id
                }
                return
            } catch {
                // The file exists but will not decode. Falling through to the
                // migration path leaves `projects` empty, and the first
                // `persist()` of the session then overwrites the only copy of
                // the user's project list — a transient read error turned into
                // permanent loss. Move it aside first so the original survives
                // whatever this session writes.
                AppLogger.log(
                    "project-store",
                    "load failed path=%@ error=%@",
                    storeURL.path,
                    error.localizedDescription
                )
                guard quarantineUnreadableStore(reason: error.localizedDescription) else {
                    isStoreUnreadable = true
                    return
                }
            }
        }

        // Restore security-scoped access for all loaded projects.
        // This re-establishes TCC authorization granted on previous launches without prompting.
        for project in projects {
            bookmarkStore.startAccessing(projectID: project.id)
        }

        guard storeURL == Self.productionStoreURL else { return }

        // 2) Migrate from UserDefaults (one-time)
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: "openowl.projects.store"),
           let decoded = try? JSONDecoder().decode([ProjectItem].self, from: data) {
            projects = decoded
                .filter { Self.isReasonableProjectPath(URL(fileURLWithPath: $0.path)) }
                .uniqued()
        } else {
            let paths = defaults.stringArray(forKey: "openowl.projects.paths") ?? []
            projects = paths
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
                .filter { Self.isReasonableProjectPath($0) }
                .map { ProjectItem(url: $0) }
                .uniqued()
        }

        let storedActive = defaults.string(forKey: "openowl.projects.active")
        if let storedActive, projects.contains(where: { $0.id == storedActive }) {
            activeProjectID = storedActive
        } else {
            activeProjectID = projects.first?.id
        }

        // Write to new file and clean up UserDefaults
        if !projects.isEmpty {
            persist()
            defaults.removeObject(forKey: "openowl.projects.store")
            defaults.removeObject(forKey: "openowl.projects.active")
            defaults.removeObject(forKey: "openowl.projects.paths")
        }
    }

    private func seedDefaultProjectIfNeeded() {
        guard projects.isEmpty else { return }
        let cwdURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        guard Self.isReasonableProjectPath(cwdURL) else { return }
        addOrActivateProject(cwdURL)
    }

    private static func isReasonableProjectPath(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let components = path.split(separator: "/")
        return components.count >= 3
    }

    /// Renames an undecodable store file out of the way and tells the user
    /// where it went, so the next `persist()` cannot destroy it.
    private func quarantineUnreadableStore(reason: String) -> Bool {
        let stamp = Int(Date().timeIntervalSince1970)
        let backup = storeURL
            .deletingLastPathComponent()
            .appendingPathComponent("openowl.json.corrupt-\(stamp)")
        do {
            try FileManager.default.moveItem(at: storeURL, to: backup)
        } catch {
            AppLogger.log("project-store", "quarantine failed error=%@", error.localizedDescription)
            unreadableStoreAlertPresenter(.quarantineFailed(
                reason: reason,
                storeURL: storeURL,
                error: error.localizedDescription
            ))
            return false
        }
        AppLogger.log("project-store", "quarantined unreadable store to %@", backup.path)
        unreadableStoreAlertPresenter(.quarantined(reason: reason, backupURL: backup))
        return true
    }

    private static func presentUnreadableStoreAlert(notice: UnreadableProjectStoreNotice) {
        DispatchQueue.main.async {
            guard NSApp?.isRunning == true else { return }

            let alert = NSAlert()
            alert.alertStyle = .warning
            switch notice {
            case .quarantined(let reason, let backupURL):
                alert.messageText = "Project list could not be read"
                alert.informativeText = """
                \(reason)

                The file was moved to \(backupURL.path) so it is not overwritten. openOwl started with an empty project list.
                """
            case .quarantineFailed(let reason, let storeURL, let error):
                alert.messageText = "Project list could not be protected"
                alert.informativeText = """
                \(reason)

                openOwl could not move \(storeURL.path) aside: \(error)

                The original file remains in place, and this session will not save project-list changes. Back up or repair the file, then restart openOwl.
                """
            }
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    private func persist() {
        guard !isStoreUnreadable else {
            AppLogger.log("project-store", "persist refused because store is unreadable")
            return
        }

        let store = StoreFile(projects: projects, activeProjectId: activeProjectID)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(store)
            let dir = storeURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: storeURL, options: .atomic)
        } catch {
            AppLogger.log("project-store", "persist failed error=%@", error.localizedDescription)
        }
    }

    private func permitsActiveContextChange() -> Bool {
        activeContextChangeApprovers.values.allSatisfy { $0() }
    }

}

private extension Array where Element == ProjectItem {
    func uniqued() -> [ProjectItem] {
        var seen: Set<String> = []
        return filter {
            let normalized = URL(fileURLWithPath: $0.path, isDirectory: true).standardizedFileURL.path
            return seen.insert(normalized).inserted
        }
    }
}
