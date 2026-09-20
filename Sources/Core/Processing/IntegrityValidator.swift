import Foundation

public struct IntegrityCheckResult: Equatable {
    public let isValid: Bool
    public let repairedText: String
    public let missingTokens: [String]
    public let alteredTokens: [String]
    public let reason: String?
}

public struct IntegrityValidator {
    
    /// Validates and ensures that essential entities from rawText are preserved in candidateText.
    /// Returns the repaired text if safe, or marks isValid = false if severe corruption/hallucination occurred.
    public static func validate(
        rawText: String,
        candidateText: String,
        customKeywords: [String] = []
    ) -> IntegrityCheckResult {
        // Extract entities from raw text
        let rawEntities = extractImportantEntities(from: rawText, customKeywords: customKeywords)
        
        var workingText = candidateText
        var missing: [String] = []
        var altered: [String] = []
        
        for entity in rawEntities {
            if !workingText.contains(entity) {
                // Check if it's a numeric representation difference (e.g. "3" vs "三", "１０" vs "10")
                if let normalizedMatch = findNormalizedMatch(entity: entity, in: workingText) {
                    // Automatically repair with original exact entity
                    workingText = workingText.replacingOccurrences(of: normalizedMatch, with: entity)
                } else {
                    missing.append(entity)
                }
            }
        }
        
        // Hallucination check: Check if candidate added URLs or emails not in raw text
        let candidateEntities = extractImportantEntities(from: workingText, customKeywords: [])
        for cEnt in candidateEntities {
            if (cEnt.contains("http://") || cEnt.contains("https://") || cEnt.contains("@")) && !rawText.contains(cEnt) {
                altered.append("Added: \(cEnt)")
            }
        }
        
        // Check text length ratio (hallucination / truncation check)
        let rawLen = rawText.trimmingCharacters(in: .whitespacesAndNewlines).count
        let candLen = workingText.trimmingCharacters(in: .whitespacesAndNewlines).count
        
        // If candidate is ridiculously short (< 30% of raw) or ridiculously long (> 250% of raw)
        if rawLen > 20 && (Double(candLen) < Double(rawLen) * 0.3 || Double(candLen) > Double(rawLen) * 2.5) {
            return IntegrityCheckResult(
                isValid: false,
                repairedText: rawText,
                missingTokens: missing,
                alteredTokens: altered,
                reason: "長さの急激な変化（要約または大幅な追加）が検出されました。"
            )
        }
        
        // If any critical entities are missing and could not be repaired
        if !missing.isEmpty || !altered.isEmpty {
            return IntegrityCheckResult(
                isValid: false,
                repairedText: rawText,
                missingTokens: missing,
                alteredTokens: altered,
                reason: "重要トークン（数字・日付・固有名詞等）の改変・欠落が検出されました: \(missing.joined(separator: ", "))"
            )
        }
        
        return IntegrityCheckResult(
            isValid: true,
            repairedText: workingText,
            missingTokens: [],
            alteredTokens: [],
            reason: nil
        )
    }
    
    /// Extracts numbers, dates, times, amounts, URLs, emails, and registered keywords.
    public static func extractImportantEntities(from text: String, customKeywords: [String] = []) -> [String] {
        var entities = Set<String>()
        
        // 1. Custom keywords (UserDictionary)
        for word in customKeywords {
            if !word.isEmpty && text.contains(word) {
                entities.insert(word)
            }
        }
        
        // 2. URLs
        let urlPattern = "https?://[a-zA-Z0-9./?=_-]+"
        if let regex = try? NSRegularExpression(pattern: urlPattern) {
            let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: text.utf16.count))
            for m in matches {
                if let r = Range(m.range, in: text) { entities.insert(String(text[r])) }
            }
        }
        
        // 3. Email addresses
        let emailPattern = "[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}"
        if let regex = try? NSRegularExpression(pattern: emailPattern) {
            let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: text.utf16.count))
            for m in matches {
                if let r = Range(m.range, in: text) { entities.insert(String(text[r])) }
            }
        }
        
        // 4. Numbers with units (e.g. 10時, 3つ, 100万円, 5000円, 2026年, 9月19日)
        let numUnitPattern = "\\d+(?:\\.\\d+)?(?:年|月|日|時|分|秒|円|万|億|つ|個|人|回|件|社|名|%)?"
        if let regex = try? NSRegularExpression(pattern: numUnitPattern) {
            let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: text.utf16.count))
            for m in matches {
                if let r = Range(m.range, in: text) {
                    let s = String(text[r])
                    if s.count > 1 || (s.first?.isNumber == true) {
                        entities.insert(s)
                    }
                }
            }
        }
        
        // 5. English words / brand names (e.g. Google, Workspace, AI, Claude, Codex)
        let englishPattern = "[A-Z][a-zA-Z0-9]+"
        if let regex = try? NSRegularExpression(pattern: englishPattern) {
            let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: text.utf16.count))
            for m in matches {
                if let r = Range(m.range, in: text) { entities.insert(String(text[r])) }
            }
        }
        
        return Array(entities)
    }
    
    private static func findNormalizedMatch(entity: String, in text: String) -> String? {
        // Map halfwidth to fullwidth to find candidate variant
        let halfToFull: [String: String] = [
            "0": "０", "1": "１", "2": "２", "3": "３", "4": "４",
            "5": "５", "6": "６", "7": "７", "8": "８", "9": "９"
        ]
        
        var fullVariant = entity
        for (hw, fw) in halfToFull {
            fullVariant = fullVariant.replacingOccurrences(of: hw, with: fw)
        }
        
        if text.contains(fullVariant) {
            return fullVariant
        }
        
        // Also check if text has halfwidth variant when entity is fullwidth
        var halfVariant = entity
        for (hw, fw) in halfToFull {
            halfVariant = halfVariant.replacingOccurrences(of: fw, with: hw)
        }
        if text.contains(halfVariant) {
            return halfVariant
        }
        
        return nil
    }
}
