import SwiftUI

public struct BenchmarkView: View {
    @State private var isRunning = false
    @State private var currentStep = ""
    @State private var results: [BenchmarkResult] = []
    
    public init() {}
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("実機パフォーマンス測定 (Whisper / LLM)")
                .font(.title2).bold()
            
            Text("お使いのMac（24GB Mシリーズ）における文字起こし・整文速度・RAMピークを測定します。")
                .foregroundColor(.secondary)
            
            HStack {
                Button(action: {
                    runAllBenchmarks()
                }) {
                    if isRunning {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("測定中: \(currentStep)")
                        }
                    } else {
                        Text("ベンチマーク開始")
                    }
                }
                .disabled(isRunning)
                .buttonStyle(.borderedProminent)
                
                Spacer()
            }
            
            Divider()
            
            if results.isEmpty {
                Text("「ベンチマーク開始」ボタンを押してテストを実行してください。")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            } else {
                List(results, id: \.testCase) { res in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(res.modelType).font(.caption).padding(4).background(Color.blue.opacity(0.2)).cornerRadius(4)
                            Text(res.modelName).bold()
                            Spacer()
                            Text(String(format: "%.2f 秒", res.durationSeconds))
                                .bold().foregroundColor(.primary)
                        }
                        HStack {
                            Text(res.testCase).font(.caption).foregroundColor(.secondary)
                            Spacer()
                            Text("Peak RAM: \(Int(res.peakMemoryMB)) MB | Swap: \(Int(res.swapUsedMB)) MB")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        if !res.notes.isEmpty {
                            Text(res.notes).font(.caption2).foregroundColor(.gray)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding()
        .frame(width: 580, height: 440)
    }
    
    private func runAllBenchmarks() {
        isRunning = true
        results.removeAll()
        
        Task {
            let models = ModelManager.shared.scanAvailableModels()
            let whisperModels = models.filter { $0.isWhisper }
            let llmModels = models.filter { $0.isLLM }
            
            // 1. Whisper Benchmark
            for w in whisperModels {
                await MainActor.run { currentStep = "Whisper (\(w.name))..." }
                let res = await BenchmarkRunner.shared.benchmarkWhisper(modelPath: w.path, durationSeconds: 30.0)
                await MainActor.run { results.append(res) }
            }
            
            // 2. LLM Benchmark
            for l in llmModels {
                await MainActor.run { currentStep = "LLM (\(l.name))..." }
                let res = await BenchmarkRunner.shared.benchmarkLLM(modelPath: l.path)
                await MainActor.run { results.append(res) }
            }
            
            await MainActor.run {
                isRunning = false
                currentStep = "完了"
            }
        }
    }
}
