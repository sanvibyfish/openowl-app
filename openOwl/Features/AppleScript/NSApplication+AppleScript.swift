import AppKit
import Foundation

@MainActor
extension NSApplication {
    @objc(scriptWindows)
    var scriptWindows: [OpenOwlScriptWindow] {
        guard let appDelegate = OpenOwlScriptRuntime.appDelegate,
              let workspaceStore = appDelegate.workspaceStore
        else { return [] }
        return [OpenOwlScriptWindow(workspaceStore: workspaceStore)]
    }

    @objc(frontWindow)
    var frontWindow: OpenOwlScriptWindow? {
        scriptWindows.first
    }

    @objc(valueInScriptWindowsWithUniqueID:)
    func valueInScriptWindows(uniqueID: String) -> OpenOwlScriptWindow? {
        guard uniqueID == "main" else { return nil }
        return scriptWindows.first
    }

    @objc(terminals)
    var terminals: [OpenOwlScriptTerminal] {
        guard let appDelegate = OpenOwlScriptRuntime.appDelegate,
              let workspaceStore = appDelegate.workspaceStore
        else { return [] }
        return workspaceStore.tabs.flatMap { tab in
            tab.splitTree.allPaneIDs.map {
                OpenOwlScriptTerminal(workspaceStore: workspaceStore, paneID: $0)
            }
        }
    }

    @objc(valueInTerminalsWithUniqueID:)
    func valueInTerminals(uniqueID: String) -> OpenOwlScriptTerminal? {
        guard let appDelegate = OpenOwlScriptRuntime.appDelegate,
              let workspaceStore = appDelegate.workspaceStore,
              let paneID = UUID(uuidString: uniqueID),
              workspaceStore.location(of: paneID) != nil
        else { return nil }
        return OpenOwlScriptTerminal(workspaceStore: workspaceStore, paneID: paneID)
    }

    @objc(handleNewSurfaceConfigurationScriptCommand:)
    func handleNewSurfaceConfigurationScriptCommand(_ command: NSScriptCommand) -> NSDictionary? {
        let rawConfiguration = command.evaluatedArguments?["configuration"]
        if rawConfiguration != nil, !(rawConfiguration is NSDictionary) {
            command.failParameter("Surface configuration must be a record.")
            return nil
        }
        do {
            return try TerminalSurfaceConfiguration(
                scriptRecord: rawConfiguration as? NSDictionary
            ).scriptDictionaryRepresentation
        } catch {
            command.failParameter(error.localizedDescription)
            return nil
        }
    }

    @objc(handleNewTabScriptCommand:)
    func handleNewTabScriptCommand(_ command: NSScriptCommand) -> OpenOwlScriptTab? {
        guard let appDelegate = OpenOwlScriptRuntime.appDelegate,
              let workspaceStore = appDelegate.workspaceStore
        else {
            command.fail(with: .notReady("The openOwl app delegate and workspace are not bound yet."))
            return nil
        }

        if let rawWindow = command.evaluatedArguments?["window"] {
            guard let window = rawWindow as? OpenOwlScriptWindow, window.stableID == "main" else {
                command.fail(with: .unknownObject("The target window does not exist."))
                return nil
            }
        }

        let configuration: TerminalSurfaceConfiguration?
        if let rawConfiguration = command.evaluatedArguments?["configuration"] {
            guard let record = rawConfiguration as? NSDictionary else {
                command.failParameter("Surface configuration must be a record.")
                return nil
            }
            do {
                configuration = try TerminalSurfaceConfiguration(scriptRecord: record)
            } catch {
                command.failParameter(error.localizedDescription)
                return nil
            }
        } else {
            configuration = nil
        }

        switch appDelegate.automationNewTab(configuration: configuration) {
        case .success(let tabID):
            guard let window = frontWindow else {
                command.fail(with: .notReady("The openOwl scripting window is unavailable."))
                return nil
            }
            return OpenOwlScriptTab(window: window, workspaceStore: workspaceStore, tabID: tabID)
        case .failure(let failure):
            command.fail(with: failure)
            return nil
        }
    }
}
