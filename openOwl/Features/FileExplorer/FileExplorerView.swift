import AppKit
import SwiftUI
import CodeEditSourceEditor
import CodeEditLanguages
import CodeEditTextView

let editorConfiguration = SourceEditorConfiguration(
    appearance: .init(
        theme: EditorTheme(
            text: .init(color: AppPalette.ns.textPrimary),
            insertionPoint: AppPalette.ns.accent,
            invisibles: .init(color: AppEditorTheme.invisibles),
            background: AppPalette.ns.surface,
            lineHighlight: AppPalette.ns.elevated,
            selection: AppEditorTheme.selection,
            keywords: .init(color: AppEditorTheme.keyword),
            commands: .init(color: AppEditorTheme.command),
            types: .init(color: AppEditorTheme.type),
            attributes: .init(color: AppEditorTheme.attribute),
            variables: .init(color: AppEditorTheme.variable),
            values: .init(color: AppEditorTheme.value),
            numbers: .init(color: AppEditorTheme.number),
            strings: .init(color: AppEditorTheme.string),
            characters: .init(color: AppEditorTheme.character),
            comments: .init(color: AppEditorTheme.comment)
        ),
        font: .monospacedSystemFont(ofSize: 12, weight: .regular),
        wrapLines: true
    ),
    // Right dock is narrow: keep soft-wrap, kill chrome that steals width or
    // paints over the leading glyphs (fold ribbon sits in the gutter and was
    // covering the first characters of tree lines like `│   ├──`).
    layout: .init(
        additionalTextInsets: NSEdgeInsets(top: 2, left: 0, bottom: 2, right: 10)
    ),
    peripherals: .init(
        showGutter: true,
        showMinimap: false,
        showReformattingGuide: false,
        showFoldingRibbon: false
    )
)

/// Configuration used when a file is opened in "large file" mode: same visual
/// theme as `editorConfiguration` but read-only, so the user can browse the
/// content without forcing CodeEditSourceEditor's edit pipeline to run on a
/// many-megabyte buffer.
let readOnlyEditorConfiguration = SourceEditorConfiguration(
    appearance: editorConfiguration.appearance,
    behavior: .init(isEditable: false, isSelectable: true),
    layout: editorConfiguration.layout,
    peripherals: editorConfiguration.peripherals
)

// MARK: - Editor Tab

private struct EditorTab: Identifiable, Equatable {
    let url: URL
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

struct FileEditorSession: Codable, Equatable {
    var openFilePaths: [String]
    var activeFilePath: String?
}

/// A tab whose buffer could not be written. Carried out of the save routines so
/// the caller can decide whether to block the action that prompted the save.
struct SaveFailure {
    let url: URL
    let message: String
}

struct FileEditorDiskSignature: Equatable {
    let modifiedAt: Date?
    let fileSize: Int
    let fileIdentifier: UInt64?
}

enum FileEditorDiskSignatureProvider {
    static func signature(for url: URL) -> FileEditorDiskSignature? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        guard let fileSize = (attributes[.size] as? NSNumber)?.intValue,
              fileSize >= 0 else {
            return nil
        }
        return FileEditorDiskSignature(
            modifiedAt: attributes[.modificationDate] as? Date,
            fileSize: fileSize,
            fileIdentifier: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        )
    }
}

struct FileEditorReadRequest {
    let id: UUID
    let sessionGeneration: UUID
    let signature: FileEditorDiskSignature
}

enum FileEditorReloadCommitPolicy {
    static func shouldCommit(
        isTabOpen: Bool,
        isDirty: Bool,
        request: FileEditorReadRequest,
        currentRequestID: UUID?,
        currentSessionGeneration: UUID,
        currentDiskSignature: FileEditorDiskSignature?
    ) -> Bool {
        isTabOpen
            && !isDirty
            && request.id == currentRequestID
            && request.sessionGeneration == currentSessionGeneration
            && request.signature == currentDiskSignature
    }

    static func shouldRetry(
        isTabOpen: Bool,
        isDirty: Bool,
        request: FileEditorReadRequest,
        currentRequestID: UUID?,
        currentSessionGeneration: UUID,
        currentDiskSignature: FileEditorDiskSignature?
    ) -> Bool {
        isTabOpen
            && !isDirty
            && request.id == currentRequestID
            && request.sessionGeneration == currentSessionGeneration
            && currentDiskSignature != nil
            && request.signature != currentDiskSignature
    }
}

enum FileEditorAutomaticReadPolicy {
    static func allowsRead(
        fileSize: Int,
        isImage: Bool,
        hugeFileThreshold: Int,
        imageMaxBytes: Int
    ) -> Bool {
        isImage ? fileSize <= imageMaxBytes : fileSize < hugeFileThreshold
    }
}

enum FileEditorSessionPersistence {
    private static let defaultsKey = "openowl.fileExplorer.editorSessions.v1"
    private static var cache: [String: FileEditorSession]?

    static func projectKey(for projectURL: URL?) -> String? {
        projectURL?.standardizedFileURL.path
    }

    static func load(forProjectKey projectKey: String?, defaults: UserDefaults = .standard) -> FileEditorSession? {
        guard let projectKey else { return nil }
        return ensureLoaded(defaults: defaults)[projectKey]
    }

    static func save(_ session: FileEditorSession, forProjectKey projectKey: String?, defaults: UserDefaults = .standard) {
        guard let projectKey else { return }
        var all = ensureLoaded(defaults: defaults)
        let normalized = normalize(session)
        if normalized.openFilePaths.isEmpty {
            all.removeValue(forKey: projectKey)
        } else {
            all[projectKey] = normalized
        }
        cache = all
        flush(all, defaults: defaults)
    }

    static func normalize(_ session: FileEditorSession) -> FileEditorSession {
        var seen = Set<String>()
        let paths = session.openFilePaths.compactMap { path -> String? in
            let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { return nil }
            return normalized
        }
        let active = session.activeFilePath.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        }
        return FileEditorSession(
            openFilePaths: paths,
            activeFilePath: active.flatMap(paths.contains) == true ? active : paths.last
        )
    }

    private static func ensureLoaded(defaults: UserDefaults) -> [String: FileEditorSession] {
        if let cache { return cache }
        guard let data = defaults.data(forKey: defaultsKey) else {
            cache = [:]
            return [:]
        }
        do {
            let decoded = try JSONDecoder().decode([String: FileEditorSession].self, from: data)
            cache = decoded
            return decoded
        } catch {
            AppLogger.log("file-editor-state", "decode-failed error=%@ dataSize=%d", String(describing: error), data.count)
            defaults.set(data, forKey: defaultsKey + ".corrupt-backup")
            cache = [:]
            return [:]
        }
    }

    private static func flush(_ sessions: [String: FileEditorSession], defaults: UserDefaults) {
        if sessions.isEmpty {
            defaults.removeObject(forKey: defaultsKey)
            return
        }
        do {
            let data = try JSONEncoder().encode(sessions)
            defaults.set(data, forKey: defaultsKey)
        } catch {
            AppLogger.log("file-editor-state", "encode-failed error=%@ sessionCount=%d", String(describing: error), sessions.count)
        }
    }
}

// MARK: - Bounds observer (AppKit → SwiftUI)

/// Reports NSView bounds after AppKit layout — more reliable than GeometryReader
/// alone when the host RightDock animates from width 0.
private struct EditorBoundsObserver: NSViewRepresentable {
    var onChange: (CGSize) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = LayoutWatchView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? LayoutWatchView)?.onChange = onChange
    }

    private final class LayoutWatchView: NSView {
        var onChange: ((CGSize) -> Void)?
        private var last: CGSize = .zero

        override func layout() {
            super.layout()
            let size = bounds.size
            guard abs(size.width - last.width) > 0.5
                    || abs(size.height - last.height) > 0.5 else { return }
            last = size
            onChange?(size)
        }
    }
}

// MARK: - Dirty Tracking Coordinator

/// Detects text changes in SourceEditor and marks the active tab as dirty.
///
/// Also pins the **wrap width** for the right dock. CodeEdit wraps at
/// `viewport.width − layoutManager.edgeInsets.horizontal`, and in the dock the
/// first layout can run while the host is still collapsed at width 0 — baking a
/// wrap point of a few glyphs that never recovers on its own.
private class EditTracker: TextViewCoordinator {
    var onTextChanged: (() -> Void)?
    weak var controller: TextViewController?

    /// Last host width we applied — avoids redundant work during live resize.
    private var lastAppliedHostWidth: CGFloat = -1

    func prepareCoordinator(controller: TextViewController) {
        self.controller = controller
        // The bounds observer can fire before this runs, while `controller` is
        // still nil, so the first pass has to come from here.
        DispatchQueue.main.async { [weak self] in
            self?.relayout()
        }
    }

    /// Re-pin insets and re-wrap against the host's current width. Cheap to
    /// over-call: a width we already applied returns immediately.
    func relayout() {
        guard let controller, let textView = controller.textView else { return }
        controller.view.layoutSubtreeIfNeeded()
        let hostWidth = controller.view.bounds.width
        guard hostWidth >= 100 else {
            // Collapsed dock or pre-layout: forget the applied width so the next
            // real one re-applies. Expanding back to the same width would
            // otherwise dedupe away, leaving wrap baked at the collapsed size.
            lastAppliedHostWidth = -1
            return
        }
        if abs(hostWidth - lastAppliedHostWidth) < 1 { return }
        lastAppliedHostWidth = hostWidth

        // Leading = gutter; trailing = small dock padding. Wrap width is
        // viewport − left − right, so this is the only right inset.
        let leading = max(textView.textInsets.left, 40)
        let trailingPadding: CGFloat = 14
        textView.textInsets = HorizontalEdgeInsets(left: leading, right: trailingPadding)
        textView.lineBreakStrategy = .word

        // Match text view width to the real host, then re-wrap.
        if abs(textView.frame.width - hostWidth) > 0.5 {
            textView.frame.size.width = hostWidth
        }
        _ = textView.updateFrameIfNeeded()
        textView.layoutManager.setNeedsLayout()
        _ = textView.layoutManager.layoutLines()
        textView.needsLayout = true
        textView.needsDisplay = true
    }

    func textViewDidChangeText(controller: TextViewController) {
        onTextChanged?()
    }

    func textViewDidChangeSelection(controller: TextViewController, newPositions: [CursorPosition]) {}

    func destroy() {
        // Deliberately does NOT clear `controller`. One EditTracker is shared by
        // every tab's editor, and `.id(storage)` rebuilds on tab switch — SwiftUI
        // registers the incoming controller before tearing the outgoing one down,
        // so clearing here would null out the live controller and `relayout()`
        // would silently no-op forever. `controller` is weak; the dying instance
        // drops out on its own.
        //
        // Resetting the width is still required: without it the incoming editor
        // gets deduped away at an identical host width and never has its insets
        // applied.
        lastAppliedHostWidth = -1
    }
}

// MARK: - FileExplorerView

struct FileExplorerView: View {
    @Environment(FileExplorerStore.self) private var store
    @Environment(ProjectStore.self) private var projectStore
    @Environment(GitChangesStore.self) private var gitStore
    @Environment(RightDockStore.self) private var rightDockStore

    // Tab management
    @State private var editorInstanceID = UUID()
    @State private var openTabs: [EditorTab] = []
    @State private var activeTabURL: URL?
    @State private var tabStorages: [URL: NSTextStorage] = [:]
    @State private var tabImageCache: [URL: NSImage] = [:]
    @State private var tabDiskSignatures: [URL: FileEditorDiskSignature] = [:]
    @State private var fileReadRequestIDs: [URL: UUID] = [:]
    @State private var editorSessionGeneration = UUID()
    @State private var dirtyTabs: Set<URL> = []
    @State private var editorSessionProjectKey: String?
    @State private var persistDebounceWork: DispatchWorkItem?

    /// Tabs currently in large-file mode: syntax highlighting off, read-only.
    /// User can lift this per-tab via the "Enable Anyway" banner.
    @State private var largeModeTabs: Set<URL> = []

    /// URLs whose huge-file confirmation dialog is currently displayed.
    /// `NSAlert.runModal()` nests an event loop that lets `.onChange(of:
    /// selectedNodeID)` schedule a second `openFileInTab` call mid-modal —
    /// without this guard the user gets two stacked dialogs for one click.
    @State private var hugeFilePending: Set<URL> = []

    /// Non-nil while a synchronous main-thread operation is expected to take
    /// long enough to look like a freeze (NSLayoutManager build/teardown for
    /// large-mode tabs). Drives a centered ProgressView overlay on the editor
    /// panel so the user knows the app is busy, not crashed.
    @State private var heavyProgressText: String? = nil
    @State private var heavyProgressURL: URL?

    // Editor state
    @State private var editorState = SourceEditorState()
    @State private var previewImage: NSImage?
    @State private var isEditorLoading = false
    @State private var pendingActivationURL: URL?

    // Dirty tracking coordinator (shared across tab switches)
    @State private var editTracker = EditTracker()

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "webp", "heic", "heif", "ico", "svg", "icns"
    ]

    /// Cap on simultaneously open tabs. Beyond this, the oldest non-active,
    /// non-dirty tab is evicted to release its NSTextStorage / NSImage and
    /// keep memory bounded across long editing sessions.
    private static let maxOpenTabs = 10

    /// Files at or above this size open in "large file" mode: tree-sitter is
    /// bypassed (`CodeLanguage.default` returns no parser) and the editor is
    /// read-only. User can override per-tab via the "Enable Anyway" banner.
    /// Mirrors VS Code's `LARGE_FILE_SIZE_THRESHOLD` (20 MB); we pick 10 MB to
    /// stay conservative while easily covering hunspell dictionaries / configs.
    private static let largeFileThreshold: Int = 10_000_000

    /// Files at or above this size require explicit confirmation before
    /// opening. They are pinned to large-file mode (Enable Anyway is still
    /// available, but the user has been warned).
    private static let hugeFileThreshold: Int = 50_000_000

    /// NSImage decode for huge images is unbounded; cap at the same threshold.
    private static let imageMaxBytes: Int = 50_000_000

    private var isActiveTabImage: Bool {
        guard let url = activeTabURL else { return false }
        return isImageURL(url)
    }

    @State private var treePanelWidth: CGFloat = 240

    var body: some View {
        HStack(spacing: 0) {
            if rightDockStore.filesShowsTree && rightDockStore.filesShowsEditor {
                treePanel
                    .frame(width: treePanelWidth)

                treePanelDivider

                editorPanel
            } else if rightDockStore.filesShowsTree {
                treePanel
                    .frame(maxWidth: .infinity)
            } else {
                editorOnlyPanel
            }
        }
        .onAppear(perform: handleAppear)
        .onChange(of: projectStore.activeKind) { _, _ in
            handleActiveContextChange()
        }
        .onChange(of: store.selectedNodeID) { _, newID in
            handleSelectedNodeChange(newID)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openFileFromTerminal)) { notification in
            handleOpenFileNotification(notification)
        }
        .onChange(of: dirtyTabs) { _, _ in
            // Publishing names rather than URLs keeps the quit prompt readable
            // and avoids handing the store anything it could act on.
            publishUnsavedTabNames()
        }
        .onDisappear(perform: handleDisappear)
        // Shortcuts are gated on right-dock visibility — without this gate, Cmd+S / Cmd+W
        // would fire even while the dock is closed or showing a different tab (the view
        // stays mounted for @State preservation, see RightDockView).
        .background {
            if rightDockStore.isExpanded && rightDockStore.activeTab == .files {
                Button("") { saveCurrentTab() }
                    .keyboardShortcut("s", modifiers: [.command])
                    .hidden()
            }
        }
        .background {
            if rightDockStore.isExpanded && rightDockStore.activeTab == .files, !openTabs.isEmpty {
                Button("") { closeActiveTab() }
                    .keyboardShortcut("w", modifiers: [.command])
                    .hidden()
            }
        }
    }

    private func setupEditTracker() {
        editTracker.onTextChanged = { [editTracker] in
            // editTracker captured to keep reference alive; only using self's state
            _ = editTracker
            if let url = activeTabURL, !isEditorLoading {
                dirtyTabs.insert(url)
            }
        }
    }

    private func handleAppear() {
        projectStore.registerActiveContextChangeApprover(
            id: editorInstanceID,
            approveActiveContextChange
        )
        store.setProject(projectStore.activeProjectURL)
        setupEditTracker()
        publishUnsavedTabNames()
        restoreEditorSession(for: projectStore.activeProjectURL, reason: "appear")
    }

    private func handleActiveContextChange() {
        flushEditorSession(reason: "context-switch-out")
        store.setProject(projectStore.activeProjectURL)
        clearEditorTabs(reason: "context-switch", persist: false)
        restoreEditorSession(for: projectStore.activeProjectURL, reason: "context-switch-in")
    }

    private func handleSelectedNodeChange(_ newID: String?) {
        // Auto-open file when selected externally (e.g. QuickOpen).
        // Defer state mutations to avoid "modifying state during view update".
        guard let newID,
              let node = store.nodeIndex[newID],
              !node.isDirectory else { return }
        Task { @MainActor in
            openFileInTab(node)
        }
    }

    private func handleOpenFileNotification(_ notification: Notification) {
        guard let url = notification.userInfo?["url"] as? URL else { return }
        openFileInTab(url: url)
        // If this file is inside the loaded tree, highlight it; otherwise
        // leave the tree alone (we don't want cmd+click to retarget the
        // explorer root).
        if store.nodeIndex[url.path] != nil {
            store.selectNode(url.path)
        }
    }

    private func handleDisappear() {
        let saveFailures = saveAllDirtyTabs()
        flushEditorSession(reason: "disappear")
        store.removeUnsavedTabNames(for: editorInstanceID)
        projectStore.unregisterActiveContextChangeApprover(id: editorInstanceID)
        if !saveFailures.isEmpty {
            presentSaveFailureAlert(saveFailures)
        }
    }

    private func approveActiveContextChange() -> Bool {
        let failures = saveAllDirtyTabs()
        publishUnsavedTabNames()
        guard failures.isEmpty else {
            presentSaveFailureAlert(failures)
            return false
        }
        return true
    }

    private func publishUnsavedTabNames() {
        store.publishUnsavedTabNames(
            dirtyTabs.map(\.lastPathComponent).sorted(),
            for: editorInstanceID
        )
    }

    // MARK: - Tree Panel

    private var treePanel: some View {
        VStack(spacing: 0) {
            // Tool strip — same flat base as the outline tree so the left
            // Files column reads as one surface (not a second elevated slab).
            HStack(spacing: 2) {
                Spacer(minLength: 0)

                Button { store.presentQuickOpen() } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.icon(font: AppFonts.toolbarIcon, size: 24))
                .help("Quick Open (⌘P)")
                .accessibilityLabel("Quick Open (⌘P)")
                .disabled(store.rootNodes.isEmpty)

                Button { store.refreshNow() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.icon(font: AppFonts.toolbarIcon, size: 24))
                .help("Refresh")
                .accessibilityLabel("Refresh")
                .disabled(store.isRefreshing)

                Button {
                    rightDockStore.filesShowsTree = false
                    rightDockStore.filesShowsEditor = true
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .buttonStyle(.icon(font: AppFonts.toolbarIcon, size: 24))
                .help("Editor only")
                .accessibilityLabel("Editor only")
                .disabled(!rightDockStore.filesShowsEditor || openTabs.isEmpty)

                Button { rightDockStore.filesShowsEditor.toggle() } label: {
                    Image(systemName: rightDockStore.filesShowsEditor
                        ? "square.lefthalf.filled"
                        : "square.split.2x1")
                }
                .buttonStyle(.icon(
                    isActive: rightDockStore.filesShowsEditor,
                    font: AppFonts.toolbarIcon,
                    size: 24
                ))
                .help(rightDockStore.filesShowsEditor ? "Hide editor" : "Show editor")
                .accessibilityLabel(rightDockStore.filesShowsEditor ? "Hide editor" : "Show editor")
            }
            .padding(.horizontal, 6)
            .panelToolHeader(background: AppPalette.base)

            errorBanner

            if store.rootNodes.isEmpty {
                Spacer()
                EmptyStateView(
                    "No files",
                    subtitle: "Open a project to browse files",
                    systemImage: "folder",
                    density: .compact
                )
                Spacer()
            } else {
                OutlineTreeView(
                    onSelectFile: { node in
                        store.selectNode(node.id)
                        // Picking a file in list-only mode auto-expands the editor —
                        // otherwise the click would be a silent no-op.
                        if !rightDockStore.filesShowsEditor {
                            rightDockStore.filesShowsEditor = true
                        }
                        openFileInTab(node)
                    },
                    onStage: { node in stageFile(node) },
                    onDiscard: { node in discardFile(node) },
                    onOpenDiff: { node in
                        // Same auto-expand for the diff entry point.
                        if !rightDockStore.filesShowsEditor {
                            rightDockStore.filesShowsEditor = true
                        }
                        openDiff(node)
                    },
                    onDelete: { urls in store.deleteNodes(urls) },
                    onRename: { node, newName in store.renameNode(node, to: newName) },
                    onCopy: { urls in store.copyFiles(urls) },
                    onCut: { urls in store.cutFiles(urls) },
                    onPaste: { targetDir in store.pasteFiles(into: targetDir) },
                    onCopyPath: { url in store.copyPath(url) },
                    onDropFiles: { targetDir, sourceURLs in
                        let fm = FileManager.default
                        var failures: [String] = []
                        for url in sourceURLs {
                            let dest = targetDir.appendingPathComponent(url.lastPathComponent)
                            do {
                                try fm.copyItem(at: url, to: dest)
                            } catch {
                                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                            }
                        }
                        if !failures.isEmpty {
                            store.errorMessage = failures.joined(separator: "；")
                        }
                        store.refreshNow()
                    },
                    onExpandDirectory: { path in store.expandDirectory(path) }
                )
            }
        }
        // Semantic palette, not .regularMaterial — the blurred material read as
        // a foreign slab against the dock's flat base/surface/elevated layers.
        .background(AppPalette.base)
    }

    // MARK: - Editor Only Panel

    private var editorOnlyPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                Button {
                    rightDockStore.filesShowsTree = true
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .buttonStyle(.icon(font: AppFonts.toolbarIcon, size: 24))
                .help("Show explorer")
                .accessibilityLabel("Show explorer")
                .padding(.leading, 4)

                if !openTabs.isEmpty {
                    editorTabBarContent
                } else {
                    Spacer()
                }
            }
            .panelToolHeader(height: AppSpacing.editorTabBarHeight, background: AppPalette.elevated)

            errorBanner

            ZStack {
                editorContentArea
                heavyProgressOverlay
            }
        }
    }

    @ViewBuilder
    private var heavyProgressOverlay: some View {
        if let text = heavyProgressText {
            Color.black.opacity(0.22)
                .overlay {
                    VStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.large)
                        Text(text)
                            .font(AppFonts.caption)
                            .foregroundStyle(AppPalette.textSecondary)
                    }
                    .padding(20)
                    .background(AppPalette.elevated)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(AppPalette.border, lineWidth: 1)
                    )
                }
        }
    }

    // MARK: - Editor Panel

    private var editorPanel: some View {
        ZStack {
            editorPanelContent
            heavyProgressOverlay
        }
    }

    /// Rendered by both the tree panel and the editor-only panel. It used to
    /// live inside the tree, so with the tree hidden — the mode people edit in
    /// longest, and therefore the one most likely to hit a save failure — open,
    /// reload and save errors were reported to a view that was never built.
    @ViewBuilder
    private var errorBanner: some View {
        if let errorMessage = store.errorMessage {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(AppFonts.toolbarIcon)
                Text(errorMessage).font(AppFonts.caption)
                Spacer()
                Button { store.errorMessage = nil } label: {
                    Image(systemName: "xmark").font(AppFonts.tinyIcon)
                }.buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            .foregroundStyle(.red)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.red.opacity(0.12))
        }
    }

    private var editorPanelContent: some View {
        VStack(spacing: 0) {
            if !openTabs.isEmpty {
                editorTabBar
            }

            editorContentArea
        }
    }

    @ViewBuilder
    private var editorContentArea: some View {
        if let url = activeTabURL {
            if isActiveTabImage, let image = previewImage {
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .background(AppPalette.base)
            } else if !isActiveTabImage, let storage = tabStorages[url] {
                let isLargeMode = largeModeTabs.contains(url)
                VStack(spacing: 0) {
                    if isLargeMode {
                        largeFileBanner(for: url)
                    }
                    // Stays mounted even while the dock is collapsed (host width
                    // 0). Unmounting there would rebuild the editor on every
                    // expand, and rebuilding clears undo — see the .id note.
                    SourceEditor(
                        storage,
                        language: isLargeMode ? CodeLanguage.default : editorLanguage(for: url),
                        configuration: isLargeMode ? readOnlyEditorConfiguration : editorConfiguration,
                        state: $editorState,
                        coordinators: [editTracker]
                    )
                    // Identity tracks the storage object, not the file on disk.
                    // A reload swaps in a new NSTextStorage and must rebuild the
                    // editor around it; a save leaves the object alone and must
                    // not — `write(atomically:)` replaces the inode, so keying
                    // this on the disk signature rebuilt the editor on every ⌘S
                    // and `setTextStorage` cleared the undo stack each time.
                    .id(ObjectIdentifier(storage))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    // Sole re-wrap trigger: AppKit reports real bounds after it
                    // finishes layout, which covers dock expand, drag-resize and
                    // tab switch without racing SwiftUI's timing.
                    .background(
                        EditorBoundsObserver { _ in
                            editTracker.relayout()
                        }
                    )
                }
            }
        } else {
            Spacer()
            EmptyStateView(
                "Select a file to edit",
                subtitle: "Click a file in the explorer or use ⌘P",
                systemImage: "doc.text",
                density: .compact
            )
            .frame(maxWidth: .infinity)
            Spacer()
        }
    }

    // MARK: - Resizable Divider

    @State private var dragStartWidth: CGFloat?

    private var treePanelDivider: some View {
        Rectangle()
            .fill(AppPalette.border)
            .frame(width: 1)
            .overlay {
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                if dragStartWidth == nil { dragStartWidth = treePanelWidth }
                                let newWidth = (dragStartWidth ?? 240) + value.translation.width
                                treePanelWidth = min(max(newWidth, 150), 500)
                            }
                            .onEnded { _ in dragStartWidth = nil }
                    )
            }
    }

    // MARK: - Tab Bar

    /// Tab pills only — used inside chrome-bearing headers so we don't stack
    /// elevated backgrounds / hairlines twice (editor-only mode).
    private var editorTabBarContent: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(openTabs) { tab in
                    EditorTabButton(
                        tab: tab,
                        isActive: tab.url == activeTabURL,
                        isDirty: dirtyTabs.contains(tab.url),
                        onSelect: { switchToTab(tab.url) },
                        onClose: { closeTab(tab.url) }
                    )
                }
            }
            .padding(.horizontal, 6)
        }
    }

    private var editorTabBar: some View {
        editorTabBarContent
            .panelToolHeader(height: AppSpacing.editorTabBarHeight, background: AppPalette.elevated)
    }

    // MARK: - Tab Management

    private func openFileInTab(_ node: FileExplorerNode) {
        guard !node.isDirectory else { return }
        openFileInTab(url: node.url)
    }

    /// URL-based overload — used by `cmd+click` from the terminal, where we
    /// have a file path but not necessarily a tree node (the file may live
    /// outside the current explorer root). Selects the tree node only if
    /// the file is already inside the loaded tree; otherwise just opens
    /// the editor tab without disturbing the tree.
    private func openFileInTab(url: URL) {
        // Already-modal de-dupe: a runModal() above is currently waiting on
        // user input for this URL, ignore re-entrant calls (see hugeFilePending
        // doc comment for the SwiftUI / nested-event-loop interaction).
        if hugeFilePending.contains(url) { return }

        // Already open — switch and refresh from disk if the backing file changed.
        // Dirty tabs keep the in-memory buffer to avoid clobbering user edits.
        if openTabs.contains(where: { $0.url == url }) {
            if activeTabURL != url {
                switchToTab(url)
            } else {
                reloadOpenTabFromDiskIfNeeded(url, reason: "reopen-active")
            }
            return
        }

        guard let fileSize = fileSize(for: url) else {
            AppLogger.log("file-editor-state", "open-skip reason=size-unknown path=%@", url.path)
            store.errorMessage = "Could not read the size of \(url.lastPathComponent) — it may have been moved or its permissions changed."
            return
        }

        let isImage = isImageURL(url)
        let needsLargeMode = !isImage && fileSize >= Self.largeFileThreshold

        // Huge files (>= 50 MB) require explicit confirmation. Skip the prompt
        // for images — NSImage handles its own decoding cost and we cap them
        // by `imageMaxBytes` below.
        if !isImage && !FileEditorAutomaticReadPolicy.allowsRead(
            fileSize: fileSize,
            isImage: false,
            hugeFileThreshold: Self.hugeFileThreshold,
            imageMaxBytes: Self.imageMaxBytes
        ) {
            hugeFilePending.insert(url)
            defer { hugeFilePending.remove(url) }

            let alert = NSAlert()
            alert.messageText = "Open large file?"
            alert.informativeText = """
            \(url.lastPathComponent) is \(Self.formattedSize(fileSize)).
            It will open in plain-text, read-only mode without syntax highlighting.
            """
            alert.addButton(withTitle: "Open")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        if isImage && !FileEditorAutomaticReadPolicy.allowsRead(
            fileSize: fileSize,
            isImage: true,
            hugeFileThreshold: Self.hugeFileThreshold,
            imageMaxBytes: Self.imageMaxBytes
        ) {
            AppLogger.log("file-editor-state", "open-skip reason=image-too-large path=%@ size=%d",
                          url.path, fileSize)
            return
        }

        evictOldestTabIfNeeded()

        // Add new tab
        openTabs.append(EditorTab(url: url))
        pendingActivationURL = url
        isEditorLoading = true
        if needsLargeMode {
            largeModeTabs.insert(url)
        }
        persistEditorSession(reason: "open-tab", activeOverride: url)
        AppLogger.log("file-editor-state", "open-tab path=%@ tabs=%d", url.path, openTabs.count)

        startOpeningFileContent(url, needsLargeMode: needsLargeMode)
    }

    private func startOpeningFileContent(
        _ url: URL,
        needsLargeMode: Bool,
        signature: FileEditorDiskSignature? = nil
    ) {
        guard let request = beginFileRead(for: url, signature: signature) else {
            // The tab is already in `openTabs` and persisted; without taking it
            // back down the user gets a tab that shows nothing and never will.
            failFileRead(
                url,
                closingTab: true,
                persistRemoval: true,
                reason: "open-stat-failed",
                message: "Could not read \(url.lastPathComponent) — it may have been moved or its permissions changed."
            )
            return
        }
        pendingActivationURL = url

        if isImageURL(url) {
            Task.detached(priority: .userInitiated) {
                let image = NSImage(contentsOf: url)
                await MainActor.run {
                    let currentSignature = FileEditorDiskSignatureProvider.signature(for: url)
                    guard FileEditorReloadCommitPolicy.shouldCommit(
                        isTabOpen: openTabs.contains(where: { $0.url == url })
                            && pendingActivationURL == url,
                        isDirty: dirtyTabs.contains(url),
                        request: request,
                        currentRequestID: fileReadRequestIDs[url],
                        currentSessionGeneration: editorSessionGeneration,
                        currentDiskSignature: currentSignature
                    ) else {
                        handleRejectedFileRead(
                            url,
                            request: request,
                            currentDiskSignature: currentSignature,
                            isEligible: pendingActivationURL == url,
                            retry: { latestSignature in
                                startOpeningFileContent(
                                    url,
                                    needsLargeMode: needsLargeMode,
                                    signature: latestSignature
                                )
                            },
                            onReject: {
                                if pendingActivationURL == url { pendingActivationURL = nil }
                                isEditorLoading = false
                            }
                        )
                        return
                    }
                    guard let image else {
                        failFileRead(
                            url,
                            closingTab: true,
                            persistRemoval: true,
                            reason: "open-image-decode-failed",
                            message: "Could not open \(url.lastPathComponent) — the image could not be decoded."
                        )
                        return
                    }
                    tabImageCache[url] = image
                    tabDiskSignatures[url] = request.signature
                    fileReadRequestIDs.removeValue(forKey: url)
                    previewImage = image
                    activeTabURL = url
                    if pendingActivationURL == url { pendingActivationURL = nil }
                    isEditorLoading = false
                }
            }
        } else {
            Task.detached(priority: .userInitiated) {
                let content: String
                do {
                    content = try String(contentsOf: url, encoding: .utf8)
                } catch {
                    // Never substitute an empty buffer here. The tab would
                    // commit, the signature check would still pass (the file on
                    // disk never changed), and the first ⌘S would truncate the
                    // real file to whatever the user typed into what looks like
                    // an empty document. Permission denied, a file deleted
                    // between stat and read, and non-UTF-8 content all land here.
                    await MainActor.run {
                        guard isCurrentFileRead(request, for: url) else { return }
                        failFileRead(
                            url,
                            closingTab: true,
                            persistRemoval: true,
                            reason: "open-read-failed",
                            message: "Could not open \(url.lastPathComponent): \(error.localizedDescription)"
                        )
                    }
                    return
                }
                let storage = NSTextStorage(string: content)

                // Show the progress overlay BEFORE committing the new tab —
                // assigning `activeTabURL` synchronously triggers SourceEditor
                // / NSLayoutManager to build line layout for the entire
                // buffer, blocking the main thread for several seconds on
                // large files. The 50ms sleep yields one SwiftUI render cycle
                // so the spinner actually paints before the freeze.
                if needsLargeMode {
                    await MainActor.run {
                        guard isCurrentFileRead(request, for: url) else { return }
                        setHeavyProgress("Loading \(url.lastPathComponent)…", for: url)
                    }
                    try? await Task.sleep(for: .milliseconds(50))
                }

                await MainActor.run {
                    let currentSignature = FileEditorDiskSignatureProvider.signature(for: url)
                    guard FileEditorReloadCommitPolicy.shouldCommit(
                        isTabOpen: openTabs.contains(where: { $0.url == url })
                            && pendingActivationURL == url,
                        isDirty: dirtyTabs.contains(url),
                        request: request,
                        currentRequestID: fileReadRequestIDs[url],
                        currentSessionGeneration: editorSessionGeneration,
                        currentDiskSignature: currentSignature
                    ) else {
                        handleRejectedFileRead(
                            url,
                            request: request,
                            currentDiskSignature: currentSignature,
                            isEligible: pendingActivationURL == url,
                            retry: { latestSignature in
                                startOpeningFileContent(
                                    url,
                                    needsLargeMode: needsLargeMode,
                                    signature: latestSignature
                                )
                            },
                            onReject: {
                                clearHeavyProgress(for: url)
                                if pendingActivationURL == url { pendingActivationURL = nil }
                                isEditorLoading = false
                            }
                        )
                        return
                    }
                    tabStorages[url] = storage
                    tabDiskSignatures[url] = request.signature
                    fileReadRequestIDs.removeValue(forKey: url)
                    previewImage = nil
                    editorState = SourceEditorState()
                    activeTabURL = url
                    if pendingActivationURL == url { pendingActivationURL = nil }
                    if needsLargeMode {
                        clearHeavyProgress(for: url)
                    }
                }
                try? await Task.sleep(for: .milliseconds(50))
                await MainActor.run {
                    guard editorSessionGeneration == request.sessionGeneration,
                          activeTabURL == url,
                          pendingActivationURL == nil else { return }
                    isEditorLoading = false
                }
            }
        }
    }

    private func restoreEditorSession(for projectURL: URL?, reason: String) {
        let projectKey = FileEditorSessionPersistence.projectKey(for: projectURL)
        if editorSessionProjectKey == projectKey, !openTabs.isEmpty {
            AppLogger.log("file-editor-state", "restore-skip reason=already-loaded project=%@",
                          projectKey ?? "nil")
            return
        }

        editorSessionProjectKey = projectKey
        clearEditorTabs(reason: "restore-reset", persist: false)

        guard let projectKey else {
            AppLogger.log("file-editor-state", "restore-skip reason=no-project")
            return
        }
        guard let session = FileEditorSessionPersistence.load(forProjectKey: projectKey) else {
            AppLogger.log("file-editor-state", "restore-empty project=%@", projectKey)
            return
        }

        let urls = restorableURLs(from: session, projectKey: projectKey)
        guard !urls.isEmpty else {
            FileEditorSessionPersistence.save(FileEditorSession(openFilePaths: [], activeFilePath: nil), forProjectKey: projectKey)
            AppLogger.log("file-editor-state", "restore-empty-after-filter project=%@", projectKey)
            return
        }

        openTabs = urls.map { EditorTab(url: $0) }
        largeModeTabs = Set(urls.filter { shouldOpenInLargeMode($0) })
        let activePath = session.activeFilePath
        let activeURL = urls.first { $0.standardizedFileURL.path == activePath } ?? urls.last
        activeTabURL = activeURL
        isEditorLoading = activeURL != nil
        previewImage = nil
        editorState = SourceEditorState()

        AppLogger.log("file-editor-state",
                      "restore project=%@ reason=%@ saved=%d restored=%d active=%@",
                      projectKey, reason, session.openFilePaths.count, urls.count, activeURL?.path ?? "nil")
        flushEditorSession(reason: "restore-sanitized")

        for url in urls {
            loadRestoredTabContent(url)
        }
    }

    private func restorableURLs(from session: FileEditorSession, projectKey: String) -> [URL] {
        let normalized = FileEditorSessionPersistence.normalize(session)
        var urls: [URL] = []
        for path in normalized.openFilePaths {
            guard urls.count < Self.maxOpenTabs else { break }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                AppLogger.log("file-editor-state", "restore-skip reason=missing project=%@ path=%@",
                              projectKey, url.path)
                continue
            }
            guard !isDirectory.boolValue else {
                AppLogger.log("file-editor-state", "restore-skip reason=directory project=%@ path=%@",
                              projectKey, url.path)
                continue
            }
            guard let fileSize = fileSize(for: url) else {
                AppLogger.log("file-editor-state", "restore-skip reason=size-unknown project=%@ path=%@",
                              projectKey, url.path)
                continue
            }
            let isImage = isImageURL(url)
            guard FileEditorAutomaticReadPolicy.allowsRead(
                fileSize: fileSize,
                isImage: isImage,
                hugeFileThreshold: Self.hugeFileThreshold,
                imageMaxBytes: Self.imageMaxBytes
            ) else {
                AppLogger.log(
                    "file-editor-state",
                    "restore-skip reason=automatic-read-limit project=%@ path=%@ size=%d",
                    projectKey,
                    url.path,
                    fileSize
                )
                continue
            }
            urls.append(url)
        }
        return urls
    }

    private func loadRestoredTabContent(
        _ url: URL,
        signature: FileEditorDiskSignature? = nil
    ) {
        guard let request = beginFileRead(for: url, signature: signature) else {
            failFileRead(
                url,
                closingTab: true,
                persistRemoval: false,
                reason: "restore-stat-failed",
                message: "Could not restore \(url.lastPathComponent) — it may have been moved or its permissions changed."
            )
            return
        }
        guard FileEditorAutomaticReadPolicy.allowsRead(
            fileSize: request.signature.fileSize,
            isImage: isImageURL(url),
            hugeFileThreshold: Self.hugeFileThreshold,
            imageMaxBytes: Self.imageMaxBytes
        ) else {
            failFileRead(
                url,
                closingTab: true,
                persistRemoval: false,
                reason: "restore-skip-automatic-read-limit",
                message: "Could not restore \(url.lastPathComponent) because it is too large to load automatically."
            )
            return
        }

        if isImageURL(url) {
            Task.detached(priority: .userInitiated) {
                let image = NSImage(contentsOf: url)
                await MainActor.run {
                    let currentSignature = FileEditorDiskSignatureProvider.signature(for: url)
                    guard FileEditorReloadCommitPolicy.shouldCommit(
                        isTabOpen: openTabs.contains(where: { $0.url == url }),
                        isDirty: dirtyTabs.contains(url),
                        request: request,
                        currentRequestID: fileReadRequestIDs[url],
                        currentSessionGeneration: editorSessionGeneration,
                        currentDiskSignature: currentSignature
                    ) else {
                        handleRejectedFileRead(
                            url,
                            request: request,
                            currentDiskSignature: currentSignature,
                            retry: { latestSignature in
                                loadRestoredTabContent(url, signature: latestSignature)
                            },
                            onReject: {
                                if activeTabURL == url {
                                    isEditorLoading = false
                                }
                            }
                        )
                        return
                    }
                    if let image {
                        tabImageCache[url] = image
                        tabDiskSignatures[url] = request.signature
                        fileReadRequestIDs.removeValue(forKey: url)
                        if activeTabURL == url {
                            previewImage = image
                            isEditorLoading = false
                        }
                    } else {
                        failFileRead(
                            url,
                            closingTab: true,
                            persistRemoval: false,
                            reason: "restore-image-failed",
                            message: "Could not restore \(url.lastPathComponent) — the image could not be decoded."
                        )
                    }
                }
            }
            return
        }

        let isLargeMode = largeModeTabs.contains(url)
        Task.detached(priority: .userInitiated) {
            let content: String
            do {
                content = try String(contentsOf: url, encoding: .utf8)
            } catch {
                await MainActor.run {
                    guard isCurrentFileRead(request, for: url) else { return }
                    failFileRead(
                        url,
                        closingTab: true,
                        persistRemoval: false,
                        reason: "restore-read-failed",
                        message: "Could not restore \(url.lastPathComponent): \(error.localizedDescription)"
                    )
                }
                return
            }
            let storage = NSTextStorage(string: content)

            if isLargeMode {
                await MainActor.run {
                    guard isCurrentFileRead(request, for: url),
                          activeTabURL == url else { return }
                    setHeavyProgress("Restoring \(url.lastPathComponent)...", for: url)
                }
                try? await Task.sleep(for: .milliseconds(50))
            }

            await MainActor.run {
                let currentSignature = FileEditorDiskSignatureProvider.signature(for: url)
                guard FileEditorReloadCommitPolicy.shouldCommit(
                    isTabOpen: openTabs.contains(where: { $0.url == url }),
                    isDirty: dirtyTabs.contains(url),
                    request: request,
                    currentRequestID: fileReadRequestIDs[url],
                    currentSessionGeneration: editorSessionGeneration,
                    currentDiskSignature: currentSignature
                ) else {
                    handleRejectedFileRead(
                        url,
                        request: request,
                        currentDiskSignature: currentSignature,
                        retry: { latestSignature in
                            loadRestoredTabContent(url, signature: latestSignature)
                        },
                        onReject: {
                            clearHeavyProgress(for: url)
                            if activeTabURL == url {
                                isEditorLoading = false
                            }
                        }
                    )
                    return
                }
                tabStorages[url] = storage
                tabDiskSignatures[url] = request.signature
                fileReadRequestIDs.removeValue(forKey: url)
                if activeTabURL == url {
                    previewImage = nil
                    editorState = SourceEditorState()
                    if isLargeMode {
                        clearHeavyProgress(for: url)
                    }
                }
            }
            try? await Task.sleep(for: .milliseconds(50))
            await MainActor.run {
                guard editorSessionGeneration == request.sessionGeneration,
                      activeTabURL == url else { return }
                isEditorLoading = false
            }
        }
    }

    private func clearEditorTabs(reason: String, persist: Bool) {
        openTabs = []
        activeTabURL = nil
        tabStorages.removeAll()
        tabImageCache.removeAll()
        tabDiskSignatures.removeAll()
        fileReadRequestIDs.removeAll()
        editorSessionGeneration = UUID()
        dirtyTabs.removeAll()
        largeModeTabs.removeAll()
        previewImage = nil
        pendingActivationURL = nil
        isEditorLoading = false
        setHeavyProgress(nil, for: nil)
        if persist {
            persistEditorSession(reason: reason)
        }
        AppLogger.log("file-editor-state", "clear reason=%@ project=%@", reason, editorSessionProjectKey ?? "nil")
    }

    private func persistEditorSession(reason: String, activeOverride: URL? = nil, immediate: Bool = false) {
        guard let editorSessionProjectKey else { return }
        persistDebounceWork?.cancel()
        let activePath = (activeOverride ?? activeTabURL)?.standardizedFileURL.path
        let tabs = openTabs.map { $0.url.standardizedFileURL.path }
        let projectKey = editorSessionProjectKey

        let work = DispatchWorkItem { [tabs, activePath, projectKey] in
            let session = FileEditorSession(openFilePaths: tabs, activeFilePath: activePath)
            FileEditorSessionPersistence.save(session, forProjectKey: projectKey)
            AppLogger.log("file-editor-state", "persist reason=%@ project=%@ tabs=%d active=%@",
                          reason, projectKey, tabs.count, activePath ?? "nil")
        }
        persistDebounceWork = work

        if immediate {
            work.perform()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
        }
    }

    private func flushEditorSession(reason: String) {
        persistEditorSession(reason: reason, immediate: true)
    }

    private func setHeavyProgress(_ text: String?, for url: URL?) {
        heavyProgressText = text
        heavyProgressURL = text == nil ? nil : url
    }

    private func clearHeavyProgress(for url: URL) {
        guard heavyProgressURL == nil || heavyProgressURL == url else { return }
        setHeavyProgress(nil, for: nil)
    }

    private func beginFileRead(
        for url: URL,
        signature: FileEditorDiskSignature? = nil
    ) -> FileEditorReadRequest? {
        guard let signature = signature ?? FileEditorDiskSignatureProvider.signature(for: url) else {
            return nil
        }
        let request = FileEditorReadRequest(
            id: UUID(),
            sessionGeneration: editorSessionGeneration,
            signature: signature
        )
        fileReadRequestIDs[url] = request.id
        return request
    }

    private func isCurrentFileRead(_ request: FileEditorReadRequest, for url: URL) -> Bool {
        fileReadRequestIDs[url] == request.id
            && editorSessionGeneration == request.sessionGeneration
    }

    /// Single exit for a read that could not produce content.
    ///
    /// Open and restore commit the tab before the read starts, so a failure has
    /// to take it back down (`closingTab`); a reload already has usable content
    /// on screen and only needs to stop pretending it refreshed. Neither may
    /// advance `tabDiskSignatures` — marking the tab as in sync with disk makes
    /// `reloadOpenTabFromDiskIfNeeded` skip it forever, so a file that briefly
    /// failed to decode would stay stale until the app restarts.
    ///
    /// Every read path routes through here. They used to clean up separately and
    /// had drifted into three different contracts: one reported the error, one
    /// closed the tab silently, one left the spinner spinning.
    private func failFileRead(
        _ url: URL,
        closingTab: Bool,
        persistRemoval: Bool,
        reason: String,
        message: String
    ) {
        AppLogger.log("file-editor-state", "%@ path=%@", reason, url.path)
        if closingTab {
            removeTab(url, reason: reason, persist: persistRemoval)
        } else {
            fileReadRequestIDs.removeValue(forKey: url)
            clearHeavyProgress(for: url)
            if pendingActivationURL == url { pendingActivationURL = nil }
            if activeTabURL == url { isEditorLoading = false }
        }
        store.errorMessage = message
    }

    @discardableResult
    private func reloadOpenTabFromDiskIfNeeded(_ url: URL, reason: String) -> Bool {
        guard openTabs.contains(where: { $0.url == url }) else { return false }
        guard !dirtyTabs.contains(url) else {
            AppLogger.log("file-editor-state", "reload-skip reason=dirty trigger=%@ path=%@", reason, url.path)
            return false
        }
        guard let signature = FileEditorDiskSignatureProvider.signature(for: url) else { return false }
        guard tabDiskSignatures[url] != signature else { return false }

        reloadOpenTabFromDisk(url, signature: signature, reason: reason)
        return true
    }

    /// Carries the caret across a reload, clamped to the new buffer — a file
    /// that shrank on disk leaves the old selection pointing past the end.
    private func clampedCursorPositions(
        _ positions: [CursorPosition]?,
        toLength length: Int
    ) -> [CursorPosition]? {
        guard let positions else { return nil }
        let clamped = positions.compactMap { position -> CursorPosition? in
            guard position.range.location != NSNotFound else { return nil }
            let location = min(position.range.location, length)
            return CursorPosition(
                range: NSRange(
                    location: location,
                    length: min(position.range.length, length - location)
                )
            )
        }
        return clamped.isEmpty ? nil : clamped
    }

    private func reloadOpenTabFromDisk(_ url: URL, signature: FileEditorDiskSignature, reason: String) {
        guard FileEditorAutomaticReadPolicy.allowsRead(
            fileSize: signature.fileSize,
            isImage: isImageURL(url),
            hugeFileThreshold: Self.hugeFileThreshold,
            imageMaxBytes: Self.imageMaxBytes
        ) else {
            failFileRead(
                url,
                closingTab: false,
                persistRemoval: false,
                reason: "reload-skip-automatic-read-limit",
                message: "Could not reload \(url.lastPathComponent) because it is too large to load automatically."
            )
            return
        }
        guard let request = beginFileRead(for: url, signature: signature) else { return }

        if isImageURL(url) {
            Task.detached(priority: .userInitiated) {
                let image = NSImage(contentsOf: url)
                await MainActor.run {
                    let currentSignature = FileEditorDiskSignatureProvider.signature(for: url)
                    guard FileEditorReloadCommitPolicy.shouldCommit(
                        isTabOpen: openTabs.contains(where: { $0.url == url }),
                        isDirty: dirtyTabs.contains(url),
                        request: request,
                        currentRequestID: fileReadRequestIDs[url],
                        currentSessionGeneration: editorSessionGeneration,
                        currentDiskSignature: currentSignature
                    ) else {
                        handleRejectedFileRead(
                            url,
                            request: request,
                            currentDiskSignature: currentSignature,
                            retry: { latestSignature in
                                reloadOpenTabFromDisk(
                                    url,
                                    signature: latestSignature,
                                    reason: "\(reason)-disk-changed-during-read"
                                )
                            }
                        )
                        return
                    }
                    guard let image else {
                        // Keep the tab and its cached image: the previously
                        // decoded copy is still the best thing to show, and not
                        // advancing the signature leaves the retry armed.
                        failFileRead(
                            url,
                            closingTab: false,
                            persistRemoval: false,
                            reason: "reload-image-decode-failed",
                            message: "Could not reload \(url.lastPathComponent) — the image could not be decoded."
                        )
                        return
                    }
                    tabImageCache[url] = image
                    tabDiskSignatures[url] = request.signature
                    fileReadRequestIDs.removeValue(forKey: url)
                    if activeTabURL == url {
                        previewImage = image
                        isEditorLoading = false
                    }
                    AppLogger.log("file-editor-state", "reload-image trigger=%@ path=%@", reason, url.path)
                }
            }
            return
        }

        let shouldUseLargeMode = signature.fileSize >= Self.largeFileThreshold
        Task.detached(priority: .userInitiated) {
            let content: String
            do {
                content = try String(contentsOf: url, encoding: .utf8)
            } catch {
                await MainActor.run {
                    guard isCurrentFileRead(request, for: url) else { return }
                    failFileRead(
                        url,
                        closingTab: false,
                        persistRemoval: false,
                        reason: "reload-read-failed",
                        message: "Failed to reload \(url.lastPathComponent): \(error.localizedDescription)"
                    )
                }
                return
            }

            await MainActor.run {
                let isTabOpen = openTabs.contains(where: { $0.url == url })
                let isDirty = dirtyTabs.contains(url)
                let currentSignature = FileEditorDiskSignatureProvider.signature(for: url)
                guard FileEditorReloadCommitPolicy.shouldCommit(
                    isTabOpen: isTabOpen,
                    isDirty: isDirty,
                    request: request,
                    currentRequestID: fileReadRequestIDs[url],
                    currentSessionGeneration: editorSessionGeneration,
                    currentDiskSignature: currentSignature
                ) else {
                    if isDirty {
                        AppLogger.log(
                            "file-editor-state",
                            "reload-skip reason=dirty-during-read trigger=%@ path=%@",
                            reason,
                            url.path
                        )
                    }
                    handleRejectedFileRead(
                        url,
                        request: request,
                        currentDiskSignature: currentSignature,
                        retry: { latestSignature in
                            reloadOpenTabFromDisk(
                                url,
                                signature: latestSignature,
                                reason: "\(reason)-disk-changed-during-read"
                            )
                        }
                    )
                    return
                }
                // Publish a fresh storage rather than mutating the one the editor
                // owns. `NSTextStorage.replaceCharacters` bypasses
                // `TextView.replaceCharacters`, so CEUndoManager keeps its
                // mutations pointing at the pre-reload content and a later undo
                // replays an out-of-bounds range — an NSRangeException Swift
                // cannot catch. Swapping the object also moves the view's
                // `ObjectIdentifier` id, so SwiftUI rebuilds around this storage.
                tabStorages[url] = NSTextStorage(string: content)
                if activeTabURL == url {
                    editorState.cursorPositions = clampedCursorPositions(
                        editorState.cursorPositions,
                        toLength: (content as NSString).length
                    )
                }
                tabDiskSignatures[url] = request.signature
                fileReadRequestIDs.removeValue(forKey: url)
                if shouldUseLargeMode {
                    largeModeTabs.insert(url)
                } else {
                    largeModeTabs.remove(url)
                }
                if activeTabURL == url {
                    previewImage = nil
                }
                AppLogger.log("file-editor-state", "reload-text trigger=%@ path=%@", reason, url.path)
            }
        }
    }

    private func handleRejectedFileRead(
        _ url: URL,
        request: FileEditorReadRequest,
        currentDiskSignature: FileEditorDiskSignature?,
        isEligible: Bool = true,
        retry: (FileEditorDiskSignature) -> Void,
        onReject: () -> Void = {}
    ) {
        guard isCurrentFileRead(request, for: url) else { return }
        let shouldRetry = FileEditorReloadCommitPolicy.shouldRetry(
            isTabOpen: isEligible && openTabs.contains(where: { $0.url == url }),
            isDirty: dirtyTabs.contains(url),
            request: request,
            currentRequestID: fileReadRequestIDs[url],
            currentSessionGeneration: editorSessionGeneration,
            currentDiskSignature: currentDiskSignature
        )
        fileReadRequestIDs.removeValue(forKey: url)

        if shouldRetry, let currentDiskSignature {
            retry(currentDiskSignature)
        } else {
            onReject()
        }
    }

    /// `nil` when the size cannot be read. Callers must treat that as "too
    /// large to open casually", not as zero: every guard here is a *lower*
    /// bound, so a 0 fallback silently waived the large-file mode, the 50 MB
    /// confirmation and the image cap all at once.
    private func fileSize(for url: URL) -> Int? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
    }

    private func isImageURL(_ url: URL) -> Bool {
        Self.imageExtensions.contains(url.pathExtension.lowercased())
    }

    private func shouldOpenInLargeMode(_ url: URL) -> Bool {
        guard !isImageURL(url) else { return false }
        // Unknown size: assume large. Read-only plain text is a recoverable
        // wrong guess; full syntax highlighting on a huge file is not.
        guard let size = fileSize(for: url) else { return true }
        return size >= Self.largeFileThreshold
    }

    private static func formattedSize(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// Yellow banner shown above the editor for tabs in large-file mode.
    /// Tapping "Enable Anyway" lifts the restriction for the current tab,
    /// triggering a SourceEditor reconfiguration with the file's real
    /// language and editable config.
    @ViewBuilder
    private func largeFileBanner(for url: URL) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(AppFonts.toolbarIcon)
            Text("Large file — syntax highlighting and editing disabled.")
                .font(AppFonts.caption)
                .foregroundStyle(AppPalette.textSecondary)
            Spacer(minLength: 8)
            Button("Enable Anyway") {
                largeModeTabs.remove(url)
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.orange.opacity(0.10))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.orange.opacity(0.25)).frame(height: 1)
        }
    }

    private func switchToTab(_ url: URL, persistSession: Bool = true) {
        guard url != activeTabURL else { return }
        guard openTabs.contains(where: { $0.url == url }) else { return }

        isEditorLoading = true
        activeTabURL = url
        editorState = SourceEditorState()
        if persistSession {
            persistEditorSession(reason: "switch-tab")
        }

        let isImage = isImageURL(url)

        if isImage {
            previewImage = tabImageCache[url]
            isEditorLoading = false
            reloadOpenTabFromDiskIfNeeded(url, reason: "switch-tab")
        } else {
            previewImage = nil
            // Storage already in tabStorages — the editor keyed on it stays put
            // unless the reload below actually replaces the object.
            Task {
                try? await Task.sleep(for: .milliseconds(50))
                guard activeTabURL == url else { return }
                isEditorLoading = false
                reloadOpenTabFromDiskIfNeeded(url, reason: "switch-tab")
            }
        }

        // Sync tree selection
        store.selectNode(url.standardizedFileURL.path)
    }

    private func closeTab(_ url: URL) {
        // Closing a large-mode tab triggers synchronous NSLayoutManager
        // teardown to release the line layout cache, which can block the main
        // thread for several seconds on multi-MB plain text. Show the spinner
        // overlay first, then yield one runloop turn so SwiftUI paints it
        // before the synchronous removeValue freeze.
        let needsSpinner = largeModeTabs.contains(url) && tabStorages[url] != nil
        if needsSpinner {
            setHeavyProgress("Closing \(url.lastPathComponent)…", for: url)
            DispatchQueue.main.async {
                performTabClose(url)
                clearHeavyProgress(for: url)
            }
        } else {
            performTabClose(url)
        }
    }

    private func performTabClose(_ url: URL) {
        // A dirty tab's buffer is the only copy of the user's edits, so closing
        // it is only safe once the write lands. `saveAllDirtyTabs` already
        // refuses to drop a tab it could not write; this path used to report the
        // error and then release the storage anyway.
        if dirtyTabs.contains(url) {
            guard let storage = tabStorages[url] else {
                AppLogger.log("file-editor-state", "close-blocked reason=storage-missing path=%@", url.path)
                presentSaveFailureAlert([SaveFailure(url: url, message: "The edits are no longer held in memory.")])
                return
            }
            if let failure = saveTab(url, storage: storage) {
                AppLogger.log("file-editor-state", "close-blocked path=%@ error=%@", url.path, failure.message)
                presentSaveFailureAlert([failure])
                return
            }
        }

        removeTab(url, reason: "close-tab")
    }

    /// Tears a tab down and moves the selection to a neighbour.
    ///
    /// Shared by manual close and by the read-failure path. The two used to be
    /// written out separately, and the failure copy forgot to move
    /// `activeTabURL` off the tab it had just removed — a failed restore left
    /// the selection pointing at a tab that no longer existed with the loading
    /// spinner running forever.
    private func removeTab(_ url: URL, reason: String, persist: Bool = true) {
        guard let index = openTabs.firstIndex(where: { $0.url == url }) else { return }
        let wasActive = url == activeTabURL
        let ownedPendingActivation = pendingActivationURL == url

        openTabs.remove(at: index)
        tabStorages.removeValue(forKey: url)
        tabImageCache.removeValue(forKey: url)
        tabDiskSignatures.removeValue(forKey: url)
        fileReadRequestIDs.removeValue(forKey: url)
        dirtyTabs.remove(url)
        largeModeTabs.remove(url)
        clearHeavyProgress(for: url)
        if pendingActivationURL == url { pendingActivationURL = nil }
        if ownedPendingActivation { isEditorLoading = false }

        if wasActive {
            activeTabURL = nil
            if openTabs.isEmpty {
                previewImage = nil
                isEditorLoading = false
            } else {
                let newIndex = min(index, openTabs.count - 1)
                let newURL = openTabs[newIndex].url
                switchToTab(newURL, persistSession: false)
            }
        }
        if persist {
            persistEditorSession(reason: reason)
        }
    }

    private func closeActiveTab() {
        guard let url = activeTabURL else { return }
        closeTab(url)
    }

    /// LRU eviction: when the open-tab cap is reached, drop the oldest tab
    /// that is neither active nor dirty so its NSTextStorage / NSImage can
    /// be released. Skips dirty tabs to avoid silently losing edits.
    private func evictOldestTabIfNeeded() {
        guard openTabs.count >= Self.maxOpenTabs else { return }
        guard let evictURL = openTabs.first(where: {
            $0.url != activeTabURL && !dirtyTabs.contains($0.url)
        })?.url else { return }
        openTabs.removeAll { $0.url == evictURL }
        tabStorages.removeValue(forKey: evictURL)
        tabImageCache.removeValue(forKey: evictURL)
        tabDiskSignatures.removeValue(forKey: evictURL)
        fileReadRequestIDs.removeValue(forKey: evictURL)
        largeModeTabs.remove(evictURL)
        persistEditorSession(reason: "evict-tab")
    }

    // MARK: - Save

    private func saveCurrentTab() {
        guard let url = activeTabURL,
              dirtyTabs.contains(url),
              let storage = tabStorages[url] else { return }
        if let failure = saveTab(url, storage: storage) {
            store.errorMessage = "Failed to save \(url.lastPathComponent): \(failure.message)"
        } else {
            store.refreshNow()
        }
    }

    /// Saves every dirty tab and returns the ones that could not be written.
    ///
    /// A failed tab keeps its dirty flag: clearing it unconditionally made the
    /// UI claim the edits were saved, and the `clearEditorTabs` that follows a
    /// project switch then dropped them for good.
    @discardableResult
    private func saveAllDirtyTabs() -> [SaveFailure] {
        var failures: [SaveFailure] = []
        for url in Array(dirtyTabs) {
            guard let storage = tabStorages[url] else {
                // A dirty tab with no storage means eviction raced the edit —
                // internal inconsistency, not "nothing to save".
                AppLogger.log("file-editor-state", "save-failed reason=storage-missing path=%@", url.path)
                failures.append(SaveFailure(url: url, message: "The edits are no longer held in memory."))
                continue
            }
            if let failure = saveTab(url, storage: storage) {
                failures.append(failure)
            }
        }
        return failures
    }

    private func saveTab(_ url: URL, storage: NSTextStorage) -> SaveFailure? {
        guard let openedSignature = tabDiskSignatures[url],
              let currentSignature = FileEditorDiskSignatureProvider.signature(for: url),
              openedSignature == currentSignature else {
            let message = "The file changed on disk after it was opened. Your edits were not written."
            AppLogger.log("file-editor-state", "save-blocked reason=disk-changed path=%@", url.path)
            return SaveFailure(url: url, message: message)
        }

        do {
            try storage.string.write(to: url, atomically: true, encoding: .utf8)
            tabDiskSignatures[url] = FileEditorDiskSignatureProvider.signature(for: url)
            dirtyTabs.remove(url)
            return nil
        } catch {
            AppLogger.log(
                "file-editor-state",
                "save-failed path=%@ error=%@",
                url.path,
                error.localizedDescription
            )
            return SaveFailure(url: url, message: error.localizedDescription)
        }
    }

    private func presentSaveFailureAlert(_ failures: [SaveFailure]) {
        let detail = failures
            .map { "• \($0.url.lastPathComponent) — \($0.message)" }
            .joined(separator: "\n")
        let alert = NSAlert()
        alert.messageText = "Some edits could not be saved"
        alert.informativeText = """
        \(detail)

        These tabs stay open with your changes so nothing is lost. Fix the problem and press ⌘S again.
        """
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Git Actions

    private func stageFile(_ node: FileExplorerNode) {
        guard node.gitState != nil else { return }
        gitStore.stage(paths: [store.relativePath(for: node)])
    }

    private func discardFile(_ node: FileExplorerNode) {
        guard node.gitState != nil else { return }
        gitStore.discardByPath(store.relativePath(for: node))
    }

    private func openDiff(_ node: FileExplorerNode) {
        guard !node.isDirectory else { return }
        rightDockStore.expand(tab: .git)
        gitStore.openDiff(forFileURL: node.url)
    }

    // MARK: - Helpers

    private func editorLanguage(for url: URL) -> CodeLanguage {
        CodeLanguage.detectLanguageFrom(url: url)
    }

    fileprivate static func fileIconName(for url: URL) -> String {
        FileIcons.iconName(for: url)
    }

    fileprivate static func fileIconColor(for url: URL) -> Color {
        FileIcons.iconColor(for: url)
    }

    private func fileIcon(for node: FileExplorerNode) -> String {
        if node.isDirectory { return "folder.fill" }
        return Self.fileIconName(for: node.url)
    }
}

// MARK: - Editor Tab Button

private struct EditorTabButton: View {
    let tab: EditorTab
    let isActive: Bool
    let isDirty: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onSelect) {
                HStack(spacing: 4) {
                    Image(systemName: FileExplorerView.fileIconName(for: tab.url))
                        .font(AppFonts.toolbarIcon)
                        .foregroundStyle(FileExplorerView.fileIconColor(for: tab.url))

                    Text(tab.name)
                        .font(AppFonts.secondaryLabel.weight(isActive ? .medium : .regular))
                        .foregroundStyle(isActive ? AppPalette.textPrimary : AppPalette.textSecondary)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            closeOrDirtyIndicator
        }
        .padding(.horizontal, 8)
        .frame(height: AppSpacing.editorTabBarHeight - 8)
        .background(
            RoundedRectangle(cornerRadius: AppSpacing.cornerRadius, style: .continuous)
                .fill(isActive
                      ? AppPalette.base
                      : (isHovering ? AppPalette.surface : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppSpacing.cornerRadius, style: .continuous)
                .strokeBorder(isActive ? AppPalette.border : Color.clear, lineWidth: 1)
        )
        .padding(.vertical, 4)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Close") { onClose() }
        }
    }

    @ViewBuilder
    private var closeOrDirtyIndicator: some View {
        if isDirty && !isHovering {
            Circle()
                .fill(AppPalette.textSecondary)
                .frame(width: 6, height: 6)
                .frame(width: 16, height: 16)
        } else if isHovering || isActive {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(AppFonts.tinyIcon.weight(.bold))
                    .foregroundStyle(AppPalette.textTertiary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close tab")
        } else {
            Color.clear.frame(width: 16, height: 16)
        }
    }
}
