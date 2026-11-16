import Foundation

/// The key held down to dictate.
public enum HoldKey: String, Sendable, CaseIterable {
    /// The fn/globe key.
    case fn
    case rightOption = "right_option"

    /// A config value figg does not know falls back to fn.
    public init(setting: String) { self = HoldKey(rawValue: setting) ?? .fn }

    /// macOS virtual key code (kVK_Function, kVK_RightOption).
    public var keyCode: UInt16 {
        switch self {
        case .fn: return 63
        case .rightOption: return 61
        }
    }

    public var label: String {
        switch self {
        case .fn: return "fn"
        case .rightOption: return "Right Option"
        }
    }
}

/// Turns raw key events into start/stop of a dictation. Kept free of AppKit
/// so the rules can be tested.
///
/// Two ways to dictate with the same key:
/// - Hold it, speak, let go: recording starts the moment the key goes down
///   (so the first word is not lost) and stops on release.
/// - Tap it: a press shorter than `minimumHold` locks recording on
///   (hands-free). The next press of the key stops it when released.
///
/// Esc cancels either way, and nothing is typed. Pressing any other key
/// while holding (fn+arrow, Option+letter) means the user is typing a
/// shortcut, so that cancels too; in hands-free mode other keys are ignored.
public struct HoldToTalk: Sendable {
    public enum Event: Equatable, Sendable {
        case start
        /// A tap locked recording on; the next press stops it.
        case handsFree
        case stop
        case cancel
    }

    enum State: Equatable, Sendable {
        case idle
        case holding(since: Date)
        case handsFree
        /// The key went down again in hands-free mode; it stops on release,
        /// so nothing is typed while the key is still held.
        case stopping
        /// Cancelled or stopped while the key is still down: its release is
        /// not a new action.
        case waitingForRelease
    }

    public static let escapeKeyCode: UInt16 = 53

    public let key: HoldKey
    public let minimumHold: TimeInterval
    private(set) var state: State = .idle

    /// Half a second: an ordinary tap often lasts 0.3-0.4 s, and a hold
    /// shorter than this is too short to say anything anyway.
    public init(key: HoldKey, minimumHold: TimeInterval = 0.5) {
        self.key = key
        self.minimumHold = minimumHold
    }

    /// Recording, by holding or hands-free.
    public var isActive: Bool {
        switch state {
        case .holding, .handsFree, .stopping: return true
        default: return false
        }
    }

    public var isHandsFree: Bool { state == .handsFree }

    /// A modifier changed. `keyCode` is the key that changed, `keyIsDown`
    /// whether the hold key's flag is now set, and `otherModifiers` whether
    /// any other modifier (Shift, Control, Option, Command) is held.
    public mutating func flagsChanged(keyCode: UInt16, keyIsDown: Bool, otherModifiers: Bool, now: Date = Date()) -> Event? {
        guard keyCode == key.keyCode else {
            // Another modifier went down during a hold: a shortcut.
            if otherModifiers, case .holding = state {
                state = .waitingForRelease
                return .cancel
            }
            return nil
        }
        switch (state, keyIsDown) {
        case (.idle, true):
            // Already holding another modifier: a shortcut, not dictation.
            guard !otherModifiers else { return nil }
            state = .holding(since: now)
            return .start
        case (.holding(let since), false):
            if now.timeIntervalSince(since) < minimumHold {
                state = .handsFree
                return .handsFree
            }
            state = .idle
            return .stop
        case (.handsFree, true):
            state = .stopping
            return nil
        case (.stopping, false):
            state = .idle
            return .stop
        case (.waitingForRelease, false):
            state = .idle
            return nil
        default:
            return nil
        }
    }

    /// A non-modifier key went down.
    public mutating func keyDown(keyCode: UInt16) -> Event? {
        if keyCode == Self.escapeKeyCode { return cancel() }
        if case .holding = state {
            state = .waitingForRelease
            return .cancel
        }
        return nil
    }

    /// Drops the recording, whatever the mode.
    public mutating func cancel() -> Event? {
        switch state {
        case .holding:
            state = .waitingForRelease
            return .cancel
        case .handsFree:
            state = .idle
            return .cancel
        case .stopping:
            state = .waitingForRelease
            return .cancel
        default:
            return nil
        }
    }
}
