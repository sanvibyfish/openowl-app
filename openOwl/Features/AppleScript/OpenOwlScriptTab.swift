import AppKit
import Foundation

@MainActor
@objc(OpenOwlScriptTab)
final class OpenOwlScriptTab: NSObject {
    let stableID: String
    private let tabID: UUID
    private let window: OpenOwlScriptWindow
    private weak var workspaceStore: TerminalWorkspaceStore?

    init(
        window: OpenOwlScriptWindow,
        workspaceStore: TerminalWorkspaceStore,
        tabID: UUID
    ) {
        self.stableID = tabID.uuidString
        self.tabID = tabID
        self.window = window
        self.workspaceStore = workspaceStore
        super.init()
    }

    @objc(id)
    var idValue: String { stableID }

    @objc(title)
    var title: String {
        workspaceStore?.tabs.first(where: { $0.id == tabID })?.title ?? ""
    }

    @objc(index)
    var index: Int {
        guard let workspaceStore,
              let index = workspaceStore.visibleTabs.firstIndex(where: { $0.id == tabID })
        else { return 0 }
        return index + 1
    }

    @objc(selected)
    var selected: Bool { workspaceStore?.activeTabID == tabID }

    @objc(focusedTerminal)
    var focusedTerminal: OpenOwlScriptTerminal? {
        guard let workspaceStore,
              let tab = workspaceStore.tabs.first(where: { $0.id == tabID }),
              let paneID = tab.focusedPaneID ?? tab.splitTree.firstPaneID
        else { return nil }
        return OpenOwlScriptTerminal(workspaceStore: workspaceStore, paneID: paneID)
    }

    @objc(terminals)
    var terminals: [OpenOwlScriptTerminal] {
        guard let workspaceStore,
              let tab = workspaceStore.tabs.first(where: { $0.id == tabID })
        else { return [] }
        return tab.splitTree.allPaneIDs.map {
            OpenOwlScriptTerminal(workspaceStore: workspaceStore, paneID: $0)
        }
    }

    @objc(valueInTerminalsWithUniqueID:)
    func valueInTerminals(uniqueID: String) -> OpenOwlScriptTerminal? {
        guard let workspaceStore,
              let paneID = UUID(uuidString: uniqueID),
              let tab = workspaceStore.tabs.first(where: { $0.id == tabID }),
              tab.splitTree.containsPane(paneID)
        else { return nil }
        return OpenOwlScriptTerminal(workspaceStore: workspaceStore, paneID: paneID)
    }

    @objc(handleSelectTabCommand:)
    func handleSelectTab(_ command: NSScriptCommand) -> Any? {
        guard let appDelegate = OpenOwlScriptRuntime.appDelegate else {
            command.fail(with: .notReady("The openOwl app delegate is unavailable."))
            return nil
        }
        if case .failure(let failure) = appDelegate.automationSelectTab(tabID: tabID) {
            command.fail(with: failure)
        }
        return nil
    }

    @objc(handleCloseTabCommand:)
    func handleCloseTab(_ command: NSScriptCommand) -> Any? {
        guard let appDelegate = OpenOwlScriptRuntime.appDelegate else {
            command.fail(with: .notReady("The openOwl app delegate is unavailable."))
            return nil
        }
        if case .failure(let failure) = appDelegate.automationCloseTab(tabID: tabID) {
            command.fail(with: failure)
        }
        return nil
    }

    override var objectSpecifier: NSScriptObjectSpecifier? {
        guard let classDescription = OpenOwlScriptRuntime.classDescription(
            for: OpenOwlScriptRuntime.windowClassCode
        ),
              let windowSpecifier = window.objectSpecifier
        else { return nil }
        return NSUniqueIDSpecifier(
            containerClassDescription: classDescription,
            containerSpecifier: windowSpecifier,
            key: "tabs",
            uniqueID: stableID
        )
    }
}
