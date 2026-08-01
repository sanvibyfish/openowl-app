import SwiftUI
import UserNotifications

@main
struct openOwlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var ghosttyManager: GhosttyAppManager
    @State private var workspaceStore = TerminalWorkspaceStore()
    @State private var projectStore: ProjectStore
    @State private var gitChangesStore = GitChangesStore()
    @State private var fileExplorerStore = FileExplorerStore()
    @State private var claudeStatusStore = ClaudeStatusStore()
    @State private var rightDockStore = RightDockStore()

    init() {
        Self.setupEnvironment()

        // ProjectStore loads projects and restores security-scoped bookmarks.
        // Working directory is passed directly to ghostty surface config via
        // TerminalPanel.workingDirectory — no need to change the app's process cwd
        // (which triggers macOS TCC prompts in dev builds).
        let store = ProjectStore()
        _projectStore = State(wrappedValue: store)
        _ghosttyManager = State(wrappedValue: GhosttyAppManager())
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(ghosttyManager)
                .environment(workspaceStore)
                .environment(projectStore)
                .environment(gitChangesStore)
                .environment(fileExplorerStore)
                .environment(claudeStatusStore)
                .environment(rightDockStore)
                .onAppear {
                    // Apply saved appearance preference (system/light/dark)
                    NSApp.appearance = AppAppearance.current.nsAppearance

                    appDelegate.workspaceStore = workspaceStore
                    appDelegate.ghosttyManager = ghosttyManager
                    appDelegate.projectStore = projectStore
                    appDelegate.rightDockStore = rightDockStore
                    appDelegate.fileExplorerStore = fileExplorerStore
                    workspaceStore.destroyPaneHandler = { [weak ghosttyManager] paneID in
                        ghosttyManager?.destroyPane(paneID)
                    }
                    workspaceStore.onContextDidChange = {
                        syncActiveProjectContext()
                    }
                    ghosttyManager.onPaneTitleChanged = { paneID, title in
                        workspaceStore.updateTitle(for: paneID, title: title)
                    }
                    ghosttyManager.onPanePwdChanged = { paneID, pwd in
                        workspaceStore.updatePanePwd(paneID: paneID, pwd: pwd)
                    }
                    ghosttyManager.onOpenUrl = { urlString in
                        handleTerminalOpenURL(urlString,
                            workspaceStore: workspaceStore,
                            rightDockStore: rightDockStore)
                    }
                    syncActiveProjectContext()
                    UpdateChecker.shared.checkOnLaunchIfNeeded()
                    claudeStatusStore.startPollingIfNeeded()
                }
                .onDisappear {
                    claudeStatusStore.stopPolling()
                    ghosttyManager.stopBackgroundTick()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                    ghosttyManager.startBackgroundTick()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    ghosttyManager.stopBackgroundTick()
                }
                .onChange(of: projectStore.activeProjectID) { _, _ in
                    syncActiveProjectContext()
                }
                .onChange(of: projectStore.activeFreeTerminalID) { _, _ in
                    syncActiveProjectContext()
                }
                .onChange(of: rightDockStore.isExpanded) { _, _ in
                    syncActiveProjectContext()
                }
                .onChange(of: rightDockStore.activeTab) { _, _ in
                    syncActiveProjectContext()
                }
                .onChange(of: gitChangesStore.statusSnapshot?.branch) { _, _ in
                    // Fires on branch change within the same repo (e.g. checkout)
                    updateActiveBranchLabel()
                }
                .onChange(of: gitChangesStore.statusSnapshot?.repositoryRoot) { _, _ in
                    // Fires when the repo root changes (e.g. switching projects that both
                    // have a 'main' branch — branch string alone wouldn't change, so we
                    // need this second observer to keep the sidebar label in sync).
                    updateActiveBranchLabel()
                }
                .frame(
                    minWidth: AppConstants.windowMinWidth,
                    minHeight: AppConstants.windowMinHeight
                )
        }
        .defaultSize(width: 1200, height: 800)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton()
            }
        }

        Settings {
            SettingsView()
        }

        Window("Update Available", id: "update") {
            UpdateAlertView()
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 400, height: 250)
    }

    private static func setupEnvironment() {
        setenv("TERM", AppConstants.termEnv, 1)

        // GHOSTTY_RESOURCES_DIR: ghostty needs this for terminfo, shell-integration, themes.
        // In dev builds, use the symlinked ghostty-resources in the project root.
        // In release builds, bundle resources inside the .app.
        if let resourcesInBundle = Bundle.main.resourcePath {
            for directoryName in ["ghostty", "ghostty-resources"] {
                let ghosttyRes = (resourcesInBundle as NSString).appendingPathComponent(directoryName)
                if FileManager.default.fileExists(atPath: ghosttyRes) {
                    setenv(AppConstants.ghosttyResourcesDirEnv, ghosttyRes, 1)
                    return
                }
            }
        }

        // Dev fallback: project root's ghostty-resources symlink
        let searchRoots = [
            (Bundle.main.bundlePath as NSString).deletingLastPathComponent,
            FileManager.default.currentDirectoryPath
        ]

        for root in searchRoots {
            var dir = root
            for _ in 0..<8 {
                let candidate = (dir as NSString).appendingPathComponent("ghostty-resources")
                if FileManager.default.fileExists(atPath: candidate) {
                    setenv(AppConstants.ghosttyResourcesDirEnv, candidate, 1)
                    return
                }
                let next = (dir as NSString).deletingLastPathComponent
                if next == dir { break }
                dir = next
            }
        }
    }

    @MainActor
    private func updateActiveBranchLabel() {
        guard let snapshot = gitChangesStore.statusSnapshot,
              let activeID = projectStore.activeProjectID,
              let activeURL = projectStore.activeProjectURL,
              snapshot.repositoryRoot.standardizedFileURL == activeURL.standardizedFileURL
        else { return }
        projectStore.updateProjectBranch(activeID, branch: snapshot.branch)
    }

    /// Resolve a URL/path string from ghostty's cmd+click action and, when
    /// it points to a local file, open it in the file explorer's editor
    /// area + reveal the dock. Returns `true` to suppress ghostty's
    /// default `NSWorkspace.open` (which would have routed the path to
    /// Finder or the user's default editor).
    @MainActor
    private func handleTerminalOpenURL(_ urlString: String,
                                       workspaceStore: TerminalWorkspaceStore,
                                       rightDockStore: RightDockStore) -> Bool {
        // External web URLs — let ghostty's default handler open them in
        // the system browser.
        if urlString.hasPrefix("http://") || urlString.hasPrefix("https://") {
            return false
        }

        let fileURL: URL?
        if urlString.hasPrefix("file://") {
            fileURL = URL(string: urlString)
        } else if urlString.hasPrefix("/") {
            fileURL = URL(fileURLWithPath: urlString)
        } else if let pwd = workspaceStore.activePaneWorkingDirectory {
            // Relative path — resolve against the focused pane's cwd so
            // `cmd+click foo/bar.swift` works after `cd`.
            fileURL = pwd.appendingPathComponent(urlString)
        } else {
            return false
        }

        guard let url = fileURL?.standardizedFileURL else { return false }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              !isDir.boolValue else {
            return false
        }

        let wasExpanded = rightDockStore.isExpanded && rightDockStore.activeTab == .files
        rightDockStore.expand(tab: .files)
        // When the dock was collapsed (or showing a different tab), FileExplorerView
        // is conditionally mounted by ContentView and its `onReceive` subscription
        // doesn't exist yet at this point in the runloop. Posting synchronously
        // would drop the notification. Defer one tick so SwiftUI has time to mount
        // the view and register its subscriber.
        let post = {
            NotificationCenter.default.post(
                name: .openFileFromTerminal,
                object: nil,
                userInfo: ["url": url]
            )
        }
        if wasExpanded {
            post()
        } else {
            DispatchQueue.main.async(execute: post)
        }
        return true
    }

    @MainActor
    private func syncActiveProjectContext() {
        // Terminal namespace follows the sidebar selection — projects bind to their
        // working directory, free terminals share the user's home as cwd.
        switch projectStore.activeKind {
        case .project(let id):
            workspaceStore.switchNamespace(.project(id))
        case .freeTerminal(let id):
            workspaceStore.switchNamespace(.freeTerminal(id))
        case .none:
            workspaceStore.switchNamespace(nil)
        }

        // Right dock follows the active terminal's cwd: project namespaces use
        // their fixed project URL; free-terminal tabs read the focused pane's
        // shell cwd (reported via OSC 7 → GHOSTTY_ACTION_PWD), so cd-ing in the
        // terminal automatically retargets file explorer + git changes.
        let cwd: URL?
        switch projectStore.activeKind {
        case .project:
            cwd = projectStore.activeProjectURL
        case .freeTerminal:
            // Fallback to $HOME until ghostty reports the shell's actual pwd
            // — without this, a free terminal opened before shell
            // integration emits OSC 7 would leave file explorer empty.
            cwd = workspaceStore.activePaneWorkingDirectory
                ?? FileManager.default.homeDirectoryForCurrentUser
        case .none:
            cwd = nil
        }
        guard let cwd, rightDockStore.isExpanded else { return }
        switch rightDockStore.activeTab {
        case .files:
            fileExplorerStore.setProject(cwd)
        case .git:
            gitChangesStore.setPreferredDirectory(cwd)
        }
    }
}
