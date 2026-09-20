import Foundation

public enum WhisperError: Error, LocalizedError {
    case binaryNotFound
    case modelNotFound(String)
    case executionFailed(Int32, String)
    case audioStoreError(String)
    case timedOut
    
    public var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "whisper-cli バイナリが見つかりません。Homebrew (brew install whisper-cpp) 等を確認してください。"
        case .modelNotFound(let path):
            return "Whisperモデルが見つかりません: \(path)"
        case .executionFailed(let code, let err):
            return "Whisper実行エラー (code \(code)): \(err)"
        case .audioStoreError(let msg):
            return "音声ファイル保存エラー: \(msg)"
        case .timedOut:
            return "Whisper処理がタイムアウトしました。"
        }
    }
}

public final class WhisperService: @unchecked Sendable {
    public static let shared = WhisperService()
    
    private let binaryPaths: [String] = [
        "/opt/homebrew/bin/whisper-cli",
        "/usr/local/bin/whisper-cli",
        "/opt/homebrew/bin/whisper-cpp",
        "/usr/local/bin/whisper-cpp"
    ]
    
    private init() {}
    
    public func findWhisperBinary() -> String? {
        for path in binaryPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }
    
    /// Transcribes 16kHz WAV audio samples using whisper-cli.
    public func transcribe(
        samples: [Float],
        modelPath: String,
        initialPrompt: String? = nil,
        language: String = "ja",
        threads: Int = 4
    ) async throws -> (text: String, durationSeconds: Double) {
        guard let binary = findWhisperBinary() else {
            throw WhisperError.binaryNotFound
        }
        
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw WhisperError.modelNotFound(modelPath)
        }
        
        let tempWavURL = TemporaryAudioStore.shared.createTempAudioFileURL(prefix: "whisper_in")
        defer {
            let deleteAudio = SettingsStore.shared.settings.deleteAudioAfterProcessing
            if deleteAudio {
                TemporaryAudioStore.shared.cleanupFile(at: tempWavURL)
            }
        }
        
        do {
            try TemporaryAudioStore.shared.writeWAVFile(samples: samples, sampleRate: 16000, destinationURL: tempWavURL)
        } catch {
            throw WhisperError.audioStoreError(error.localizedDescription)
        }
        
        return try await runWhisperProcess(
            binaryPath: binary,
            modelPath: modelPath,
            wavPath: tempWavURL.path,
            initialPrompt: initialPrompt,
            language: language,
            threads: threads
        )
    }
    
    private func runWhisperProcess(
        binaryPath: String,
        modelPath: String,
        wavPath: String,
        initialPrompt: String?,
        language: String,
        threads: Int
    ) async throws -> (text: String, durationSeconds: Double) {
        var args = [
            "-m", modelPath,
            "-f", wavPath,
            "-l", language,
            "-t", "\(threads)",
            "-nt" // no timestamps
        ]
        if let prompt = initialPrompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args.append(contentsOf: ["--prompt", prompt])
        }

        let output: ProcessOutput
        do {
            output = try await ProcessRunner.run(executable: binaryPath, arguments: args, timeout: 120)
        } catch {
            throw WhisperError.executionFailed(-1, error.localizedDescription)
        }

        if output.timedOut {
            throw WhisperError.timedOut
        }
        guard output.exitCode == 0 else {
            throw WhisperError.executionFailed(output.exitCode, String(output.stderr.suffix(400)))
        }
        return (text: cleanWhisperOutput(output.stdout), durationSeconds: output.durationSeconds)
    }
    
    private func cleanWhisperOutput(_ raw: String) -> String {
        // Strip whisper output brackets like [00:00:00.000 --> 00:00:04.000] if present
        let pattern = "\\[\\d{2}:\\d{2}:\\d{2}\\.\\d{3}\\s*-->\\s*\\d{2}:\\d{2}:\\d{2}\\.\\d{3}\\]"
        let regex = try? NSRegularExpression(pattern: pattern)
        let stripped = regex?.stringByReplacingMatches(in: raw, options: [], range: NSRange(location: 0, length: raw.utf16.count), withTemplate: "") ?? raw
        
        // Remove special whisper tokens like [BLANK_AUDIO], [MUSIC], etc.
        let tokenPattern = "\\[[A-Z0-9_]+\\]"
        let tokenRegex = try? NSRegularExpression(pattern: tokenPattern)
        let tokenStripped = tokenRegex?.stringByReplacingMatches(in: stripped, options: [], range: NSRange(location: 0, length: stripped.utf16.count), withTemplate: "") ?? stripped
        
        return tokenStripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
