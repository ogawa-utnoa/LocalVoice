import Foundation

public enum AppOperatingMode: String, Codable, CaseIterable {
    case normal = "Normal"
    case lowMemory = "Low Memory"
    case emergency = "Emergency"
}

public struct LocalVoiceSettings: Codable, Equatable {
    public var shortcutKeyCode: UInt16 = 49 // Space
    public var shortcutModifiers: UInt = 524288 // NSEvent.ModifierFlags.option.rawValue
    public var shortcutDisplayName: String = "Option + Space"
    
    public var maxRecordingDurationSeconds: Double = 600.0 // 10 minutes
    public var chunkDurationSeconds: Double = 30.0
    public var chunkOverlapSeconds: Double = 2.0
    
    public var whisperModelPath: String = ""
    public var llmModelPath: String = ""
    public var autoModelSelection: Bool = true
    
    public var enableFillerRemoval: Bool = true
    public var enableLLMRewrite: Bool = true
    public var enableAutoInsertion: Bool = true
    public var copyToClipboardOnFinish: Bool = true
    public var deleteAudioAfterProcessing: Bool = true
    
    public var logLevel: String = "INFO" // DEBUG, INFO, WARN, ERROR
    public var modelsDirectory: String = ""
    
    public init() {}
}

public final class SettingsStore: @unchecked Sendable {
    public static let shared = SettingsStore()
    
    private let userDefaultsKey = "LocalVoiceSettings"
    private let lock = NSLock()
    private var currentSettings: LocalVoiceSettings
    
    private init() {
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let loaded = try? JSONDecoder().decode(LocalVoiceSettings.self, from: data) {
            self.currentSettings = loaded
        } else {
            self.currentSettings = LocalVoiceSettings()
        }
    }
    
    public var settings: LocalVoiceSettings {
        get {
            lock.lock()
            defer { lock.unlock() }
            return currentSettings
        }
        set {
            lock.lock()
            currentSettings = newValue
            let data = try? JSONEncoder().encode(newValue)
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
            lock.unlock()
        }
    }
    
    public func update(_ block: (inout LocalVoiceSettings) -> Void) {
        lock.lock()
        var copy = currentSettings
        block(&copy)
        currentSettings = copy
        let data = try? JSONEncoder().encode(copy)
        UserDefaults.standard.set(data, forKey: userDefaultsKey)
        lock.unlock()
    }
}
