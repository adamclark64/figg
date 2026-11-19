import AppKit
import ApplicationServices

/// Puts dictated text into the focused app without the clipboard: an AX
/// write where that works, typed keystrokes otherwise.
public enum TextInserter {
    public enum Result: Equatable, Sendable {
        case inserted
        case typed
        case notInserted(NotInsertedReason)
    }

    /// What is focused right now, read through Accessibility.
    @MainActor
    public static func focusedField() -> (FocusedField, AXUIElement?) {
        let app = NSWorkspace.shared.frontmostApplication
        var field = FocusedField(bundleID: app?.bundleIdentifier)
        let system = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return (field, nil) }
        let element = value as! AXUIElement
        field.role = string(element, kAXRoleAttribute)
        field.subrole = string(element, kAXSubroleAttribute)
        return (field, element)
    }

    /// The character just before the cursor, if the field exposes it.
    public static func precedingCharacter(_ element: AXUIElement?) -> Character? {
        guard let element, let text = string(element, kAXValueAttribute) else { return nil }
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return text.last }
        var range = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range), range.location > 0 else { return nil }
        let units = Array(text.utf16)
        guard range.location <= units.count else { return text.last }
        return String(utf16CodeUnits: [units[range.location - 1]], count: 1).first
    }

    @MainActor
    public static func insert(_ text: String) -> Result {
        let (field, element) = focusedField()
        switch InsertionRouter.method(for: field, trusted: AXIsProcessTrusted()) {
        case .none(let reason):
            return .notInserted(reason)
        case .keystrokes:
            type(text)
            return .typed
        case .accessibility:
            if let element, writeSelection(element, text) { return .inserted }
            type(text)
            return .typed
        }
    }

    /// Replaces the selection (or inserts at the cursor) and checks the value
    /// really changed.
    static func writeSelection(_ element: AXUIElement, _ text: String) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue else { return false }
        let before = string(element, kAXValueAttribute)
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
        else { return false }
        let after = string(element, kAXValueAttribute)
        return InsertionRouter.axWriteTookEffect(before: before, after: after, inserted: text)
    }

    /// Types the text as Unicode key events. No modifier flags are set, so a
    /// still-held key cannot turn the text into shortcuts.
    static func type(_ text: String) {
        let source = CGEventSource(stateID: .hidSystemState)
        for piece in KeystrokeChunks.split(text) {
            let units = Array(piece.utf16)
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                event.flags = []
                units.withUnsafeBufferPointer {
                    event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: $0.baseAddress)
                }
                event.post(tap: .cghidEventTap)
            }
            // Some apps drop events that arrive faster than they read them.
            usleep(2_000)
        }
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
