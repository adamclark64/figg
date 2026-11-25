import AppKit
import FiggAudio
import FiggFeedback
import FiggMeetingApps
import FiggStartup
import FiggWidget
import SwiftUI

@main
struct FiggApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @StateObject private var settings: AppSettings
    @StateObject private var model: AppModel

    init() {
        // First, before anything that could stall, so every stage and any
        // main-thread stall of this launch lands in the stage log.
        StartupLog.shared.begin()
        StartupWatchdog.shared.start()
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
                Button(model.isPaused ? "Resume Recording" : "Pause Recording") { model.togglePause() }
                    .keyboardShortcut("p", modifiers: [.command, .option, .control])
                    .disabled(!model.isRecording)
                Button("New Note Without Recording") { _ = model.newMeeting() }
                    .keyboardShortcut("n")
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Task { await model.checkForUpdatesNow() } }
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
            if model.isRecording, model.isPaused {
                Image(systemName: "pause.circle.fill")
            } else if model.isRecording {
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

/// Notices when the main thread stops answering during launch and records
/// the stall in the stage log, for the next bug report. A step that blocks
/// the main actor cannot be timed out and no banner can draw meanwhile, so
/// this is the only way such a hang leaves a trace.
///
/// A main-queue timer stamps a heartbeat; a background timer feeds the
/// stamps and the clock to `StallDetector` and writes any stall it reports.
/// Both stop 10 s after launch reaches `ready`.
final class StartupWatchdog: @unchecked Sendable {
    static let shared = StartupWatchdog(log: .shared)

    private let log: StartupLog
    private let lock = NSLock()
    private var detector: StallDetector
    private var started = false
    private var readyAt: TimeInterval?
    private var heartbeat: DispatchSourceTimer?
    private var check: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "figg.startup-watchdog", qos: .utility)

    /// How long the watchdog keeps watching once launch is `ready`.
    private static let afterReady: TimeInterval = 10

    init(log: StartupLog) {
        self.log = log
        detector = StallDetector(start: Self.now())
    }

    /// Monotonic seconds; does not jump with the wall clock.
    private static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Starts both timers. Called once, on the main thread, from `FiggApp.init`.
    func start() {
        let first = lock.withLock { () -> Bool in
            guard !started else { return false }
            started = true
            detector = StallDetector(start: Self.now())
            return true
        }
        guard first else { return }

        // Fires only when the main queue is free, so a gap means a stall.
        let beat = DispatchSource.makeTimerSource(queue: .main)
        beat.schedule(deadline: .now(), repeating: .milliseconds(500))
        beat.setEventHandler { [weak self] in self?.beat() }

        let watch = DispatchSource.makeTimerSource(queue: queue)
        watch.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
        watch.setEventHandler { [weak self] in self?.tick() }

        lock.withLock {
            heartbeat = beat
            check = watch
        }
        beat.resume()
        watch.resume()
    }

    private func beat() {
        let time = Self.now()
        lock.withLock { detector.heartbeat(at: time) }
    }

    /// On the background queue: records a stall at the current stage, and
    /// stops both timers once launch has been `ready` for a while.
    private func tick() {
        let time = Self.now()
        let stage = log.current?.stage ?? .launched
        let stall = lock.withLock { detector.stall(at: time) }
        if let stall { log.stalled(at: stage, seconds: stall) }
        guard stage == .ready else { return }
        let done = lock.withLock { () -> Bool in
            if readyAt == nil { readyAt = time }
            return time - (readyAt ?? time) >= Self.afterReady
        }
        if done { stop() }
    }

    private func stop() {
        let timers = lock.withLock { () -> [DispatchSourceTimer] in
            let all = [heartbeat, check].compactMap { $0 }
            heartbeat = nil
            check = nil
            return all
        }
        timers.forEach { $0.cancel() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var hotKey: HotKey?

    /// `open build/Figg.app --args --probe-audio` runs the capture probe with
    /// figg's own permissions and writes the report to /tmp/figg-probe.txt;
    /// `--ax-dump <profile id>` saves a scrubbed meeting app capture.
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Screenshots a bug report left for pasting into the browser.
        ScreenshotHandoff.removeOldFolders(
            in: ScreenshotHandoff.root(bundleIdentifier: Bundle.main.bundleIdentifier))
        if let dump = AXDump.arguments(CommandLine.arguments) {
            // `--ax-dump <profile id>`: saves what figg reads of that meeting
            // app, scrubbed, for test fixtures (see AXDump).
            let line = AXDump.run(profileID: dump.id, replacements: dump.replacements, keepValues: dump.keepValues)
            NSLog("figg ax-dump: %@", line)
            try? (line + "\n").write(toFile: "/tmp/figg-ax-dump.txt", atomically: true, encoding: .utf8)
        }
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
