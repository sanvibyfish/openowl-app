import AppKit
import SwiftUI
import UserNotifications

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    weak var ghosttyManager: GhosttyAppManager?
    var workspaceStore: TerminalWorkspaceStore?
    weak var projectStore: ProjectStore?
    weak var rightDockStore: RightDockStore?
    private var localKeyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        applyDevIcon()
        ensureEditMenu()
        installTerminalMenu()
        installViewMenu()
        installLocalKeyMonitor()
        #if DEBUG
        installDebugMenu()
        #endif
        requestNotificationPermission()
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            NSLog("openOwl: [Notification] permission granted=%d error=%@",
                  granted ? 1 : 0, error?.localizedDescription ?? "nil")
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
        workspaceStore?.newTab()
    }

    @objc private func menuCloseTab() {
        guard let workspaceStore else { return }
        if workspaceStore.closeCurrent() == .closeWindow {
            NSApp.keyWindow?.performClose(nil)
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
        if let tab = workspaceStore.tabs.first(where: { $0.id == workspaceStore.activeTabID }),
           let paneID = tab.focusedPaneID ?? tab.splitTree.firstPaneID {
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
        // These shortcuts must only fire when a terminal NSView has focus.
        // Without the firstResponder guard, ⌘T/⌘W/⌘D/⌘F would be consumed by the
        // menu before the search TextField ever sees them.
        case #selector(menuNewTab), #selector(menuCloseTab),
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
        // Stop all security-scoped access sessions so macOS can clean up
        projectStore?.bookmarkStore.stopAll()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let hasActiveTerminal = ghosttyManager?.needsConfirmQuit() ?? false

        NSLog(
            "openOwl: applicationShouldTerminate requested terminal=%d",
            hasActiveTerminal ? 1 : 0
        )

        guard hasActiveTerminal else {
            return .terminateNow
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quit openOwl?"
        alert.informativeText = "A terminal command is still running. Quitting will stop it."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit")

        let confirmed = alert.runModal() == .alertSecondButtonReturn
        NSLog("openOwl: applicationShouldTerminate %@", confirmed ? "confirmed" : "cancelled")
        return confirmed ? .terminateNow : .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func installLocalKeyMonitor() {
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseUp]) { [weak self] event in
            guard let self else { return event }
            switch event.type {
            case .keyDown:
                return self.handleLocalKeyDown(event) ? nil : event
            case .leftMouseUp:
                // Deferred so PaneDropDelegate.performDrop() (called synchronously by
                // AppKit during the same event dispatch) runs first. For successful
                // drops cleanup() already clears draggingPaneID and this is a no-op.
                // For cancelled drags (no valid target), this clears the stuck overlay.
                Task { @MainActor [weak self] in
                    self?.workspaceStore?.cancelDragIfActive()
                }
                return event
            default:
                return event
            }
        }
    }

    private func handleLocalKeyDown(_ event: NSEvent) -> Bool {
        guard let workspaceStore else { return false }

        // Search shortcuts: Esc (close) works from anywhere.
        // Return/Shift+Return (navigate) only when the search text field is focused —
        // if TerminalNSView has focus, the user is typing in the terminal and Return
        // must reach the shell (e.g. IME confirmation, command execution).
        if let tab = workspaceStore.tabs.first(where: { $0.id == workspaceStore.activeTabID }),
           let paneID = tab.focusedPaneID ?? tab.splitTree.firstPaneID,
           let searchState = workspaceStore.paneSearchStates[paneID],
           searchState.isSearching {
            switch event.keyCode {
            // Return/Shift+Return handled by SwiftUI onKeyPress in TerminalSearchOverlay —
            // only fires when the search text field has SwiftUI focus, so it never
            // steals Enter from the terminal (IME confirmation, command execution).
            case 53: // Escape — close search from anywhere
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
            workspaceStore.newTab()
            return true
        case "w":
            if workspaceStore.closeCurrent() == .closeWindow {
                NSApp.keyWindow?.performClose(nil)
            }
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
            if let tab = workspaceStore.tabs.first(where: { $0.id == workspaceStore.activeTabID }),
               let paneID = tab.focusedPaneID ?? tab.splitTree.firstPaneID {
                workspaceStore.startSearch(paneID: paneID)
            }
            return true
        default:
            return false
        }
    }

    private func routeTerminalFallbackKeyDown(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> Bool {
        guard !(rightDockStore?.isFullscreen ?? false) else { return false }

        let isEscape = event.keyCode == 53 && (flags.isEmpty || flags == [.shift])
        let isControlC = flags == [.control] && event.charactersIgnoringModifiers?.lowercased() == "c"
        guard isEscape || isControlC else { return false }

        guard let window = NSApp.keyWindow else { return false }
        if let firstResponder = window.firstResponder {
            if let terminalResponder = firstResponder as? TerminalNSView,
               terminalResponder.acceptsTerminalKeyboardInput {
                return false
            }
            if firstResponder !== window && !(firstResponder is TerminalNSView) {
                return false
            }
        }

        guard let workspaceStore else { return false }
        guard let tab = workspaceStore.tabs.first(where: { $0.id == workspaceStore.activeTabID }),
              let paneID = tab.focusedPaneID ?? tab.splitTree.firstPaneID,
              let terminalView = ghosttyManager?.terminalView(for: paneID) else { return false }

        ghosttyManager?.ensurePaneFocused(paneID)
        return terminalView.handleMonitoredKeyDown(event)
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
