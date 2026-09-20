import Foundation

public struct AudioChunk: Identifiable, Equatable {
    public let id: UUID
    public let index: Int
    public let startTimeSeconds: Double
    public let endTimeSeconds: Double
    public let samples: [Float]
    public let fileURL: URL?
    public let isFinal: Bool
    
    public init(
        id: UUID = UUID(),
        index: Int,
        startTimeSeconds: Double,
        endTimeSeconds: Double,
        samples: [Float],
        fileURL: URL? = nil,
        isFinal: Bool = false
    ) {
        self.id = id
        self.index = index
        self.startTimeSeconds = startTimeSeconds
        self.endTimeSeconds = endTimeSeconds
        self.samples = samples
        self.fileURL = fileURL
        self.isFinal = isFinal
    }
    
    public var durationSeconds: Double {
        return endTimeSeconds - startTimeSeconds
    }
    
    public static func == (lhs: AudioChunk, rhs: AudioChunk) -> Bool {
        return lhs.id == rhs.id && lhs.index == rhs.index
    }
}

public final class ChunkManager: @unchecked Sendable {
    private let lock = NSLock()
    private let sampleRate: Int
    private let chunkDurationSeconds: Double
    private let overlapDurationSeconds: Double
    
    private var lastChunkEndSample: Int = 0
    private var chunkIndexCounter: Int = 0
    
    public init(
        sampleRate: Int = 16000,
        chunkDurationSeconds: Double = 30.0,
        overlapDurationSeconds: Double = 2.0
    ) {
        self.sampleRate = sampleRate
        self.chunkDurationSeconds = chunkDurationSeconds
        self.overlapDurationSeconds = overlapDurationSeconds
    }
    
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        lastChunkEndSample = 0
        chunkIndexCounter = 0
    }
    
    /// Checks if a new chunk of ~30s can be formed from the buffer.
    /// Returns chunks ready for transcription.
    public func pollReadyChunks(from buffer: AudioBuffer) -> [AudioChunk] {
        lock.lock()
        defer { lock.unlock() }
        
        var chunks: [AudioChunk] = []
        let chunkSamples = Int(chunkDurationSeconds * Double(sampleRate))
        let overlapSamples = Int(overlapDurationSeconds * Double(sampleRate))
        
        while true {
            let startSample: Int
            if chunkIndexCounter == 0 {
                startSample = 0
            } else {
                startSample = lastChunkEndSample - overlapSamples
            }
            
            let targetEndSample = startSample + chunkSamples
            guard buffer.totalSamplesCount >= targetEndSample else {
                break
            }
            
            let slice = buffer.slice(from: startSample, to: targetEndSample)
            let startSec = Double(startSample) / Double(sampleRate)
            let endSec = Double(targetEndSample) / Double(sampleRate)
            
            let chunk = AudioChunk(
                index: chunkIndexCounter,
                startTimeSeconds: startSec,
                endTimeSeconds: endSec,
                samples: slice,
                fileURL: nil,
                isFinal: false
            )
            chunks.append(chunk)
            
            lastChunkEndSample = targetEndSample
            chunkIndexCounter += 1
        }
        
        return chunks
    }
    
    /// Extracts the remaining un-transcribed audio when recording stops.
    public func finalizeRemainingChunk(from buffer: AudioBuffer) -> AudioChunk? {
        lock.lock()
        defer { lock.unlock() }
        
        let overlapSamples = Int(overlapDurationSeconds * Double(sampleRate))
        let startSample: Int
        if chunkIndexCounter == 0 {
            startSample = 0
        } else {
            startSample = max(0, lastChunkEndSample - overlapSamples)
        }
        
        let totalSamples = buffer.totalSamplesCount
        guard totalSamples > startSample else {
            return nil
        }
        
        let remainingSamples = buffer.slice(from: startSample, to: totalSamples)
        guard !remainingSamples.isEmpty else {
            return nil
        }
        
        // Minimum duration threshold (e.g. 0.3s) to avoid empty clicks
        let minSamples = Int(Double(sampleRate) * 0.3)
        guard remainingSamples.count >= minSamples else {
            return nil
        }
        
        let startSec = Double(startSample) / Double(sampleRate)
        let endSec = Double(totalSamples) / Double(sampleRate)
        
        let chunk = AudioChunk(
            index: chunkIndexCounter,
            startTimeSeconds: startSec,
            endTimeSeconds: endSec,
            samples: remainingSamples,
            fileURL: nil,
            isFinal: true
        )
        
        lastChunkEndSample = totalSamples
        chunkIndexCounter += 1
        return chunk
    }
}
