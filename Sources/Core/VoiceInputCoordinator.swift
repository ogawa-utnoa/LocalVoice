import Foundation
import Combine

public enum VoiceInputState: Equatable {
    case idle
    case recording(elapsedSeconds: Double)
    case transcribing(remainingChunks: Int)
    case rewriting
    case inserting
    case done(message: String)
    case error(message: String)

    public var displayText: String {
        switch self {
        case .idle:
            return "待機中"
        case .recording(let sec):
            return "録音中 (\(Int(sec))秒)"
        case .transcribing(let chunks):
            return "文字起こし中 (残\(chunks))"
        case .rewriting:
            return "文章整形中..."
        case .inserting:
            return "入力欄へ挿入中..."
        case .done(let msg):
            return msg
        case .error(let msg):
            return "エラー: \(msg)"
        }
    }
}

public final class VoiceInputCoordinator: ObservableObject, @unchecked Sendable {
    public static let shared = VoiceInputCoordinator()

    @Published public private(set) var currentState: VoiceInputState = .idle
    @Published public private(set) var currentAudioLevel: Float = 0.0
    @Published public private(set) var lastProcessedResult: ProcessedResult?

    private let captureService = AudioCaptureService.shared
    private var transcriptionQueue: TranscriptionQueue?
    private var recordingTimer: Timer?
    private var isProcessing = false
    private var resetWorkItem: DispatchWorkItem?

    private init() {
        setupCallbacks()
    }

    private func setupCallbacks() {
        captureService.onChunkReady = { [weak self] chunk in
            Task { [weak self] in
                await self?.transcriptionQueue?.enqueue(chunk: chunk)
            }
        }

        captureService.onMaxDurationReached = { [weak self] in
            Task { @MainActor [weak self] in
                AppLogger.shared.warn("Max recording duration reached. Stopping automatically.")
                await self?.stopRecordingAndProcess()
            }
        }

        captureService.onAudioLevel = { [weak self] level in
            DispatchQueue.main.async {
                self?.currentAudioLevel = level
            }
        }
    }

    /// Toggles recording on / off (called by the global shortcut or the menu bar).
    @MainActor
    public func toggleRecording() async {
        if captureService.currentlyRecording {
            await stopRecordingAndProcess()
        } else if isProcessing {
            AppLogger.shared.info("Toggle ignored: previous recording is still being processed")
        } else {
            await startRecording()
        }
    }

    @MainActor
    public func startRecording() async {
        guard !captureService.currentlyRecording, !isProcessing else { return }
        cancelPendingReset()

        // 1. Check microphone permission
        let hasMic = await captureService.checkMicrophonePermission()
        guard hasMic else {
            showTransient(.error(message: "マイク権限がありません（システム設定 > プライバシーとセキュリティ > マイク）"), seconds: 6)
            return
        }

        // Insertion needs Accessibility. Ask now (once per launch) so the user can fix it while speaking;
        // recording continues either way and the text will at least land on the clipboard.
        if !AccessibilityService.shared.isAccessibilityTrusted() {
            AppLogger.shared.warn("Accessibility not trusted at recording start")
            AccessibilityService.shared.requestPermissionIfNeeded()
        }

        // 2. Determine mode and resolve Whisper model
        let currentMode = ResourceMonitor.shared.determineRecommendedMode()
        guard let whisperModel = ModelManager.shared.resolveWhisperModelPath(for: currentMode) else {
            showTransient(.error(message: "Whisperモデルが見つかりません（Models/README.md）"), seconds: 6)
            return
        }
        AppLogger.shared.info("Recording start: mode=\(currentMode.rawValue) whisper=\(URL(fileURLWithPath: whisperModel).lastPathComponent)")

        let initialPrompt = UserDictionary.shared.generateWhisperPrompt()
        self.transcriptionQueue = TranscriptionQueue(modelPath: whisperModel, initialPrompt: initialPrompt)

        // 3. Start audio capture
        let settings = SettingsStore.shared.settings
        do {
            try captureService.startRecording(maxDurationSeconds: settings.maxRecordingDurationSeconds)
            self.currentState = .recording(elapsedSeconds: 0.0)
            startUIUpdateTimer()
        } catch {
            self.transcriptionQueue = nil
            showTransient(.error(message: "録音開始に失敗: \(error.localizedDescription)"), seconds: 6)
        }
    }

    @MainActor
    public func stopRecordingAndProcess() async {
        guard captureService.currentlyRecording, !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }

        stopUIUpdateTimer()
        let recordingDuration = captureService.currentRecordingDuration
        let queue = transcriptionQueue
        transcriptionQueue = nil

        // Step 1: Stop recording & finalize the remaining audio as the last chunk
        let finalChunk = captureService.stopRecording()
        if let lastChunk = finalChunk {
            await queue?.enqueue(chunk: lastChunk)
        }

        guard let queue = queue else {
            showTransient(.error(message: "内部エラー: 文字起こしキューがありません"), seconds: 5)
            return
        }

        // Step 2: Await all transcription chunks
        self.currentState = .transcribing(remainingChunks: await queue.pendingCount)
        let chunkResults = await queue.drainAndAwaitAll()
        let chunkTexts = chunkResults.map { $0.text }
        let totalWhisperDuration = chunkResults.reduce(0.0) { $0 + $1.durationSeconds }

        // Step 3: Rule-based + LLM rewriting
        self.currentState = .rewriting
        let mode = ResourceMonitor.shared.determineRecommendedMode()
        let processed = await TextProcessingPipeline.shared.process(
            transcribedChunks: chunkTexts,
            whisperDuration: totalWhisperDuration,
            mode: mode
        )
        self.lastProcessedResult = processed
        AppLogger.shared.info("Pipeline: raw=\(processed.rawMergedText.count) chars, final=\(processed.finalText.count) chars, usedLLM=\(processed.usedLLM), fallback=\(processed.fallbackOccurred) \(processed.fallbackReason ?? "")")

        // Step 4: Insert (or explain why nothing was inserted)
        var insertion: InsertionResult?
        if processed.finalText.isEmpty {
            if let whisperError = chunkResults.compactMap({ $0.errorMessage }).first {
                showTransient(.error(message: "文字起こしに失敗: \(whisperError)"), seconds: 8)
            } else if finalChunk == nil && chunkResults.isEmpty {
                showTransient(.error(message: "録音が短すぎました"), seconds: 4)
            } else {
                showTransient(.error(message: "音声を認識できませんでした（マイク入力を確認）"), seconds: 5)
            }
        } else {
            self.currentState = .inserting
            let result = await AccessibilityService.shared.insertText(processed.finalText)
            insertion = result
            switch result {
            case .directAccessibilitySuccess, .pasteEventSuccess:
                showTransient(.done(message: "✓ 入力しました"), seconds: 1.2)
            case .clipboardOnlyFallback(let reason):
                showTransient(.done(message: "📋 クリップボードに保存 — ⌘Vで貼り付け。\(reason)"), seconds: 6)
            }
        }

        // Step 5: Log session metrics (never the spoken text itself, Specification #30)
        var metrics = SessionMetrics()
        metrics.recordingDurationSeconds = recordingDuration
        metrics.chunkCount = chunkResults.count
        metrics.whisperProcessingTimeSeconds = totalWhisperDuration
        metrics.llmProcessingTimeSeconds = processed.llmDurationSeconds
        metrics.totalProcessingTimeSeconds = processed.totalProcessingDurationSeconds
        metrics.peakMemoryUsageMB = ResourceMonitor.shared.getCurrentProcessMemoryMB()
        metrics.fallbackTriggered = processed.fallbackOccurred
        metrics.fallbackReason = processed.fallbackReason
        if case .clipboardOnlyFallback = insertion { metrics.errorCode = "INSERT_CLIPBOARD_ONLY" }
        AppLogger.shared.recordSessionMetrics(metrics)
    }

    /// Shows a result / error for a few seconds, then returns to idle (unless something else started meanwhile).
    @MainActor
    private func showTransient(_ state: VoiceInputState, seconds: Double) {
        cancelPendingReset()
        currentState = state
        let item = DispatchWorkItem { [weak self] in
            guard let self = self, self.currentState == state else { return }
            self.currentState = .idle
        }
        resetWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func cancelPendingReset() {
        resetWorkItem?.cancel()
        resetWorkItem = nil
    }

    private func startUIUpdateTimer() {
        recordingTimer?.invalidate()
        // Scheduled from the main actor, so the block runs on the main run loop
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self, !self.isProcessing, self.captureService.currentlyRecording else { return }
            self.currentState = .recording(elapsedSeconds: self.captureService.currentRecordingDuration)
        }
    }

    private func stopUIUpdateTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
    }
}
