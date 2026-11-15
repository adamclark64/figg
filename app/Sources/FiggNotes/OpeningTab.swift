import Foundation

/// Which notes tab a meeting opens on. Most people never type their own
/// notes, so opening every meeting on an empty "My notes" page made them
/// click over to the enhanced notes each time.
public enum OpeningTab: String, Sendable, Equatable {
    case mine
    case enhanced

    /// - Parameters:
    ///   - setting: `notes.default_tab` from config.yaml ("enhanced" or
    ///     "mine"); anything else counts as the default, "enhanced".
    ///   - hasEnhanced: the meeting has saved enhanced notes.
    ///   - isRecording: this meeting is being recorded now, where typing
    ///     notes is the point.
    public static func pick(setting: String, hasEnhanced: Bool, isRecording: Bool) -> OpeningTab {
        if isRecording || !hasEnhanced { return .mine }
        return setting.lowercased() == OpeningTab.mine.rawValue ? .mine : .enhanced
    }
}
