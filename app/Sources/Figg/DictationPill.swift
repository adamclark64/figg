import AppKit
import FiggStore
import SwiftUI

/// The dictation panel at the bottom of the screen: the words as they are
/// heard, the app they will go into, a live wave, and a menu of actions.
/// A non-activating panel, so the app being typed into keeps focus and its
/// cursor even when the panel is clicked.
@MainActor
final class DictationPill {
    private let panel: NSPanel
    static let size = NSSize(width: 600, height: 190)

    /// Whether the box is open. The view animates every change: a small
    /// pill springs open into the box on show and folds back into it on hide.
    private let presence = PillPresence()

    init(controller: DictationController) {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: DictationPanelView(controller: controller, presence: presence))
    }

    /// Bumped by every show and hide, so a close that a new show interrupts
    /// does not order the panel out when its animation ends.
    private var generation = 0
    private var isHiding = false

    /// Puts the panel up and springs the box open. Showing it again while it
    /// is up (a new phase) only keeps it there; showing it while it closes
    /// springs it straight back from wherever the close had got to.
    func show() {
        generation += 1
        let alreadyUp = panel.isVisible && !isHiding
        isHiding = false
        guard !alreadyUp else { return }
        if !panel.isVisible { panel.setFrameOrigin(restingOrigin()) }
        panel.orderFrontRegardless()
        presence.open = true
    }

    /// Folds the box back into a pill that drops away, then takes the panel
    /// off screen once the view has finished animating.
    func hide() {
        guard panel.isVisible, !isHiding else { return }
        generation += 1
        let mine = generation
        isHiding = true
        presence.open = false
        DispatchQueue.main.asyncAfter(deadline: .now() + PanelMotion.closeDuration) { [weak self] in
            guard let self, self.generation == mine else { return }
            self.isHiding = false
            self.panel.orderOut(nil)
        }
    }

    /// Centred just above the bottom of the screen with the active window.
    private func restingOrigin() -> NSPoint {
        guard let screen = NSScreen.main else { return panel.frame.origin }
        let f = screen.visibleFrame
        return NSPoint(x: f.midX - panel.frame.width / 2, y: f.minY + 12)
    }
}

/// Open or closed, shared between the panel and its view.
@MainActor
final class PillPresence: ObservableObject {
    @Published var open = false
}

/// Always dark, like a heads-up display, in figg's night colours.
enum PanelColors {
    static let top = Color(nsColor: NSColor(hex: 0x2A2127))
    static let bottom = Color(nsColor: NSColor(hex: 0x1C1619))
    static let line = Color(nsColor: NSColor(hex: 0x3F333A))
    static let ink = Color(nsColor: NSColor(hex: 0xF5EEF2))
    static let muted = Color(nsColor: NSColor(hex: 0xA8999F))
    static let accent = Color(nsColor: NSColor(hex: 0xE08BBD))
    static let warning = Color(nsColor: NSColor(hex: 0xF0B36A))
}

/// How the box opens and closes. Opening, a small pill rises from the
/// bottom of the screen and springs out into the full box, a light runs
/// once round its edge, and the words, wave and buttons follow it in.
/// Closing, the contents go first, the box folds back into the pill, and
/// the pill drops away. Reduce Motion keeps only a fade.
enum PanelMotion {
    static let openSize = CGSize(width: 560, height: 150)
    static let openRadius: CGFloat = 26
    static let pillSize = CGSize(width: 128, height: 34)
    /// How far below its place the pill starts, and drops back to. Kept
    /// inside the panel's 20 pt margin, or the window clips the pill.
    static let drop: CGFloat = 12
    /// Time the close takes before the panel can go off screen.
    static let closeDuration: TimeInterval = 0.36

    static func box(open: Bool) -> Animation {
        open ? .spring(response: 0.5, dampingFraction: 0.68) : .spring(response: 0.26, dampingFraction: 0.92)
    }
    /// The pill appears straight away, and fades only after it has folded up.
    static func presence(open: Bool) -> Animation {
        open ? .easeOut(duration: 0.14) : .easeIn(duration: 0.14).delay(0.2)
    }
    static func lift(open: Bool) -> Animation {
        open ? .spring(response: 0.42, dampingFraction: 0.72) : .easeIn(duration: 0.16).delay(0.18)
    }
    /// The contents follow the box in, and leave before it folds.
    static func contents(open: Bool) -> Animation {
        open ? .spring(response: 0.42, dampingFraction: 0.85).delay(0.13) : .easeIn(duration: 0.09)
    }
    static func gear(open: Bool) -> Animation {
        open ? .spring(response: 0.36, dampingFraction: 0.55).delay(0.24) : .easeIn(duration: 0.08)
    }
    static let fade = Animation.easeInOut(duration: 0.18)
}

struct DictationPanelView: View {
    @ObservedObject var controller: DictationController
    @ObservedObject var presence: PillPresence
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Counts up by one on every open; its fraction drives the light round
    /// the edge, so each open runs it once with no reset in between.
    @State private var sweep: Double = 0

    private var open: Bool { presence.open }
    /// With Reduce Motion the box keeps its shape and only fades.
    private var morphOpen: Bool { open || reduceMotion }

    var body: some View {
        let size = morphOpen ? PanelMotion.openSize : PanelMotion.pillSize
        let radius = morphOpen ? PanelMotion.openRadius : PanelMotion.pillSize.height / 2
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)

        ZStack(alignment: .bottom) {
            shape
                .fill(LinearGradient(colors: [PanelColors.top, PanelColors.bottom], startPoint: .top, endPoint: .bottom))
                .overlay(shape.strokeBorder(PanelColors.line, lineWidth: 1))
                .modifier(SweepGlow(progress: sweep, radius: radius))
                .shadow(color: .black.opacity(0.45), radius: 16, y: 6)
                .frame(width: size.width, height: size.height)
                .animation(PanelMotion.box(open: open), value: morphOpen)
            content
                .frame(width: PanelMotion.openSize.width, height: PanelMotion.openSize.height)
                .opacity(open ? 1 : 0)
                .blur(radius: open || reduceMotion ? 0 : 6)
                .offset(y: open || reduceMotion ? 0 : 10)
                .animation(reduceMotion ? PanelMotion.fade : PanelMotion.contents(open: open), value: open)
                .mask(alignment: .bottom) {
                    shape
                        .frame(width: size.width, height: size.height)
                        .animation(PanelMotion.box(open: open), value: morphOpen)
                }
        }
        .frame(width: PanelMotion.openSize.width, height: PanelMotion.openSize.height, alignment: .bottom)
        .overlay(alignment: .topTrailing) {
            gear
                .scaleEffect(open ? 1 : 0.2)
                .opacity(open ? 1 : 0)
                .animation(reduceMotion ? PanelMotion.fade : PanelMotion.gear(open: open), value: open)
        }
        .onHover { controller.hovering = $0 }
        .opacity(open ? 1 : 0)
        .animation(reduceMotion ? PanelMotion.fade : PanelMotion.presence(open: open), value: open)
        .offset(y: open || reduceMotion ? 0 : PanelMotion.drop)
        .animation(PanelMotion.lift(open: open), value: open)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
        .onChange(of: open) { _, isOpen in
            guard isOpen, !reduceMotion else { return }
            withAnimation(.easeOut(duration: 0.55).delay(0.08)) { sweep = sweep.rounded(.down) + 1 }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(headline)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(isPlaceholder ? PanelColors.muted : PanelColors.ink)
                .lineLimit(3)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.easeOut(duration: 0.15), value: controller.liveText)
            Spacer(minLength: 6)
            // The hint sits on its own line, so a long one never runs into
            // the wave.
            Text(status)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(statusIsWarning ? PanelColors.warning : PanelColors.muted)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 8)
            ZStack {
                WaveBars(phase: controller.phase, level: { CGFloat(controller.level) }, revealed: open || reduceMotion)
                HStack(spacing: 10) {
                    appIcon
                    Spacer()
                    actions
                }
            }
            .frame(height: 30)
        }
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    // MARK: Text

    private var isPlaceholder: Bool {
        if case .note = controller.phase, controller.liveText.isEmpty { return false }
        return controller.liveText.isEmpty
    }

    private var headline: String {
        if !controller.liveText.isEmpty { return controller.liveText }
        switch controller.phase {
        case .listening: return "Listening…"
        case .transcribing: return "Transcribing…"
        case .cleaning: return "Cleaning up…"
        case .note(let text): return text
        default: return ""
        }
    }

    private var status: String {
        let app = controller.target?.localizedName ?? "the app in front"
        switch controller.phase {
        case .listening where controller.handsFree:
            return "Press \(controller.shortcutLabel) to finish · esc to cancel"
        case .listening: return "Release \(controller.shortcutLabel) to type · esc to cancel"
        case .transcribing: return "esc to cancel"
        case .cleaning: return "esc to type it as heard"
        case .done(.inserted), .done(.typed): return "Typed into \(app)"
        case .done(.notInserted): return "Saved in History"
        case .note(let text): return controller.liveText.isEmpty ? "" : text
        case .idle: return ""
        }
    }

    private var statusIsWarning: Bool {
        if case .note = controller.phase { return true }
        return false
    }

    // MARK: Controls

    @ViewBuilder private var appIcon: some View {
        if let icon = controller.target?.icon {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 30, height: 30)
                .help(controller.target?.localizedName ?? "")
        } else {
            Image(systemName: "app.dashed").font(.system(size: 22)).foregroundStyle(PanelColors.muted)
        }
    }

    private var actions: some View {
        Menu {
            Button("Insert Last", systemImage: "text.insert") { controller.insertLast() }
                .disabled(controller.history.isEmpty)
            Button("Copy Last", systemImage: "doc.on.doc") { controller.copyLast() }
                .disabled(controller.history.isEmpty)
            Button("Use Raw Text", systemImage: "text.quote") { controller.useRawText() }
                .disabled(!controller.canUseRawText)
            Button("Process Again", systemImage: "wand.and.stars") { controller.processAgain() }
                .disabled(controller.history.isEmpty || controller.phase == .cleaning)
            Divider()
            Button("Dictation History…", systemImage: "clock.arrow.circlepath") { controller.showHistory() }
            Button("Dictation Settings…", systemImage: "gearshape") { controller.showSettings() }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(PanelColors.ink)
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var gear: some View {
        Button { controller.showSettings() } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 13))
                .foregroundStyle(PanelColors.ink)
                .frame(width: 30, height: 30)
                .background(Circle().fill(PanelColors.bottom))
                .overlay(Circle().strokeBorder(PanelColors.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Dictation settings")
        .offset(x: -14, y: -10)
    }
}

/// Eleven rounded bars in the middle of the panel. While listening they
/// follow the mic level with a little ripple; while transcribing a gentle
/// pulse travels across; otherwise they rest as dots.
struct WaveBars: View {
    let phase: DictationController.Phase
    let level: () -> CGFloat
    /// Off while the box is closed: the bars grow in one after another from
    /// the middle out as it opens.
    var revealed = true
    private let count = 11

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let l = min(1, level())
            HStack(spacing: 5) {
                ForEach(0..<count, id: \.self) { i in
                    Capsule()
                        .fill(color)
                        .frame(width: 5, height: height(i, t: t, level: l))
                        .scaleEffect(y: revealed ? 1 : 0.05)
                        .opacity(revealed ? 1 : 0)
                        .animation(reveal(i), value: revealed)
                }
            }
            .frame(height: 28)
        }
    }

    private func reveal(_ i: Int) -> Animation {
        guard revealed else { return .easeIn(duration: 0.08) }
        let fromMiddle = abs(Double(i) - Double(count - 1) / 2)
        return .spring(response: 0.34, dampingFraction: 0.5).delay(0.16 + fromMiddle * 0.03)
    }

    private var color: Color {
        switch phase {
        case .listening, .transcribing, .cleaning: return PanelColors.accent
        default: return PanelColors.muted.opacity(0.6)
        }
    }

    private func height(_ i: Int, t: Double, level: CGFloat) -> CGFloat {
        let centre = 1 - abs(Double(i) - Double(count - 1) / 2) / (Double(count) / 2)
        switch phase {
        case .listening:
            let ripple = 0.55 + 0.45 * sin(t * 9 + Double(i) * 0.8)
            return 8 + 20 * level * CGFloat(ripple * (0.5 + 0.5 * centre))
        case .transcribing, .cleaning:
            let pulse = max(0, sin(t * 4 - Double(i) * 0.6))
            return 8 + 10 * CGFloat(pulse)
        default:
            return 8
        }
    }
}

/// A light that runs once round the box's edge as it opens: a bright arc of
/// figg pink chasing itself round, with a soft glow, fading in and out.
/// Only the fraction of `progress` matters, so it rests unseen at every
/// whole number.
struct SweepGlow: ViewModifier, Animatable {
    var progress: Double
    var radius: CGFloat

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let p = progress - progress.rounded(.down)
        let strength = sin(p * .pi)
        let start = Angle.degrees(90 + p * 400)
        let arc = AngularGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .clear, location: 0.55),
                .init(color: PanelColors.accent, location: 0.85),
                .init(color: .white, location: 0.97),
                .init(color: .clear, location: 1),
            ],
            center: .center, startAngle: start, endAngle: start + .degrees(360))
        let edge = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .overlay(edge.strokeBorder(arc, lineWidth: 2).opacity(strength).allowsHitTesting(false))
            .overlay(edge.strokeBorder(arc, lineWidth: 8).blur(radius: 8).opacity(strength).allowsHitTesting(false))
    }
}
