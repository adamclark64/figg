import AppKit
import FiggAudio
import SwiftUI

/// Polls which apps hold the microphone every 2 s and offers to start or
/// stop recording. The decision logic lives in `MeetingDetector`; this class
/// only samples, prompts and acts.
@MainActor
final class MeetingWatcher {
    private weak var model: AppModel?
    private let settings: AppSettings
    private var detector = MeetingDetector()
    private let prompt = PromptPanel()
    private var timer: Timer?

    init(model: AppModel, settings: AppSettings) {
        self.model = model
        self.settings = settings
    }

    func start() {
        guard #available(macOS 14.2, *) else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    @available(macOS 14.2, *)
    private func tick() {
        guard let model, settings.config.detection.enabled else { return }
        detector.ignored = MeetingDetector.defaultIgnored.union(settings.config.detection.ignoreApps)
        let apps = Set(MicUsage.appsUsingInput().map(MeetingDetector.parentBundleID))
        switch detector.update(apps: apps, isRecording: model.isRecording) {
        case let .started(app)?:
            prompt.show(
                icon: "waveform",
                title: "\(Self.displayName(app)) is using your microphone",
                message: "Record this meeting with figg?",
                primary: "Record",
                secondary: "Not now"
            ) { [weak model] in
                Task { await model?.startRecording() }
                Self.showMainWindow()
            }
        case let .ended(app)?:
            prompt.show(
                icon: "stop.circle",
                title: "\(Self.displayName(app)) stopped using the microphone",
                message: "Stop recording and write up the notes?",
                primary: "Stop",
                secondary: "Keep recording"
            ) { [weak model] in
                Task { await model?.stopRecording() }
            }
        case nil:
            break
        }
    }

    /// "Zoom" for us.zoom.xos; the raw ID if the app can't be found.
    static func displayName(_ id: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return id }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    static func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }?.makeKeyAndOrderFront(nil)
    }
}

/// A small floating card in the top-right corner. Non-activating, so it does
/// not pull focus from the meeting app; disappears after 30 s.
@MainActor
final class PromptPanel {
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    /// The fig app icon, shown in prompts (and on the recording widget)
    /// instead of a generic symbol. Missing when run via `swift run`; the SF
    /// Symbol `icon` is the fallback.
    static let figLogo: NSImage? = Bundle.main.image(forResource: "AppIcon")

    func show(icon: String, title: String, message: String, primary: String, secondary: String, onPrimary: @escaping () -> Void) {
        close()
        let card = PromptCard(logo: Self.figLogo, icon: icon, title: title, message: message, primary: primary, secondary: secondary,
                              onPrimary: { [weak self] in self?.close(); onPrimary() },
                              onSecondary: { [weak self] in self?.close() })
        let host = NSHostingView(rootView: card)
        host.frame.size = host.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                            styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.contentView = host
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.maxX - panel.frame.width - 16, y: screen.maxY - panel.frame.height - 16))
        }
        panel.orderFrontRegardless()
        self.panel = panel
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            self?.close()
        }
    }

    func close() {
        dismissTask?.cancel()
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct PromptCard: View {
    let logo: NSImage?
    let icon: String
    let title: String
    let message: String
    let primary: String
    let secondary: String
    let onPrimary: () -> Void
    let onSecondary: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let logo {
                Image(nsImage: logo)
                    .resizable()
                    .frame(width: 32, height: 32)
            } else {
                Image(systemName: icon).font(.title2).foregroundStyle(.red)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline).fixedSize(horizontal: false, vertical: true)
                Text(message).foregroundStyle(.secondary)
                HStack {
                    Button(primary, action: onPrimary).keyboardShortcut(.defaultAction)
                    Button(secondary, action: onSecondary)
                }
                .padding(.top, 2)
            }
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
    }
}
