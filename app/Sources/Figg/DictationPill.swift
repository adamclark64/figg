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
        panel.contentView = NSHostingView(rootView: DictationPanelView(controller: controller))
    }

    /// Rises this far into place as it opens, and sinks part of it as it closes.
    private static let travel: CGFloat = 14
    /// Bumped by every show and hide, so a close that a new show interrupts
    /// does not order the panel out when its fade ends.
    private var generation = 0
    private var isHiding = false

    /// Fades the panel in while it rises into place. Showing it again while
    /// it is up (a new phase) only keeps it there.
    func show() {
        generation += 1
        let resting = restingOrigin()
        let alreadyUp = panel.isVisible && !isHiding
        isHiding = false
        // Left alone, so a fade-in still running finishes smoothly.
        guard !alreadyUp else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.setFrameOrigin(NSPoint(x: resting.x, y: resting.y - (reduceMotion ? 0 : Self.travel)))
        }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)  // quick, soft landing
            panel.animator().alphaValue = 1
            panel.animator().setFrameOrigin(resting)
        }
    }

    /// Fades the panel out while it sinks a little, then takes it off screen.
    func hide() {
        guard panel.isVisible, !isHiding else { return }
        generation += 1
        let mine = generation
        isHiding = true
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let origin = panel.frame.origin
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            if !reduceMotion {
                panel.animator().setFrameOrigin(NSPoint(x: origin.x, y: origin.y - Self.travel / 2))
            }
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == mine else { return }
                self.isHiding = false
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
            }
        }
    }

    /// Centred just above the bottom of the screen with the active window.
    private func restingOrigin() -> NSPoint {
        guard let screen = NSScreen.main else { return panel.frame.origin }
        let f = screen.visibleFrame
        return NSPoint(x: f.midX - panel.frame.width / 2, y: f.minY + 12)
    }
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

struct DictationPanelView: View {
    @ObservedObject var controller: DictationController

    var body: some View {
        content
            .frame(width: 560, height: 150)
            .background(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(LinearGradient(colors: [PanelColors.top, PanelColors.bottom], startPoint: .top, endPoint: .bottom))
                    .overlay(
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .strokeBorder(PanelColors.line, lineWidth: 1))
                    .shadow(color: .black.opacity(0.45), radius: 16, y: 6))
            .overlay(alignment: .topTrailing) { gear }
            .onHover { controller.hovering = $0 }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(\.colorScheme, .dark)
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
                WaveBars(phase: controller.phase, level: { CGFloat(controller.level) })
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
                }
            }
            .frame(height: 28)
        }
    }

    private var color: Color {
        switch phase {
        case .listening, .transcribing: return PanelColors.accent
        default: return PanelColors.muted.opacity(0.6)
        }
    }

    private func height(_ i: Int, t: Double, level: CGFloat) -> CGFloat {
        let centre = 1 - abs(Double(i) - Double(count - 1) / 2) / (Double(count) / 2)
        switch phase {
        case .listening:
            let ripple = 0.55 + 0.45 * sin(t * 9 + Double(i) * 0.8)
            return 8 + 20 * level * CGFloat(ripple * (0.5 + 0.5 * centre))
        case .transcribing:
            let pulse = max(0, sin(t * 4 - Double(i) * 0.6))
            return 8 + 10 * CGFloat(pulse)
        default:
            return 8
        }
    }
}
