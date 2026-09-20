import Foundation

public struct FillerProcessor {
    
    // Fillers that are usually safe to remove when at the start of sentence, after punctuation, or isolated.
    private static let contextFillers: [String] = [
        "えーっと",
        "えっと",
        "えー",
        "えーと",
        "あー",
        "あのー",
        "そのー",
        "そのえーと",
        "うーん"
    ]
    
    // Words that must be protected if followed or preceded by specific characters (e.g. あの人, まあまあ)
    private static let protectedWords: Set<String> = [
        "あの人", "あの件", "あの時", "あの日", "あの場所", "あの会社", "あの本",
        "まあまあ", "ええ", "ええと", "えーい", "なんかの"
    ]
    
    /// Cleans fillers conservatively while strictly protecting semantic meaning.
    public static func removeFillers(_ text: String) -> String {
        var processed = text
        
        // 1. Remove isolated single-filler utterances
        let trimmed = processed.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["あー", "えー", "えっと", "えーっと", "あのー", "そのー", "うーん", "あー。"].contains(trimmed) {
            return ""
        }
        
        // 2. Clear prominent fillers appearing after start of sentence or after punctuation
        // Patterns like: (^|[、。\n\s])(あー|えー|えっと|えーっと|あのー|そのー)[、\s]*
        for filler in contextFillers {
            // Regex match boundary: start of text or punctuation/whitespace
            let pattern = "(^|[、。\n\\s])" + NSRegularExpression.escapedPattern(for: filler) + "([、\\s]+|$)"
            if let regex = try? NSRegularExpression(pattern: pattern) {
                processed = regex.stringByReplacingMatches(
                    in: processed,
                    options: [],
                    range: NSRange(location: 0, length: processed.utf16.count),
                    withTemplate: "$1"
                )
            }
        }
        
        // 3. Handle "あの" carefully: remove only if followed by punctuation like "あの、"
        if let regexAno = try? NSRegularExpression(pattern: "(^|[、。\n\\s])あの、") {
            processed = regexAno.stringByReplacingMatches(
                in: processed,
                options: [],
                range: NSRange(location: 0, length: processed.utf16.count),
                withTemplate: "$1"
            )
        }
        
        // 4. Handle "まあ" carefully: remove only if followed by "、" and not part of "まあまあ"
        if !processed.contains("まあまあ") {
            if let regexMaa = try? NSRegularExpression(pattern: "(^|[、。\n\\s])まあ、") {
                processed = regexMaa.stringByReplacingMatches(
                    in: processed,
                    options: [],
                    range: NSRange(location: 0, length: processed.utf16.count),
                    withTemplate: "$1"
                )
            }
        }
        
        // 5. Clean up dangling commas and extra spaces
        processed = cleanPunctuationAndSpacing(processed)
        
        return processed
    }
    
    private static func cleanPunctuationAndSpacing(_ text: String) -> String {
        var result = text
        // Clean double commas like "、、" -> "、"
        while result.contains("、、") {
            result = result.replacingOccurrences(of: "、、", with: "、")
        }
        // Remove leading commas or punctuation
        while result.hasPrefix("、") || result.hasPrefix("。") {
            result.removeFirst()
        }
        // Collapse multiple spaces
        let spaceRegex = try? NSRegularExpression(pattern: "[ \\t]{2,}")
        result = spaceRegex?.stringByReplacingMatches(
            in: result,
            options: [],
            range: NSRange(location: 0, length: result.utf16.count),
            withTemplate: " "
        ) ?? result
        
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
