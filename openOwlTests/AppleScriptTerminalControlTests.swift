import AppKit
import Foundation
import Testing
@testable import openOwl

@Suite("Terminal AppleScript control contract")
struct AppleScriptTerminalControlTests {
    @Test @MainActor func bundleDeclaresScriptingDefinition() {
        let bundle = Bundle(for: AppDelegate.self)

        #expect(bundle.object(forInfoDictionaryKey: "NSAppleScriptEnabled") as? Bool == true)
        #expect(bundle.object(forInfoDictionaryKey: "OSAScriptingDefinition") as? String == "openOwl.sdef")
        #expect(bundle.url(forResource: "openOwl", withExtension: "sdef") != nil)
    }

    @Test @MainActor func applicationRuntimeExposesScriptingSelectors() {
        let application = NSApplication.shared
        let selectorNames = [
            "scriptWindows",
            "frontWindow",
            "terminals",
            "valueInTerminalsWithUniqueID:",
        ]

        for selectorName in selectorNames {
            #expect(application.responds(to: NSSelectorFromString(selectorName)))
        }
    }

    @Test @MainActor func scriptingWrappersExposeStableUniqueIDSpecifiers() throws {
        let store = TerminalWorkspaceStore()
        let namespace: TerminalNamespace = .freeTerminal(UUID())
        store.switchNamespace(namespace)
        let tabID = try #require(store.activeTabID)
        let paneID = try #require(store.activeFocusedPaneID)

        let window = OpenOwlScriptWindow(workspaceStore: store)
        let tab = OpenOwlScriptTab(window: window, workspaceStore: store, tabID: tabID)
        let terminal = OpenOwlScriptTerminal(workspaceStore: store, paneID: paneID)
        let cases: [(NSScriptObjectSpecifier?, String)] = [
            (window.objectSpecifier, window.stableID),
            (tab.objectSpecifier, tab.stableID),
            (terminal.objectSpecifier, terminal.stableID),
        ]

        for (specifier, stableID) in cases {
            let uniqueIDSpecifier = specifier as? NSUniqueIDSpecifier
            #expect(uniqueIDSpecifier != nil)
            #expect(uniqueIDSpecifier?.uniqueID as? String == stableID)
        }
    }

    @Test @MainActor func splitTargetedPaneSupportsEveryDirection() throws {
        let cases: [(TerminalSplitDirection, TerminalSplitAxis, Bool)] = [
            (.left, .horizontal, true),
            (.right, .horizontal, false),
            (.up, .vertical, true),
            (.down, .vertical, false),
        ]

        for (direction, expectedAxis, newPaneFirst) in cases {
            let store = TerminalWorkspaceStore()
            let namespace: TerminalNamespace = .freeTerminal(UUID())
            store.switchNamespace(namespace)
            let targetPane = try #require(store.activeFocusedPaneID)

            let newPane = try #require(store.split(paneID: targetPane, direction: direction))
            let tab = try #require(store.tabs.first)

            guard case .split(let axis, _, let first, let second) = tab.splitTree else {
                Issue.record("Expected a split root")
                continue
            }
            #expect(axis == expectedAxis)
            #expect(first.firstPaneID == (newPaneFirst ? newPane : targetPane))
            #expect(second.firstPaneID == (newPaneFirst ? targetPane : newPane))
            #expect(tab.focusedPaneID == newPane)
        }
    }

    @Test @MainActor func splitRecordsLaunchConfigurationBeforeSurfaceCreation() throws {
        let store = TerminalWorkspaceStore()
        let namespace: TerminalNamespace = .freeTerminal(UUID())
        store.switchNamespace(namespace)
        let targetPane = try #require(store.activeFocusedPaneID)
        let configuration = TerminalSurfaceConfiguration(
            workingDirectory: "/tmp/project",
            command: "claude",
            initialInput: "status",
            waitAfterCommand: true,
            environmentVariables: ["OPENOWL_TEAM=review"],
            fontSize: 14
        )

        let newPane = try #require(store.split(
            paneID: targetPane,
            direction: .right,
            configuration: configuration
        ))

        #expect(store.launchConfiguration(for: newPane) == configuration)
    }

    @Test @MainActor func splitInheritsReportedTargetPwdUnlessConfigurationOverrides() throws {
        let store = TerminalWorkspaceStore()
        let namespace: TerminalNamespace = .freeTerminal(UUID())
        store.switchNamespace(namespace)
        let targetPane = try #require(store.activeFocusedPaneID)
        store.updatePanePwd(paneID: targetPane, pwd: "/tmp/reported-target")

        let inheritedPane = try #require(store.split(
            paneID: targetPane,
            direction: .right,
            configuration: TerminalSurfaceConfiguration(command: "claude")
        ))
        #expect(store.launchConfiguration(for: inheritedPane)?.workingDirectory == "/tmp/reported-target")

        let explicitPane = try #require(store.split(
            paneID: targetPane,
            direction: .down,
            configuration: TerminalSurfaceConfiguration(
                workingDirectory: "/tmp/explicit-target",
                command: "claude"
            )
        ))
        #expect(store.launchConfiguration(for: explicitPane)?.workingDirectory == "/tmp/explicit-target")
    }

    @Test @MainActor func splitUnknownPaneFailsWithoutMutation() {
        let store = TerminalWorkspaceStore()
        let namespace: TerminalNamespace = .freeTerminal(UUID())
        store.switchNamespace(namespace)
        let originalTabs = store.tabs

        #expect(store.split(paneID: UUID(), direction: .right) == nil)
        #expect(store.tabs == originalTabs)
    }

    @Test @MainActor func locationAndTargetedFocusResolveStablePaneIdentity() throws {
        let store = TerminalWorkspaceStore()
        let firstNamespace: TerminalNamespace = .freeTerminal(UUID())
        let secondNamespace: TerminalNamespace = .project("project-B")
        store.switchNamespace(firstNamespace)
        store.switchNamespace(secondNamespace)
        let secondPane = try #require(store.activeFocusedPaneID)
        let secondTab = try #require(store.activeTabID)
        store.switchNamespace(firstNamespace)

        let location = try #require(store.location(of: secondPane))
        #expect(location.namespace == secondNamespace)
        #expect(location.tabID == secondTab)

        store.selectPane(secondPane, in: secondNamespace)
        #expect(store.activeNamespace == secondNamespace)
        #expect(store.activeTabID == secondTab)
        #expect(store.activeFocusedPaneID == secondPane)
    }

    @Test @MainActor func closeTargetedPaneCleansStateAndDestroysSurfaceOnce() throws {
        let store = TerminalWorkspaceStore()
        let namespace: TerminalNamespace = .freeTerminal(UUID())
        store.switchNamespace(namespace)
        let originalPane = try #require(store.activeFocusedPaneID)
        let configuration = TerminalSurfaceConfiguration(command: "claude")
        let newPane = try #require(store.split(
            paneID: originalPane,
            direction: .right,
            configuration: configuration
        ))
        store.updateTitle(for: newPane, title: "Agent")
        store.updatePanePwd(paneID: newPane, pwd: "/tmp/project")
        var destroyed: [UUID] = []
        store.destroyPaneHandler = { destroyed.append($0) }

        #expect(store.closePane(newPane))
        #expect(store.paneInfos(for: namespace).map(\.paneID) == [originalPane])
        #expect(store.launchConfiguration(for: newPane) == nil)
        #expect(destroyed == [newPane])
        #expect(store.closePane(UUID()) == false)
        #expect(destroyed == [newPane])
    }

    @Test @MainActor func closeFocusedActivePaneNotifiesContextButClosingBackgroundDoesNot() async throws {
        let activeStore = TerminalWorkspaceStore()
        let activeNamespace: TerminalNamespace = .freeTerminal(UUID())
        activeStore.switchNamespace(activeNamespace)
        let neighborPane = try #require(activeStore.activeFocusedPaneID)
        activeStore.updatePanePwd(paneID: neighborPane, pwd: "/tmp/neighbor")
        let focusedPane = try #require(activeStore.split(
            paneID: neighborPane,
            direction: .right
        ))
        activeStore.updatePanePwd(paneID: focusedPane, pwd: "/tmp/focused")
        var activeContextChanges = 0
        activeStore.onContextDidChange = { activeContextChanges += 1 }

        #expect(activeStore.closePane(focusedPane))
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(activeContextChanges == 1)
        #expect(activeStore.activeFocusedPaneID == neighborPane)
        #expect(activeStore.activePaneWorkingDirectory?.path == "/tmp/neighbor")

        let backgroundStore = TerminalWorkspaceStore()
        let backgroundNamespace: TerminalNamespace = .freeTerminal(UUID())
        backgroundStore.switchNamespace(backgroundNamespace)
        let backgroundPane = try #require(backgroundStore.activeFocusedPaneID)
        backgroundStore.updatePanePwd(paneID: backgroundPane, pwd: "/tmp/background")
        let stillFocusedPane = try #require(backgroundStore.split(
            paneID: backgroundPane,
            direction: .right
        ))
        backgroundStore.updatePanePwd(paneID: stillFocusedPane, pwd: "/tmp/still-focused")
        var backgroundContextChanges = 0
        backgroundStore.onContextDidChange = { backgroundContextChanges += 1 }

        #expect(backgroundStore.closePane(backgroundPane))
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(backgroundContextChanges == 0)
        #expect(backgroundStore.activeFocusedPaneID == stillFocusedPane)
        #expect(backgroundStore.activePaneWorkingDirectory?.path == "/tmp/still-focused")
    }

    @Test func surfaceConfigurationParserValidatesFontSizeBoundaries() throws {
        let minimum = try TerminalSurfaceConfiguration(
            scriptRecord: ["fontSize": 1] as NSDictionary
        )
        let maximum = try TerminalSurfaceConfiguration(
            scriptRecord: ["fontSize": 255] as NSDictionary
        )

        #expect(minimum.fontSize == 1)
        #expect(maximum.fontSize == 255)
        #expect(configurationParsingFails(["fontSize": 256]))
        #expect(configurationParsingFails(["fontSize": Double.greatestFiniteMagnitude]))
    }

    @Test func surfaceConfigurationParserRejectsNulInCStringFields() {
        let cases: [[String: Any]] = [
            ["workingDirectory": "/tmp/project\0child"],
            ["command": "printf\0ignored"],
            ["initialInput": "status\0ignored"],
            ["environmentVariables": ["OPENOWL_TEAM=review\0ignored"]],
        ]

        for record in cases {
            #expect(configurationParsingFails(record))
        }
    }

    @Test func surfaceConfigurationParserValidatesWorkingDirectory() throws {
        let existingDirectory = FileManager.default.temporaryDirectory.path
        let missingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openowl-missing-\(UUID().uuidString)", isDirectory: true)
            .path

        #expect(configurationParsingFails(["workingDirectory": "relative/path"]))
        #expect(configurationParsingFails(["workingDirectory": missingDirectory]))
        #expect(configurationParsingFails(["workingDirectory": #filePath]))

        let configuration = try TerminalSurfaceConfiguration(
            scriptRecord: ["workingDirectory": existingDirectory] as NSDictionary
        )
        #expect(configuration.workingDirectory == existingDirectory)
    }

    @Test @MainActor func scriptTerminalExposesStableProperties() throws {
        let store = TerminalWorkspaceStore()
        let namespace: TerminalNamespace = .freeTerminal(UUID())
        store.switchNamespace(namespace)
        let paneID = try #require(store.activeFocusedPaneID)
        store.updateTitle(for: paneID, title: "Review Agent")
        store.updatePanePwd(paneID: paneID, pwd: "/tmp/project")

        let terminal = OpenOwlScriptTerminal(workspaceStore: store, paneID: paneID)

        #expect(terminal.stableID == paneID.uuidString)
        #expect(terminal.title == "Review Agent")
        #expect(terminal.workingDirectory == "/tmp/project")
    }

    private func configurationParsingFails(_ record: [String: Any]) -> Bool {
        do {
            _ = try TerminalSurfaceConfiguration(scriptRecord: record as NSDictionary)
            return false
        } catch {
            return true
        }
    }
}
