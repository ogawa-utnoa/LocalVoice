import Foundation

public struct ModelDescriptor: Equatable, Hashable {
    public let name: String
    public let path: String
    public let fileSizeMB: Double
    public let isWhisper: Bool
    public let isLLM: Bool
}

public final class ModelManager: @unchecked Sendable {
    public static let shared = ModelManager()
    
    private let lock = NSLock()
    
    private init() {}
    
    public var candidateModelDirectories: [URL] {
        var dirs: [URL] = []
        
        // 1. Next to the app bundle (e.g. LocalVoice/Models)
        let bundleParent = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Models")
        dirs.append(bundleParent)
        
        // 2. Current working directory (swift run / tests from the repository root)
        let cwdModels = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Models")
        dirs.append(cwdModels)
        
        // 3. User home directory ~/.localvoiceinput/models
        let homeModels = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".localvoiceinput/models", isDirectory: true)
        dirs.append(homeModels)
        
        return dirs
    }
    
    public var defaultModelsDirectoryURL: URL {
        for dir in candidateModelDirectories {
            if FileManager.default.fileExists(atPath: dir.path) {
                return dir
            }
        }
        return candidateModelDirectories.first!
    }
    
    /// Finds all available Whisper and LLM models.
    public func scanAvailableModels(in customDirectory: String? = nil) -> [ModelDescriptor] {
        lock.lock()
        defer { lock.unlock() }
        
        var targetDirs: [URL] = []
        if let custom = customDirectory, !custom.isEmpty {
            targetDirs.append(URL(fileURLWithPath: custom))
        } else {
            targetDirs = candidateModelDirectories
        }
        
        var results: [ModelDescriptor] = []
        var seenPaths = Set<String>()
        
        for dirURL in targetDirs {
            guard let items = try? FileManager.default.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: [.fileSizeKey]) else {
                continue
            }
            
            for file in items {
                guard !seenPaths.contains(file.path) else { continue }
                seenPaths.insert(file.path)
                
                let name = file.lastPathComponent
                guard let attrs = try? file.resourceValues(forKeys: [.fileSizeKey]),
                      let size = attrs.fileSize else { continue }
                let sizeMB = Double(size) / (1024 * 1024)
                
                let isWhisper = name.hasPrefix("ggml-") && name.hasSuffix(".bin")
                let isLLM = name.hasSuffix(".gguf")
                
                if isWhisper || isLLM {
                    results.append(ModelDescriptor(
                        name: name,
                        path: file.path,
                        fileSizeMB: sizeMB,
                        isWhisper: isWhisper,
                        isLLM: isLLM
                    ))
                }
            }
        }
        return results
    }
    
    /// Resolves Whisper model path based on operating mode and manual overrides.
    public func resolveWhisperModelPath(for mode: AppOperatingMode) -> String? {
        let settings = SettingsStore.shared.settings
        if !settings.autoModelSelection && !settings.whisperModelPath.isEmpty {
            if FileManager.default.fileExists(atPath: settings.whisperModelPath) {
                return settings.whisperModelPath
            }
        }
        
        let models = scanAvailableModels(in: settings.modelsDirectory.isEmpty ? nil : settings.modelsDirectory)
        let whisperModels = models.filter { $0.isWhisper }
        
        switch mode {
        case .normal:
            // Measured on Japanese speech with product names (scripts/eval_asr.py, with vocabulary prompt):
            // large-v3-turbo q5_0 CER 2.1% vs small 6.3%, ~1.7s per utterance on M4.
            if let turbo = whisperModels.first(where: { $0.name.contains("large-v3-turbo") }) {
                return turbo.path
            }
            if let medium = whisperModels.first(where: { $0.name.contains("medium") }) {
                return medium.path
            }
            if let small = whisperModels.first(where: { $0.name.contains("small") }) {
                return small.path
            }
            return whisperModels.first?.path
            
        case .lowMemory, .emergency:
            if let small = whisperModels.first(where: { $0.name.contains("small") }) {
                return small.path
            }
            if let tiny = whisperModels.first(where: { $0.name.contains("tiny") }) {
                return tiny.path
            }
            return whisperModels.first?.path
        }
    }
    
    /// Resolves LLM model path based on operating mode.
    public func resolveLLMModelPath(for mode: AppOperatingMode) -> String? {
        let settings = SettingsStore.shared.settings
        if !settings.autoModelSelection && !settings.llmModelPath.isEmpty {
            if FileManager.default.fileExists(atPath: settings.llmModelPath) {
                return settings.llmModelPath
            }
        }
        
        if mode == .emergency {
            return nil
        }
        
        let models = scanAvailableModels(in: settings.modelsDirectory.isEmpty ? nil : settings.modelsDirectory)
        let llmModels = models.filter { $0.isLLM }
        
        switch mode {
        case .normal:
            if let normalModel = llmModels.first(where: { $0.name.contains("1.5b") || $0.name.contains("1.7b") }) {
                return normalModel.path
            }
            return llmModels.first?.path
            
        case .lowMemory:
            if let lowModel = llmModels.first(where: { $0.name.contains("0.5b") || $0.name.contains("0.6b") }) {
                return lowModel.path
            }
            return llmModels.first?.path
            
        case .emergency:
            return nil
        }
    }
}
