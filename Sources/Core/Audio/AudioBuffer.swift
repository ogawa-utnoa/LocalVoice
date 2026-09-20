import Foundation

/// Thread-safe audio sample buffer holding 16kHz float samples with ring-buffer overflow protection.
public final class AudioBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    public let sampleRate: Int
    public let maxCapacitySamples: Int
    
    public init(sampleRate: Int = 16000, maxDurationSeconds: Double = 660.0) { // 11 mins capacity
        self.sampleRate = sampleRate
        self.maxCapacitySamples = Int(Double(sampleRate) * maxDurationSeconds)
    }
    
    public func append(newSamples: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        samples.append(contentsOf: newSamples)
        
        // Ring buffer safeguard: if exceeding max capacity, drop oldest samples
        if samples.count > maxCapacitySamples {
            let overflow = samples.count - maxCapacitySamples
            samples.removeFirst(overflow)
        }
    }
    
    public var totalSamplesCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return samples.count
    }
    
    public var totalDurationSeconds: Double {
        lock.lock()
        defer { lock.unlock() }
        return Double(samples.count) / Double(sampleRate)
    }
    
    /// Extracts a slice of samples between startSample and endSample.
    public func slice(from startSample: Int, to endSample: Int) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        
        let start = max(0, min(startSample, samples.count))
        let end = max(start, min(endSample, samples.count))
        guard start < end else { return [] }
        return Array(samples[start..<end])
    }
    
    /// Returns all samples currently held.
    public func allSamples() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }
    
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        samples.removeAll(keepingCapacity: true)
    }
}
