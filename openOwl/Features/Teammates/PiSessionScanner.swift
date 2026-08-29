import Foundation

/// pi coding-agent sessions (source `.pi`).
///
/// Each session is a JSONL transcript under
/// `~/.pi/agent/sessions/<project-slug>/<started-ts>_<session-id>.jsonl`,
/// e.g. `2026-08-27T04-01-51-612Z_01a04161-….jsonl`. Header lines give:
/// - `{"type":"session", cwd, timestamp}` — project + start
/// - `{"type":"model_change", provider, modelId}` — model
/// - first `message{role:user}` — first user text doubles as the title
///
/// The *current* conversation is a live pi session (its file grows as pi
/// works), so the panel naturally shows "pi is working right now" too.
/// Attach opens the transcript in the editor.
enum PiSessionScanner {

    static var rootURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".pi/agent/sessions")
    }

    /// Most-recent sessions to surface.
    static let limit = 12

    static func scan(rootURL: URL? = nil) -> [TeammateSession] {
        let root = rootURL ?? Self.rootURL
        let fm = FileManager.default
        guard let slugs = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }

        var files: [(url: URL, mtime: Date?)] = []
        for slug in slugs {
            let dir = root.appendingPathComponent(slug)
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names where name.hasSuffix(".jsonl") {
                let url = dir.appendingPathComponent(name)
                let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
                files.append((url, mtime))
            }
        }
        files.sort {
            ($0.mtime ?? .distantPast) > ($1.mtime ?? .distantPast)
        }

        let now = Date()
        return files.prefix(Self.limit).map { file in
            let header = parseHeader(url: file.url)
            let mtime = file.mtime ?? .distantPast
            let isLive = now.timeIntervalSince(mtime) < TeammateSession.liveWindow
            let project = (header.cwd as NSString?)?.lastPathComponent ?? file.url.deletingLastPathComponent().lastPathComponent
            let title = header.title ?? "pi session"

            return TeammateSession(
                source: .pi,
                id: file.url.lastPathComponent,
                name: title,
                detail: "\(project) · \(header.model ?? "?")",
                agents: [
                    TeammateAgent(
                        pid: nil,
                        id: file.url.lastPathComponent,
                        name: title,
                        team: nil,
                        colorName: isLive ? "green" : nil,
                        type: "pi session",
                        model: header.model
                    )
                ],
                outputTail: nil,
                attach: .openFile(file.url.path),
                timestamp: mtime
            )
        }
    }

    // MARK: Parsing (pure, tested)

    struct Header {
        var cwd: String?
        var model: String?
        var title: String?
    }

    static func parseHeader(url: URL, maxBytes: Int = 16_384) -> Header {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return Header() }
        let prefix = String(decoding: data.prefix(maxBytes), as: UTF8.self)
        return parseHeaderData(prefix)
    }

    /// Scans session JSONL prefix for the session record (cwd), the latest
    /// model change in the window, and the first user text message.
    static func parseHeaderData(_ text: String) -> Header {
        var header = Header()
        for line in text.split(separator: "\n") {
            guard let json = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
                continue
            }
            switch json["type"] as? String {
            case "session":
                if header.cwd == nil {
                    header.cwd = json["cwd"] as? String
                }
            case "model_change":
                header.model = json["modelId"] as? String ?? header.model
            case "message":
                if header.title == nil,
                   let message = json["message"] as? [String: Any],
                   (message["role"] as? String) == "user",
                   let content = message["content"] as? [[String: Any]],
                   let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String,
                   !text.isEmpty {
                    let oneLine = text.replacingOccurrences(of: "\n", with: " ")
                    header.title = oneLine.count > 72 ? String(oneLine.prefix(72)) + "…" : oneLine
                }
            default:
                break
            }
            if header.cwd != nil, header.title != nil, header.model != nil { break }
        }
        return header
    }
}