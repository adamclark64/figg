import AppKit
import FiggDictation

/// Plays dictation's start, stop and cancel cues. Each sound is loaded once
/// and kept, so it starts at once; one still ringing is restarted rather
/// than skipped.
@MainActor
final class DictationSounds {
    private var loaded: [String: NSSound] = [:]

    func play(_ sound: DictationSound, volume: Float) {
        guard let s = load(sound) else { return }
        s.stop()
        s.volume = volume
        s.play()
    }

    private func load(_ sound: DictationSound) -> NSSound? {
        if let s = loaded[sound.name] { return s }
        guard let s = NSSound(contentsOfFile: sound.path(resources: Bundle.main.resourcePath ?? ""), byReference: true) else { return nil }
        loaded[sound.name] = s
        return s
    }
}
