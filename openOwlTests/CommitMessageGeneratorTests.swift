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

        #expect(state.cancel() === newProcess)
    }

    @Test func cancelAtomicallyClearsCurrentProcess() {
        let state = CommitMessageGenerator.ProcessState()
        let process = Process()
        state.install(process)

        #expect(state.cancel() === process)
        #expect(state.cancel() == nil)
    }

    /// A cancelled run must be distinguishable from a failed one: the
    /// terminationHandler uses this to end quietly instead of reporting the
    /// user's own cancellation as a CLI error.
    @Test func cancellationIsRecordedAndClearedByNextRun() {
        let state = CommitMessageGenerator.ProcessState()
        state.install(Process())
        #expect(state.wasCancelled == false)

        _ = state.cancel()
        #expect(state.wasCancelled == true)

        state.reset()
        #expect(state.wasCancelled == false)
    }
}
