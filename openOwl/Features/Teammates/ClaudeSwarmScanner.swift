import Foundation

// MARK: - Models

/// A Claude Code subagent (teammate) process, as launched by Claude's Team /
/// swarm mode: `claude … --agent-id <name>@session-<hex> --agent-name <name>
/// --agent-color <color> … --model opus`.
struct TeammateAgent: Identifiable, Equatable {
    let pid: Int32
    /// Full `--agent-id` value (e.g. `reviewer@session-eb28c314`).
    let id: String
    /// `--agent-name` (e.g. `reviewer`).
    let name: String
    /// `--team-name` (the parent session id, e.g. `session-eb28c314`).
    let team: String?
    /// `--agent-color` name as Claude reports it (purple / pink / orange…).
    var colorName: String
    /// `--agent-type` (e.g. `pr-review-toolkit:code-reviewer` or `general-purpose`).
    let type: String?
    /// `--model` (e.g. `opus`, `opus[1m]`).
    let model: String?

    var idForSwiftUI: Int32 { pid }
}

/// One pane inside a swarm's tmux window. The pane's process is the actual
/// `claude` agent binary, so we can map pane → agent deterministically via
/// `pane_pid` (no fragile title matching).
struct TeammatePane: Identifiable, Equatable {
    let index: Int
    /// tmux pane title — Claude's own label for this view (e.g. `✳ general-purpose`).
    let title: String
    /// Resolved agent for the pane's pid, when it is a claude teammate.
    let agent: TeammateAgent?

    var id: Int { index }
}

/// A live "View teammates" swarm: a tmux server on socket `claude-swarm-<pid>`
/// whose window shows one pane per teammate (or the orchestrator's view).
struct ClaudeSwarmSession: Identifiable, Equatable {
    /// tmux socket base name, e.g. `claude-swarm-42398`.
    let socketName: String
    /// The pid embedded in the socket name — the parent `claude` process that
    /// owns the swarm.
    let ownerPID: Int32
    /// Panes in the swarm window, one per teammate.
    let panes: [TeammatePane]
    /// Tail of the first pane's captured output (live activity preview).
    let outputTail: String?

    var id: String { socketName }
}

// MARK: - Scanner

/// Discovers running Claude swarm sessions. Two sources are cross-referenced:
/// 1. live tmux sockets under the user's tmux dir (`claude-swarm-<pid>`), and
/// 2. each pane's process (`pane_pid` → `ps -o args=` → `--agent-*` flags).
/// All I/O is synchronous subprocess calls — callers run it off the main actor.
enum ClaudeSwarmScanner {

    static var socketRoot: String { "/private/tmp/tmux-\(getuid())" }

    private(set) static var cachedTmuxPath: String?

    static func scan(socketRoot: String? = nil) -> [ClaudeSwarmSession] {
        let root = socketRoot ?? Self.socketRoot
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        let sockets = entries.filter { $0.hasPrefix("claude-swarm-") }.sorted()

        var sessions: [ClaudeSwarmSession] = []
        for socket in sockets {
            guard isLive(socket) else { continue }
            let panes = panes(in: socket)
            let ownerPID = Int32(socket.dropFirst("claude-swarm-".count)) ?? 0
            sessions.append(ClaudeSwarmSession(
                socketName: socket,
                ownerPID: ownerPID,
                panes: panes,
                outputTail: outputTail(of: socket)
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