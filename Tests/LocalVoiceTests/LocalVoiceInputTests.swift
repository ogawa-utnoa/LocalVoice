import Foundation
import AppKit
import AVFoundation
import LocalVoiceCore

// MARK: - Test Framework Support (Pure Swift)

private var totalTestsRun = 0
private var totalTestsPassed = 0
private var totalTestsFailed = 0

private func runTest(name: String, block: () throws -> Void) {
    totalTestsRun += 1
    do {
        try block()
        totalTestsPassed += 1
        print("  ✓ [PASS] \(name)")
    } catch {
        totalTestsFailed += 1
        print("  ✗ [FAIL] \(name): \(error)")
    }
}

private func runAsyncTest(name: String, block: () async throws -> Void) async {
    totalTestsRun += 1
    do {
        try await block()
        totalTestsPassed += 1
        print("  ✓ [PASS] \(name)")
    } catch {
        totalTestsFailed += 1
        print("  ✗ [FAIL] \(name): \(error)")
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

private func assertTrue(_ condition: Bool, _ message: String = "Expected true but got false", file: String = #file, line: Int = #line) throws {
    if !condition { throw TestFailure(message: "\(message) at \(file):\(line)") }
}

private func assertFalse(_ condition: Bool, _ message: String = "Expected false but got true", file: String = #file, line: Int = #line) throws {
    if condition { throw TestFailure(message: "\(message) at \(file):\(line)") }
}

private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "", file: String = #file, line: Int = #line) throws {
    if actual != expected {
        throw TestFailure(message: "Expected [\(expected)] but got [\(actual)]. \(message) at \(file):\(line)")
    }
}

private func assertNotNil<T>(_ value: T?, _ message: String = "Expected non-nil value", file: String = #file, line: Int = #line) throws {
    if value == nil { throw TestFailure(message: "\(message) at \(file):\(line)") }
}

// MARK: - Test Runner Entry Point

@main
struct TestRunner {
    static func main() async {
        print("\n=======================================================")
        print("  Running LocalVoice Test Suite (Pure Swift)")
        print("=======================================================\n")
        
        // 1. Audio & Chunk Tests
        print("[Audio & Chunking Tests]")
        runTest(name: "AudioBuffer: Append and Slice") {
            let buffer = AudioBuffer(sampleRate: 16000, maxDurationSeconds: 10.0)
            let sampleData: [Float] = Array(repeating: 0.5, count: 16000)
            buffer.append(newSamples: sampleData)
            try assertEqual(buffer.totalSamplesCount, 16000)
            try assertTrue(abs(buffer.totalDurationSeconds - 1.0) < 0.001)
            
            let slice = buffer.slice(from: 0, to: 8000)
            try assertEqual(slice.count, 8000)
            try assertEqual(slice.first, 0.5)
        }
        
        runTest(name: "AudioBuffer: Ring buffer capacity limit") {
            let buffer = AudioBuffer(sampleRate: 100, maxDurationSeconds: 1.0) // 100 samples max
            let excess: [Float] = Array(repeating: 1.0, count: 150)
            buffer.append(newSamples: excess)
            try assertEqual(buffer.totalSamplesCount, 100)
        }
        
        runTest(name: "ChunkManager: 30s chunking, 2s overlap, final chunk") {
            let chunkManager = ChunkManager(sampleRate: 1000, chunkDurationSeconds: 10.0, overlapDurationSeconds: 2.0)
            let buffer = AudioBuffer(sampleRate: 1000, maxDurationSeconds: 60.0)
            
            buffer.append(newSamples: Array(repeating: 0.1, count: 10_000))
            var ready = chunkManager.pollReadyChunks(from: buffer)
            try assertEqual(ready.count, 1)
            try assertEqual(ready[0].startTimeSeconds, 0.0)
            try assertEqual(ready[0].endTimeSeconds, 10.0)
            
            // Add 8s -> should produce second chunk (8s..18s) with 2s overlap
            buffer.append(newSamples: Array(repeating: 0.2, count: 8_000))
            ready = chunkManager.pollReadyChunks(from: buffer)
            try assertEqual(ready.count, 1)
            try assertEqual(ready[0].startTimeSeconds, 8.0)
            try assertEqual(ready[0].endTimeSeconds, 18.0)
            
            // Add 3s -> stop recording -> finalize remaining chunk (16s..21s)
            buffer.append(newSamples: Array(repeating: 0.3, count: 3_000))
            let finalChunk = chunkManager.finalizeRemainingChunk(from: buffer)
            try assertNotNil(finalChunk)
            try assertEqual(finalChunk?.startTimeSeconds, 16.0)
            try assertEqual(finalChunk?.endTimeSeconds, 21.0)
            try assertTrue(finalChunk?.isFinal == true)
        }
        
        // 2. Overlap Merger Tests
        print("\n[Overlap Merger Tests]")
        runTest(name: "OverlapMerger: Deduplicate overlapping chunk boundary") {
            let chunkA = "Google Workspaceの設定を確認して"
            let chunkB = "Workspaceの設定を確認してから次に進みます"
            let merged = OverlapMerger.merge(previousText: chunkA, nextText: chunkB)
            try assertEqual(merged, "Google Workspaceの設定を確認してから次に進みます")
        }
        
        runTest(name: "OverlapMerger: Sequential chunks mergeAll") {
            let chunks = [
                "第一に要件を定義します",
                "要件を定義します。第二に設計を行います",
                "第二に設計を行います。第三に実装します"
            ]
            let merged = OverlapMerger.mergeAll(chunks)
            try assertTrue(merged.contains("第一に要件を定義します"))
            try assertTrue(merged.contains("第三に実装します"))
        }
        
        // 3. Text Processing Tests
        print("\n[Text Processing Tests (Fillers & Rewrites)]")
        runTest(name: "FillerProcessor: Removes common fillers (あー、えーっと)") {
            let input = "えーっと、来週の件ですが、あー、進めておきます。"
            let cleaned = FillerProcessor.removeFillers(input)
            try assertFalse(cleaned.contains("えーっと"))
            try assertFalse(cleaned.contains("あー"))
            try assertTrue(cleaned.contains("来週の件ですが"))
            try assertTrue(cleaned.contains("進めておきます"))
        }
        
        runTest(name: "FillerProcessor: Strictly preserves 'あの人' and 'まあまあ'") {
            let input = "あの人が言っていた件は、まあまあ順調です。"
            let cleaned = FillerProcessor.removeFillers(input)
            try assertTrue(cleaned.contains("あの人"), "'あの人' must be preserved")
            try assertTrue(cleaned.contains("まあまあ"), "'まあまあ' must be preserved")
        }
        
        runTest(name: "RewriteDetector: Slips-of-the-tongue correction (火曜日、いや水曜日)") {
            let input = "来週の火曜日、いや水曜日の10時から田中さんと打ち合わせします"
            let corrected = RewriteDetector.processCorrections(input)
            try assertEqual(corrected, "来週の水曜日の10時から田中さんと打ち合わせします")
        }
        
        runTest(name: "RewriteDetector: '火曜じゃなくて水曜日'") {
            let input = "火曜じゃなくて水曜日の10時"
            let corrected = RewriteDetector.processCorrections(input)
            try assertEqual(corrected, "水曜日の10時")
        }
        
        runTest(name: "TextNormalizer: Period and spacing normalization") {
            let input = "  これはテストです、  "
            let normalized = TextNormalizer.normalize(input)
            try assertEqual(normalized, "これはテストです。")
        }
        
        // 4. Integrity Validation Tests
        print("\n[Integrity Validation Tests (Numbers, Dates, URLs)]")
        runTest(name: "IntegrityValidator: Preserves valid entities without alteration") {
            let raw = "2026年9月19日の10時から、https://example.com でGoogle Workspaceの勉強会を行います。参加費は5000円です。"
            let cand = "2026年9月19日の10時から、https://example.com でGoogle Workspaceの勉強会を行います。参加費は5000円です。"
            let res = IntegrityValidator.validate(rawText: raw, candidateText: cand, customKeywords: ["Google Workspace", "Gemini"])
            try assertTrue(res.isValid)
            try assertTrue(res.missingTokens.isEmpty)
        }
        
        runTest(name: "IntegrityValidator: Rejects hallucinated or tampered dates/amounts") {
            let raw = "打ち合わせは水曜日の10時からで、費用は100万円です。"
            let tampered = "打ち合わせは木曜日の15時からで、費用は50万円です。"
            let res = IntegrityValidator.validate(rawText: raw, candidateText: tampered)
            try assertFalse(res.isValid, "Must reject tampered date/amount")
        }
        
        runTest(name: "IntegrityValidator: Automatically repairs fullwidth number variants") {
            let raw = "3つの機能があります。"
            let cand = "３つの機能があります。"
            let res = IntegrityValidator.validate(rawText: raw, candidateText: cand)
            try assertTrue(res.isValid)
            try assertEqual(res.repairedText, "3つの機能があります。")
        }
        
        // 5. Insertion & Clipboard Tests
        print("\n[Insertion & Clipboard Tests]")
        // Keep the user's real clipboard intact across these tests
        let userClipboard = ClipboardService.shared.snapshot()
        
        runTest(name: "ClipboardService: Set and get string") {
            let testVal = "LocalVoice_Test_\(UUID().uuidString)"
            ClipboardService.shared.copyToClipboard(testVal)
            let read = NSPasteboard.general.string(forType: .string)
            try assertEqual(read, testVal)
        }
        
        runTest(name: "ClipboardService: Snapshot and restore previous clipboard") {
            ClipboardService.shared.copyToClipboard("before")
            let snap = ClipboardService.shared.snapshot()
            ClipboardService.shared.copyToClipboard("after")
            ClipboardService.shared.restore(snap)
            try assertEqual(NSPasteboard.general.string(forType: .string), "before")
        }
        
        await runAsyncTest(name: "AccessibilityService: Text stays on clipboard when auto-insert is off (no keystrokes sent)") {
            // Auto-insert OFF so the test never pastes into whatever app is frontmost
            let saved = SettingsStore.shared.settings
            SettingsStore.shared.update { $0.enableAutoInsertion = false; $0.copyToClipboardOnFinish = true }
            defer { SettingsStore.shared.settings = saved }
            
            let testVal = "Safety_Retention_\(UUID().uuidString)"
            let result = await AccessibilityService.shared.insertText(testVal)
            if case .clipboardOnlyFallback = result {} else {
                throw TestFailure(message: "Expected clipboard-only result, got \(result)")
            }
            try assertEqual(NSPasteboard.general.string(forType: .string), testVal)
        }
        
        ClipboardService.shared.restore(userClipboard)
        
        // 6. Resource Monitor & Memory Tests
        print("\n[Resource Monitor & Memory Pressure Tests]")
        runTest(name: "ResourceMonitor: Live macOS memory statistics") {
            let stats = ResourceMonitor.shared.getMemoryStats()
            try assertTrue(stats.totalRAMBytes > 0)
            try assertTrue(stats.usedRAMMB > 0)
            let mode = ResourceMonitor.shared.determineRecommendedMode()
            try assertTrue([AppOperatingMode.normal, .lowMemory, .emergency].contains(mode))
            print("    [System RAM Info] Total: \(Int(stats.totalRAMBytes / (1024*1024*1024)))GB | Available: \(Int(stats.availableRAMMB))MB | Mode: \(mode.rawValue)")
        }
        
        // 7. Pipeline Safe Fallback Tests
        print("\n[Pipeline Fallback Tests]")
        await runAsyncTest(name: "Pipeline: Graceful fallback to rule-based text in Emergency mode") {
            let rawChunks = ["えーっと、本日の会議を、あー、開始します"]
            let result = await TextProcessingPipeline.shared.process(
                transcribedChunks: rawChunks,
                whisperDuration: 0.5,
                mode: .emergency
            )
            try assertEqual(result.usedLLM, false)
            try assertFalse(result.finalText.contains("えーっと"))
            try assertFalse(result.finalText.contains("あー"))
            try assertTrue(result.finalText.contains("本日の会議") && result.finalText.contains("開始します"))
        }
        
        // 8. Model Discovery Tests
        print("\n[Model Discovery Tests]")
        runTest(name: "ModelManager: Scans and discovers Whisper and LLM models") {
            let models = ModelManager.shared.scanAvailableModels()
            try assertTrue(!models.isEmpty, "Should find downloaded models")
            let whisper = ModelManager.shared.resolveWhisperModelPath(for: .normal)
            try assertNotNil(whisper, "Should resolve Whisper model for normal mode")
            let llm = ModelManager.shared.resolveLLMModelPath(for: .normal)
            try assertNotNil(llm, "Should resolve LLM model for normal mode")
            print("    [Discovered] Whisper: \(URL(fileURLWithPath: whisper ?? "").lastPathComponent) | LLM: \(URL(fileURLWithPath: llm ?? "").lastPathComponent)")
        }
        
        // 9. Shortcut Manager Customization Tests
        print("\n[Shortcut Manager Customization Tests]")
        runTest(name: "GlobalShortcutManager: Formats and updates custom shortcuts") {
            let formatted = GlobalShortcutManager.formatShortcut(keyCode: 49, modifiers: .option)
            try assertEqual(formatted, "⌥ Option + Space")
            
            let formattedCtrl = GlobalShortcutManager.formatShortcut(keyCode: 49, modifiers: .control)
            try assertEqual(formattedCtrl, "⌃ Control + Space")
            
            let formattedF2 = GlobalShortcutManager.formatShortcut(keyCode: 120, modifiers: [])
            try assertEqual(formattedF2, "F2")
            
            // Test updating shortcut
            GlobalShortcutManager.shared.updateShortcut(keyCode: 49, modifiers: .option)
            try assertEqual(SettingsStore.shared.settings.shortcutDisplayName, "⌥ Option + Space")
        }
        
        // 10. Regression tests for "recording stops but nothing is inserted"
        print("\n[Subprocess & LLM Output Tests]")
        await runAsyncTest(name: "ProcessRunner: Kills a hung process at the timeout") {
            let out = try await ProcessRunner.run(executable: "/bin/sleep", arguments: ["10"], timeout: 0.5)
            try assertTrue(out.timedOut, "sleep 10 must be reported as timed out")
            try assertTrue(out.durationSeconds < 5, "must not wait for the full 10 seconds")
        }
        
        await runAsyncTest(name: "ProcessRunner: stdin is closed, so tools waiting for input exit immediately") {
            let out = try await ProcessRunner.run(executable: "/bin/cat", arguments: [], timeout: 3)
            try assertFalse(out.timedOut, "cat must see EOF instead of waiting for keyboard input")
            try assertEqual(out.exitCode, 0)
        }
        
        await runAsyncTest(name: "ProcessRunner: Large stderr output does not deadlock") {
            let out = try await ProcessRunner.run(
                executable: "/bin/sh",
                arguments: ["-c", "head -c 300000 /dev/zero | tr '\\0' 'x' 1>&2; echo ok"],
                timeout: 10
            )
            try assertFalse(out.timedOut)
            try assertEqual(out.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "ok")
            try assertEqual(out.stderr.count, 300000)
        }
        
        runTest(name: "LLMService: Strips llama.cpp end marker and ChatML tokens") {
            let cleaned = LLMService.cleanLLMOutput("来週の水曜日10時から打ち合わせをします。 [end of text]\n\n")
            try assertEqual(cleaned, "来週の水曜日10時から打ち合わせをします。")
            try assertEqual(LLMService.cleanLLMOutput("整文結果：こんにちは。<|im_end|>"), "こんにちは。")
        }
        
        runTest(name: "LLMService: Splits unpunctuated long text into bounded blocks") {
            let text = String(repeating: "あいうえおかきくけこ", count: 130) // 1300 chars, no punctuation
            let blocks = LLMService.splitIntoParagraphs(text, maxLen: 500)
            try assertTrue(blocks.count >= 3)
            try assertTrue(blocks.allSatisfy { $0.count <= 500 })
            try assertEqual(blocks.joined(), text)
        }
        
        print("\n[Silence & Rewrite Safety Tests]")
        runTest(name: "TranscriptionQueue: Silence gate and known hallucinations") {
            try assertTrue(TranscriptionQueue.peakRMS(Array(repeating: 0, count: 16000)) < TranscriptionQueue.silenceThreshold)
            let tone = (0..<16000).map { Float(sin(Double($0) * 0.1)) * 0.1 }
            try assertTrue(TranscriptionQueue.peakRMS(tone) > TranscriptionQueue.silenceThreshold)
            try assertTrue(TranscriptionQueue.isKnownHallucination("ご視聴ありがとうございました。"))
            try assertFalse(TranscriptionQueue.isKnownHallucination("ご視聴ありがとうございました。次回は来週です。"))
        }
        
        runTest(name: "RewriteDetector: Keeps real reduplicated words (いろいろ, そろそろ, まあまあ)") {
            let input = "いろいろ試してそろそろ終わります。まあまあ順調です"
            try assertEqual(RewriteDetector.processCorrections(input), input)
        }
        
        runTest(name: "RewriteDetector: Does not treat 'いやです' or unrelated 'じゃなくて' context as a correction") {
            try assertEqual(RewriteDetector.processCorrections("それはいやです"), "それはいやです")
            try assertEqual(RewriteDetector.processCorrections("これはペンじゃなくて鉛筆です"), "これは鉛筆です")
        }
        
        // 11. Accuracy: dictionary spelling fixes and the "keep the speaker's words" guard
        print("\n[Vocabulary & Edit Guard Tests]")
        runTest(name: "VocabularyNormalizer: Fixes product-name spellings as whole words only") {
            let pairs = UserDictionary.defaultEntries
                .flatMap { e in e.variants.map { (variant: $0, word: e.word) } }
                .sorted { $0.variant.count > $1.variant.count }
            let fixed = VocabularyNormalizer.normalize(
                "クロードコードとクロードとCloude CodeとClaudでやる。チャットGPTとアンチグラビティとタイプレス", pairs: pairs)
            try assertEqual(fixed, "Claude CodeとClaudeとClaude CodeとClaudeでやる。ChatGPTとAntigravityとTypeless")
            try assertEqual(VocabularyNormalizer.normalize("ClaudeとGoogle Cloudとクロードモネ", pairs: pairs), "ClaudeとGoogle Cloudとクロードモネ")
        }
        
        runTest(name: "UserDictionary: Migration adds new default words / variants and keeps user words") {
            let old = [UserDictionaryEntry(word: "Claude", reading: "くろーど"), UserDictionaryEntry(word: "山田商事")]
            let migrated = UserDictionary.migrate(old)
            let claude = migrated.first { $0.word == "Claude" }
            try assertTrue(claude?.variants.contains("くろーど") == true, "user variant kept")
            try assertTrue(claude?.variants.contains("クロード") == true, "default variant added")
            try assertTrue(migrated.contains { $0.word == "山田商事" })
            try assertTrue(migrated.contains { $0.word == "Antigravity" })
        }
        
        runTest(name: "UserDictionary: Personal dictionary file is merged (words added, variants unioned)") {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lvi_dict_\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let file = dir.appendingPathComponent("dictionary.json")
            try #"[{"word": "山田商事", "reading": "やまだしょうじ, ヤマダ商事"}, {"word": "Claude", "reading": "クロウド"}]"#
                .write(to: file, atomically: true, encoding: .utf8)
            let merged = UserDictionary.merge(UserDictionary.defaultEntries, withPersonalFile: file)
            try assertTrue(merged.first { $0.word == "山田商事" }?.variants.contains("ヤマダ商事") == true)
            let claude = merged.first { $0.word == "Claude" }
            try assertTrue(claude?.variants.contains("クロウド") == true && claude?.variants.contains("クロード") == true)
            // Missing or broken files are ignored
            try assertEqual(UserDictionary.merge([], withPersonalFile: dir.appendingPathComponent("none.json")).count, 0)
        }
        
        runTest(name: "UserDictionary: Whisper prompt is a short Japanese-punctuated word list") {
            let prompt = UserDictionary.shared.generateWhisperPrompt()
            try assertTrue(prompt.hasSuffix("。") && prompt.contains("、") && prompt.count <= 160, "prompt: \(prompt)")
        }
        
        runTest(name: "UserDictionary: Prompt keeps shipped words and cuts the list at the budget") {
            // A long list measurably hurts Whisper, so personal words fill only what is left
            let hints = ["Claude", "Codex", "Gemini", "Substack", "Notion", "Lancers"]
            let personal: Set<String> = ["Substack", "Notion", "Lancers"]
            let short = UserDictionary.promptText(hints: hints, personal: personal, maxCharacters: 30)
            try assertEqual(short, "Claude、Codex、Gemini、Substack。")
            try assertTrue(short.count <= 31, "budget respected: \(short.count)")
            let all = UserDictionary.promptText(hints: hints, personal: personal, maxCharacters: 150)
            try assertEqual(all, "Claude、Codex、Gemini、Substack、Notion、Lancers。")
            try assertEqual(UserDictionary.promptText(hints: [], personal: [], maxCharacters: 150), "")
        }
        
        runTest(name: "EditGuard: Accepts filler removal, punctuation and self-corrections") {
            try assertTrue(EditGuard.check(input: "見積もりは、まあ、月額3万円です", output: "見積もりは月額3万円です。").accepted)
            try assertTrue(EditGuard.check(input: "来週の火曜日、いや水曜日の10時から", output: "来週の水曜日の10時から").accepted)
            try assertTrue(EditGuard.check(
                input: "来週までに提案書を送ると伝えてあります。じゃなくて、再来週までに送ると伝えてあります",
                output: "再来週までに提案書を送ると伝えてあります。").accepted)
        }
        
        runTest(name: "EditGuard: Rejects paraphrase, invented text and dropped content") {
            try assertFalse(EditGuard.check(
                input: "Antigravityは制限に達したので、すべてこの後Claudeでやる予定です。",
                output: "Antigravityは制限に達しましたので、これからClaudeで処理することにしています。").accepted)
            try assertFalse(EditGuard.check(input: "テストです", output: "これはテスト用の文章で、動作確認のために入力しています。").accepted)
            try assertFalse(EditGuard.check(
                input: "最初のGoogle Workspaceのところなんだけど、管理画面から設定します",
                output: "最初のGoogle Workspaceのところから設定します。").accepted)
            try assertFalse(EditGuard.check(
                input: "Antigravityは制限に達したので、すべてこの後Claudeでやる予定です。",
                output: "Antigravityは制限に達したので、Claudeでやる予定です。").accepted, "dropping 'すべてこの後' must be rejected")
        }
        
        // 12. End-to-end pipeline with real speech (skipped when whisper / llama / models are not installed)
        print("\n[End-to-End Speech Pipeline Tests]")
        let whisperModel = ModelManager.shared.resolveWhisperModelPath(for: .normal)
        let llmModel = ModelManager.shared.resolveLLMModelPath(for: .normal)
        // The speech tests synthesize Japanese audio with the macOS "Kyoko" voice
        let voices = (try? await ProcessRunner.run(executable: "/usr/bin/say", arguments: ["-v", "?"], timeout: 10).stdout) ?? ""
        let hasJapaneseVoice = voices.contains("Kyoko")
        if WhisperService.shared.findWhisperBinary() != nil, whisperModel != nil,
           LLMService.shared.findLlamaBinary() != nil, llmModel != nil,
           hasJapaneseVoice {
            
            await runAsyncTest(name: "LLMService: Returns only the rewritten sentence (no banner / prompt echo)") {
                let raw = "えーっと、来週の火曜日、いや水曜日の10時から田中さんと打ち合わせをします。費用は100万円です。"
                let (out, dur) = try await LLMService.shared.rewriteText(rawText: raw, modelPath: llmModel!)
                print("    [LLM] \(String(format: "%.2f", dur))s")
                for junk in ["Loading model", "available commands", "<|im_start|>", "[end of text]", "▄", "Prompt:"] {
                    try assertFalse(out.contains(junk), "LLM output must not contain '\(junk)'")
                }
                try assertTrue(out.contains("10時") && out.contains("100万円"), "numbers must survive")
                try assertTrue(out.count < raw.count * 2, "output must not include the prompt")
            }
            
            await runAsyncTest(name: "E2E: Spoken audio -> Whisper -> merge -> rules -> LLM -> final text") {
                let wav = FileManager.default.temporaryDirectory.appendingPathComponent("lvi_e2e_\(UUID().uuidString).wav")
                defer { try? FileManager.default.removeItem(at: wav) }
                let say = try await ProcessRunner.run(
                    executable: "/usr/bin/say",
                    arguments: ["-v", "Kyoko", "--file-format=WAVE", "--data-format=LEF32@16000", "-o", wav.path,
                                "えーっと、来週の水曜日の10時から、田中さんと打ち合わせをします。"],
                    timeout: 30
                )
                try assertEqual(say.exitCode, 0, "say failed: \(say.stderr)")
                
                let file = try AVAudioFile(forReading: wav)
                let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
                try file.read(into: buffer)
                let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
                try assertTrue(file.processingFormat.sampleRate == 16000 && samples.count > 16000)
                
                let queue = TranscriptionQueue(modelPath: whisperModel!, initialPrompt: UserDictionary.shared.generateWhisperPrompt())
                await queue.enqueue(chunk: AudioChunk(index: 0, startTimeSeconds: 0, endTimeSeconds: Double(samples.count) / 16000, samples: samples, isFinal: true))
                let results = await queue.drainAndAwaitAll()
                try assertEqual(results.count, 1)
                try assertTrue(results[0].errorMessage == nil, "whisper error: \(results[0].errorMessage ?? "")")
                
                let processed = await TextProcessingPipeline.shared.process(
                    transcribedChunks: results.map { $0.text },
                    whisperDuration: results[0].durationSeconds,
                    mode: .normal
                )
                print("    [E2E] whisper=\(String(format: "%.2f", results[0].durationSeconds))s llm=\(String(format: "%.2f", processed.llmDurationSeconds))s usedLLM=\(processed.usedLLM) fallback=\(processed.fallbackOccurred)")
                print("    [E2E] final: \(processed.finalText)")
                try assertFalse(processed.finalText.isEmpty, "final text must not be empty")
                try assertTrue(processed.finalText.contains("10時"), "time must be preserved")
                try assertTrue(processed.finalText.contains("打ち合わせ"))
                try assertFalse(processed.finalText.contains("Loading model"))
            }
            
            await runAsyncTest(name: "E2E: Real example keeps the speaker's words and fixes product names") {
                let wav = FileManager.default.temporaryDirectory.appendingPathComponent("lvi_e2e2_\(UUID().uuidString).wav")
                defer { try? FileManager.default.removeItem(at: wav) }
                _ = try await ProcessRunner.run(
                    executable: "/usr/bin/say",
                    arguments: ["-v", "Kyoko", "--file-format=WAVE", "--data-format=LEF32@16000", "-o", wav.path,
                                "えーっと、アンチグラビティは制限に達したので、すべてこの後クロードでやる予定です。"],
                    timeout: 30
                )
                let file = try AVAudioFile(forReading: wav)
                let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
                try file.read(into: buffer)
                let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
                
                let queue = TranscriptionQueue(modelPath: whisperModel!, initialPrompt: UserDictionary.shared.generateWhisperPrompt())
                await queue.enqueue(chunk: AudioChunk(index: 0, startTimeSeconds: 0, endTimeSeconds: Double(samples.count) / 16000, samples: samples, isFinal: true))
                let results = await queue.drainAndAwaitAll()
                let processed = await TextProcessingPipeline.shared.process(
                    transcribedChunks: results.map { $0.text }, whisperDuration: results[0].durationSeconds, mode: .normal)
                print("    [E2E] model=\(URL(fileURLWithPath: whisperModel!).lastPathComponent) whisper=\(String(format: "%.2f", results[0].durationSeconds))s llm=\(String(format: "%.2f", processed.llmDurationSeconds))s")
                print("    [E2E] raw  : \(processed.rawMergedText)")
                print("    [E2E] final: \(processed.finalText)  \(processed.fallbackReason ?? "")")
                try assertTrue(processed.finalText.contains("Antigravity"), "Antigravity")
                try assertTrue(processed.finalText.contains("Claude"), "Claude")
                try assertTrue(processed.finalText.contains("予定です"), "speaker's ending must be kept")
                try assertTrue(processed.finalText.contains("すべてこの後") || processed.finalText.contains("全てこの後"), "no words may be dropped")
            }
        } else {
            print("  - [SKIP] needs whisper-cli, llama-completion, models and the Japanese 'Kyoko' voice (System Settings > Accessibility > Spoken Content)")
        }
        
        // Final Summary
        print("\n=======================================================")
        print("  Test Results: \(totalTestsPassed)/\(totalTestsRun) passed (\(totalTestsFailed) failed)")
        print("=======================================================\n")
        
        if totalTestsFailed > 0 {
            exit(1)
        }
    }
}
