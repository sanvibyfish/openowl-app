import Foundation
import Testing
@testable import openOwl

/// Cross-implementation protocol tests: the Swift `MessageBusService` must be
/// byte-compatible with the Python `buslib.py` used by the openowl CLI and the
/// codex/pi adapters (REQ-009). Each test drives one side and reads the other
/// side through the real python3 implementation.
@Suite("MessageBusService")
struct MessageBusServiceTests {
    /// Path to the repo's scripts/message-bus (buslib.py lives there).
    private static let buslibDir = "/Users/sanvi/Documents/workspace/ios/openowl-app/scripts/message-bus"

    @MainActor
    private func python(_ code: String) -> String {
        let script = """
        import sys
        sys.path.insert(0, "\(Self.buslibDir)")
        \(code)
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["python3", "-c", script]
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        try? proc.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        #expect(proc.terminationStatus == 0, "python helper failed: \(String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")")
        return String(data: data, encoding: .utf8) ?? ""
    }

    @MainActor
    private func makeBus() -> MessageBusService {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("openowl-bus-\(UUID().uuidString)", isDirectory: true)
        setenv("OPENOWL_BUS", tmp.path, 1)
        let bus = MessageBusService()
        bus.refresh()
        return bus
    }

    @Test @MainActor
    func swiftSendIsReadableByPython() async throws {
        let bus = makeBus()
        let mid = bus.send("来自 Swift 的消息", to: "codex-python", from: "openowl")
        #expect(mid != nil)

        let read = python("""
        import buslib
        msgs = buslib.unread("codex-python")
        print(len(msgs))
        for m in msgs:
            print(m["from"], m["body"])
        """)
        #expect(read.contains("1"), "python should see exactly one message, got: \(read)")
        #expect(read.contains("openowl 来自 Swift 的消息"))
    }

    @Test @MainActor
    func pythonSendIsReadableBySwift() async throws {
        let bus = makeBus()
        python("""
        import buslib
        buslib.ensure_bus()
        buslib.send("openowl", "来自 Python 的消息", sender="codex-python")
        """)
        let unread = bus.unread(for: "openowl")
        #expect(unread.count == 1)
        #expect(unread[0].from == "codex-python")
        #expect(unread[0].body == "来自 Python 的消息")
    }

    @Test @MainActor
    func paneNamingPriority() async throws {
        let bus = makeBus()
        // override outranks title, title outranks pane-N fallback
        bus.setPaneName(paneID: "P-1", name: "codex-a")
        bus.registerPanes([
            (id: "P-1", title: "my title"),
            (id: "P-2", title: "pi-main"),
            (id: "P-3", title: nil),
        ])
        let agents = bus.listAgentNames()
        #expect(agents["P-1"] == "codex-a", "override should win, got \(String(describing: agents["P-1"]))")
        #expect(agents["P-2"] == "pi-main", "title should be used, got \(String(describing: agents["P-2"]))")
        #expect(agents["P-3"] == "pane-3", "fallback should be pane-N in registration order, got \(String(describing: agents["P-3"]))")
    }

    @Test @MainActor
    func watermarkInterop() async throws {
        let bus = makeBus()
        // python writes two messages; swift reads + acks one batch
        python("""
        import buslib
        buslib.ensure_bus()
        buslib.send("openowl", "first", sender="py")
        buslib.send("openowl", "second", sender="py")
        """)
        var unread = bus.unread(for: "openowl")
        #expect(unread.count == 2)
        bus.advanceCursor(for: "openowl", ids: unread.map { $0.id })
        #expect(bus.unread(for: "openowl").isEmpty)

        // python side must also see the advanced watermark (no re-injection)
        let stillThere = python("""
        import buslib
        print(len(buslib.unread("openowl")))
        """)
        #expect(stillThere.contains("0"), "python should see 0 unread after swift ack, got: \(stillThere)")
    }
}
