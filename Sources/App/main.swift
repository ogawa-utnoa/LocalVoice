import AppKit
import SwiftUI
import LocalVoiceCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLogger.shared.info("LocalVoice application starting...")
        
        // Setup Menu Bar Item
        MenuBarController.shared.setup()
        
        // Setup Floating Overlay (Typeless-like indicator)
        RecordingOverlayController.shared.setup()
        
        // Start Global Shortcut Listener (Option + Space)
        GlobalShortcutManager.shared.onTrigger = {
            Task { @MainActor in
                await VoiceInputCoordinator.shared.toggleRecording()
            }
        }
        GlobalShortcutManager.shared.startMonitoring()
        
        // Check initial permissions in background
        Task {
            let hasMic = await AudioCaptureService.shared.checkMicrophonePermission()
            let hasAX = AccessibilityService.shared.isAccessibilityTrusted(promptIfNeeded: false)
            
            AppLogger.shared.info("Permissions check: Microphone=\(hasMic), Accessibility=\(hasAX)")
            
            let currentMode = ResourceMonitor.shared.determineRecommendedMode()
            AppLogger.shared.info("System memory status: Mode=\(currentMode.rawValue)")
            
            let models = ModelManager.shared.scanAvailableModels()
            AppLogger.shared.info("Detected \(models.count) local models in scan directory.")
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        GlobalShortcutManager.shared.stopMonitoring()
        TemporaryAudioStore.shared.cleanupAll()
        AppLogger.shared.info("LocalVoice terminated cleanly.")
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // Menu bar only app (does not show in Dock)
app.run()
