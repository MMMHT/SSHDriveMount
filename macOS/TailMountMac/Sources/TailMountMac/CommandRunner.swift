import Foundation
import Darwin

struct CommandResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let timedOut: Bool
    let duration: TimeInterval
    var combinedOutput: String { [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n") }
}

enum CommandRunner {
    private final class OutputCollector {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            lock.lock()
            data.append(chunk)
            lock.unlock()
        }

        func string() -> String {
            lock.lock()
            let snapshot = data
            lock.unlock()
            return String(decoding: snapshot, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    static func run(
        _ executable: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        input: Data? = nil,
        timeout: TimeInterval = 15
    ) async throws -> CommandResult {
        let process = Process()
        let output = Pipe()
        let errorPipe = Pipe()
        let standardInput = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errorPipe
        if input != nil { process.standardInput = standardInput }
        var childEnvironment = ProcessInfo.processInfo.environment
        // GUI applications export their own bundle identifier. Command-line
        // helpers such as the Tailscale app binary can mis-detect their launch
        // mode when that identifier is inherited by the child process.
        childEnvironment.removeValue(forKey: "__CFBundleIdentifier")
        childEnvironment.merge(environment) { _, new in new }
        process.environment = childEnvironment

        return try await withCheckedThrowingContinuation { continuation in
            let lock = NSLock()
            var finished = false
            var didTimeOut = false
            let started = Date()
            let stdoutCollector = OutputCollector()
            let stderrCollector = OutputCollector()

            output.fileHandleForReading.readabilityHandler = { handle in
                stdoutCollector.append(handle.availableData)
            }
            errorPipe.fileHandleForReading.readabilityHandler = { handle in
                stderrCollector.append(handle.availableData)
            }

            func finish(_ result: Result<CommandResult, Error>) {
                lock.lock()
                guard !finished else { lock.unlock(); return }
                finished = true
                lock.unlock()
                output.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(with: result)
            }

            process.terminationHandler = { process in
                stdoutCollector.append(output.fileHandleForReading.readDataToEndOfFile())
                stderrCollector.append(errorPipe.fileHandleForReading.readDataToEndOfFile())
                lock.lock()
                let timedOut = didTimeOut
                lock.unlock()
                finish(.success(CommandResult(
                    exitCode: process.terminationStatus,
                    stdout: stdoutCollector.string(),
                    stderr: stderrCollector.string(),
                    timedOut: timedOut,
                    duration: Date().timeIntervalSince(started)
                )))
            }

            do {
                try process.run()
                if let input {
                    standardInput.fileHandleForWriting.write(input)
                    try? standardInput.fileHandleForWriting.close()
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    lock.lock()
                    let shouldTerminate = !finished && process.isRunning
                    if shouldTerminate { didTimeOut = true }
                    lock.unlock()
                    if shouldTerminate {
                        process.terminate()
                        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                            if process.isRunning {
                                Darwin.kill(process.processIdentifier, SIGKILL)
                            }
                        }
                    }
                }
            } catch {
                finish(.failure(error))
            }
        }
    }
}
