import Foundation

public struct OverlapMerger {
    
    /// Merges two overlapping transcribed texts (previous chunk and next chunk).
    /// Finds the optimal overlap point to eliminate duplicate phrases caused by the 2-second audio overlap.
    public static func merge(previousText: String, nextText: String) -> String {
        let prevTrimmed = previousText.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextTrimmed = nextText.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if prevTrimmed.isEmpty { return nextTrimmed }
        if nextTrimmed.isEmpty { return prevTrimmed }
        
        // Exact prefix match test:
        if nextTrimmed.hasPrefix(prevTrimmed) {
            return nextTrimmed
        }
        if prevTrimmed.hasSuffix(nextTrimmed) {
            return prevTrimmed
        }
        
        // Find longest matching suffix of prevTrimmed that matches a prefix of nextTrimmed
        let maxOverlapLength = min(prevTrimmed.count, nextTrimmed.count, 60) // Up to 60 chars (approx 2-3s speech)
        
        var bestOverlapCount = 0
        
        // Search from longest possible match down to minimum threshold of 3 characters
        for length in stride(from: maxOverlapLength, through: 3, by: -1) {
            let prevSuffix = String(prevTrimmed.suffix(length))
            let nextPrefix = String(nextTrimmed.prefix(length))
            
            if prevSuffix == nextPrefix {
                bestOverlapCount = length
                break
            }
            
            // Fuzzy match (ignore punctuation / spaces during comparison)
            let prevClean = cleanForComparison(prevSuffix)
            let nextClean = cleanForComparison(nextPrefix)
            if prevClean.count >= 3 && prevClean == nextClean {
                bestOverlapCount = length
                break
            }
        }
        
        if bestOverlapCount > 0 {
            let remainingNext = String(nextTrimmed.dropFirst(bestOverlapCount)).trimmingCharacters(in: .whitespacesAndNewlines)
            if remainingNext.isEmpty {
                return prevTrimmed
            }
            return prevTrimmed + (shouldAddSpace(prev: prevTrimmed, next: remainingNext) ? " " : "") + remainingNext
        }
        
        // No direct match found: check token-level overlap
        let prevWords = prevTrimmed.split(separator: " ").map(String.init)
        let nextWords = nextTrimmed.split(separator: " ").map(String.init)
        
        if prevWords.count > 1 && nextWords.count > 1 {
            let maxWordOverlap = min(prevWords.count, nextWords.count, 8)
            for wLen in stride(from: maxWordOverlap, through: 1, by: -1) {
                let pSuffixWords = Array(prevWords.suffix(wLen))
                let nPrefixWords = Array(nextWords.prefix(wLen))
                if pSuffixWords == nPrefixWords {
                    let remainingNextWords = nextWords.dropFirst(wLen).joined(separator: " ")
                    return prevTrimmed + " " + remainingNextWords
                }
            }
        }
        
        // Default concatenation with appropriate spacing
        let separator = shouldAddSpace(prev: prevTrimmed, next: nextTrimmed) ? " " : ""
        return prevTrimmed + separator + nextTrimmed
    }
    
    /// Merges an array of sequential chunk transcriptions.
    public static func mergeAll(_ transcriptions: [String]) -> String {
        guard !transcriptions.isEmpty else { return "" }
        var result = transcriptions[0]
        for i in 1..<transcriptions.count {
            result = merge(previousText: result, nextText: transcriptions[i])
        }
        return result
    }
    
    private static func cleanForComparison(_ text: String) -> String {
        let ignored: Set<Character> = ["、", "。", " ", "\n", "\t", ",", ".", "・"]
        return text.filter { !ignored.contains($0) }
    }
    
    private static func shouldAddSpace(prev: String, next: String) -> Bool {
        guard let lastChar = prev.last, let firstChar = next.first else { return false }
        // If both are ASCII alphanumeric, add space
        if lastChar.isASCII && !lastChar.isPunctuation && !lastChar.isWhitespace &&
           firstChar.isASCII && !firstChar.isPunctuation && !firstChar.isWhitespace {
            return true
        }
        // In Japanese text (CJK), spaces are usually not added between characters
        return false
    }
}
