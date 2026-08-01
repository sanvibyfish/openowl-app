import AppKit

// MARK: - Custom NSOutlineView for keyboard handling

final class KeyableOutlineView: NSOutlineView {
    var onDeleteKey: (() -> Void)?
    var onEnterKey: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117: // Backspace, Forward Delete
            onDeleteKey?()
        case 36: // Enter/Return
            onEnterKey?()
        default:
            super.keyDown(with: event)
        }
    }
}

// MARK: - OutlineTreeViewController

final class OutlineTreeViewController: NSViewController {

    // MARK: - Callbacks

    var onSelectFile: ((FileExplorerNode) -> Void)?
    var onStage: ((FileExplorerNode) -> Void)?
    var onDiscard: ((FileExplorerNode) -> Void)?
    var onOpenDiff: ((FileExplorerNode) -> Void)?
    var onDelete: (([URL]) -> Void)?
    var onRename: ((FileExplorerNode, String) -> Void)?
    var onCopy: (([URL]) -> Void)?
    var onCut: (([URL]) -> Void)?
    var onPaste: ((URL) -> Void)?
    var onRevealInFinder: ((URL) -> Void)?
    var onCopyPath: ((URL) -> Void)?
    var onDropFiles: ((URL, [URL]) -> Void)?
    var onExpandDirectory: ((String) -> Void)?

    // MARK: - Data

    private(set) var rootNodes: [FileExplorerNode] = []
    private(set) var nodeIndex: [String: FileExplorerNode] = [:]

    private var outlineView: KeyableOutlineView!
    private var scrollView: NSScrollView!
    private var renamingNodeID: String?
    /// Set to true during programmatic row selection (e.g. from updateNSViewController)
    /// to suppress the outlineViewSelectionDidChange → onSelectFile callback.
    private var isProgrammaticSelection = false

    // MARK: - Lifecycle

    override func loadView() {
        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear

        outlineView = KeyableOutlineView()
        outlineView.headerView = nil
        outlineView.allowsMultipleSelection = true
        outlineView.allowsEmptySelection = true
        outlineView.indentationPerLevel = 16
        outlineView.rowHeight = AppSpacing.listRowHeight
        outlineView.intercellSpacing = NSSize(width: 0, height: 0)
        outlineView.usesAlternatingRowBackgroundColors = false
        // Flat list (not sourceList) — sourceList paints a loud system slab
        // that fights the dock's base surface. Selection paint is custom
        // via AccentBarTableRowView (same chrome as SwiftUI session/git rows).
        outlineView.selectionHighlightStyle = .regular
        outlineView.backgroundColor = .clear
        outlineView.floatsGroupRows = false
        outlineView.autoresizesOutlineColumn = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("FileColumn"))
        column.isEditable = false
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        outlineView.dataSource = self
        outlineView.delegate = self

        outlineView.doubleAction = #selector(handleDoubleClick)
        outlineView.target = self

        // Keyboard
        outlineView.onDeleteKey = { [weak self] in self?.deleteSelectedNodes() }
        outlineView.onEnterKey = { [weak self] in self?.startRenameSelectedNode() }

        // Drag & Drop
        outlineView.registerForDraggedTypes([.fileURL])
        outlineView.setDraggingSourceOperationMask(.copy, forLocal: false)

        scrollView.documentView = outlineView
        self.view = scrollView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Initial data may have been set before loadView; apply it now
        if !rootNodes.isEmpty {
            outlineView.reloadData()
        }
    }

    // MARK: - Public API

    func updateData(rootNodes: [FileExplorerNode], nodeIndex: [String: FileExplorerNode]) {
        self.rootNodes = rootNodes
        self.nodeIndex = nodeIndex

        guard outlineView != nil else { return }

        let expandedPaths = saveExpandedState()
        let selectedPaths = saveSelectedState()

        // Suppress outlineViewSelectionDidChange during the entire reload+restore
        // cycle to avoid modifying SwiftUI @State during a view update.
        isProgrammaticSelection = true
        defer { isProgrammaticSelection = false }

        outlineView.reloadData()
        restoreExpandedState(expandedPaths)
        restoreSelectedState(selectedPaths)
    }

    func selectAndReveal(nodeID: String) {
        guard outlineView != nil else { return }
        expandParents(of: nodeID)

        let row = outlineView.row(forItem: nodeID as NSString)
        guard row >= 0 else { return }
        isProgrammaticSelection = true
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        isProgrammaticSelection = false
        outlineView.scrollRowToVisible(row)
    }

    /// Update local data snapshot without reloading the outline view.
    /// Called synchronously from the onExpandDirectory callback so NSOutlineView
    /// can query the updated nodeIndex during the same expand cycle.
    func syncData(rootNodes: [FileExplorerNode], nodeIndex: [String: FileExplorerNode]) {
        self.rootNodes = rootNodes
        self.nodeIndex = nodeIndex
    }

    func expandTopLevel() {
        guard outlineView != nil else { return }
        for node in rootNodes where node.isDirectory {
            outlineView.expandItem(node.id as NSString, expandChildren: false)
        }
    }

    // MARK: - State Save/Restore

    private func saveExpandedState() -> Set<String> {
        var expanded = Set<String>()
        for row in 0..<outlineView.numberOfRows {
            if let item = outlineView.item(atRow: row) as? NSString,
               outlineView.isItemExpanded(item) {
                expanded.insert(item as String)
            }
        }
        return expanded
    }

    private func restoreExpandedState(_ paths: Set<String>) {
        for path in paths {
            outlineView.expandItem(path as NSString, expandChildren: false)
        }
    }

    private func saveSelectedState() -> Set<String> {
        var selected = Set<String>()
        for row in outlineView.selectedRowIndexes {
            if let item = outlineView.item(atRow: row) as? NSString {
                selected.insert(item as String)
            }
        }
        return selected
    }

    private func restoreSelectedState(_ paths: Set<String>) {
        var indices = IndexSet()
        for path in paths {
            let row = outlineView.row(forItem: path as NSString)
            if row >= 0 { indices.insert(row) }
        }
        if !indices.isEmpty {
            // isProgrammaticSelection is already set by the caller (updateData)
            outlineView.selectRowIndexes(indices, byExtendingSelection: false)
        }
    }

    private func expandParents(of nodeID: String) {
        // Walk up via URL path components
        var url = URL(fileURLWithPath: nodeID)
        var ancestors: [String] = []
        while true {
            let parent = url.deletingLastPathComponent()
            let parentPath = parent.standardizedFileURL.path
            guard nodeIndex[parentPath] != nil else { break }
            ancestors.append(parentPath)
            url = parent
        }
        // Expand from root down
        for path in ancestors.reversed() {
            outlineView.expandItem(path as NSString, expandChildren: false)
        }
    }

    // MARK: - Actions

    @objc private func handleDoubleClick() {
        let row = outlineView.clickedRow
        guard row >= 0, let item = outlineView.item(atRow: row) as? NSString else { return }
        let path = item as String
        guard let node = nodeIndex[path] else { return }

        if node.isDirectory {
            if outlineView.isItemExpanded(item) {
                outlineView.collapseItem(item)
            } else {
                outlineView.expandItem(item)
            }
        } else {
            onSelectFile?(node)
        }
    }

    private func deleteSelectedNodes() {
        let urls = selectedNodeURLs()
        guard !urls.isEmpty else { return }
        onDelete?(urls)
    }

    private func startRenameSelectedNode() {
        guard outlineView.selectedRowIndexes.count == 1 else { return }
        let row = outlineView.selectedRow
        guard let item = outlineView.item(atRow: row) as? NSString,
              let node = nodeIndex[item as String] else { return }
        renamingNodeID = node.id
        outlineView.reloadItem(item)
    }

    private func selectedNodeURLs() -> [URL] {
        outlineView.selectedRowIndexes.compactMap { row in
            guard let item = outlineView.item(atRow: row) as? NSString,
                  let node = nodeIndex[item as String] else { return nil }
            return node.url
        }
    }

    private func selectedNodes() -> [FileExplorerNode] {
        outlineView.selectedRowIndexes.compactMap { row in
            guard let item = outlineView.item(atRow: row) as? NSString else { return nil }
            return nodeIndex[item as String]
        }
    }

    // MARK: - Context Menu

    private func buildContextMenu(for node: FileExplorerNode) -> NSMenu {
        let menu = NSMenu()
        let isChangedFile = !node.isDirectory && node.gitState != nil
        let selectedCount = outlineView.selectedRowIndexes.count

        menu.addItem(withTitle: "Reveal in Finder", action: #selector(contextRevealInFinder(_:)), keyEquivalent: "")
            .representedObject = node
        menu.addItem(.separator())

        menu.addItem(withTitle: "Cut", action: #selector(contextCut(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Copy", action: #selector(contextCopy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Paste", action: #selector(contextPaste(_:)), keyEquivalent: "")
            .representedObject = node
        menu.addItem(withTitle: "Copy Path", action: #selector(contextCopyPath(_:)), keyEquivalent: "")
            .representedObject = node
        menu.addItem(.separator())

        menu.addItem(withTitle: "Rename", action: #selector(contextRename(_:)), keyEquivalent: "")
            .representedObject = node
        let deleteItem = menu.addItem(withTitle: "Delete", action: #selector(contextDelete(_:)), keyEquivalent: "")
        deleteItem.representedObject = node

        if isChangedFile {
            menu.addItem(.separator())
            menu.addItem(withTitle: "Open Changes", action: #selector(contextOpenDiff(_:)), keyEquivalent: "")
                .representedObject = node

            let stageTitle = selectedCount > 1 ? "Stage \(selectedCount) Files" : "Stage Changes"
            menu.addItem(withTitle: stageTitle, action: #selector(contextStage(_:)), keyEquivalent: "")
                .representedObject = node

            let discardTitle = selectedCount > 1 ? "Discard \(selectedCount) Files" : "Discard Changes"
            menu.addItem(withTitle: discardTitle, action: #selector(contextDiscard(_:)), keyEquivalent: "")
                .representedObject = node
        }

        for item in menu.items {
            item.target = self
        }

        return menu
    }

    @objc private func contextRevealInFinder(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? FileExplorerNode else { return }
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }

    @objc private func contextCut(_ sender: NSMenuItem) {
        onCut?(selectedNodeURLs())
    }

    @objc private func contextCopy(_ sender: NSMenuItem) {
        onCopy?(selectedNodeURLs())
    }

    @objc private func contextPaste(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? FileExplorerNode else { return }
        let targetDir = node.isDirectory ? node.url : node.url.deletingLastPathComponent()
        onPaste?(targetDir)
    }

    @objc private func contextCopyPath(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? FileExplorerNode else { return }
        onCopyPath?(node.url)
    }

    @objc private func contextRename(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? FileExplorerNode else { return }
        renamingNodeID = node.id
        let row = outlineView.row(forItem: node.id as NSString)
        if row >= 0 {
            outlineView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
        }
    }

    @objc private func contextDelete(_ sender: NSMenuItem) {
        deleteSelectedNodes()
    }

    @objc private func contextOpenDiff(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? FileExplorerNode else { return }
        onOpenDiff?(node)
    }

    @objc private func contextStage(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? FileExplorerNode else { return }
        onStage?(node)
    }

    @objc private func contextDiscard(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? FileExplorerNode else { return }
        onDiscard?(node)
    }
}

// MARK: - NSOutlineViewDataSource

extension OutlineTreeViewController: NSOutlineViewDataSource {

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item = item as? NSString else {
            return rootNodes.count
        }
        let path = item as String
        return nodeIndex[path]?.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let item = item as? NSString {
            let path = item as String
            if let children = nodeIndex[path]?.children, index < children.count {
                return children[index].id as NSString
            }
            return "" as NSString
        }
        guard index < rootNodes.count else { return "" as NSString }
        return rootNodes[index].id as NSString
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let item = item as? NSString else { return false }
        return nodeIndex[item as String]?.isDirectory ?? false
    }

    // MARK: Drag source

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        guard let item = item as? NSString,
              let node = nodeIndex[item as String] else { return nil }
        return node.url as NSURL
    }

    // MARK: Drop target

    func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: any NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        // Only accept drops onto directories
        guard let item = item as? NSString,
              let node = nodeIndex[item as String],
              node.isDirectory else {
            return []
        }
        return .copy
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        acceptDrop info: any NSDraggingInfo,
        item: Any?,
        childIndex index: Int
    ) -> Bool {
        guard let item = item as? NSString,
              let targetNode = nodeIndex[item as String],
              targetNode.isDirectory else { return false }

        let pasteboard = info.draggingPasteboard
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL], !urls.isEmpty else { return false }

        onDropFiles?(targetNode.url, urls)
        return true
    }
}

// MARK: - NSOutlineViewDelegate

extension OutlineTreeViewController: NSOutlineViewDelegate {

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? NSString,
              let node = nodeIndex[item as String] else { return nil }

        let cell: OutlineTreeCellView
        if let reused = outlineView.makeView(withIdentifier: OutlineTreeCellView.identifier, owner: self) as? OutlineTreeCellView {
            cell = reused
        } else {
            cell = OutlineTreeCellView(frame: .zero)
            cell.identifier = OutlineTreeCellView.identifier
        }

        let isRenaming = renamingNodeID == node.id
        cell.configure(node: node, isRenaming: isRenaming)

        cell.onStage = { [weak self] in self?.onStage?(node) }
        cell.onDiscard = { [weak self] in self?.onDiscard?(node) }
        cell.onCommitRename = { [weak self] newName in
            self?.renamingNodeID = nil
            self?.onRename?(node, newName)
        }
        cell.onCancelRename = { [weak self] in
            self?.renamingNodeID = nil
        }

        return cell
    }

    /// Custom row so selection matches SwiftUI `selectableRowChrome` (accent bar
    /// + soft fill) instead of the system blue slab.
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        if let reused = outlineView.makeView(
            withIdentifier: AccentBarTableRowView.reuseIdentifier,
            owner: self
        ) as? AccentBarTableRowView {
            return reused
        }
        let row = AccentBarTableRowView()
        row.identifier = AccentBarTableRowView.reuseIdentifier
        return row
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        AppSpacing.listRowHeight
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        // Ignore programmatic selections (e.g. from updateNSViewController / selectAndReveal)
        // to avoid modifying SwiftUI @State during a view update cycle.
        guard !isProgrammaticSelection else { return }
        guard let outlineView = notification.object as? NSOutlineView else { return }
        let row = outlineView.selectedRow
        guard row >= 0,
              let item = outlineView.item(atRow: row) as? NSString,
              let node = nodeIndex[item as String] else { return }

        onSelectFile?(node)
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        true
    }

    func outlineViewItemWillExpand(_ notification: Notification) {
        guard let item = notification.userInfo?["NSObject"] as? NSString else { return }
        let path = item as String
        if let node = nodeIndex[path], node.isDirectory, node.children == nil {
            // Lazy load: scan this directory's children
            onExpandDirectory?(path)
        }
    }

    // Context menu
    func outlineView(_ outlineView: NSOutlineView, menuForItem item: Any) -> NSMenu? {
        // NSOutlineView doesn't have a built-in menuForItem delegate,
        // so we handle it via the menu delegate approach below
        return nil
    }
}

// MARK: - NSMenuDelegate for right-click

extension OutlineTreeViewController {
    override func viewDidAppear() {
        super.viewDidAppear()
        // Resize the outline column to fill the scroll view now that the view has its final frame.
        // On initial load, reloadData() may run before SwiftUI sets the view frame, causing
        // Auto Layout to position the gitBadge at the wrong (zero-width) trailing edge.
        outlineView.sizeLastColumnToFit()
        // Set up context menu
        outlineView.menu = NSMenu()
        outlineView.menu?.delegate = self
    }
}

extension OutlineTreeViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let clickedRow = outlineView.clickedRow
        guard clickedRow >= 0,
              let item = outlineView.item(atRow: clickedRow) as? NSString,
              let node = nodeIndex[item as String] else { return }

        // If clicked row isn't in selection, select it.
        // Suppress selectionDidChange → onSelectFile so right-clicking a file
        // does not auto-load it into the editor (and pin its NSTextStorage in
        // tabStorages, growing memory with every right-click).
        if !outlineView.selectedRowIndexes.contains(clickedRow) {
            isProgrammaticSelection = true
            outlineView.selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
            isProgrammaticSelection = false
        }

        let contextMenu = buildContextMenu(for: node)
        for item in contextMenu.items {
            contextMenu.removeItem(item)
            menu.addItem(item)
        }
    }
}
