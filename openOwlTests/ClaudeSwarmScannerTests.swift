import Testing
import Foundation
@testable import openOwl

@Suite("ClaudeSwarmScanner")
struct ClaudeSwarmScannerTests {

    // MARK: - parseAgent

    @Test func parseAgent_fullFlags() {
        let args = "/Users/sanvi/.local/share/claude/versions/2.1.251 --agent-id reviewer@session-eb28c314 --agent-name reviewer --team-name session-eb28c314 --agent-color yellow --agent-type pr-review-toolkit:code-reviewer --dangerously-skip-permissions --model opus"
        let agent = ClaudeSwarmScanner.parseAgent(args: args, pid: 40252)
        #expect(agent != nil)
        #expect(agent?.pid == 40252)
        #expect(agent?.id == "reviewer@session-eb28c314")
        #expect(agent?.name == "reviewer")
        #expect(agent?.team == "session-eb28c314")
        #expect(agent?.colorName == "yellow")
        #expect(agent?.type == "pr-review-toolkit:code-reviewer")
        #expect(agent?.model == "opus")
    }

    @Test func parseAgent_modelWithBrackets() {
        let args = "claude 2.1.241 --agent-id simplification@session-eb28c314 --agent-name simplification --team-name session-eb28c314 --agent-color cyan --model opus[1m]"
        let agent = ClaudeSwarmScanner.parseAgent(args: args, pid: 1)
        #expect(agent?.model == "opus[1m]")
        #expect(agent?.type == nil)
    }

    @Test func parseAgent_withoutColorIsRejected() {
        let args = "claude --agent-id x@session-1 --agent-name x --model opus"
        #expect(ClaudeSwarmScanner.parseAgent(args: args, pid: 1) == nil)
    }

    @Test func parseAgent_nonAgentCommandLineIsRejected() {
        let args = "claude --dangerously-skip-permissions"
        #expect(ClaudeSwarmScanner.parseAgent(args: args, pid: 1) == nil)
    }

    @Test func parseAgent_doesNotConsumeUnknownFlagValues() {
        // --parent-session-id <uuid> sits between the flags we care about; the
        // parser must skip it and still find the next agent flag.
        let args = "claude --agent-id dev@session-7 --parent-session-id ABC-123 --agent-name dev --agent-color purple --model opus"
        let agent = ClaudeSwarmScanner.parseAgent(args: args, pid: 9)
        #expect(agent?.id == "dev@session-7")
        #expect(agent?.name == "dev")
        #expect(agent?.colorName == "purple")
        #expect(agent?.model == "opus")
    }

    // MARK: - parsePanesOutput

    @Test func parsePanesOutput_sortsAndResolvesPids() {
        let output = """
        2\t40003\t✳ Thai-learn-web 复杂度简化
        0\t40001\t✳ pr-review-toolkit:code-reviewer
        1\t40002\t✳ pr-review-toolkit:code-simplifier
        """
        let panes = ClaudeSwarmScanner.parsePanesOutput(output)
        #expect(panes.count == 3)
        #expect(panes[0].index == 0)
        #expect(panes[1].index == 1)
        #expect(panes[2].index == 2)
        #expect(panes[0].title == "✳ pr-review-toolkit:code-reviewer")
        // Unknown pids resolve to nil agents (ps finds nothing) — and that must
        // not drop the pane.
        #expect(panes[2].agent == nil)
    }

    @Test func parsePanesOutput_skipsMalformedKeepsValid() {
        let output = "not-a-pane\tline\n0\t99999\tok\n"
        let panes = ClaudeSwarmScanner.parsePanesOutput(output)
        #expect(panes.count == 1)
        #expect(panes[0].title == "ok")
    }
}