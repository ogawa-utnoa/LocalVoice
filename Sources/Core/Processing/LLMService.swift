import Foundation

public enum LLMError: Error, LocalizedError {
    case binaryNotFound
    case modelNotFound(String)
    case executionFailed(Int32, String)
    case timedOut
    case emptyResponse
    
    public var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "llama-cli バイナリが見つかりません。Homebrew (brew install llama.cpp) 等を確認してください。"
        case .modelNotFound(let path):
            return "LLMモデルが見つかりません: \(path)"
        case .executionFailed(let code, let err):
            return "LLM実行エラー (code \(code)): \(err)"
        case .timedOut:
            return "LLM整文処理がタイムアウトしました。"
        case .emptyResponse:
            return "LLMから空の応答が返されました。"
        }
    }
}

public final class LLMService: @unchecked Sendable {
    public static let shared = LLMService()
    
    // llama-completion is the one-shot raw-prompt tool. Newer Homebrew llama.cpp turned llama-cli into an
    // interactive chat UI that echoes a banner and the prompt to stdout, so it is only a last resort for old installs.
    private let binaryPaths: [String] = [
        "/opt/homebrew/bin/llama-completion",
        "/usr/local/bin/llama-completion",
        "/opt/homebrew/bin/llama-cli",
        "/usr/local/bin/llama-cli"
    ]
    
    // Based on Specification #11, tightened after measuring Qwen2.5-1.5B: the original prompt let the model
    // paraphrase ("やる予定です" -> "処理することにしています"). Typeless keeps the speaker's words, so the model
    // is told to act as a proofreader that only deletes fillers, applies self-corrections and fixes punctuation.
    public static let systemPrompt: String = """
    あなたは音声入力の文字起こしを清書する校正者です。話者が使った単語・語尾・言い回しをそのまま残し、次の3つだけを行います。
    1. 「えー」「えっと」「あの」「まあ」「なんか」などのつなぎ言葉を消す
    2. 言い直しは後の言い方だけを残す(例:「火曜日、いや水曜日」→「水曜日」)
    3. 句読点を整える
    言い換え・要約・語尾の変更・敬語への変更・情報の追加は禁止です。数字・日付・時刻・URL・メールアドレス・人名・製品名・会社名・固有名詞は一字も変えません。清書した文章だけを出力してください。
    """
    
    /// Few-shot turns that show "keep the words, delete only the noise".
    public static let examples: [(input: String, output: String)] = [
        ("えーと、明日の、あー、会議なんですけど、まあ、10時からでお願いします", "明日の会議なんですけど、10時からでお願いします。"),
        ("資料は火曜日、いや水曜日までに送ります", "資料は水曜日までに送ります。"),
        ("今日はですね、なんか、ちょっと思ったことがあって、なので今作ってます", "今日はですね、ちょっと思ったことがあって、なので今作ってます。")
    ]
    
    static func buildPrompt(for text: String) -> String {
        var prompt = "<|im_start|>system\n\(systemPrompt)<|im_end|>\n"
        for example in examples {
            prompt += "<|im_start|>user\n\(example.input)<|im_end|>\n<|im_start|>assistant\n\(example.output)<|im_end|>\n"
        }
        prompt += "<|im_start|>user\n\(text)<|im_end|>\n<|im_start|>assistant\n"
        return prompt
    }
    
    private init() {}
    
    public func findLlamaBinary() -> String? {
        for path in binaryPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }
    
    public struct RewriteOutput {
        public let text: String
        public let durationSeconds: Double
        public let totalBlocks: Int
        /// Blocks whose LLM output failed EditGuard and were kept as the (rule-processed) input
        public let rejectedBlocks: Int
        public let rejectionReasons: [String]
    }
    
    /// Rewrites the full transcribed raw text into clean natural writing.
    public func rewriteText(
        rawText: String,
        modelPath: String,
        threads: Int = 4,
        contextSize: Int = 4096
    ) async throws -> (text: String, durationSeconds: Double) {
        let out = try await rewriteTextGuarded(rawText: rawText, modelPath: modelPath, threads: threads, contextSize: contextSize)
        return (out.text, out.durationSeconds)
    }
    
    /// Splits long speech into blocks (Specification #12), rewrites each block, and keeps a block's input
    /// whenever the model paraphrased, invented or dropped content (EditGuard).
    public func rewriteTextGuarded(
        rawText: String,
        modelPath: String,
        threads: Int = 4,
        contextSize: Int = 4096
    ) async throws -> RewriteOutput {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return RewriteOutput(text: "", durationSeconds: 0, totalBlocks: 0, rejectedBlocks: 0, rejectionReasons: [])
        }
        
        guard let binary = findLlamaBinary() else {
            throw LLMError.binaryNotFound
        }
        
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw LLMError.modelNotFound(modelPath)
        }
        
        let startTime = Date()
        let blocks = trimmed.count > 1200 ? Self.splitIntoParagraphs(trimmed, maxLen: 500) : [trimmed]
        var results: [String] = []
        var reasons: [String] = []
        
        for block in blocks {
            let (candidate, _) = try await runSingleLlamaRewrite(
                text: block,
                binary: binary,
                modelPath: modelPath,
                threads: threads,
                contextSize: contextSize
            )
            let verdict = EditGuard.check(input: block, output: candidate)
            if verdict.accepted {
                results.append(candidate)
            } else {
                results.append(block)
                reasons.append(verdict.reason ?? "?")
                AppLogger.shared.info("LLM block rejected by EditGuard: \(verdict.reason ?? "?") (added \(String(format: "%.2f", verdict.addedRatio)), kept \(String(format: "%.2f", verdict.keptRatio)))")
            }
        }
        
        return RewriteOutput(
            text: results.joined(separator: "\n"),
            durationSeconds: Date().timeIntervalSince(startTime),
            totalBlocks: blocks.count,
            rejectedBlocks: reasons.count,
            rejectionReasons: reasons
        )
    }
    
    private func runSingleLlamaRewrite(
        text: String,
        binary: String,
        modelPath: String,
        threads: Int,
        contextSize: Int
    ) async throws -> (text: String, durationSeconds: Double) {
        // ChatML prompt (Qwen2.5). Passed as a raw completion prompt, so no extra chat template is applied.
        let prompt = Self.buildPrompt(for: text)
        
        // Japanese is roughly 1 token per character; leave headroom for punctuation / line breaks.
        let maxTokens = min(2048, max(128, text.count * 2))
        let args = [
            "-m", modelPath,
            "-p", prompt,
            "-c", "\(contextSize)",
            "-t", "\(threads)",
            "-n", "\(maxTokens)",
            "--temp", "0", // greedy: the same speech always gives the same text
            "-no-cnv",
            "--no-display-prompt",
            "--no-warmup"
        ]
        
        let output: ProcessOutput
        do {
            output = try await ProcessRunner.run(
                executable: binary,
                arguments: args,
                timeout: 30 + Double(text.count) / 10
            )
        } catch {
            throw LLMError.executionFailed(-1, error.localizedDescription)
        }
        
        if output.timedOut {
            throw LLMError.timedOut
        }
        guard output.exitCode == 0 else {
            throw LLMError.executionFailed(output.exitCode, String(output.stderr.suffix(400)))
        }
        
        let cleaned = Self.cleanLLMOutput(output.stdout)
        guard !cleaned.isEmpty else {
            throw LLMError.emptyResponse
        }
        return (text: cleaned, durationSeconds: output.durationSeconds)
    }
    
    /// Splits text into blocks of at most maxLen characters, preferring sentence ends (。！？),
    /// then commas, and only hard-cutting when a single run has no punctuation at all.
    public static func splitIntoParagraphs(_ text: String, maxLen: Int) -> [String] {
        var sentences: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if "。！？!?\n".contains(ch) {
                sentences.append(current)
                current = ""
            }
        }
        if !current.isEmpty { sentences.append(current) }
        
        // Break over-long sentences at the last comma before maxLen, else hard-cut.
        var pieces: [String] = []
        for sentence in sentences {
            var rest = Substring(sentence)
            while rest.count > maxLen {
                let window = rest.prefix(maxLen)
                let cut = window.lastIndex(where: { $0 == "、" || $0 == "," }).map { rest.index(after: $0) } ?? window.endIndex
                pieces.append(String(rest[..<cut]))
                rest = rest[cut...]
            }
            if !rest.isEmpty { pieces.append(String(rest)) }
        }
        
        var results: [String] = []
        var block = ""
        for piece in pieces {
            if block.count + piece.count > maxLen && !block.isEmpty {
                results.append(block)
                block = ""
            }
            block += piece
        }
        if !block.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            results.append(block)
        }
        return results
    }
    
    /// Strips llama.cpp end markers, ChatML tokens and occasional preambles from the model output.
    public static func cleanLLMOutput(_ raw: String) -> String {
        var text = raw
        
        for marker in ["[end of text]", "<|im_end|>", "<|endoftext|>", "<|im_start|>"] {
            text = text.replacingOccurrences(of: marker, with: "")
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        let prefixesToRemove = [
            "以下は整文後の文章です：",
            "以下は整文後の文章です:",
            "整文した文章です：",
            "整文結果：",
            "完成した文章：",
            "出力："
        ]
        for prefix in prefixesToRemove where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
