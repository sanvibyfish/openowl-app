import AppKit
import Foundation

/// Catches process exits that bypass AppKit's normal termination flow, so a
/// mystery `exit(1)` or crash can be attributed to a concrete call site.
///
/// Background (2026-08-11): the app exited with status 1 — launchd recorded
/// "exited due to exit(1)", no .ips crash report was written, and
/// `applicationWillTerminate` never ran. Static analysis found no `exit()`
/// call anywhere in app source. This monitor closes the gap:
///
///   • `atexit()` — runs on ANY `exit()` / main-return path (including the
///     normal ⌘Q quit, exit 0). Handlers run synchronously on the exiting
///     thread, so the recorded backtrace names the `exit()` caller.
///   • Fatal signal handlers — record the crashing thread's backtrace, then
///     restore the default handler and re-raise so macOS still writes a .ips.
///
/// Records go to `~/Library/Logs/openOwl/exit.log` using POSIX open/write,
/// which stays valid inside a signal handler. Normal quits produce exactly
/// one line; nothing else in the app is affected.
enum AppExitMonitor {
    private static var installed = false
    private static let lock = NSLock()

    private static let logDir = NSHomeDirectory() + "/Library/Logs/openOwl"
    private static let logPath = logDir + "/exit.log"

    /// Idempotent; safe to call from multiple entry points.
    static func install() {
        lock.lock()
        defer { lock.unlock() }
        guard !installed else { return }
        installed = true

        // Any exit()/main-return — including normal quit. Runs on the exiting
        // thread, so the stack trace below includes the exit() caller.
        atexit(exitHandler)

        // Fatal signals: record, then re-raise with default so the OS still
        // collects a crash report (git's 2026-08-11 SIGBUS is what led here).
        for sig in [SIGBUS, SIGSEGV, SIGABRT, SIGILL, SIGFPE, SIGTRAP, SIGSYS] {
            signal(sig, fatalSignalHandler)
        }

        // SIGTERM (logout/shutdown): record, then re-raise — outcome is the
        // default one, now with a log line.
        signal(SIGTERM, fatalSignalHandler)

        // DIAG (2026-08-12): sendEvent-level ESC probe. The local keyDown
        // monitor never saw ESC while Ctrl-C did, so the event was suspected
        // to be swallowed before NSApplication — this confirms at the outer-
        // most AppKit boundary which layer is dropping it.
        installSendEventProbe()
    }

    // MARK: - sendEvent probe (DIAG)

    private static func installSendEventProbe() {
        guard let original = class_getInstanceMethod(NSApplication.self, #selector(NSApplication.sendEvent(_:))) else { return }
        let block: @convention(block) (NSApplication, Selector, NSEvent) -> Void = { app, sel, event in
            if event.type == .keyDown, event.keyCode == 53 {
                AppLogger.log(
                    "keyboard-routing",
                    "sendEvent-probe esc keyDown chars=%@ window=%@",
                    event.characters ?? "?",
                    app.keyWindow.map { String(describing: type(of: $0)) } ?? "nil"
                )
            }
            let imp = method_getImplementation(original)
            typealias SendEventFn = @convention(c) (AnyObject, Selector, NSEvent) -> Void
            unsafeBitCast(imp, to: SendEventFn.self)(app, sel, event)
        }
        method_setImplementation(original, imp_implementationWithBlock(block))
    }

    // MARK: - Handlers

    private static let exitHandler: @convention(c) () -> Void = {
        // Runs in normal process context (exit() → atexit) — Foundation OK.
        let header = "=== exited via exit()/main-return at \(Self.timestamp())\n"
        append(header)
        appendBacktrace()
        NSLog("openOwl: process exited via exit()/main-return — see %@", logPath)
    }

    private static let fatalSignalHandler: @convention(c) (Int32) -> Void = { sig in
        // Async-signal-safe path only.
        append("=== fatal signal \(sig) (\(Self.signalName(sig)))\n")
        appendBacktrace()
        signal(sig, SIG_DFL)
        raise(sig)
    }

    // MARK: - Logging (POSIX, async-signal-safe)

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }

    private static func signalName(_ sig: Int32) -> String {
        switch sig {
        case SIGBUS: return "SIGBUS"
        case SIGSEGV: return "SIGSEGV"
        case SIGABRT: return "SIGABRT"
        case SIGILL: return "SIGILL"
        case SIGFPE: return "SIGFPE"
        case SIGTRAP: return "SIGTRAP"
        case SIGSYS: return "SIGSYS"
        case SIGTERM: return "SIGTERM"
        default: return "signal-\(sig)"
        }
    }

    private static func append(_ text: String) {
        let fd = open(logPath, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        text.withCString { ptr in
            _ = write(fd, UnsafeRawPointer(ptr), strlen(ptr))
        }
    }

    /// Appends the current thread's backtrace (64 frames max).
    private static func appendBacktrace() {
        let fd = open(logPath, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let frames = 64
        let buffer = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: frames)
        defer { buffer.deallocate() }
        let count = backtrace(buffer, Int32(frames))
        backtrace_symbols_fd(buffer, count, fd)
        let newline = "\n"
        newline.withCString { ptr in
            _ = write(fd, UnsafeRawPointer(ptr), strlen(ptr))
        }
    }
}
