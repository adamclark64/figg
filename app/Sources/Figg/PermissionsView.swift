import AppKit
import FiggPermissions
import FiggStore
import SwiftUI

/// The one place figg asks for macOS permissions. Everything else in the app
/// that finds a permission missing sends the user here instead of firing its
/// own prompt, so prompts only ever come from a button the user pressed.
@MainActor
final class PermissionCenter: ObservableObject {
    static let shared = PermissionCenter()

    /// What figg can't record or dictate without. Screen Recording is only
    /// for the widget's screenshot button.
    static let needed: [Permission] = [.microphone, .systemAudio, .accessibility]

    @Published private(set) var statuses: [Permission: PermissionStatus] = [:]
    /// The row whose button is running.
    @Published private(set) var working: Permission?
    /// A permission was just given that macOS only applies after a restart.
    @Published private(set) var needsRelaunch = false

    private var fixed: Set<Permission> = []
    private let askedStore = AskedPermissions(in: FiggPaths.standard.base)
    /// Prompts shown before, whose answer this launch should already see.
    private var asked: Set<Permission>
    private let bundleID = Bundle.main.bundleIdentifier ?? "dev.adamclark.figg"
    private let signerURL = SignerCheck.storeURL(in: FiggPaths.standard.base)
    /// This copy's designated requirement, loaded by the first read. Not a
    /// stored-property initialiser: the Security calls behind it can block,
    /// and `shared` is first touched on the main thread during launch.
    private var signer: String?
    private var signerLoaded = false
    /// Whether any read of the statuses has finished. Until one has,
    /// `statuses` is empty and `missing` lists everything, so nothing that
    /// acts on `missing` (storing the signer, the launch check) may run.
    @Published private(set) var hasRead = false
    /// The read in flight, and when it started, so overlapping refreshes
    /// (the Permissions tab ticks every second) share one read.
    private var inFlight: Task<Void, Never>?
    private var inFlightStarted: Date?
    /// Counts reads started, so a stale read finishing late does not clear
    /// the marker of the newer read that replaced it.
    private var readCount = 0
    /// A read in flight longer than this is treated as stuck and no longer
    /// blocks a new one, so a daemon that never answers once does not
    /// freeze the rows for the rest of the launch.
    private static let staleAfter: TimeInterval = 5

    /// Reads nothing: the first status read is `refreshAsync()`, run off
    /// the main thread, so creating `shared` can never stall launch. The
    /// asked-before list is a small file in figg's own folder.
    private init() {
        asked = askedStore.load()
    }

    static func open() { SettingsWindow.open(tab: .permissions) }

    func status(_ permission: Permission) -> PermissionStatus { statuses[permission] ?? .notAsked }
    func step(_ permission: Permission) -> PermissionStep {
        PermissionStep.next(for: status(permission), fixedThisLaunch: fixed.contains(permission),
                            askedBefore: asked.contains(permission))
    }
    var missing: [Permission] { Self.needed.filter { status($0) != .granted } }

    /// For sync callers (views, `AppModel`): starts `refreshAsync()`.
    func refresh() {
        Task { await refreshAsync() }
    }

    /// Reads every status, and the signer once, off the main thread, then
    /// applies them here. A call while a recent read is still running waits
    /// for that read instead of starting another.
    func refreshAsync() async {
        if let inFlight, let started = inFlightStarted, Date().timeIntervalSince(started) < Self.staleAfter {
            await inFlight.value
            return
        }
        readCount += 1
        let number = readCount
        let task = Task { await self.read() }
        inFlight = task
        inFlightStarted = Date()
        await task.value
        if readCount == number {
            inFlight = nil
            inFlightStarted = nil
        }
    }

    private func read() async {
        if !signerLoaded {
            let requirement = await SignerCheck.currentRequirementAsync()
            if !signerLoaded {
                signer = requirement
                signerLoaded = true
            }
        }
        let newStatuses = await SystemPermissions.statuses()
        statuses = newStatuses
        hasRead = true
        // Remembered only once everything works, so a half-finished fix
        // still opens this screen next launch.
        if missing.isEmpty, let signer { SignerCheck.store(signer, at: signerURL) }
    }

    /// For sync callers (`AppModel.init` today): starts `checkAtLaunchAsync()`.
    func checkAtLaunch() {
        Task { await checkAtLaunchAsync() }
    }

    /// At launch: a new signer (or a first run) with something missing opens
    /// this screen, since macOS will not say so itself. Decides only after a
    /// read finished, so an empty `statuses` never counts as "all missing".
    func checkAtLaunchAsync() async {
        await refreshAsync()
        guard hasRead else { return }
        let stored = SignerCheck.stored(at: signerURL)
        guard SignerCheck.shouldOpenPermissions(current: signer, stored: stored, statuses: statuses) else { return }
        Task {
            try? await Task.sleep(for: .seconds(1))
            Self.open()
        }
    }

    /// Runs the row's one step.
    func run(_ permission: Permission) async {
        let step = step(permission)
        guard step != .none, working == nil else { return }
        working = permission
        switch step {
        case .none: break
        case .ask:
            await SystemPermissions.request(permission)
            askedStore.record(permission)
            // Screen Recording only shows its answer after a reopen, so this
            // launch keeps offering Allow; the next one offers Fix.
            if !permission.needsRelaunch { asked.insert(permission) }
        case .fix:
            // Clears only figg's own entry for this one permission.
            _ = await SystemPermissions.reset(permission, bundleID: bundleID)
            fixed.insert(permission)
            await SystemPermissions.request(permission)
        case .openSettings:
            SystemPermissions.open(permission)
        }
        working = nil
        await refreshAsync()
        if permission.needsRelaunch, step != .openSettings { needsRelaunch = true }
    }

    /// Mic and system audio first (their prompts wait for an answer), then
    /// Accessibility, whose prompt hands over to System Settings.
    func fixAll() async {
        for permission in Self.needed where status(permission) != .granted {
            await run(permission)
        }
    }

    /// Quits and opens this same copy again.
    func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundleURL.path]
        try? process.run()
        NSApp.terminate(nil)
    }
}

struct PermissionsSettings: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var center = PermissionCenter.shared
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                if center.missing.isEmpty {
                    Label("figg has everything it needs.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Text("figg needs these to record calls and dictate. Click Fix all and answer macOS's prompts. For Accessibility, switch figg on in the list System Settings opens.")
                    Button("Fix all") { Task { await center.fixAll() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(center.working != nil)
                }
                if center.needsRelaunch {
                    HStack {
                        Text(model.isRecording ? "Reopen figg after this recording to finish." : "figg needs to reopen to use this.")
                        Spacer()
                        Button("Quit & Reopen figg") { center.relaunch() }
                            .disabled(model.isRecording)
                    }
                }
            }
            Section {
                ForEach(shown) { permission in
                    row(permission)
                }
            }
            Text("If System Settings shows figg switched on but it says not allowed here, click Fix: figg clears its own old entry and macOS asks again. No other app's permissions are touched.")
                .settingsCaption()
        }
        .onAppear { center.refresh() }
        .onReceive(tick) { _ in center.refresh() }
    }

    /// Calendars only matters with the calendar switched on.
    private var shown: [Permission] {
        Permission.allCases.filter { $0 != .calendar || model.settings.config.calendar.enabled }
    }

    private func row(_ permission: Permission) -> some View {
        let granted = center.status(permission) == .granted
        let step = center.step(permission)
        return HStack(alignment: .top) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title)
                Text(permission.purpose).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if center.working == permission {
                ProgressView().controlSize(.small)
            } else if step != .none {
                Button(step.label) { Task { await center.run(permission) } }
                    .disabled(center.working != nil)
            } else {
                Text("Allowed").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
