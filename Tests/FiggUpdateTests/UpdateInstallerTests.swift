import FiggUpdate
import Foundation
import Testing

/// Records every command; side effects (like creating the mounted app) are
/// injected per-test so the real FileManager work in between is exercised.
final class FakeRunner: CommandRunner, @unchecked Sendable {
    private(set) var calls: [(tool: String, args: [String])] = []
    /// Keyed by tool basename, e.g. "hdiutil". Return value becomes run()'s output.
    var hooks: [String: ([String]) throws -> String] = [:]

    func run(_ tool: String, _ args: [String]) async throws -> String {
        calls.append((tool, args))
        let name = (tool as NSString).lastPathComponent
        return try hooks[name]?(args) ?? ""
    }

    func tools() -> [String] { calls.map { ($0.tool as NSString).lastPathComponent } }
}

@Suite struct UpdateInstallerTests {
    /// Builds a temp "installed app" and wires a FakeRunner whose hdiutil
    /// attach hook plants Figg.app at the requested mountpoint.
    func makeFixture(signingIdentities: String) throws -> (FakeRunner, UpdateInstaller, dmg: URL, app: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("figg-installer-test-\(UUID().uuidString)")
        let app = root.appendingPathComponent("Applications/Figg.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try "old".write(to: app.appendingPathComponent("Contents/marker.txt"), atomically: true, encoding: .utf8)
        let dmg = root.appendingPathComponent("figg-0.4.0.dmg")
        try Data().write(to: dmg)

        let runner = FakeRunner()
        runner.hooks["hdiutil"] = { args in
            if args.first == "attach", let i = args.firstIndex(of: "-mountpoint") {
                let mounted = URL(fileURLWithPath: args[i + 1]).appendingPathComponent("Figg.app/Contents")
                try FileManager.default.createDirectory(at: mounted, withIntermediateDirectories: true)
                try "new".write(to: mounted.appendingPathComponent("marker.txt"), atomically: true, encoding: .utf8)
            }
            return ""
        }
        runner.hooks["security"] = { _ in signingIdentities }
        return (runner, UpdateInstaller(runner: runner), dmg, app)
    }

    @Test func installsAndResignsWhenLocalCertExists() async throws {
        let (runner, installer, dmg, app) = try makeFixture(
            signingIdentities: #"1) ABC123 "figg Local Signing""#)
        try await installer.install(dmg: dmg, over: app)

        let marker = try String(contentsOf: app.appendingPathComponent("Contents/marker.txt"), encoding: .utf8)
        #expect(marker == "new")
        // Attach, then quarantine strip and re-sign on the staged copy, then detach.
        #expect(runner.tools() == ["hdiutil", "security", "xattr", "codesign", "hdiutil"])
        let codesign = runner.calls.first { ($0.tool as NSString).lastPathComponent == "codesign" }!
        #expect(codesign.args.contains("figg Local Signing"))
        #expect(codesign.args.contains("--preserve-metadata=entitlements"))
    }

    @Test func skipsResignWithoutLocalCert() async throws {
        let (runner, installer, dmg, app) = try makeFixture(signingIdentities: "0 valid identities found")
        try await installer.install(dmg: dmg, over: app)
        #expect(!runner.tools().contains("codesign"))
        let marker = try String(contentsOf: app.appendingPathComponent("Contents/marker.txt"), encoding: .utf8)
        #expect(marker == "new")
    }

    @Test func emptyDMGLeavesAppUntouchedAndDetaches() async throws {
        let (runner, installer, dmg, app) = try makeFixture(signingIdentities: "")
        runner.hooks["hdiutil"] = { _ in "" }  // attach "succeeds" but plants nothing
        await #expect(throws: InstallError.appMissingFromDMG) {
            try await installer.install(dmg: dmg, over: app)
        }
        let marker = try String(contentsOf: app.appendingPathComponent("Contents/marker.txt"), encoding: .utf8)
        #expect(marker == "old")
        #expect(runner.tools().last == "hdiutil")  // detach still ran
    }

    @Test func throwAfterStagingCleansUpAndKeepsOldApp() async throws {
        let (runner, installer, dmg, app) = try makeFixture(
            signingIdentities: #"1) ABC123 "figg Local Signing""#)
        let failure = InstallError.command(tool: "codesign", status: 1, stderr: "boom")
        runner.hooks["codesign"] = { _ in throw failure }
        await #expect(throws: failure) {
            try await installer.install(dmg: dmg, over: app)
        }
        let marker = try String(contentsOf: app.appendingPathComponent("Contents/marker.txt"), encoding: .utf8)
        #expect(marker == "old")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: app.deletingLastPathComponent().path)
            .filter { $0.hasPrefix(".figg-update") }
        #expect(leftovers.isEmpty)
        #expect(runner.tools().last == "hdiutil")  // detach ran on the failure path
    }

    @Test func failedFinalMoveRestoresOldApp() async throws {
        let (runner, installer, dmg, app) = try makeFixture(signingIdentities: "")
        // Removing the staged copy after staging makes the final move fail,
        // which exercises the rollback that puts the old app back.
        runner.hooks["xattr"] = { args in
            try FileManager.default.removeItem(atPath: args[args.count - 1])
            return ""
        }
        await #expect(throws: (any Error).self) {
            try await installer.install(dmg: dmg, over: app)
        }
        let marker = try String(contentsOf: app.appendingPathComponent("Contents/marker.txt"), encoding: .utf8)
        #expect(marker == "old")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: app.deletingLastPathComponent().path)
            .filter { $0.hasPrefix(".figg-update") }
        #expect(leftovers.isEmpty)
    }
}
