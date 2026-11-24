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
    private let signer = SignerCheck.currentRequirement()

    private init() {
        asked = askedStore.load()
        refresh()
    }

    static func open() { SettingsWindow.open(tab: .permissions) }

    func status(_ permission: Permission) -> PermissionStatus { statuses[permission] ?? .notAsked }
    func step(_ permission: Permission) -> PermissionStep {
        PermissionStep.next(for: status(permission), fixedThisLaunch: fixed.contains(permission),
                            askedBefore: asked.contains(permission))
    }
    var missing: [Permission] { Self.needed.filter { status($0) != .granted } }

    func refresh() {
        statuses = Dictionary(uniqueKeysWithValues: Permission.allCases.map { ($0, SystemPermissions.status($0)) })
        // Remembered only once everything works, so a half-finished fix
        // still opens this screen next launch.
        if missing.isEmpty, let signer { SignerCheck.store(signer, at: signerURL) }
    }

    /// At launch: a new signer (or a first run) with something missing opens
    /// this screen, since macOS will not say so itself.
    func checkAtLaunch() {
        refresh()
        guard SignerCheck.shouldOpenPermissions(current: signer, stored: SignerCheck.stored(at: signerURL), statuses: statuses) else { return }
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
        refresh()
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
