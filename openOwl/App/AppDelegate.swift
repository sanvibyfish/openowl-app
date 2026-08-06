import AppKit
import SwiftUI
import UserNotifications

/// Decides whether the app-level Escape/Ctrl-C fallback may bypass AppKit's
/// current responder. This is intentionally separate from pane lookup so the
/// responder-chain policy can be regression tested without a live terminal.
enum TerminalFallbackResponderPolicy {
    /// Ctrl-C / general terminal key fallback: don't steal from text fields,
    /// outlines (copy selection), tables, etc.
    static func allowsFallback(
        from responder: NSResponder?,
        in window: NSWindow?,
        terminalWindow: NSWindow?
    ) -> Bool {
        allowsFallback(
            from: responder,
            in: window,
            terminalWindow: terminalWindow,
            mode: .general
        )
    }

    /// Escape is special: users almost always mean "send ESC to the shell /
    /// cancel in the terminal". Only real text editing should keep it.
    /// File tree / table focus must NOT strand Escape (common intermittent bug).
    static func allowsEscapeFallback(
        from responder: NSResponder?,
        in window: NSWindow?,
        terminalWindow: NSWindow?
    ) -> Bool {
        allowsFallback(
            from: responder,
            in: window,
            terminalWindow: terminalWindow,
            mode: .escape
        )
    }

    private enum Mode { case general, escape }

    private static func allowsFallback(
        from responder: NSResponder?,
        in window: NSWindow?,
        terminalWindow: NSWindow?,
        mode: Mode
    ) -> Bool {
        guard let window,
              window === terminalWindow,
              !(window is NSPanel),
              window.sheetParent == nil,
              window.attachedSheet == nil else {
            return false
        }
        guard let responder else { return true }
        if let terminal = responder as? TerminalNSView {
            // An active terminal receives the original event through AppKit.
            // A stale/hidden terminal may fall back to the workspace's active pane.
            return !terminal.acceptsTerminalKeyboardInput
        }
        if responder === window { return true }

        guard let view = responder as? NSView else {
            // Menus and other non-view responders own their keyboard interaction.
            return false
        }
        if !isAttachedAndVisible(view, in: window) {
            // SwiftUI can leave the old control as first responder briefly after
            // a dock/tab transition. A detached or hidden control no longer owns
            // keyboard interaction and must not strand Escape.
            return true
        }
        switch mode {
        case .escape:
            return !isTextEditingInput(view)
        case .general:
            return !isInteractiveInput(view)
        }
    }

    private static func isAttachedAndVisible(_ view: NSView, in window: NSWindow) -> Bool {
        guard view.window === window else { return false }

        var candidate: NSView? = view
        while let current = candidate {
            if current.isHidden || current.alphaValue < 0.01 {
                return false
            }
            candidate = current.superview
        }
        return true
    }

    /// True text editing only — Escape should stay with these (rename, commit,
    /// Quick Open, terminal search field).
    private static func isTextEditingInput(_ view: NSView) -> Bool {
        var candidate: NSView? = view
        while let current = candidate {
            if current is NSTextView || current is NSTextField {
                return true
            }
            candidate = current.superview
        }
        return false
    }

    private static func isInteractiveInput(_ view: NSView) -> Bool {
        var candidate: NSView? = view
        while let current = candidate {
            // NSTextView covers the shared field editor used by NSTextField.
            // Outline/table/collection keep Ctrl-C for copy; Escape uses the
            // narrower isTextEditingInput check instead.
            if current is NSTextView
                || current is NSTextField
                || current is NSOutlineView
                || current is NSTableView
                || current is NSCollectionView {
                return true
            }
            candidate = current.superview
        }
        return false
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    weak var ghosttyManager: GhosttyAppManager?
    var workspaceStore: TerminalWorkspaceStore?
    weak var projectStore: ProjectStore?
    weak var rightDockStore: RightDockStore?
    weak var fileExplorerStore: FileExplorerStore?
    private var localKeyMonitor: Any?
    private let resourceMonitor = ResourceMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        UNUserNotificationCenter.current().delegate = self
        applyDevIcon()
        ensureEditMenu()
        installTerminalMenu()
        installViewMenu()
        installLocalKeyMonitor()
        #if DEBUG
        installDebugMenu()
        #endif
        requestNotificationPermission()
        startResourceMonitor()
    }

    /// Sampling is independent of notification permission — keep the two apart
    /// so the monitor does not wait on (or get skipped by) the auth callback.
    private func startResourceMonitor() {
        resourceMonitor.onSelfProcessAlert = { [weak self] _ in
            guard let self else { return }
            if let dump = self.ghosttyManager?.diagnosticDump() {
                AppLogger.log("resource-monitor", "openOwl self-alert dump:\n%@", dump)
            }
            if let workspace = self.workspaceStore {
                AppLogger.log(
                    "resource-monitor",
                    "workspace tabs=%d visible=%d namespace=%@",
                    workspace.tabs.count,
                    workspace.visibleTabs.count,
                    String(describing: workspace.activeNamespace)
                )
            }
        }
        resourceMonitor.start()
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error {
                AppLogger.log("notification", "authorization failed: %@", error.localizedDescription)
                return
            }
            guard granted else {
                // Resource alerts are delivered as user notifications, so a
                // denial silences the whole alerting path. Say so explicitly —
                // "no alerts" must not read as "nothing is wrong".
                AppLogger.log(
                    "notification",
                    "permission denied — resource alerts cannot be delivered"
                )
                return
            }
            AppLogger.log("notification", "permission granted")
        }
    }

    /// In Debug builds, override the Dock icon with the DEV-badged variant.
    /// The asset catalog compiler generates an incomplete icns for alternate icon sets,
    /// so we load the full-resolution image from Assets.car at runtime instead.
    private func applyDevIcon() {
        #if DEBUG
        if let devIcon = NSImage(named: "AppIconDev") {
            NSApp.applicationIconImage = devIcon
        }
        #endif
    }

    /// SwiftUI sometimes omits the Edit menu. Ensure Cut/Copy/Paste/Select All exist
    /// so that TextField and TextEditor support Cmd+C/V/X/A.
    private func ensureEditMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }

        // Check if Edit menu already exists
        if mainMenu.item(withTitle: "Edit") != nil { return }

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editMenuItem.submenu = editMenu

        // Insert after the app menu (index 1)
        let insertIndex = min(1, mainMenu.items.count)
        mainMenu.insertItem(editMenuItem, at: insertIndex)
    }

    // MARK: - Terminal Menu

    private func installTerminalMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }

        let menu = NSMenu(title: "Terminal")

        let newTab = NSMenuItem(title: "New Tab", action: #selector(menuNewTab), keyEquivalent: "t")
        menu.addItem(newTab)

        let closeTab = NSMenuItem(title: "Close Tab", action: #selector(menuCloseTab), keyEquivalent: "w")
        menu.addItem(closeTab)

        menu.addItem(.separator())

        let splitH = NSMenuItem(title: "Split Right", action: #selector(menuSplitHorizontal), keyEquivalent: "d")
        menu.addItem(splitH)

        let splitV = NSMenuItem(title: "Split Down", action: #selector(menuSplitVertical), keyEquivalent: "d")
        splitV.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(splitV)

        menu.addItem(.separator())

        let maximize = NSMenuItem(title: "Maximize Pane", action: #selector(menuToggleMaximize), keyEquivalent: "\r")
        maximize.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(maximize)

        let findItem = NSMenuItem(title: "Find...", action: #selector(menuTerminalSearch), keyEquivalent: "f")
        menu.addItem(findItem)

        menu.addItem(.separator())

        let focusLeft = NSMenuItem(title: "Focus Left", action: #selector(menuFocusLeft), keyEquivalent: "")
        focusLeft.keyEquivalent = String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
        focusLeft.keyEquivalentModifierMask = [.command]
        menu.addItem(focusLeft)

        let focusRight = NSMenuItem(title: "Focus Right", action: #selector(menuFocusRight), keyEquivalent: "")
        focusRight.keyEquivalent = String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
        focusRight.keyEquivalentModifierMask = [.command]
        menu.addItem(focusRight)

        let focusUp = NSMenuItem(title: "Focus Up", action: #selector(menuFocusUp), keyEquivalent: "")
        focusUp.keyEquivalent = String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
        focusUp.keyEquivalentModifierMask = [.command]
        menu.addItem(focusUp)

        let focusDown = NSMenuItem(title: "Focus Down", action: #selector(menuFocusDown), keyEquivalent: "")
        focusDown.keyEquivalent = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
        focusDown.keyEquivalentModifierMask = [.command]
        menu.addItem(focusDown)

        let menuItem = NSMenuItem(title: "Terminal", action: nil, keyEquivalent: "")
        menuItem.submenu = menu
        let insertIndex = min(mainMenu.items.count, 3) // After Edit
        mainMenu.insertItem(menuItem, at: insertIndex)
    }

    // MARK: - View Menu

    private func installViewMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }

        let menu = NSMenu(title: "View")

        let terminal = NSMenuItem(title: "Terminal", action: #selector(menuShowTerminal), keyEquivalent: "")
        menu.addItem(terminal)

        let git = NSMenuItem(title: "Git Changes", action: #selector(menuShowGit), keyEquivalent: "")
        menu.addItem(git)

        let files = NSMenuItem(title: "File Explorer", action: #selector(menuShowFiles), keyEquivalent: "")
        menu.addItem(files)

        menu.addItem(.separator())

        let quickOpen = NSMenuItem(title: "Quick Open", action: #selector(menuQuickOpen), keyEquivalent: "p")
        menu.addItem(quickOpen)

        let menuItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        menuItem.submenu = menu
        let insertIndex = min(mainMenu.items.count, 4) // After Terminal
        mainMenu.insertItem(menuItem, at: insertIndex)
    }

    // MARK: - Debug Menu

    #if DEBUG
    private func installDebugMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }
        let menu = NSMenu(title: "Debug")

        let diag = NSMenuItem(title: "Copy Diagnostic to Clipboard", action: #selector(menuCopyDiagnostic), keyEquivalent: "i")
        diag.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(diag)

        let menuItem = NSMenuItem(title: "Debug", action: nil, keyEquivalent: "")
        menuItem.submenu = menu
        mainMenu.addItem(menuItem)
    }

    @objc private func menuCopyDiagnostic() {
        guard let dump = ghosttyManager?.diagnosticDump() else {
            NSSound.beep()
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(dump, forType: .string)
        NSLog("openOwl: [Debug] Diagnostic copied to clipboard (%d bytes)", dump.count)
    }
    #endif

    // MARK: - Menu Actions

    @objc private func menuNewTab() {
        guard canOpenNewTab else { return }
        workspaceStore?.newTab()
    }

    /// True only in the free-terminal namespace — see validateMenuItem.
    private var canOpenNewTab: Bool {
        guard let namespace = workspaceStore?.activeNamespace else { return false }
        if case .freeTerminal = namespace { return true }
        return false
    }

    @objc private func menuCloseTab() {
        closeCurrentTerminal()
    }

    /// Shared by the Close Tab menu item and the ⌘W local monitor.
    private func closeCurrentTerminal() {
        guard let workspaceStore else { return }
        switch workspaceStore.closeCurrent(approveProjectDeactivation: {
            guard let projectStore,
                  let freeTerminalID = projectStore.freeTerminals.first?.id else {
                return false
            }
            return projectStore.activate(.freeTerminal(freeTerminalID))
        }) {
        case .none:
            break
        case .closeWindow:
            NSApp.keyWindow?.performClose(nil)
        case .projectEmptied:
            break
        }
    }

    @objc private func menuSplitHorizontal() {
        workspaceStore?.splitCurrent(axis: .horizontal)
    }

    @objc private func menuSplitVertical() {
        workspaceStore?.splitCurrent(axis: .vertical)
    }

    @objc private func menuToggleMaximize() {
        workspaceStore?.toggleMaximizeCurrentPane()
    }

    @objc private func menuFocusLeft() {
        workspaceStore?.focusNeighbor(.left)
    }

    @objc private func menuFocusRight() {
        workspaceStore?.focusNeighbor(.right)
    }

    @objc private func menuFocusUp() {
        workspaceStore?.focusNeighbor(.up)
    }

    @objc private func menuFocusDown() {
        workspaceStore?.focusNeighbor(.down)
    }

    @objc private func menuShowTerminal() {
        // Terminal owns the center view — only action needed is to drop fullscreen
        // if the right dock is currently masking it.
        rightDockStore?.isFullscreen = false
    }

    @objc private func menuShowGit() {
        rightDockStore?.expand(tab: .git)
    }

    @objc private func menuShowFiles() {
        rightDockStore?.expand(tab: .files)
    }

    @objc private func menuQuickOpen() {
        NotificationCenter.default.post(name: .quickOpen, object: nil)
    }

    @objc private func menuTerminalSearch() {
        guard let workspaceStore else { return }
        if let paneID = workspaceStore.activeFocusedPaneID {
            workspaceStore.startSearch(paneID: paneID)
        }
    }

    // MARK: - Menu Validation
    // NSMenuItemValidation is implicitly conformed via NSObject

    @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        // Terminal occupies the center area unless the right dock is fullscreen.
        let terminalOnly = !(rightDockStore?.isFullscreen ?? false)
        // Menu key-equivalents run before NSEvent local monitors. The firstResponder
        // guard must match handleLocalKeyDown so shortcuts don't fire when the search
        // TextField (or any other non-terminal control) has focus.
        let terminalFocused = terminalOnly && NSApp.keyWindow?.firstResponder is TerminalNSView

        switch menuItem.action {
        // Tabs are a free-terminal affordance — only that namespace draws a tab
        // bar. In a project, ⌘T created a tab with no visible entry point and
        // switched to it; projects lay out with worktrees plus splits instead.
        case #selector(menuNewTab):
            return terminalFocused && canOpenNewTab

        // These shortcuts must only fire when a terminal NSView has focus.
        // Without the firstResponder guard, ⌘W/⌘D/⌘F would be consumed by the
        // menu before the search TextField ever sees them.
        case #selector(menuCloseTab),
             #selector(menuSplitHorizontal), #selector(menuSplitVertical):
            return terminalFocused

        // Search can be started even if the cursor is elsewhere in the terminal tab
        // (e.g. sidebar, status bar), so only require the tab, not TerminalNSView focus.
        case #selector(menuTerminalSearch):
            return terminalOnly

        case #selector(menuFocusLeft), #selector(menuFocusRight),
             #selector(menuFocusUp), #selector(menuFocusDown):
            // Disable when single pane — mirrors handleLocalKeyDown's guard.
            // If enabled with one pane, the menu key equivalent consumes Cmd+Arrow
            // before the terminal NSView receives it (local monitor passes it through).
            guard terminalFocused, let ws = workspaceStore,
                  let tabID = ws.activeTabID,
                  let tab = ws.tabs.first(where: { $0.id == tabID }) else { return false }
            return tab.splitTree.leafCount > 1

        case #selector(menuToggleMaximize):
            if let ws = workspaceStore {
                menuItem.title = ws.maximizedPaneID != nil ? "Restore Pane" : "Maximize Pane"
            }
            return terminalOnly

        default:
            return true
        }
    }

    deinit {
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSLog("openOwl: applicationWillTerminate")
        resourceMonitor.stop()
        // Stop all security-scoped access sessions so macOS can clean up
        projectStore?.bookmarkStore.stopAll()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let hasActiveTerminal = ghosttyManager?.needsConfirmQuit() ?? false
        // The editor keeps unsaved buffers in view state and only writes them
        // from `.onDisappear`, which macOS does not guarantee to run on quit.
        // Without this check ⌘Q dropped them with no prompt and no log.
        let unsaved = fileExplorerStore?.unsavedTabNames ?? []

        AppLogger.log(
            "app-lifecycle",
            "terminate requested terminal=%d unsaved=%d",
            hasActiveTerminal ? 1 : 0,
            unsaved.count
        )

        guard hasActiveTerminal || !unsaved.isEmpty else {
            return .terminateNow
        }

        var reasons: [String] = []
        if !unsaved.isEmpty {
            reasons.append("These files have unsaved changes:\n" + unsaved.map { "• \($0)" }.joined(separator: "\n"))
        }
        if hasActiveTerminal {
            reasons.append("A terminal command is still running. Quitting will stop it.")
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quit openOwl?"
        alert.informativeText = reasons.joined(separator: "\n\n")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: unsaved.isEmpty ? "Quit" : "Discard and Quit")

        let confirmed = alert.runModal() == .alertSecondButtonReturn
        AppLogger.log("app-lifecycle", "terminate %@", confirmed ? "confirmed" : "cancelled")
        return confirmed ? .terminateNow : .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func installLocalKeyMonitor() {
        // Pane-drag cleanup used to hang off .leftMouseUp here, but AppKit's
        // dragging session never routes that event through NSApp.sendEvent, so
        // the monitor never fired. TerminalWorkspaceView polls the button state
        // instead — see watchForPaneDragEnd.
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            return self.handleLocalKeyDown(event) ? nil : event
        }
    }

    private func handleLocalKeyDown(_ event: NSEvent) -> Bool {
        guard let workspaceStore else { return false }

        // Search shortcuts: Esc (close) works from anywhere.
        // Return/Shift+Return (navigate) only when the search text field is focused —
        // if TerminalNSView has focus, the user is typing in the terminal and Return
        // must reach the shell (e.g. IME confirmation, command execution).
        if let paneID = workspaceStore.activeFocusedPaneID,
           let searchState = workspaceStore.paneSearchStates[paneID],
           searchState.isSearching {
            switch event.keyCode {
            // Return/Shift+Return handled by SwiftUI onKeyPress in TerminalSearchOverlay —
            // only fires when the search text field has SwiftUI focus, so it never
            // steals Enter from the terminal (IME confirmation, command execution).
            case 53: // Escape — close search from anywhere
                AppLogger.log(
                    "keyboard-routing",
                    "escape consumed=terminal-search pane=%@",
                    paneID.uuidString.prefix(8) as CVarArg
                )
                workspaceStore.endSearch(paneID: paneID)
                ghosttyManager?.terminalView(for: paneID)?.performBindingAction("end_search")
                _ = ghosttyManager?.focusPane(paneID)
                return true
            default:
                break
            }
        }

        let flags = event.modifierFlags.intersection([.command, .shift, .control, .option])
        if routeTerminalFallbackKeyDown(event, flags: flags) {
            return true
        }

        guard flags.contains(.command) else { return false }
        guard !flags.contains(.control), !flags.contains(.option) else { return false }

        // Cmd+number: context-sensitive switch.
        //  • Free-terminal active → switch among that namespace's tabs (ghostty style).
        //  • Project active        → switch projects (terminal + sidebar + cwd + git + files).
        if let chars = event.charactersIgnoringModifiers?.lowercased(),
           let tabNumber = Int(chars), (1...9).contains(tabNumber),
           !flags.contains(.shift) {
            guard let projectStore else { return false }
            let index = tabNumber - 1

            if case .freeTerminal = projectStore.activeKind {
                let visibleTabs = workspaceStore.visibleTabs
                guard index < visibleTabs.count else { return true }
                rightDockStore?.isFullscreen = false
                workspaceStore.selectTab(id: visibleTabs[index].id)
                return true
            }

            let tabs = projectStore.orderedProjectTabs
            guard index < tabs.count else { return true }
            // Switching projects with Cmd+1..9 should also surface the terminal.
            rightDockStore?.isFullscreen = false
            projectStore.activateProject(id: tabs[index].id)
            return true
        }

        // All other terminal shortcuts only work when the terminal is visible
        // (i.e. right dock is not currently in fullscreen mode).
        guard !(rightDockStore?.isFullscreen ?? false) else { return false }

        // Cmd+Shift+Return: toggle maximize/restore current pane (terminal tab only)
        if flags == [.command, .shift], event.keyCode == 36 {
            workspaceStore.toggleMaximizeCurrentPane()
            return true
        }

        // If focus is not on a TerminalNSView (e.g. search field, commit message),
        // pass all events through so standard text-editing shortcuts work.
        guard NSApp.keyWindow?.firstResponder is TerminalNSView else { return false }

        // Arrow key pane navigation: only intercept when multiple panes exist.
        // Single-pane: let ghostty handle its own Cmd+arrow bindings.
        let isMultiPane: Bool = {
            guard let tab = workspaceStore.tabs.first(where: { $0.id == workspaceStore.activeTabID }) else { return false }
            return tab.splitTree.leafCount > 1
        }()

        if isMultiPane {
            switch event.keyCode {
            case 123: // Left arrow
                if flags.contains(.shift) {
                    workspaceStore.swapPaneWithNeighbor(.left)
                } else {
                    workspaceStore.focusNeighbor(.left)
                }
                return true
            case 124: // Right arrow
                if flags.contains(.shift) {
                    workspaceStore.swapPaneWithNeighbor(.right)
                } else {
                    workspaceStore.focusNeighbor(.right)
                }
                return true
            case 125: // Down arrow
                if flags.contains(.shift) {
                    workspaceStore.swapPaneWithNeighbor(.down)
                } else {
                    workspaceStore.focusNeighbor(.down)
                }
                return true
            case 126: // Up arrow
                if flags.contains(.shift) {
                    workspaceStore.swapPaneWithNeighbor(.up)
                } else {
                    workspaceStore.focusNeighbor(.up)
                }
                return true
            default:
                break
            }
        }

        guard let chars = event.charactersIgnoringModifiers?.lowercased() else { return false }

        switch chars {
        case "t":
            // Same rule as validateMenuItem: this monitor is a second entry
            // point for ⌘T, so graying out the menu item alone would not stop it.
            guard canOpenNewTab else { return false }
            workspaceStore.newTab()
            return true
        case "w":
            closeCurrentTerminal()
            return true
        case "d":
            if flags.contains(.shift) {
                workspaceStore.splitCurrent(axis: .vertical)
            } else {
                workspaceStore.splitCurrent(axis: .horizontal)
            }
            return true
        case "f":
            guard !flags.contains(.shift) else { return false }
            if let paneID = workspaceStore.activeFocusedPaneID {
                workspaceStore.startSearch(paneID: paneID)
            }
            return true
        default:
            return false
        }
    }

    private func routeTerminalFallbackKeyDown(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> Bool {
        let isEscape = event.keyCode == 53 && (flags.isEmpty || flags == [.shift])
        let isControlC = flags == [.control] && event.charactersIgnoringModifiers?.lowercased() == "c"
        guard isEscape || isControlC else { return false }

        let keyName = isEscape ? "escape" : "ctrl-c"
        // Always log ESC/Ctrl-C attempts so intermittent routing is diagnosable.
        AppLogger.log(
            "keyboard-routing",
            "key=%@ firstResponder=%@",
            keyName,
            NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        )
        guard !(rightDockStore?.isFullscreen ?? false) else {
            AppLogger.log(
                "keyboard-routing",
                "fallback blocked key=%@ reason=right-dock-fullscreen",
                keyName
            )
            return false
        }

        guard let window = NSApp.keyWindow else { return false }
        let originalResponder = window.firstResponder
        if isEscape,
           let terminalResponder = originalResponder as? TerminalNSView,
           terminalResponder.acceptsTerminalKeyboardInput {
            return terminalResponder.performKeyEquivalent(with: event)
        }

        guard let workspaceStore else { return false }
        guard let paneID = workspaceStore.activeFocusedPaneID else {
            AppLogger.log(
                "keyboard-routing",
                "fallback failed key=%@ reason=no-focused-pane responder=%@",
                keyName,
                originalResponder.map { String(describing: type(of: $0)) } ?? "nil"
            )
            return false
        }
        guard let terminalView = ghosttyManager?.terminalView(for: paneID) else {
            AppLogger.log(
                "keyboard-routing",
                "fallback failed key=%@ reason=no-terminal-view pane=%@ responder=%@",
                keyName,
                paneID.uuidString.prefix(8) as CVarArg,
                originalResponder.map { String(describing: type(of: $0)) } ?? "nil"
            )
            return false
        }

        let allowed = isEscape
            ? TerminalFallbackResponderPolicy.allowsEscapeFallback(
                from: originalResponder,
                in: window,
                terminalWindow: terminalView.window
            )
            : TerminalFallbackResponderPolicy.allowsFallback(
                from: originalResponder,
                in: window,
                terminalWindow: terminalView.window
            )
        guard allowed else {
            if !(originalResponder is TerminalNSView) {
                AppLogger.log(
                    "keyboard-routing",
                    "fallback blocked key=%@ responder=%@",
                    keyName,
                    originalResponder.map { String(describing: type(of: $0)) } ?? "nil"
                )
            }
            return false
        }

        ghosttyManager?.ensurePaneFocused(paneID)
        let handled = terminalView.handleMonitoredKeyDown(event)
        AppLogger.log(
            "keyboard-routing",
            "fallback key=%@ pane=%@ responder=%@ handled=%d terminalAccepts=%d",
            keyName,
            paneID.uuidString.prefix(8) as CVarArg,
            originalResponder.map { String(describing: type(of: $0)) } ?? "nil",
            handled ? 1 : 0,
            terminalView.acceptsTerminalKeyboardInput ? 1 : 0
        )
        return handled
    }
}

// MARK: - Keyboard Routing

extension AppDelegate {
    /// Route key events to the focused terminal NSView, bypassing SwiftUI's event handling.
    /// Without this, SwiftUI intercepts keys like arrow keys, Tab, Escape, etc.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for window in sender.windows {
                window.makeKeyAndOrderFront(self)
            }
        }
        return true
    }
}

// MARK: - User Notifications

extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}
