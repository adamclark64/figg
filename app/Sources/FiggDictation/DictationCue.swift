import Foundation

/// The short sounds dictation plays, so hands-free mode never leaves the user
/// guessing whether figg is still listening. The user picks one for each cue
/// from the built-in macOS system sounds. They are played by figg's own
/// process, and the meeting recorder's system-audio tap excludes figg, so a
/// cue never lands in a meeting's call audio.
public enum DictationCue: String, CaseIterable, Sendable {
    /// Listening started (key down, or a tap into hands-free).
    case start
    /// Listening stopped and the text is about to be typed.
    case stop
    /// Esc, a shortcut pressed while holding, or nothing was heard.
    case cancel

    /// The sound used when config.yaml names none, or one this Mac lacks.
    public var defaultSound: String {
        switch self {
        case .start: return "Tink"
        case .stop: return "Pop"
        case .cancel: return "Bottle"
        }
    }

    /// The setting's value meaning "play nothing for this cue".
    public static let none = "none"

    /// The sound to play for a setting: nil for "none", the default for a
    /// name that is not a known system sound (a typo in config.yaml).
    public func sound(setting: String) -> DictationSound? {
        if setting.lowercased() == Self.none { return nil }
        return DictationSound.named(setting) ?? DictationSound.named(defaultSound)
    }

    /// The volume to play at, from the user's setting (0...1). Cancel is
    /// softer: nothing went wrong, nothing was typed.
    public func volume(setting: Double) -> Float {
        let v = Float(min(max(setting, 0), 1))
        return self == .cancel ? v * 0.6 : v
    }

    /// `samples` (16 kHz mono) with the start cue silenced: the first
    /// `seconds` set to zero, so the timing of what follows is kept.
    public static func silencingStart(_ samples: [Float], seconds: Double, sampleRate: Double = 16_000) -> [Float] {
        let n = min(samples.count, max(0, Int(seconds * sampleRate)))
        guard n > 0 else { return samples }
        var out = samples
        out.replaceSubrange(0..<n, with: repeatElement(0, count: n))
        return out
    }
}

/// One of the sounds in /System/Library/Sounds, with how long it can be
/// heard (until 40 dB below its peak, measured from the files on macOS 15).
/// Only the short, soft ones are offered: alert sounds like Basso, Funk and
/// Sosumi read as an error, and long ones like Blow would eat speech.
public struct DictationSound: Equatable, Sendable {
    public let name: String
    public let audibleSeconds: Double

    public var path: String { "/System/Library/Sounds/\(name).aiff" }

    /// Speaker output can lag the call by 100 ms or more (Bluetooth), so the
    /// mic is silenced for that much longer than the sound itself.
    public static let outputLatency = 0.2

    /// Seconds of the dictation mic to silence after playing this as the
    /// start cue. A long sound costs the first moment of speech, which the
    /// Settings picker says next to it.
    public var muteSeconds: Double { audibleSeconds + Self.outputLatency }

    /// Short enough that nobody has started a word before it is over.
    public var isQuick: Bool { audibleSeconds <= 0.2 }

    public static let all: [DictationSound] = [
        ("Tink", 0.04), ("Frog", 0.11), ("Morse", 0.14), ("Pop", 0.21),
        ("Ping", 0.30), ("Bottle", 0.32), ("Purr", 0.34), ("Glass", 0.75),
    ].map { DictationSound(name: $0.0, audibleSeconds: $0.1) }

    public static func named(_ name: String) -> DictationSound? {
        all.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}
