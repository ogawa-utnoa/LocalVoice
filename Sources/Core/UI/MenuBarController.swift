import AppKit
import SwiftUI
import Combine

public final class MenuBarController: NSObject, @unchecked Sendable {
    public static let shared = MenuBarController()
    
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    private var settingsWindow: NSWindow?
    private var benchmarkWindow: NSWindow?
    
    private override init() {
        super.init()
    }
    
    @MainActor
    public func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusItemUI(state: VoiceInputCoordinator.shared.currentState)
        buildMenu()
        
        // Subscribe to coordinator state changes
        VoiceInputCoordinator.shared.$currentState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.updateStatusItemUI(state: state)
                self?.buildMenu()
            }
            .store(in: &cancellables)
    }
    
    @MainActor
    private func updateStatusItemUI(state: VoiceInputState) {
        guard let button = statusItem?.button else { return }
        let shortcut = SettingsStore.shared.settings.shortcutDisplayName
        
        switch state {
        case .idle:
            button.title = "🎙️"
            button.toolTip = "Local Voice Input (待機中) - [\(shortcut)] で録音"
        case .recording(let sec):
            button.title = "🔴 \(Int(sec))s"
            button.toolTip = "録音中... もう一度 [\(shortcut)] を押すと終了"
        case .transcribing:
            button.title = "⏳ 文字起こし"
            button.toolTip = "Whisperで音声を文字起こし中..."
        case .rewriting:
            button.title = "✨ 整文中"
            button.toolTip = "ローカルLLMで文章を整文中..."
        case .inserting:
            button.title = "✍️ 挿入中"
            button.toolTip = "アクティブな入力欄へ自動挿入中..."
        case .done(let msg):
            button.title = msg.hasPrefix("✓") ? "✓" : "📋"
            button.toolTip = msg
        case .error(let msg):
            button.title = "⚠️ エラー"
            button.toolTip = msg
        }
    }
    
    @MainActor
    private func buildMenu() {
        let menu = NSMenu()
        let coordinator = VoiceInputCoordinator.shared
        let isRecording = AudioCaptureService.shared.currentlyRecording
        let shortcut = SettingsStore.shared.settings.shortcutDisplayName
        
        // Status header
        let statusMenuItem = NSMenuItem(title: "状態: \(coordinator.currentState.displayText)", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Toggle Recording Item
        let toggleTitle = isRecording ? "録音を停止して文章を挿入 (\(shortcut))" : "録音を開始 (\(shortcut))"
        let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(toggleRecordingAction), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Permission status: an invalid Accessibility permission is the #1 reason text is not inserted
        if !AccessibilityService.shared.isAccessibilityTrusted() {
            let axItem = NSMenuItem(title: "⚠️ アクセシビリティ権限が無効（自動入力できません）...", action: #selector(openAccessibilitySettingsAction), keyEquivalent: "")
            axItem.target = self
            menu.addItem(axItem)
            menu.addItem(NSMenuItem.separator())
        }
        
        // Settings Item
        let settingsItem = NSMenuItem(title: "設定...", action: #selector(openSettingsAction), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        
        // Benchmark Item
        let benchmarkItem = NSMenuItem(title: "パフォーマンス測定 (ベンチマーク)...", action: #selector(openBenchmarkAction), keyEquivalent: "b")
        benchmarkItem.target = self
        menu.addItem(benchmarkItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let logItem = NSMenuItem(title: "ログを開く", action: #selector(openLogAction), keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Quit Item
        let quitItem = NSMenuItem(title: "終了", action: #selector(quitAction), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        statusItem?.menu = menu
    }
    
    @objc private func toggleRecordingAction() {
        Task { @MainActor in
            await VoiceInputCoordinator.shared.toggleRecording()
        }
    }
    
    @objc private func openSettingsAction() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.center()
            window.title = "LocalVoiceInput 設定"
            window.contentView = NSHostingView(rootView: SettingsView())
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc private func openBenchmarkAction() {
        if benchmarkWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 580, height: 440),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.center()
            window.title = "実機パフォーマンス測定"
            window.contentView = NSHostingView(rootView: BenchmarkView())
            window.isReleasedWhenClosed = false
            benchmarkWindow = window
        }
        benchmarkWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc private func openAccessibilitySettingsAction() {
        _ = AccessibilityService.shared.isAccessibilityTrusted(promptIfNeeded: true)
        AccessibilityService.shared.openAccessibilitySettings()
    }
    
    @objc private func openLogAction() {
        NSWorkspace.shared.open(AppLogger.shared.logFileURL)
    }
    
    @objc private func quitAction() {
        NSApplication.shared.terminate(nil)
    }
}
