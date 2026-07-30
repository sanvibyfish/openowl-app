import Foundation

/// File logger → ~/Library/Logs/openOwl/openowl.log
///
/// Noisy tags (`resize-diag`) are off by default. Enable with:
///   defaults write com.openowl.app log.resizeDiag -bool YES
/// Keyboard routing is always on (needed to debug Escape).
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

    /// Tags that only write when explicitly enabled via UserDefaults.
    private static let optInTags: Set<String> = ["resize-diag"]

    private static func isEnabled(_ tag: String) -> Bool {
        guard optInTags.contains(tag) else { return true }
        switch tag {
        case "resize-diag":
            return UserDefaults.standard.bool(forKey: "log.resizeDiag")
        default:
            return true
        }
    }

    static func log(_ tag: String, _ message: String) {
        guard isEnabled(tag) else { return }
        let timestamp = dateFormatter.string(from: Date())
        let line = "\(timestamp) [\(tag)] \(message)\n"
        NSLog("openOwl: [%@] %@", tag, message)
        queue.async {
            writeToFile(line)
        }
    }

    static func log(_ tag: String, _ format: String, _ args: CVarArg...) {
        guard isEnabled(tag) else { return }
        let message = String(format: format, arguments: args)
        log(tag, message)
    }

    /// Always-on log for important resize milestones (dock toggles, force sync).
    /// Bypasses the resize-diag opt-in so ops events still appear.
    static func logResizeEvent(_ message: String) {
        log("resize", message)
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
