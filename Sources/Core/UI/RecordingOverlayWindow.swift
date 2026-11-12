import AppKit
import SwiftUI
import Combine

public struct RecordingOverlayView: View {
    @ObservedObject var coordinator = VoiceInputCoordinator.shared
    
    public var body: some View {
        HStack(spacing: 12) {
            switch coordinator.currentState {
            case .idle:
                EmptyView()
            case .recording(let sec):
                Circle()
                    .fill(Color.red)
                    .frame(width: 14, height: 14)
                    .opacity(0.4 + Double(min(1.0, coordinator.currentAudioLevel * 5)))
                    .animation(.easeInOut(duration: 0.2), value: coordinator.currentAudioLevel)
                
                Text("録音中")
                    .bold()
                    .foregroundColor(.white)
                
                Text("\(Int(sec))s")
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.white.opacity(0.8))
                
                Spacer()
                
                Text("[\(SettingsStore.shared.settings.shortcutDisplayName)] で停止")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.2))
                    .foregroundColor(.white)
                    .cornerRadius(4)
                
            case .transcribing:
                ProgressView()
                    .controlSize(.small)
                Text("文字起こし中...")
                    .bold()
                    .foregroundColor(.white)
                
            case .rewriting:
                Text("✨")
                Text("文章整文中...")
                    .bold()
                    .foregroundColor(.white)
                
            case .inserting:
                Text("✍️")
                Text("入力欄へ挿入中...")
                    .bold()
                    .foregroundColor(.white)
                
            case .done(let msg):
                Text(msg)
                    .font(.callout)
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                
            case .error(let msg):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.yellow)
                Text(msg)
                    .font(.caption)
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .frame(minWidth: 260, maxWidth: 520)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.black.opacity(0.85))
                .shadow(color: .black.opacity(0.3), radius: 12, x: 0, y: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
    }
}

public final class RecordingOverlayController: @unchecked Sendable {
    public static let shared = RecordingOverlayController()
    
    private var window: NSPanel?
    private var cancellables = Set<AnyCancellable>()
    
    private init() {}
    
    @MainActor
    public func setup() {
        VoiceInputCoordinator.shared.$currentState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.handleStateChange(state)
            }
            .store(in: &cancellables)
    }
    
    @MainActor
    private func handleStateChange(_ state: VoiceInputState) {
        switch state {
        case .recording, .transcribing, .rewriting, .inserting, .done, .error:
            showOverlay()
        case .idle:
            hideOverlay()
        }
    }
    
    @MainActor
    private func showOverlay() {
        if window == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 340, height: 48),
                styleMask: [.nonactivatingPanel, .hudWindow],
                backing: .buffered,
                defer: false
            )
            panel.level = .floating
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = false
            panel.isMovableByWindowBackground = true
            // queue: nil = delivered synchronously, so `isPlacing` reliably marks our own moves
            NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: nil) { [weak self] _ in
                self?.savePosition()
            }
            panel.contentView = NSHostingView(rootView: RecordingOverlayView())
            self.window = panel
        }
        
        guard let window = self.window, let screen = NSScreen.main else { return }
        
        // Fit the panel to the current message (errors can be longer than the recording pill)
        var size = window.frame.size
        if let content = window.contentView {
            let fitting = content.fittingSize
            size = NSSize(width: max(340, fitting.width), height: max(48, fitting.height))
        }
        
        // Runs every second while recording: re-place only on first show or a size change, or the panel drifts upward.
        if !window.isVisible || size != lastWantedSize {
            lastWantedSize = size
            let center = window.isVisible ? NSPoint(x: window.frame.midX, y: window.frame.midY) : Self.savedCenter()
            let screens = NSScreen.screens.map { (frame: $0.frame, visible: $0.visibleFrame) }
            isPlacing = true
            window.setFrame(NSRect(origin: Self.placement(center: center, size: size, screens: screens, activeScreen: screen.visibleFrame), size: size), display: true)
            isPlacing = false
        }
        window.orderFront(nil)
    }
    
    /// Where the panel goes: around the remembered center, kept fully inside the screen that center is on.
    /// Without a remembered center (or when its screen is gone): bottom center of the active screen (similar to Typeless / Siri).
    /// The screen is found by its full frame (the center may sit in the Dock / menu bar band), the panel is kept inside its visible frame.
    public static func placement(center: NSPoint?, size: NSSize, screens: [(frame: NSRect, visible: NSRect)], activeScreen: NSRect) -> NSPoint {
        guard let c = center, let s = screens.first(where: { $0.frame.contains(c) })?.visible else {
            return NSPoint(x: activeScreen.midX - size.width / 2, y: activeScreen.minY + 60)
        }
        return NSPoint(x: max(s.minX, min(c.x - size.width / 2, s.maxX - size.width)),
                       y: max(s.minY, min(c.y - size.height / 2, s.maxY - size.height)))
    }
    
    // The settings screen rewrites the whole settings struct, so the position lives under its own key.
    // The center is stored (not the origin): the panel's width changes with the message.
    private static let positionKey = "LocalVoiceOverlayCenter"
    private var isPlacing = false
    private var lastWantedSize = NSSize.zero
    
    private static func savedCenter() -> NSPoint? {
        guard let a = UserDefaults.standard.array(forKey: positionKey) as? [Double], a.count == 2 else { return nil }
        return NSPoint(x: a[0], y: a[1])
    }
    
    static func resetPosition() {
        UserDefaults.standard.removeObject(forKey: positionKey)
    }
    
    private func savePosition() {
        // only the user's drags (left button down), not our own placement or AppKit's repositioning
        guard !isPlacing, NSEvent.pressedMouseButtons & 1 != 0, let f = window?.frame else { return }
        UserDefaults.standard.set([Double(f.midX), Double(f.midY)], forKey: Self.positionKey)
    }
    
    @MainActor
    private func hideOverlay() {
        // Small fade delay so user sees completion
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            if VoiceInputCoordinator.shared.currentState == .idle {
                self?.window?.orderOut(nil)
            }
        }
    }
}
