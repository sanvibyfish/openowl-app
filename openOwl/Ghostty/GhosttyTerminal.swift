import AppKit
import QuartzCore

/// Core terminal NSView backed by CAMetalLayer + ghostty_surface_t.
/// Keyboard, mouse, resize, focus — mirrors Ghostty SurfaceView_AppKit.swift.
///
/// Known workaround:
/// - Composing keyAction skipped: key encoder leaks first character during composition.
class TerminalNSView: NSView {
    private var surface: ghostty_surface_t?
    private let ghosttyApp: ghostty_app_t
    private let paneID: UUID
    private var metalLayer: CAMetalLayer!
    private var trackingArea: NSTrackingArea?
    private var markedText = NSMutableAttributedString()
    private var keyTextAccumulator: [String]?
    private var lastSyncedBackingSize: CGSize?
    private var lastSyncedScale: CGFloat = 0
    private var resizeDebounceWork: DispatchWorkItem?
    /// Whether the host (TerminalScrollView) considers this surface visible.
    /// Used by viewDidMoveToWindow to avoid briefly un-hiding a paused surface.
    private var hostVisible = true

    weak var appManager: GhosttyAppManager?
    var onFocus: (() -> Void)?
    /// Working directory for the shell. Set before the view is added to a window.
    /// Passed directly to ghostty_surface_config — avoids changing the app's process cwd
    /// which triggers macOS TCC prompts in dev builds.
    var initialWorkingDirectory: String?
    var paneIdentifier: UUID { paneID }
    /// Whether Metal is currently rendering (layer not hidden).
    var isRenderingActive: Bool { !(metalLayer?.isHidden ?? true) }
    var acceptsTerminalKeyboardInput: Bool {
        guard let surface else { return false }
        return appManager?.activeSurface == surface && isEffectivelyVisible
    }

    init(ghosttyApp: ghostty_app_t, paneID: UUID) {
        self.ghosttyApp = ghosttyApp
        self.paneID = paneID
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Layer Setup

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.device = MTLCreateSystemDefaultDevice()
        layer.isOpaque = true
        layer.contentsScale = window?.backingScaleFactor ?? 2.0
        layer.isHidden = !hostVisible
        metalLayer = layer
        return layer
    }

    override var wantsUpdateLayer: Bool { true }

    // MARK: - Surface Lifecycle

    /// Toggle Metal rendering based on surface visibility.
    /// Called by TerminalScrollView when SwiftUI signals visibility changes.
    /// When hidden, metalLayer.isHidden prevents WindowServer from compositing
    /// this surface, which is the primary fix for WindowServer CPU exhaustion
    /// with many terminal surfaces.
    func setSurfaceVisibility(_ visible: Bool) {
        guard hostVisible != visible else { return }
        hostVisible = visible
        metalLayer?.isHidden = !visible
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else {
            // View removed from window — pause Metal rendering to prevent
            // GPU/WindowServer stress from orphaned surfaces.
            metalLayer?.isHidden = true
            return
        }
        // View (re)attached to a window — only resume rendering if the host
        // considers this surface visible. Without this guard, a brief
        // metalLayer.isHidden=false would occur before updateNSView applies
        // the correct visibility, causing an unnecessary GPU render.
        metalLayer?.isHidden = !hostVisible

        // Reattached to a window with an existing surface (SwiftUI recreated the wrapper).
        // Restore scale/size/focus — the surface and shell process are still alive.
        if let surface {
            lastSyncedScale = window.backingScaleFactor
            metalLayer.contentsScale = window.backingScaleFactor
            ghostty_surface_set_content_scale(surface, Double(window.backingScaleFactor), Double(window.backingScaleFactor))
            let fbSize = convertToBacking(bounds.size)
            if fbSize.width > 0 && fbSize.height > 0 {
                syncSurfaceSize(reason: "reattach", force: true)
            }
            setupTrackingArea()
            // Only restore focus if the host considers this surface visible.
            // Hidden panes (background tab, maximized sibling) must not grab
            // focus or trigger ghostty rendering.
            if hostVisible {
                ghostty_surface_set_focus(surface, true)
                appManager?.activeSurface = surface
                window.makeFirstResponder(self)
            }
            needsDisplay = true
            return
        }

        // First time — create a new surface.

        lastSyncedScale = window.backingScaleFactor
        metalLayer.contentsScale = window.backingScaleFactor

        var surfaceConfig = ghostty_surface_config_new()
        surfaceConfig.platform_tag = GHOSTTY_PLATFORM_MACOS
        surfaceConfig.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(self).toOpaque()
        ))
        surfaceConfig.userdata = Unmanaged.passUnretained(self).toOpaque()
        surfaceConfig.scale_factor = Double(window.backingScaleFactor)
        surfaceConfig.font_size = 0

        // Set working directory — prefer explicit path, fall back to process cwd
        let cwd: String
        if let dir = initialWorkingDirectory {
            cwd = dir
        } else {
            cwd = FileManager.default.currentDirectoryPath
            NSLog("openOwl: [Terminal] initialWorkingDirectory nil for pane %@, falling back to: %@",
                  paneID.uuidString, cwd)
        }
        var cwdPtr = strdup(cwd)
        surfaceConfig.working_directory = UnsafePointer(cwdPtr)

        // Inject environment variables for shell integration
        let resourcesPath = Bundle.main.resourceURL?
            .appendingPathComponent("ghostty-resources/terminfo").path
        var envVars: [ghostty_env_var_s] = []
        var envStorage: [UnsafeMutablePointer<CChar>] = []

        // TERMINFO_DIRS: so the shell can find xterm-ghostty terminfo
        if let terminfoPath = resourcesPath {
            let keyPtr = strdup("TERMINFO_DIRS")!
            let valPtr = strdup(terminfoPath)!
            envStorage.append(contentsOf: [keyPtr, valPtr])
            envVars.append(ghostty_env_var_s(key: keyPtr, value: valPtr))
        }

        // GHOSTTY_SHELL_FEATURES: enables shell integration SSH wrapper
        // that sets TERM=xterm-256color for remote connections (prevents
        // garbled output on servers without xterm-ghostty terminfo)
        do {
            let keyPtr = strdup("GHOSTTY_SHELL_FEATURES")!
            let valPtr = strdup("cursor,sudo,title,ssh-env,ssh-terminfo")!
            envStorage.append(contentsOf: [keyPtr, valPtr])
            envVars.append(ghostty_env_var_s(key: keyPtr, value: valPtr))
        }

        if !envVars.isEmpty {
            envVars.withUnsafeMutableBufferPointer { buf in
                surfaceConfig.env_vars = buf.baseAddress
                surfaceConfig.env_var_count = buf.count
                self.surface = ghostty_surface_new(self.ghosttyApp, &surfaceConfig)
            }
        } else {
            surface = ghostty_surface_new(ghosttyApp, &surfaceConfig)
        }
        for ptr in envStorage { free(ptr) }
        free(cwdPtr); cwdPtr = nil

        guard surface != nil else {
            NSLog("openOwl: Failed to create ghostty surface")
            return
        }

        let fbSize = convertToBacking(bounds.size)
        if fbSize.width > 0 && fbSize.height > 0 {
            syncSurfaceSize(reason: "create", force: true)
        }
        ghostty_surface_set_content_scale(surface, Double(window.backingScaleFactor), Double(window.backingScaleFactor))

        if let surface {
            appManager?.register(surface: surface, for: paneID, view: self)
        }

        setupTrackingArea()
        window.makeFirstResponder(self)
    }

    override func removeFromSuperview() {
        // Don't free the surface here — SwiftUI's ForEach may dismantle and
        // recreate NSViewRepresentable wrappers during @Observable re-evaluation.
        // The surface stays alive so makeNSView can reuse this view later.
        // Explicit cleanup happens via destroySurface() when a pane is actually closed.
        super.removeFromSuperview()
    }

    /// Explicitly free the ghostty surface. Called only when the pane is
    /// permanently closed (not when SwiftUI temporarily removes the view).
    func destroySurface() {
        guard let surface else { return }
        appManager?.unregisterPane(paneID)
        ghostty_surface_free(surface)
        self.surface = nil
    }

    // MARK: - Public API

    func sendText(_ text: String) {
        guard let surface else { return }
        text.withCString { cstr in
            ghostty_surface_text(surface, cstr, UInt(text.utf8.count))
        }
    }

    /// Execute a ghostty keybinding action (e.g. "scroll_to_row:42")
    @discardableResult
    func performBindingAction(_ action: String) -> Bool {
        guard let surface else { return false }
        return ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
    }

    // MARK: - Edit Menu Actions

    @objc func copy(_ sender: Any?) {
        guard let surface else { return }
        let action = "copy_to_clipboard"
        if !ghostty_surface_binding_action(surface, action, UInt(action.utf8.count)) {
            NSLog("openOwl: binding action failed action=%@", action)
        }
    }

    @objc func paste(_ sender: Any?) {
        pasteFromClipboard()
    }

    @objc func pasteAsPlainText(_ sender: Any?) {
        pasteFromClipboard()
    }

    private func pasteFromClipboard() {
        guard let surface else { return }
        let pb = NSPasteboard.general
        let value: String
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            value = urls
                .map { $0.isFileURL ? Self.shellEscapedPath($0.path) : $0.absoluteString }
                .joined(separator: " ")
        } else {
            value = pb.string(forType: .string) ?? ""
        }
        guard !value.isEmpty else { return }
        value.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(value.utf8.count))
        }
    }

    @objc override func selectAll(_ sender: Any?) {
        guard let surface else { return }
        let action = "select_all"
        if !ghostty_surface_binding_action(surface, action, UInt(action.utf8.count)) {
            NSLog("openOwl: binding action failed action=%@", action)
        }
    }

    // MARK: - First Responder

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        if let surface {
            ghostty_surface_set_focus(surface, true)
            appManager?.activeSurface = surface
            onFocus?()
        }
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        if let surface {
            ghostty_surface_set_focus(surface, false)
        }
        return super.resignFirstResponder()
    }

    // MARK: - Resize

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncSurfaceSize(reason: "setFrameSize")
    }

    /// Synchronize the libghostty surface/PTY size with the current AppKit bounds.
    ///
    /// AppKit resize callbacks are not reliable enough on their own when SwiftUI
    /// temporarily hides panes by driving their host view to zero width (right-dock
    /// fullscreen, inactive tabs, maximized siblings). Hidden panes should keep
    /// their last usable PTY size; when they become visible again, callers force a
    /// resync against the settled bounds.
    func syncSurfaceSize(reason: String, force: Bool = false) {
        if force {
            resizeDebounceWork?.cancel()
            resizeDebounceWork = nil
            commitSurfaceSize(reason: reason)
        } else {
            resizeDebounceWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.commitSurfaceSize(reason: reason)
            }
            resizeDebounceWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.032, execute: work)
        }
    }

    private func commitSurfaceSize(reason: String) {
        guard let surface else { return }
        let paneTag = paneID.uuidString.prefix(8) as CVarArg
        func logSkip(_ detail: String) {
            AppLogger.log("resize-diag", "syncSurfaceSize skipped pane=%@ reason=%@ %@", paneTag, reason, detail)
        }

        guard hostVisible else { logSkip("hostVisible=false pts=\(bounds.size.width)x\(bounds.size.height)"); return }

        let pointSize = bounds.size
        guard pointSize.width > 1, pointSize.height > 1 else {
            logSkip("tiny pts=\(pointSize.width)x\(pointSize.height)"); return
        }

        let fbSize = convertToBacking(pointSize)
        guard fbSize.width > 1, fbSize.height > 1 else {
            logSkip("tiny px=\(Int(fbSize.width))x\(Int(fbSize.height))"); return
        }

        let backingSize = CGSize(width: floor(fbSize.width), height: floor(fbSize.height))
        guard backingSize != lastSyncedBackingSize else { return }

        ghostty_surface_set_size(surface, UInt32(backingSize.width), UInt32(backingSize.height))
        lastSyncedBackingSize = backingSize
        let after = ghostty_surface_size(surface)
        AppLogger.log("resize-diag", "syncSurfaceSize pane=%@ reason=%@ pts=%.1fx%.1f px=%.0fx%.0f cols=%d rows=%d window=%@",
                      paneID.uuidString.prefix(8) as CVarArg,
                      reason,
                      pointSize.width, pointSize.height,
                      backingSize.width, backingSize.height,
                      Int(after.columns), Int(after.rows),
                      window == nil ? "nil" : "set")
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let window, let surface else { return }
        let newScale = window.backingScaleFactor
        guard newScale != lastSyncedScale else { return }
        lastSyncedScale = newScale
        metalLayer?.contentsScale = newScale
        ghostty_surface_set_content_scale(
            surface,
            Double(newScale),
            Double(newScale)
        )
        syncSurfaceSize(reason: "backing-change", force: true)
    }

    // MARK: - Keyboard Input

    override func keyDown(with event: NSEvent) {
        guard acceptsTerminalKeyboardInput else { return }
        guard let surface else {
            interpretKeyEvents([event])
            return
        }

        let translationEvent = translatedKeyEvent(for: event, surface: surface)
        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        let markedTextBefore = markedText.length > 0
        interpretKeyEvents([translationEvent])
        syncPreedit(clearIfNeeded: markedTextBefore)

        let acc = keyTextAccumulator ?? []
        if !acc.isEmpty {
            for text in acc {
                _ = keyAction(action, event: event, translationEvent: translationEvent, text: text)
            }
        } else if markedText.length > 0 || markedTextBefore {
            // Composing — skip keyAction. See class doc for workaround details.
        } else {
            _ = keyAction(
                action,
                event: event,
                translationEvent: translationEvent,
                text: GhosttyInput.ghosttyCharacters(from: translationEvent)
            )
        }
    }

    override func keyUp(with event: NSEvent) {
        _ = keyAction(GHOSTTY_ACTION_RELEASE, event: event)
    }

    override func flagsChanged(with event: NSEvent) {
        guard surface != nil else {
            super.flagsChanged(with: event)
            return
        }

        if hasMarkedText() { return }

        let mod: UInt32
        switch event.keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }

        let mods = GhosttyInput.ghosttyMods(event.modifierFlags)
        var action = GHOSTTY_ACTION_RELEASE
        if mods.rawValue & mod != 0 {
            let sidePressed: Bool
            switch event.keyCode {
            case 0x3C:
                sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERSHIFTKEYMASK) != 0
            case 0x3E:
                sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCTLKEYMASK) != 0
            case 0x3D:
                sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERALTKEYMASK) != 0
            case 0x36:
                sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCMDKEYMASK) != 0
            default:
                sidePressed = true
            }
            if sidePressed {
                action = GHOSTTY_ACTION_PRESS
            }
        }

        _ = keyAction(action, event: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, let surface else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // performKeyEquivalent traverses ALL NSViews in the window.
        // Only the first responder should claim terminal shortcuts —
        // this prevents stealing Cmd+V/C from TextFields.
        guard window?.firstResponder === self else { return false }

        // Intercept Escape — NavigationSplitView consumes ESC before keyDown
        // reaches this view. Use the stricter acceptsTerminalKeyboardInput
        // guard because ESC directly invokes keyDown, which must only run on
        // the active, visible pane.
        if event.keyCode == 53, flags.isEmpty || flags == .shift {
            guard acceptsTerminalKeyboardInput else { return false }
            keyDown(with: event)
            return true
        }

        // Intercept Cmd+V (paste) — direct text injection via ghostty_surface_text.
        // ghostty_surface_binding_action("paste_from_clipboard") requires an async
        // callback chain through read_clipboard_cb that depends on activeSurface
        // being set correctly; direct injection is more reliable.
        if flags == .command, event.charactersIgnoringModifiers == "v" {
            pasteFromClipboard()
            return true
        }

        // Intercept Cmd+C (copy)
        if flags == .command, event.charactersIgnoringModifiers == "c" {
            let action = "copy_to_clipboard"
            if !ghostty_surface_binding_action(surface, action, UInt(action.utf8.count)) {
                NSLog("openOwl: Cmd+C copy action failed on surface")
            }
            return true
        }

        // Cmd+F: Terminal search
        if flags == .command, event.charactersIgnoringModifiers == "f" {
            NotificationCenter.default.post(
                name: .terminalSearch,
                object: nil,
                userInfo: ["paneID": paneID]
            )
            return true
        }

        // Let app-level shortcuts bypass the terminal so keyDown doesn't consume them.
        // Cmd+P: Quick Open
        if flags == .command, event.charactersIgnoringModifiers == "p" {
            NotificationCenter.default.post(name: .quickOpen, object: nil)
            return true
        }

        return false
    }

    @discardableResult
    func handleMonitoredKeyDown(_ event: NSEvent) -> Bool {
        guard acceptsTerminalKeyboardInput else { return false }
        keyDown(with: event)
        return true
    }

    override func insertText(_ insertString: Any) {
        insertText(insertString, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    override func doCommand(by selector: Selector) {
        // Intentionally empty — prevents NSBeep for unhandled key commands.
    }

    // MARK: - Mouse Input

    override func mouseDown(with event: NSEvent) {
        guard let surface else { return }
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let mods = GhosttyInput.modifierFlags(from: event)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, mods)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods)
    }

    override func mouseUp(with event: NSEvent) {
        guard let surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        let mods = GhosttyInput.modifierFlags(from: event)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, mods)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let surface else { return }
        let mods = GhosttyInput.modifierFlags(from: event)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, mods)
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface else { return }
        let mods = GhosttyInput.modifierFlags(from: event)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, mods)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        let mods = GhosttyInput.modifierFlags(from: event)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, mods)
    }

    override func mouseMoved(with event: NSEvent) {
        guard let surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        let mods = GhosttyInput.modifierFlags(from: event)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, mods)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var scrollMods: Int32 = 0
        if event.hasPreciseScrollingDeltas {
            scrollMods |= 1
        }
        if event.momentumPhase != [] {
            if event.momentumPhase == .began {
                scrollMods |= (1 << 1)
            } else if event.momentumPhase == .changed {
                scrollMods |= (2 << 1)
            } else if event.momentumPhase == .ended {
                scrollMods |= (3 << 1)
            }
        }
        ghostty_surface_mouse_scroll(surface, event.scrollingDeltaX, event.scrollingDeltaY, scrollMods)
    }

    // MARK: - Drag & Drop

    private static let acceptedDropTypes: Set<NSPasteboard.PasteboardType> = [.fileURL, .URL, .string]

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        NSLog("openOwl: [TerminalNSView] draggingEntered types=%@", sender.draggingPasteboard.types?.map(\.rawValue) ?? [])
        guard let types = sender.draggingPasteboard.types,
              !Set(types).isDisjoint(with: Self.acceptedDropTypes) else { return [] }
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let types = sender.draggingPasteboard.types,
              !Set(types).isDisjoint(with: Self.acceptedDropTypes) else { return [] }
        return .copy
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let types = sender.draggingPasteboard.types else { return false }
        return !Set(types).isDisjoint(with: Self.acceptedDropTypes)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        guard let surface else {
            NSLog("openOwl: [Terminal] performDragOperation rejected — no surface (pane not yet initialized)")
            return false
        }

        let content: String?
        // Check file URLs FIRST: Finder puts both .fileURL (multi) and .URL (single, first only)
        // on the pasteboard when dragging multiple files. Reading .URL first would discard
        // all but the first file.
        if let fileURLs = pb.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL], !fileURLs.isEmpty {
            content = fileURLs
                .map { $0.standardizedFileURL.path }
                .uniquedPreservingOrder()
                .map(Self.shellEscapedPath)
                .joined(separator: " ")
        } else if let url = pb.string(forType: .URL) {
            // Non-file URL (e.g. http://) — escape as-is
            content = Self.shellEscapedPath(url)
        } else if let str = pb.string(forType: .string) {
            // Plain text — not escaped (user may be pasting a command)
            content = str
        } else {
            content = nil
        }

        guard let content, !content.isEmpty else {
            NSLog(
                "openOwl: [Terminal] performDragOperation rejected — no usable pasteboard content (types=%@)",
                pb.types?.map(\.rawValue) ?? []
            )
            return false
        }
        window?.makeFirstResponder(self)
        let payload = content + " "
        payload.withCString { cstr in
            ghostty_surface_text(surface, cstr, UInt(payload.utf8.count))
        }
        return true
    }

    // MARK: - Private Helpers

    /// Checks if this view is actually visible by walking the superview chain.
    /// SwiftUI's .opacity(0) sets alphaValue on an ancestor wrapper view.
    private var isEffectivelyVisible: Bool {
        var view: NSView? = self
        while let v = view {
            if v.isHidden || v.alphaValue < 0.01 { return false }
            view = v.superview
        }
        return true
    }

    private func setupTrackingArea() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea!)
    }

    /// Escape shell-sensitive characters with backslashes (matches Ghostty's Shell.escape).
    static let shellEscapeCharacters = "\\ ()[]{}<>\"'`!#$&;|*?\t"

    static func shellEscapedPath(_ path: String) -> String {
        var result = path
        for char in shellEscapeCharacters {
            result = result.replacingOccurrences(
                of: String(char),
                with: "\\\(char)"
            )
        }
        return result
    }

    private func keyAction(
        _ action: ghostty_input_action_e,
        event: NSEvent,
        translationEvent: NSEvent? = nil,
        text: String? = nil,
        composing: Bool = false
    ) -> Bool {
        guard let surface else { return false }

        var key = GhosttyInput.keyEvent(
            from: event,
            action: action,
            translationMods: translationEvent?.modifierFlags
        )
        key.composing = composing

        if let text, !text.isEmpty,
           let codepoint = text.utf8.first, codepoint >= 0x20 {
            return text.withCString { ptr in
                key.text = ptr
                return ghostty_surface_key(surface, key)
            }
        } else {
            return ghostty_surface_key(surface, key)
        }
    }

    private func translatedKeyEvent(for event: NSEvent, surface: ghostty_surface_t) -> NSEvent {
        let translationModsGhostty = GhosttyInput.eventModifierFlags(
            mods: ghostty_surface_key_translation_mods(
                surface,
                GhosttyInput.ghosttyMods(event.modifierFlags)
            )
        )
        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if translationModsGhostty.contains(flag) {
                translationMods.insert(flag)
            } else {
                translationMods.remove(flag)
            }
        }
        if translationMods == event.modifierFlags {
            return event
        }
        return NSEvent.keyEvent(
            with: event.type,
            location: event.locationInWindow,
            modifierFlags: translationMods,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: event.characters(byApplyingModifiers: translationMods) ?? "",
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
            isARepeat: event.isARepeat,
            keyCode: event.keyCode
        ) ?? event
    }

    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }
        if markedText.length > 0 {
            let str = markedText.string
            let len = str.utf8CString.count
            if len > 0 {
                str.withCString { ptr in
                    ghostty_surface_preedit(surface, ptr, UInt(len - 1))
                }
            }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }
}

// MARK: - NSTextInputClient

extension TerminalNSView: NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        guard let surface else { return }
        let str: String
        switch string {
        case let attributed as NSAttributedString:
            str = attributed.string
        case let value as String:
            str = value
        default:
            return
        }

        unmarkText()

        if var accumulator = keyTextAccumulator {
            accumulator.append(str)
            keyTextAccumulator = accumulator
            return
        }

        // Direct text input outside keyDown flow (e.g. async IME commit)
        str.withCString { cstr in
            ghostty_surface_text(surface, cstr, UInt(str.utf8.count))
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let attributed as NSAttributedString:
            markedText = NSMutableAttributedString(attributedString: attributed)
        case let value as String:
            markedText = NSMutableAttributedString(string: value)
        default:
            return
        }

        if keyTextAccumulator == nil {
            syncPreedit()
        }
    }

    func unmarkText() {
        if markedText.length > 0 {
            markedText.mutableString.setString("")
            syncPreedit()
        }
    }

    func hasMarkedText() -> Bool { markedText.length > 0 }

    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

    func markedRange() -> NSRange {
        guard markedText.length > 0 else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: 0, length: markedText.length)
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface, let window else { return .zero }
        var x: Double = 0, y: Double = 0, w: Double = 0, h: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        let viewRect = NSRect(x: x, y: frame.size.height - y, width: w, height: h)
        let winRect = convert(viewRect, to: nil)
        return window.convertToScreen(winRect)
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }
}

private extension Array where Element == String {
    func uniquedPreservingOrder() -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        output.reserveCapacity(count)
        for value in self where seen.insert(value).inserted {
            output.append(value)
        }
        return output
    }
}
