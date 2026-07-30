import SwiftUI

/// Bottom status bar — quiet Muxy-style strip: path · project · branch left,
/// context mode right. 28pt, no loud chrome.
struct StatusBarView: View {
    @Environment(GitChangesStore.self) private var gitStore
    @Environment(RightDockStore.self) private var rightDockStore
    @Environment(ProjectStore.self) private var projectStore
    @Environment(FileExplorerStore.self) private var fileExplorerStore

    static let height: CGFloat = AppSpacing.statusBarHeight

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            StatusBarLocationLabel(
                path: abbreviatedActivePath,
                projectName: activeProjectName,
                branch: gitStore.statusSnapshot?.branch,
                changesCount: totalChangesCount
            )

            Spacer(minLength: 8)

            #if DEBUG
            MetalStatsView()
            #endif

            StatusBarContextInfo(
                visibleArea: visibleArea,
                selectedFileName: fileExplorerStore.selectedNode?.name
            )
        }
        .padding(.horizontal, 12)
        .frame(height: Self.height)
        .background(AppPalette.elevated)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(AppPalette.border)
                .frame(height: 1)
        }
    }

    private var activeProjectName: String? {
        guard let id = projectStore.activeProjectID else { return nil }
        return projectStore.projects.first(where: { $0.id == id })?.displayName
    }

    private var abbreviatedActivePath: String? {
        guard let url = projectStore.activeProjectURL else {
            if projectStore.activeFreeTerminalID != nil {
                return "~"
            }
            return nil
        }
        return (url.standardizedFileURL.path as NSString).abbreviatingWithTildeInPath
    }

    private var visibleArea: StatusBarVisibleArea {
        guard rightDockStore.isExpanded else { return .terminal }
        switch rightDockStore.activeTab {
        case .files: return .files
        case .git: return .git
        }
    }

    private var totalChangesCount: Int {
        guard let snapshot = gitStore.statusSnapshot else { return 0 }
        return snapshot.staged.count
            + snapshot.modified.count
            + snapshot.untracked.count
    }
}

// MARK: - Location (left)

private struct StatusBarLocationLabel: View {
    let path: String?
    let projectName: String?
    let branch: String?
    let changesCount: Int

    var body: some View {
        HStack(spacing: 6) {
            if let path {
                Text(path)
                    .font(AppFonts.statusBar)
                    .foregroundStyle(AppPalette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(-1)
            }

            if let projectName {
                bullet
                Text(projectName)
                    .font(AppFonts.statusBar.weight(.medium))
                    .foregroundStyle(AppPalette.textSecondary)
                    .lineLimit(1)
            }

            if let branch {
                bullet
                Image(systemName: "arrow.triangle.branch")
                    .font(AppFonts.toolbarIcon)
                    .foregroundStyle(AppPalette.textTertiary)
                Text(branch)
                    .font(AppFonts.statusBar)
                    .foregroundStyle(AppPalette.textSecondary)
                    .lineLimit(1)

                if changesCount > 0 {
                    Text("\(changesCount)")
                        .font(AppFonts.badge)
                        .foregroundStyle(AppPalette.textSecondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(AppPalette.textTertiary.opacity(0.18))
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                }
            }
        }
    }

    private var bullet: some View {
        Text("·")
            .font(AppFonts.statusBar)
            .foregroundStyle(AppPalette.textTertiary)
    }
}

// MARK: - Context Info (right)

enum StatusBarVisibleArea {
    case terminal
    case git
    case files
}

private struct StatusBarContextInfo: View {
    let visibleArea: StatusBarVisibleArea
    let selectedFileName: String?

    var body: some View {
        HStack(spacing: 5) {
            switch visibleArea {
            case .terminal:
                Image(systemName: "terminal")
                    .font(AppFonts.toolbarIcon)
                Text("Terminal")
                    .font(AppFonts.statusBar)

            case .git:
                Image(systemName: "arrow.triangle.pull")
                    .font(AppFonts.toolbarIcon)
                Text("Git")
                    .font(AppFonts.statusBar)

            case .files:
                if let name = selectedFileName {
                    Image(systemName: "doc")
                        .font(AppFonts.toolbarIcon)
                    Text(name)
                        .font(AppFonts.statusBar)
                        .lineLimit(1)
                } else {
                    Image(systemName: "folder")
                        .font(AppFonts.toolbarIcon)
                    Text("Files")
                        .font(AppFonts.statusBar)
                }
            }
        }
        .foregroundStyle(AppPalette.textTertiary)
    }
}

// MARK: - Metal Stats (DEBUG only)

#if DEBUG
private struct MetalStatsView: View {
    @Environment(GhosttyAppManager.self) private var manager
    @State private var total = 0
    @State private var active = 0

    var body: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(active <= 1 ? Color.green : Color.orange)
                .frame(width: 6, height: 6)
            Text("Metal \(active)/\(total)")
                .font(Font.system(.caption, design: .monospaced))
        }
        .foregroundStyle(AppPalette.textTertiary)
        .help("Active/Total Metal surfaces (ideal: 1 active)")
        .onAppear { refresh() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            refresh()
        }
    }

    private func refresh() {
        let stats = manager.surfaceStats
        total = stats.total
        active = stats.active
    }
}
#endif
