import Foundation

public struct RewriteDetector {
    
    /// Normalizes common verbal corrections and slips-of-the-tongue.
    public static func processCorrections(_ text: String) -> String {
        var processed = text
        
        // Pattern 1: Word + "、いや" + CorrectedWord (e.g. "来週の火曜日、いや水曜日の10時" -> "来週の水曜日の10時")
        // Match optional prefix with particle 'の', then word1, then "いや", then word2
        // "いや" must follow a comma/space, so words like "それはいやです" are never touched
        let iyaPattern = "(?:([^、。\n\\s]+?の))?([^、。\n\\s]{1,8})[、\\s]+いや[、\\s]*([^、。\n\\s]{1,8})"
        if let regexIya = try? NSRegularExpression(pattern: iyaPattern) {
            let matches = regexIya.matches(in: processed, options: [], range: NSRange(location: 0, length: processed.utf16.count))
            for match in matches.reversed() {
                let prefixRange = match.range(at: 1)
                let word1Range = match.range(at: 2)
                let word2Range = match.range(at: 3)
                
                if let r1 = Range(word1Range, in: processed),
                   let r2 = Range(word2Range, in: processed),
                   let fullRange = Range(match.range(at: 0), in: processed) {
                    let word1 = String(processed[r1])
                    let word2 = String(processed[r2])
                    let prefix: String
                    if prefixRange.location != NSNotFound, let pr = Range(prefixRange, in: processed) {
                        prefix = String(processed[pr])
                    } else {
                        prefix = ""
                    }
                    
                    if shouldReplaceCorrection(word1: word1, word2: word2) {
                        processed.replaceSubrange(fullRange, with: prefix + word2)
                    }
                }
            }
        }
        
        // Pattern 2: "〜じゃなくて〜" or "〜ではなくて〜" (e.g. "火曜じゃなくて水曜")
        // word1 cannot contain particles, so only the corrected word is dropped ("これはペンじゃなくて鉛筆" -> "これは鉛筆"),
        // and hiragana-only word1 is skipped because it is usually a fragment of a longer word.
        let jyanakutePattern = "([^、。\n\\sのはがをにでとも]{1,8})[、\\s]*(?:じゃなくて|ではなくて|ではなく)[、\\s]*([^、。\n\\s]{1,15})"
        if let regexJya = try? NSRegularExpression(pattern: jyanakutePattern) {
            let matches = regexJya.matches(in: processed, options: [], range: NSRange(location: 0, length: processed.utf16.count))
            for match in matches.reversed() {
                if let range1 = Range(match.range(at: 1), in: processed),
                   let range2 = Range(match.range(at: 2), in: processed),
                   let fullRange = Range(match.range(at: 0), in: processed) {
                    let word1 = String(processed[range1])
                    guard !isHiraganaOnly(word1) else { continue }
                    let word2 = String(processed[range2])
                    processed.replaceSubrange(fullRange, with: word2)
                }
            }
        }
        
        // Pattern 3: Immediate word stutter / repetition (e.g. "そのその", "今日の今日の")
        // 3+ characters only: 2-character reduplications are real words (いろいろ, そろそろ, まあまあ, どんどん)
        let stutterPattern = "([^、。\n\\s]{3,8})\\1"
        if let regexStutter = try? NSRegularExpression(pattern: stutterPattern) {
            processed = regexStutter.stringByReplacingMatches(
                in: processed,
                options: [],
                range: NSRange(location: 0, length: processed.utf16.count),
                withTemplate: "$1"
            )
        }
        
        return processed
    }
    
    private static func isHiraganaOnly(_ word: String) -> Bool {
        word.unicodeScalars.allSatisfy { (0x3040...0x309F).contains($0.value) || $0.value == 0x30FC }
    }
    
    private static func shouldReplaceCorrection(word1: String, word2: String) -> Bool {
        // Exclude common phrases where "いや" is not a slip-of-the-tongue
        let negativeKeywords = ["いやだ", "いやがる", "いやな"]
        if negativeKeywords.contains(where: { word2.hasPrefix($0) }) {
            return false
        }
        return true
    }
}
