import AppKit
import SwiftUI

/// Detail list beside `ProjectRail` for the **currently selected** root only:
/// main branch, worktrees, and each terminal pane.
///
/// Project switching lives on the monogram rail — this panel does not re-list
/// other projects (that would duplicate the rail).
struct ProjectSessionList: View {
    static let width: CGFloat = 210

    @Environment(ProjectStore.self) private var projectStore
    @Environment(TerminalWorkspaceStore.self) private var workspace

    private var shortcutMap: [String: Int] {
        var map: [String: Int] = [:]
        for (index, item) in projectStore.orderedProjectTabs.enumerated() where index < 9 {
            map[item.id] = index + 1
        }
        return map
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if projectStore.activeFreeTerminalID != nil {
                        freeTerminalContent
                    } else if let project = projectStore.activeRootProject {
                        projectContent(project)
                    } else {
                        Text("Pick a project on the left rail")
                            .font(AppFonts.caption)
                            .foregroundStyle(AppPalette.textTertiary)
                            .padding(12)
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 6)
            }
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(AppPalette.elevated)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(AppPalette.border)
                .frame(width: 1)
        }
    }

    private var header: some View {
        // One Spacer per branch, never two. A trailing Spacer shared by all
        // branches would split the free width with the one before the button,
        // parking `plus.diamond` mid-header instead of against the edge.
        HStack(spacing: 6) {
            if projectStore.activeFreeTerminalID != nil {
                Text("TERMINAL")
                    .font(AppFonts.sectionHeader)
                    .tracking(AppFonts.sectionTracking)
                    .foregroundStyle(AppPalette.textTertiary)
                Spacer(minLength: 0)
            } else if let project = projectStore.activeRootProject {
                Text(project.displayName)
                    .font(AppFonts.sectionHeader)
                    .tracking(0.5)
                    .foregroundStyle(AppPalette.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if projectStore.isCreatingWorktree(rootID: project.id) {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 12, height: 12)
                } else {
                    Button {
                        Task { await createWorktree(for: project) }
                    } label: {
                        Image(systemName: "plus.diamond")
                            .font(AppFonts.smallIcon)
                            .foregroundStyle(AppPalette.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .disabled(project.branchPrefix == nil)
                    .help(project.branchPrefix == nil ? ProjectRail.missingPrefixHelp : "Create worktree")
                    .accessibilityLabel("Create worktree")
                }
            } else {
                Text("SESSIONS")
                    .font(AppFonts.sectionHeader)
                    .tracking(AppFonts.sectionTracking)
                    .foregroundStyle(AppPalette.textTertiary)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 10)
        // Same tool-header chrome as right dock / Files / Git.
        .panelToolHeader(background: AppPalette.elevated)
    }

    // MARK: - Free terminal (only when free terminal is selected on the rail)

    @ViewBuilder
    private var freeTerminalContent: some View {
        if let termID = projectStore.freeTerminals.first?.id {
            let panes = workspace.paneInfos(for: .freeTerminal(termID))

            ForEach(panes) { info in
                SessionPaneRow(
                    info: info,
                    namespace: .freeTerminal(termID),
                    isGroupSelected: true
                )
            }

            if panes.isEmpty {
                Text("No panes yet")
                    .font(AppFonts.caption)
                    .foregroundStyle(AppPalette.textTertiary)
                    .padding(.leading, 8)
                    .padding(.vertical, 2)
            }
        }
    }

    // MARK: - Current project only: branches + panes

    @ViewBuilder
    private func projectContent(_ project: ProjectItem) -> some View {
        let worktrees = projectStore.worktrees(for: project.id)
        let mainSelected = projectStore.activeProjectID == project.id
        let shortcuts = shortcutMap

        SessionRow(
            title: project.lastBranch ?? "main",
            path: project.path,
            isSelected: mainSelected,
            shortcutNumber: shortcuts[project.id],
            onSelect: { projectStore.activateProject(id: project.id) },
            extraMenuItems: { EmptyView() }
        )

        ForEach(workspace.paneInfos(for: project.id)) { info in
            SessionPaneRow(
                info: info,
                namespace: .project(project.id),
                isGroupSelected: mainSelected
            )
        }

        ForEach(worktrees) { wt in
            let wtSelected = projectStore.activeProjectID == wt.id
            let isArchiving = projectStore.isArchivingWorktree(id: wt.id)
            SessionRow(
                title: wt.worktreeBranch ?? wt.name,
                path: wt.path,
                isSelected: wtSelected,
                shortcutNumber: shortcuts[wt.id],
                onSelect: { projectStore.activateProject(id: wt.id) },
                extraMenuItems: {
                    Button("Rename Branch…") { promptRename(wt: wt) }
                    Divider()
                    Button(isArchiving ? "Archiving..." : "Archive Worktree", role: .destructive) {
                        Task { await WorktreeArchive.archive(wt: wt, projectStore: projectStore) }
                    }
                    .disabled(isArchiving)
                }
            )

            ForEach(workspace.paneInfos(for: wt.id)) { info in
                SessionPaneRow(
                    info: info,
                    namespace: .project(wt.id),
                    isGroupSelected: wtSelected
                )
            }
        }
    }

    private func createWorktree(for project: ProjectItem) async {
        await createWorktreeReportingFailure(for: project, in: projectStore)
    }

    private func promptRename(wt: ProjectItem) {
        let alert = NSAlert()
        alert.messageText = "Rename branch"
        alert.informativeText = "New branch name for \"\(wt.worktreeBranch ?? wt.name)\":"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(string: wt.worktreeBranch ?? wt.name)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        Task {
            do {
                try await projectStore.renameWorktreeProject(id: wt.id, newBranch: trimmed)
            } catch {
                AppLogger.log("worktree", "rename failed id=%@ error=%@", wt.id, error.localizedDescription)
                WorktreeAlert.present(title: "Rename failed", message: error.localizedDescription)
            }
        }
    }
}

// MARK: - Rows

/// One branch row — the project's main branch and each worktree render
/// identically. Worktree-only actions come in through `extraMenuItems`.
private struct SessionRow<ExtraMenu: View>: View {
    let title: String
    let path: String
    let isSelected: Bool
    var shortcutNumber: Int?
    let onSelect: () -> Void
    @ViewBuilder let extraMenuItems: () -> ExtraMenu

    @State private var hovering = false

    var body: some View {
        Button(action: onSelect) {
            branchLabel
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(path)
        .contextMenu {
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
            extraMenuItems()
        }
    }

    private var branchLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 11))
                .foregroundStyle(isSelected ? AppPalette.accent : AppPalette.textTertiary)
                .frame(width: 14)

            Text(title)
                .font(AppFonts.body.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? AppPalette.textPrimary : AppPalette.textSecondary)
                .lineLimit(1)

            Spacer(minLength: 2)

            if let n = shortcutNumber {
                Text("\u{2318}\(n)")
                    .font(AppFonts.badge)
                    .foregroundStyle(AppPalette.textTertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .selectableRowChrome(isSelected: isSelected, isHovering: hovering)
        .contentShape(Rectangle())
    }
}

private struct SessionPaneRow: View {
    let info: PaneInfo
    let namespace: TerminalNamespace
    let isGroupSelected: Bool

    @Environment(ProjectStore.self) private var projectStore
    @Environment(TerminalWorkspaceStore.self) private var workspace
    @State private var hovering = false

    private var isFocused: Bool {
        guard isGroupSelected,
              let tab = workspace.tabs.first(where: { $0.id == workspace.activeTabID }) else {
            return false
        }
        return (tab.focusedPaneID ?? tab.splitTree.firstPaneID) == info.paneID
    }

    var body: some View {
        Button {
            if projectStore.activate(namespace) {
                workspace.selectPane(info.paneID, in: namespace)
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(isFocused ? AppPalette.accent.opacity(0.7) : AppPalette.textTertiary.opacity(0.5))
                    .frame(width: 6, height: 6)

                Text(info.title)
                    .font(AppFonts.secondaryLabel)
                    .foregroundStyle(isFocused ? AppPalette.textPrimary : AppPalette.textSecondary)
                    .lineLimit(1)

                Spacer(minLength: 2)
            }
            .padding(.leading, 22)
            .padding(.trailing, 8)
            .padding(.vertical, 3)
            .selectableRowChrome(
                isSelected: isFocused,
                isHovering: hovering,
                cornerRadius: AppSpacing.cornerRadiusSmall,
                accentBarHeight: 10
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(info.title)
        .accessibilityLabel(info.title)
    }
}
