import AppKit
import Foundation

@MainActor
@objc(OpenOwlScriptTerminal)
final class OpenOwlScriptTerminal: NSObject {
    let paneID: UUID
    private weak var workspaceStore: TerminalWorkspaceStore?

    init(workspaceStore: TerminalWorkspaceStore, paneID: UUID) {
        self.workspaceStore = workspaceStore
        self.paneID = paneID
        super.init()
    }

    @objc(id)
    var stableID: String { paneID.uuidString }

    @objc(title)
    var title: String {
        guard let workspaceStore,
              let location = workspaceStore.location(of: paneID),
              let tab = workspaceStore.tabs.first(where: { $0.id == location.tabID })
        else { return "" }
        return workspaceStore.paneTitles[paneID] ?? tab.title
    }

    @objc(workingDirectory)
    var workingDirectory: String {
        workspaceStore?.panePwds[paneID] ?? ""
    }

    @objc(handleSplitCommand:)
    func handleSplit(_ command: NSScriptCommand) -> Any? {
        guard let rawDirection = command.evaluatedArguments?["direction"] else {
            command.failParameter("Missing split direction.", missing: true)
            return nil
        }
        guard let directionCode = Self.directionCode(from: rawDirection),
              let direction = OpenOwlScriptSplitDirection(code: directionCode)
        else {
            command.failParameter("Unknown split direction.")
            return nil
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

        guard let appDelegate = OpenOwlScriptRuntime.appDelegate else {
            command.fail(with: .notReady("The openOwl app delegate is unavailable."))
            return nil
        }
        switch appDelegate.automationSplit(
            paneID: paneID,
            direction: direction.terminalDirection,
            configuration: configuration
        ) {
        case .success(let newPaneID):
            guard let workspaceStore else {
                command.fail(with: .notReady("The terminal workspace is unavailable."))
                return nil
            }
            return OpenOwlScriptTerminal(workspaceStore: workspaceStore, paneID: newPaneID)
        case .failure(let failure):
            command.fail(with: failure)
            return nil
        }
    }

    @objc(handleFocusCommand:)
    func handleFocus(_ command: NSScriptCommand) -> Any? {
        guard let appDelegate = OpenOwlScriptRuntime.appDelegate else {
            command.fail(with: .notReady("The openOwl app delegate is unavailable."))
            return nil
        }
        if case .failure(let failure) = appDelegate.automationFocus(paneID: paneID) {
            command.fail(with: failure)
        }
        return nil
    }

    @objc(handleCloseCommand:)
    func handleClose(_ command: NSScriptCommand) -> Any? {
        guard let appDelegate = OpenOwlScriptRuntime.appDelegate else {
            command.fail(with: .notReady("The openOwl app delegate is unavailable."))
            return nil
        }
        if case .failure(let failure) = appDelegate.automationClosePane(paneID: paneID) {
            command.fail(with: failure)
        }
        return nil
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
            key: "terminals",
            uniqueID: stableID
        )
    }

    private static func directionCode(from value: Any?) -> UInt32? {
        if let code = value as? UInt32 { return code }
        return (value as? NSNumber)?.uint32Value
    }
}
