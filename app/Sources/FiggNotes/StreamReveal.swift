import Foundation

/// Paces streamed text so it appears at an even speed instead of in the
/// bursts the model sends it in.
///
/// Each tick reveals a few more characters of the text received so far. The
/// speed rises with the backlog, so the reveal never falls more than about
/// `catchUp` seconds behind the model however fast it writes, and once the
/// stream has finished the rest comes out quicker still.
public struct StreamReveal: Sendable, Equatable {
    /// Characters per second when the reveal is close behind the stream.
    public var baseRate: Double = 80
    /// How far behind the stream the reveal may fall, in seconds.
    public var catchUp: Double = 0.7
    /// The same once the stream has finished, so the last part does not linger.
    public var finishCatchUp: Double = 0.3

    /// How many characters (grapheme clusters) of `target` are showing.
    public private(set) var shown = 0
    private var target = ""
    private var carry = 0.0

    public init() {}

    /// The text to draw now.
    public var visible: String { String(target.prefix(shown)) }

    /// True while some received text is not showing yet.
    public var isBehind: Bool { shown < target.count }

    /// Takes the latest streamed text. A text that does not continue the old
    /// one (Regenerate started over) is revealed again from the start.
    public mutating func receive(_ text: String) {
        if !text.hasPrefix(visible) {
            shown = 0
            carry = 0
        }
        target = text
        shown = min(shown, target.count)
    }

    /// Shows everything at once, for text that was never streamed here.
    public mutating func showAll(_ text: String) {
        target = text
        shown = text.count
        carry = 0
    }

    /// Moves the reveal on by `dt` seconds.
    public mutating func advance(by dt: Double, finished: Bool) {
        let backlog = target.count - shown
        guard backlog > 0, dt > 0 else { return }
        let rate = max(baseRate, Double(backlog) / (finished ? finishCatchUp : catchUp))
        carry += rate * dt
        let step = Int(carry)
        carry -= Double(step)
        shown = min(target.count, shown + step)
    }
}
