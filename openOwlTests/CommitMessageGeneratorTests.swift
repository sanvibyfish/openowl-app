import Foundation
import Testing
@testable import openOwl

@Suite("Commit Message Generator")
struct CommitMessageGeneratorTests {
    @Test func oldProcessCannotClearNewProcess() {
        let state = CommitMessageGenerator.ProcessState()
        let oldProcess = Process()
        let newProcess = Process()

        state.install(oldProcess)
        state.install(newProcess)
        state.clear(ifCurrent: oldProcess)

        #expect(state.take() === newProcess)
    }

    @Test func takeAtomicallyClearsCurrentProcess() {
        let state = CommitMessageGenerator.ProcessState()
        let process = Process()
        state.install(process)

        #expect(state.take() === process)
        #expect(state.take() == nil)
    }
}
