import Foundation
import Observation

/// Live roster of Claude Code swarm sessions ("teammates").
///
/// Scans tmux sockets + claude agent processes on a background queue and
/// publishes the result on the main actor, so the panel can render a
/// continuously-updating view of who is working right now.
@MainActor
@Observable
final class TeammatesStore {
    private(set) var sessions: [ClaudeSwarmSession] = []
    private(set) var isRefreshing = false
    private(set) var lastRefreshAt: Date?
    /// Set when the scanner cannot run (tmux missing / unusable), so the UI can
    /// say why the panel is empty instead of pretending there is nobody home.
    private(set) var lastError: String?

    /// Poll cadence. Fast enough that a new / finished teammate shows up within
    /// a few seconds of it changing.
    private let refreshInterval: TimeInterval = 5

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

    /// Prompt refresh (refresh button). Runs the scan off the main actor.
    func refreshNow() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let scanned: [ClaudeSwarmSession]
        let error: String?
        if ClaudeSwarmScanner.tmuxPath() == nil {
            scanned = []
            error = "tmux not found — teammates views run inside tmux."
        } else {
            scanned = await Task.detached(priority: .utility) {
                ClaudeSwarmScanner.scan()
            }.value
            error = nil
        }

        sessions = scanned
        lastRefreshAt = Date()
        lastError = error
    }
}