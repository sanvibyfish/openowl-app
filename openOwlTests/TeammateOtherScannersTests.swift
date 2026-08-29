import Testing
import Foundation
@testable import openOwl

@Suite("CodexSessionScanner")
struct CodexSessionScannerTests {

    @Test func parseIndexLine_full() {
        let line = #"{"id":"019c2992-0ad5-7892-95d1-e6592746a3b0","thread_name":"提交 skill 并补充 README 中英文","updated_at":"2026-03-10T13:58:38.466465Z"}"#
        let entry = CodexSessionScanner.parseIndexLine(line)
        #expect(entry != nil)
        #expect(entry?.id == "019c2992-0ad5-7892-95d1-e6592746a3b0")
        #expect(entry?.name == "提交 skill 并补充 README 中英文")
        #expect(entry?.date != nil)
        #expect(entry?.date?.timeIntervalSince1970 ?? 0 > 1_700_000_000)
    }

    @Test func parseIndexLine_missingNameAndDateOK() {
        let line = #"{"id":"abc-123"}"#
        let entry = CodexSessionScanner.parseIndexLine(line)
        #expect(entry?.id == "abc-123")
        #expect(entry?.name == "")
        #expect(entry?.date == nil)
    }

    @Test func parseIndexLine_malformedIsNil() {
        #expect(CodexSessionScanner.parseIndexLine("not json") == nil)
        #expect(CodexSessionScanner.parseIndexLine(#"{"name":"no id"}"#) == nil)
    }

    @Test func sessionID_fromRolloutFilename() {
        let name = "rollout-2026-01-22T15-42-28-019be4de-8c5f-76c0-b665-47b8671b20cf.jsonl"
        #expect(CodexSessionScanner.sessionID(fromRolloutFilename: name)
            == "019be4de-8c5f-76c0-b665-47b8671b20cf")
    }

    @Test func cwd_fromRolloutFirstLine() {
        let line = #"{"timestamp":"2026-01-22T08:42:28.861Z","type":"session_meta","payload":{"id":"019be4de-8c5f-76c0-b665-47b8671b20cf","timestamp":"2026-01-22T08:42:28.831Z","cwd":"/Users/sanvi/Documents/workspace/web3/thai-learn-web","originator":"codex_cli_rs","cli_version":"0.87.0"}}"#
        #expect(CodexSessionScanner.cwd(fromRolloutFirstLine: line)
            == "/Users/sanvi/Documents/workspace/web3/thai-learn-web")
    }
}

@Suite("PiSessionScanner")
struct PiSessionScannerTests {

    @Test func parseHeaderData_extractsCwdModelTitle() {
        let text = """
        {"type":"session","version":3,"id":"01a04161-9dfc-7eb8-a5d4-8824c6df9c13","timestamp":"2026-08-27T04:01:51.612Z","cwd":"/Users/sanvi/Documents/workspace/ios/openowl-app"}
        {"type":"model_change","id":"05c84d2f","parentId":null,"timestamp":"2026-08-27T04:01:53.562Z","provider":"opencode-go","modelId":"ox-alpha-free"}
        {"type":"message","id":"17b0076f","parentId":"da3ed23c","timestamp":"2026-08-27T04:02:31.918Z","message":{"role":"user","content":[{"type":"text","text":"我们file explorer显示有问题"}],"timestamp":1787803351913}}
        """
        let header = PiSessionScanner.parseHeaderData(text)
        #expect(header.cwd == "/Users/sanvi/Documents/workspace/ios/openowl-app")
        #expect(header.model == "ox-alpha-free")
        #expect(header.title == "我们file explorer显示有问题")
    }

    @Test func parseHeaderData_keepsLatestModelAndFirstTitle() {
        let text = """
        {"type":"model_change","modelId":"alpha"}
        {"type":"model_change","modelId":"beta"}
        {"type":"message","message":{"role":"user","content":[{"type":"text","text":"first"}]}}
        {"type":"message","message":{"role":"user","content":[{"type":"text","text":"second"}]}}
        """
        let header = PiSessionScanner.parseHeaderData(text)
        #expect(header.model == "beta")
        #expect(header.title == "first")
    }

    @Test func parseHeaderData_titleCollapsesNewlinesAndTruncates() {
        let long = String(repeating: "字", count: 100)
        let text = """
        {"type":"message","message":{"role":"user","content":[{"type":"text","text":"line1\\nline2 \(long)"}]}}
        """
        let header = PiSessionScanner.parseHeaderData(text)
        #expect(header.title != nil)
        #expect(!header.title!.contains("\n"))
        #expect(header.title!.count <= 73)
        #expect(header.title!.hasSuffix("…"))
    }

    @Test func parseHeaderData_ignoresNonUserMessages() {
        let text = """
        {"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"assistant text"}]}}
        """
        let header = PiSessionScanner.parseHeaderData(text)
        #expect(header.title == nil)
    }

    @Test func parseHeaderData_empty() {
        let header = PiSessionScanner.parseHeaderData("")
        #expect(header.cwd == nil)
        #expect(header.model == nil)
        #expect(header.title == nil)
    }
}