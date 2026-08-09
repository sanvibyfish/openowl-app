import AppKit
import Foundation

@MainActor
extension AppDelegate {
    private func automationBindings() -> Result<(
        workspace: TerminalWorkspaceStore,
        project: ProjectStore,
        ghostty: GhosttyAppManager
    ), OpenOwlScriptFailure> {
        guard let workspaceStore else {
            return .failure(.notReady("The terminal workspace is not bound yet."))
        }
        guard let projectStore else {
            return .failure(.notReady("The project store is not bound yet."))
        }
        guard let ghosttyManager, ghosttyManager.isReady else {
            return .failure(.notReady("The terminal runtime is not ready."))
        }
        return .success((workspaceStore, projectStore, ghosttyManager))
    }

    func automationNewTab(
        configuration: TerminalSurfaceConfiguration?
    ) -> Result<UUID, OpenOwlScriptFailure> {
        switch automationBindings() {
        case .failure(let failure):
            return .failure(failure)
        case .success(let bindings):
            guard let namespace = bindings.workspace.activeNamespace else {
                return .failure(.notReady("No terminal namespace is active."))
            }
            guard case .freeTerminal = namespace else {
                return .failure(.notPermitted(
                    "New tabs are only available in a free-terminal namespace."
                ))
            }
            guard let paneID = bindings.workspace.activeFocusedPaneID,
                  let terminalView = bindings.ghostty.terminalView(for: paneID),
                  terminalView.window != nil
            else {
                return .failure(.notReady(
                    "The current terminal window is not available."
                ))
            }
            let tabID = bindings.workspace.newTab(
                makeActive: true,
                for: namespace,
                configuration: configuration
            )
            bindings.workspace.notifyContextChange()
            return .success(tabID)
        }
    }

    func automationSplit(
        paneID: UUID,
        direction: TerminalSplitDirection,
        configuration: TerminalSurfaceConfiguration?
    ) -> Result<UUID, OpenOwlScriptFailure> {
        switch automationBindings() {
        case .failure(let failure):
            return .failure(failure)
        case .success(let bindings):
            guard let location = bindings.workspace.location(of: paneID) else {
                return .failure(.unknownObject("The target terminal no longer exists."))
            }
            guard let terminalView = bindings.ghostty.terminalView(for: paneID),
                  terminalView.window != nil
            else {
                return .failure(.notReady(
                    "The target terminal window is not available."
                ))
            }
            if let failure = activate(
                location: location,
                workspace: bindings.workspace,
                project: bindings.project
            ) {
                return .failure(failure)
            }
            guard let newPaneID = bindings.workspace.split(
                paneID: paneID,
                direction: direction,
                configuration: configuration
            ) else {
                return .failure(.failed("The terminal could not be split."))
            }
            return .success(newPaneID)
        }
    }

    func automationFocus(paneID: UUID) -> Result<Void, OpenOwlScriptFailure> {
        switch automationBindings() {
        case .failure(let failure):
            return .failure(failure)
        case .success(let bindings):
            guard let location = bindings.workspace.location(of: paneID) else {
                return .failure(.unknownObject("The target terminal no longer exists."))
            }
            guard let terminalView = bindings.ghostty.terminalView(for: paneID),
                  terminalView.window != nil
            else {
                return .failure(.notReady(
                    "The target terminal window is not available."
                ))
            }
            guard bindings.ghostty.focusPane(paneID) else {
                return .failure(.notReady(
                    "The target terminal surface cannot receive focus yet."
                ))
            }
            if let failure = activate(
                location: location,
                workspace: bindings.workspace,
                project: bindings.project
            ) {
                return .failure(failure)
            }
            NSApp.activate(ignoringOtherApps: true)
            return .success(())
        }
    }

    func automationClosePane(paneID: UUID) -> Result<Void, OpenOwlScriptFailure> {
        switch automationBindings() {
        case .failure(let failure):
            return .failure(failure)
        case .success(let bindings):
            guard bindings.workspace.location(of: paneID) != nil else {
                return .failure(.unknownObject("The target terminal no longer exists."))
            }
            guard bindings.workspace.closePane(paneID) else {
                return .failure(.notPermitted(
                    "The last terminal in a tab cannot be closed by automation."
                ))
            }
            return .success(())
        }
    }

    func automationSelectTab(tabID: UUID) -> Result<Void, OpenOwlScriptFailure> {
        switch automationBindings() {
        case .failure(let failure):
            return .failure(failure)
        case .success(let bindings):
            guard let tab = bindings.workspace.tabs.first(where: { $0.id == tabID }),
                  let paneID = tab.focusedPaneID ?? tab.splitTree.firstPaneID,
                  let location = bindings.workspace.location(of: paneID)
            else {
                return .failure(.unknownObject("The target tab no longer exists."))
            }
            if let failure = activate(
                location: location,
                workspace: bindings.workspace,
                project: bindings.project
            ) {
                return .failure(failure)
            }
            return .success(())
        }
    }

    func automationCloseTab(tabID: UUID) -> Result<Void, OpenOwlScriptFailure> {
        switch automationBindings() {
        case .failure(let failure):
            return .failure(failure)
        case .success(let bindings):
            guard let tab = bindings.workspace.tabs.first(where: { $0.id == tabID }),
                  let paneID = tab.splitTree.firstPaneID,
                  let location = bindings.workspace.location(of: paneID)
            else {
                return .failure(.unknownObject("The target tab no longer exists."))
            }

            let namespaceTabCount = bindings.workspace.tabs.reduce(into: 0) { count, candidate in
                guard let candidatePaneID = candidate.splitTree.firstPaneID,
                      bindings.workspace.location(of: candidatePaneID)?.namespace == location.namespace
                else { return }
                count += 1
            }
            guard namespaceTabCount > 1 else {
                return .failure(.notPermitted(
                    "The last tab in a namespace cannot be closed by automation."
                ))
            }
            guard bindings.workspace.closeTab(id: tabID) else {
                return .failure(.failed("The tab could not be closed."))
            }
            return .success(())
        }
    }

    func automationInput(text: String, paneID: UUID) -> Result<Void, OpenOwlScriptFailure> {
        switch automationBindings() {
        case .failure(let failure):
            return .failure(failure)
        case .success(let bindings):
            guard bindings.workspace.location(of: paneID) != nil else {
                return .failure(.unknownObject("The target terminal no longer exists."))
            }
            guard let terminalView = bindings.ghostty.terminalView(for: paneID) else {
                return .failure(.notReady("The target terminal surface is not ready."))
            }
            terminalView.sendText(text)
            return .success(())
        }
    }

    private func activate(
        location: TerminalPaneLocation,
        workspace: TerminalWorkspaceStore,
        project: ProjectStore
    ) -> OpenOwlScriptFailure? {
        if workspace.activeNamespace != location.namespace {
            guard project.activate(location.namespace) else {
                return .vetoed("The terminal context change was rejected.")
            }
        }
        workspace.selectPane(location.paneID, in: location.namespace)
        return nil
    }
}
