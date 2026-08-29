import Foundation

/// Which agent ecosystem a roster entry came from. The three share one card
/// shape but have completely different substrates:
///
/// - `.claude` — Claude Code Team/swarm, multiplexed into tmux (`claude-swarm-*`);
///   pane processes give per-agent color/type/model for free.
/// - `.codex` — OpenAI Codex sessions on the local app-server daemon; local
///   state is `~/.codex/session_index.jsonl` + archived JSONL rollouts.
/// - `.pi` — pi (this coding agent) sessions, logged as JSONL transcripts under
///   `~/.pi/agent/sessions/<project>/<ts>_<sessionid>.jsonl`.
enum TeammateSource: String, CaseIterable, Equatable, Sendable {
    case claude
    case codex
    case pi

    var label: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .pi: return "Pi"
        }
    }
}

/// What the panel's attach button should do for a session.
enum TeammateAttach: Equatable, Sendable {
    /// Run in a new terminal tab (claude → `tmux -L <socket> a`, codex → `codex resume <id>`).
    case command(String)
    /// Open a file in the editor (pi → the session transcript).
    case openFile(String)
}

/// One working entity inside a roster entry. Metadata availability differs by
/// source — claude panes carry color/type/model, codex/pi sessions at best have
/// a title + model.
struct TeammateAgent: Identifiable, Equatable, Sendable {
    /// Process id (claude only; the pane's pid resolving to a claude agent).
    let pid: Int32?
    /// Source-local identity (claude agent-id, codex/pi session id).
    let id: String
    /// Display name (agent-name / thread name / first user message).
    let name: String
    /// Parent team/session (claude `--team-name`).
    let team: String?
    /// Claude `--agent-color`; also reused for the generic "live" green dot.
    let colorName: String?
    /// Role / type (e.g. `pr-review-toolkit:code-reviewer`).
    let type: String?
    /// Model (e.g. `opus`, `opus[1m]`).
    let model: String?

    var idForSwiftUI: String { id }
}

/// One row in the Teammates panel — a live swarm (claude), a recent codex
/// session, or a recent pi session (including the conversation running pi).
struct TeammateSession: Identifiable, Equatable, Sendable {
    let source: TeammateSource
    /// Source-local identity (socket name / codex session id / pi session uuid).
    let id: String
    /// Primary label (socket name / thread name / pi title).
    let name: String
    /// Secondary line (claude pane count, codex cwd, pi project · model).
    let detail: String?
    let agents: [TeammateAgent]
    /// Last captured output (claude tmux pane tail; nil for codex/pi).
    let outputTail: String?
    let attach: TeammateAttach?
    /// Update time used for ordering/freshness.
    let timestamp: Date?

    var idForSwiftUI: String { "\(source.rawValue)-\(id)" }

    /// Claude sessions are live by construction (the socket is alive); others
    /// count as live while their last update is recent.
    var isLive: Bool {
        if source == .claude { return true }
        guard let timestamp else { return false }
        return Date().timeIntervalSince(timestamp) < Self.liveWindow
    }

    static let liveWindow: TimeInterval = 10 * 60
}