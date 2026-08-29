import Foundation

/// Discovers running Claude swarm sessions (source `.claude`).
///
/// Two sources are cross-referenced:
/// 1. live tmux sockets under the user's tmux dir (`claude-swarm-<pid>`), and
/// 2. each pane's process (`pane_pid` → `ps -o args=` → `--agent-*` flags),
/// which gives a deterministic pane → agent map without fragile title matching.
/// All I/O is synchronous subprocess calls — callers run it off the main actor.
enum ClaudeSwarmScanner {

    static var socketRoot: String { "/private/tmp/tmux-\(getuid())" }

    private(set) static var cachedTmuxPath: String?

    static func scan(socketRoot: String? = nil) -> [TeammateSession] {
        let root = socketRoot ?? Self.socketRoot
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        let sockets = entries.filter { $0.hasPrefix("claude-swarm-") }.sorted()

        var sessions: [TeammateSession] = []
        for socket in sockets {
            guard isLive(socket) else { continue }
            let panes = panes(in: socket)
            let agents = panes.map { pane -> TeammateAgent in
                if let agent = pane.agent { return agent }
                // Pane without a resolvable claude process — fall back to the
                // pane title so the row still says what is in there.
                var name = pane.title
                if name.hasPrefix("✳ ") { name.removeFirst(2) }
                if name.isEmpty { name = "unnamed pane" }
                return TeammateAgent(
                    pid: nil,
                    id: "\(socket)-pane\(pane.index)",
                    name: name,
                    team: nil,
                    colorName: nil,
                    type: nil,
                    model: nil
                )
            }
            let ownerPID = Int32(socket.dropFirst("claude-swarm-".count)) ?? 0
            sessions.append(TeammateSession(
                source: .claude,
                id: socket,
                name: socket,
                detail: "\(panes.count) \(panes.count == 1 ? "pane" : "panes")",
                agents: agents,
                outputTail: outputTail(of: socket),
                attach: .command("tmux -L \(socket) a"),
                timestamp: Date()
            ))
        }
        return sessions
    }

    // MARK: tmux

    /// `tmux -L <socket> ls` succeeds only when the server is up.
    static func isLive(_ socket: String) -> Bool {
        runTMUX(["-L", socket, "ls"]) != nil
    }

    static func panes(in socket: String) -> [TeammatePane] {
        guard let out = runTMUX(["-L", socket, "list-panes", "-a", "-F", "#{pane_index}\t#{pane_pid}\t#{pane_title}"]) else {
            return []
        }
        return Self.parsePanesOutput(out)
    }

    /// `tmux capture-pane -t 0` → last non-empty lines (live output preview).
    static func outputTail(of socket: String, maxLines: Int = 3) -> String? {
        guard let out = runTMUX(["-L", socket, "capture-pane", "-p", "-t", "0"]) else { return nil }
        let lines = out.split(separator: "\n").map(String.init)
        let trimmed = lines.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !trimmed.isEmpty else { return nil }
        return trimmed.suffix(maxLines).joined(separator: "\n")
    }

    /// Pure: `list-panes -F "#{pane_index}\t#{pane_pid}\t#{pane_title}"` output
    /// → panes, resolving each pane's agent by pid. Exposed for tests.
    static func parsePanesOutput(_ output: String) -> [TeammatePane] {
        var panes: [TeammatePane] = []
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t").map(String.init)
            guard parts.count >= 3,
                  let index = Int(parts[0]),
                  let pid = Int32(parts[1].trimmingCharacters(in: .whitespaces))
            else { continue }
            let title = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
            let agent = Self.agent(forPID: pid)
            panes.append(TeammatePane(index: index, title: title, agent: agent))
        }
        return panes.sorted { $0.index < $1.index }
    }

    // MARK: ps

    static func agent(forPID pid: Int32) -> TeammateAgent? {
        guard let args = run("/bin/ps", ["-p", "\(pid)", "-o", "args="]),
              args.contains("--agent-id")
        else { return nil }
        return Self.parseAgent(args: args, pid: pid)
    }

    /// Pure: parse `--agent-*` flags out of a claude process command line.
    static func parseAgent(args: String, pid: Int32) -> TeammateAgent? {
        let tokens = args.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var values: [String: String] = [:]
        let wanted: Set<String> = [
            "--agent-id", "--agent-name", "--team-name", "--agent-color", "--agent-type", "--model",
        ]
        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            if wanted.contains(token), i + 1 < tokens.count {
                values[token] = tokens[i + 1]
                i += 2
            } else {
                i += 1
            }
        }
        guard let id = values["--agent-id"],
              let name = values["--agent-name"],
              let color = values["--agent-color"]
        else { return nil }
        return TeammateAgent(
            pid: pid,
            id: id,
            name: name,
            team: values["--team-name"],
            colorName: color,
            type: values["--agent-type"],
            model: values["--model"]
        )
    }

    // MARK: Process helpers

    private static func runTMUX(_ args: [String]) -> String? {
        guard let tmux = tmuxPath() else { return nil }
        return run(tmux, args)
    }

    /// Locate tmux — GUI-launched apps get a minimal PATH without Homebrew, so
    /// resolve the binary explicitly once and cache it.
    static func tmuxPath() -> String? {
        if let cached = cachedTmuxPath { return cached }
        let candidates = [
            "/opt/homebrew/bin/tmux",
            "/usr/local/bin/tmux",
            "/usr/bin/tmux",
            "/bin/tmux",
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            cachedTmuxPath = candidate
            return candidate
        }
        cachedTmuxPath = nil
        return nil
    }

    /// Runs `executable args`, returns trimmed stdout. Times out and terminates
    /// the process rather than hanging the UI on a wedged tmux server.
    static func run(_ executable: String, _ args: [String], timeout: TimeInterval = 3) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading

        do {
            try process.run()
        } catch {
            return nil
        }

        var outData = Data()
        let drain = DispatchGroup()
        drain.enter()
        DispatchQueue.global(qos: .utility).async {
            outData.append(outHandle.readDataToEndOfFile())
            _ = errHandle.readDataToEndOfFile()
            drain.leave()
        }
        guard drain.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return nil
        }
        let text = String(data: outData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == true ? nil : text
    }
}

/// One pane inside a swarm's tmux window. The pane's process is the actual
/// `claude` agent binary, so pane → agent maps deterministically via `pane_pid`.
struct TeammatePane: Equatable {
    let index: Int
    /// tmux pane title — Claude's own label for this view (e.g. `✳ general-purpose`).
    let title: String
    /// Resolved agent for the pane's pid, when it is a claude teammate.
    let agent: TeammateAgent?
}