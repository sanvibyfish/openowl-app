import AppKit
import Foundation

@MainActor
@objc(OpenOwlScriptWindow)
final class OpenOwlScriptWindow: NSObject {
    let stableID = "main"
    private weak var workspaceStore: TerminalWorkspaceStore?

    init(workspaceStore: TerminalWorkspaceStore) {
        self.workspaceStore = workspaceStore
        super.init()
    }

    @objc(id)
    var idValue: String { stableID }

    @objc(title)
    var title: String {
        guard let workspaceStore,
              workspaceStore.activeNamespace != nil,
              let activeTabID = workspaceStore.activeTabID,
              let tab = workspaceStore.tabs.first(where: { $0.id == activeTabID })
        else { return "" }
        return tab.title
    }

    @objc(tabs)
    var tabs: [OpenOwlScriptTab] {
        guard let workspaceStore else { return [] }
        return activeNamespaceTabs.map {
            OpenOwlScriptTab(window: self, workspaceStore: workspaceStore, tabID: $0.id)
        }
    }

    @objc(selectedTab)
    var selectedTab: OpenOwlScriptTab? {
        guard let workspaceStore,
              let tabID = workspaceStore.activeTabID,
              activeNamespaceTabs.contains(where: { $0.id == tabID })
        else { return nil }
        return OpenOwlScriptTab(window: self, workspaceStore: workspaceStore, tabID: tabID)
    }

    @objc(valueInTabsWithUniqueID:)
    func valueInTabs(uniqueID: String) -> OpenOwlScriptTab? {
        guard let workspaceStore,
              let tabID = UUID(uuidString: uniqueID),
              activeNamespaceTabs.contains(where: { $0.id == tabID })
        else { return nil }
        return OpenOwlScriptTab(window: self, workspaceStore: workspaceStore, tabID: tabID)
    }

    @objc(terminals)
    var terminals: [OpenOwlScriptTerminal] {
        guard let workspaceStore else { return [] }
        return activeNamespaceTabs.flatMap { tab in
            tab.splitTree.allPaneIDs.map {
                OpenOwlScriptTerminal(workspaceStore: workspaceStore, paneID: $0)
            }
        }
    }

    @objc(valueInTerminalsWithUniqueID:)
    func valueInTerminals(uniqueID: String) -> OpenOwlScriptTerminal? {
        guard let workspaceStore,
              let paneID = UUID(uuidString: uniqueID),
              activeNamespaceTabs.contains(where: { $0.splitTree.containsPane(paneID) })
        else { return nil }
        return OpenOwlScriptTerminal(workspaceStore: workspaceStore, paneID: paneID)
    }

    private var activeNamespaceTabs: [TerminalTabState] {
        guard let workspaceStore, workspaceStore.activeNamespace != nil else { return [] }
        return workspaceStore.visibleTabs
    }

    override var objectSpecifier: NSScriptObjectSpecifier? {
        guard let classDescription = OpenOwlScriptRuntime.classDescription(
            for: OpenOwlScriptRuntime.applicationClassCode
        ) else {
            return nil
        }
        return NSUniqueIDSpecifier(
            containerClassDescription: classDescription,
            containerSpecifier: nil,
            key: "scriptWindows",
            uniqueID: stableID
        )
    }
}
