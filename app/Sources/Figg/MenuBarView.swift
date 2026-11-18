import FiggStore
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    /// The menu bar panel this view sits in. `.window` style menus stay open
    /// after a click, unlike real menus, so every button closes it first.
    @State private var panel: NSWindow?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.isRecording, let started = model.recordingStarted {
                if model.isPaused {
                    Label("Paused", systemImage: "pause.circle.fill")
                        .foregroundStyle(.secondary)
                } else {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Label("Recording \(formatTimestamp(ctx.date.timeIntervalSince(started)))", systemImage: "record.circle.fill")
                            .foregroundStyle(.red)
                    }
                }
                Button("Stop and write notes") { dismiss { model.toggleRecording() } }
                    .keyboardShortcut(.defaultAction)
                Button(model.isPaused ? "Resume recording" : "Pause recording") { dismiss { model.togglePause() } }
                Button("Copy consent message") { dismiss { model.copyConsentSnippet() } }
            } else {
                Button("Start recording") {
                    dismiss {
                        model.toggleRecording()
                        open()
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
            Text("⌃⌥⌘R from any app").font(.caption).foregroundStyle(.secondary)
            Divider()
            Button("Open figg") { dismiss { open() } }
            Button("Settings…") { dismiss { SettingsWindow.open() } }
            Button("Dictation History…") { dismiss { model.dictation.showHistory() } }
            Button("Check for Updates…") {
                dismiss {
                    Task { await model.checkForUpdatesNow() }
                    open()
                }
            }
            Button("Report a Bug…") {
                dismiss {
                    openWindow(id: "bug-report")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
            }
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding(12)
        .frame(width: 240)
        .background(HostWindowReader { panel = $0 })
    }

    /// Closes the menu panel, then runs the action, so a window the action
    /// opens comes up in front rather than behind the panel.
    ///
    /// It closes by clicking the menu bar icon, the way the user would.
    /// Closing the panel window directly leaves SwiftUI thinking it is open:
    /// the icon stays highlighted and the next click does nothing.
    private func dismiss(_ action: () -> Void) {
        if let panel, panel.isVisible {
            if let button = Self.statusButton() {
                button.performClick(nil)
            } else {
                panel.close()
            }
        }
        action()
    }

    /// figg's menu bar icon. It is the app's only status item.
    private static func statusButton() -> NSStatusBarButton? {
        for window in NSApp.windows where window.className.contains("StatusBarWindow") {
            if let button = findButton(in: window.contentView) { return button }
        }
        return nil
    }

    private static func findButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for sub in view.subviews {
            if let found = findButton(in: sub) { return found }
        }
        return nil
    }

    private func open() {
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

/// Hands back the NSWindow a SwiftUI view is shown in, once it is attached.
struct HostWindowReader: NSViewRepresentable {
    let found: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ReaderView()
        view.onWindow = found
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ReaderView: NSView {
        var onWindow: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Not during SwiftUI's own update, where setting state warns.
            let window = window
            DispatchQueue.main.async { [onWindow] in onWindow?(window) }
        }
    }
}
