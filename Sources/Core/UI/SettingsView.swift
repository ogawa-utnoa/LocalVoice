import SwiftUI
import AppKit

public struct SettingsView: View {
    @State private var settings = SettingsStore.shared.settings
    @State private var dictionaryEntries = UserDictionary.shared.allEntries
    @State private var newWord = ""
    @State private var newReading = ""
    @State private var availableModels: [ModelDescriptor] = []
    @State private var isRecordingShortcut = false
    @State private var keyMonitor: Any?
    
    public init() {}
    
    public var body: some View {
        TabView {
            // General Tab
            Form {
                Section(header: Text("グローバルショートカット設定").bold()) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("現在のショートカット:")
                            Spacer()
                            Text(settings.shortcutDisplayName)
                                .font(.system(.body, design: .monospaced))
                                .bold()
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(isRecordingShortcut ? Color.orange.opacity(0.2) : Color.blue.opacity(0.15))
                                .foregroundColor(isRecordingShortcut ? .orange : .blue)
                                .cornerRadius(6)
                        }
                        
                        HStack {
                            if isRecordingShortcut {
                                Button("キャンセル (Esc)") {
                                    stopRecordingShortcut()
                                }
                                .buttonStyle(.bordered)
                                
                                Text("任意のキーの組み合わせを押してください...")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                            } else {
                                Button("ショートカットを変更...") {
                                    startRecordingShortcut()
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                        
                        // Shortcut presets
                        HStack(spacing: 8) {
                            Text("プリセット:")
                                .font(.caption).foregroundColor(.secondary)
                            
                            Button("⌥ Space") {
                                applyPreset(keyCode: 49, modifiers: .option, name: "Option + Space")
                            }
                            .buttonStyle(.borderless).font(.caption)
                            
                            Button("⌃ Space") {
                                applyPreset(keyCode: 49, modifiers: .control, name: "Control + Space")
                            }
                            .buttonStyle(.borderless).font(.caption)
                            
                            Button("⇧⌘ Space") {
                                applyPreset(keyCode: 49, modifiers: [.shift, .command], name: "Command + Shift + Space")
                            }
                            .buttonStyle(.borderless).font(.caption)
                            
                            Button("F2") {
                                applyPreset(keyCode: 120, modifiers: [], name: "F2")
                            }
                            .buttonStyle(.borderless).font(.caption)
                        }
                    }
                    .padding(.vertical, 4)
                }
                
                Section(header: Text("録音と挿入").bold()) {
                    Slider(value: $settings.maxRecordingDurationSeconds, in: 60...600, step: 30) {
                        Text("最大録音時間: \(Int(settings.maxRecordingDurationSeconds / 60))分 (\(Int(settings.maxRecordingDurationSeconds))秒)")
                    }
                    Text("最大録音時間: \(Int(settings.maxRecordingDurationSeconds / 60))分")
                        .font(.caption).foregroundColor(.secondary)
                    
                    Toggle("入力欄への自動挿入 (Accessibility API)", isOn: $settings.enableAutoInsertion)
                    Toggle("完了時にクリップボードへコピー", isOn: $settings.copyToClipboardOnFinish)
                    Toggle("処理後に一時音声を削除 (プライバシー保護)", isOn: $settings.deleteAudioAfterProcessing)
                }
                
                Section(header: Text("整文エンジン").bold()) {
                    Toggle("フィラー自動除去 (あー、えー等)", isOn: $settings.enableFillerRemoval)
                    Toggle("ローカルLLMによる整文 (言い直し・段落整形)", isOn: $settings.enableLLMRewrite)
                }
            }
            .padding()
            .tabItem {
                Label("一般", systemImage: "gearshape")
            }
            
            // Models Tab
            Form {
                Section(header: Text("ローカルモデル設定").bold()) {
                    Toggle("リソース状況に応じたモデル自動切替 (推奨)", isOn: $settings.autoModelSelection)
                    
                    Picker("Whisperモデル", selection: $settings.whisperModelPath) {
                        Text("自動検出").tag("")
                        ForEach(availableModels.filter { $0.isWhisper }, id: \.path) { model in
                            Text("\(model.name) (\(Int(model.fileSizeMB)) MB)").tag(model.path)
                        }
                    }
                    
                    Picker("LLMモデル (GGUF)", selection: $settings.llmModelPath) {
                        Text("自動検出").tag("")
                        ForEach(availableModels.filter { $0.isLLM }, id: \.path) { model in
                            Text("\(model.name) (\(Int(model.fileSizeMB)) MB)").tag(model.path)
                        }
                    }
                    
                    HStack {
                        Button("モデル再スキャン") {
                            refreshModels()
                        }
                        
                        Spacer()
                        
                        Text("検出数: Whisper \(availableModels.filter { $0.isWhisper }.count)件 / LLM \(availableModels.filter { $0.isLLM }.count)件")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                
                Section(header: Text("メモリ保護").bold()) {
                    let mem = ResourceMonitor.shared.getMemoryStats()
                    Text("空きRAM: \(String(format: "%.1f", mem.availableRAMMB / 1024)) GB / 24 GB")
                    Text("動作モード: \(ResourceMonitor.shared.determineRecommendedMode().rawValue)")
                        .foregroundColor(.blue)
                }
            }
            .padding()
            .tabItem {
                Label("モデル", systemImage: "cpu")
            }
            
            // User Dictionary Tab
            VStack(alignment: .leading, spacing: 12) {
                Text("固有名詞辞書")
                    .font(.headline)
                Text("正しい表記と、聞き間違えやすい書き方（カンマ区切り）を登録すると、文字起こし後に正しい表記へ直します。例: Claude ← クロード, Claud")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                HStack {
                    TextField("単語 (例: Google Workspace)", text: $newWord)
                    TextField("聞き間違い・読み (例: クロード, Claud)", text: $newReading)
                    Button("追加") {
                        guard !newWord.isEmpty else { return }
                        UserDictionary.shared.addEntry(word: newWord, reading: newReading)
                        newWord = ""
                        newReading = ""
                        dictionaryEntries = UserDictionary.shared.allEntries
                    }
                    .disabled(newWord.isEmpty)
                }
                
                List {
                    ForEach(dictionaryEntries) { entry in
                        HStack {
                            Text(entry.word).bold()
                            if !entry.reading.isEmpty {
                                Text("← \(entry.reading)").foregroundColor(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Button(action: {
                                UserDictionary.shared.removeEntry(id: entry.id)
                                dictionaryEntries = UserDictionary.shared.allEntries
                            }) {
                                Image(systemName: "trash")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(minHeight: 180)
            }
            .padding()
            .tabItem {
                Label("辞書", systemImage: "character.book.closed")
            }
        }
        .frame(width: 560, height: 460)
        .onAppear {
            refreshModels()
        }
        .onDisappear {
            stopRecordingShortcut()
        }
        .onChange(of: settings) { _, newValues in
            SettingsStore.shared.settings = newValues
        }
    }
    
    private func refreshModels() {
        availableModels = ModelManager.shared.scanAvailableModels()
    }
    
    private func startRecordingShortcut() {
        isRecordingShortcut = true
        stopRecordingShortcut()
        
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Cancel on Escape
            if event.keyCode == 53 {
                self.stopRecordingShortcut()
                return nil
            }
            
            let modifiers = event.modifierFlags.intersection([.control, .option, .shift, .command])
            let keyCode = event.keyCode
            
            // Update shortcut
            GlobalShortcutManager.shared.updateShortcut(keyCode: keyCode, modifiers: modifiers)
            self.settings = SettingsStore.shared.settings
            self.stopRecordingShortcut()
            return nil
        }
    }
    
    private func stopRecordingShortcut() {
        isRecordingShortcut = false
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }
    
    private func applyPreset(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, name: String) {
        GlobalShortcutManager.shared.updateShortcut(keyCode: keyCode, modifiers: modifiers)
        self.settings = SettingsStore.shared.settings
    }
}
