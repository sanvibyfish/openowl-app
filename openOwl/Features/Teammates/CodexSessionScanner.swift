import Foundation

/// Codex sessions (source `.codex`).
///
/// Codex agents run on the app-server daemon and keep local state as:
/// - `~/.codex/session_index.jsonl` — one line per session:
///   `{id, thread_name, updated_at}` (updated_at → freshness ordering).
/// - `~/.codex/archived_sessions/rollout-<ts>-<session-id>.jsonl` — full
///   rollouts; the first line carries `cwd` we can show, read on demand only
///   for the sessions the panel actually lists.
///
/// Attach maps to `codex resume <session-id>` (interactive TUI in a terminal).
enum CodexSessionScanner {

    static var indexURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/session_index.jsonl")
    }

    static var archivedDir: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/archived_sessions")
    }

    /// How many most-recent sessions to surface. Bounded so archived-rollout
    /// enrichment only opens a handful of files per poll.
    static let limit = 15

    static func scan(indexURL: URL? = nil, archivedDir: URL? = nil) -> [TeammateSession] {
        let index = indexURL ?? Self.indexURL
        guard let text = try? String(contentsOf: index, encoding: .utf8) else { return [] }

        var entries: [IndexEntry] = []
        for line in text.split(separator: "\n") {
            guard let entry = parseIndexLine(String(line)) else { continue }
            entries.append(entry)
        }
        entries.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }

        guard !entries.isEmpty else { return [] }
        let recent = entries.prefix(Self.limit)
        let cwds = archivedCWDs(ids: Set(recent.map { $0.id }), archivedDir: archivedDir ?? Self.archivedDir)
        let now = Date()

        return recent.map { entry in
            let cwd = cwds[entry.id]
            let isLive = entry.date.map { now.timeIntervalSince($0) < TeammateSession.liveWindow } ?? false
            return TeammateSession(
                source: .codex,
                id: entry.id,
                name: entry.name.isEmpty ? "codex session \(entry.id.prefix(8))" : entry.name,
                detail: cwd,
                agents: [
                    TeammateAgent(
                        pid: nil,
                        id: entry.id,
                        name: entry.name.isEmpty ? "codex session" : entry.name,
                        team: nil,
                        colorName: isLive ? "green" : nil,
                        type: "codex session",
                        model: nil
                    )
                ],
                outputTail: nil,
                attach: .command("codex resume \(entry.id)"),
                timestamp: entry.date
            )
        }
    }

    // MARK: Parsing (pure, tested)

    struct IndexEntry {
        let id: String
        let name: String
        let date: Date?
    }

    static func parseIndexLine(_ line: String) -> IndexEntry? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        guard let id = json["id"] as? String, !id.isEmpty else { return nil }
        let name = json["thread_name"] as? String ?? ""
        let date = (json["updated_at"] as? String).flatMap { Self.dateFormatter.date(from: $0) }
        return IndexEntry(id: id, name: name, date: date)
    }

    private static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Read `cwd` from the first line of each matching rollout file — only for
    /// the ids we actually list.
    static func archivedCWDs(ids: Set<String>, archivedDir: URL) -> [String: String] {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: archivedDir.path) else {
            return [:]
        }
        var result: [String: String] = [:]
        for file in files where file.hasPrefix("rollout-") {
            guard let id = sessionID(fromRolloutFilename: file), ids.contains(id) else { continue }
            let url = archivedDir.appendingPathComponent(file)
            guard let first = try? String(contentsOf: url, encoding: .utf8)
                .split(separator: "\n").first
            else { continue }
            result[id] = cwd(fromRolloutFirstLine: String(first))
        }
        return result
    }

    /// `rollout-<ts>-<uuid>.jsonl` → uuid.
    static func sessionID(fromRolloutFilename file: String) -> String? {
        let stem = String(file.dropFirst("rollout-".count))
            .replacingOccurrences(of: ".jsonl", with: "")
        let components = stem.split(separator: "-", omittingEmptySubsequences: true)
        guard components.count >= 5 else { return nil }
        return components.suffix(5).joined(separator: "-")
    }

    static func cwd(fromRolloutFirstLine line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = json["payload"] as? [String: Any]
        else { return nil }
        return payload["cwd"] as? String
    }
}