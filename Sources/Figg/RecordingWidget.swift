import AppKit
import Combine
import FiggAudio
import FiggWidget
import SwiftUI

/// The floating pill shown while figg records and another app is in front:
/// clicking the fig returns to the note, a small waveform shows both
/// streams, the camera takes a screenshot to the clipboard, and hovering or
/// right-clicking offers Stop and Hide.
///
/// This class only watches state and owns the panel. When the pill shows and
/// where it sits are decided by `RecordingWidgetRules` and `WidgetPlacement`.
@MainActor
final class RecordingWidget {
    private weak var model: AppModel?
    private let settings: AppSettings
    private let state = WidgetState()
    private var panel: NSPanel?
    private var watches: Set<AnyCancellable> = []
    /// The meeting the user chose "Hide for this meeting" on.
    private var hiddenFor: String?
    /// True while the macOS crosshair is up. The pill steps aside for it, so
    /// it is never in the way of, or in, the screenshot.
    private var capturing = false
    /// Screen Recording access was asked for during this launch.
    private var askedForScreenAccess = false

    init(model: AppModel, settings: AppSettings) {
        self.model = model
        self.settings = settings
    }

    func start() {
        guard let model else { return }
        let center = NotificationCenter.default
        let triggers: [AnyPublisher<Void, Never>] = [
            model.$recordingId.map { _ in }.eraseToAnyPublisher(),
            settings.$config.map(\.recording.widget).removeDuplicates().map { _ in }.eraseToAnyPublisher(),
            center.publisher(for: NSApplication.didBecomeActiveNotification).map { _ in }.eraseToAnyPublisher(),
            center.publisher(for: NSApplication.didResignActiveNotification).map { _ in }.eraseToAnyPublisher(),
            // A display was added, removed or rearranged: clamp the pill back on screen.
            center.publisher(for: NSApplication.didChangeScreenParametersNotification).map { _ in }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(triggers)
            // @Published fires before the new value is stored, so wait a turn
            // of the run loop and read settled state.
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refresh() }
            .store(in: &watches)
    }

    private func refresh() {
        guard let model else { return }
        // "Hide for this meeting" ends with the meeting.
        if hiddenFor != model.recordingId { hiddenFor = nil }
        let show = RecordingWidgetRules.shouldShow(
            enabled: settings.config.recording.widget,
            recordingId: model.recordingId,
            appIsActive: NSApplication.shared.isActive,
            hiddenFor: hiddenFor)
        if show, !capturing { present() } else { dismiss() }
    }

    private func present() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.setFrameOrigin(placed(saved: settings.config.recording.widgetPosition.map { CGPoint(x: $0.x, y: $0.y) }))
        guard !panel.isVisible else { return }
        state.expanded = false
        // Regardless: figg is in the background by definition here.
        panel.orderFrontRegardless()
    }

    private func dismiss() {
        panel?.orderOut(nil)
    }

    private func placed(saved: CGPoint?) -> CGPoint {
        let screens = NSScreen.screens.map(\.visibleFrame)
        let main = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        return WidgetPlacement.origin(
            saved: saved, size: WidgetMetrics.panelSize, screens: screens, main: main,
            centreFromTop: WidgetMetrics.restingCentre)
    }

    // MARK: Actions

    private func openNote() {
        guard let model, let id = model.recordingId else { return }
        model.selection = .meeting(id)
        MeetingWatcher.showMainWindow()
    }

    private func stopRecording() {
        Task { await model?.stopRecording() }
    }

    private func hideForThisMeeting() {
        hiddenFor = model?.recordingId
        refresh()
    }

    /// Brings up the same crosshair as ⌘⇧4 and copies the result. The
    /// picture goes to the clipboard only: figg does not keep or read it.
    private func takeScreenshot() {
        guard !capturing else { return }
        // macOS only lets an app with Screen Recording access capture other
        // apps' windows. The first press without it asks (the system dialog
        // offers System Settings) and stops there, so the crosshair does not
        // open on top of that dialog. The preflight answer can stay false
        // until figg restarts even after access is granted, so later presses
        // go ahead regardless rather than blocking mid-meeting.
        if !CGPreflightScreenCaptureAccess(), !askedForScreenAccess {
            askedForScreenAccess = true
            CGRequestScreenCaptureAccess()
            model?.banners.append(Banner(
                kind: .warning,
                text: "To take screenshots from the recording widget, allow figg under System Settings > Privacy & Security > Screen & System Audio Recording, then press the camera again. Screenshots go to your clipboard only.",
                action: .openPrivacySettings))
            return
        }
        capturing = true
        dismiss()
        Task {
            let outcome = await Self.runScreenshotTool()
            capturing = false
            state.justCopied = outcome == .copied
            refresh()
            guard outcome == .copied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            state.justCopied = false
        }
    }

    private static func runScreenshotTool() async -> ScreenshotCommand.Outcome {
        let before = NSPasteboard.general.changeCount
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ScreenshotCommand.tool)
        process.arguments = ScreenshotCommand.arguments
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in done.resume() }
            do {
                try process.run()
            } catch {
                // Never started, so the handler will not fire.
                process.terminationHandler = nil
                done.resume()
            }
        }
        return ScreenshotCommand.outcome(clipboardBefore: before, clipboardAfter: NSPasteboard.general.changeCount)
    }

    /// After a drag: pull the pill fully on screen and remember the spot.
    private func dropped() {
        guard let panel else { return }
        let origin = placed(saved: panel.frame.origin)
        panel.setFrameOrigin(origin)
        settings.config.recording.widgetPosition = .init(x: Double(origin.x.rounded()), y: Double(origin.y.rounded()))
    }

    // MARK: Panel

    private func makePanel() -> NSPanel {
        let size = WidgetMetrics.panelSize
        let pill = WidgetPill(
            settings: settings,
            state: state,
            meter: { [weak model] in model?.levelMeter },
            logo: PromptPanel.figLogo,
            onOpen: { [weak self] in self?.openNote() },
            onCapture: { [weak self] in self?.takeScreenshot() },
            onStop: { [weak self] in self?.stopRecording() },
            onHide: { [weak self] in self?.hideForThisMeeting() })
        let host = WidgetHostingView(rootView: pill)
        // The panel has one fixed size; do not let SwiftUI resize the window.
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: size)
        host.state = state
        host.onOpen = { [weak self] in self?.openNote() }
        host.onCapture = { [weak self] in self?.takeScreenshot() }
        host.onDropped = { [weak self] in self?.dropped() }
        host.menuItems = { [weak self] in
            [
                ("Open Note", { self?.openNote() }),
                ("Take Screenshot", { self?.takeScreenshot() }),
                ("Stop Recording", { self?.stopRecording() }),
                ("Hide for This Meeting", { self?.hideForThisMeeting() }),
            ]
        }

        // Same traits as the meeting prompt: floats over everything, on every
        // Space and over full-screen apps, and never activates figg.
        let panel = WidgetPanel(contentRect: NSRect(origin: .zero, size: size),
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The pill draws its own shadow; a window shadow would trace the
        // fixed panel rectangle, not the pill.
        panel.hasShadow = false
        // Always the dark palette, so the pill reads on any desktop.
        panel.appearance = NSAppearance(named: .darkAqua)
        // Ask macOS to leave the pill out of screenshots and screen shares, so
        // people watching you present do not see it. Newer capture paths may
        // ignore this.
        panel.sharingType = .none
        panel.contentView = host
        return panel
    }
}

/// What the pill is showing beyond its resting look. Drawn by the SwiftUI
/// pill; `expanded` is set by the AppKit host, which tracks the mouse.
@MainActor
final class WidgetState: ObservableObject {
    /// The hover controls (Stop, Hide) are out.
    @Published var expanded = false
    /// A screenshot just landed on the clipboard; the camera shows a tick.
    @Published var justCopied = false
}

/// Sizes shared by the SwiftUI pill and the AppKit view that handles its
/// mouse. Rectangles are in points from the panel's top-left corner.
enum WidgetMetrics {
    /// Clear space around the pill, for its shadow.
    static let margin: CGFloat = 10
    static let pillWidth: CGFloat = 40
    static let padding: CGFloat = 8
    static let logo: CGFloat = 24
    static let gap: CGFloat = 7
    static let waveform = CGSize(width: 26, height: 20)
    static let controlsGap: CGFloat = 8
    static let button: CGFloat = 24
    static let buttonGap: CGFloat = 2

    static let restingHeight = padding + logo + gap + waveform.height + gap + button + padding
    static let expandedHeight = restingHeight + controlsGap + button + buttonGap + button

    /// The panel never changes size: it is as tall as the expanded pill, and
    /// the part below a resting pill is clear and lets clicks through.
    static let panelSize = CGSize(width: pillWidth + 2 * margin, height: expandedHeight + 2 * margin)
    /// Distance from the panel's top edge to the middle of the resting pill.
    static let restingCentre = margin + restingHeight / 2

    static func pillRect(expanded: Bool) -> CGRect {
        CGRect(x: margin, y: margin, width: pillWidth, height: expanded ? expandedHeight : restingHeight)
    }

    /// The fig: a click here opens the note.
    static let logoRect = CGRect(x: margin, y: margin, width: pillWidth, height: padding + logo + gap / 2)
    /// The camera: a click here takes a screenshot.
    static let captureRect = CGRect(x: margin, y: margin + restingHeight - padding - button - gap / 2,
                                    width: pillWidth, height: gap / 2 + button + padding)
    /// The whole resting pill: a drag anywhere on it moves the pill.
    static let dragRect = pillRect(expanded: false)
}

/// Borderless panels refuse key status by default; say so explicitly, since
/// the whole point is that the meeting app keeps the keyboard.
private final class WidgetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Handles the mouse for the pill in AppKit rather than with SwiftUI
/// gestures: a SwiftUI drag measures in window coordinates, which stand
/// still while the window follows the pointer, and SwiftUI hover does not
/// fire in a window of a background app.
private final class WidgetHostingView: NSHostingView<WidgetPill> {
    var state: WidgetState?
    var onOpen: (() -> Void)?
    var onCapture: (() -> Void)?
    var onDropped: (() -> Void)?
    var menuItems: (() -> [(String, () -> Void)])?
    private var tracking: NSTrackingArea?
    private let hover = HoverOwner()

    /// The first click must act, not just wake the panel.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func location(_ event: NSEvent) -> CGPoint {
        var p = convert(event.locationInWindow, from: nil)
        if !isFlipped { p.y = bounds.height - p.y }
        return p
    }

    /// A press on the resting pill is a drag if the pointer travels, else a
    /// click on whatever is under it (the fig or the camera). Presses on the
    /// hover controls go to SwiftUI's buttons.
    override func mouseDown(with event: NSEvent) {
        let start = location(event)
        guard WidgetMetrics.dragRect.contains(start), let window else {
            super.mouseDown(with: event)
            return
        }
        let startMouse = NSEvent.mouseLocation
        let startOrigin = window.frame.origin
        var dragged = false
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            let now = NSEvent.mouseLocation
            let dx = now.x - startMouse.x, dy = now.y - startMouse.y
            if !dragged, hypot(dx, dy) < 4 { continue }
            dragged = true
            window.setFrameOrigin(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
        }
        if dragged {
            onDropped?()
        } else if WidgetMetrics.logoRect.contains(start) {
            onOpen?()
        } else if WidgetMetrics.captureRect.contains(start) {
            onCapture?()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard WidgetMetrics.pillRect(expanded: state?.expanded ?? false).contains(location(event)),
              let items = menuItems?() else { return nil }
        let menu = NSMenu()
        for (title, action) in items {
            menu.addItem(ClosureMenuItem(title: title, run: action))
        }
        return menu
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        hover.moved = { [weak self] event in self?.pointerMoved(event) }
        hover.exited = { [weak self] in self?.setExpanded(false) }
        // Always active: figg is in the background whenever the pill shows.
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: hover)
        addTrackingArea(area)
        tracking = area
    }

    /// Expanded while the pointer is over the pill as currently drawn, so
    /// the clear part of the panel under a resting pill does not open it.
    private func pointerMoved(_ event: NSEvent) {
        setExpanded(WidgetMetrics.pillRect(expanded: state?.expanded ?? false).contains(location(event)))
    }

    private func setExpanded(_ expanded: Bool) {
        guard let state, state.expanded != expanded else { return }
        state.expanded = expanded
    }
}

/// Receives the tracking area's events, so they do not mix with the mouse
/// handling `NSHostingView` does for SwiftUI.
private final class HoverOwner: NSObject {
    var moved: ((NSEvent) -> Void)?
    var exited: (() -> Void)?

    @objc func mouseEntered(with event: NSEvent) { moved?(event) }
    @objc func mouseMoved(with event: NSEvent) { moved?(event) }
    @objc func mouseExited(with event: NSEvent) { exited?() }
}

private final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void

    init(title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { run() }
}

// MARK: Views

/// Draws the pill. Mouse handling for the fig, waveform and camera lives in
/// `WidgetHostingView`; only the two hover buttons are SwiftUI controls.
struct WidgetPill: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var state: WidgetState
    /// Polled by the waveform; a new recording brings a new meter.
    let meter: () -> LevelMeter?
    let logo: NSImage?
    let onOpen: () -> Void
    let onCapture: () -> Void
    let onStop: () -> Void
    let onHide: () -> Void

    private typealias M = WidgetMetrics

    var body: some View {
        let theme = Theme.named(settings.config.appearance.theme)
        let shape = RoundedRectangle(cornerRadius: M.pillWidth / 2, style: .continuous)
        VStack(spacing: 0) {
            fig(theme)
            WidgetWaveform(meter: meter, mic: theme.ink, system: theme.accent, floor: theme.inkMuted.opacity(0.45))
                .frame(width: M.waveform.width, height: M.waveform.height)
                .padding(.top, M.gap)
            camera(theme)
                .padding(.top, M.gap)
            if state.expanded {
                VStack(spacing: M.buttonGap) {
                    control("stop.fill", "Stop recording", theme.record, theme, action: onStop)
                    control("eye.slash", "Hide for this meeting", theme.inkMuted, theme, action: onHide)
                }
                .padding(.top, M.controlsGap)
                .transition(.opacity)
            }
        }
        .padding(.vertical, M.padding)
        .frame(width: M.pillWidth)
        .background(theme.canvas, in: shape)
        .overlay(shape.strokeBorder(theme.inkMuted.opacity(0.35)))
        .shadow(color: .black.opacity(0.35), radius: 5, y: 2)
        .padding(M.margin)
        .frame(width: M.panelSize.width, height: M.panelSize.height, alignment: .top)
        .animation(.easeOut(duration: 0.15), value: state.expanded)
    }

    private func fig(_ theme: Theme) -> some View {
        Group {
            if let logo {
                Image(nsImage: logo).resizable().interpolation(.high)
            } else {
                // No app bundle (swift run): any mark will do.
                Image(systemName: "record.circle.fill").resizable().foregroundStyle(theme.record)
            }
        }
        .frame(width: M.logo, height: M.logo)
        .accessibilityElement()
        .accessibilityLabel("figg is recording. Open the meeting note")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, onOpen)
    }

    /// Not a SwiftUI button: the host view treats a press here as a click or
    /// the start of a drag, like the fig.
    private func camera(_ theme: Theme) -> some View {
        Image(systemName: state.justCopied ? "checkmark" : "camera.viewfinder")
            .font(.system(size: state.justCopied ? 11 : 13, weight: .semibold))
            .foregroundStyle(state.justCopied ? theme.accent : theme.ink)
            .frame(width: M.button, height: M.button)
            .background(theme.surface, in: Circle())
            .accessibilityElement()
            .accessibilityLabel(state.justCopied ? "Screenshot copied" : "Take a screenshot to the clipboard")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, onCapture)
    }

    private func control(_ icon: String, _ label: String, _ color: Color, _ theme: Theme, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: M.button, height: M.button)
                .background(theme.surface, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// `LiveWaveform` folded into one small strip: your microphone grows up from
/// the centre line and the call's audio grows down, so a flat lower half
/// while people talk still points at missing System Audio Recording
/// permission. Both halves flat means nothing is heard.
private struct WidgetWaveform: View {
    let meter: () -> LevelMeter?
    let mic: Color
    let system: Color
    let floor: Color

    private static let bars = 7
    /// Meter bars (50 ms each) folded into one drawn bar.
    private static let group = 2

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 20)) { _ in
            let snapshot = meter()?.snapshot() ?? [:]
            let up = RecordingWidgetRules.compactLevels(snapshot[.mic] ?? [], count: Self.bars, group: Self.group)
            let down = RecordingWidgetRules.compactLevels(snapshot[.system] ?? [], count: Self.bars, group: Self.group)
            Canvas { ctx, size in
                let step = size.width / CGFloat(Self.bars)
                let width = max(1, step * 0.6)
                let half = size.height / 2
                for i in 0..<Self.bars {
                    let x = CGFloat(i) * step + (step - width) / 2
                    draw(&ctx, level: up[i], x: x, width: width, from: half - 0.5, reach: half - 0.5, sign: -1, color: mic)
                    draw(&ctx, level: down[i], x: x, width: width, from: half + 0.5, reach: half - 0.5, sign: 1, color: system)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Live audio levels")
    }

    /// One bar growing from the centre line; a silent bar keeps a dot so the
    /// strip reads as "on but quiet" rather than missing.
    private func draw(_ ctx: inout GraphicsContext, level: Float, x: CGFloat, width: CGFloat,
                      from: CGFloat, reach: CGFloat, sign: CGFloat, color: Color) {
        let h = max(1, CGFloat(level) * reach)
        let rect = CGRect(x: x, y: sign < 0 ? from - h : from, width: width, height: h)
        ctx.fill(Path(roundedRect: rect, cornerRadius: width / 2), with: .color(level > 0.02 ? color : floor))
    }
}
