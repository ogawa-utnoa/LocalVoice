import Foundation

public struct UserDictionaryEntry: Codable, Equatable, Identifiable {
    public var id: UUID
    /// Correct spelling, e.g. "Claude"
    public var word: String
    /// Readings / known misrecognitions separated by "," or "、", e.g. "クロード, Claud, Cloude".
    /// Every variant is rewritten to `word` after transcription.
    public var reading: String
    public var isPromptHint: Bool

    public init(id: UUID = UUID(), word: String, reading: String = "", isPromptHint: Bool = true) {
        self.id = id
        self.word = word
        self.reading = reading
        self.isPromptHint = isPromptHint
    }

    public var variants: [String] {
        reading
            .components(separatedBy: CharacterSet(charactersIn: ",、，"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != word }
    }
}

public final class UserDictionary: @unchecked Sendable {
    public static let shared = UserDictionary()

    private let key = "LocalVoiceUserDictionary"
    private let versionKey = "LocalVoiceUserDictionaryVersion"
    /// Bump when the defaults change so existing users receive the new words / variants.
    private static let defaultsVersion = 3
    private let lock = NSLock()
    private var entries: [UserDictionaryEntry]
    /// Words that came from the personal dictionary file; they go first into the Whisper prompt,
    /// because they are the words this person actually says.
    private var personalWords: Set<String> = []
    
    /// Optional personal dictionary kept outside the repository (names of your company, clients, people...).
    /// JSON array: [{"word": "正しい表記", "reading": "聞き間違い1, 聞き間違い2"}]. Merged on every launch.
    public static var personalFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".localvoice/dictionary.json")
    }
    
    /// Defaults for AI / Google product names. Variants come from real Whisper outputs
    /// (see scripts/eval_asr.py), e.g. large-v3-turbo writes "Claud" / "Cloude" for "Claude".
    public static let defaultEntries: [UserDictionaryEntry] = [
        UserDictionaryEntry(word: "Claude Code", reading: "クロードコード, クロード・コード, Claudeコード, Claude code, Cloude Code, Claud Code"),
        UserDictionaryEntry(word: "Claude", reading: "クロード, Claud, Cloude"),
        UserDictionaryEntry(word: "ChatGPT", reading: "チャットジーピーティー, チャットGPT, Chat GPT, ChatGBT"),
        UserDictionaryEntry(word: "Codex", reading: "コーデックス"),
        UserDictionaryEntry(word: "Antigravity", reading: "アンチグラビティ, アンティグラビティ, AntiGravity"),
        UserDictionaryEntry(word: "Gemini", reading: "ジェミニ"),
        UserDictionaryEntry(word: "NotebookLM", reading: "ノートブックLM, ノートブックエルエム, Notebook LM"),
        UserDictionaryEntry(word: "Google Workspace", reading: "Googleワークスペース, グーグルワークスペース, Google workspace, GoogleWorkspace"),
        UserDictionaryEntry(word: "Typeless", reading: "タイプレス")
    ]
    
    private init() {
        let defaults = UserDefaults.standard
        var loadedEntries: [UserDictionaryEntry]
        if let data = defaults.data(forKey: key),
           let loaded = try? JSONDecoder().decode([UserDictionaryEntry].self, from: data) {
            if defaults.integer(forKey: versionKey) < Self.defaultsVersion {
                loadedEntries = Self.migrate(loaded)
                defaults.set(Self.defaultsVersion, forKey: versionKey)
                if let encoded = try? JSONEncoder().encode(loadedEntries) {
                    defaults.set(encoded, forKey: key)
                }
            } else {
                loadedEntries = loaded
            }
        } else {
            loadedEntries = Self.defaultEntries
            defaults.set(Self.defaultsVersion, forKey: versionKey)
        }
        self.entries = Self.merge(loadedEntries, withPersonalFile: Self.personalFileURL)
        self.personalWords = Set(Self.personalEntries(at: Self.personalFileURL).map { $0.word })
    }
    
    /// Adds new default words / variants without touching words the user added.
    public static func migrate(_ old: [UserDictionaryEntry]) -> [UserDictionaryEntry] {
        union(old, with: defaultEntries)
    }
    
    /// Merges a personal dictionary file. A missing or unreadable file changes nothing.
    public static func merge(_ base: [UserDictionaryEntry], withPersonalFile url: URL) -> [UserDictionaryEntry] {
        union(base, with: personalEntries(at: url))
    }
    
    static func personalEntries(at url: URL) -> [UserDictionaryEntry] {
        struct FileEntry: Decodable { let word: String; let reading: String? }
        guard let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([FileEntry].self, from: data) else {
            return []
        }
        return items
            .filter { !$0.word.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { UserDictionaryEntry(word: $0.word.trimmingCharacters(in: .whitespaces), reading: $0.reading ?? "") }
    }
    
    /// Adds entries whose word is missing, and adds missing variants to words that already exist.
    static func union(_ base: [UserDictionaryEntry], with extra: [UserDictionaryEntry]) -> [UserDictionaryEntry] {
        var result = base
        for add in extra {
            if let i = result.firstIndex(where: { $0.word == add.word }) {
                let existing = Set(result[i].variants)
                let missing = add.variants.filter { !existing.contains($0) }
                if !missing.isEmpty {
                    result[i].reading = (result[i].variants + missing).joined(separator: ", ")
                }
            } else {
                result.append(add)
            }
        }
        return result
    }
    
    public var allEntries: [UserDictionaryEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    public func addEntry(word: String, reading: String = "", isPromptHint: Bool = true) {
        lock.lock()
        defer { lock.unlock() }
        let word = word.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty, !entries.contains(where: { $0.word == word }) else { return }
        entries.append(UserDictionaryEntry(word: word, reading: reading, isPromptHint: isPromptHint))
        persist()
    }

    public func removeEntry(id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll { $0.id == id }
        persist()
    }

    /// Whisper's initial prompt acts as "previous text", so a Japanese-punctuated word list works best
    /// (measured: product-name accuracy 0/36 -> 30/36 on large-v3-turbo). Whisper itself caps it at ~224 tokens,
    /// so this stays at 150 characters; personal words come first when the list does not fit.
    public func generateWhisperPrompt(maxCharacters: Int = 150) -> String {
        lock.lock()
        defer { lock.unlock() }
        return Self.promptText(hints: entries.filter { $0.isPromptHint }.map { $0.word },
                               personal: personalWords,
                               maxCharacters: maxCharacters)
    }
    
    /// Measured on large-v3-turbo: 9 words (90 characters) gives CER 0.7%, 17 words (150) 1.3%,
    /// 37 words (300) 3.7% — a long list makes Whisper worse. So the list stays short: shipped words first,
    /// then personal words in file order until the budget is used up.
    public static func promptText(hints: [String], personal: Set<String>, maxCharacters: Int) -> String {
        let ordered = hints.filter { !personal.contains($0) } + hints.filter { personal.contains($0) }
        var prompt = ""
        for word in ordered {
            let next = prompt.isEmpty ? word : prompt + "、" + word
            if next.count > maxCharacters { break }
            prompt = next
        }
        return prompt.isEmpty ? "" : prompt + "。"
    }

    public var wordsToProtect: [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries.map { $0.word }
    }

    /// (variant, correct word) pairs, longest variant first so "クロードコード" wins over "クロード".
    public var replacementPairs: [(variant: String, word: String)] {
        lock.lock()
        defer { lock.unlock() }
        return entries
            .flatMap { entry in entry.variants.map { (variant: $0, word: entry.word) } }
            .sorted { $0.variant.count > $1.variant.count }
    }

    private func persist() {
        let data = try? JSONEncoder().encode(entries)
        UserDefaults.standard.set(data, forKey: key)
    }
}
