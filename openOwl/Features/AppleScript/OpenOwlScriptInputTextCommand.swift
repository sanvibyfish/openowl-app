import AppKit

@MainActor
@objc(OpenOwlScriptInputTextCommand)
final class OpenOwlScriptInputTextCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let text = directParameter as? String else {
            failParameter("Missing text to input.", missing: true)
            return nil
        }
        guard let terminal = evaluatedArguments?["terminal"] as? OpenOwlScriptTerminal else {
            failParameter("Missing terminal target.", missing: true)
            return nil
        }
        guard let appDelegate = OpenOwlScriptRuntime.appDelegate else {
            fail(with: .notReady("The openOwl app delegate is unavailable."))
            return nil
        }
        if case .failure(let failure) = appDelegate.automationInput(
            text: text,
            paneID: terminal.paneID
        ) {
            fail(with: failure)
        }
        return nil
    }
}
