import SwiftUI

/// Right-dock panel that shows live Claude Code Team / swarm sessions
/// ("teammates") and attaches to them in the built-in terminal.
///
/// Each swarm is a tmux server on socket `claude-swarm-<pid>`; its window has
/// one pane per teammate. The panel lists those sessions with each pane's
/// resolved agent (name, color, role, model) plus a live output tail, and an
/// "attach" action that opens `tmux -L <socket> a` in a new terminal tab.
struct TeammatesView: View {
    @Environment(TeammatesStore.self) private var store
    @Environment(TerminalWorkspaceStore.self) private var workspace
    @Environment(RightDockStore.self) private var dock

    var body: some View {
        VStack(spacing: 0) {
            toolStrip
            content
        }
        .background(AppPalette.base)
    }

    // MARK: - Tool strip

    private var toolStrip: some View {
        HStack(spacing: 4) {
            Text("auto 5s")
                .font(AppFonts.caption)
                .foregroundStyle(AppPalette.textTertiary)
            Text("·")
                .font(AppFonts.caption)
                .foregroundStyle(AppPalette.textTertiary)
            if let updated = store.lastRefreshAt {
                Text("updated \(updated.formatted(date: .omitted, time: .standard))")
                    .font(AppFonts.caption)
                    .foregroundStyle(AppPalette.textTertiary)
            }
            Spacer(minLength: 0)
            Button {
                Task { await store.refreshNow() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.icon(font: AppFonts.toolbarIcon, size: 22))
            .help("Refresh")
            .accessibilityLabel("Refresh teammates")
            .disabled(store.isRefreshing)
        }
        .padding(.horizontal, 6)
        .panelToolHeader(background: AppPalette.base)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let error = store.lastError {
            VStack(spacing: 0) {
                errorBanner(error)
                Spacer()
            }
        } else if store.sessions.isEmpty {
            Spacer()
            EmptyStateView(
                "No teammate sessions",
                subtitle: "Claude Code team / swarm sessions appear here.\nView teammates: tmux -L claude-swarm-<pid> a",
                systemImage: "person.2",
                density: .compact
            )
            Spacer()
        } else {
            sessionList
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(AppFonts.toolbarIcon)
            Text(message).font(AppFonts.caption)
            Spacer()
        }
        .foregroundStyle(.red)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color.red.opacity(0.12))
    }

    private var sessionList: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(store.sessions) { session in
                    sessionCard(session)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
        }
    }

    private func sessionCard(_ session: ClaudeSwarmSession) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "square.split.2x1")
                    .font(AppFonts.toolbarIcon)
                    .foregroundStyle(AppPalette.textTertiary)
                Text(session.socketName)
                    .font(Self.mono(10, .medium))
                    .foregroundStyle(AppPalette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text("\(session.panes.count) \(session.panes.count == 1 ? "pane" : "panes")")
                    .font(AppFonts.caption)
                    .foregroundStyle(AppPalette.textTertiary)
                attachButton(session)
            }

            if session.panes.isEmpty {
                Text("no panes")
                    .font(AppFonts.caption)
                    .foregroundStyle(AppPalette.textTertiary)
                    .padding(.leading, 2)
            } else {
                ForEach(session.panes) { pane in
                    paneRow(pane)
                }
            }

            if let tail = session.outputTail, !tail.isEmpty {
                Text(tail)
                    .font(Self.mono(9, .regular))
                    .foregroundStyle(AppPalette.textTertiary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(AppPalette.elevated)
                    .clipShape(RoundedRectangle(cornerRadius: AppSpacing.cornerRadiusSmall, style: .continuous))
            }
        }
        .padding(8)
        .background(AppPalette.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppSpacing.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppSpacing.cornerRadius, style: .continuous)
                .stroke(AppPalette.border, lineWidth: 1)
        )
    }

    private func paneRow(_ pane: TeammatePane) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Self.agentColor(pane.agent?.colorName))
                .frame(width: 8, height: 8)
            Text(pane.agent?.name ?? paneTitle(pane.title))
                .font(AppFonts.primaryLabel)
                .foregroundStyle(AppPalette.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let type = pane.agent?.type {
                Text(type)
                    .font(AppFonts.caption)
                    .foregroundStyle(AppPalette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 2)
            if let model = pane.agent?.model {
                Text(model)
                    .font(Self.mono(9, .regular))
                    .foregroundStyle(AppPalette.textTertiary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Actions

    private func attachButton(_ session: ClaudeSwarmSession) -> some View {
        Button {
            attach(to: session)
        } label: {
            Image(systemName: "terminal")
        }
        .buttonStyle(.icon(font: AppFonts.toolbarIcon, size: 18))
        .help("Attach in terminal: tmux -L \(session.socketName) a")
        .accessibilityLabel("Attach \(session.socketName) in terminal")
    }

    private func attach(to session: ClaudeSwarmSession) {
        let config = TerminalSurfaceConfiguration(command: "tmux -L \(session.socketName) a")
        _ = workspace.newTab(for: nil, configuration: config)
        workspace.notifyContextChange()
        // The point of attach is to watch the swarm — collapse the dock so the
        // terminal pane is actually visible instead of hiding behind the panel.
        dock.collapse()
    }

    // MARK: - Helpers

    /// Strip Claude's "✳ " view-title prefix when the pane is not (yet) linked
    /// to an agent process.
    private func paneTitle(_ title: String) -> String {
        var text = title
        if text.hasPrefix("✳ ") { text.removeFirst(2) }
        return text.isEmpty ? "unnamed pane" : text
    }

    /// Claude's `--agent-color` name → dot color. Unknown colors fall back to a
    /// neutral accent so the row still reads as an identifier.
    private static func mono(_ size: CGFloat, _ weight: Font.Weight) -> Font {
        Font.system(size: size, weight: weight, design: .monospaced)
    }

    static func agentColor(_ name: String?) -> Color {
        guard let name else { return AppPalette.textTertiary }
        switch name.lowercased() {
        case "purple": return Color(red: 0.50, green: 0.47, blue: 0.87)
        case "pink": return Color(red: 0.83, green: 0.33, blue: 0.49)
        case "orange": return Color(red: 0.94, green: 0.62, blue: 0.15)
        case "yellow": return Color(red: 0.98, green: 0.78, blue: 0.46)
        case "cyan": return Color(red: 0.36, green: 0.79, blue: 0.65)
        case "blue": return Color(red: 0.22, green: 0.54, blue: 0.92)
        case "red": return Color(red: 0.89, green: 0.29, blue: 0.29)
        case "green": return Color(red: 0.39, green: 0.60, blue: 0.13)
        case "gray", "grey": return Color(red: 0.53, green: 0.52, blue: 0.50)
        default: return AppPalette.textTertiary
        }
    }
}