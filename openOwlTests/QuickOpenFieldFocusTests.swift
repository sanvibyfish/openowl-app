import AppKit
import SwiftUI
import Testing
@testable import openOwl

/// Regression coverage for the ⌘P panel focus bug.
///
/// The panel appeared over the ghostty terminal, but SwiftUI's `@FocusState`
/// never managed to take first responder away from the terminal's `NSView`, so
/// typing, arrows and Escape fell through to the shell. `QuickOpenField` owns an
/// `NSTextField` and claims the responder explicitly; this test stands in a
/// competing first responder for the terminal and asserts the field wins.
@Suite("Quick open field focus")
@MainActor
struct QuickOpenFieldFocusTests {

    /// An AppKit view that is willing to be first responder, like TerminalNSView.
    private final class CompetingResponderView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    private func firstTextField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField { return field }
        for subview in view.subviews {
            if let found = firstTextField(in: subview) { return found }
        }
        return nil
    }

    @Test func claimsFirstResponderFromCompetingAppKitView() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 80),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.close() }

        let container = NSView(frame: window.contentLayoutRect)
        let competitor = CompetingResponderView(frame: container.bounds)
        container.addSubview(competitor)
        window.contentView = container
        #expect(window.makeFirstResponder(competitor))
        #expect(window.firstResponder === competitor)

        let hosting = NSHostingView(rootView: QuickOpenField(
            text: .constant(""),
            placeholder: "Go to File",
            onSubmit: {},
            onMoveSelection: { _ in },
            onEscape: {}
        ))
        hosting.frame = NSRect(x: 0, y: 0, width: 420, height: 40)
        container.addSubview(hosting)
        hosting.layoutSubtreeIfNeeded()

        // The field retries on a 10ms tick until it is attached and focused.
        var field: NSTextField?
        for _ in 0..<80 {
            if field == nil { field = firstTextField(in: hosting) }
            if let field,
               window.firstResponder === field || window.firstResponder === field.currentEditor() {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        let resolved = try #require(field, "NSTextField was never created")
        #expect(
            window.firstResponder === resolved || window.firstResponder === resolved.currentEditor(),
            "expected the Quick Open field to own focus, got \(String(describing: window.firstResponder))"
        )
    }
}
