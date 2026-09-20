import Foundation
import AppKit
import Carbon

public final class ClipboardService: @unchecked Sendable {
    public static let shared = ClipboardService()

    /// A copy of every item/type on the pasteboard, so the user's previous clipboard can be restored.
    public struct Snapshot {
        fileprivate let items: [[NSPasteboard.PasteboardType: Data]]
    }

    private init() {}

    /// Copies text to system clipboard.
    public func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    public func snapshot() -> Snapshot {
        let items = NSPasteboard.general.pasteboardItems ?? []
        let copied: [[NSPasteboard.PasteboardType: Data]] = items.map { item in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { dict[type] = data }
            }
            return dict
        }
        return Snapshot(items: copied)
    }

    public func restore(_ snapshot: Snapshot) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let items: [NSPasteboardItem] = snapshot.items.map { dict in
            let item = NSPasteboardItem()
            for (type, data) in dict { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }

    /// Waits (without blocking the main thread) until the user has released Option / Command / Control / Shift,
    /// so the synthetic ⌘V is not merged with the still-held shortcut modifiers (e.g. ⌥⌘V = "move" in Finder).
    public func waitForModifierRelease(timeout: TimeInterval = 1.5) async {
        let mask: CGEventFlags = [.maskAlternate, .maskCommand, .maskControl, .maskShift]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let flags = CGEventSource.flagsState(.hidSystemState)
            if flags.intersection(mask).isEmpty { return }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    /// Simulates ⌘V into the frontmost app. Returns false when the events could not be created.
    /// Requires Accessibility permission; without it macOS silently drops the events.
    @discardableResult
    public func sendPasteEvent() -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        let cmdKey = CGKeyCode(kVK_Command)
        let vKey = CGKeyCode(kVK_ANSI_V) // same physical key on JIS and US keyboards

        guard let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: cmdKey, keyDown: true),
              let vDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false),
              let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: cmdKey, keyDown: false) else {
            return false
        }
        cmdDown.flags = .maskCommand
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand
        cmdUp.flags = []

        cmdDown.post(tap: .cghidEventTap)
        vDown.post(tap: .cghidEventTap)
        vUp.post(tap: .cghidEventTap)
        cmdUp.post(tap: .cghidEventTap)
        return true
    }
}
