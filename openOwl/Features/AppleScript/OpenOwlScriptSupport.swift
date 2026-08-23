import AppKit
import CoreFoundation
import Foundation

// The scripting object-model conventions and Ghostty-compatible four-character
// codes in this directory are adapted from Ghostty's macOS AppleScript support.
// See GhosttyAppleScriptNotice.swift for the retained MIT license notice.

@MainActor
enum OpenOwlScriptRuntime {
    static weak var appDelegate: AppDelegate?

    static func classDescription(
        for code: UInt32
    ) -> NSScriptClassDescription? {
        let registry = NSScriptSuiteRegistry.shared()
        registry.loadSuites(from: Bundle.main)
        return registry.classDescription(withAppleEventCode: code)
    }

    static let applicationClassCode: UInt32 = 0x6361_7070 // capp
    static let windowClassCode: UInt32 = 0x4777_6E64 // Gwnd
}

enum OpenOwlScriptFailure: LocalizedError {
    case notReady(String)
    case unknownObject(String)
    case vetoed(String)
    case notPermitted(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notReady(let message),
             .unknownObject(let message),
             .vetoed(let message),
             .notPermitted(let message),
             .failed(let message):
            return message
        }
    }

    var scriptErrorNumber: Int {
        switch self {
        case .unknownObject:
            return errAENoSuchObject
        case .vetoed, .notPermitted:
            return errAEEventNotPermitted
        case .notReady, .failed:
            return errAEEventFailed
        }
    }
}

extension NSScriptCommand {
    func fail(with failure: OpenOwlScriptFailure) {
        scriptErrorNumber = failure.scriptErrorNumber
        scriptErrorString = failure.localizedDescription
    }

    func failParameter(_ message: String, missing: Bool = false) {
        scriptErrorNumber = missing ? errAEParamMissed : errAECoercionFail
        scriptErrorString = message
    }
}

enum OpenOwlScriptRecordError: LocalizedError {
    case invalidType(parameter: String, expected: String)
    case invalidValue(parameter: String, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidType(let parameter, let expected):
            return "\(parameter) must be \(expected)."
        case .invalidValue(let parameter, let message):
            return "\(parameter) \(message)."
        }
    }
}

extension TerminalSurfaceConfiguration {
    init(scriptRecord source: NSDictionary?) throws {
        guard let source else {
            self.init()
            return
        }
        guard let record = source as? [String: Any] else {
            throw OpenOwlScriptRecordError.invalidType(
                parameter: "configuration",
                expected: "a surface configuration record"
            )
        }

        let workingDirectory = try Self.optionalText(
            record["workingDirectory"],
            parameter: "initial working directory"
        )
        if let workingDirectory {
            guard (workingDirectory as NSString).isAbsolutePath else {
                throw OpenOwlScriptRecordError.invalidValue(
                    parameter: "initial working directory",
                    message: "must be an absolute path"
                )
            }
            var isDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(
                atPath: workingDirectory,
                isDirectory: &isDirectory
            ), isDirectory.boolValue else {
                throw OpenOwlScriptRecordError.invalidValue(
                    parameter: "initial working directory",
                    message: "must exist and be a directory"
                )
            }
        }
        let command = try Self.optionalText(record["command"], parameter: "command")
        let initialInput = try Self.optionalText(
            record["initialInput"],
            parameter: "initial input"
        )

        let waitAfterCommand: Bool
        if let rawWait = record["waitAfterCommand"] {
            guard Self.isBoolean(rawWait), let value = rawWait as? NSNumber else {
                throw OpenOwlScriptRecordError.invalidType(
                    parameter: "wait after command",
                    expected: "boolean"
                )
            }
            waitAfterCommand = value.boolValue
        } else {
            waitAfterCommand = false
        }

        let environmentVariables: [String]
        if let rawEnvironment = record["environmentVariables"] {
            guard let assignments = rawEnvironment as? [String] else {
                throw OpenOwlScriptRecordError.invalidType(
                    parameter: "environment variables",
                    expected: "a list of KEY=VALUE text values"
                )
            }
            for assignment in assignments {
                guard !assignment.contains("\0") else {
                    throw OpenOwlScriptRecordError.invalidValue(
                        parameter: "environment variables",
                        message: "must not contain U+0000"
                    )
                }
                guard let separator = assignment.firstIndex(of: "="), separator != assignment.startIndex else {
                    throw OpenOwlScriptRecordError.invalidValue(
                        parameter: "environment variables",
                        message: "must use KEY=VALUE format; got \"\(assignment)\""
                    )
                }
            }
            environmentVariables = assignments
        } else {
            environmentVariables = []
        }

        let fontSize: Float?
        if let rawFontSize = record["fontSize"] {
            guard !Self.isBoolean(rawFontSize), let number = rawFontSize as? NSNumber else {
                throw OpenOwlScriptRecordError.invalidType(
                    parameter: "font size",
                    expected: "a number"
                )
            }
            let value = number.doubleValue
            guard value.isFinite else {
                throw OpenOwlScriptRecordError.invalidValue(
                    parameter: "font size",
                    message: "must be finite"
                )
            }
            let converted = Float(value)
            guard converted.isFinite, (1...255).contains(converted) else {
                throw OpenOwlScriptRecordError.invalidValue(
                    parameter: "font size",
                    message: "must be between 1 and 255 points"
                )
            }
            fontSize = converted
        } else {
            fontSize = nil
        }

        self.init(
            workingDirectory: workingDirectory,
            command: command,
            initialInput: initialInput,
            waitAfterCommand: waitAfterCommand,
            environmentVariables: environmentVariables,
            fontSize: fontSize
        )
    }

    var scriptDictionaryRepresentation: NSDictionary {
        var record: [String: Any] = [
            "workingDirectory": "",
            "command": "",
            "initialInput": "",
            "waitAfterCommand": waitAfterCommand,
            "environmentVariables": environmentVariables,
        ]
        if let workingDirectory { record["workingDirectory"] = workingDirectory }
        if let command { record["command"] = command }
        if let initialInput { record["initialInput"] = initialInput }
        if let fontSize { record["fontSize"] = NSNumber(value: fontSize) }
        return record as NSDictionary
    }

    private static func optionalText(_ rawValue: Any?, parameter: String) throws -> String? {
        guard let rawValue else { return nil }
        guard let value = rawValue as? String else {
            throw OpenOwlScriptRecordError.invalidType(parameter: parameter, expected: "text")
        }
        guard !value.contains("\0") else {
            throw OpenOwlScriptRecordError.invalidValue(
                parameter: parameter,
                message: "must not contain U+0000"
            )
        }
        return value.isEmpty ? nil : value
    }

    private static func isBoolean(_ value: Any) -> Bool {
        guard let object = value as AnyObject? else { return false }
        return CFGetTypeID(object) == CFBooleanGetTypeID()
    }
}

enum OpenOwlScriptSplitDirection {
    case left
    case right
    case up
    case down

    init?(code: UInt32) {
        switch code {
        case Self.fourCharacterCode("GSlf"): self = .left
        case Self.fourCharacterCode("GSrt"): self = .right
        case Self.fourCharacterCode("GSup"): self = .up
        case Self.fourCharacterCode("GSdn"): self = .down
        default: return nil
        }
    }

    var terminalDirection: TerminalSplitDirection {
        switch self {
        case .left: .left
        case .right: .right
        case .up: .up
        case .down: .down
        }
    }

    private static func fourCharacterCode(_ value: StaticString) -> UInt32 {
        value.withUTF8Buffer { buffer in
            buffer.reduce(0) { ($0 << 8) | UInt32($1) }
        }
    }
}
