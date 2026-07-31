import AppKit
import SwiftUI
import Testing
@testable import openOwl

@Suite("Terminal fallback responder policy")
@MainActor
struct TerminalKeyboardRoutingTests {
    @Test func hostingContainerAllowsFallback() {
        let window = NSWindow()
        let hostingView = NSHostingView(rootView: EmptyView())
        window.contentView = hostingView

        #expect(TerminalFallbackResponderPolicy.allowsFallback(
            from: hostingView,
            in: window,
            terminalWindow: window
        ))
    }

    @Test func noninteractiveHostingSubviewAllowsFallback() {
        let window = NSWindow()
        let hostingView = NSHostingView(rootView: EmptyView())
        let subtreeView = NSView()
        hostingView.addSubview(subtreeView)
        window.contentView = hostingView

        #expect(TerminalFallbackResponderPolicy.allowsFallback(
            from: subtreeView,
            in: window,
            terminalWindow: window
        ))
    }

    @Test func textInputInsideHostingSubviewBlocksFallback() {
        let window = NSWindow()
        let hostingView = NSHostingView(rootView: EmptyView())
        let subtreeView = NSView()
        let field = NSTextField()
        hostingView.addSubview(subtreeView)
        subtreeView.addSubview(field)
        window.contentView = hostingView

        #expect(!TerminalFallbackResponderPolicy.allowsFallback(
            from: field,
            in: window,
            terminalWindow: window
        ))
    }

    @Test func windowAllowsFallback() {
        let window = NSWindow()
        window.makeFirstResponder(window)

        #expect(TerminalFallbackResponderPolicy.allowsFallback(
            from: window.firstResponder,
            in: window,
            terminalWindow: window
        ))
    }

    @Test func attachedTextFieldAndTextViewBlockFallback() {
        let window = NSWindow()
        let container = NSView()
        let field = NSTextField()
        let editor = NSTextView()
        container.addSubview(field)
        container.addSubview(editor)
        window.contentView = container
        window.makeFirstResponder(field)
        #expect(!TerminalFallbackResponderPolicy.allowsFallback(
            from: window.firstResponder,
            in: window,
            terminalWindow: window
        ))
        #expect(!TerminalFallbackResponderPolicy.allowsFallback(
            from: editor,
            in: window,
            terminalWindow: window
        ))
    }

    @Test func detachedOrHiddenTextInputAllowsFallback() {
        let window = NSWindow()
        let container = NSView()
        let hiddenField = NSTextField()
        hiddenField.isHidden = true
        container.addSubview(hiddenField)
        window.contentView = container

        #expect(TerminalFallbackResponderPolicy.allowsFallback(
            from: hiddenField,
            in: window,
            terminalWindow: window
        ))
        #expect(TerminalFallbackResponderPolicy.allowsFallback(
            from: NSTextField(),
            in: window,
            terminalWindow: window
        ))
    }

    @Test func interactiveDescendantOfOutlineBlocksFallback() {
        let window = NSWindow()
        let outline = NSOutlineView()
        let internalView = NSView()
        outline.addSubview(internalView)
        window.contentView = outline

        #expect(!TerminalFallbackResponderPolicy.allowsFallback(
            from: internalView,
            in: window,
            terminalWindow: window
        ))
    }

    @Test func commandButtonsAllowFallback() {
        let window = NSWindow()
        let button = NSButton()
        window.contentView = button

        #expect(TerminalFallbackResponderPolicy.allowsFallback(
            from: button,
            in: window,
            terminalWindow: window
        ))
    }

    @Test func outlineAllowsEscapeButBlocksGeneralFallback() {
        let window = NSWindow()
        let outline = NSOutlineView()
        let internalView = NSView()
        outline.addSubview(internalView)
        window.contentView = outline

        #expect(TerminalFallbackResponderPolicy.allowsEscapeFallback(
            from: internalView,
            in: window,
            terminalWindow: window
        ))
        #expect(!TerminalFallbackResponderPolicy.allowsFallback(
            from: internalView,
            in: window,
            terminalWindow: window
        ))
    }

    @Test func textFieldBlocksEscapeFallback() {
        let window = NSWindow()
        let field = NSTextField()
        window.contentView = field

        #expect(!TerminalFallbackResponderPolicy.allowsEscapeFallback(
            from: field,
            in: window,
            terminalWindow: window
        ))
    }

    @Test func nonTerminalWindowBlocksFallback() {
        let terminalWindow = NSWindow()
        let dialogWindow = NSWindow()
        let button = NSButton()
        dialogWindow.contentView = button

        #expect(!TerminalFallbackResponderPolicy.allowsEscapeFallback(
            from: button,
            in: dialogWindow,
            terminalWindow: terminalWindow
        ))
    }

    @Test func alertAndOpenPanelBlockFallback() {
        let alert = NSAlert()
        let panel = NSOpenPanel()

        #expect(!TerminalFallbackResponderPolicy.allowsEscapeFallback(
            from: alert.window.firstResponder,
            in: alert.window,
            terminalWindow: alert.window
        ))
        #expect(!TerminalFallbackResponderPolicy.allowsEscapeFallback(
            from: panel.firstResponder,
            in: panel,
            terminalWindow: panel
        ))
    }

    @Test func sheetBlocksFallback() {
        let parent = NSWindow()
        let sheet = NSWindow()
        parent.beginSheet(sheet)
        defer { parent.endSheet(sheet) }

        #expect(!TerminalFallbackResponderPolicy.allowsEscapeFallback(
            from: sheet.firstResponder,
            in: sheet,
            terminalWindow: sheet
        ))
        #expect(!TerminalFallbackResponderPolicy.allowsEscapeFallback(
            from: parent.firstResponder,
            in: parent,
            terminalWindow: parent
        ))
    }
}
