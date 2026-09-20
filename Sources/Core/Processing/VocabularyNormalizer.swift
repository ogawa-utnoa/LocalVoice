import Foundation

/// Rewrites known readings / misrecognitions to the dictionary spelling
/// ("クロード" -> "Claude", "Cloude Code" -> "Claude Code", "チャットGPT" -> "ChatGPT").
/// Deterministic, so it cannot invent content the way an LLM can.
public struct VocabularyNormalizer {

    public static func normalize(_ text: String, pairs: [(variant: String, word: String)]) -> String {
        var result = text
        for pair in pairs {
            result = replace(pair.variant, with: pair.word, in: result)
        }
        return result
    }

    /// Replaces whole-word occurrences only: a Latin variant must not touch neighbouring Latin letters
    /// ("Claud" must not match inside "Claude"), and a katakana variant must not be part of a longer katakana word.
    static func replace(_ variant: String, with word: String, in text: String) -> String {
        guard !variant.isEmpty, text.contains(variant) else { return text }
        var output = ""
        var index = text.startIndex
        while let range = text.range(of: variant, range: index..<text.endIndex) {
            let before = range.lowerBound > text.startIndex ? text[text.index(before: range.lowerBound)] : nil
            let after = range.upperBound < text.endIndex ? text[range.upperBound] : nil
            let ok = boundaryOK(variantEdge: variant.first!, neighbour: before)
                && boundaryOK(variantEdge: variant.last!, neighbour: after)
            output += text[index..<range.lowerBound]
            output += ok ? word : String(text[range])
            index = range.upperBound
        }
        output += text[index...]
        return output
    }

    private static func boundaryOK(variantEdge: Character, neighbour: Character?) -> Bool {
        guard let n = neighbour else { return true }
        if isLatin(variantEdge) && isLatin(n) { return false }
        if isKatakana(variantEdge) && isKatakana(n) { return false }
        return true
    }

    static func isLatin(_ c: Character) -> Bool {
        c.isASCII && c.isLetter
    }

    static func isKatakana(_ c: Character) -> Bool {
        c.unicodeScalars.allSatisfy { (0x30A0...0x30FF).contains($0.value) }
    }
}
