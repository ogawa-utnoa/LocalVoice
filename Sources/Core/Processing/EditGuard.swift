import Foundation

public struct EditGuardResult: Equatable {
    public let accepted: Bool
    /// Share of output characters that do not come from the input (paraphrase / invention)
    public let addedRatio: Double
    /// Share of input characters that survive in the output
    public let keptRatio: Double
    public let reason: String?
}

/// Makes the LLM a "delete-only" editor, like Typeless: it may drop fillers, apply self-corrections and fix
/// punctuation, but it must keep the speaker's own words. Measured on Qwen2.5-1.5B, rejecting outputs that fail
/// this check removes paraphrases ("やる予定です" -> "処理することにしています") and invented sentences.
public struct EditGuard {
    /// Correction cues; a deleted stretch next to one of these is a legitimate self-correction.
    static let correctionMarkers = ["いや", "じゃなくて", "ではなく", "違う", "ちがう", "訂正", "間違え", "やっぱり", "失礼"]
    /// Words that may be deleted anywhere (longest first so "えーっと" is stripped before "えー").
    static let fillerTokens = ["えーっと", "ええっと", "えーと", "ええと", "えっと", "あのー", "そのー", "うーん",
                               "えー", "あー", "あの", "その", "まあ", "なんか", "ですね", "うん", "ええ", "あ", "え", "ね"]

    public static func check(input: String, output: String,
                             maxAddedRatio: Double = 0.08, minKeptRatio: Double = 0.5) -> EditGuardResult {
        let a = Array(normalize(input))
        let b = Array(normalize(output))
        guard !a.isEmpty else {
            return EditGuardResult(accepted: b.isEmpty, addedRatio: b.isEmpty ? 0 : 1, keptRatio: 1, reason: nil)
        }
        guard !b.isEmpty else {
            return EditGuardResult(accepted: false, addedRatio: 0, keptRatio: 0, reason: "出力が空")
        }

        let keptMask = lcsMask(a, b)
        let common = keptMask.filter { $0 }.count
        let added = Double(b.count - common) / Double(b.count)
        let kept = Double(common) / Double(a.count)
        let addedChars = b.count - common

        // A few characters may change (e.g. "みたいな" -> "のような"), but not whole phrases
        if added > maxAddedRatio && addedChars > 3 {
            return EditGuardResult(accepted: false, addedRatio: added, keptRatio: kept, reason: "言い換え・追加を検出")
        }
        let hasCorrection = correctionMarkers.contains { input.contains($0) }
        if kept < (hasCorrection ? min(minKeptRatio, 0.3) : minKeptRatio) {
            return EditGuardResult(accepted: false, addedRatio: added, keptRatio: kept, reason: "削除が多すぎる")
        }

        // Every deleted stretch must be a filler, a self-correction (near a correction cue), or at most
        // 2 leftover characters (a particle like "から"). Content words must survive elsewhere in the output.
        // Measured: Qwen2.5-1.5B silently dropped "すべてこの後" (hiragana, no kanji run) before this check.
        let outputString = String(b)
        var i = 0
        while i < a.count {
            guard !keptMask[i] else { i += 1; continue }
            var j = i
            while j < a.count && !keptMask[j] { j += 1 }
            let span = String(a[i..<j])
            let context = String(a[max(0, i - 4)..<min(a.count, j + 6)])
            let isCorrection = correctionMarkers.contains { context.contains($0) }
            if !isCorrection {
                for word in contentWords(in: span) where !outputString.contains(word) {
                    return EditGuardResult(accepted: false, addedRatio: added, keptRatio: kept,
                                           reason: "内容語の削除を検出")
                }
                var rest = span
                for filler in fillerTokens { rest = rest.replacingOccurrences(of: filler, with: "") }
                if rest.count > 2 {
                    return EditGuardResult(accepted: false, addedRatio: added, keptRatio: kept,
                                           reason: "言葉の削除を検出")
                }
            }
            i = j
        }
        return EditGuardResult(accepted: true, addedRatio: added, keptRatio: kept, reason: nil)
    }

    /// NFKC, no whitespace / punctuation — only the words matter.
    static func normalize(_ s: String) -> String {
        let ignored = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .union(CharacterSet(charactersIn: "、。，．・「」『』（）()!?！？〜~"))
        return String(String.UnicodeScalarView(
            s.precomposedStringWithCompatibilityMapping.unicodeScalars.filter { !ignored.contains($0) }
        ))
    }

    /// Runs of 2+ kanji / katakana / latin / digit characters.
    static func contentWords(in s: String) -> [String] {
        var words: [String] = []
        var current = ""
        for ch in s {
            if isContent(ch) {
                current.append(ch)
            } else {
                if current.count >= 2 { words.append(current) }
                current = ""
            }
        }
        if current.count >= 2 { words.append(current) }
        return words
    }

    private static func isContent(_ c: Character) -> Bool {
        if c.isASCII { return c.isLetter || c.isNumber }
        return c.unicodeScalars.allSatisfy {
            (0x4E00...0x9FFF).contains($0.value) || (0x30A0...0x30FF).contains($0.value)
        }
    }

    /// Marks which characters of `a` belong to a longest common subsequence with `b`.
    static func lcsMask(_ a: [Character], _ b: [Character]) -> [Bool] {
        let n = a.count, m = b.count
        var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var mask = [Bool](repeating: false, count: n)
        var i = 0, j = 0
        while i < n && j < m {
            if a[i] == b[j] {
                mask[i] = true; i += 1; j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return mask
    }
}
