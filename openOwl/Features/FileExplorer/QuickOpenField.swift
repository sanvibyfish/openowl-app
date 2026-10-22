import AppKit
import SwiftUI

/// AppKit-backed single-line field for the ⌘P panel.
///
/// SwiftUI's `TextField` + `@FocusState` could not reliably claim first responder
/// over the ghostty terminal's `NSView` in this hybrid app: the panel appeared
/// but the terminal kept focus, so every keystroke, arrow key and Escape fell
/// through to the shell — Quick Open looked broken and the terminal "ran away".
///
/// Owning the `NSTextField` lets us call `makeFirstResponder` explicitly once the
/// view is attached to a window, and route ↑ / ↓ / Return / Escape through the
/// delegate instead of SwiftUI key handlers that depend on focus state being in
/// sync with AppKit.
struct QuickOpenField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onSubmit: () -> Void
    var onMoveSelection: (Int) -> Void
    var onEscape: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.isBezeled = false
        field.isEditable = true
        field.isSelectable = true
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 14)
        field.textColor = .labelColor
        field.placeholderString = placeholder
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.cell?.truncatesLastVisibleLine = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        context.coordinator.claimFocus(for: field)
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: QuickOpenField
        private var hasClaimedFocus = false
        private var didAttachToWindow = false

        init(_ parent: QuickOpenField) {
            self.parent = parent
        }

        /// The field is inserted into the SwiftUI overlay before its window
        /// exists, so a synchronous `makeFirstResponder` is dropped. Poll for a
        /// short window and re-claim whenever the field has lost focus — the
        /// terminal wrapper reparents during the presentation animation and can
        /// yank the responder back if the claim only happened once.
        func claimFocus(for field: NSTextField) {
            guard !hasClaimedFocus else { return }
            hasClaimedFocus = true
            attemptFocus(field, retriesLeft: 25)
        }

        private func attemptFocus(_ field: NSTextField, retriesLeft: Int) {
            guard retriesLeft > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak field] in
                guard let field else { return }
                if let window = field.window {
                    self.didAttachToWindow = true
                    if window.firstResponder !== field.currentEditor() {
                        window.makeFirstResponder(field)
                    }
                } else if self.didAttachToWindow {
                    // Panel was dismissed — stop chasing the responder so we
                    // don't steal focus back from the file editor it just opened.
                    return
                }
                self.attemptFocus(field, retriesLeft: retriesLeft - 1)
            }
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                parent.onMoveSelection(-1)
                return true
            case #selector(NSResponder.moveDown(_:)):
                parent.onMoveSelection(1)
                return true
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onEscape()
                return true
            default:
                return false
            }
        }
    }
}
