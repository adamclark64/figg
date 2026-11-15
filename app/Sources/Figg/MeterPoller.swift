import AppKit
import FiggAudio
import SwiftUI

/// Feeds a level meter view at most 10 times a second, and only when the
/// meter has a new bar and the view's window can be seen (`RedrawGate`).
/// The views used to redraw on a 20 fps timeline for the whole call, which
/// cost about 8% of a core per meter (issue #27).
@MainActor
final class MeterPoller: ObservableObject {
    @Published private(set) var snapshot: [AudioStream: [Float]] = [:]
    /// The window the view sits in; set by `WindowProbe`.
    weak var window: NSWindow?

    private let meter: () -> LevelMeter?
    private var gate = RedrawGate()
    private var timer: Timer?

    static let interval: TimeInterval = 0.1

    init(meter: @escaping () -> LevelMeter?) {
        self.meter = meter
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Let macOS batch the wake-ups with other timers.
        timer.tolerance = Self.interval / 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let meter = meter() else {
            if !snapshot.isEmpty { snapshot = [:] }
            return
        }
        if gate.shouldRedraw(meter: meter, visible: isVisible) {
            snapshot = meter.snapshot()
        }
    }

    /// On screen and not fully covered. Before the window is known, assume
    /// visible so the first frame draws.
    private var isVisible: Bool {
        guard let window else { return true }
        return window.isVisible && window.occlusionState.contains(.visible)
    }
}

/// Finds the window a SwiftUI view is in and hands it to a poller.
struct WindowProbe: NSViewRepresentable {
    let poller: MeterPoller

    func makeNSView(context: Context) -> NSView {
        let view = ProbeView()
        view.onWindow = { [weak poller] in poller?.window = $0 }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ProbeView: NSView {
        var onWindow: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
        }
    }
}
