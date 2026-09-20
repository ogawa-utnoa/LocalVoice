import Foundation

public final class TemporaryAudioStore: @unchecked Sendable {
    public static let shared = TemporaryAudioStore()
    
    private let fileManager = FileManager.default
    private let baseDirectory: URL
    private let lock = NSLock()
    
    private init() {
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent("LocalVoiceAudio", isDirectory: true)
        try? fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        self.baseDirectory = tempDir
    }
    
    public func createTempAudioFileURL(prefix: String = "chunk") -> URL {
        lock.lock()
        defer { lock.unlock() }
        let filename = "\(prefix)_\(UUID().uuidString).wav"
        return baseDirectory.appendingPathComponent(filename)
    }
    
    /// Writes 16kHz 16-bit mono PCM samples to a valid WAV file.
    public func writeWAVFile(samples: [Float], sampleRate: Int = 16000, destinationURL: URL) throws {
        let int16Samples = samples.map { sample -> Int16 in
            let clamped = max(-1.0, min(1.0, sample))
            return Int16(clamped * 32767.0)
        }
        
        let pcmData = int16Samples.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
        
        let headerData = makeWAVHeader(dataByteCount: pcmData.count, sampleRate: sampleRate, channels: 1, bitsPerSample: 16)
        
        var completeData = headerData
        completeData.append(pcmData)
        
        try completeData.write(to: destinationURL, options: .atomic)
    }
    
    public func cleanupFile(at url: URL) {
        lock.lock()
        defer { lock.unlock() }
        try? fileManager.removeItem(at: url)
    }
    
    public func cleanupAll() {
        lock.lock()
        defer { lock.unlock() }
        if let files = try? fileManager.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: nil) {
            for file in files {
                try? fileManager.removeItem(at: file)
            }
        }
    }
    
    private func makeWAVHeader(dataByteCount: Int, sampleRate: Int, channels: Int, bitsPerSample: Int) -> Data {
        var header = Data()
        let byteRate = sampleRate * channels * (bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let totalChunkSize = 36 + dataByteCount
        
        // "RIFF"
        header.append(contentsOf: [0x52, 0x49, 0x46, 0x46])
        // Size
        var chunkSize = UInt32(totalChunkSize).littleEndian
        header.append(Data(bytes: &chunkSize, count: 4))
        // "WAVE"
        header.append(contentsOf: [0x57, 0x41, 0x56, 0x45])
        // "fmt "
        header.append(contentsOf: [0x66, 0x6D, 0x74, 0x20])
        // Subchunk1Size (16 for PCM)
        var subchunk1Size = UInt32(16).littleEndian
        header.append(Data(bytes: &subchunk1Size, count: 4))
        // AudioFormat (1 for PCM)
        var audioFormat = UInt16(1).littleEndian
        header.append(Data(bytes: &audioFormat, count: 2))
        // NumChannels
        var numChannels = UInt16(channels).littleEndian
        header.append(Data(bytes: &numChannels, count: 2))
        // SampleRate
        var sRate = UInt32(sampleRate).littleEndian
        header.append(Data(bytes: &sRate, count: 4))
        // ByteRate
        var bRate = UInt32(byteRate).littleEndian
        header.append(Data(bytes: &bRate, count: 4))
        // BlockAlign
        var bAlign = UInt16(blockAlign).littleEndian
        header.append(Data(bytes: &bAlign, count: 2))
        // BitsPerSample
        var bPerSample = UInt16(bitsPerSample).littleEndian
        header.append(Data(bytes: &bPerSample, count: 2))
        // "data"
        header.append(contentsOf: [0x64, 0x61, 0x74, 0x61])
        // Data chunk size
        var dSize = UInt32(dataByteCount).littleEndian
        header.append(Data(bytes: &dSize, count: 4))
        
        return header
    }
}
