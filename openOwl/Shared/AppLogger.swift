import Foundation

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

    static func log(_ tag: String, _ message: String) {
        let timestamp = dateFormatter.string(from: Date())
        let line = "\(timestamp) [\(tag)] \(message)\n"
        NSLog("openOwl: [%@] %@", tag, message)
        queue.async {
            writeToFile(line)
        }
    }

    static func log(_ tag: String, _ format: String, _ args: CVarArg...) {
        let message = String(format: format, arguments: args)
        log(tag, message)
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
