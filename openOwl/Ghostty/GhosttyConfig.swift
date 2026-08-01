import Foundation

struct GhosttyConfigSnapshot {
    let command: String?
    let fontFamily: String?
    let fontSize: Double?
    let theme: String?
    let scrollbackLimit: UInt?
}

/// Manages ghostty_config_t lifecycle.
/// Loads user's ~/.config/ghostty/config and finalizes for use.
final class GhosttyConfig {
    private(set) var config: ghostty_config_t?
    private(set) var diagnostics: [String] = []
    private(set) var snapshot = GhosttyConfigSnapshot(
        command: nil,
        fontFamily: nil,
        fontSize: nil,
        theme: nil,
        scrollbackLimit: nil
    )

    init() {
        config = ghostty_config_new()
        guard config != nil else { return }

        // Load openOwl defaults first (user config can override these).
        // Zero padding since openOwl manages its own split pane layout.
        Self.loadDefaults(into: config!)

        // Only load openOwl's own config — NOT ~/.config/ghostty/config.
        // Users who also have Ghostty installed should not be affected.
        if let configPath = Self.appConfigPath() {
            configPath.withCString { cPath in
                ghostty_config_load_file(config, cPath)
            }
        }

        ghostty_config_finalize(config)

        diagnostics = Self.collectDiagnostics(from: config)
        snapshot = Self.captureSnapshot(from: config)

        if !diagnostics.isEmpty {
            NSLog("openOwl: ghostty config diagnostics count = \(diagnostics.count)")
            for diagnostic in diagnostics {
                NSLog("openOwl: ghostty config diagnostic: \(diagnostic)")
            }
        }

        NSLog(
            "openOwl: config snapshot command=%@ font-family=%@ font-size=%@ theme=%@ scrollback-limit=%@",
            snapshot.command ?? "<nil>",
            snapshot.fontFamily ?? "<nil>",
            snapshot.fontSize.map { String($0) } ?? "<nil>",
            snapshot.theme ?? "<nil>",
            snapshot.scrollbackLimit.map { String($0) } ?? "<nil>"
        )
    }

    deinit {
        if let config {
            ghostty_config_free(config)
        }
    }
}

extension GhosttyConfig {
    /// Path to openOwl's terminal config override file.
    static func appConfigPath() -> String? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }
        let dir = appSupport.appendingPathComponent("com.openowl.app")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config").path
    }

    /// Write a key-value pair to the openOwl config override file.
    /// Existing keys are updated in-place; new keys are appended.
    static func setOverride(key: String, value: String?) {
        guard let path = appConfigPath() else { return }
        let url = URL(fileURLWithPath: path)
        var lines: [String] = (try? String(contentsOf: url, encoding: .utf8))?.components(separatedBy: "\n") ?? []

        // Remove existing entry for this key
        lines.removeAll { $0.hasPrefix("\(key) =") || $0.hasPrefix("\(key)=") }

        // Append new value (if not nil)
        if let value {
            lines.append("\(key) = \(value)")
        }

        // Remove trailing empty lines
        while lines.last?.isEmpty == true { lines.removeLast() }

        let content = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Read a key from the openOwl config override file.
    static func readOverride(key: String) -> String? {
        guard let path = appConfigPath(),
              let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("\(key) =") || trimmed.hasPrefix("\(key)=") {
                let value = trimmed.drop(while: { $0 != "=" }).dropFirst().trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }
}

extension GhosttyConfig {
    /// Load openOwl-specific defaults via a temp config file (ghostty has no set API).
    /// Loaded BEFORE the user config so users can still override these values.
    static func loadDefaults(into config: ghostty_config_t) {
        let defaults = """
        window-padding-x = 0
        window-padding-y = 0
        window-padding-balance = true
        """
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openowl-defaults.conf")
        try? defaults.write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        tempURL.path.withCString { path in
            ghostty_config_load_file(config, path)
        }
    }
}

private extension GhosttyConfig {
    static func collectDiagnostics(from config: ghostty_config_t?) -> [String] {
        guard let config else { return [] }
        let count = ghostty_config_diagnostics_count(config)
        guard count > 0 else { return [] }

        var output: [String] = []
        output.reserveCapacity(Int(count))

        for index in 0..<count {
            let diagnostic = ghostty_config_get_diagnostic(config, index)
            output.append(String(cString: diagnostic.message))
        }
        return output
    }

    static func captureSnapshot(from config: ghostty_config_t?) -> GhosttyConfigSnapshot {
        GhosttyConfigSnapshot(
            command: readString(config: config, key: "command"),
            fontFamily: readString(config: config, key: "font-family"),
            fontSize: readFontSize(config: config, key: "font-size"),
            theme: readString(config: config, key: "theme"),
            scrollbackLimit: readUInt(config: config, key: "scrollback-limit")
        )
    }

    static func readString(config: ghostty_config_t?, key: String) -> String? {
        guard let config else { return nil }
        var value: UnsafePointer<CChar>?
        guard ghostty_config_get(config, &value, key, UInt(key.utf8.count)) else { return nil }
        guard let value else { return nil }
        let string = String(cString: value)
        return string.isEmpty ? nil : string
    }

    static func readFontSize(config: ghostty_config_t?, key: String) -> Double? {
        guard let config else { return nil }
        var value: Float = 0
        guard ghostty_config_get(config, &value, key, UInt(key.utf8.count)) else { return nil }
        guard value.isFinite, value > 0 else { return nil }
        return Double(value)
    }

    static func readUInt(config: ghostty_config_t?, key: String) -> UInt? {
        guard let config else { return nil }
        var value: UInt64 = 0
        guard ghostty_config_get(config, &value, key, UInt(key.utf8.count)) else { return nil }
        return UInt(value)
    }
}
