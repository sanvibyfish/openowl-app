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
                    leftSplitView
                        .frame(idealWidth: 220, maxWidth: 280)
                    diffPanel
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
            changesPanel
                .frame(minHeight: 180)

            gitGraphPanel
                .frame(minHeight: 120)
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
            }
            .scrollEdgeEffectIfAvailable(for: .top)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

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
        .frame(height: AppSpacing.headerHeight)
        .background(RailChrome.background)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(RailChrome.hairline)
                .frame(height: 1)
        }
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
                    .frame(height: store.commitMessage.contains("\n") ? 52 : 28)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .padding(.trailing, 20)
                    .background(AppPalette.elevated)
                    .clipShape(RoundedRectangle(cornerRadius: AppSpacing.cornerRadiusSmall))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppSpacing.cornerRadiusSmall)
                            .stroke(commitFieldFocused ? AppPalette.accent.opacity(0.5) : AppPalette.border, lineWidth: 1)
                    )
                    .focused($commitFieldFocused)
                    .overlay(alignment: .topLeading) {
                        if store.commitMessage.isEmpty {
                            Text("Commit message")
                                .font(AppFonts.secondaryLabel)
                                .foregroundStyle(AppPalette.textTertiary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .allowsHitTesting(false)
                        }
                    }

                if store.isGeneratingMessage {
                    Button {
                        store.cancelGenerateCommitMessage()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(AppFonts.smallIcon)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 24, height: 24)
                    .padding(2)
                    .help("Stop generating")
                    .accessibilityLabel("Stop generating")
                } else if store.commitMessage.isEmpty {
                    Button {
                        store.generateCommitMessage()
                    } label: {
                        Image(systemName: "sparkles")
                            .font(AppFonts.toolbarIcon)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 24, height: 24)
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
                        .font(AppFonts.secondaryLabel.weight(.medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: AppSpacing.cornerRadiusSmall)
                        .fill(commitEnabled ? AppPalette.accent.opacity(0.15) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppSpacing.cornerRadiusSmall)
                        .stroke(commitEnabled ? AppPalette.accent.opacity(0.3) : AppPalette.border, lineWidth: 1)
                )
                .foregroundStyle(commitEnabled ? AppPalette.accent : AppPalette.textTertiary)
            }
            .buttonStyle(.plain)
            .disabled(!commitEnabled)
        }
        .padding(.horizontal, AppSpacing.panelPadding)
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
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle")
                    .font(AppFonts.title)
                    .foregroundStyle(AppPalette.textTertiary)
                Text("No changes detected")
                    .font(AppFonts.secondaryLabel)
                    .foregroundStyle(AppPalette.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }
    }

    // MARK: - Left Bottom: Git Graph Panel

    private var gitGraphPanel: some View {
        VStack(spacing: 0) {
            // Toolbar: branch + remote actions
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(AppFonts.toolbarIcon)
                    .foregroundStyle(.secondary)
                Text(store.statusSnapshot?.branch ?? "—")
                    .font(AppFonts.secondaryLabel.weight(.medium))
                    .lineLimit(1)

                Spacer(minLength: 4)

                // Ahead/Behind pill badges
                if let snapshot = store.statusSnapshot {
                    if snapshot.behindCount > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "arrow.down").font(AppFonts.tinyIcon)
                            Text("\(snapshot.behindCount)").font(AppFonts.badge)
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.12))
                        .clipShape(Capsule())
                    }
                    if snapshot.aheadCount > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "arrow.up").font(AppFonts.tinyIcon)
                            Text("\(snapshot.aheadCount)").font(AppFonts.badge)
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.12))
                        .clipShape(Capsule())
                    }
                }

                Button { store.pull() } label: {
                    Image(systemName: "arrow.down").font(AppFonts.toolbarIcon)
                }
                .buttonStyle(.plain).help("Pull").accessibilityLabel("Pull").disabled(store.isRunningCommand)

                Button { store.push() } label: {
                    Image(systemName: "arrow.up").font(AppFonts.toolbarIcon)
                }
                .buttonStyle(.plain).help("Push").accessibilityLabel("Push").disabled(store.isRunningCommand)

                Button { store.refreshNow() } label: {
                    SpinningIcon(systemName: "arrow.clockwise", isSpinning: store.isRefreshing)
                        .font(AppFonts.toolbarIcon)
                }
                .buttonStyle(.plain).help("Refresh").accessibilityLabel("Refresh").disabled(store.isRefreshing || store.isRunningCommand)
            }
            .padding(.horizontal, AppSpacing.panelPadding)
            .frame(height: AppSpacing.headerHeight)

            PanelDivider()

            // Commit graph
            if store.logEntries.isEmpty {
                Spacer()
                EmptyStateView("No commits yet", subtitle: "Make your first commit to see the graph")
                Spacer()
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
    }

    // MARK: - Right: Diff Panel

    private var diffPanel: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 6) {
                if let hash = store.selectedCommitHash, !store.commitDiffText.isEmpty {
                    let short = String(hash.prefix(7))
                    let count = store.commitFiles.count
                    Text("\(count) file\(count == 1 ? "" : "s") changed")
                        .font(AppFonts.diffCode.weight(.medium))
                    Text("(\(short))")
                        .font(AppFonts.caption)
                        .foregroundStyle(.tertiary)
                } else if let change = store.selectedChange {
                    Text(change.path)
                        .font(AppFonts.diffCode.weight(.medium))
                        .lineLimit(1)
                    Text(change.section == .staged ? "(staged)" : "(working tree)")
                        .font(AppFonts.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("Diff")
                        .font(AppFonts.primaryLabel)
                        .foregroundStyle(.secondary)
                }
                Spacer()

                if store.selectedCommitHash != nil, !store.commitDiffText.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showCommitFileList.toggle()
                        }
                    } label: {
                        Image(systemName: "sidebar.left")
                            .font(AppFonts.secondaryLabel)
                            .foregroundStyle(showCommitFileList ? .primary : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Toggle file list")
                    .accessibilityLabel("Toggle file list")
                }
            }
            .padding(.horizontal, AppSpacing.panelPadding)
            .frame(height: AppSpacing.headerHeight)

            PanelDivider()

            // Content
            if store.selectedCommitHash != nil, !store.commitDiffText.isEmpty {
                let sections = splitDiffByFile(store.commitDiffText)
                HStack(spacing: 0) {
                    if showCommitFileList {
                        commitFileSidebar(sections: sections)
                        PanelDivider()
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
                Spacer()
                EmptyStateView("No diff output")
                Spacer()
            } else {
                Spacer()
                EmptyStateView("Select a file to view diff", subtitle: "Click a changed file to see its diff")
                Spacer()
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
            VStack(alignment: .leading, spacing: 0) {
                ForEach(sections, id: \.path) { section in
                    let isSelected = selectedCommitFilePath == section.path
                    let isImage = Self.imageExtensions.contains(
                        URL(fileURLWithPath: section.path).pathExtension.lowercased()
                    )
                    HStack(spacing: 4) {
                        if isImage {
                            Image(systemName: "photo")
                                .font(AppFonts.smallIcon)
                                .foregroundStyle(.secondary)
                                .frame(width: 12)
                        } else {
                            Text(String(section.status.rawValue))
                                .font(AppFonts.diffMeta)
                                .foregroundStyle(commitStatusColor(section.status))
                                .frame(width: 12)
                        }

                        Text(URL(fileURLWithPath: section.path).lastPathComponent)
                            .font(AppFonts.secondaryLabel)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedCommitFilePath = section.path
                        collapsedCommitFiles.remove(section.path)
                        scrollTarget = section.path
                    }
                }
            }
        }
        .frame(width: 160)
        .background(.regularMaterial)
    }

    private func commitDiffByFile(sections: [FileDiffSection]) -> some View {
        GeometryReader { geo in
            let halfWidth = max((geo.size.width - 1) / 2, 0)
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(sections, id: \.path) { section in
                            commitFileSection(section, halfWidth: halfWidth)
                                .id(section.path)
                        }
                    }
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

    private func commitFileSection(_ section: FileDiffSection, halfWidth: CGFloat) -> some View {
        let isCollapsed = collapsedCommitFiles.contains(section.path)
        let isImage = Self.imageExtensions.contains(
            URL(fileURLWithPath: section.path).pathExtension.lowercased()
        )
        let isBinary = !isImage && section.diff.contains("Binary files")
        let rows = (isCollapsed || isImage || isBinary) ? [] : parseSideBySide(section.diff)
        return VStack(alignment: .leading, spacing: 0) {
            // File header bar
            HStack(spacing: 6) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(AppFonts.badge.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 10)

                Text(commitStatusString(section.status))
                    .font(AppFonts.diffMeta)
                    .foregroundStyle(commitStatusColor(section.status))

                Text(section.path)
                    .font(AppFonts.diffCode.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.head)

                Spacer()

                if isImage {
                    Text("image")
                        .font(AppFonts.badge)
                        .foregroundStyle(.tertiary)
                } else if isBinary {
                    Text("binary")
                        .font(AppFonts.badge)
                        .foregroundStyle(.tertiary)
                } else if !isCollapsed {
                    Text("\(rows.count) lines")
                        .font(AppFonts.badge)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(selectedCommitFilePath == section.path
                        ? Color.accentColor.opacity(0.1)
                        : Color.secondary.opacity(0.08))
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
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                } else {
                    singleFileDiffRows(section.diff, halfWidth: halfWidth)
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

    // MARK: - Single File Diff (side-by-side)

    @State private var diffScrollWidth: CGFloat = 0

    private func singleFileDiff(_ diffText: String) -> some View {
        GeometryReader { outerGeo in
            let effectiveWidth = diffScrollWidth > 0 ? diffScrollWidth : outerGeo.size.width
            let halfWidth = max((effectiveWidth - 1) / 2, 0)
            ScrollView(.vertical) {
                singleFileDiffRows(diffText, halfWidth: halfWidth)
                    .background(
                        GeometryReader { innerGeo in
                            Color.clear.preference(key: DiffWidthKey.self, value: innerGeo.size.width)
                        }
                    )
            }
            .onPreferenceChange(DiffWidthKey.self) { w in
                if w > 0 { diffScrollWidth = w }
            }
        }
        .overlay {
            Rectangle()
                .fill(Color.secondary.opacity(0.2))
                .frame(width: 1)
                .frame(maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func singleFileDiffRows(_ diffText: String, halfWidth: CGFloat) -> some View {
        let rows = parseSideBySide(diffText)
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(rows.indices, id: \.self) { i in
                let row = rows[i]
                if row.kind == .hunkHeader {
                    if expandedHunks.contains(row.hunkIndex), let lines = cachedFileLines {
                        let fromLine = row.prevNewEnd
                        let toLine = row.newStartLine
                        ForEach(fromLine..<toLine, id: \.self) { lineNo in
                            let idx = lineNo - 1
                            let content = idx >= 0 && idx < lines.count ? lines[idx] : ""
                            HStack(alignment: .top, spacing: 0) {
                                diffSideCell(lineNo: lineNo, content: content, kind: .context, side: .left, cellWidth: halfWidth)
                                    .frame(width: halfWidth)
                                Color.clear.frame(width: 1)
                                diffSideCell(lineNo: lineNo, content: content, kind: .context, side: .right, cellWidth: halfWidth)
                                    .frame(width: halfWidth)
                            }
                        }
                    } else if row.skippedLines > 0 {
                        hunkHeaderBar(skippedLines: row.skippedLines, hunkIndex: row.hunkIndex)
                    }
                } else {
                    HStack(alignment: .top, spacing: 0) {
                        diffSideCell(lineNo: row.oldLineNo, content: row.oldContent, kind: row.kind, side: .left, cellWidth: halfWidth)
                            .frame(width: halfWidth)
                        Rectangle().fill(Color.secondary.opacity(0.2)).frame(width: 1)
                        diffSideCell(lineNo: row.newLineNo, content: row.newContent, kind: row.kind, side: .right, cellWidth: halfWidth)
                            .frame(width: halfWidth)
                    }
                }
            }
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
                    .foregroundStyle(.secondary.opacity(0.6))
                Text("\(skippedLines) unmodified lines")
                    .font(AppFonts.secondaryLabel)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.down")
                    .font(AppFonts.tinyIcon)
                    .foregroundStyle(.secondary.opacity(0.6))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.secondary.opacity(0.08))
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

    private func diffSideCell(lineNo: Int?, content: String?, kind: DiffRowKind, side: DiffSide, cellWidth: CGFloat) -> some View {
        // gutter(2) + lineNo(36) + lineNo trailing pad(6) + text leading pad(4) + right margin(6) = 54
        let textWidth = max(cellWidth - 54, 0)
        return HStack(alignment: .top, spacing: 0) {
            gutterBar(kind: kind, side: side)

            Text(lineNo.map { String($0) } ?? "")
                .font(AppFonts.diffCode)
                .foregroundStyle(.secondary.opacity(0.5))
                .frame(width: 36, alignment: .trailing)
                .padding(.trailing, 6)
                .padding(.top, 1)

            if let content {
                Text(highlightCode(content))
                    .font(AppFonts.diffCode)
                    .padding(.leading, 4)
                    .padding(.vertical, 1)
                    .frame(width: textWidth, alignment: .leading)
            } else {
                Color.clear.frame(width: textWidth)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
        .background(diffRowBackground(kind: kind, side: side))
    }

    @ViewBuilder
    private func gutterBar(kind: DiffRowKind, side: DiffSide) -> some View {
        switch (kind, side) {
        case (.added, .right):
            Color(nsColor: .systemGreen).frame(width: 2)
        case (.removed, .left):
            Color(nsColor: .systemRed).frame(width: 2)
        default:
            Color.clear.frame(width: 2)
        }
    }

    // MARK: - Diff Parsing

    private enum DiffSide { case left, right }
    private enum DiffRowKind { case context, added, removed, hunkHeader }

    private struct DiffRow {
        let oldLineNo: Int?; let oldContent: String?
        let newLineNo: Int?; let newContent: String?
        let kind: DiffRowKind
        var skippedLines: Int = 0
        var hunkIndex: Int = 0
        var newStartLine: Int = 0 // for expanding: first new line of this hunk
        var prevNewEnd: Int = 0   // for expanding: last new line before this hunk
    }

    private func parseSideBySide(_ diffText: String) -> [DiffRow] {
        var rows: [DiffRow] = []
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
                var row = DiffRow(oldLineNo: nil, oldContent: line, newLineNo: nil, newContent: line, kind: .hunkHeader)
                row.skippedLines = skipped
                row.hunkIndex = hunkIdx
                row.newStartLine = newNewStart
                row.prevNewEnd = prevNewEnd
                rows.append(row)
                hunkIdx += 1
                continue
            }
            if line.hasPrefix("-") {
                rows.append(DiffRow(oldLineNo: oldNo, oldContent: String(line.dropFirst()), newLineNo: nil, newContent: nil, kind: .removed))
                oldNo += 1
            } else if line.hasPrefix("+") {
                rows.append(DiffRow(oldLineNo: nil, oldContent: nil, newLineNo: newNo, newContent: String(line.dropFirst()), kind: .added))
                newNo += 1
                prevNewEnd = newNo
            } else {
                let c = line.hasPrefix(" ") ? String(line.dropFirst()) : line
                rows.append(DiffRow(oldLineNo: oldNo, oldContent: c, newLineNo: newNo, newContent: c, kind: .context))
                oldNo += 1; newNo += 1
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

    private func diffRowBackground(kind: DiffRowKind, side: DiffSide) -> Color {
        switch kind {
        case .added:
            return side == .right
                ? Color(nsColor: .systemGreen).opacity(0.12)
                : Color(nsColor: .systemGreen).opacity(0.04)  // empty side tint
        case .removed:
            return side == .left
                ? Color(nsColor: .systemRed).opacity(0.12)
                : Color(nsColor: .systemRed).opacity(0.04)    // empty side tint
        case .hunkHeader: return Color(nsColor: .systemBlue).opacity(0.06)
        case .context: return diffBgColor
        }
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

            Rectangle().fill(Color.secondary.opacity(0.2)).frame(width: 1)

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

// MARK: - Diff Width Preference Key

private struct DiffWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 { value = next }
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

            Rectangle().fill(Color.secondary.opacity(0.2)).frame(width: 1)

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
                    .foregroundStyle(.tertiary)
            } else if !loaded {
                ProgressView().controlSize(.small)
            } else {
                Text(loadError ?? "Image unavailable")
                    .font(AppFonts.caption)
                    .foregroundStyle(.secondary)
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

private let graphRowHeight: CGFloat = 28
private let graphColWidth: CGFloat = 14
private let graphLeftPad: CGFloat = 8
private let graphCircleR: CGFloat = 4

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
        let graphWidth = graphLeftPad + CGFloat(max(layout.maxColumns, 1)) * graphColWidth + graphLeftPad

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

            // Commit list
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(entries) { entry in
                    CommitRow(entry: entry, isSelected: entry.hash == selectedHash)
                        .onTapGesture { onSelect(entry.hash) }
                }

                if hasMore {
                    Text("Loading more...")
                        .font(AppFonts.caption)
                        .foregroundStyle(.secondary)
                        .frame(height: graphRowHeight)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .onAppear { onLoadMore() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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

    private static let iso8601 = ISO8601DateFormatter()

    var body: some View {
        HStack(spacing: 4) {
            // Ref badges
            if !entry.refs.isEmpty {
                ForEach(parseBadges(), id: \.label) { badge in
                    Text(badge.label)
                        .font(AppFonts.badge)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(badge.color.opacity(0.15))
                        .foregroundStyle(badge.color)
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                }
            }

            // Message
            Text(entry.message)
                .font(AppFonts.secondaryLabel)
                .lineLimit(1)
                .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.8))

            Spacer(minLength: 4)

            // Relative date
            Text(relativeDate)
                .font(AppFonts.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 42, alignment: .trailing)
        }
        .padding(.horizontal, 6)
        .frame(height: graphRowHeight)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .contentShape(Rectangle())
    }

    private struct RefBadge {
        let label: String
        let color: Color
    }

    private func parseBadges() -> [RefBadge] {
        entry.refs.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.compactMap { ref in
            if ref.hasPrefix("HEAD -> ") {
                return RefBadge(label: String(ref.dropFirst(8)), color: Color(nsColor: .systemGreen))
            } else if ref.hasPrefix("tag: ") {
                return RefBadge(label: String(ref.dropFirst(5)), color: Color(nsColor: .systemYellow))
            } else if ref.contains("/") {
                return nil  // skip remote refs inline
            } else if ref == "HEAD" {
                return RefBadge(label: "HEAD", color: Color(nsColor: .systemGreen))
            } else {
                return RefBadge(label: ref, color: Color(nsColor: .systemBlue))
            }
        }
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
                            .font(AppFonts.tinyIcon.weight(.bold)).frame(width: 10)
                        SectionTitle(title)
                    }
                }
                .buttonStyle(.plain)

                Spacer(minLength: 4)

                action().opacity(0.7)

                Text("\(count)")
                    .font(AppFonts.badge).foregroundStyle(AppPalette.textSecondary)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .padding(.horizontal, 8).padding(.vertical, 5)

            if isExpanded { content() }
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
        HStack(spacing: 4) {
            HStack(spacing: 0) {
                Text(fileName).font(AppFonts.secondaryLabel).foregroundStyle(.primary.opacity(0.85)).lineLimit(1)
                if !dirPath.isEmpty {
                    Text("  \(dirPath)").font(AppFonts.secondaryLabel).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if hovering {
                if discardable, let onDiscard {
                    Image(systemName: "arrow.uturn.backward").font(AppFonts.smallIcon)
                        .foregroundStyle(.secondary)
                        .onTapGesture { onDiscard() }
                        .help("Discard")
                }
                if let onAction {
                    Image(systemName: actionIcon).font(AppFonts.toolbarIcon.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .onTapGesture { onAction() }
                        .help(actionHelp)
                }
            }

            Text(statusLetter)
                .font(AppFonts.diffCode.weight(.medium))
                .foregroundStyle(statusColor)
                .frame(width: 12, alignment: .trailing)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppSpacing.cornerRadiusSmall)
                .fill(isSelected ? AppColors.activeBackground : (hovering ? AppColors.hoverBackground : Color.clear))
        )
        .padding(.horizontal, 2)
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
        default: return .secondary
        }
    }
}

private enum GitConfirmationAction {
    case deleteBranch(branch: String)
    case discardChanges(changes: [GitFileChange])
}
