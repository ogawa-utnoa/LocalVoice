import Foundation

public struct ProcessOutput {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    public let timedOut: Bool
    public let durationSeconds: Double
}

/// Runs a subprocess (whisper-cli / llama-completion) safely:
/// - stdin is /dev/null so interactive tools can never wait for keyboard input
/// - stdout / stderr are drained concurrently so a full pipe (64KB) can never deadlock
/// - the process is terminated (then SIGKILLed) when the timeout expires, so the app never hangs forever
public enum ProcessRunner {

    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T
        init(_ value: T) { stored = value }
        var value: T {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    public static func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> ProcessOutput {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let start = Date()
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.standardInput = FileHandle.nullDevice

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                let outData = Box(Data())
                let errData = Box(Data())
                let timedOut = Box(false)
                let group = DispatchGroup()

                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    outData.value = outPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    errData.value = errPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }

                let timeoutItem = DispatchWorkItem {
                    guard process.isRunning else { return }
                    timedOut.value = true
                    process.terminate()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
                        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem)

                process.waitUntilExit()
                timeoutItem.cancel()
                group.wait()

                continuation.resume(returning: ProcessOutput(
                    stdout: String(decoding: outData.value, as: UTF8.self),
                    stderr: String(decoding: errData.value, as: UTF8.self),
                    exitCode: process.terminationStatus,
                    timedOut: timedOut.value,
                    durationSeconds: Date().timeIntervalSince(start)
                ))
            }
        }
    }
}
