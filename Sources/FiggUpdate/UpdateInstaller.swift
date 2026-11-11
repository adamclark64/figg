import Foundation

/// Shells out for the steps that need real tools (hdiutil, security, xattr,
/// codesign). Tests swap in a recorder so the sequencing and the FileManager
/// work around it are exercised without touching real disks or certs.
public protocol CommandRunner: Sendable {
    @discardableResult
    func run(_ tool: String, _ args: [String]) async throws -> String
}

public struct ProcessRunner: CommandRunner {
    public init() {}

    @discardableResult
    public func run(_ tool: String, _ args: [String]) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        // Drain before waiting so a chatty tool can't fill the pipe and hang.
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw InstallError.command(tool: tool, status: process.terminationStatus,
                                       stderr: String(data: errData, encoding: .utf8) ?? "")
        }
        return String(data: outData, encoding: .utf8) ?? ""
    }
}

public enum InstallError: LocalizedError, Equatable {
    case appMissingFromDMG
    case command(tool: String, status: Int32, stderr: String)

    public var errorDescription: String? {
        switch self {
        case .appMissingFromDMG:
            "The downloaded dmg does not contain Figg.app."
        case let .command(tool, status, stderr):
            "\((tool as NSString).lastPathComponent) failed (\(status)): \(stderr)"
        }
    }
}

/// Installs a downloaded figg dmg over the given app bundle. Everything
/// destructive happens after the new copy is fully staged next to the
/// destination (same volume, so the swap is two renames), which keeps the
/// running app intact if any earlier step fails.
public struct UpdateInstaller: Sendable {
    let runner: any CommandRunner

    public init(runner: any CommandRunner = ProcessRunner()) {
        self.runner = runner
    }

    public func install(dmg: URL, over appURL: URL) async throws {
        let fm = FileManager.default
        let mount = dmg.deletingLastPathComponent().appendingPathComponent("mnt")
        try await runner.run("/usr/bin/hdiutil",
                             ["attach", dmg.path, "-nobrowse", "-readonly", "-mountpoint", mount.path])
        do {
            try await stageAndSwap(from: mount, over: appURL, fm: fm)
        } catch {
            _ = try? await runner.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
            throw error
        }
        _ = try? await runner.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
    }

    private func stageAndSwap(from mount: URL, over appURL: URL, fm: FileManager) async throws {
        let source = mount.appendingPathComponent("Figg.app")
        guard fm.fileExists(atPath: source.appendingPathComponent("Contents").path) else {
            throw InstallError.appMissingFromDMG
        }

        // Stage beside the destination so the final move is a same-volume rename.
        let parent = appURL.deletingLastPathComponent()
        let staged = parent.appendingPathComponent(".figg-update-\(UUID().uuidString)/Figg.app")
        try fm.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Runs on every exit path. After a successful swap the staged app has
        // moved out, so this only removes the empty directory; on failure it
        // removes the half-staged copy instead of leaving a hidden app bundle.
        defer { try? fm.removeItem(at: staged.deletingLastPathComponent()) }
        try fm.copyItem(at: source, to: staged)

        // CI dmgs are ad-hoc signed; re-signing with the local cert keeps the
        // mic and system-audio permissions across the update.
        // No -v: the self-signed "figg Local Signing" cert is not a "valid"
        // identity to security(1), yet codesign accepts it (bundle.sh checks
        // the same way). With -v the re-sign silently never ran (seen live
        // updating 0.3.0 to 0.4.0) and updates kept the ad-hoc CI signature,
        // which drops the mic and system-audio permissions.
        let identities = try await runner.run("/usr/bin/security", ["find-identity", "-p", "codesigning"])
        try await runner.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])
        if identities.contains("figg Local Signing") {
            try await runner.run("/usr/bin/codesign",
                                 ["--force", "--deep", "--options", "runtime", "--timestamp=none",
                                  "--preserve-metadata=entitlements",
                                  "--sign", "figg Local Signing", staged.path])
        }

        let old = parent.appendingPathComponent(".figg-update-old-\(UUID().uuidString)")
        try fm.moveItem(at: appURL, to: old)
        do {
            try fm.moveItem(at: staged, to: appURL)
        } catch {
            try? fm.moveItem(at: old, to: appURL)  // roll back
            throw error
        }
        try? fm.removeItem(at: old)
    }
}
