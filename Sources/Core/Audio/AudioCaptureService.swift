import Foundation
import AVFoundation

public enum AudioCaptureError: Error, LocalizedError {
    case microphonePermissionDenied
    case engineSetupFailed(String)
    case deviceDisconnected
    case recordingAlreadyActive
    
    public var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "マイクへのアクセス権限がありません。システム設定から許可してください。"
        case .engineSetupFailed(let msg):
            return "オーディオエンジンの初期化に失敗しました: \(msg)"
        case .deviceDisconnected:
            return "録音デバイスが切断されました。"
        case .recordingAlreadyActive:
            return "既に録音中です。"
        }
    }
}

public final class AudioCaptureService: @unchecked Sendable {
    public static let shared = AudioCaptureService()
    
    private let engine = AVAudioEngine()
    private let targetSampleRate: Double = 16000.0
    private let targetFormat: AVAudioFormat
    
    private let lock = NSLock()
    private var isRecording = false
    private var recordingStartTime: Date?
    private var timer: DispatchSourceTimer?
    
    public let buffer: AudioBuffer
    public let chunkManager: ChunkManager
    
    public var onChunkReady: (@Sendable (AudioChunk) -> Void)?
    public var onMaxDurationReached: (@Sendable () -> Void)?
    public var onError: (@Sendable (AudioCaptureError) -> Void)?
    public var onAudioLevel: (@Sendable (Float) -> Void)?
    
    private init() {
        self.targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        self.buffer = AudioBuffer(sampleRate: 16000, maxDurationSeconds: 660.0) // 11 mins
        self.chunkManager = ChunkManager(sampleRate: 16000, chunkDurationSeconds: 30.0, overlapDurationSeconds: 2.0)
    }
    
    public func checkMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }
    
    public func startRecording(maxDurationSeconds: Double = 600.0) throws {
        lock.lock()
        guard !isRecording else {
            lock.unlock()
            throw AudioCaptureError.recordingAlreadyActive
        }
        
        buffer.clear()
        chunkManager.reset()
        
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            lock.unlock()
            throw AudioCaptureError.engineSetupFailed("無効な入力フォーマットです。")
        }
        
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            lock.unlock()
            throw AudioCaptureError.engineSetupFailed("オーディオコンバーターの作成に失敗しました。")
        }
        
        inputNode.removeTap(onBus: 0)
        
        let bufferSize: AVAudioFrameCount = 4096
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] (pcmBuffer, time) in
            guard let self = self else { return }
            self.processAudioTap(pcmBuffer: pcmBuffer, converter: converter)
        }
        
        do {
            try engine.start()
            isRecording = true
            recordingStartTime = Date()
        } catch {
            inputNode.removeTap(onBus: 0)
            lock.unlock()
            throw AudioCaptureError.engineSetupFailed(error.localizedDescription)
        }
        
        // Start background periodic check for chunks and max duration
        startPollingTimer(maxDurationSeconds: maxDurationSeconds)
        lock.unlock()
        
        AppLogger.shared.info("Audio capture started. Target: 16kHz mono. Max duration: \(maxDurationSeconds)s")
    }
    
    public func stopRecording() -> AudioChunk? {
        lock.lock()
        defer { lock.unlock() }
        
        guard isRecording else { return nil }
        
        timer?.cancel()
        timer = nil
        
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        
        let duration = recordingStartTime != nil ? Date().timeIntervalSince(recordingStartTime!) : 0.0
        AppLogger.shared.info("Audio capture stopped. Total recorded: \(String(format: "%.2f", duration))s")
        
        // Finalize any remaining un-transcribed audio chunk
        let finalChunk = chunkManager.finalizeRemainingChunk(from: buffer)
        return finalChunk
    }
    
    public var currentlyRecording: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isRecording
    }
    
    public var currentRecordingDuration: Double {
        lock.lock()
        defer { lock.unlock() }
        guard let start = recordingStartTime, isRecording else { return 0.0 }
        return Date().timeIntervalSince(start)
    }
    
    private func processAudioTap(pcmBuffer: AVAudioPCMBuffer, converter: AVAudioConverter) {
        let frameCapacity = AVAudioFrameCount(Double(pcmBuffer.frameLength) * (targetSampleRate / pcmBuffer.format.sampleRate)) + 512
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else { return }
        
        var error: NSError?
        var haveData = true
        
        converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
            if haveData {
                outStatus.pointee = .haveData
                haveData = false
                return pcmBuffer
            } else {
                outStatus.pointee = .noDataNow
                return nil
            }
        }
        
        guard error == nil, convertedBuffer.frameLength > 0,
              let floatData = convertedBuffer.floatChannelData?[0] else { return }
        
        let frameLength = Int(convertedBuffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: floatData, count: frameLength))
        
        // Add to thread-safe audio buffer
        buffer.append(newSamples: samples)
        
        // Compute audio level for UI VU meter
        var sumSquares: Float = 0.0
        for s in samples { sumSquares += s * s }
        let rms = sqrt(sumSquares / Float(max(1, frameLength)))
        onAudioLevel?(rms)
    }
    
    private func startPollingTimer(maxDurationSeconds: Double) {
        let queue = DispatchQueue(label: "com.localvoiceinput.audiopoller", qos: .userInitiated)
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1.0, repeating: 1.0)
        
        t.setEventHandler { [weak self] in
            guard let self = self else { return }
            
            let duration = self.currentRecordingDuration
            if duration >= maxDurationSeconds {
                self.onMaxDurationReached?()
                return
            }
            
            // Poll for newly formed 30s chunks
            let chunks = self.chunkManager.pollReadyChunks(from: self.buffer)
            for chunk in chunks {
                self.onChunkReady?(chunk)
            }
        }
        
        self.timer = t
        t.resume()
    }
}
