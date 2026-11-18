import Carbon.HIToolbox
import FiggDictation
import Foundation

/// A system-wide shortcut through the Carbon hot-key API, which needs no
/// Accessibility permission. figg's own: ⌃⌥⌘R starts and stops recording
/// (⌘⇧R was the original plan but it is Chrome's hard-reload shortcut), and
/// the dictation paste-last shortcut. Each one checks the pressed key's ID
/// and passes others on, so several can be registered at once.
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let id: UInt32
    private let action: () -> Void
    private static var nextID: UInt32 = 1

    /// False when macOS refused the shortcut. Another app holding the same
    /// keys does not count: macOS lets a second app register them too.
    private(set) var registered = false

    convenience init(action: @escaping () -> Void) {
        self.init(KeyCombo(keyCode: UInt16(kVK_ANSI_R), modifiers: [.command, .option, .control]), action: action)
    }

    init(_ combo: KeyCombo, action: @escaping () -> Void) {
        self.action = action
        id = Self.nextID
        Self.nextID += 1
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            var pressed = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            guard status == noErr, pressed.signature == HotKey.signature, pressed.id == hotKey.id else {
                return OSStatus(eventNotHandledErr)
            }
            DispatchQueue.main.async { hotKey.action() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        registered = RegisterEventHotKey(UInt32(combo.keyCode), Self.carbonModifiers(combo.modifiers),
                                         hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr
    }

    private static let signature = OSType(0x4649_4747) // "FIGG"

    static func carbonModifiers(_ m: KeyCombo.Modifiers) -> UInt32 {
        var out = 0
        if m.contains(.command) { out |= cmdKey }
        if m.contains(.option) { out |= optionKey }
        if m.contains(.control) { out |= controlKey }
        if m.contains(.shift) { out |= shiftKey }
        return UInt32(out)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}
