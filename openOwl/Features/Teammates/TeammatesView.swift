import SwiftUI

/// Right-dock panel that shows live agent sessions — Claude Code Team/swarm,
/// Codex, and pi — and attaches to them from the built-in terminal.
///
/// Each swarm is a tmux server on socket `claude-swarm-<pid>`; its window has
/// one pane per teammate. Codex sessions come from the local session index,
/// pi sessions from the transcript store (the running conversation is a live
/// pi session). Attach: claude → `tmux -L <socket> a`, codex → `codex resume
/// <id>` (both open a terminal tab), pi → open the transcript in the editor.
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
        if let notice = store.notice {
            noticeBanner(notice)
        }
        if store.sessions.isEmpty {
            Spacer()
            EmptyStateView(
                "No agent sessions",
                subtitle: "Claude swarms, Codex sessions and pi sessions appear here.\nStart one, or view teammates: tmux -L claude-swarm-<pid> a",
                systemImage: "person.2",
                density: .compact
            )
            Spacer()
        } else {
            sessionList
        }
    }

    private func noticeBanner(_ message: String) -> some View {
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

    private func sessionCard(_ session: TeammateSession) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                sourceBadge(session.source)
                Text(session.name)
                    .font(Self.mono(10, .medium))
                    .foregroundStyle(AppPalette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if session.isLive {
                    Circle()
                        .fill(AppPalette.accent.opacity(0.9))
                        .frame(width: 6, height: 6)
                }
                Spacer(minLength: 4)
                if let detail = session.detail {
                    Text(detail)
                        .font(AppFonts.caption)
                        .foregroundStyle(AppPalette.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let attach = session.attach {
                    attachButton(attach)
                }
            }

            if session.agents.isEmpty {
                Text("no agents")
                    .font(AppFonts.caption)
                    .foregroundStyle(AppPalette.textTertiary)
                    .padding(.leading, 2)
            } else {
                ForEach(session.agents) { agent in
                    agentRow(agent)
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
        .accessibilityElement(children: .contain)
    }

    private func agentRow(_ agent: TeammateAgent) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Self.agentColor(agent.colorName))
                .frame(width: 8, height: 8)
            Text(agent.name)
                .font(AppFonts.primaryLabel)
                .foregroundStyle(AppPalette.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let type = agent.type {
                Text(type)
                    .font(AppFonts.caption)
                    .foregroundStyle(AppPalette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 2)
            if let model = agent.model {
                Text(model)
                    .font(Self.mono(9, .regular))
                    .foregroundStyle(AppPalette.textTertiary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Source badge

    /// Category color per ecosystem — color encodes the *source*, not sequence.
    static func sourceColor(_ source: TeammateSource) -> Color {
        switch source {
        case .claude: return Color(red: 0.50, green: 0.47, blue: 0.87) // purple ramp
        case .codex: return Color(red: 0.11, green: 0.62, blue: 0.46) // teal ramp
        case .pi: return Color(red: 0.22, green: 0.54, blue: 0.92) // blue ramp
        }
    }

    private func sourceBadge(_ source: TeammateSource) -> some View {
        Text(source.label)
            .font(AppFonts.caption.weight(.medium))
            .foregroundStyle(Self.sourceColor(source))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Self.sourceColor(source).opacity(0.16))
            .clipShape(Capsule())
    }

    // MARK: - Actions

    private func attachButton(_ attach: TeammateAttach) -> some View {
        Button {
            perform(attach)
        } label: {
            Image(systemName: iconFor(attach))
        }
        .buttonStyle(.icon(font: AppFonts.toolbarIcon, size: 18))
        .help(helpFor(attach))
        .accessibilityLabel(helpFor(attach))
    }

    private func iconFor(_ attach: TeammateAttach) -> String {
        switch attach {
        case .command: return "terminal"
        case .openFile: return "doc.plaintext"
        }
    }

    private func helpFor(_ attach: TeammateAttach) -> String {
        switch attach {
        case .command(let command): return "Attach in terminal: \(command)"
        case .openFile(let path): return "Open transcript: \(path)"
        }
    }

    private func perform(_ attach: TeammateAttach) {
        switch attach {
        case .command(let command):
            let config = TerminalSurfaceConfiguration(command: command)
            _ = workspace.newTab(for: nil, configuration: config)
            workspace.notifyContextChange()
            // The point of attach is to watch the agent — collapse the dock so
            // the terminal pane is actually visible instead of hiding behind
            // the panel.
            dock.collapse()

        case .openFile(let path):
            NotificationCenter.default.post(
                name: .openFileFromTerminal,
                object: nil,
                userInfo: ["url": URL(fileURLWithPath: path)]
            )
            // The transcript opens in the Files editor — switch the dock so it
            // is visible instead of sitting behind the Teammates panel.
            dock.activeTab = .files
        }
    }

    // MARK: - Helpers

    private static func mono(_ size: CGFloat, _ weight: Font.Weight) -> Font {
        Font.system(size: size, weight: weight, design: .monospaced)
    }

    /// Claude's `--agent-color` name → dot color; the generic "green" means a
    /// live codex/pi session. Unknown names fall back to a neutral accent.
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