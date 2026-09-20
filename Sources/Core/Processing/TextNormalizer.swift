import Foundation

public struct TextNormalizer {
    
    /// Normalizes Japanese text punctuation, paragraph breaks, and spacing.
    public static func normalize(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.isEmpty { return "" }
        
        // Remove trailing commas
        while result.hasSuffix("、") || result.hasSuffix(",") {
            result.removeLast()
        }
        
        // Ensure sentence ends with period if it looks like a complete sentence
        let endsWithPunctuation = ["。", "！", "？", "!", "?", "…", "」", "）", ")"].contains(where: { result.hasSuffix($0) })
        if !endsWithPunctuation && !result.isEmpty {
            result += "。"
        }
        
        // Remove redundant consecutive spaces
        let spaceRegex = try? NSRegularExpression(pattern: "[ \\t]{2,}")
        result = spaceRegex?.stringByReplacingMatches(
            in: result,
            options: [],
            range: NSRange(location: 0, length: result.utf16.count),
            withTemplate: " "
        ) ?? result
        
        // Remove extra blank lines (limit to max 2 newlines)
        let newlineRegex = try? NSRegularExpression(pattern: "\n{3,}")
        result = newlineRegex?.stringByReplacingMatches(
            in: result,
            options: [],
            range: NSRange(location: 0, length: result.utf16.count),
            withTemplate: "\n\n"
        ) ?? result
        
        return result
    }
}
