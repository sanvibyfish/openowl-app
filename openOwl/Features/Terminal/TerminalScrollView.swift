import AppKit

/// Scrollbar state from ghostty core: total rows, viewport offset, visible row count.
struct TerminalScrollbarState {
    let total: UInt64
    let offset: UInt64
    let len: UInt64
}

/// Hosts a TerminalNSView with a custom scroll indicator overlay.
///
/// No NSScrollView is used — scrollWheel events go directly to TerminalNSView → ghostty.
/// A standalone ScrollIndicatorView shows scroll position from ghostty's SCROLLBAR action.
class TerminalScrollView: NSView {
    let terminalView: TerminalNSView
    private let scroller: ScrollIndicatorView
    private var terminalShouldBeVisible = true

    /// When true, the terminal view keeps its current frame width even if the
    /// host shrinks (e.g. Right Dock opening). Prevents destructive PTY reflow
    /// of scrollback content. The overflow is clipped by masksToBounds.
    var freezeTerminalWidth = false

    /// Current scrollbar state from ghostty core
    var scrollbarState: TerminalScrollbarState?

    init(terminalView: TerminalNSView) {
        self.terminalView = terminalView

        // Custom scroll indicator — a simple rounded bar drawn manually.
        // NSScroller (both overlay and legacy) doesn't render the knob
        // correctly without an NSScrollView parent.
        scroller = ScrollIndicatorView()

        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(terminalView)
        addSubview(scroller)

        scroller.onScrollRequest = { [weak self] position in
            self?.scrollToPosition(position)
        }
        scroller.onInteractionChange = { [weak self] active in
            self?.setScrollerInteractionActive(active)
        }

        // Accept file/URL/text drops on this top-level view (SwiftUI hosts this directly)
        registerForDraggedTypes([.fileURL, .URL, .string])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    deinit {
        scrollerFadeTimer?.invalidate()
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        let prev = terminalView.frame

        if freezeTerminalWidth && bounds.width < prev.width {
            terminalView.frame = CGRect(x: 0, y: 0, width: prev.width, height: bounds.height)
        } else {
            terminalView.frame = bounds
        }
        terminalView.syncSurfaceSize(reason: "scroll-layout")

        let indicatorWidth: CGFloat = 8
        let margin: CGFloat = 2
        scroller.frame = CGRect(
            x: bounds.width - indicatorWidth - margin,
            y: margin,
            width: indicatorWidth,
            height: bounds.height - margin * 2
        )
        AppLogger.log("resize-diag", "ScrollView.layout pane=%@ bounds=%.1fx%.1f prevTermFrame=%.1fx%.1f frozen=%@ changed=%@",
                      terminalView.paneIdentifier.uuidString.prefix(8) as CVarArg,
                      bounds.width, bounds.height,
                      prev.width, prev.height,
                      freezeTerminalWidth ? "y" : "n",
                      prev.size == bounds.size ? "no" : "YES")
    }

    // MARK: - Public API

    /// Called when ghostty sends GHOSTTY_ACTION_SCROLLBAR
    func updateScrollbar(_ state: TerminalScrollbarState) {
        let previousOffset = scrollbarState?.offset
        scrollbarState = state

        guard state.total > 0, state.len > 0, state.total >= state.len else { return }

        let hasScrollback = state.total > state.len

        if hasScrollback {
            let maxOffset = state.total - state.len
            let proportion = CGFloat(state.len) / CGFloat(state.total)
            // Clamp: ghostty values are async and offset can transiently exceed maxOffset
            let position = maxOffset > 0 ? min(CGFloat(state.offset) / CGFloat(maxOffset), 1.0) : 0
            scroller.update(proportion: proportion, position: position)

            if state.offset != previousOffset {
                showScrollerTemporarily()
            }
        } else if scroller.alphaValue > 0 {
            scroller.alphaValue = 0
        }
    }

    private var scrollerFadeTimer: Timer?
    private var scrollerInteractionActive = false

    private func showScrollerTemporarily() {
        scroller.alphaValue = 0.7
        scrollerFadeTimer?.invalidate()
        // While the user is dragging, keep the indicator visible indefinitely.
        guard !scrollerInteractionActive else { return }
        scrollerFadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                self?.scroller.animator().alphaValue = 0
            }
        }
    }

    /// Called by ScrollIndicatorView during mouseDown/mouseUp so we can suspend fade.
    private func setScrollerInteractionActive(_ active: Bool) {
        scrollerInteractionActive = active
        if active {
            scrollerFadeTimer?.invalidate()
            scroller.alphaValue = 0.7
        } else {
            // Restart the fade countdown after the drag ends.
            showScrollerTemporarily()
        }
    }

    /// Converts a fractional position [0, 1] into a scrollback row and forwards
    /// to ghostty via the scroll_to_row binding action.
    /// position=0 → top of scrollback, position=1 → live viewport.
    private func scrollToPosition(_ position: CGFloat) {
        guard let state = scrollbarState,
              state.total > state.len else { return }
        let maxOffset = state.total - state.len
        let clamped = max(0, min(1, position))
        let row = UInt64((CGFloat(maxOffset) * clamped).rounded())
        terminalView.performBindingAction("scroll_to_row:\(row)")
    }

    func setTerminalVisibility(_ isVisible: Bool) {
        let changed = terminalShouldBeVisible != isVisible
        terminalShouldBeVisible = isVisible
        terminalView.setSurfaceVisibility(isVisible)
        guard isVisible, changed else { return }

        needsLayout = true
        layoutSubtreeIfNeeded()
        terminalView.syncSurfaceSize(reason: "visibility-restored", force: true)
    }

    // MARK: - Drag & Drop (forwarded to terminalView)

    private static let acceptedDropTypes: Set<NSPasteboard.PasteboardType> = [.fileURL, .URL, .string]

    /// Reject drags on hidden terminals (opacity=0 via SwiftUI project tab switching).
    /// Without this, AppKit routes drags to invisible views in the ZStack, causing
    /// the file path to appear in the wrong project's terminal.
    private var isEffectivelyVisible: Bool {
        var view: NSView? = self
        while let v = view {
            if v.isHidden || v.alphaValue < 0.01 { return false }
            view = v.superview
        }
        return true
    }

    private func canAcceptDrag(_ sender: NSDraggingInfo) -> Bool {
        guard isEffectivelyVisible,
              let types = sender.draggingPasteboard.types,
              !Set(types).isDisjoint(with: Self.acceptedDropTypes) else { return false }
        return true
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        canAcceptDrag(sender) ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        canAcceptDrag(sender) ? .copy : []
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        canAcceptDrag(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard isEffectivelyVisible else { return false }
        return terminalView.performDragOperation(sender)
    }
}

// MARK: - Scroll Indicator

/// Custom scroll indicator that draws a rounded bar.
/// NSScroller doesn't render its knob correctly without an NSScrollView parent,
/// so we draw our own minimal indicator. Supports click-to-jump and knob dragging.
class ScrollIndicatorView: NSView {
    private var proportion: CGFloat = 1
    private var position: CGFloat = 0

    /// Called when the user drags the knob or clicks the track.
    /// Argument is the target position in [0, 1], where 0 = top of scrollback.
    var onScrollRequest: ((CGFloat) -> Void)?
    /// Called at mouseDown (true) and mouseUp (false) so the host can suspend fade.
    var onInteractionChange: ((Bool) -> Void)?

    /// Captured at mouseDown when the click hit the knob itself:
    /// knob's top-Y in view coords minus the mouseDown Y. Used to preserve the
    /// mouse-to-knob offset during drag (prevents knob from snapping to cursor).
    private var dragKnobOffsetY: CGFloat?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        alphaValue = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(proportion: CGFloat, position: CGFloat) {
        self.proportion = proportion
        self.position = position
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard proportion < 1 else { return }
        let rect = knobRect()
        let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        NSColor.labelColor.withAlphaComponent(0.35).setFill()
        path.fill()
    }

    // MARK: - Geometry helpers

    /// Returns the knob rect in view coordinates (AppKit, +Y up).
    private func knobRect() -> NSRect {
        let knobHeight = max(bounds.height * proportion, 24)
        let trackSpace = bounds.height - knobHeight
        // position 0 → top of scrollback → knob at top of track (high Y in AppKit)
        let knobY = bounds.height - knobHeight - (trackSpace * position)
        return NSRect(x: 1, y: knobY, width: bounds.width - 2, height: knobHeight)
    }

    /// Converts a cursor Y (view coords) to a position in [0, 1], given the knob
    /// height. When `knobTopYAtMouseDown` is provided, preserves the relative offset
    /// so the knob doesn't jump under the cursor.
    private func positionForCursorY(_ cursorY: CGFloat, knobOffsetY: CGFloat) -> CGFloat {
        let knobHeight = knobRect().height
        let trackSpace = bounds.height - knobHeight
        guard trackSpace > 0 else { return 0 }
        // Target knob top-Y, adjusted so the cursor stays at the same spot on the knob.
        let targetKnobTopY = cursorY + knobOffsetY
        // Invert: knobY = bounds.height - knobHeight - (trackSpace * position)
        // => position = (bounds.height - knobHeight - knobY) / trackSpace
        let pos = (bounds.height - knobHeight - targetKnobTopY) / trackSpace
        return max(0, min(1, pos))
    }

    // MARK: - Mouse handling

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Reject hit tests when fully transparent — otherwise the scroller swallows
    /// clicks even when invisible, blocking the terminal underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard alphaValue > 0.01, proportion < 1 else { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let knob = knobRect()

        if knob.contains(p) {
            // Click on knob → start drag, preserve cursor offset on the knob.
            // knobOffsetY = knobTopY - cursorY; adding this back to cursor gives knob top.
            dragKnobOffsetY = knob.maxY - p.y - knob.height
            onInteractionChange?(true)
        } else {
            // Click on empty track → jump so the knob center lands at cursor,
            // then enter drag mode anchored there.
            dragKnobOffsetY = -knob.height / 2
            let newPos = positionForCursorY(p.y, knobOffsetY: dragKnobOffsetY!)
            onInteractionChange?(true)
            onScrollRequest?(newPos)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let offset = dragKnobOffsetY else { return }
        let p = convert(event.locationInWindow, from: nil)
        let newPos = positionForCursorY(p.y, knobOffsetY: offset)
        onScrollRequest?(newPos)
    }

    override func mouseUp(with event: NSEvent) {
        dragKnobOffsetY = nil
        onInteractionChange?(false)
    }
}
