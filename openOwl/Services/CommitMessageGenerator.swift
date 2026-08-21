import Foundation

final class CommitMessageGenerator {
    final class ProcessState {
        private let lock = NSLock()
        private var process: Process?

        func install(_ process: Process) {
            lock.lock()
            self.process = process
            lock.unlock()
        }

        func clear(ifCurrent process: Process) {
            lock.lock()
            if self.process === process {
                self.process = nil
            }
            lock.unlock()
        }

        func take() -> Process? {
            lock.lock()
            let process = process
            self.process = nil
            lock.unlock()
            return process
        }
    }

    private let maxDiffChars = 20_000
    private let processState = ProcessState()

    func generate(diff: String) async throws -> String {
        let truncatedDiff: String
        if diff.count > maxDiffChars {
            truncatedDiff = String(diff.prefix(maxDiffChars))
                + "\n\n[... diff truncated, \(diff.count - maxDiffChars) more characters ...]"
        } else {
            truncatedDiff = diff
        }

        let tmpFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("openowl-diff-\(UUID().uuidString).txt")
        try truncatedDiff.write(to: tmpFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        let prompt = "Write a commit message for this diff. One summary line, then bullet points. Only output the message."

        // Find user's default shell
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shell)
        // -lc: login shell + run command (loads PATH from profile but not interactive)
        proc.arguments = ["-lic", "cat '\(tmpFile.path)' | claude -p '\(prompt)'"]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        // Start draining before the child runs. Reading only in the
        // terminationHandler deadlocks: a claude CLI that fills the 64KB stdout
        // buffer blocks in write(), never exits, so the handler never fires and
        // the caller's `isGeneratingMessage` spins forever.
        let stdoutDrain = try GitPipeDrain(fileHandle: stdoutPipe.fileHandleForReading)
        let stderrDrain = try GitPipeDrain(fileHandle: stderrPipe.fileHandleForReading)

        return try await withCheckedThrowingContinuation { continuation in
            proc.terminationHandler = { [weak self] process in
                self?.processState.clear(ifCurrent: process)

                let outData: Data
                let errData: Data
                do {
                    outData = try stdoutDrain.finish(command: "claude")
                    errData = try stderrDrain.finish(command: "claude")
                } catch {
                    continuation.resume(throwing: GeneratorError.cliError(error.localizedDescription))
                    return
                }
                let output = (String(data: outData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let errOutput = (String(data: errData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

                if process.terminationStatus != 0 || output.isEmpty {
                    let msg = errOutput.isEmpty ? (output.isEmpty ? "claude returned no output" : output) : errOutput
                    if msg.contains("command not found") {
                        continuation.resume(throwing: GeneratorError.cliError("claude CLI not found. Install: npm i -g @anthropic-ai/claude-code"))
                    } else {
                        continuation.resume(throwing: GeneratorError.cliError(msg))
                    }
                    return
                }

                NSLog("CommitMessageGenerator: got response, length=%d", output.count)
                continuation.resume(returning: output)
            }

            do {
                try proc.run()
                // Register only once it is actually running: cancel() calls
                // terminate(), and terminate() on a Process that was never
                // launched raises NSInvalidArgumentException — an ObjC
                // exception Swift cannot catch, so it takes the app down.
                processState.install(proc)
                NSLog("CommitMessageGenerator: process started, pid=%d", proc.processIdentifier)
            } catch {
                continuation.resume(throwing: GeneratorError.cliError(error.localizedDescription))
            }
        }
    }

    func cancel() {
        processState.take()?.terminate()
    }

    enum GeneratorError: LocalizedError {
        case cliError(String)

        var errorDescription: String? {
            switch self {
            case .cliError(let msg): return msg
            }
        }
    }
}
