import Foundation
import Observation

/// Live roster of agent sessions across Claude swarm, Codex, and pi.
///
/// Each source scanner reads local state / processes off the main actor and
/// the result is merged here: claude swarms (live tmux), recent codex
/// sessions (session index + rollouts), recent pi sessions (transcripts).
/// The panel renders one card per session, grouped visually by source badge.
@MainActor
@Observable
final class TeammatesStore {
    private(set) var sessions: [TeammateSession] = []
    private(set) var isRefreshing = false
    private(set) var lastRefreshAt: Date?
    /// Set when claude's tmux isn't available, so the panel can say why the
    /// claude section is missing without hiding codex/pi entries.
    private(set) var notice: String?

    /// Poll cadence. Fast enough that a new / finished teammate shows up within
    /// a few seconds of it changing.
    private let refreshInterval: TimeInterval = 5

    /// Total rows cap across sources keeps the panel shallow.
    private let maxSessions = 25

    private var pollingTask: Task<Void, Never>?
    private var hasStarted = false

    var isEmpty: Bool { sessions.isEmpty }

    func startPollingIfNeeded() {
        guard !hasStarted else { return }
        hasStarted = true
        pollingTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshNow()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self.refreshInterval))
                if Task.isCancelled { break }
                await self.refreshNow()
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
        hasStarted = false
    }

    /// Prompt refresh (refresh button). Runs each scanner off the main actor.
    func refreshNow() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        async let claude = Task.detached(priority: .utility) { ClaudeSwarmScanner.scan() }.value
        async let codex = Task.detached(priority: .utility) { CodexSessionScanner.scan() }.value
        async let pi = Task.detached(priority: .utility) { PiSessionScanner.scan() }.value
        let (claudeSessions, codexSessions, piSessions) = await (claude, codex, pi)

        sessions = Self.merged(claudeSessions + codexSessions + piSessions, max: maxSessions)
        notice = ClaudeSwarmScanner.tmuxPath() == nil
            ? "tmux not found — Claude swarm views unavailable."
            : nil
        lastRefreshAt = Date()
    }

    /// Live first, then most recently updated; clamp to `max`.
    static func merged(_ input: [TeammateSession], max: Int) -> [TeammateSession] {
        input
            .sorted { lhs, rhs in
                if lhs.isLive != rhs.isLive { return lhs.isLive }
                return (lhs.timestamp ?? .distantPast) > (rhs.timestamp ?? .distantPast)
            }
            .prefix(max)
            .map { $0 }
    }
}