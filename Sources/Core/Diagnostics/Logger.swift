import Foundation

public enum LogLevel: Int, Comparable {
    case debug = 0
    case info = 1
    case warn = 2
    case error = 3
    
    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }
    
    init(fromString string: String) {
        switch string.uppercased() {
        case "DEBUG": self = .debug
        case "WARN", "WARNING": self = .warn
        case "ERROR": self = .error
        default: self = .info
        }
    }
}

public struct SessionMetrics: Codable {
    public var sessionId: UUID = UUID()
    public var startTime: Date = Date()
    public var recordingDurationSeconds: Double = 0.0
    public var chunkCount: Int = 0
    public var whisperProcessingTimeSeconds: Double = 0.0
    public var llmProcessingTimeSeconds: Double = 0.0
    public var totalProcessingTimeSeconds: Double = 0.0
    public var whisperModelUsed: String = ""
    public var llmModelUsed: String = ""
    public var peakMemoryUsageMB: Double = 0.0
    public var errorCode: String? = nil
    public var fallbackTriggered: Bool = false
    public var fallbackReason: String? = nil
    
    public init() {}
}

public final class AppLogger: @unchecked Sendable {
    public static let shared = AppLogger()
    
    private let lock = NSLock()
    private var minLevel: LogLevel = .info
    private var sessionHistory: [SessionMetrics] = []
    private let timestampFormatter = ISO8601DateFormatter()
    private var fileHandle: FileHandle?
    
    /// ~/Library/Logs/LocalVoiceInput/app.log — metadata only (timings, states, error codes), never spoken text.
    public let logFileURL: URL
    private let maxLogBytes: UInt64 = 5 * 1024 * 1024
    
    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/LocalVoiceInput", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        logFileURL = dir.appendingPathComponent("app.log")
        openLogFile()
    }
    
    private func openLogFile() {
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: logFileURL.path),
           let size = attrs[.size] as? UInt64, size > maxLogBytes {
            let rotated = logFileURL.appendingPathExtension("1")
            try? fm.removeItem(at: rotated)
            try? fm.moveItem(at: logFileURL, to: rotated)
        }
        if !fm.fileExists(atPath: logFileURL.path) {
            fm.createFile(atPath: logFileURL.path, contents: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: logFileURL)
        _ = try? fileHandle?.seekToEnd()
    }
    
    public func setLogLevel(_ levelString: String) {
        lock.lock()
        defer { lock.unlock() }
        minLevel = LogLevel(fromString: levelString)
    }
    
    public func debug(_ message: String) {
        log(.debug, message)
    }
    
    public func info(_ message: String) {
        log(.info, message)
    }
    
    public func warn(_ message: String) {
        log(.warn, message)
    }
    
    public func error(_ message: String, error: Error? = nil) {
        let errDesc = error != nil ? " Error: \(error!.localizedDescription)" : ""
        log(.error, message + errDesc)
    }
    
    public func recordSessionMetrics(_ metrics: SessionMetrics) {
        lock.lock()
        defer { lock.unlock() }
        sessionHistory.append(metrics)
        // Keep last 100 sessions in memory
        if sessionHistory.count > 100 {
            sessionHistory.removeFirst(sessionHistory.count - 100)
        }
        
        // Log telemetry-free session summary
        let summary = "[SESSION] duration=\(String(format: "%.1f", metrics.recordingDurationSeconds))s " +
            "chunks=\(metrics.chunkCount) whisper=\(String(format: "%.2f", metrics.whisperProcessingTimeSeconds))s " +
            "llm=\(String(format: "%.2f", metrics.llmProcessingTimeSeconds))s total=\(String(format: "%.2f", metrics.totalProcessingTimeSeconds))s " +
            "peakRAM=\(String(format: "%.1f", metrics.peakMemoryUsageMB))MB"
        logUnlocked(.info, summary)
    }
    
    public func getRecentMetrics() -> [SessionMetrics] {
        lock.lock()
        defer { lock.unlock() }
        return sessionHistory
    }
    
    private func log(_ level: LogLevel, _ message: String) {
        lock.lock()
        defer { lock.unlock() }
        logUnlocked(level, message)
    }
    
    private func logUnlocked(_ level: LogLevel, _ message: String) {
        guard level >= minLevel else { return }
        let timestamp = timestampFormatter.string(from: Date())
        let levelTag: String
        switch level {
        case .debug: levelTag = "[DEBUG]"
        case .info:  levelTag = "[INFO ]"
        case .warn:  levelTag = "[WARN ]"
        case .error: levelTag = "[ERROR]"
        }
        // Note: Strict privacy rule: NEVER print user transcriptions or spoken words here!
        let line = "\(timestamp) \(levelTag) \(message)"
        print(line)
        if let data = (line + "\n").data(using: .utf8) {
            try? fileHandle?.write(contentsOf: data)
        }
    }
}
