import Foundation

/// File logger → ~/Library/Logs/openOwl/openowl.log
///
/// Noisy tags are off by default. Enable with:
///   defaults write com.openowl.app.dev log.resizeDiag -bool YES
///   defaults write com.openowl.app.dev log.keyboardRouting -bool YES
///
/// Note the `.dev` suffix: these tags are only useful in Debug builds, and
/// Debug ships as com.openowl.app.dev with its own UserDefaults domain.
/// Release builds read com.openowl.app.
enum AppLogger {
    private static let queue = DispatchQueue(label: "com.openowl.logger", qos: .utility)
    private static let maxFileSize: UInt64 = 10 * 1024 * 1024 // 10 MB
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static var fileHandle: FileHandle?
    private static var currentFileSize: UInt64 = 0

    private static let logDir: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Logs/openOwl", isDirectory: true)
    }()

    private static let logFile: URL = {
        logDir.appendingPathComponent("openowl.log")
    }()

    /// Tags that only write when their UserDefaults switch is on.
    /// Every other tag is always on.
    /// `keyboard-routing` fires on every ESC and Ctrl-C — the two most-pressed
    /// keys in a terminal — and each call does a synchronous NSLog plus a file
    /// write on the keystroke path. It stays off unless someone is actually
    /// debugging the Escape routing it was added for.
    static let optInTags: [String: String] = [
        "resize-diag": "log.resizeDiag",
        "keyboard-routing": "log.keyboardRouting",
    ]

    static func isEnabled(_ tag: String) -> Bool {
        guard let key = optInTags[tag] else { return true }
        return UserDefaults.standard.bool(forKey: key)
    }

    static func log(_ tag: String, _ message: String) {
        guard isEnabled(tag) else { return }
        emit(tag, message)
    }

    static func log(_ tag: String, _ format: String, _ args: CVarArg...) {
        guard isEnabled(tag) else { return }
        emit(tag, String(format: format, arguments: args))
    }

    private static func emit(_ tag: String, _ message: String) {
        let timestamp = dateFormatter.string(from: Date())
        let line = "\(timestamp) [\(tag)] \(message)\n"
        NSLog("openOwl: [%@] %@", tag, message)
        queue.async {
            writeToFile(line)
        }
    }

    private static func writeToFile(_ line: String) {
        if fileHandle == nil {
            openLogFile()
        }
        guard let handle = fileHandle, let data = line.data(using: .utf8) else { return }
        handle.write(data)
        currentFileSize += UInt64(data.count)
        if currentFileSize > maxFileSize {
            rotateLogFile()
        }
    }

    private static func openLogFile() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: logDir.path) {
            try? fm.createDirectory(at: logDir, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: logFile.path) {
            fm.createFile(atPath: logFile.path, contents: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: logFile)
        fileHandle?.seekToEndOfFile()
        currentFileSize = fileHandle?.offsetInFile ?? 0
    }

    private static func rotateLogFile() {
        fileHandle?.closeFile()
        fileHandle = nil
        let fm = FileManager.default
        let prev = logDir.appendingPathComponent("openowl.1.log")
        try? fm.removeItem(at: prev)
        try? fm.moveItem(at: logFile, to: prev)
        openLogFile()
    }
}
