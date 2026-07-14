import Foundation

struct CommandResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    var combinedOutput: String { [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n") }
}

enum CommandRunner {
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
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }

        return try await withCheckedThrowingContinuation { continuation in
            let lock = NSLock()
            var finished = false

            func finish(_ result: Result<CommandResult, Error>) {
                lock.lock()
                guard !finished else { lock.unlock(); return }
                finished = true
                lock.unlock()
                continuation.resume(with: result)
            }

            process.terminationHandler = { process in
                let out = output.fileHandleForReading.readDataToEndOfFile()
                let err = errorPipe.fileHandleForReading.readDataToEndOfFile()
                finish(.success(CommandResult(
                    exitCode: process.terminationStatus,
                    stdout: String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                    stderr: String(decoding: err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
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
                    let shouldTerminate = !finished
                    lock.unlock()
                    if shouldTerminate {
                        process.terminate()
                        finish(.failure(TailMountError.timeout))
                    }
                }
            } catch {
                finish(.failure(error))
            }
        }
    }
}
