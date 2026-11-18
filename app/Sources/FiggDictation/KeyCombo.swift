import Foundation

/// A key with modifiers, as written in config.yaml: "ctrl+option+cmd+v".
/// Used for the shortcut that types the last dictation again. Parsing is
/// lenient about case, order and names (cmd/command, opt/option/alt,
/// ctrl/control); writing always gives the canonical form.
public struct KeyCombo: Equatable, Sendable {
    public struct Modifiers: OptionSet, Equatable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let control = Modifiers(rawValue: 1)
        public static let option = Modifiers(rawValue: 2)
        public static let shift = Modifiers(rawValue: 4)
        public static let command = Modifiers(rawValue: 8)
    }

    /// A macOS virtual key code (kVK_*).
    public var keyCode: UInt16
    public var modifiers: Modifiers

    public init(keyCode: UInt16, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Needs Command, Control or Option: Shift alone (or nothing) would
    /// take over a key the user types every day.
    public var isUsable: Bool {
        !modifiers.intersection([.command, .control, .option]).isEmpty && Self.keyNames[keyCode] != nil
    }

    /// nil for "", "none", an unknown key name, or no usable modifier.
    public init?(setting: String) {
        let parts = setting.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let keyName = parts.last, !keyName.isEmpty, keyName != "none",
              let code = Self.keyNames.first(where: { $0.value == keyName })?.key else { return nil }
        var mods: Modifiers = []
        for part in parts.dropLast() {
            switch part {
            case "ctrl", "control", "⌃": mods.insert(.control)
            case "opt", "option", "alt", "⌥": mods.insert(.option)
            case "shift", "⇧": mods.insert(.shift)
            case "cmd", "command", "⌘": mods.insert(.command)
            default: return nil
            }
        }
        self.init(keyCode: code, modifiers: mods)
        guard isUsable else { return nil }
    }

    /// What config.yaml stores, e.g. "ctrl+option+cmd+v".
    public var setting: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("option") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        parts.append(Self.keyNames[keyCode] ?? "?")
        return parts.joined(separator: "+")
    }

    /// What Settings and menus show, e.g. "⌃⌥⌘V", in Apple's modifier order.
    public var label: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        let name = Self.keyNames[keyCode] ?? "?"
        return s + (Self.symbols[name] ?? name.uppercased())
    }

    /// Key codes figg accepts, by name (US layout positions, as Carbon
    /// hot keys use).
    public static let keyNames: [UInt16: String] = {
        var m: [UInt16: String] = [
            0x00: "a", 0x0B: "b", 0x08: "c", 0x02: "d", 0x0E: "e", 0x03: "f", 0x05: "g",
            0x04: "h", 0x22: "i", 0x26: "j", 0x28: "k", 0x25: "l", 0x2E: "m", 0x2D: "n",
            0x1F: "o", 0x23: "p", 0x0C: "q", 0x0F: "r", 0x01: "s", 0x11: "t", 0x20: "u",
            0x09: "v", 0x0D: "w", 0x07: "x", 0x10: "y", 0x06: "z",
            0x1D: "0", 0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x17: "5", 0x16: "6",
            0x1A: "7", 0x1C: "8", 0x19: "9",
            0x31: "space", 0x24: "return", 0x30: "tab",
            0x2B: ",", 0x2F: ".", 0x2C: "/", 0x29: ";", 0x27: "'", 0x21: "[", 0x1E: "]",
            0x2A: "\\", 0x1B: "-", 0x18: "=", 0x32: "`",
        ]
        let f: [UInt16] = [0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F]
        for (i, code) in f.enumerated() { m[code] = "f\(i + 1)" }
        return m
    }()

    static let symbols = ["space": "Space", "return": "↩", "tab": "⇥"]

    /// The suggestion shown in Settings: ⌃⌥⌘V, next to figg's ⌃⌥⌘R (record)
    /// and ⌃⌥⌘P (pause). Not on until the user picks it: a global shortcut
    /// takes the keys from every app, and macOS gives no way to ask whether
    /// another app already uses them (a second app may register the same
    /// hot key without an error).
    public static let pasteLastDefault = KeyCombo(keyCode: 0x09, modifiers: [.control, .option, .command])

    // MARK: Clashes

    /// figg's own global and menu shortcuts.
    static let figgOwn: [(KeyCombo, String)] = [
        (KeyCombo(keyCode: 0x0F, modifiers: [.control, .option, .command]), "figg's Start/Stop Recording"),
        (KeyCombo(keyCode: 0x23, modifiers: [.control, .option, .command]), "figg's Pause Recording"),
    ]

    /// Editing shortcuts nearly every Mac app has, and macOS's own default
    /// shortcuts. A global shortcut on one of these would break it
    /// everywhere. The defaults are listed here because
    /// com.apple.symbolichotkeys only holds the ones a user has changed.
    static let standard: [(KeyCombo, String)] = [
        ("cmd+c", "Copy"), ("cmd+v", "Paste"), ("cmd+x", "Cut"), ("cmd+z", "Undo"),
        ("shift+cmd+z", "Redo"), ("cmd+a", "Select All"), ("cmd+s", "Save"),
        ("cmd+q", "Quit"), ("cmd+w", "Close"), ("cmd+n", "New"), ("cmd+t", "New Tab"),
        ("cmd+f", "Find"), ("cmd+p", "Print"), ("cmd+o", "Open"), ("cmd+h", "Hide"),
        ("cmd+m", "Minimize"), ("cmd+,", "Settings"), ("cmd+tab", "the app switcher"),
        ("cmd+space", "Spotlight"), ("option+cmd+v", "Move Here in Finder"),
        ("option+shift+cmd+v", "Paste and Match Style"), ("shift+cmd+v", "Paste and Match Style in many apps"),
        ("ctrl+cmd+space", "the emoji picker"), ("ctrl+cmd+q", "Lock Screen"), ("ctrl+cmd+f", "Full Screen"),
        ("option+cmd+h", "Hide Others"), ("shift+cmd+/", "Help"), ("option+cmd+space", "a Finder search window"),
        ("shift+cmd+3", "a macOS screenshot shortcut"), ("shift+cmd+4", "a macOS screenshot shortcut"),
        ("shift+cmd+5", "a macOS screenshot shortcut"), ("shift+cmd+6", "a macOS screenshot shortcut"),
        ("ctrl+shift+cmd+3", "a macOS screenshot shortcut"), ("ctrl+shift+cmd+4", "a macOS screenshot shortcut"),
        ("ctrl+space", "the input source switcher"), ("ctrl+option+space", "the input source switcher"),
        ("option+cmd+d", "Show or Hide the Dock"), ("ctrl+cmd+d", "Look Up"),
    ].map { (KeyCombo(setting: $0.0)!, $0.1) }

    /// What already uses this shortcut, if figg can tell: figg itself, a
    /// standard editing shortcut, or a macOS shortcut that is turned on in
    /// System Settings > Keyboard > Keyboard Shortcuts. Shortcuts inside
    /// other apps' menus cannot be checked.
    public func clash(systemHotKeys: [String: Any] = [:]) -> String? {
        if let own = Self.figgOwn.first(where: { $0.0 == self }) { return own.1 }
        if let std = Self.standard.first(where: { $0.0 == self }) { return std.1 }
        if Self.enabledSystemCombos(systemHotKeys).contains(self) { return "a macOS shortcut" }
        return nil
    }

    /// The turned-on shortcuts in `com.apple.symbolichotkeys`'s
    /// AppleSymbolicHotKeys: each entry's value has parameters
    /// [character, key code, NSEvent modifier mask].
    static func enabledSystemCombos(_ hotKeys: [String: Any]) -> [KeyCombo] {
        hotKeys.values.compactMap { entry in
            guard let entry = entry as? [String: Any],
                  (entry["enabled"] as? Bool) ?? ((entry["enabled"] as? Int) == 1),
                  let value = entry["value"] as? [String: Any],
                  let params = value["parameters"] as? [Int], params.count == 3,
                  params[1] >= 0, params[1] < 0xFFFF else { return nil }
            let mask = params[2]
            var mods: Modifiers = []
            if mask & 0x20000 != 0 { mods.insert(.shift) }
            if mask & 0x40000 != 0 { mods.insert(.control) }
            if mask & 0x80000 != 0 { mods.insert(.option) }
            if mask & 0x100000 != 0 { mods.insert(.command) }
            return KeyCombo(keyCode: UInt16(params[1]), modifiers: mods)
        }
    }
}
