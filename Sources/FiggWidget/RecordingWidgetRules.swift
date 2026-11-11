import CoreGraphics
import Foundation

/// The decisions behind the floating recording widget, kept free of AppKit
/// so they can be tested: when the pill shows, where it sits, and what its
/// small waveform draws.
public enum RecordingWidgetRules {
    /// The pill is for when figg is recording but out of sight. It stays
    /// away while figg is the app in front (the recording strip is already
    /// visible there), when the setting is off, and for a meeting the user
    /// hid it for.
    public static func shouldShow(enabled: Bool, recordingId: String?, appIsActive: Bool, hiddenFor: String?) -> Bool {
        guard enabled, let recordingId, !appIsActive else { return false }
        return recordingId != hiddenFor
    }

    /// The newest `count` bars for the pill, oldest first. Each is the
    /// loudest of `group` consecutive meter bars, so a word is not lost
    /// between redraws. Short history is padded with silence at the old end.
    public static func compactLevels(_ bars: [Float], count: Int, group: Int) -> [Float] {
        guard count > 0, group > 0 else { return [] }
        var out: [Float] = []
        var end = bars.count
        while out.count < count, end > 0 {
            let start = max(0, end - group)
            out.append(bars[start..<end].max() ?? 0)
            end = start
        }
        out.append(contentsOf: Array(repeating: 0, count: count - out.count))
        return out.reversed()
    }
}

/// Where the widget panel goes. All rectangles and points are in AppKit
/// screen coordinates (origin bottom-left, y up); `screens` are the visible
/// frames, so the panel never sits under the menu bar or the Dock.
public enum WidgetPlacement {
    /// Right edge of `screen`, with the point `centreFromTop` below the
    /// panel's top edge at mid height. The panel is taller than the resting
    /// pill (it leaves room for the hover controls), so centring the panel
    /// itself would put the pill visibly too high.
    public static func defaultOrigin(size: CGSize, in screen: CGRect, centreFromTop: CGFloat) -> CGPoint {
        let origin = CGPoint(x: screen.maxX - size.width, y: screen.midY + centreFromTop - size.height)
        return clamp(origin, size: size, to: screen)
    }

    /// Moves `origin` the least distance that puts the whole panel inside `screen`.
    public static func clamp(_ origin: CGPoint, size: CGSize, to screen: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(origin.x, screen.minX), max(screen.minX, screen.maxX - size.width)),
            y: min(max(origin.y, screen.minY), max(screen.minY, screen.maxY - size.height)))
    }

    /// The saved position, pulled back inside the screen it overlaps most.
    /// A position on no screen at all (its display was unplugged) falls back
    /// to the default on `main`; the saved value itself is left alone, so
    /// the pill returns to its spot when that display comes back.
    public static func origin(saved: CGPoint?, size: CGSize, screens: [CGRect], main: CGRect, centreFromTop: CGFloat) -> CGPoint {
        guard let saved else { return defaultOrigin(size: size, in: main, centreFromTop: centreFromTop) }
        let frame = CGRect(origin: saved, size: size)
        let overlaps = screens.map { screen -> (CGRect, CGFloat) in
            let hit = screen.intersection(frame)
            return (screen, hit.isNull ? 0 : hit.width * hit.height)
        }
        guard let best = overlaps.max(by: { $0.1 < $1.1 }), best.1 > 0 else {
            return defaultOrigin(size: size, in: main, centreFromTop: centreFromTop)
        }
        return clamp(saved, size: size, to: best.0)
    }
}

/// The pill's screenshot button hands off to macOS's own capture tool, so
/// the user gets the familiar ⌘⇧4 crosshair and figg never sees the pixels.
public enum ScreenshotCommand {
    public static let tool = "/usr/sbin/screencapture"
    /// `-i`: pick a region with the crosshair (Space switches to picking a
    /// window, Esc cancels). `-c`: put the picture on the clipboard. No file
    /// name is passed, so nothing is written to disk.
    public static let arguments = ["-i", "-c"]

    public enum Outcome: Equatable, Sendable {
        case copied
        /// Esc, or the tool could not run: the clipboard is as it was.
        case nothingCopied
    }

    /// The tool's exit status does not say whether the user cancelled, so
    /// judge by the clipboard: its change count moves only when a picture
    /// was put on it.
    public static func outcome(clipboardBefore: Int, clipboardAfter: Int) -> Outcome {
        clipboardAfter == clipboardBefore ? .nothingCopied : .copied
    }
}
