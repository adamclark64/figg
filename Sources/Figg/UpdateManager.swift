import AppKit
import FiggUpdate
import Foundation

/// Thin app-side driver for FiggUpdate: holds UI phase, downloads the dmg,
/// and relaunches. All decisions that deserve tests live in FiggUpdate.
@MainActor
final class UpdateManager: ObservableObject {
    enum Phase: Equatable {
        case idle, checking
        case available(ReleaseInfo)
        case downloading, installing
        case upToDate
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// 0...1 while `.downloading`, nil when the size is not known yet.
    @Published private(set) var downloadProgress: Double?

    /// Stamped by bundle.sh from the release tag. Nil for `swift run` and
    /// Xcode builds: comparing against a made-up version would offer every
    /// release as an update to a build that must never be replaced.
    nonisolated static var currentVersion: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    /// Returns the newer release, if any. quietly=true (launch auto-check)
    /// stays silent on failure; the Settings button passes false and shows
    /// the outcome either way.
    @discardableResult
    func check(quietly: Bool) async -> ReleaseInfo? {
        // A check mid-install would reset the phase and resurrect the Update
        // button, letting a second install race the first.
        switch phase {
        case .downloading, .installing: return nil
        default: break
        }
        guard let current = Self.currentVersion else {
            phase = quietly ? .idle : .failed("This build has no version, so updates are disabled.")
            return nil
        }
        phase = .checking
        do {
            let release = try await UpdateChecker().latest()
            if UpdateChecker.isNewer(release.version, than: current) {
                phase = .available(release)
                return release
            }
            phase = quietly ? .idle : .upToDate
        } catch {
            phase = quietly ? .idle : .failed(error.localizedDescription)
        }
        return nil
    }

    /// Download, install over the running bundle, relaunch. The recording
    /// guard lives in AppModel, which owns that state. `canRelaunch` is
    /// asked after the install, so the caller can veto the quit if
    /// circumstances changed during the download. Returns whether it
    /// relaunched.
    @discardableResult
    func downloadAndInstall(_ release: ReleaseInfo, canRelaunch: () -> Bool = { true }) async -> Bool {
        // Outside a real .app (swift run, Xcode) bundleURL is the build products
        // directory, and the swap would delete it.
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            phase = .failed("figg is not running from an app bundle, so it can't update itself.")
            return false
        }
        downloadProgress = nil
        phase = .downloading
        var stagingDir: URL?
        defer { if let stagingDir { _ = try? FileManager.default.removeItem(at: stagingDir) } }
        do {
            let watcher = DownloadProgress { [weak self] fraction in
                Task { @MainActor in self?.downloadProgress = fraction }
            }
            let (temp, response) = try await URLSession.shared.download(from: release.dmgURL, delegate: watcher)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw UpdateError.badResponse((response as? HTTPURLResponse)?.statusCode ?? 0)
            }
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("figg-update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            stagingDir = dir
            let dmg = dir.appendingPathComponent("figg-\(release.version).dmg")
            try FileManager.default.moveItem(at: temp, to: dmg)

            phase = .installing
            try await UpdateInstaller().install(dmg: dmg, over: Bundle.main.bundleURL)
            guard canRelaunch() else {
                phase = .idle
                return false
            }
            relaunch()
            return true
        } catch {
            phase = .failed(error.localizedDescription)
            return false
        }
    }

    /// `open -n` from a detached shell that outlives this process.
    private func relaunch() {
        let path = Bundle.main.bundleURL.path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open -n \"$0\"", path]
        _ = try? process.run()
        NSApp.terminate(nil)
    }
}

/// Reports a download's fraction complete, at most once per whole percent so
/// the UI is not redrawn for every network packet. Reports nil while the
/// server has not said how big the file is.
private final class DownloadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let report: @Sendable (Double?) -> Void
    private let lock = NSLock()
    private var observation: NSKeyValueObservation?
    private var lastPercent = -1

    init(report: @escaping @Sendable (Double?) -> Void) {
        self.report = report
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        let observation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            self?.update(progress.totalUnitCount > 0 ? progress.fractionCompleted : nil)
        }
        lock.lock()
        self.observation = observation
        lock.unlock()
    }

    private func update(_ fraction: Double?) {
        let percent = fraction.map { Int($0 * 100) } ?? -1
        lock.lock()
        let changed = percent != lastPercent
        lastPercent = percent
        lock.unlock()
        if changed { report(fraction) }
    }
}
