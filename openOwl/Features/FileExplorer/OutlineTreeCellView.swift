import AppKit

final class OutlineTreeCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("OutlineTreeCellView")

    private let iconView = NSImageView()
    private let nameField = NSTextField(labelWithString: "")
    private let gitBadge = NSTextField(labelWithString: "")
    private let stageButton = NSButton()
    private let discardButton = NSButton()

    private var trackingArea: NSTrackingArea?
    private var isHovering = false
    private var currentNode: FileExplorerNode?

    var onStage: (() -> Void)?
    var onDiscard: (() -> Void)?
    var onCommitRename: ((String) -> Void)?
    var onCancelRename: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        // Icon
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)

        // Name
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.font = .systemFont(ofSize: 11)
        nameField.lineBreakMode = .byTruncatingTail
        nameField.maximumNumberOfLines = 1
        nameField.cell?.truncatesLastVisibleLine = true
        addSubview(nameField)
        textField = nameField

        // Git badge
        gitBadge.translatesAutoresizingMaskIntoConstraints = false
        gitBadge.font = .monospacedSystemFont(ofSize: 9, weight: .medium)
        gitBadge.alignment = .right
        gitBadge.setContentHuggingPriority(.required, for: .horizontal)
        gitBadge.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(gitBadge)

        // Stage button (+)
        stageButton.translatesAutoresizingMaskIntoConstraints = false
        stageButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Stage")
        stageButton.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        stageButton.isBordered = false
        stageButton.toolTip = "Stage Changes"
        stageButton.target = self
        stageButton.action = #selector(stageClicked)
        stageButton.isHidden = true
        addSubview(stageButton)

        // Discard button (undo arrow)
        discardButton.translatesAutoresizingMaskIntoConstraints = false
        discardButton.image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: "Discard")
        discardButton.symbolConfiguration = .init(pointSize: 9, weight: .regular)
        discardButton.isBordered = false
        discardButton.toolTip = "Discard Changes"
        discardButton.target = self
        discardButton.action = #selector(discardClicked)
        discardButton.isHidden = true
        addSubview(discardButton)

        imageView = iconView

        // Name truncates instead of pushing badge off-screen
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),

            nameField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 4),
            nameField.centerYAnchor.constraint(equalTo: centerYAnchor),

            gitBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            gitBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
            gitBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 12),

            stageButton.trailingAnchor.constraint(equalTo: gitBadge.leadingAnchor, constant: -2),
            stageButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            stageButton.widthAnchor.constraint(equalToConstant: 16),

            discardButton.trailingAnchor.constraint(equalTo: stageButton.leadingAnchor, constant: -2),
            discardButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            discardButton.widthAnchor.constraint(equalToConstant: 16),

            nameField.trailingAnchor.constraint(lessThanOrEqualTo: discardButton.leadingAnchor, constant: -4),
        ])
    }

    func configure(node: FileExplorerNode, isRenaming: Bool) {
        currentNode = node

        // Icon
        let symbolName = Self.iconName(for: node)
        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: node.name)
        iconView.contentTintColor = node.isDirectory ? .systemBlue : .secondaryLabelColor

        // Name
        if isRenaming {
            nameField.isEditable = true
            nameField.isBezeled = true
            nameField.bezelStyle = .roundedBezel
            nameField.drawsBackground = true
            nameField.backgroundColor = .textBackgroundColor
            nameField.textColor = .controlTextColor
            nameField.focusRingType = .exterior
            nameField.stringValue = node.name
            nameField.delegate = self
            nameField.target = self
            nameField.action = #selector(renameCommitted)
            // During reloadItem/reloadData the cell is NOT in the view hierarchy
            // yet, so a synchronous makeFirstResponder fails and the field never
            // gets focus — Enter/Esc/click-away then all appear dead. Defer to
            // the next runloop, and re-check isEditable in case the cell was
            // reused (scrolled away) by then.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.nameField.isEditable else { return }
                self.window?.makeFirstResponder(self.nameField)
                self.nameField.selectText(nil)
            }
        } else {
            nameField.isEditable = false
            nameField.isBezeled = false
            nameField.drawsBackground = false
            nameField.focusRingType = .default
            nameField.stringValue = node.name
            nameField.textColor = Self.gitColor(for: node.gitState) ?? .labelColor
            nameField.delegate = nil
            nameField.target = nil
            nameField.action = nil
        }

        // Git badge (files show letter code, directories show dot indicator)
        if let state = node.gitState {
            gitBadge.stringValue = node.isDirectory ? "●" : state.shortCode
            gitBadge.textColor = Self.gitColor(for: state) ?? .secondaryLabelColor
            gitBadge.isHidden = false
        } else {
            gitBadge.isHidden = true
        }

        updateHoverButtons()
    }

    // MARK: - Hover tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        updateHoverButtons()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        updateHoverButtons()
    }

    private func updateHoverButtons() {
        let showButtons = isHovering && currentNode?.gitState != nil && !(currentNode?.isDirectory ?? true)
        stageButton.isHidden = !showButtons
        discardButton.isHidden = !showButtons
    }

    // MARK: - Actions

    @objc private func stageClicked() { onStage?() }
    @objc private func discardClicked() { onDiscard?() }
    @objc private func renameCommitted() {
        let newName = nameField.stringValue
        if let node = currentNode {
            configure(node: node, isRenaming: false)
        }
        window?.makeFirstResponder(superview)
        onCommitRename?(newName)
    }

    // MARK: - Helpers

    static func iconName(for node: FileExplorerNode) -> String {
        if node.isDirectory { return "folder.fill" }
        return FileIcons.iconName(for: node.url)
    }

    static func gitColor(for state: FileGitState?) -> NSColor? {
        guard let state else { return nil }
        switch state {
        case .added: return .systemGreen
        case .modified: return .systemYellow
        case .deleted: return .systemRed
        case .renamed: return .systemBlue
        case .conflicted: return .systemPink
        }
    }
}

// MARK: - NSTextFieldDelegate (rename)

extension OutlineTreeCellView: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            if let node = currentNode {
                configure(node: node, isRenaming: false)
            }
            onCancelRename?()
            window?.makeFirstResponder(superview) // return focus to outline view
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        // Click-away commits the rename, matching Finder. Enter already commits
        // via the action selector; the isEditable guard prevents a second
        // commit after Enter flipped the field back to label mode.
        //
        // The programmatic case — reloadData pulling the field editor out from
        // under an in-progress rename, which an FSEvent burst during a build
        // triggers routinely — is detected by the cell having left the view
        // hierarchy. `currentEditor()` cannot tell the two apart: whether the
        // field editor has already resigned by the time this notification
        // arrives is not ordered by AppKit, so testing it was as likely to drop
        // every click-away rename as to admit a programmatic one.
        guard nameField.isEditable, window != nil, superview != nil else { return }
        renameCommitted()
    }
}
