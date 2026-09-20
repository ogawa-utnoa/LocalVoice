import Foundation
import AppKit
import Carbon

public final class GlobalShortcutManager: @unchecked Sendable {
    public static let shared = GlobalShortcutManager()
    
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    
    public var onTrigger: (@Sendable () -> Void)?
    
    private let hotKeySignature: OSType = 0x4C564950 // 'LVIP'
    private let hotKeyId: UInt32 = 1
    
    private init() {}
    
    public func startMonitoring() {
        stopMonitoring()
        
        let targetKeyCode = SettingsStore.shared.settings.shortcutKeyCode // e.g. 49 (Space)
        let rawModifiers = SettingsStore.shared.settings.shortcutModifiers
        let targetModifiers = NSEvent.ModifierFlags(rawValue: rawModifiers)
            .intersection([.control, .option, .shift, .command])
        
        // 1. Register Carbon HotKey (Rock-solid system-wide hook, works even without accessibility permissions)
        registerCarbonHotKey(keyCode: targetKeyCode, modifiers: targetModifiers)
        
        // 2. Backup NSEvent monitors using deviceIndependentFlagsMask
        let cleanTargetMask = targetModifiers.rawValue
        
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let cleanEventMask = event.modifierFlags.intersection(.deviceIndependentFlagsMask).intersection([.control, .option, .shift, .command]).rawValue
            if event.keyCode == targetKeyCode && cleanEventMask == cleanTargetMask {
                self?.handleTrigger()
            }
        }
        
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let cleanEventMask = event.modifierFlags.intersection(.deviceIndependentFlagsMask).intersection([.control, .option, .shift, .command]).rawValue
            if event.keyCode == targetKeyCode && cleanEventMask == cleanTargetMask {
                self?.handleTrigger()
                return nil
            }
            return event
        }
        
        AppLogger.shared.info("Global shortcut listener active for: \(SettingsStore.shared.settings.shortcutDisplayName)")
    }
    
    public func stopMonitoring() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let hRef = eventHandlerRef {
            RemoveEventHandler(hRef)
            eventHandlerRef = nil
        }
        if let gm = globalMonitor {
            NSEvent.removeMonitor(gm)
            globalMonitor = nil
        }
        if let lm = localMonitor {
            NSEvent.removeMonitor(lm)
            localMonitor = nil
        }
    }
    
    private var lastTriggerTime: TimeInterval = 0
    private func handleTrigger() {
        // Debounce triggers within 300ms to avoid double toggles from Carbon + NSEvent
        let now = Date().timeIntervalSince1970
        guard now - lastTriggerTime > 0.35 else { return }
        lastTriggerTime = now
        
        AppLogger.shared.info("Shortcut triggered (Toggle recording requested)")
        onTrigger?()
    }
    
    private func registerCarbonHotKey(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        
        let handler: EventHandlerUPP = { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            if status == noErr && hotKeyID.signature == 0x4C564950 && hotKeyID.id == 1 {
                GlobalShortcutManager.shared.handleTrigger()
            }
            return noErr
        }
        
        InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventType, nil, &eventHandlerRef)
        
        var carbonMods: UInt32 = 0
        if modifiers.contains(.command) { carbonMods |= UInt32(cmdKey) }
        if modifiers.contains(.option) { carbonMods |= UInt32(optionKey) }
        if modifiers.contains(.control) { carbonMods |= UInt32(controlKey) }
        if modifiers.contains(.shift) { carbonMods |= UInt32(shiftKey) }
        
        let hotKeyID = EventHotKeyID(signature: hotKeySignature, id: hotKeyId)
        let status = RegisterEventHotKey(
            UInt32(keyCode),
            carbonMods,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if status == noErr {
            AppLogger.shared.info("Carbon hotkey registered")
        } else {
            // e.g. the combination is taken by another app or rejected by macOS; the NSEvent monitors remain as backup
            AppLogger.shared.warn("Carbon hotkey registration failed (OSStatus \(status)); relying on NSEvent monitors")
        }
    }
    
    /// Updates the registered shortcut and restarts the event monitor.
    public func updateShortcut(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        let cleanModifiers = modifiers.intersection([.control, .option, .shift, .command])
        let displayName = Self.formatShortcut(keyCode: keyCode, modifiers: cleanModifiers)
        
        SettingsStore.shared.update { settings in
            settings.shortcutKeyCode = keyCode
            settings.shortcutModifiers = cleanModifiers.rawValue
            settings.shortcutDisplayName = displayName
        }
        
        startMonitoring()
        AppLogger.shared.info("Updated global shortcut to: \(displayName)")
    }
    
    /// Formats key code and modifier flags into human-readable string (e.g. "⌥ Option + Space").
    public static func formatShortcut(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("⌃ Control") }
        if modifiers.contains(.option) { parts.append("⌥ Option") }
        if modifiers.contains(.shift) { parts.append("⇧ Shift") }
        if modifiers.contains(.command) { parts.append("⌘ Command") }
        
        let keyName = keyDisplayName(for: keyCode)
        parts.append(keyName)
        
        return parts.joined(separator: " + ")
    }
    
    public static func keyDisplayName(for keyCode: UInt16) -> String {
        switch keyCode {
        case 49: return "Space"
        case 36: return "Return"
        case 48: return "Tab"
        case 51: return "Delete"
        case 53: return "Escape"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 122: return "F1"
        case 120: return "F2"
        case 99: return "F3"
        case 118: return "F4"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        // Letters
        case 0: return "A"
        case 11: return "B"
        case 8: return "C"
        case 2: return "D"
        case 14: return "E"
        case 3: return "F"
        case 5: return "G"
        case 4: return "H"
        case 34: return "I"
        case 38: return "J"
        case 40: return "K"
        case 37: return "L"
        case 46: return "M"
        case 45: return "N"
        case 31: return "O"
        case 35: return "P"
        case 12: return "Q"
        case 15: return "R"
        case 1: return "S"
        case 17: return "T"
        case 32: return "U"
        case 9: return "V"
        case 13: return "W"
        case 7: return "X"
        case 16: return "Y"
        case 6: return "Z"
        // Numbers
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 23: return "5"
        case 22: return "6"
        case 26: return "7"
        case 28: return "8"
        case 25: return "9"
        case 29: return "0"
        default: return "Key(\(keyCode))"
        }
    }
}
