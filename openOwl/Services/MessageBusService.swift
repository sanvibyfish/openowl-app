import Foundation
import Observation

// MARK: - Models (protocol-compatible with scripts/message-bus/buslib.py)

struct BusMessage: Codable, Identifiable, Equatable {
    let id: String
    let from: String
    let to: String
    let ts: String
    let kind: String
    let body: String
    let replyTo: String?
    let meta: [String: String]?
}

struct BusAgentInfo: Identifiable, Equatable {
    let name: String
    let kind: String
    let cwd: String?
    let paneId: String?
    let heartbeat: String?
    var isOnline: Bool

    var id: String { name }
}

/// Swift side of the openOwl message bus (REQ-009). Mirrors the semantics of
/// `scripts/message-bus/buslib.py` exactly so the GUI, the CLI and every agent
/// adapter share one protocol:
///   - ~/.openowl/bus/agents.json          registry (name -> info)
///   - ~/.openowl/bus/inboxes/{agent}.jsonl per-agent queue (JSONL, flock)
///   - ~/.openowl/bus/cursors/{agent}.json  read watermark (max id)
/// Message ids are YYYYMMDDHHMMSSffffff + pid + seq so string comparison is
/// chronological — the watermark (max id) depends on that (see REQ-009 §4.1).
@MainActor
@Observable
final class MessageBusService {
    // MARK: Published state (UI)

    private(set) var messages: [BusMessage] = []   // openowl inbox, newest first
    private(set) var agents: [BusAgentInfo] = []
    private(set) var unreadCount = 0
    var sendTo = "codex"
    var sendBody = ""

    // MARK: Configuration

    static let ownAgentName = "openowl"
    private static let onlineWindow: TimeInterval = 300

    private let busDir: URL
    private let inboxDir: URL
    private let cursorDir: URL
    private let lockDir: URL
    private let registryURL: URL

    private var pollTimer: Timer?
    private var registeredPaneIDs: Set<String> = []
    /// Explicit user-chosen bus names per pane (right-click on the tab bar).
    /// Outranks pane titles and the pane-N fallback.
    private var paneNameOverrides: [String: String] = [:]
    private var paneSequence: [String: Int] = [:]
    private var nextPaneSequence = 0
    private let paneNamesURL: URL
    private static var idSeq: UInt16 = 0
    private static let idSeqLock = NSLock()

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = ProcessInfo.processInfo.environment["OPENOWL_BUS"]
            .map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".openowl/bus", isDirectory: true)
        busDir = dir
        inboxDir = dir.appendingPathComponent("inboxes", isDirectory: true)
        cursorDir = dir.appendingPathComponent("cursors", isDirectory: true)
        lockDir = dir.appendingPathComponent("locks", isDirectory: true)
        registryURL = dir.appendingPathComponent("agents.json")
        paneNamesURL = dir.appendingPathComponent("pane-names.json")
        loadPaneNames()
    }

    // MARK: Lifecycle

    func start(panesProvider: @escaping () -> [(id: String, title: String?)]) {
        ensureDirectories()
        refresh()
        // Poll instead of FSEvents: bus files are small and infrequent; a
        // 2s timer keeps notification latency low without watcher complexity.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.registerPanes(panesProvider())
                self.refresh()
            }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func registerPanes(_ panes: [(id: String, title: String?)]) {
        let now = Date()
        for pane in panes {
            let seq: Int
            if let existing = paneSequence[pane.id] {
                seq = existing
            } else {
                nextPaneSequence += 1
                seq = nextPaneSequence
                paneSequence[pane.id] = seq
            }
            registeredPaneIDs.insert(pane.id)
            let name = paneNameOverrides[pane.id]
                ?? sanitizedPaneTitle(pane.title)
                ?? "pane-\(seq)"
            registerAgent(name: name, kind: "openowl-pane", paneId: pane.id, heartbeat: now)
        }
    }

    /// paneID → bus name for openowl panes (from the registry), used by tests
    /// and future routing/display.
    func listAgentNames() -> [String: String] {
        var result: [String: String] = [:]
        for info in loadAgents() where info.kind == "openowl-pane" {
            if let paneId = info.paneId {
                result[paneId] = info.name
            }
        }
        return result
    }

    /// User-facing bus name for a pane (override or derived), for tab labels.
    func paneName(for paneID: String) -> String? {
        paneNameOverrides[paneID]
    }

    /// Set/clear an explicit bus name for a pane (right-click on the tab bar).
    /// v1: overrides live in ~/.openowl/bus/pane-names.json keyed by pane UUID,
    /// which is per-session (panes are rebuilt on relaunch) — renaming after a
    /// restart is expected.
    func setPaneName(paneID: String, name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            paneNameOverrides.removeValue(forKey: paneID)
        } else {
            paneNameOverrides[paneID] = trimmed
        }
        persistPaneNames()
        refresh()
    }

    private func sanitizedPaneTitle(_ title: String?) -> String? {
        guard let title else { return nil }
        let cleaned = title
            .unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .map(String.init)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(40))
    }

    private func loadPaneNames() {
        guard let data = try? Data(contentsOf: paneNamesURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return
        }
        paneNameOverrides = obj
    }

    private func persistPaneNames() {
        atomicWrite(Self.jsonString(paneNameOverrides), to: paneNamesURL)
    }

    /// Register this app + keep the registry heartbeat fresh.
    func refresh() {
        registerAgent(name: Self.ownAgentName, kind: "openowl", heartbeat: Date())
        agents = loadAgents()
        let unread = unread(for: Self.ownAgentName, limit: 200)
        unreadCount = unread.count
        messages = unread.reversed() // newest first
    }

    // MARK: Send

    @discardableResult
    func send(_ body: String, to agent: String, from sender: String? = nil,
              kind: String = "message", replyTo: String? = nil) -> String? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !agent.isEmpty else { return nil }
        let effectiveSender = sender ?? MessageBusService.ownAgentName
        let msg = BusMessage(
            id: Self.newID(),
            from: effectiveSender,
            to: agent,
            ts: Self.nowISO(),
            kind: kind,
            body: trimmed,
            replyTo: replyTo,
            meta: nil
        )
        let path = inboxDir.appendingPathComponent("\(agent).jsonl")
        let lockPath = lockDir.appendingPathComponent("\(agent).lock")
        let line = (try? JSONEncoder().encode(msg)).map { String(data: $0, encoding: .utf8)! + "\n" }
        guard let line else { return nil }
        withLock(lockPath.path) {
            try? FileManager.default.createDirectory(at: inboxDir, withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: path) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: path)
            }
        }
        touchHeartbeat(effectiveSender)
        return msg.id
    }

    // MARK: Read / ack

    func unread(for agent: String, limit: Int = 5) -> [BusMessage] {
        let cursor = readCursor(agent)
        let path = inboxDir.appendingPathComponent("\(agent).jsonl")
        let lockPath = lockDir.appendingPathComponent("\(agent).lock")
        var msgs: [BusMessage] = []
        withLock(lockPath.path) {
            guard let data = try? Data(contentsOf: path) else { return }
            for line in data.split(separator: 0x0A) {
                guard let m = try? JSONDecoder().decode(BusMessage.self, from: Data(line)) else { continue }
                if m.id > cursor { msgs.append(m) }
            }
        }
        msgs.sort { $0.ts < $1.ts }
        return Array(msgs.prefix(limit))
    }

    func advanceCursor(for agent: String, ids: [String]) {
        guard !ids.isEmpty else { return }
        let cursor = readCursor(agent)
        let next = ids.reduce(cursor) { max($0, $1) }
        let payload = #"{"agent":"\#(agent)","watermark":"\#(next)"}"# + "\n"
        try? FileManager.default.createDirectory(at: cursorDir, withIntermediateDirectories: true)
        let url = cursorDir.appendingPathComponent("\(agent).json")
        atomicWrite(payload, to: url)
    }

    // MARK: Registry

    private func registerAgent(name: String, kind: String, paneId: String? = nil,
                               heartbeat: Date = Date(), cwd: String? = nil) {
        var registry = loadRegistry()
        var agents = registry["agents"] as? [String: [String: Any]] ?? [:]
        var entry = agents[name] ?? [:]
        entry["kind"] = kind
        if let paneId { entry["paneId"] = paneId }
        entry["cwd"] = cwd ?? entry["cwd"] ?? FileManager.default.currentDirectoryPath
        entry["heartbeat"] = Self.iso(heartbeat)
        agents[name] = entry
        registry["agents"] = agents
        atomicWrite(Self.jsonString(registry), to: registryURL)
    }

    private func touchHeartbeat(_ name: String) {
        registerAgent(name: name, kind: "openowl")
    }

    private func loadAgents() -> [BusAgentInfo] {
        let registry = loadRegistry()
        let agents = registry["agents"] as? [String: [String: Any]] ?? [:]
        let now = Date()
        return agents.map { name, info in
            let hb = info["heartbeat"] as? String
            let age = hb.flatMap(Self.isoDate).map { now.timeIntervalSince($0) }
            let online = age.map { $0 < Self.onlineWindow } ?? false
            return BusAgentInfo(
                name: name,
                kind: info["kind"] as? String ?? "?",
                cwd: info["cwd"] as? String,
                paneId: info["paneId"] as? String,
                heartbeat: hb,
                isOnline: online
            )
        }
    }

    // MARK: File plumbing

    private func ensureDirectories() {
        for url in [busDir, inboxDir, cursorDir, lockDir] {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        if !FileManager.default.fileExists(atPath: registryURL.path) {
            atomicWrite(#"{"agents":{}}"# + "\n", to: registryURL)
        }
    }

    private func loadRegistry() -> [String: Any] {
        guard let data = try? Data(contentsOf: registryURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ["agents": [String: Any]()]
        }
        return obj
    }

    private func readCursor(_ agent: String) -> String {
        let url = cursorDir.appendingPathComponent("\(agent).json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ""
        }
        return obj["watermark"] as? String ?? ""
    }

    private func atomicWrite(_ content: String, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        // .atomic writes to a temp file and renames — the reliable form of
        // atomic replace (replaceItemAt fails when the target doesn't exist
        // yet, which broke first-time cursor creation).
        try? Data(content.utf8).write(to: url, options: .atomic)
    }

    private func withLock<T>(_ lockPath: String, _ body: () -> T) -> T {
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return body() }
        defer { close(fd) }
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN) }
        return body()
    }

    // MARK: ids / timestamps (must match buslib.py)

    private static func newID() -> String {
        let micros = nowISO() // yyyyMMddHHmmssffffff
        let pid = String(format: "%04x", ProcessInfo.processInfo.processIdentifier & 0xFFFF)
        idSeqLock.lock()
        defer { idSeqLock.unlock() }
        idSeq &+= 1
        let seq = String(format: "%04x", idSeq)
        return "\(micros)\(pid)\(seq)"
    }

    private static func nowISO() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmssSSSSSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: Date())
    }

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func isoDate(_ s: String) -> Date? {
        ISO8601DateFormatter().date(from: s)
    }

    private static func jsonString(_ obj: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private static func jsonString(_ obj: [String: String]) -> String {
        (try? JSONEncoder().encode(obj))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}
