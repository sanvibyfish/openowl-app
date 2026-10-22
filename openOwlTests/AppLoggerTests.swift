import Foundation
import Testing
@testable import openOwl

/// The logger holds an open `FileHandle` for the life of the process. If the log
/// directory is removed underneath it (cleanup tools, `rm -rf`, log rotation by
/// something else), writes keep "succeeding" into an unlinked inode and the log
/// silently ceases to exist on disk until the app restarts.
@Suite("AppLogger recovery", .serialized)
struct AppLoggerTests {

    @Test func recreatesLogFileAfterDirectoryIsDeleted() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("openowl-applogger-\(UUID().uuidString)", isDirectory: true)
        defer {
            AppLogger.logDirectoryOverride = nil
            try? FileManager.default.removeItem(at: dir)
        }
        AppLogger.logDirectoryOverride = dir
        let logFile = dir.appendingPathComponent("openowl.log")

        AppLogger.log("test", "first line")
        try await waitForFile(logFile)
        #expect(try String(contentsOf: logFile, encoding: .utf8).contains("first line"))

        // Something wipes the directory while the handle is still open.
        try FileManager.default.removeItem(at: dir)

        AppLogger.log("test", "second line")
        try await waitForFile(logFile)
        #expect(
            try String(contentsOf: logFile, encoding: .utf8).contains("second line"),
            "logger must reopen the file instead of writing into the deleted inode"
        )
    }

    @Test func recreatesLogFileAfterFileIsDeleted() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("openowl-applogger-\(UUID().uuidString)", isDirectory: true)
        defer {
            AppLogger.logDirectoryOverride = nil
            try? FileManager.default.removeItem(at: dir)
        }
        AppLogger.logDirectoryOverride = dir
        let logFile = dir.appendingPathComponent("openowl.log")

        AppLogger.log("test", "before")
        try await waitForFile(logFile)

        // Directory survives, only the file goes away.
        try FileManager.default.removeItem(at: logFile)

        AppLogger.log("test", "after")
        try await waitForFile(logFile)
        #expect(try String(contentsOf: logFile, encoding: .utf8).contains("after"))
    }

    private func waitForFile(_ url: URL, timeout: TimeInterval = 3) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("log file was never (re)created at \(url.path)")
    }
}
