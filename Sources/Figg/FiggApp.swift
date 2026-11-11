import AppKit
import FiggAudio
import FiggWidget
import SwiftUI

@main
struct FiggApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @StateObject private var settings: AppSettings
    @StateObject private var model: AppModel

    init() {
        let settings = AppSettings()
        _settings = StateObject(wrappedValue: settings)
        _model = StateObject(wrappedValue: AppModel(settings: settings))
    }

    var body: some Scene {
        Window("figg", id: "main") {
            MainView()
                .environmentObject(model)
                .environmentObject(settings)
                .frame(minWidth: 820, minHeight: 520)
                .onAppear { delegate.hotKey = HotKey { model.toggleRecording() } }
                // Pick up hand edits to config.yaml.
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    settings.reload()
                }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button(model.isRecording ? "Stop Recording" : "Start Recording") { model.toggleRecording() }
                    .keyboardShortcut("r", modifiers: [.command, .option, .control])
                Button("New Note Without Recording") { _ = model.newMeeting() }
                    .keyboardShortcut("n")
            }
            BugReportCommands()
        }

        // Its own window (not a sheet) so it opens from the menu bar menu even
        // when the main window is closed.
        Window("Report a Bug", id: "bug-report") {
            BugReportView()
                .environmentObject(settings)
                .environment(\.theme, Theme.named(settings.config.appearance.theme))
                .environment(\.loaderStyle, LoaderStyle.named(settings.config.appearance.loader))
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            MenuBarView()
                .environmentObject(model)
        } label: {
            if model.isRecording {
                Image(systemName: "record.circle.fill").symbolRenderingMode(.multicolor)
            } else if let fig = Self.menuBarIcon {
                Image(nsImage: fig)
            } else {
                Image(systemName: "waveform")
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(model)
                .environment(\.loaderStyle, LoaderStyle.named(settings.config.appearance.loader))
        }
    }
}

/// Adds "Report a Bug…" to the Help menu.
struct BugReportCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .help) {
            Button("Report a Bug…") {
                openWindow(id: "bug-report")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
        }
    }
}

extension FiggApp {
    /// Fig silhouette from the app bundle, as a template so macOS tints it for
    /// light and dark menu bars. Missing when run via `swift run`.
    static let menuBarIcon: NSImage? = {
        guard let image = Bundle.main.image(forResource: "MenuBarIcon") else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: image.size.width / image.size.height * 18, height: 18)
        return image
    }()
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var hotKey: HotKey?

    /// `open build/Figg.app --args --probe-audio` runs the capture probe with
    /// figg's own permissions and writes the report to /tmp/figg-probe.txt.
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard CommandLine.arguments.contains("--probe-audio") else { return }
        try? "probe starting\n".write(toFile: "/tmp/figg-probe.txt", atomically: true, encoding: .utf8)
        Task {
            let report = await AudioProbe.run(seconds: 6)
            try? report.write(toFile: "/tmp/figg-probe.txt", atomically: true, encoding: .utf8)
            NSLog("figg probe:\n%@", report)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
