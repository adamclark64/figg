import FiggNotes
import Foundation

/// Runs `StreamReveal` at screen rate for the enhanced notes pane, so notes
/// being written flow onto the page at an even speed.
///
/// `text` is nil when nothing is being revealed; the pane then shows the
/// saved notes as they are. A stream that ends keeps revealing until it has
/// caught up, so the last burst does not jump in.
@MainActor
final class NotesReveal: ObservableObject {
    @Published private(set) var text: String?

    private var reveal = StreamReveal()
    private var finished = true
    private var timer: Timer?
    private var lastTick: Date?

    /// True while characters are still arriving on screen.
    var isRevealing: Bool { text != nil }

    /// Call with the streamed text each time it changes, and with nil when
    /// the stream ends. With `animate` off (Reduce Motion) text shows at once.
    func update(streaming: String?, animate: Bool) {
        guard animate else {
            stop()
            return
        }
        if let streaming {
            finished = false
            reveal.receive(streaming)
            start()
        } else {
            finished = true
        }
        publish()
    }

    private func start() {
        guard timer == nil else { return }
        lastTick = Date()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // .common keeps it ticking while the user scrolls the notes.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let now = Date()
        reveal.advance(by: now.timeIntervalSince(lastTick ?? now), finished: finished)
        lastTick = now
        publish()
    }

    private func publish() {
        if finished && !reveal.isBehind {
            stop()
        } else {
            let visible = reveal.visible
            if text != visible { text = visible }
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        lastTick = nil
        finished = true
        reveal = StreamReveal()
        if text != nil { text = nil }
    }
}
