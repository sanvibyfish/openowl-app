import AppKit
import SwiftUI

/// Muxy-style narrow left rail: free terminal + project monograms + add.
///
/// Replaces the wide `NavigationSplitView` sidebar so the terminal owns the
/// viewport. Worktree switch / project admin actions live on context menus and
/// a popover (click the already-active project icon).
struct ProjectRail: View {
    @Environment(ProjectStore.self) private var projectStore
    @Environment(TerminalWorkspaceStore.self) private var workspace
    @Environment(ClaudeStatusStore.self) private var claudeStatusStore
    @Environment(\.openURL) private var openURL

    /// Bound from ContentView — toggles the worktree/pane session list.
    @Binding var isSessionListVisible: Bool

    static let width: CGFloat = RailChrome.leftWidth

    @State private var popoverProjectID: String?
    @State private var creatingWorktreeFor: String?
    @State private var showAddMenu = false

    var body: some View {
        VStack(spacing: 2) {
            freeTerminalButton

            railDivider

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(railProjects) { project in
                        projectButton(project)
                    }

                    addProjectButton
                }
                .padding(.vertical, 2)
            }

            Spacer(minLength: 0)

            if claudeStatusStore.shouldShowIncidentBanner {
                claudeIncidentButton
            }

            // Toggle session list (worktrees + panes)
            RailStripButton(
                width: Self.width,
                isSelected: isSessionListVisible,
                help: isSessionListVisible ? "Hide sessions list" : "Show sessions list",
                action: {
                    withAnimation(.easeOut(duration: 0.15)) {
                        isSessionListVisible.toggle()
                    }
                }
            ) {
                Image(systemName: isSessionListVisible ? "sidebar.left" : "sidebar.squares.left")
                    .font(.system(size: 14, weight: .medium))
            }
        }
        .padding(.vertical, 6)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(RailChrome.background)
        .overlay(alignment: .trailing) {
            // Only draw hairline when session list is hidden (list has its own edge)
            if !isSessionListVisible {
                Rectangle()
                    .fill(RailChrome.hairline)
                    .frame(width: 1)
            }
        }
    }

    // MARK: - Free terminal

    private var freeTerminalButton: some View {
        let isSelected = projectStore.activeFreeTerminalID != nil
        let unread: Int = {
            guard let id = projectStore.freeTerminals.first?.id else { return 0 }
            return workspace.bellCount(for: .freeTerminal(id))
        }()

        return RailStripButton(
            width: Self.width,
            isSelected: isSelected,
            help: "Terminal",
            badge: unread,
            action: {
                if let id = projectStore.freeTerminals.first?.id {
                    projectStore.activate(.freeTerminal(id))
                }
                popoverProjectID = nil
            }
        ) {
            Image(systemName: "terminal")
                .font(.system(size: 15, weight: .medium))
        }
    }

    // MARK: - Projects

    /// Only roots that already have open tabs, plus the currently selected root.
    /// Inactive projects stay off the rail (open via + menu).
    private var railProjects: [ProjectItem] {
        let selectedRootID = selectedRootProjectID
        return projectStore.rootProjects.filter { project in
            if project.id == selectedRootID { return true }
            return isProjectActive(project)
        }
    }

    private var inactiveProjects: [ProjectItem] {
        let shown = Set(railProjects.map(\.id))
        return projectStore.rootProjects.filter { !shown.contains($0.id) }
    }

    private var selectedRootProjectID: String? {
        guard let activeID = projectStore.activeProjectID,
              let active = projectStore.projects.first(where: { $0.id == activeID }) else {
            return nil
        }
        return active.worktreeOf ?? active.id
    }

    private func isProjectActive(_ project: ProjectItem) -> Bool {
        if workspace.hasTabs(for: .project(project.id)) { return true }
        return projectStore.worktrees(for: project.id).contains {
            workspace.hasTabs(for: .project($0.id))
        }
    }

    private func isProjectSelected(_ project: ProjectItem) -> Bool {
        guard let activeID = projectStore.activeProjectID,
              let active = projectStore.projects.first(where: { $0.id == activeID }) else {
            return false
        }
        if active.id == project.id { return true }
        return active.worktreeOf == project.id
    }

    private func projectUnread(_ project: ProjectItem) -> Int {
        var total = workspace.bellCount(for: project.id)
        for wt in projectStore.worktrees(for: project.id) {
            total += workspace.bellCount(for: wt.id)
        }
        return total
    }

    @ViewBuilder
    private func projectButton(_ project: ProjectItem) -> some View {
        let selected = isProjectSelected(project)
        let dimmed = !isProjectActive(project) && !selected

        RailStripButton(
            width: Self.width,
            isSelected: selected,
            help: projectTooltip(project),
            badge: projectUnread(project),
            action: { handleProjectClick(project) }
        ) {
            ProjectMonogram(name: project.displayName, isSelected: selected, isDimmed: dimmed)
        }
        .popover(isPresented: Binding(
            get: { popoverProjectID == project.id },
            set: { if !$0 { popoverProjectID = nil } }
        ), arrowEdge: .trailing) {
            ProjectRailPopover(
                project: project,
                creatingWorktree: creatingWorktreeFor == project.id,
                onActivateMain: {
                    projectStore.activateProject(id: project.id)
                    popoverProjectID = nil
                },
                onActivateWorktree: { wtID in
                    projectStore.activateProject(id: wtID)
                    popoverProjectID = nil
                },
                onCreateWorktree: {
                    Task { await createWorktree(for: project) }
                },
                onRemove: {
                    projectStore.removeProject(id: project.id)
                    popoverProjectID = nil
                }
            )
        }
        .contextMenu {
            projectContextMenu(project)
        }
    }

    private func projectTooltip(_ project: ProjectItem) -> String {
        if let branch = project.lastBranch {
            return "\(project.displayName) · \(branch)"
        }
        return project.displayName
    }

    private func handleProjectClick(_ project: ProjectItem) {
        if isProjectSelected(project) {
            // Second click on the active project opens the worktree / admin popover.
            popoverProjectID = popoverProjectID == project.id ? nil : project.id
            return
        }
        projectStore.activateLastProject(inRoot: project.id)
        popoverProjectID = nil
    }

    @ViewBuilder
    private func projectContextMenu(_ project: ProjectItem) -> some View {
        Button("Open Main") {
            projectStore.activateProject(id: project.id)
        }

        let worktrees = projectStore.worktrees(for: project.id)
        if !worktrees.isEmpty {
            Menu("Worktrees") {
                ForEach(worktrees) { wt in
                    Button(wt.worktreeBranch ?? wt.name) {
                        projectStore.activateProject(id: wt.id)
                    }
                }
            }
        }

        Button("Create Worktree") {
            Task { await createWorktree(for: project) }
        }

        Divider()

        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([project.url])
        }

        Button("Remove Project", role: .destructive) {
            projectStore.removeProject(id: project.id)
        }
    }

    private func createWorktree(for project: ProjectItem) async {
        creatingWorktreeFor = project.id
        defer { creatingWorktreeFor = nil }

        // Use this root's stored prefix (not activeProject's) so create works
        // from the rail even when another project is selected.
        let prefix = project.branchPrefix ?? "dev"
        let generated = BranchNameGenerator.generate(prefix: prefix)
        let git = GitService(workingDirectory: project.url)

        do {
            let worktreePath = try await git.addWorktree(
                branch: generated.branchName,
                dirName: generated.dirName
            )
            let newProject = projectStore.addWorktreeProject(
                parentID: project.id,
                path: worktreePath,
                branch: generated.branchName
            )
            projectStore.activateProject(id: newProject.id)
            popoverProjectID = nil
        } catch {
            NSLog("openOwl: [ProjectRail] Failed to create worktree: %@", error.localizedDescription)
        }
    }

    // MARK: - Add / Claude

    private var addProjectButton: some View {
        // Same RailStripButton chrome as monograms — system Menu ignores
        // custom labels and looks broken; use a popover instead.
        RailStripButton(
            width: Self.width,
            isSelected: showAddMenu,
            help: "Open project",
            action: {
                popoverProjectID = nil
                showAddMenu.toggle()
            }
        ) {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .medium))
        }
        .popover(isPresented: $showAddMenu, arrowEdge: .trailing) {
            AddProjectPopover(
                inactiveProjects: inactiveProjects,
                onOpenFolder: {
                    showAddMenu = false
                    projectStore.openProjectPicker()
                },
                onActivate: { id in
                    showAddMenu = false
                    projectStore.activateProject(id: id)
                    popoverProjectID = nil
                }
            )
        }
    }

    private var claudeIncidentButton: some View {
        RailStripButton(
            width: Self.width,
            isSelected: false,
            help: claudeStatusStore.bannerTitle,
            action: { openURL(claudeStatusStore.bannerIncidentURL) }
        ) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.yellow)
        }
        .contextMenu {
            Button("Open status page") {
                openURL(claudeStatusStore.bannerIncidentURL)
            }
            Button("Dismiss") {
                claudeStatusStore.dismissCurrentIncident()
            }
        }
    }

    private var railDivider: some View {
        Rectangle()
            .fill(RailChrome.hairline)
            .frame(height: 1)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
    }
}

// MARK: - Add project popover

private struct AddProjectPopover: View {
    let inactiveProjects: [ProjectItem]
    let onOpenFolder: () -> Void
    let onActivate: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onOpenFolder) {
                HStack(spacing: 8) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 16)
                    Text("Open Folder…")
                        .font(AppFonts.body)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(AppPalette.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !inactiveProjects.isEmpty {
                Rectangle()
                    .fill(RailChrome.hairline)
                    .frame(height: 1)
                    .padding(.vertical, 2)

                Text("INACTIVE")
                    .font(AppFonts.sectionHeader)
                    .tracking(AppFonts.sectionTracking)
                    .foregroundStyle(AppPalette.textTertiary)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 4)

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(inactiveProjects) { project in
                            Button {
                                onActivate(project.id)
                            } label: {
                                HStack(spacing: 8) {
                                    Text(String(project.displayName.prefix(1)).uppercased())
                                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                                        .foregroundStyle(AppPalette.textSecondary)
                                        .frame(width: 18, height: 18)
                                        .background(
                                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                                .fill(AppPalette.surface)
                                        )
                                    Text(project.displayName)
                                        .font(AppFonts.body)
                                        .foregroundStyle(AppPalette.textPrimary)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
        }
        .padding(.vertical, 4)
        .frame(width: 220)
    }
}

// MARK: - Project monogram

private struct ProjectMonogram: View {
    let name: String
    let isSelected: Bool
    let isDimmed: Bool

    private var letters: String {
        let cleaned = name.filter { $0.isLetter || $0.isNumber }
        if cleaned.isEmpty { return "?" }
        return String(cleaned.prefix(1)).uppercased()
    }

    private var tint: Color {
        let palette: [Color] = [
            .blue, .purple, .teal, .orange, .pink, .indigo, .mint, .cyan, .green
        ]
        var hash = 0
        for scalar in name.unicodeScalars {
            hash = hash &* 31 &+ Int(scalar.value)
        }
        return palette[abs(hash) % palette.count]
    }

    var body: some View {
        Text(letters)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(isSelected ? .white : tint)
            .frame(width: 26, height: 26)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? tint : tint.opacity(0.18))
            )
            .opacity(isDimmed ? 0.45 : 1)
    }
}

// MARK: - Project popover (worktrees + admin)

private struct ProjectRailPopover: View {
    let project: ProjectItem
    let creatingWorktree: Bool
    let onActivateMain: () -> Void
    let onActivateWorktree: (String) -> Void
    let onCreateWorktree: () -> Void
    let onRemove: () -> Void

    @Environment(ProjectStore.self) private var projectStore
    @Environment(TerminalWorkspaceStore.self) private var workspace

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                ProjectMonogram(name: project.displayName, isSelected: false, isDimmed: false)
                    .scaleEffect(0.85)

                VStack(alignment: .leading, spacing: 2) {
                    Text(project.displayName)
                        .font(AppFonts.primaryLabel)
                        .lineLimit(1)
                    Text(project.path)
                        .font(AppFonts.caption)
                        .foregroundStyle(AppPalette.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 0)
            }
            .padding(12)

            Divider()

            // Main branch
            popoverRow(
                title: project.lastBranch ?? "main",
                subtitle: "Main working tree",
                systemImage: "arrow.triangle.branch",
                isActive: projectStore.activeProjectID == project.id,
                unread: workspace.bellCount(for: project.id),
                action: onActivateMain
            )

            // Worktrees
            let worktrees = projectStore.worktrees(for: project.id)
            if !worktrees.isEmpty {
                Text("WORKTREES")
                    .font(AppFonts.sectionHeader)
                    .tracking(AppFonts.sectionTracking)
                    .foregroundStyle(AppPalette.textTertiary)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 4)

                ForEach(worktrees) { wt in
                    popoverRow(
                        title: wt.worktreeBranch ?? wt.name,
                        subtitle: nil,
                        systemImage: "arrow.triangle.branch",
                        isActive: projectStore.activeProjectID == wt.id,
                        unread: workspace.bellCount(for: wt.id),
                        action: { onActivateWorktree(wt.id) }
                    )
                    .contextMenu {
                        Button("Copy Path") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(wt.path, forType: .string)
                        }
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([wt.url])
                        }
                        Divider()
                        Button("Archive Worktree", role: .destructive) {
                            Task { await WorktreeArchive.archive(wt: wt, projectStore: projectStore) }
                        }
                    }
                }
            }

            Divider()
                .padding(.top, 4)

            // Actions
            Button(action: onCreateWorktree) {
                HStack(spacing: 8) {
                    if creatingWorktree {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "plus.diamond")
                            .font(.system(size: 12))
                    }
                    Text("Create Worktree")
                        .font(AppFonts.body)
                    Spacer()
                }
                .foregroundStyle(AppPalette.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(creatingWorktree)

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([project.url])
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.system(size: 12))
                    Text("Reveal in Finder")
                        .font(AppFonts.body)
                    Spacer()
                }
                .foregroundStyle(AppPalette.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(role: .destructive, action: onRemove) {
                HStack(spacing: 8) {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                    Text("Remove Project")
                        .font(AppFonts.body)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 6)
        }
        .frame(width: 260)
    }

    private func popoverRow(
        title: String,
        subtitle: String?,
        systemImage: String,
        isActive: Bool,
        unread: Int,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 12))
                    .foregroundStyle(isActive ? AppPalette.accent : AppPalette.textSecondary)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(AppFonts.body.weight(isActive ? .semibold : .regular))
                        .foregroundStyle(AppPalette.textPrimary)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(AppFonts.caption)
                            .foregroundStyle(AppPalette.textTertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)

                if unread > 0 {
                    Text("\(unread)")
                        .font(AppFonts.badge)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(AppPalette.accent))
                }

                if isActive {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(AppPalette.accent)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(isActive ? AppPalette.accent.opacity(0.10) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Worktree archive (shared flow from former wide sidebar)

@MainActor
enum WorktreeArchive {
    static func archive(wt: ProjectItem, projectStore: ProjectStore) async {
        guard let parentID = wt.worktreeOf,
              let parent = projectStore.projects.first(where: { $0.id == parentID }) else {
            presentAlert(
                title: "Archive failed",
                message: "Could not archive \"\(wt.worktreeBranch ?? wt.name)\" because its parent project is missing."
            )
            return
        }

        let parentGit = GitService(workingDirectory: parent.url)
        do {
            if try await parentGit.isRegisteredWorktree(path: wt.path) {
                do {
                    let dirty = try await GitService.hasUncommittedChanges(at: wt.url)
                    if dirty {
                        let proceed = confirm(
                            title: "Archive worktree?",
                            message: "\"\(wt.worktreeBranch ?? wt.name)\" has uncommitted changes.\n\nArchive this worktree anyway?",
                            primary: "Archive"
                        )
                        guard proceed else { return }
                    }
                } catch {
                    NSLog("openOwl: [ProjectRail] Failed to check uncommitted changes: %@", error.localizedDescription)
                }
            }

            let outcome = try await parentGit.removeWorktree(path: wt.path)
            if outcome == .unregisteredPath {
                let shouldTrash = confirm(
                    title: "Worktree registration missing",
                    message: "\"\(wt.worktreeBranch ?? wt.name)\" is no longer registered as a Git worktree, but its folder still exists and may contain files.\n\nMove the folder to Trash and remove it from OpenOwl?",
                    primary: "Move to Trash"
                )
                guard shouldTrash else { return }

                let worktreeURL = wt.url
                try await Task.detached(priority: .userInitiated) {
                    try FileManager.default.trashItem(
                        at: worktreeURL,
                        resultingItemURL: nil
                    )
                }.value
            }
        } catch {
            presentAlert(
                title: "Archive failed",
                message: "Could not archive \"\(wt.worktreeBranch ?? wt.name)\".\n\n\(error.localizedDescription)"
            )
            return
        }

        if projectStore.activeProjectID == wt.id {
            projectStore.activateProject(id: parentID)
        }
        projectStore.removeWorktreeProject(id: wt.id)
    }

    private static func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func confirm(title: String, message: String, primary: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: primary)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
