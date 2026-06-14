import AppKit
import Darwin
import Observation

/// Manages the ghostty_app_t lifecycle and provides runtime callbacks.
/// Injected via .environment() throughout the SwiftUI view hierarchy.
@Observable
final class GhosttyAppManager {
    private(set) var isReady = false
    private(set) var error: String?

    private(set) var app: ghostty_app_t?
    @ObservationIgnored private var config: GhosttyConfig?
    // Internal bookkeeping — @ObservationIgnored prevents SwiftUI cascade:
    // without this, any surface register/unregister triggers view re-evaluation,
    // which recreates NSViewRepresentable wrappers, which creates MORE surfaces.
    @ObservationIgnored private var paneSurfaceMap: [UUID: ghostty_surface_t] = [:]
    @ObservationIgnored private var paneViewMap: [UUID: WeakTerminalView] = [:]
    @ObservationIgnored private var retainedTerminalViews: [UUID: TerminalNSView] = [:]
    @ObservationIgnored private var retainedScrollViews: [UUID: TerminalScrollView] = [:]

    private(set) var launchProfile = GhosttyLaunchProfile(
        configCommand: nil,
        fallbackShell: "/bin/zsh"
    )
    var onPaneTitleChanged: ((UUID, String) -> Void)?
    var onPanePwdChanged: ((UUID, String) -> Void)?
    var onPaneBell: ((UUID) -> Void)?
    /// Called when ghostty wants to open a URL/path (cmd+click on a hyperlink
    /// or detected path). Return `true` if the host handled it (suppresses
    /// ghostty's default `NSWorkspace.open`); return `false` to let ghostty's
    /// system handler run.
    var onOpenUrl: ((String) -> Bool)?
    var onSearchEnd: ((UUID) -> Void)?
    var onSearchTotal: ((UUID, UInt?) -> Void)?
    var onSearchSelected: ((UUID, UInt?) -> Void)?

    /// Stores a reference to the active surface so clipboard callbacks can reach it.
    /// Updated when a TerminalNSView creates its surface.
    var activeSurface: ghostty_surface_t?

    /// Coalesces wakeup_cb → tick() dispatches. libghostty may fire wakeup hundreds of
    /// times per second during heavy TUI output; without coalescing, each one enqueues
    /// a separate main-queue block, saturating the main thread and delaying UI input.
    /// Guarded by `tickLock`; accessed from both the wakeup thread and the main thread.
    @ObservationIgnored private var tickScheduled = false
    @ObservationIgnored private var tickLock = os_unfair_lock_s()


    init() {
        initializeGhostty()
    }

    deinit {
        if let app {
            ghostty_app_free(app)
        }
    }

    private func initializeGhostty() {
        // Initialize the ghostty library
        var args: [UnsafeMutablePointer<CChar>?] = []
        let appName = strdup("openOwl")
        args.append(appName)

        let result = ghostty_init(1, &args)
        appName?.deallocate()

        guard result == GHOSTTY_SUCCESS else {
            error = "ghostty_init failed with code \(result)"
            return
        }

        // Create config
        config = GhosttyConfig()
        guard config?.config != nil else {
            error = "Failed to create ghostty config"
            return
        }
        launchProfile = GhosttyLaunchProfile(
            configCommand: config?.snapshot.command,
            fallbackShell: Self.detectFallbackShell()
        )
        NSLog(
            "openOwl: launch profile config-command=%@ fallback-shell=%@",
            launchProfile.configCommand ?? "<nil>",
            launchProfile.fallbackShell
        )

        // Setup runtime callbacks
        var runtime = ghostty_runtime_config_s()
        runtime.userdata = Unmanaged.passUnretained(self).toOpaque()
        runtime.supports_selection_clipboard = true

        runtime.wakeup_cb = { userdata in
            guard let userdata else { return }
            let manager = Unmanaged<GhosttyAppManager>.fromOpaque(userdata).takeUnretainedValue()
            manager.scheduleTick()
        }

        runtime.action_cb = { app, target, action in
            guard let app else { return false }
            guard let userdata = ghostty_app_userdata(app) else { return false }
            let manager = Unmanaged<GhosttyAppManager>.fromOpaque(userdata).takeUnretainedValue()
            return manager.handleAction(target: target, action: action)
        }

        runtime.read_clipboard_cb = { userdata, clipboard, state in
            guard let userdata else { return false }
            let manager = Unmanaged<GhosttyAppManager>.fromOpaque(userdata).takeUnretainedValue()
            // Capture the triggering surface synchronously. `state` is bound to
            // this specific surface — passing it to a different surface (or to
            // a freed one) is a use-after-free. We MUST complete on the same
            // surface that triggered the request, not whichever happens to be
            // active when the async block runs.
            guard let triggeringSurface = manager.activeSurface else { return false }

            // Must defer completion to avoid reentrancy crash:
            // ghostty_surface_key → paste binding → read_clipboard_cb →
            // ghostty_surface_complete_clipboard_request would crash if synchronous.
            DispatchQueue.main.async {
                guard manager.isSurfaceAlive(triggeringSurface) else { return }
                let value = GhosttyAppManager.readPasteboardContent()
                value.withCString { ptr in
                    ghostty_surface_complete_clipboard_request(triggeringSurface, ptr, state, false)
                }
            }
            return true
        }

        runtime.confirm_read_clipboard_cb = { userdata, content, state, _ in
            guard let content, let userdata else { return }
            let manager = Unmanaged<GhosttyAppManager>.fromOpaque(userdata).takeUnretainedValue()
            // Same surface-bound `state` constraint as read_clipboard_cb above:
            // capture sync, verify alive async.
            guard let triggeringSurface = manager.activeSurface else { return }
            // Copy content before async dispatch — libghostty may free the buffer after callback returns.
            let contentStr = String(cString: content)
            DispatchQueue.main.async {
                guard manager.isSurfaceAlive(triggeringSurface) else { return }
                contentStr.withCString { ptr in
                    ghostty_surface_complete_clipboard_request(triggeringSurface, ptr, state, true)
                }
            }
        }

        runtime.write_clipboard_cb = { _, clipboard, content, count, _ in
            guard let content, count > 0 else { return }
            let buffer = UnsafeBufferPointer(start: content, count: Int(count))

            // Find text/plain content, or fall back to first available
            var fallback: String?
            for item in buffer {
                guard let dataPtr = item.data else { continue }
                let value = String(cString: dataPtr)

                if let mimePtr = item.mime {
                    let mime = String(cString: mimePtr)
                    if mime.hasPrefix("text/plain") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(value, forType: .string)
                        return
                    }
                }
                if fallback == nil { fallback = value }
            }

            if let fallback {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(fallback, forType: .string)
            }
        }

        runtime.close_surface_cb = { userdata, confirm in
            NSLog("ghostty: surface close requested")
        }

        // Create app
        app = ghostty_app_new(&runtime, config!.config)
        guard app != nil else {
            error = "Failed to create ghostty app"
            return
        }

        isReady = true
    }

    /// Called from wakeup_cb (any thread). Coalesces multiple wakeups into a single
    /// main-thread tick: if a tick is already scheduled, further wakeups are no-ops
    /// until it runs. Clearing the flag BEFORE running tick ensures we don't miss a
    /// wakeup that fires while tick is executing.
    func scheduleTick() {
        os_unfair_lock_lock(&tickLock)
        if tickScheduled {
            os_unfair_lock_unlock(&tickLock)
            return
        }
        tickScheduled = true
        os_unfair_lock_unlock(&tickLock)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            os_unfair_lock_lock(&self.tickLock)
            self.tickScheduled = false
            os_unfair_lock_unlock(&self.tickLock)
            self.tick()
        }
    }

    /// Process pending ghostty events on the main thread.
    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    // MARK: - Background tick timer

    private var backgroundTickTimer: Timer?

    /// Ensure ghostty events (bell, title changes) are processed even when the app
    /// is inactive. macOS may delay DispatchQueue.main.async for background apps,
    /// so we run a low-frequency timer to call tick() while backgrounded.
    func startBackgroundTick() {
        guard backgroundTickTimer == nil else { return }
        backgroundTickTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(backgroundTickTimer!, forMode: .common)
    }

    func stopBackgroundTick() {
        backgroundTickTimer?.invalidate()
        backgroundTickTimer = nil
    }

    var configSnapshot: GhosttyConfigSnapshot? {
        config?.snapshot
    }

    func register(surface: ghostty_surface_t, for paneID: UUID, view: TerminalNSView) {
        paneSurfaceMap[paneID] = surface
        paneViewMap[paneID] = WeakTerminalView(view)
        retainedTerminalViews[paneID] = view
        activeSurface = surface
    }

    func registerScrollView(_ scrollView: TerminalScrollView, for paneID: UUID) {
        retainedScrollViews[paneID] = scrollView
    }

    func unregisterPane(_ paneID: UUID) {
        if let surface = paneSurfaceMap.removeValue(forKey: paneID), activeSurface == surface {
            activeSurface = nil
        }
        paneViewMap.removeValue(forKey: paneID)
    }

    /// Explicitly destroy a pane's terminal surface and release the retained view.
    /// Called when a pane is actually closed (not just hidden by SwiftUI lifecycle).
    func destroyPane(_ paneID: UUID) {
        if let view = retainedTerminalViews.removeValue(forKey: paneID) {
            view.destroySurface()
        }
        retainedScrollViews.removeValue(forKey: paneID)
        unregisterPane(paneID)
    }

    func terminalView(for paneID: UUID) -> TerminalNSView? {
        paneViewMap[paneID]?.value
    }

    func scrollView(for paneID: UUID) -> TerminalScrollView? {
        retainedScrollViews[paneID]
    }

    func focusPane(_ paneID: UUID) -> Bool {
        guard let view = paneViewMap[paneID]?.value else {
            paneViewMap.removeValue(forKey: paneID)
            return false
        }
        guard let window = view.window else { return false }
        window.makeKeyAndOrderFront(nil)
        return window.makeFirstResponder(view)
    }

    func ensurePaneFocused(_ paneID: UUID) {
        guard let surface = paneSurfaceMap[paneID] else { return }
        if activeSurface != surface {
            activeSurface = surface
        }
        if let view = paneViewMap[paneID]?.value,
           view.window?.firstResponder !== view {
            _ = view.window?.makeFirstResponder(view)
        }
    }

    /// Surface stats for debug display: (total retained, currently rendering).
    var surfaceStats: (total: Int, active: Int) {
        let total = retainedTerminalViews.count
        let active = retainedTerminalViews.values.filter(\.isRenderingActive).count
        return (total, active)
    }

    /// Dump diagnostic info for debugging. Returns a string ready to paste.
    func diagnosticDump() -> String {
        var lines: [String] = []
        lines.append("=== openOwl Diagnostic ===")
        lines.append("Time: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("")

        // Metal surfaces
        let stats = surfaceStats
        lines.append("Metal Surfaces: \(stats.active) active / \(stats.total) total")
        for (paneID, view) in retainedTerminalViews {
            let state = view.isRenderingActive ? "ACTIVE" : "paused"
            let hasWindow = view.window != nil ? "in-window" : "detached"
            let hasSurface = paneSurfaceMap[paneID] != nil ? "surface-ok" : "no-surface"
            lines.append("  \(String(paneID.uuidString.prefix(8))) [\(state)] [\(hasWindow)] [\(hasSurface)]")
        }
        lines.append("")

        // Scroll views
        let scrollTotal = retainedScrollViews.count
        lines.append("Scroll Views: \(scrollTotal) retained")
        lines.append("")

        // Memory
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            lines.append("Memory: \(info.resident_size / 1_048_576) MB resident")
        } else {
            lines.append("Memory: unavailable (error \(result))")
        }
        lines.append("")
        lines.append("=== End Diagnostic ===")
        return lines.joined(separator: "\n")
    }

    func surface(for paneID: UUID) -> ghostty_surface_t? {
        paneSurfaceMap[paneID]
    }

    /// Returns whether libghostty believes quitting would terminate active work.
    func needsConfirmQuit() -> Bool {
        guard let app else { return false }
        return ghostty_app_needs_confirm_quit(app)
    }

    /// Whether the given surface is still registered (i.e. its pane hasn't been
    /// destroyed). Clipboard callbacks check this before calling
    /// `ghostty_surface_complete_clipboard_request` because the `state` pointer
    /// is surface-bound and becomes invalid once the surface is freed.
    func isSurfaceAlive(_ surface: ghostty_surface_t) -> Bool {
        paneSurfaceMap.values.contains(where: { $0 == surface })
    }

    private func handleAction(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        // All callbacks are called synchronously — tick() already runs on the main
        // thread (via Timer or wakeup_cb). Using DispatchQueue.main.async would cause
        // macOS to delay delivery for backgrounded apps, breaking notifications.
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE, GHOSTTY_ACTION_SET_TAB_TITLE:
            guard let title = titleFromAction(action) else { return false }
            guard let paneID = paneID(for: target) else { return false }
            onPaneTitleChanged?(paneID, title)
            return false

        case GHOSTTY_ACTION_PWD:
            guard let paneID = paneID(for: target) else { return false }
            guard let raw = action.action.pwd.pwd else { return true }
            let pwd = String(cString: raw)
            // file:// URI is allowed by OSC 7 — strip if present.
            let cleaned = pwd.hasPrefix("file://") ? String(pwd.dropFirst("file://".count)) : pwd
            onPanePwdChanged?(paneID, cleaned)
            return true

        case GHOSTTY_ACTION_OPEN_URL:
            guard let raw = action.action.open_url.url else { return false }
            let urlString = String(cString: raw)
            // If host claims it (file path → file explorer), tell ghostty
            // we handled it so it doesn't also fire NSWorkspace.open.
            return onOpenUrl?(urlString) ?? false

        case GHOSTTY_ACTION_SCROLLBAR:
            guard let paneID = paneID(for: target) else { return false }
            let v = action.action.scrollbar
            let state = TerminalScrollbarState(total: v.total, offset: v.offset, len: v.len)
            retainedScrollViews[paneID]?.updateScrollbar(state)
            return true

        case GHOSTTY_ACTION_CELL_SIZE:
            // Cell size is handled by ghostty internally. Previously used for
            // NSScrollView document height calculation, no longer needed.
            return true

        case GHOSTTY_ACTION_RING_BELL:
            guard let paneID = paneID(for: target) else { return false }
            onPaneBell?(paneID)
            return true

        case GHOSTTY_ACTION_START_SEARCH:
            // Return false — we handle Cmd+F ourselves via performKeyEquivalent.
            // Ghostty triggers this when its own keybinding fires; we don't need it.
            return false

        case GHOSTTY_ACTION_END_SEARCH:
            guard let paneID = paneID(for: target) else { return false }
            onSearchEnd?(paneID)
            return true

        case GHOSTTY_ACTION_SEARCH_TOTAL:
            guard let paneID = paneID(for: target) else { return false }
            let raw = action.action.search_total.total
            let total: UInt? = raw >= 0 ? UInt(raw) : nil
            onSearchTotal?(paneID, total)
            return true

        case GHOSTTY_ACTION_SEARCH_SELECTED:
            guard let paneID = paneID(for: target) else { return false }
            let raw = action.action.search_selected.selected
            let selected: UInt? = raw >= 0 ? UInt(raw) : nil
            onSearchSelected?(paneID, selected)
            return true

        default:
            return false
        }
    }

    private func titleFromAction(_ action: ghostty_action_s) -> String? {
        let rawTitle: UnsafePointer<CChar>?
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            rawTitle = action.action.set_title.title
        case GHOSTTY_ACTION_SET_TAB_TITLE:
            rawTitle = action.action.set_tab_title.title
        default:
            rawTitle = nil
        }

        guard let rawTitle else { return nil }
        let title = String(cString: rawTitle).trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    private func paneID(for target: ghostty_target_s) -> UUID? {
        switch target.tag {
        case GHOSTTY_TARGET_SURFACE:
            return paneID(for: target.target.surface)

        case GHOSTTY_TARGET_APP:
            return paneID(for: activeSurface)

        default:
            return nil
        }
    }

    private func paneID(for surface: ghostty_surface_t?) -> UUID? {
        guard let surface else { return nil }
        for (paneID, mappedSurface) in paneSurfaceMap where mappedSurface == surface {
            return paneID
        }
        return nil
    }
}

struct GhosttyLaunchProfile {
    let configCommand: String?
    let fallbackShell: String

    var shouldInjectFallbackShell: Bool {
        configCommand == nil
    }
}

private final class WeakTerminalView {
    weak var value: TerminalNSView?

    init(_ value: TerminalNSView?) {
        self.value = value
    }
}

private extension GhosttyAppManager {
    static let shellEscapeCharacters = "\\ ()[]{}<>\"'`!#$&;|*?\t"

    static func readPasteboardContent() -> String {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            return urls
                .map { url -> String in
                    guard url.isFileURL else { return url.absoluteString }
                    var result = url.path
                    for char in shellEscapeCharacters {
                        result = result.replacingOccurrences(of: String(char), with: "\\\(char)")
                    }
                    return result
                }
                .joined(separator: " ")
        }
        return pb.string(forType: .string) ?? ""
    }

    static func detectFallbackShell() -> String {
        if let envShell = ProcessInfo.processInfo.environment["SHELL"], isExecutableFile(envShell) {
            return envShell
        }

        if let loginShell = loginShellPath(), isExecutableFile(loginShell) {
            return loginShell
        }

        return "/bin/zsh"
    }

    static func loginShellPath() -> String? {
        guard let passwd = getpwuid(getuid()) else { return nil }
        guard let shell = passwd.pointee.pw_shell else { return nil }
        let path = String(cString: shell)
        return path.isEmpty ? nil : path
    }

    static func isExecutableFile(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }
}
