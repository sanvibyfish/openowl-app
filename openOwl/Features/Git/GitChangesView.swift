import AppKit
import Foundation
import SwiftUI

struct GitChangesView: View {
    @Environment(GitChangesStore.self) private var store
    @Environment(ProjectStore.self) private var projectStore
    @Environment(RightDockStore.self) private var rightDockStore
    @State private var confirmationAction: GitConfirmationAction?
    @State private var selectedIDs: Set<String> = []
    @State private var lastClickedID: String?
    @State private var expandedHunks: Set<Int> = []
    @State private var cachedFileLines: [String]?
    @FocusState private var commitFieldFocused: Bool

    var body: some View {
        Group {
            if rightDockStore.gitShowsDiff {
                HSplitView {
                    // Hard min so HSplitView cannot squeeze the graph mid-circle
                    // or commit message mid-glyph (was the "left side clipped" bug).
                    leftSplitView
                        .frame(minWidth: 220, idealWidth: 260, maxWidth: 360)
                    diffPanel
                        .frame(minWidth: 240)
                }
            } else {
                leftSplitView
                    .frame(maxWidth: .infinity)
            }
        }
        .onAppear {
            syncRepositoryIfActive()
        }
        .onChange(of: store.selectedChange?.id) { _, _ in
            expandedHunks.removeAll()
            cachedFileLines = nil
        }
        .alert("Confirm Action", isPresented: isShowingConfirmation, presenting: confirmationAction) { action in
            confirmationButtons(for: action)
        } message: { action in
            Text(confirmationMessage(for: action))
        }
    }

    private func syncRepositoryIfActive() {
        guard rightDockStore.isExpanded && rightDockStore.activeTab == .git else { return }
        guard let url = projectStore.activeProjectURL else { return }
        store.setPreferredDirectory(url)
    }

    // MARK: - Left Split (Changes + Graph)

    private var leftSplitView: some View {
        VSplitView {
            // Keep mins modest so a clean working tree doesn't force a tall
            // empty upper pane that swallows the commit graph.
            changesPanel
                .frame(minHeight: 140)

            gitGraphPanel
                .frame(minHeight: 100)
        }
    }

    // MARK: - Left Top: Changes Panel

    private var changesPanel: some View {
        VStack(spacing: 0) {
            changesPanelToolbar

            commitArea

            PanelDivider()

            // File sections
            ScrollView {
                VStack(spacing: 0) {
                    stagedSection
                    changesSection
                }
                .padding(.vertical, 2)
            }
            .scrollEdgeEffectIfAvailable(for: .top)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppPalette.base)

            // Error/Info banners
            if let errorMessage = store.errorMessage {
                statusBanner(text: errorMessage, color: .red) {
                    store.errorMessage = nil
                }
            } else if let infoMessage = store.infoMessage {
                statusBanner(text: infoMessage, color: .green) {
                    store.clearInfoMessage()
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Changes Panel Toolbar

    private var changesPanelToolbar: some View {
        // No "CHANGES" title — the Git tab above already names this panel.
        HStack(spacing: 2) {
            Spacer(minLength: 0)

            Button { store.refreshNow() } label: {
                SpinningIcon(systemName: "arrow.clockwise", isSpinning: store.isRefreshing)
            }
            .buttonStyle(.icon(font: AppFonts.toolbarIcon, size: 24))
            .help("Refresh")
            .accessibilityLabel("Refresh")
            .disabled(store.isRefreshing || store.isRunningCommand)

            Button { rightDockStore.gitShowsDiff.toggle() } label: {
                Image(systemName: rightDockStore.gitShowsDiff
                    ? "square.lefthalf.filled"
                    : "square.split.2x1")
            }
            .buttonStyle(.icon(
                isActive: rightDockStore.gitShowsDiff,
                font: AppFonts.toolbarIcon,
                size: 24
            ))
            .help(rightDockStore.gitShowsDiff ? "Hide diff" : "Show diff")
            .accessibilityLabel(rightDockStore.gitShowsDiff ? "Hide diff" : "Show diff")
        }
        .padding(.horizontal, 6)
        .panelToolHeader(background: AppPalette.elevated)
    }

    // MARK: - Commit Area (compact, web-style)

    private var commitArea: some View {
        @Bindable var store = store
        return VStack(spacing: 6) {
            // Commit message with inline AI generate button
            ZStack(alignment: .topTrailing) {
                TextEditor(text: $store.commitMessage)
                    .font(AppFonts.secondaryLabel)
                    .scrollContentBackground(.hidden)
                    .scrollDisabled(true)
                    .frame(height: store.commitMessage.contains("\n") ? 48 : 26)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .padding(.trailing, 22)
                    .background(AppPalette.surface)
                    .clipShape(RoundedRectangle(cornerRadius: AppSpacing.cornerRadiusSmall, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppSpacing.cornerRadiusSmall, style: .continuous)
                            .stroke(
                                commitFieldFocused ? AppPalette.accent.opacity(0.45) : AppPalette.border,
                                lineWidth: 1
                            )
                    )
                    .focused($commitFieldFocused)
                    .overlay(alignment: .topLeading) {
                        if store.commitMessage.isEmpty {
                            Text("Commit message")
                                .font(AppFonts.secondaryLabel)
                                .foregroundStyle(AppPalette.textTertiary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .allowsHitTesting(false)
                        }
                    }

                if store.isGeneratingMessage {
                    Button {
                        store.cancelGenerateCommitMessage()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(AppFonts.smallIcon)
                            .foregroundStyle(AppPalette.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 22, height: 22)
                    .padding(2)
                    .help("Stop generating")
                    .accessibilityLabel("Stop generating")
                } else if store.commitMessage.isEmpty {
                    Button {
                        store.generateCommitMessage()
                    } label: {
                        Image(systemName: "sparkles")
                            .font(AppFonts.toolbarIcon)
                            .foregroundStyle(AppPalette.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 22, height: 22)
                    .padding(2)
                    .disabled(store.isRunningCommand || !hasAnyChanges)
                    .help("Generate commit message (AI)")
                    .accessibilityLabel("Generate commit message (AI)")
                }
            }

            Button {
                store.commit()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark")
                        .font(AppFonts.badge.weight(.semibold))
                    Text(store.isRunningCommand ? "Committing..." : "Commit")
                        .font(AppFonts.caption.weight(.medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: AppSpacing.cornerRadiusSmall, style: .continuous)
                        .fill(commitEnabled ? AppPalette.accent.opacity(0.14) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppSpacing.cornerRadiusSmall, style: .continuous)
                        .stroke(
                            commitEnabled ? AppPalette.accent.opacity(0.28) : AppPalette.border,
                            lineWidth: 1
                        )
                )
                .foregroundStyle(commitEnabled ? AppPalette.accent : AppPalette.textTertiary)
            }
            .buttonStyle(.plain)
            .disabled(!commitEnabled)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        // Cmd+Return is gated on right-dock visibility so it doesn't fire while
        // the dock is closed or showing a different tab — this view stays mounted
        // for @State preservation (commit message draft, expanded hunks, etc.).
        .background {
            if rightDockStore.isExpanded && rightDockStore.activeTab == .git, commitEnabled {
                Button("") { store.commit() }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .hidden()
            }
        }
    }

    // MARK: - Staged Changes Section

    @ViewBuilder
    private var stagedSection: some View {
        let staged = store.statusSnapshot?.staged ?? []
        if !staged.isEmpty {
            CollapsibleSection(
                title: "Staged Changes",
                count: staged.count,
                action: {
                    AnyView(
                        Button { store.unstageAll() } label: {
                            Image(systemName: "minus")
                                .font(AppFonts.toolbarIcon.weight(.semibold))
                        }
                        .buttonStyle(.plain)
                        .help("Unstage All")
                        .accessibilityLabel("Unstage All")
                    )
                }
            ) {
                ForEach(staged) { change in
                    FileStatusRow(
                        change: change,
                        isSelected: selectedIDs.contains(change.id),
                        selectedCount: selectedIDs.count,
                        actionIcon: "minus",
                        actionHelp: "Unstage",
                        onSelect: { handleClick(change) },
                        onAction: {
                            let sel = selectedChanges(in: staged)
                            if sel.count > 1 { store.unstage(paths: sel.map(\.path)) }
                            else { store.unstage(change) }
                        },
                        onDiscard: nil
                    )
                }
            }
        }
    }

    // MARK: - Changes Section (Modified + Untracked)

    @ViewBuilder
    private var changesSection: some View {
        let modified = store.statusSnapshot?.modified ?? []
        let untracked = store.statusSnapshot?.untracked ?? []
        let changes = modified + untracked

        if !changes.isEmpty {
            CollapsibleSection(
                title: "Changes",
                count: changes.count,
                action: {
                    AnyView(
                        HStack(spacing: 2) {
                            Button {
                                requestDiscard(changes: changes)
                            } label: {
                                Image(systemName: "arrow.uturn.backward")
                                    .font(AppFonts.badge.weight(.semibold))
                            }
                            .buttonStyle(.plain)
                            .help("Discard All")
                            .accessibilityLabel("Discard All")

                            Button { store.stageAll() } label: {
                                Image(systemName: "plus")
                                    .font(AppFonts.toolbarIcon.weight(.semibold))
                            }
                            .buttonStyle(.plain)
                            .help("Stage All")
                            .accessibilityLabel("Stage All")
                        }
                    )
                }
            ) {
                ForEach(changes) { change in
                    FileStatusRow(
                        change: change,
                        isSelected: selectedIDs.contains(change.id),
                        selectedCount: selectedIDs.count,
                        actionIcon: "plus",
                        actionHelp: "Stage",
                        discardable: true,
                        onSelect: { handleClick(change) },
                        onAction: {
                            let sel = selectedChanges(in: changes)
                            if sel.count > 1 { store.stage(paths: sel.map(\.path)) }
                            else { store.stage(change) }
                        },
                        onDiscard: {
                            let sel = selectedChanges(in: changes)
                            if sel.count > 1 { requestDiscard(changes: sel) }
                            else { requestDiscard(changes: [change]) }
                        }
                    )
                }
            }
        }

        if store.statusSnapshot?.untrackedTruncated == true {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle")
                    .font(AppFonts.smallIcon)
                Text("Showing first 500 untracked files. Consider updating .gitignore.")
                    .font(AppFonts.caption)
            }
            .foregroundStyle(.orange)
            .padding(.horizontal, 8).padding(.vertical, 4)
        }

        if !hasAnyChanges {
            // Quiet inline filler — a hero empty state here used to dwarf the
            // commit graph below and read as a second logo on the panel.
            EmptyStateView(
                "Working tree is clean",
                systemImage: "checkmark.circle",
                density: .quiet
            )
            .padding(.top, 10)
        }
    }

    // MARK: - Left Bottom: Git Graph Panel

    private var gitGraphPanel: some View {
        VStack(spacing: 0) {
            // Toolbar: branch + remote actions — same tool-header chrome as Files/Changes.
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                    .font(AppFonts.toolbarIcon)
                    .foregroundStyle(AppPalette.textTertiary)
                    .layoutPriority(2)
                Text(store.statusSnapshot?.branch ?? "—")
                    .font(AppFonts.secondaryLabel.weight(.medium))
                    .foregroundStyle(AppPalette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(0)
                    .help(store.statusSnapshot?.branch ?? "")

                Spacer(minLength: 2)

                // Ahead/Behind pill badges
                if let snapshot = store.statusSnapshot {
                    if snapshot.behindCount > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "arrow.down").font(AppFonts.tinyIcon)
                            Text("\(snapshot.behindCount)").font(AppFonts.badge)
                        }
                        .foregroundStyle(AppPalette.textSecondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(AppPalette.surface))
                    }
                    if snapshot.aheadCount > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "arrow.up").font(AppFonts.tinyIcon)
                            Text("\(snapshot.aheadCount)").font(AppFonts.badge)
                        }
                        .foregroundStyle(AppPalette.textSecondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(AppPalette.surface))
                    }
                }

                Button { store.pull() } label: {
                    Image(systemName: "arrow.down")
                }
                .buttonStyle(.icon(font: AppFonts.toolbarIcon, size: 22))
                .help("Pull")
                .accessibilityLabel("Pull")
                .disabled(store.isRunningCommand)

                Button { store.push() } label: {
                    Image(systemName: "arrow.up")
                }
                .buttonStyle(.icon(font: AppFonts.toolbarIcon, size: 22))
                .help("Push")
                .accessibilityLabel("Push")
                .disabled(store.isRunningCommand)

                Button { store.refreshNow() } label: {
                    SpinningIcon(systemName: "arrow.clockwise", isSpinning: store.isRefreshing)
                }
                .buttonStyle(.icon(font: AppFonts.toolbarIcon, size: 22))
                .help("Refresh")
                .accessibilityLabel("Refresh")
                .disabled(store.isRefreshing || store.isRunningCommand)
            }
            .padding(.horizontal, 8)
            .panelToolHeader(background: AppPalette.elevated)

            // Commit graph
            if store.logEntries.isEmpty {
                Spacer(minLength: 0)
                EmptyStateView(
                    "No commits yet",
                    subtitle: "Make your first commit",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    density: .compact
                )
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    GitGraphContentView(
                        entries: store.logEntries,
                        selectedHash: store.selectedCommitHash,
                        onSelect: { hash in
                            // Same auto-expand: a commit click in list-only mode
                            // would otherwise update state with no visible result.
                            if !rightDockStore.gitShowsDiff {
                                rightDockStore.gitShowsDiff = true
                            }
                            store.selectCommit(hash)
                        },
                        onLoadMore: { store.loadMoreLog() },
                        hasMore: store.hasMoreLog
                    )
                }
            }
        }
        .background(AppPalette.base)
    }

    // MARK: - Right: Diff Panel

    private var diffPanel: some View {
        VStack(spacing: 0) {
            // Header — trailing controls are fixedSize so path/hash never shove
            // them off-screen; path truncates first (full string in help).
            HStack(spacing: 6) {
                if let hash = store.selectedCommitHash, !store.commitDiffText.isEmpty {
                    let short = String(hash.prefix(7))
                    let count = store.commitFiles.count
                    Text("\(count) file\(count == 1 ? "" : "s") changed")
                        .font(AppFonts.diffCode.weight(.medium))
                        .foregroundStyle(AppPalette.textPrimary)
                        .lineLimit(1)
                        .layoutPriority(1)
                    Text("(\(short))")
                        .font(AppFonts.caption)
                        .foregroundStyle(AppPalette.textTertiary)
                        .fixedSize()
                        .help(hash)
                } else if let change = store.selectedChange {
                    Text(change.path)
                        .font(AppFonts.diffCode.weight(.medium))
                        .foregroundStyle(AppPalette.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                        .help(change.path)
                    Text(change.section == .staged ? "(staged)" : "(working tree)")
                        .font(AppFonts.caption)
                        .foregroundStyle(AppPalette.textTertiary)
                        .fixedSize()
                } else {
                    Text("Diff")
                        .font(AppFonts.primaryLabel)
                        .foregroundStyle(AppPalette.textSecondary)
                }

                Spacer(minLength: 4)

                if store.selectedCommitHash != nil, !store.commitDiffText.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showCommitFileList.toggle()
                        }
                    } label: {
                        Image(systemName: "sidebar.left")
                    }
                    .buttonStyle(.icon(
                        isActive: showCommitFileList,
                        font: AppFonts.toolbarIcon,
                        size: 22
                    ))
                    .help("Toggle file list")
                    .accessibilityLabel("Toggle file list")
                }
            }
            .padding(.horizontal, 10)
            .panelToolHeader(background: AppPalette.elevated)

            // Content
            if store.selectedCommitHash != nil, !store.commitDiffText.isEmpty {
                let sections = splitDiffByFile(store.commitDiffText)
                HStack(spacing: 0) {
                    if showCommitFileList {
                        commitFileSidebar(sections: sections)
                        // `PanelDivider` is fixed horizontal and width-greedy;
                        // between two side-by-side panes it needs the vertical
                        // form, which is what the old `Divider()` resolved to
                        // here on its own.
                        Rectangle()
                            .fill(AppPalette.border)
                            .frame(width: 1)
                            .frame(maxHeight: .infinity)
                    }
                    commitDiffByFile(sections: sections)
                }
            } else if let change = store.selectedChange, isImagePath(change.path) {
                WorkingTreeImageDiffView(
                    change: change,
                    repositoryURL: store.repositoryURL
                )
            } else if store.selectedChange != nil, !store.selectedDiffText.isEmpty {
                singleFileDiff(store.selectedDiffText)
            } else if store.selectedChange != nil {
                Spacer(minLength: 0)
                EmptyStateView(
                    "No diff output",
                    systemImage: "doc.text",
                    density: .compact
                )
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
                EmptyStateView(
                    "Select a file to view diff",
                    subtitle: "Pick a change or commit on the left",
                    systemImage: "doc.text.magnifyingglass",
                    density: .compact
                )
                Spacer(minLength: 0)
            }
        }
        .background(diffBgColor)
    }

    // MARK: - Commit Diff (file-by-file sections)

    @State private var collapsedCommitFiles: Set<String> = []
    @State private var showCommitFileList = true
    @State private var scrollTarget: String?
    @State private var selectedCommitFilePath: String?

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "bmp", "tiff", "webp", "heic", "ico", "svg", "icns"
    ]

    private func commitFileSidebar(sections: [FileDiffSection]) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(sections, id: \.path) { section in
                    let isSelected = selectedCommitFilePath == section.path
                    let isImage = Self.imageExtensions.contains(
                        URL(fileURLWithPath: section.path).pathExtension.lowercased()
                    )
                    HStack(spacing: 6) {
                        if isImage {
                            Image(systemName: "photo")
                                .font(AppFonts.smallIcon)
                                .foregroundStyle(AppPalette.textSecondary)
                                .frame(width: 12)
                        } else {
                            Text(String(section.status.rawValue))
                                .font(AppFonts.diffMeta)
                                .foregroundStyle(commitStatusColor(section.status))
                                .frame(width: 12)
                        }

                        Text(URL(fileURLWithPath: section.path).lastPathComponent)
                            .font(AppFonts.secondaryLabel)
                            .foregroundStyle(isSelected ? AppPalette.textPrimary : AppPalette.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .selectableRowChrome(isSelected: isSelected, accentBarHeight: 12)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedCommitFilePath = section.path
                        collapsedCommitFiles.remove(section.path)
                        scrollTarget = section.path
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
        }
        .frame(width: 168)
        .background(AppPalette.elevated)
    }

    private func commitDiffByFile(sections: [FileDiffSection]) -> some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                // Unified (single-column) + wrap — standard for narrow dock;
                // no side-by-side half-width / content-stretch horizontal scroll.
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(sections, id: \.path) { section in
                            commitFileSection(section)
                                .id(section.path)
                        }
                    }
                    .frame(minWidth: geo.size.width, maxWidth: .infinity, minHeight: geo.size.height, alignment: .topLeading)
                }
                .onChange(of: scrollTarget) { _, target in
                    guard let target else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            proxy.scrollTo(target, anchor: .top)
                        }
                        scrollTarget = nil
                    }
                }
            }
        }
    }

    private func commitFileSection(_ section: FileDiffSection) -> some View {
        let isCollapsed = collapsedCommitFiles.contains(section.path)
        let isImage = Self.imageExtensions.contains(
            URL(fileURLWithPath: section.path).pathExtension.lowercased()
        )
        let isBinary = !isImage && section.diff.contains("Binary files")
        let rows = (isCollapsed || isImage || isBinary) ? [] : parseUnified(section.diff)
        let lineLabel: String? = {
            if isImage { return "image" }
            if isBinary { return "binary" }
            if !isCollapsed {
                let n = rows.filter { $0.kind != .hunkHeader }.count
                return "\(n) lines"
            }
            return nil
        }()
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(AppFonts.badge.weight(.semibold))
                    .foregroundStyle(AppPalette.textTertiary)
                    .frame(width: 10)
                    .fixedSize()

                Text(commitStatusString(section.status))
                    .font(AppFonts.diffMeta)
                    .foregroundStyle(commitStatusColor(section.status))
                    .fixedSize()

                Text(section.path)
                    .font(AppFonts.diffCode.weight(.medium))
                    .foregroundStyle(AppPalette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(-1)
                    .help(section.path)

                if let lineLabel {
                    Text(lineLabel)
                        .font(AppFonts.badge)
                        .foregroundStyle(AppPalette.textTertiary)
                        .fixedSize()
                        .layoutPriority(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                selectedCommitFilePath == section.path
                    ? AppPalette.accent.opacity(0.10)
                    : AppPalette.elevated
            )
            .contentShape(Rectangle())
            .onTapGesture {
                selectedCommitFilePath = section.path
                if collapsedCommitFiles.contains(section.path) {
                    collapsedCommitFiles.remove(section.path)
                } else {
                    collapsedCommitFiles.insert(section.path)
                }
            }

            if !isCollapsed {
                if isImage {
                    commitImageView(section: section)
                } else if isBinary {
                    Text("Binary file changed")
                        .font(AppFonts.secondaryLabel)
                        .foregroundStyle(AppPalette.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                } else {
                    unifiedDiffRows(rows)
                }
            }

            PanelDivider()
        }
    }

    private func commitImageView(section: FileDiffSection) -> some View {
        CommitImageDiffView(
            hash: store.selectedCommitHash ?? "",
            path: section.path,
            status: section.status,
            repositoryURL: store.repositoryURL
        )
    }

    private func commitStatusString(_ status: DiffFileStatus) -> String {
        switch status {
        case .added: return "ADDED"
        case .deleted: return "DELETED"
        case .renamed: return "RENAMED"
        case .modified: return "MODIFIED"
        }
    }

    // MARK: - Unified (inline) Diff
    //
    // Right-dock standard: single column like VS Code / GitHub mobile — fill the
    // pane width, wrap long lines. Side-by-side needs ~2× width and forces either
    // mid-glyph truncation or a horizontal-only layout.

    private func singleFileDiff(_ diffText: String) -> some View {
        let rows = parseUnified(diffText)
        return GeometryReader { geo in
            ScrollView(.vertical, showsIndicators: true) {
                unifiedDiffRows(rows)
                    .frame(minWidth: geo.size.width, maxWidth: .infinity, minHeight: geo.size.height, alignment: .topLeading)
            }
        }
    }

    @ViewBuilder
    private func unifiedDiffRows(_ rows: [UnifiedDiffRow]) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(rows.indices, id: \.self) { i in
                let row = rows[i]
                if row.kind == .hunkHeader {
                    if expandedHunks.contains(row.hunkIndex),
                       let lines = cachedFileLines,
                       !lines.isEmpty {
                        let fromLine = row.prevNewEnd
                        let toLine = row.newStartLine
                        ForEach(fromLine..<toLine, id: \.self) { lineNo in
                            let idx = lineNo - 1
                            let content = idx >= 0 && idx < lines.count ? lines[idx] : ""
                            unifiedLineRow(
                                oldLineNo: lineNo,
                                newLineNo: lineNo,
                                content: content,
                                kind: .context
                            )
                        }
                    } else if expandedHunks.contains(row.hunkIndex),
                              cachedFileLines != nil,
                              cachedFileLines?.isEmpty == true {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Loading unmodified lines…")
                                .font(AppFonts.caption)
                                .foregroundStyle(AppPalette.textTertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: 28)
                        .padding(.horizontal, 10)
                        .background(AppPalette.elevated)
                    } else if row.skippedLines > 0 {
                        hunkHeaderBar(skippedLines: row.skippedLines, hunkIndex: row.hunkIndex)
                    }
                } else {
                    unifiedLineRow(
                        oldLineNo: row.oldLineNo,
                        newLineNo: row.newLineNo,
                        content: row.content,
                        kind: row.kind
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func unifiedLineRow(
        oldLineNo: Int?,
        newLineNo: Int?,
        content: String,
        kind: DiffRowKind
    ) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Rectangle()
                .fill(unifiedGutterColor(kind))
                .frame(width: 3)

            Text(oldLineNo.map { String($0) } ?? "")
                .font(AppFonts.diffCode)
                .foregroundStyle(AppPalette.textTertiary)
                .monospacedDigit()
                .frame(width: 36, alignment: .trailing)
                .padding(.trailing, 4)
                .padding(.top, 1)

            Text(newLineNo.map { String($0) } ?? "")
                .font(AppFonts.diffCode)
                .foregroundStyle(AppPalette.textTertiary)
                .monospacedDigit()
                .frame(width: 36, alignment: .trailing)
                .padding(.trailing, 6)
                .padding(.top, 1)

            Text(unifiedPrefix(kind))
                .font(AppFonts.diffCode.weight(.semibold))
                .foregroundStyle(unifiedPrefixColor(kind))
                .frame(width: 12, alignment: .center)
                .padding(.top, 1)

            Text(highlightCode(content.isEmpty ? " " : content))
                .font(AppFonts.diffCode)
                // Wrap to pane width — no mid-line clip, no forced horizontal scroll.
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 8)
                .padding(.vertical, 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(unifiedRowBackground(kind))
    }

    private func unifiedPrefix(_ kind: DiffRowKind) -> String {
        switch kind {
        case .added: return "+"
        case .removed: return "−"
        case .context, .hunkHeader: return " "
        }
    }

    private func unifiedPrefixColor(_ kind: DiffRowKind) -> Color {
        switch kind {
        case .added: return Color(nsColor: .systemGreen)
        case .removed: return Color(nsColor: .systemRed)
        case .context, .hunkHeader: return AppPalette.textTertiary
        }
    }

    private func unifiedGutterColor(_ kind: DiffRowKind) -> Color {
        switch kind {
        case .added: return Color(nsColor: .systemGreen)
        case .removed: return Color(nsColor: .systemRed)
        case .context, .hunkHeader: return .clear
        }
    }

    private func unifiedRowBackground(_ kind: DiffRowKind) -> Color {
        switch kind {
        case .added: return Color(nsColor: .systemGreen).opacity(0.12)
        case .removed: return Color(nsColor: .systemRed).opacity(0.12)
        case .hunkHeader: return Color(nsColor: .systemBlue).opacity(0.06)
        case .context: return diffBgColor
        }
    }

    private func commitStatusColor(_ status: DiffFileStatus) -> Color {
        switch status {
        case .added: return .green
        case .deleted: return .red
        case .modified: return .yellow
        case .renamed: return .blue
        }
    }

    private func hunkHeaderBar(skippedLines: Int, hunkIndex: Int) -> some View {
        Button {
            loadFileIfNeeded()
            expandedHunks.insert(hunkIndex)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.down")
                    .font(AppFonts.tinyIcon)
                    .foregroundStyle(AppPalette.textTertiary)
                Text("\(skippedLines) unmodified lines")
                    .font(AppFonts.secondaryLabel)
                    .foregroundStyle(AppPalette.textSecondary)
                Image(systemName: "chevron.down")
                    .font(AppFonts.tinyIcon)
                    .foregroundStyle(AppPalette.textTertiary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(AppPalette.elevated)
    }

    private func loadFileIfNeeded() {
        guard cachedFileLines == nil,
              let repoURL = store.repositoryURL,
              let path = store.selectedChange?.path else { return }
        let fileURL = repoURL.appendingPathComponent(path)
        cachedFileLines = [] // sentinel: prevents duplicate loads while async in flight
        Task {
            let lines = await Task.detached(priority: .userInitiated) {
                (try? String(contentsOf: fileURL, encoding: .utf8))?.components(separatedBy: "\n") ?? []
            }.value
            // Guard: selection may have changed while the detached read was in flight.
            // If so, reset the sentinel so the new selection's loadFileIfNeeded can run.
            guard store.selectedChange?.path == path else {
                cachedFileLines = nil
                return
            }
            cachedFileLines = lines
            if lines.isEmpty {
                store.errorMessage = "Could not read \(fileURL.lastPathComponent)"
            }
        }
    }

    // MARK: - Diff Parsing (unified)

    private enum DiffRowKind { case context, added, removed, hunkHeader }

    private struct UnifiedDiffRow {
        let oldLineNo: Int?
        let newLineNo: Int?
        let content: String
        let kind: DiffRowKind
        var skippedLines: Int = 0
        var hunkIndex: Int = 0
        var newStartLine: Int = 0
        var prevNewEnd: Int = 0
    }

    private func parseUnified(_ diffText: String) -> [UnifiedDiffRow] {
        var rows: [UnifiedDiffRow] = []
        var oldNo = 0, newNo = 0
        var prevNewEnd = 1 // 1-based: next expected new line
        var hunkIdx = 0

        for line in diffText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if isDiffMeta(line) { continue }
            if line.hasPrefix("@@") {
                let newOldStart: Int
                let newNewStart: Int
                if let m1 = line.range(of: #"-(\d+)"#, options: .regularExpression),
                   let m2 = line.range(of: #"\+(\d+)"#, options: .regularExpression) {
                    newOldStart = Int(line[m1].dropFirst()) ?? 1
                    newNewStart = Int(line[m2].dropFirst()) ?? 1
                } else {
                    newOldStart = oldNo
                    newNewStart = newNo
                }
                let skipped = max(0, newNewStart - prevNewEnd)
                oldNo = newOldStart
                newNo = newNewStart
                var row = UnifiedDiffRow(
                    oldLineNo: nil,
                    newLineNo: nil,
                    content: line,
                    kind: .hunkHeader
                )
                row.skippedLines = skipped
                row.hunkIndex = hunkIdx
                row.newStartLine = newNewStart
                row.prevNewEnd = prevNewEnd
                rows.append(row)
                hunkIdx += 1
                continue
            }
            if line.hasPrefix("-") {
                rows.append(UnifiedDiffRow(
                    oldLineNo: oldNo,
                    newLineNo: nil,
                    content: String(line.dropFirst()),
                    kind: .removed
                ))
                oldNo += 1
            } else if line.hasPrefix("+") {
                rows.append(UnifiedDiffRow(
                    oldLineNo: nil,
                    newLineNo: newNo,
                    content: String(line.dropFirst()),
                    kind: .added
                ))
                newNo += 1
                prevNewEnd = newNo
            } else {
                let c = line.hasPrefix(" ") ? String(line.dropFirst()) : line
                rows.append(UnifiedDiffRow(
                    oldLineNo: oldNo,
                    newLineNo: newNo,
                    content: c,
                    kind: .context
                ))
                oldNo += 1
                newNo += 1
                prevNewEnd = newNo
            }
        }
        return rows
    }

    private func isDiffMeta(_ line: String) -> Bool {
        line.hasPrefix("diff ") || line.hasPrefix("index ") || line.hasPrefix("--- ") || line.hasPrefix("+++ ")
            || line.hasPrefix("old mode") || line.hasPrefix("new mode") || line.hasPrefix("new file mode")
            || line.hasPrefix("deleted file mode") || line.hasPrefix("similarity index")
            || line.hasPrefix("rename ") || line.hasPrefix("copy ")
    }

    // MARK: - Syntax Highlighting

    private var selectedFileExtension: String? {
        guard let path = store.selectedChange?.path, let ext = path.split(separator: ".").last else { return nil }
        let n = ext.lowercased(); return n.isEmpty ? nil : n
    }

    private func highlightCode(_ code: String) -> AttributedString {
        let text = code.isEmpty ? " " : code
        var attr = AttributedString(text)
        attr.foregroundColor = diffTextColor
        guard let ext = selectedFileExtension else { return attr }
        if let cp = commentPattern(for: ext) { applyHL(cp, Color(nsColor: AppEditorTheme.comment), &attr, text) }
        applyHL(#"\"([^\"\\]|\\.)*\"|'([^'\\]|\\.)*'"#, Color(nsColor: AppEditorTheme.string), &attr, text)
        if let kp = keywordPattern(for: ext) { applyHL(kp, Color(nsColor: AppEditorTheme.keyword), &attr, text) }
        applyHL(#"\b\d+(\.\d+)?\b"#, Color(nsColor: AppEditorTheme.number), &attr, text)
        return attr
    }

    private func applyHL(_ pattern: String, _ color: Color, _ attr: inout AttributedString, _ text: String) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let r = Range(match.range, in: text), let ar = Range(r, in: attr) else { continue }
            attr[ar].foregroundColor = color
        }
    }

    private func keywordPattern(for ext: String) -> String? {
        switch ext {
        case "swift": return #"\b(import|let|var|func|struct|class|enum|protocol|extension|if|else|for|while|switch|case|default|guard|return|defer|do|catch|throw|throws|try|async|await|actor|where|in|self|Self|true|false|nil|private|public|internal|static|override)\b"#
        case "ts", "tsx", "js", "jsx": return #"\b(import|from|export|const|let|var|function|class|interface|type|if|else|for|while|switch|case|default|return|try|catch|throw|async|await|new|typeof|this|true|false|null|undefined)\b"#
        case "py": return #"\b(import|from|as|def|class|if|elif|else|for|while|return|try|except|finally|raise|with|lambda|async|await|yield|True|False|None|self)\b"#
        case "go": return #"\b(package|import|func|type|struct|interface|var|const|if|else|for|switch|case|default|return|defer|go|range|map|chan|select|true|false|nil)\b"#
        case "rs": return #"\b(use|mod|fn|struct|enum|impl|trait|let|mut|if|else|for|while|loop|match|return|pub|async|await|move|self|Self|true|false)\b"#
        case "c", "h", "cpp", "hpp", "cc": return #"\b(include|define|typedef|struct|enum|class|if|else|for|while|switch|case|return|static|const|void|int|char|float|double|bool|auto|true|false|NULL)\b"#
        case "yaml", "yml": return #"\b(true|false|null|yes|no|on|off)\b"#
        default: return nil
        }
    }

    private func commentPattern(for ext: String) -> String? {
        switch ext {
        case "swift", "ts", "tsx", "js", "jsx", "go", "rs", "java", "kt", "c", "h", "cpp", "hpp", "cc": return #"//.*$"#
        case "py", "sh", "zsh", "bash", "rb", "yaml", "yml", "toml": return #"#.*$"#
        default: return nil
        }
    }

    // MARK: - Multi-select

    private var allChanges: [GitFileChange] {
        let s = store.statusSnapshot
        return (s?.staged ?? []) + (s?.modified ?? []) + (s?.untracked ?? [])
    }

    private func handleClick(_ change: GitFileChange) {
        let modifiers = NSEvent.modifierFlags

        if modifiers.contains(.command) {
            // Cmd+Click: toggle
            if selectedIDs.contains(change.id) {
                selectedIDs.remove(change.id)
            } else {
                selectedIDs.insert(change.id)
            }
        } else if modifiers.contains(.shift), let lastID = lastClickedID {
            // Shift+Click: range select
            let items = allChanges
            if let fromIdx = items.firstIndex(where: { $0.id == lastID }),
               let toIdx = items.firstIndex(where: { $0.id == change.id }) {
                let range = min(fromIdx, toIdx)...max(fromIdx, toIdx)
                for i in range { selectedIDs.insert(items[i].id) }
            }
        } else {
            // Normal click: single select
            selectedIDs = [change.id]
        }

        lastClickedID = change.id
        // Picking a change in list-only mode auto-expands the diff so the
        // click has a visible effect.
        if !rightDockStore.gitShowsDiff {
            rightDockStore.gitShowsDiff = true
        }
        store.selectChange(change)
    }

    private func selectedChanges(in section: [GitFileChange]) -> [GitFileChange] {
        section.filter { selectedIDs.contains($0.id) }
    }

    // MARK: - Helpers

    private func isImagePath(_ path: String) -> Bool {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        return Self.imageExtensions.contains(ext)
    }

    private var hasAnyChanges: Bool {
        store.statusSnapshot?.hasAnyChanges ?? false
    }

    private var commitEnabled: Bool {
        !store.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !store.isRunningCommand
            && hasAnyChanges
    }

    private func statusBanner(text: String, color: Color, onDismiss: @escaping () -> Void) -> some View {
        HStack {
            Text(text).font(AppFonts.caption).lineLimit(2)
            Spacer(minLength: 4)
            Button { onDismiss() } label: {
                Image(systemName: "xmark").font(AppFonts.tinyIcon)
            }.buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(color.opacity(0.12))
    }

    private func requestDiscard(changes: [GitFileChange]) {
        let d = changes.filter { $0.section == .modified || $0.section == .untracked }
        guard !d.isEmpty else { return }
        confirmationAction = .discardChanges(changes: d)
    }

    private var isShowingConfirmation: Binding<Bool> {
        Binding(get: { confirmationAction != nil }, set: { if !$0 { confirmationAction = nil } })
    }

    @ViewBuilder
    private func confirmationButtons(for action: GitConfirmationAction) -> some View {
        switch action {
        case .deleteBranch(let branch):
            Button("Delete", role: .destructive) { store.deleteBranch(name: branch, force: false); confirmationAction = nil }
            Button("Force Delete", role: .destructive) { store.deleteBranch(name: branch, force: true); confirmationAction = nil }
            Button("Cancel", role: .cancel) { confirmationAction = nil }
        case .discardChanges(let changes):
            Button("Discard", role: .destructive) { store.discard(changes); confirmationAction = nil }
            Button("Cancel", role: .cancel) { confirmationAction = nil }
        }
    }

    private func confirmationMessage(for action: GitConfirmationAction) -> String {
        switch action {
        case .deleteBranch(let branch): return "Delete branch `\(branch)`?"
        case .discardChanges(let changes):
            if changes.count == 1, let c = changes.first { return "Discard changes for `\(c.path)`? This cannot be undone." }
            return "Discard \(changes.count) changes? This cannot be undone."
        }
    }

    // MARK: - Diff Helpers

    private let diffBgColor = AppPalette.surface
    private let diffTextColor = AppPalette.textPrimary
}

// MARK: - Working Tree Image Diff View

private struct WorkingTreeImageDiffView: View {
    let change: GitFileChange
    let repositoryURL: URL?

    @State private var newImage: NSImage?
    @State private var oldImage: NSImage?
    @State private var loaded = false

    private var isNew: Bool { change.workTreeStatus == "?" || change.indexStatus == "A" }
    private var isDeleted: Bool { change.workTreeStatus == "D" }

    var body: some View {
        HStack(spacing: 0) {
            // Left: old version (from HEAD)
            imageSide(
                label: isNew ? nil : "Before",
                color: .red,
                image: isNew ? nil : oldImage,
                placeholder: isNew ? "(new file)" : nil
            )

            Rectangle().fill(AppPalette.border).frame(width: 1)

            // Right: current working tree version
            imageSide(
                label: isDeleted ? nil : "After",
                color: .green,
                image: isDeleted ? nil : newImage,
                placeholder: isDeleted ? "(deleted)" : nil
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: change.id) {
            await loadImages()
        }
    }

    private func imageSide(label: String?, color: Color, image: NSImage?, placeholder: String?) -> some View {
        ZStack {
            if let image {
                VStack(spacing: 4) {
                    if let label {
                        Text(label)
                            .font(AppFonts.badge.weight(.bold))
                            .foregroundStyle(color)
                    }
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(color.opacity(0.3), lineWidth: 1)
                        )
                }
                .padding(12)
            } else if let placeholder {
                Text(placeholder)
                    .font(AppFonts.caption)
                    .foregroundStyle(AppPalette.textTertiary)
            } else if !loaded {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(color.opacity(image != nil ? 0.04 : 0.02))
    }

    private func loadImages() async {
        guard let repositoryURL else { loaded = true; return }

        // Current file from disk
        if !isDeleted {
            let fileURL = repositoryURL.appendingPathComponent(change.path)
            newImage = NSImage(contentsOf: fileURL)
        }

        // Old version from HEAD
        if !isNew {
            let git = GitService(workingDirectory: repositoryURL)
            let ref = change.section == .staged ? "HEAD" : "HEAD"
            if let data = try? await git.fileData(at: ref, path: change.path) {
                oldImage = NSImage(data: data)
            }
        }

        loaded = true
    }
}

// MARK: - Commit Image Diff View

private struct CommitImageDiffView: View {
    let hash: String
    let path: String
    let status: DiffFileStatus
    let repositoryURL: URL?

    @State private var newImage: NSImage?
    @State private var oldImage: NSImage?
    @State private var loaded = false
    @State private var loadError: String?

    var body: some View {
        HStack(spacing: 0) {
            // Left side (old / before)
            imageSide(
                label: status == .added ? nil : "Before",
                color: .red,
                image: status == .added ? nil : oldImage,
                placeholder: status == .added ? "(new file)" : nil
            )

            Rectangle().fill(AppPalette.border).frame(width: 1)

            // Right side (new / after)
            imageSide(
                label: status == .deleted ? nil : "After",
                color: .green,
                image: status == .deleted ? nil : newImage,
                placeholder: status == .deleted ? "(deleted)" : nil
            )
        }
        .frame(height: 200)
        .task(id: hash + path) {
            await loadImages()
        }
    }

    private func imageSide(label: String?, color: Color, image: NSImage?, placeholder: String?) -> some View {
        ZStack {
            if let image {
                VStack(spacing: 4) {
                    if let label {
                        Text(label)
                            .font(AppFonts.badge.weight(.bold))
                            .foregroundStyle(color)
                    }
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(color.opacity(0.3), lineWidth: 1)
                        )
                }
                .padding(8)
            } else if let placeholder {
                Text(placeholder)
                    .font(AppFonts.caption)
                    .foregroundStyle(AppPalette.textTertiary)
            } else if !loaded {
                ProgressView().controlSize(.small)
            } else {
                Text(loadError ?? "Image unavailable")
                    .font(AppFonts.caption)
                    .foregroundStyle(AppPalette.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(color.opacity(image != nil ? 0.04 : 0.02))
    }

    private func loadImages() async {
        guard let repositoryURL, !hash.isEmpty else { loaded = true; return }
        let git = GitService(workingDirectory: repositoryURL)

        if status != .deleted {
            do {
                let data = try await git.fileData(at: hash, path: path)
                newImage = NSImage(data: data)
            } catch {
                loadError = "Failed to load image"
            }
        }

        if status != .added {
            do {
                let data = try await git.fileData(at: "\(hash)^", path: path)
                oldImage = NSImage(data: data)
            } catch {
                if loadError == nil { loadError = "Failed to load image" }
            }
        }

        loaded = true
    }
}

// MARK: - Split Diff by File

enum DiffFileStatus: Character {
    case added = "A"
    case modified = "M"
    case deleted = "D"
    case renamed = "R"
}

struct FileDiffSection: Identifiable {
    let path: String
    let status: DiffFileStatus
    let diff: String
    var id: String { path }
}

func splitDiffByFile(_ fullDiff: String) -> [FileDiffSection] {
    let lines = fullDiff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var sections: [FileDiffSection] = []
    var currentPath = ""
    var currentStatus: DiffFileStatus = .modified
    var currentLines: [String] = []

    for line in lines {
        if line.hasPrefix("diff --git ") {
            // Flush previous
            if !currentPath.isEmpty {
                sections.append(FileDiffSection(path: currentPath, status: currentStatus, diff: currentLines.joined(separator: "\n")))
            }
            // Parse path: "diff --git a/foo b/foo" → "foo"
            // Use " b/" separator (not space split) to handle paths with spaces
            if let bRange = line.range(of: " b/", options: .backwards) {
                currentPath = String(line[line.index(bRange.lowerBound, offsetBy: 3)...])
            } else {
                currentPath = "unknown"
            }
            currentStatus = .modified
            currentLines = []
        } else if line.hasPrefix("new file") {
            currentStatus = .added
        } else if line.hasPrefix("deleted file") {
            currentStatus = .deleted
        } else if line.hasPrefix("rename ") || line.hasPrefix("similarity index") {
            currentStatus = .renamed
        } else {
            currentLines.append(line)
        }
    }

    // Flush last
    if !currentPath.isEmpty {
        sections.append(FileDiffSection(path: currentPath, status: currentStatus, diff: currentLines.joined(separator: "\n")))
    }

    return sections
}

// MARK: - Git Graph Content (swim lanes + commit list)

private let graphRowHeight: CGFloat = 26
private let graphColWidth: CGFloat = 12
/// Enough room for a selected circle (r+1) so the leftmost lane isn't
/// mid-clipped by the scroll view edge.
private let graphLeftPad: CGFloat = 10
private let graphCircleR: CGFloat = 3.5

private let laneColors = AppGraphColors.lanes

struct GraphNode {
    let hash: String
    let column: Int
    let row: Int
    let color: Color
}

struct GraphLayout {
    let nodes: [GraphNode]
    let segments: [(col: Int, row: Int, color: Color)]
    let connectors: [(fromCol: Int, fromRow: Int, toCol: Int, toRow: Int, color: Color)]
    let maxColumns: Int
}

func computeGraphLayout(entries: [GitLogEntry]) -> GraphLayout {
    guard !entries.isEmpty else {
        return GraphLayout(nodes: [], segments: [], connectors: [], maxColumns: 0)
    }

    var hashToRow: [String: Int] = [:]
    for (i, entry) in entries.enumerated() { hashToRow[entry.hash] = i }

    var lanes: [String?] = []
    var nodes: [GraphNode] = []
    var segments: [(col: Int, row: Int, color: Color)] = []
    var connectors: [(fromCol: Int, fromRow: Int, toCol: Int, toRow: Int, color: Color)] = []
    var maxColumns = 0

    for row in 0..<entries.count {
        let entry = entries[row]
        let hash = entry.hash

        var column = lanes.firstIndex(of: hash) ?? -1
        if column == -1 {
            column = lanes.firstIndex(of: nil as String?) ?? lanes.count
            if column == lanes.count { lanes.append(nil) }
            lanes[column] = hash
        }

        let color = laneColors[column % laneColors.count]
        nodes.append(GraphNode(hash: hash, column: column, row: row, color: color))

        // Collapse duplicate lanes
        for i in (column + 1)..<lanes.count {
            if lanes[i] == hash {
                connectors.append((i, row, column, row, laneColors[i % laneColors.count]))
                lanes[i] = nil
            }
        }

        if entry.parents.isEmpty {
            lanes[column] = nil
        } else {
            let firstParent = entry.parents[0]
            lanes[column] = hashToRow[firstParent] != nil ? firstParent : nil

            for p in 1..<entry.parents.count {
                let parentHash = entry.parents[p]
                guard hashToRow[parentHash] != nil else { continue }
                var parentLane = lanes.firstIndex(of: parentHash) ?? -1
                if parentLane == -1 {
                    parentLane = lanes.firstIndex(of: nil as String?) ?? lanes.count
                    if parentLane == lanes.count { lanes.append(nil) }
                    lanes[parentLane] = parentHash
                }
                if parentLane != column {
                    connectors.append((column, row, parentLane, row + 1, laneColors[parentLane % laneColors.count]))
                }
            }
        }

        while !lanes.isEmpty && lanes.last == nil { lanes.removeLast() }
        maxColumns = max(maxColumns, lanes.count, column + 1)

        if row < entries.count - 1 {
            for c in 0..<lanes.count where lanes[c] != nil {
                segments.append((c, row, laneColors[c % laneColors.count]))
            }
        }
    }

    return GraphLayout(nodes: nodes, segments: segments, connectors: connectors, maxColumns: maxColumns)
}

private struct GitGraphContentView: View {
    let entries: [GitLogEntry]
    let selectedHash: String?
    let onSelect: (String) -> Void
    let onLoadMore: () -> Void
    let hasMore: Bool

    @State private var layout = GraphLayout(nodes: [], segments: [], connectors: [], maxColumns: 0)

    /// Lightweight identity for detecting entries changes without requiring Equatable
    private var entriesIdentity: String {
        "\(entries.count)-\(entries.first?.hash ?? "")-\(entries.last?.hash ?? "")"
    }

    var body: some View {
        // Right pad matches left so multi-lane graphs aren't flush against the
        // message column; +2 gives the selected ring a pixel of air.
        let graphWidth = graphLeftPad
            + CGFloat(max(layout.maxColumns, 1)) * graphColWidth
            + graphLeftPad

        HStack(alignment: .top, spacing: 0) {
            // SVG-like graph using Canvas
            Canvas { context, _ in
                func cx(_ col: Int) -> CGFloat { graphLeftPad + CGFloat(col) * graphColWidth + graphColWidth / 2 }
                func cy(_ row: Int) -> CGFloat { CGFloat(row) * graphRowHeight + graphRowHeight / 2 }

                // Lane segments
                for seg in layout.segments {
                    var path = Path()
                    path.move(to: CGPoint(x: cx(seg.col), y: cy(seg.row)))
                    path.addLine(to: CGPoint(x: cx(seg.col), y: cy(seg.row + 1)))
                    context.stroke(path, with: .color(seg.color.opacity(0.7)), lineWidth: 1.5)
                }

                // Connectors
                for conn in layout.connectors {
                    let x1 = cx(conn.fromCol), y1 = cy(conn.fromRow)
                    let x2 = cx(conn.toCol), y2 = cy(conn.toRow)
                    var path = Path()
                    path.move(to: CGPoint(x: x1, y: y1))
                    if conn.fromRow == conn.toRow {
                        let belowY = y1 + graphRowHeight / 2
                        path.addQuadCurve(to: CGPoint(x: x2, y: y2), control: CGPoint(x: x1, y: belowY))
                    } else {
                        let midY = (y1 + y2) / 2
                        path.addCurve(to: CGPoint(x: x2, y: y2),
                                       control1: CGPoint(x: x1, y: midY),
                                       control2: CGPoint(x: x2, y: midY))
                    }
                    context.stroke(path, with: .color(conn.color.opacity(0.7)), lineWidth: 1.5)
                }

                // Commit circles
                for node in layout.nodes {
                    let isSelected = node.hash == selectedHash
                    let r = isSelected ? graphCircleR + 1 : graphCircleR
                    let rect = CGRect(x: cx(node.column) - r, y: cy(node.row) - r, width: r * 2, height: r * 2)
                    context.fill(Path(ellipseIn: rect), with: .color(node.color))
                    if isSelected {
                        context.stroke(Path(ellipseIn: rect), with: .color(.white), lineWidth: 1.5)
                    }
                }
            }
            .frame(width: graphWidth, height: CGFloat(entries.count) * graphRowHeight)
            .fixedSize(horizontal: true, vertical: false)

            // Commit list — min width so HSplit crushing can't hide the message.
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(entries) { entry in
                    CommitRow(entry: entry, isSelected: entry.hash == selectedHash)
                        .onTapGesture { onSelect(entry.hash) }
                }

                if hasMore {
                    Text("Loading more...")
                        .font(AppFonts.caption)
                        .foregroundStyle(AppPalette.textTertiary)
                        .frame(height: graphRowHeight)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .onAppear { onLoadMore() }
                }
            }
            .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 2)
        .onAppear {
            layout = computeGraphLayout(entries: entries)
        }
        .onChange(of: entriesIdentity) { _, _ in
            layout = computeGraphLayout(entries: entries)
        }
    }
}

private struct CommitRow: View {
    let entry: GitLogEntry
    let isSelected: Bool

    @State private var hovering = false
    private static let iso8601 = ISO8601DateFormatter()

    var body: some View {
        HStack(spacing: 5) {
            // At most one badge so the commit message isn't crushed in a
            // narrow dock column (was rendering 2–3 truncated pills).
            if let badge = primaryBadge {
                Text(badge.label)
                    .font(AppFonts.badge)
                    .lineLimit(1)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(badge.color.opacity(0.15))
                    .foregroundStyle(badge.color)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    .layoutPriority(1)
                    .help(badge.fullLabel)
            }

            Text(entry.message)
                .font(AppFonts.secondaryLabel)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(isSelected ? AppPalette.textPrimary : AppPalette.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(0)

            Text(relativeDate)
                .font(AppFonts.caption)
                .foregroundStyle(AppPalette.textTertiary)
                .monospacedDigit()
                .frame(minWidth: 28, alignment: .trailing)
                .layoutPriority(2)
        }
        .padding(.horizontal, 6)
        .frame(height: graphRowHeight)
        .selectableRowChrome(isSelected: isSelected, isHovering: hovering, accentBarHeight: 11)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(entry.message)
    }

    private struct RefBadge {
        let label: String
        let fullLabel: String
        let color: Color
    }

    /// Prefer HEAD branch, then a local branch, then a tag — never dump every ref.
    private var primaryBadge: RefBadge? {
        let refs = entry.refs
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }

        if let head = refs.first(where: { $0.hasPrefix("HEAD -> ") }) {
            let name = String(head.dropFirst(8))
            return RefBadge(label: abbreviatedBranch(name), fullLabel: name, color: Color(nsColor: .systemGreen))
        }
        if refs.contains("HEAD") {
            return RefBadge(label: "HEAD", fullLabel: "HEAD", color: Color(nsColor: .systemGreen))
        }
        if let local = refs.first(where: { !$0.contains("/") && !$0.hasPrefix("tag: ") }) {
            return RefBadge(label: abbreviatedBranch(local), fullLabel: local, color: Color(nsColor: .systemBlue))
        }
        if let tag = refs.first(where: { $0.hasPrefix("tag: ") }) {
            let name = String(tag.dropFirst(5))
            return RefBadge(label: abbreviatedBranch(name), fullLabel: name, color: Color(nsColor: .systemYellow))
        }
        return nil
    }

    private func abbreviatedBranch(_ name: String) -> String {
        // Keep short names intact; long ones like "sanvibyfish/v2-2" → "v2-2".
        if name.count <= 12 { return name }
        if let slash = name.lastIndex(of: "/") {
            let tail = String(name[name.index(after: slash)...])
            if !tail.isEmpty, tail.count <= 14 { return tail }
        }
        return String(name.prefix(11)) + "…"
    }

    private var relativeDate: String {
        guard let date = Self.iso8601.date(from: entry.date) else { return "" }
        let diff = Int(Date().timeIntervalSince(date))
        if diff < 60 { return "now" }
        if diff < 3600 { return "\(diff / 60)m" }
        if diff < 86400 { return "\(diff / 3600)h" }
        if diff < 604800 { return "\(diff / 86400)d" }
        if diff < 2592000 { return "\(diff / 604800)w" }
        if diff < 31536000 { return "\(diff / 2592000)mo" }
        return "\(diff / 31536000)y"
    }
}

// MARK: - Collapsible Section

private struct CollapsibleSection<Content: View>: View {
    let title: String
    let count: Int
    let action: () -> AnyView
    @ViewBuilder let content: () -> Content
    @State private var isExpanded = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(AppFonts.tinyIcon.weight(.bold))
                            .foregroundStyle(AppPalette.textTertiary)
                            .frame(width: 10)
                        SectionTitle(title)
                    }
                }
                .buttonStyle(.plain)

                Spacer(minLength: 4)

                action()
                    .foregroundStyle(AppPalette.textSecondary)

                Text("\(count)")
                    .font(AppFonts.badge)
                    .foregroundStyle(AppPalette.textSecondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(AppPalette.surface))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            if isExpanded {
                content()
                    .padding(.bottom, 2)
            }
        }
    }
}

// MARK: - File Status Row

private struct FileStatusRow: View {
    let change: GitFileChange
    let isSelected: Bool
    var selectedCount: Int = 0
    var actionIcon: String
    var actionHelp: String
    var discardable: Bool = false
    let onSelect: () -> Void
    var onAction: (() -> Void)?
    var onDiscard: (() -> Void)?
    @State private var hovering = false

    private var isBatch: Bool { isSelected && selectedCount > 1 }

    private var fileName: String { change.path.split(separator: "/").last.map(String.init) ?? change.path }
    private var dirPath: String {
        guard change.path.contains("/") else { return "" }
        return String(change.path.prefix(upTo: change.path.lastIndex(of: "/")!))
    }

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 0) {
                Text(fileName)
                    .font(AppFonts.secondaryLabel)
                    .foregroundStyle(isSelected ? AppPalette.textPrimary : AppPalette.textSecondary)
                    .lineLimit(1)
                if !dirPath.isEmpty {
                    Text("  \(dirPath)")
                        .font(AppFonts.caption)
                        .foregroundStyle(AppPalette.textTertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if hovering {
                if discardable, let onDiscard {
                    Image(systemName: "arrow.uturn.backward")
                        .font(AppFonts.smallIcon)
                        .foregroundStyle(AppPalette.textSecondary)
                        .onTapGesture { onDiscard() }
                        .help("Discard")
                }
                if let onAction {
                    Image(systemName: actionIcon)
                        .font(AppFonts.toolbarIcon.weight(.semibold))
                        .foregroundStyle(AppPalette.textSecondary)
                        .onTapGesture { onAction() }
                        .help(actionHelp)
                }
            }

            Text(statusLetter)
                .font(AppFonts.diffCode.weight(.medium))
                .foregroundStyle(statusColor)
                .frame(width: 12, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .selectableRowChrome(isSelected: isSelected, isHovering: hovering)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 1) { onSelect() }
        .contextMenu {
            if let onAction {
                let label = change.section == .staged
                    ? (isBatch ? "Unstage \(selectedCount) Files" : "Unstage")
                    : (isBatch ? "Stage \(selectedCount) Files" : "Stage")
                Button(label) { onAction() }
            }
            if discardable, let onDiscard {
                Button(isBatch ? "Discard \(selectedCount) Files" : "Discard Changes") { onDiscard() }
            }
            Divider()
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(change.path, forType: .string)
            }
        }
    }

    private var statusLetter: String {
        switch change.section {
        case .staged: return String(change.indexStatus)
        case .modified: return String(change.workTreeStatus)
        case .untracked: return "U"
        }
    }

    private var statusColor: Color {
        switch statusLetter {
        case "M": return Color(nsColor: .systemYellow)
        case "A": return Color(nsColor: .systemGreen)
        case "D": return Color(nsColor: .systemRed)
        case "R": return Color(nsColor: .systemPurple)
        default: return AppPalette.textSecondary
        }
    }
}

private enum GitConfirmationAction {
    case deleteBranch(branch: String)
    case discardChanges(changes: [GitFileChange])
}
