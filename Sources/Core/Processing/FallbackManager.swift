import Foundation

public struct ProcessedResult {
    public let finalText: String
    public let rawMergedText: String
    public let ruleProcessedText: String
    public let usedLLM: Bool
    public let fallbackOccurred: Bool
    public let fallbackReason: String?
    public let whisperDurationSeconds: Double
    public let llmDurationSeconds: Double
    public let totalProcessingDurationSeconds: Double
}

public final class TextProcessingPipeline: @unchecked Sendable {
    public static let shared = TextProcessingPipeline()
    
    private init() {}
    
    /// Executes the full post-recording pipeline:
    /// 1. Merges overlapping chunk texts
    /// 2. Rule-based preprocessing (Filler removal, Rewrite detection, Normalization)
    /// 3. LLM full-text rewriting (if enabled and models available)
    /// 4. Integrity verification (protection of numbers, dates, URLs, custom dictionary words)
    /// 5. Safe fallback to rule-based text if LLM corrupts or fails
    public func process(
        transcribedChunks: [String],
        whisperDuration: Double,
        mode: AppOperatingMode
    ) async -> ProcessedResult {
        let startTime = Date()
        
        // 1. Merge overlapping chunk transcriptions, then fix dictionary spellings ("クロード" -> "Claude")
        let vocabulary = UserDictionary.shared.replacementPairs
        let rawMergedText = VocabularyNormalizer.normalize(OverlapMerger.mergeAll(transcribedChunks), pairs: vocabulary)
        let trimmedRaw = rawMergedText.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if trimmedRaw.isEmpty {
            return ProcessedResult(
                finalText: "",
                rawMergedText: "",
                ruleProcessedText: "",
                usedLLM: false,
                fallbackOccurred: false,
                fallbackReason: nil,
                whisperDurationSeconds: whisperDuration,
                llmDurationSeconds: 0.0,
                totalProcessingDurationSeconds: Date().timeIntervalSince(startTime)
            )
        }
        
        // 2. Rule-based preprocessing
        var ruleText = trimmedRaw
        let settings = SettingsStore.shared.settings
        
        if settings.enableFillerRemoval {
            ruleText = FillerProcessor.removeFillers(ruleText)
        }
        ruleText = RewriteDetector.processCorrections(ruleText)
        ruleText = TextNormalizer.normalize(ruleText)
        
        // If LLM is disabled by user settings or mode is Emergency, return rule-based text directly
        guard settings.enableLLMRewrite && mode != .emergency else {
            let elapsed = Date().timeIntervalSince(startTime)
            return ProcessedResult(
                finalText: ruleText,
                rawMergedText: trimmedRaw,
                ruleProcessedText: ruleText,
                usedLLM: false,
                fallbackOccurred: false,
                fallbackReason: mode == .emergency ? "緊急省メモリモードのためLLMをバイパスしました" : nil,
                whisperDurationSeconds: whisperDuration,
                llmDurationSeconds: 0.0,
                totalProcessingDurationSeconds: elapsed
            )
        }
        
        // 3. Resolve LLM Model
        guard let llmModelPath = ModelManager.shared.resolveLLMModelPath(for: mode) else {
            AppLogger.shared.warn("No suitable LLM model found. Falling back to rule-based output.")
            let elapsed = Date().timeIntervalSince(startTime)
            return ProcessedResult(
                finalText: ruleText,
                rawMergedText: trimmedRaw,
                ruleProcessedText: ruleText,
                usedLLM: false,
                fallbackOccurred: true,
                fallbackReason: "LLMモデルが見つかりません",
                whisperDurationSeconds: whisperDuration,
                llmDurationSeconds: 0.0,
                totalProcessingDurationSeconds: elapsed
            )
        }
        
        // 4. Run LLM Rewriting (blocks that paraphrase or drop content fall back to ruleText inside the service)
        var llmOutput = ""
        var llmDuration = 0.0
        var guardNote: String?
        do {
            let rewritten = try await LLMService.shared.rewriteTextGuarded(
                rawText: ruleText,
                modelPath: llmModelPath
            )
            llmOutput = VocabularyNormalizer.normalize(rewritten.text, pairs: vocabulary)
            llmDuration = rewritten.durationSeconds
            if rewritten.rejectedBlocks > 0 {
                guardNote = "LLM出力 \(rewritten.rejectedBlocks)/\(rewritten.totalBlocks) ブロックを却下: \(rewritten.rejectionReasons.joined(separator: ", "))"
            }
        } catch {
            AppLogger.shared.error("LLM rewrite failed. Falling back to rule-based result.", error: error)
            let elapsed = Date().timeIntervalSince(startTime)
            return ProcessedResult(
                finalText: ruleText,
                rawMergedText: trimmedRaw,
                ruleProcessedText: ruleText,
                usedLLM: false,
                fallbackOccurred: true,
                fallbackReason: "LLM実行エラー: \(error.localizedDescription)",
                whisperDurationSeconds: whisperDuration,
                llmDurationSeconds: 0.0,
                totalProcessingDurationSeconds: elapsed
            )
        }
        
        // 5. Integrity Verification (Specification #20)
        let customWords = UserDictionary.shared.wordsToProtect
        let validation = IntegrityValidator.validate(
            rawText: trimmedRaw,
            candidateText: llmOutput,
            customKeywords: customWords
        )
        
        let finalText: String
        let fallbackOccurred: Bool
        let fallbackReason: String?
        
        if validation.isValid {
            finalText = TextNormalizer.normalize(validation.repairedText)
            fallbackOccurred = guardNote != nil
            fallbackReason = guardNote
        } else {
            AppLogger.shared.warn("Integrity validation rejected LLM output: \(validation.reason ?? "Unknown"). Reverting to rule-based text.")
            finalText = ruleText
            fallbackOccurred = true
            fallbackReason = validation.reason
        }
        
        let totalElapsed = Date().timeIntervalSince(startTime)
        return ProcessedResult(
            finalText: finalText,
            rawMergedText: trimmedRaw,
            ruleProcessedText: ruleText,
            usedLLM: true,
            fallbackOccurred: fallbackOccurred,
            fallbackReason: fallbackReason,
            whisperDurationSeconds: whisperDuration,
            llmDurationSeconds: llmDuration,
            totalProcessingDurationSeconds: totalElapsed
        )
    }
}
