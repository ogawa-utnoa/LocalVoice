import Foundation

public struct BenchmarkResult: Codable {
    public let modelName: String
    public let modelType: String // "Whisper" or "LLM"
    public let testCase: String
    public let durationSeconds: Double
    public let peakMemoryMB: Double
    public let memoryPressureBefore: String
    public let memoryPressureAfter: String
    public let swapUsedMB: Double
    public let success: Bool
    public let notes: String
}

public final class BenchmarkRunner: @unchecked Sendable {
    public static let shared = BenchmarkRunner()
    
    private init() {}
    
    /// Generates a synthetic test audio sample of specified duration.
    public func generateTestAudioSamples(durationSeconds: Double) -> [Float] {
        let sampleRate = 16000
        let totalSamples = Int(Double(sampleRate) * durationSeconds)
        var samples = [Float](repeating: 0.0, count: totalSamples)
        
        // Gentle 440Hz tone with silence intervals to simulate speech activity
        for i in 0..<totalSamples {
            let t = Double(i) / Double(sampleRate)
            if Int(t) % 2 == 0 {
                samples[i] = Float(sin(2.0 * .pi * 440.0 * t) * 0.1)
            } else {
                samples[i] = 0.0
            }
        }
        return samples
    }
    
    /// Runs Whisper benchmark for 30-second audio.
    public func benchmarkWhisper(modelPath: String, durationSeconds: Double = 30.0) async -> BenchmarkResult {
        let pressureBefore = "\(ResourceMonitor.shared.getMemoryPressureLevel())"
        let samples = generateTestAudioSamples(durationSeconds: durationSeconds)
        let modelName = URL(fileURLWithPath: modelPath).lastPathComponent
        
        let start = Date()
        do {
            let (_, inferTime) = try await WhisperService.shared.transcribe(
                samples: samples,
                modelPath: modelPath
            )
            let memAfter = ResourceMonitor.shared.getMemoryStats()
            let pressureAfter = "\(ResourceMonitor.shared.getMemoryPressureLevel())"
            let peakMem = ResourceMonitor.shared.getCurrentProcessMemoryMB()
            let swapMB = Double(memAfter.swapUsedBytes) / (1024 * 1024)
            
            return BenchmarkResult(
                modelName: modelName,
                modelType: "Whisper",
                testCase: "\(Int(durationSeconds))秒音声 文字起こし",
                durationSeconds: inferTime,
                peakMemoryMB: peakMem,
                memoryPressureBefore: pressureBefore,
                memoryPressureAfter: pressureAfter,
                swapUsedMB: swapMB,
                success: true,
                notes: "推論時間: \(String(format: "%.2f", inferTime))s"
            )
        } catch {
            let memAfter = ResourceMonitor.shared.getMemoryStats()
            return BenchmarkResult(
                modelName: modelName,
                modelType: "Whisper",
                testCase: "\(Int(durationSeconds))秒音声 文字起こし",
                durationSeconds: Date().timeIntervalSince(start),
                peakMemoryMB: ResourceMonitor.shared.getCurrentProcessMemoryMB(),
                memoryPressureBefore: pressureBefore,
                memoryPressureAfter: "\(ResourceMonitor.shared.getMemoryPressureLevel())",
                swapUsedMB: Double(memAfter.swapUsedBytes) / (1024 * 1024),
                success: false,
                notes: "エラー: \(error.localizedDescription)"
            )
        }
    }
    
    /// Runs LLM rewriting benchmark on sample test text.
    public func benchmarkLLM(modelPath: String) async -> BenchmarkResult {
        let pressureBefore = "\(ResourceMonitor.shared.getMemoryPressureLevel())"
        let modelName = URL(fileURLWithPath: modelPath).lastPathComponent
        
        // 5-minute equivalent speech text sample with fillers, corrections, numbers, and dates
        let sampleText = """
        えーっと、来週の、あー、火曜日、いや水曜日の10時から、田中さんとGoogle Workspaceの導入について打ち合わせをします。
        この機能は3つあって、まず1つ目はAIによる自動化で、あと2つ目はカレンダー連携で、あ、最初のAIのところなんだけど、
        Geminiを使って文章を要約する予定です。費用は月額100万円ではなくて50万円で合意しました。
        詳細は https://example.com/project を確認してください。連絡先は tanaka@example.com です。
        """
        
        let start = Date()
        do {
            let (rewritten, inferTime) = try await LLMService.shared.rewriteText(
                rawText: sampleText,
                modelPath: modelPath
            )
            let memAfter = ResourceMonitor.shared.getMemoryStats()
            let pressureAfter = "\(ResourceMonitor.shared.getMemoryPressureLevel())"
            let peakMem = ResourceMonitor.shared.getCurrentProcessMemoryMB()
            let swapMB = Double(memAfter.swapUsedBytes) / (1024 * 1024)
            
            return BenchmarkResult(
                modelName: modelName,
                modelType: "LLM",
                testCase: "整文・言い直し・原文保護テスト",
                durationSeconds: inferTime,
                peakMemoryMB: peakMem,
                memoryPressureBefore: pressureBefore,
                memoryPressureAfter: pressureAfter,
                swapUsedMB: swapMB,
                success: true,
                notes: "出力文字数: \(rewritten.count)文字, 処理時間: \(String(format: "%.2f", inferTime))s"
            )
        } catch {
            let memAfter = ResourceMonitor.shared.getMemoryStats()
            return BenchmarkResult(
                modelName: modelName,
                modelType: "LLM",
                testCase: "整文・言い直し・原文保護テスト",
                durationSeconds: Date().timeIntervalSince(start),
                peakMemoryMB: ResourceMonitor.shared.getCurrentProcessMemoryMB(),
                memoryPressureBefore: pressureBefore,
                memoryPressureAfter: "\(ResourceMonitor.shared.getMemoryPressureLevel())",
                swapUsedMB: Double(memAfter.swapUsedBytes) / (1024 * 1024),
                success: false,
                notes: "エラー: \(error.localizedDescription)"
            )
        }
    }
}
