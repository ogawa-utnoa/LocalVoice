import Foundation

public struct ChunkTranscriptionResult: Equatable {
    public let chunkIndex: Int
    public let text: String
    public let durationSeconds: Double
    public let isFinal: Bool
    /// Set when Whisper failed for this chunk (the chunk still keeps its slot so ordering is preserved).
    public let errorMessage: String?

    public init(chunkIndex: Int, text: String, durationSeconds: Double, isFinal: Bool, errorMessage: String? = nil) {
        self.chunkIndex = chunkIndex
        self.text = text
        self.durationSeconds = durationSeconds
        self.isFinal = isFinal
        self.errorMessage = errorMessage
    }
}

public actor TranscriptionQueue {
    private var pendingChunks: [AudioChunk] = []
    private var completedResults: [ChunkTranscriptionResult] = []
    private var isProcessing = false
    private var modelPath: String
    private var initialPrompt: String

    /// Peak RMS (per 50ms window) below which a chunk is treated as silence and not sent to Whisper.
    /// Whisper tends to hallucinate stock phrases on silent input.
    public static let silenceThreshold: Float = 0.002

    /// Whole-chunk outputs Whisper is known to hallucinate on silence / noise (Japanese).
    private static let knownHallucinations: Set<String> = [
        "ご視聴ありがとうございました",
        "ご視聴いただきありがとうございました",
        "最後までご視聴いただきありがとうございました",
        "チャンネル登録よろしくお願いします",
        "おやすみなさい"
    ]

    public init(modelPath: String, initialPrompt: String = "") {
        self.modelPath = modelPath
        self.initialPrompt = initialPrompt
    }

    public func updateModelPath(_ newPath: String) {
        self.modelPath = newPath
    }

    public func updatePrompt(_ newPrompt: String) {
        self.initialPrompt = newPrompt
    }

    /// Enqueues a newly captured chunk. Starts the worker if idle.
    /// `isProcessing` is set here (synchronously, inside the actor) so two enqueues can never start two workers,
    /// and `drainAndAwaitAll` can never observe a gap where a chunk is neither pending nor being processed.
    public func enqueue(chunk: AudioChunk) {
        pendingChunks.append(chunk)
        if !isProcessing {
            isProcessing = true
            Task { await self.processQueue() }
        }
    }

    /// Waits until all queued chunks are transcribed and returns the ordered results.
    public func drainAndAwaitAll() async -> [ChunkTranscriptionResult] {
        while isProcessing || !pendingChunks.isEmpty {
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }
        return completedResults.sorted(by: { $0.chunkIndex < $1.chunkIndex })
    }

    public var pendingCount: Int {
        pendingChunks.count + (isProcessing ? 1 : 0)
    }

    public func reset() {
        pendingChunks.removeAll()
        completedResults.removeAll()
    }

    public static func peakRMS(_ samples: [Float], windowSize: Int = 800) -> Float {
        guard !samples.isEmpty else { return 0 }
        var peak: Float = 0
        var start = 0
        while start < samples.count {
            let end = min(start + windowSize, samples.count)
            var sum: Float = 0
            for i in start..<end { sum += samples[i] * samples[i] }
            peak = max(peak, (sum / Float(end - start)).squareRoot())
            start = end
        }
        return peak
    }

    public static func isKnownHallucination(_ text: String) -> Bool {
        let stripped = text.filter { !"。、．.!！ 　\n".contains($0) }
        return knownHallucinations.contains(stripped)
    }

    private func processQueue() async {
        while !pendingChunks.isEmpty {
            let chunk = pendingChunks.removeFirst()

            let level = Self.peakRMS(chunk.samples)
            if level < Self.silenceThreshold {
                AppLogger.shared.info("Chunk #\(chunk.index) skipped as silence (peak RMS \(String(format: "%.4f", level)))")
                completedResults.append(ChunkTranscriptionResult(
                    chunkIndex: chunk.index, text: "", durationSeconds: 0, isFinal: chunk.isFinal
                ))
                continue
            }

            do {
                let (rawText, dur) = try await WhisperService.shared.transcribe(
                    samples: chunk.samples,
                    modelPath: modelPath,
                    initialPrompt: initialPrompt
                )
                let text = Self.isKnownHallucination(rawText) ? "" : rawText
                if text.isEmpty && !rawText.isEmpty {
                    AppLogger.shared.info("Chunk #\(chunk.index) dropped a known Whisper hallucination")
                }
                completedResults.append(ChunkTranscriptionResult(
                    chunkIndex: chunk.index, text: text, durationSeconds: dur, isFinal: chunk.isFinal
                ))
                AppLogger.shared.info("Transcribed chunk #\(chunk.index) (\(String(format: "%.1f", chunk.durationSeconds))s audio, peak RMS \(String(format: "%.3f", level))) in \(String(format: "%.2f", dur))s -> \(text.count) chars")
            } catch {
                AppLogger.shared.error("Failed to transcribe chunk #\(chunk.index)", error: error)
                // Keep a placeholder so chunk ordering is preserved
                completedResults.append(ChunkTranscriptionResult(
                    chunkIndex: chunk.index, text: "", durationSeconds: 0, isFinal: chunk.isFinal,
                    errorMessage: error.localizedDescription
                ))
            }
        }
        isProcessing = false
    }
}
