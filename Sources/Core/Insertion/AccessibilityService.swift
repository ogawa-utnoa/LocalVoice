import Foundation
import ApplicationServices
import AppKit

public enum InsertionResult: Equatable {
    case directAccessibilitySuccess
    case pasteEventSuccess
    case clipboardOnlyFallback(reason: String)
}

public final class AccessibilityService: @unchecked Sendable {
    public static let shared = AccessibilityService()

    private let lock = NSLock()
    private var didPromptThisLaunch = false

    private init() {}

    /// Checks whether the app currently has Accessibility permissions.
    /// Note: an ad-hoc signed app gets a new code signature on every rebuild, and macOS then treats the old
    /// permission as belonging to a different app (System Settings still shows the toggle ON, but this returns false).
    public func isAccessibilityTrusted(promptIfNeeded: Bool = false) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: promptIfNeeded]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// Shows the macOS permission dialog at most once per launch (the dialog links to System Settings).
    @discardableResult
    public func requestPermissionIfNeeded() -> Bool {
        if isAccessibilityTrusted(promptIfNeeded: false) { return true }
        lock.lock()
        let shouldPrompt = !didPromptThisLaunch
        didPromptThisLaunch = true
        lock.unlock()
        if shouldPrompt {
            _ = isAccessibilityTrusted(promptIfNeeded: true)
        }
        return false
    }

    public func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Inserts text into the focused input of the frontmost app.
    /// Tier 1: clipboard + ⌘V (works in Chrome / Safari / Slack / VS Code / Terminal / Notion / TextEdit alike)
    /// Tier 2: direct AXSelectedText write (only when synthetic key events cannot be created)
    /// Tier 3: clipboard only
    /// Guarantee: unless the user turned "keep on clipboard" off AND insertion succeeded, the text stays on the clipboard.
    ///
    /// Why paste first: AXUIElementSetAttributeValue(kAXSelectedText) returns .success in Chrome and Electron apps
    /// without inserting anything, so "AX first" silently loses the text in the most common targets.
    public func insertText(_ text: String) async -> InsertionResult {
        let settings = SettingsStore.shared.settings
        let previousClipboard = settings.copyToClipboardOnFinish ? nil : ClipboardService.shared.snapshot()

        // ALWAYS copy to clipboard first so the text is never lost
        ClipboardService.shared.copyToClipboard(text)

        guard settings.enableAutoInsertion else {
            return .clipboardOnlyFallback(reason: "自動挿入がオフです。")
        }

        guard isAccessibilityTrusted(promptIfNeeded: false) else {
            AppLogger.shared.warn("Accessibility permission not granted (or invalidated by rebuild). Text saved to clipboard.")
            requestPermissionIfNeeded()
            return .clipboardOnlyFallback(reason: "アクセシビリティ権限が無効です。")
        }

        let focusInfo = InputTargetDetector.getFocusedElement()
        AppLogger.shared.info("Insert target: app=\(focusInfo.appName ?? "?") role=\(focusInfo.role ?? "?") subrole=\(focusInfo.subrole ?? "-")")

        // Security safeguard: never auto-type into password / secure text fields
        if focusInfo.isSecure {
            AppLogger.shared.warn("Focused element is a secure text field. Skipping insertion.")
            return .clipboardOnlyFallback(reason: "パスワード欄のため自動入力しませんでした。")
        }

        await ClipboardService.shared.waitForModifierRelease()

        // Tier 1: ⌘V
        if ClipboardService.shared.sendPasteEvent() {
            AppLogger.shared.info("Inserted via ⌘V paste")
            if let previous = previousClipboard {
                // Give the target app time to read the pasteboard before restoring the old contents
                try? await Task.sleep(nanoseconds: 800_000_000)
                ClipboardService.shared.restore(previous)
            }
            return .pasteEventSuccess
        }

        // Tier 2: direct AX write
        if let target = focusInfo.element,
           AXUIElementSetAttributeValue(target, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success {
            AppLogger.shared.info("Inserted via AXSelectedTextAttribute")
            return .directAccessibilitySuccess
        }

        // Tier 3: clipboard only (text is already there)
        AppLogger.shared.warn("Both paste and AX insertion failed. Text left on clipboard.")
        return .clipboardOnlyFallback(reason: "自動入力に失敗しました。")
    }
}
