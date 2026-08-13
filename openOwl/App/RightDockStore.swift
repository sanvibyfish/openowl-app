import CoreGraphics
import Foundation
import Observation

enum RightDockTab: String, CaseIterable, Hashable, Identifiable {
    case files
    case git
    case bus

    var id: String { rawValue }

    var title: String {
        switch self {
        case .files: return "Files"
        case .git: return "Git"
        case .bus: return "Bus"
        }
    }

    var systemImage: String {
        switch self {
        case .files: return "folder"
        case .git: return "point.bottomleft.forward.to.point.topright.scurvepath"
        case .bus: return "tray.2"
        }
    }
}

@MainActor
@Observable
final class RightDockStore {
    static let minWidth: CGFloat = 320
    /// When Files editor / Git diff is visible, dock must be wide enough that
    /// neither the list column nor the detail column gets crushed mid-glyph.
    static let minWidthWithDetail: CGFloat = 520
    static let defaultWidth: CGFloat = 520
    /// Width used when the active tab's detail panel is hidden — narrow enough
    /// to comfortably fit just the tree/changes list without dead space.
    static let listOnlyWidth: CGFloat = 280
    static let maxWidthFraction: CGFloat = 0.55

    private static let keyExpanded = "openowl.rightDock.isExpanded"
    private static let keyActiveTab = "openowl.rightDock.activeTab"
    private static let keyWidth = "openowl.rightDock.width"
    private static let keyFilesShowsEditor = "openowl.rightDock.files.showsEditor"
    private static let keyFilesShowsTree = "openowl.rightDock.files.showsTree"
    private static let keyGitShowsDiff = "openowl.rightDock.git.showsDiff"

    var isExpanded: Bool {
        didSet {
            UserDefaults.standard.set(isExpanded, forKey: Self.keyExpanded)
            if !isExpanded {
                endInteractiveResize()
                isFullscreen = false
            }
            startDockResizeAnimation()
        }
    }

    var activeTab: RightDockTab {
        didSet { UserDefaults.standard.set(activeTab.rawValue, forKey: Self.keyActiveTab) }
    }

    var width: CGFloat {
        didSet { UserDefaults.standard.set(Double(width), forKey: Self.keyWidth) }
    }

    /// Fullscreen is session-scoped — not persisted across launches.
    var isFullscreen: Bool = false {
        didSet {
            if isFullscreen { endInteractiveResize() }
            startDockResizeAnimation()
        }
    }

    /// True only during the ~400ms window after the dock starts expanding/collapsing.
    /// Used by TerminalPanel to freeze terminal resize during the animation to prevent
    /// destructive PTY reflow, then auto-releases so the terminal can resize normally.
    private(set) var isAnimatingDockResize: Bool = false
    private var dockResizeTimer: DispatchWorkItem?

    /// True while the user is dragging the dock resize handle. The terminal
    /// should keep rendering clipped to its host, but the PTY size must not
    /// follow every intermediate drag width.
    private(set) var isInteractingWithWidthResize: Bool = false

    var shouldFreezeTerminalResize: Bool {
        isAnimatingDockResize || isInteractingWithWidthResize
    }

    /// File explorer: false hides the editor pane, leaving only the tree.
    var filesShowsEditor: Bool {
        didSet {
            if !filesShowsEditor { filesShowsTree = true }
            UserDefaults.standard.set(filesShowsEditor, forKey: Self.keyFilesShowsEditor)
        }
    }

    /// File explorer: false hides the tree pane, leaving only the editor.
    var filesShowsTree: Bool {
        didSet {
            if !filesShowsTree { filesShowsEditor = true }
            UserDefaults.standard.set(filesShowsTree, forKey: Self.keyFilesShowsTree)
        }
    }

    /// Git changes: false hides the diff pane, leaving only the changes list.
    var gitShowsDiff: Bool {
        didSet { UserDefaults.standard.set(gitShowsDiff, forKey: Self.keyGitShowsDiff) }
    }

    init() {
        let defaults = UserDefaults.standard
        self.isExpanded = defaults.object(forKey: Self.keyExpanded) as? Bool ?? false
        let savedTab = defaults.string(forKey: Self.keyActiveTab) ?? ""
        self.activeTab = RightDockTab(rawValue: savedTab) ?? .git
        let savedWidth = defaults.object(forKey: Self.keyWidth) as? Double
        let resolvedWidth = CGFloat(savedWidth ?? Double(Self.defaultWidth))
        self.width = max(Self.minWidth, resolvedWidth)
        self.filesShowsEditor = defaults.object(forKey: Self.keyFilesShowsEditor) as? Bool ?? true
        self.filesShowsTree = defaults.object(forKey: Self.keyFilesShowsTree) as? Bool ?? true
        self.gitShowsDiff = defaults.object(forKey: Self.keyGitShowsDiff) as? Bool ?? true
        if !filesShowsTree && !filesShowsEditor {
            filesShowsTree = true
        }
    }

    func startDockResizeAnimation() {
        dockResizeTimer?.cancel()
        isAnimatingDockResize = true
        let work = DispatchWorkItem { [weak self] in
            self?.isAnimatingDockResize = false
        }
        dockResizeTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func beginInteractiveResize() {
        isInteractingWithWidthResize = true
    }

    func endInteractiveResize() {
        isInteractingWithWidthResize = false
    }

    /// True if the active tab's detail panel (editor / diff) is currently visible.
    var showsDetailForActiveTab: Bool {
        switch activeTab {
        case .files: return filesShowsEditor
        case .git: return gitShowsDiff
        case .bus: return false
        }
    }

    /// Floor for the current mode. List-only reports `listOnlyWidth` because
    /// that is exactly what `effectiveWidth` renders in that mode — reporting
    /// `minWidth` here would have the type contradict its own output.
    var currentMinWidth: CGFloat {
        showsDetailForActiveTab ? Self.minWidthWithDetail : Self.listOnlyWidth
    }

    /// Width the dock panel actually occupies, given fullscreen state and
    /// whether the active tab is showing its detail pane. The host passes its
    /// own width so fullscreen can stretch to fill it.
    func effectiveWidth(hostWidth: CGFloat) -> CGFloat {
        if isFullscreen { return max(0, hostWidth) }
        let maxW = Self.maxNormalWidth(hostWidth: hostWidth)
        if !showsDetailForActiveTab {
            return min(Self.listOnlyWidth, maxW)
        }
        // Prefer the detail floor so HSplit columns aren't crushed mid-glyph.
        // The outer min still lets a small window win.
        return min(max(width, currentMinWidth), maxW)
    }

    static func maxNormalWidth(hostWidth: CGFloat) -> CGFloat {
        max(0, hostWidth * maxWidthFraction)
    }

    /// Toolbar button behavior:
    /// - panel 折叠 → 展开并切到该 tab
    /// - panel 已展开且 tab 相同 → 折叠
    /// - panel 已展开且 tab 不同 → 切到该 tab（保持展开）
    func toggle(tab: RightDockTab) {
        if !isExpanded {
            activeTab = tab
            isExpanded = true
        } else if activeTab == tab {
            isExpanded = false
        } else {
            activeTab = tab
        }
    }

    func collapse() {
        isExpanded = false
    }

    func expand(tab: RightDockTab) {
        activeTab = tab
        isExpanded = true
    }

    /// No-op when panel is collapsed (no fullscreen without an open panel).
    func toggleFullscreen() {
        guard isExpanded else { return }
        isFullscreen.toggle()
    }

    /// Clamp width to [currentMinWidth, maxWidth]. Caller passes the live maxWidth
    /// derived from the host window.
    func setWidth(_ newWidth: CGFloat, maxWidth: CGFloat) {
        let floor = currentMinWidth
        let clampedMax = max(floor, maxWidth)
        width = min(max(floor, newWidth), clampedMax)
    }
}
