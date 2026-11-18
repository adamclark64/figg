import AppKit
import FiggDictation
import SwiftUI

/// A button that shows a shortcut and, when clicked, records the next key
/// pressed with Command, Control or Option. Esc cancels; Delete clears it.
/// A shortcut figg, a standard editing command or macOS already uses is
/// refused. Writes the config.yaml form ("ctrl+option+cmd+v", or "" for off).
struct ShortcutRecorder: View {
    @Binding var setting: String
    @State private var recording = false
    @State private var monitor: Any?
    @State private var hint: String?

    var body: some View {
        HStack {
            Button(recording ? "Type a shortcut…" : (KeyCombo(setting: setting)?.label ?? "None")) {
                recording ? stop() : start()
            }
            .frame(minWidth: 120)
            if !setting.isEmpty, !recording {
                Button("Clear") { setting = "" }
            }
            if let hint { Text(hint).font(.caption).foregroundStyle(.secondary) }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        hint = "Esc to cancel"
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }

    private func handle(_ event: NSEvent) {
        switch event.keyCode {
        case 0x35: // Esc
            hint = nil
            stop()
            return
        case 0x33, 0x75: // Delete, Forward Delete
            setting = ""
            hint = nil
            stop()
            return
        default: break
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: KeyCombo.Modifiers = []
        if flags.contains(.control) { mods.insert(.control) }
        if flags.contains(.option) { mods.insert(.option) }
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.command) { mods.insert(.command) }
        let combo = KeyCombo(keyCode: event.keyCode, modifiers: mods)
        guard combo.isUsable else {
            hint = "Hold ⌘, ⌃ or ⌥ with a letter, number or F-key"
            return
        }
        let system = UserDefaults(suiteName: "com.apple.symbolichotkeys")?
            .dictionary(forKey: "AppleSymbolicHotKeys") ?? [:]
        if let user = combo.clash(systemHotKeys: system) {
            hint = "\(combo.label) is \(user). Try another."
            return
        }
        setting = combo.setting
        hint = nil
        stop()
    }
}
