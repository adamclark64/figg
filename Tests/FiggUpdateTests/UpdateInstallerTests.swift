import CryptoKit
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
    /// Builds a temp "installed app", a "downloaded dmg" signed with a
    /// throwaway release key, and a FakeRunner whose hdiutil attach hook
    /// plants Figg.app (at `mountedVersion`) at the requested mountpoint.
    func makeFixture(signingIdentities: String, mountedVersion: String? = "0.4.0") throws -> Fixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("figg-installer-test-\(UUID().uuidString)")
        let app = root.appendingPathComponent("Applications/Figg.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try "old".write(to: app.appendingPathComponent("Contents/marker.txt"), atomically: true, encoding: .utf8)
        let dmg = root.appendingPathComponent("figg-0.4.0.dmg")
        let bytes = Data("the dmg the release job built".utf8)
        try bytes.write(to: dmg)

        let key = Curve25519.Signing.PrivateKey()
        let release = ReleaseInfo(
            version: "0.4.0", dmgURL: URL(string: "https://store.example.com/releases/figg-0.4.0.dmg")!,
            dmgSize: bytes.count, signature: try key.signature(for: bytes).base64EncodedString())

        let runner = FakeRunner()
        runner.hooks["hdiutil"] = { args in
            if args.first == "attach", let i = args.firstIndex(of: "-mountpoint") {
                let mounted = URL(fileURLWithPath: args[i + 1]).appendingPathComponent("Figg.app/Contents")
                try FileManager.default.createDirectory(at: mounted, withIntermediateDirectories: true)
                try "new".write(to: mounted.appendingPathComponent("marker.txt"), atomically: true, encoding: .utf8)
                if let mountedVersion {
                    let info = try PropertyListSerialization.data(
                        fromPropertyList: ["CFBundleShortVersionString": mountedVersion], format: .xml, options: 0)
                    try info.write(to: mounted.appendingPathComponent("Info.plist"))
                }
            }
            return ""
        }
        runner.hooks["security"] = { _ in signingIdentities }
        let verifier = UpdateVerifier(publicKeys: [key.publicKey.rawRepresentation.base64EncodedString()])
        return Fixture(runner: runner, installer: UpdateInstaller(runner: runner, verifier: verifier),
                       release: release, dmg: dmg, app: app)
    }

    struct Fixture {
        let runner: FakeRunner
        let installer: UpdateInstaller
        var release: ReleaseInfo
        let dmg: URL
        let app: URL

        /// The same download, offered with a different signature.
        func signed(_ signature: String?) -> Fixture {
            var copy = self
            copy.release.signature = signature
            return copy
        }

        func install() async throws {
            try await installer.install(release, dmg: dmg, over: app)
        }

        func marker() throws -> String {
            try String(contentsOf: app.appendingPathComponent("Contents/marker.txt"), encoding: .utf8)
        }
    }

    @Test func installsAndResignsWhenLocalCertExists() async throws {
        let fixture = try makeFixture(
            signingIdentities: #"1) ABC123 "figg Local Signing""#)
        try await fixture.install()

        #expect(try fixture.marker() == "new")
        // Attach, then quarantine strip and re-sign on the staged copy, then detach.
        #expect(fixture.runner.tools() == ["hdiutil", "security", "xattr", "codesign", "hdiutil"])
        let codesign = fixture.runner.calls.first { ($0.tool as NSString).lastPathComponent == "codesign" }!
        #expect(codesign.args.contains("figg Local Signing"))
        #expect(codesign.args.contains("--preserve-metadata=entitlements"))
    }

    @Test func skipsResignWithoutLocalCert() async throws {
        let fixture = try makeFixture(signingIdentities: "0 valid identities found")
        try await fixture.install()
        #expect(!fixture.runner.tools().contains("codesign"))
        #expect(try fixture.marker() == "new")
    }

    @Test func emptyDMGLeavesAppUntouchedAndDetaches() async throws {
        let fixture = try makeFixture(signingIdentities: "")
        fixture.runner.hooks["hdiutil"] = { _ in "" }  // attach "succeeds" but plants nothing
        await #expect(throws: InstallError.appMissingFromDMG) {
            try await fixture.install()
        }
        #expect(try fixture.marker() == "old")
        #expect(fixture.runner.tools().last == "hdiutil")  // detach still ran
    }

    @Test func throwAfterStagingCleansUpAndKeepsOldApp() async throws {
        let fixture = try makeFixture(
            signingIdentities: #"1) ABC123 "figg Local Signing""#)
        let failure = InstallError.command(tool: "codesign", status: 1, stderr: "boom")
        fixture.runner.hooks["codesign"] = { _ in throw failure }
        await #expect(throws: failure) {
            try await fixture.install()
        }
        #expect(try fixture.marker() == "old")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: fixture.app.deletingLastPathComponent().path)
            .filter { $0.hasPrefix(".figg-update") }
        #expect(leftovers.isEmpty)
        #expect(fixture.runner.tools().last == "hdiutil")  // detach ran on the failure path
    }

    @Test func failedFinalMoveRestoresOldApp() async throws {
        let fixture = try makeFixture(signingIdentities: "")
        // Removing the staged copy after staging makes the final move fail,
        // which exercises the rollback that puts the old app back.
        fixture.runner.hooks["xattr"] = { args in
            try FileManager.default.removeItem(atPath: args[args.count - 1])
            return ""
        }
        await #expect(throws: (any Error).self) {
            try await fixture.install()
        }
        #expect(try fixture.marker() == "old")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: fixture.app.deletingLastPathComponent().path)
            .filter { $0.hasPrefix(".figg-update") }
        #expect(leftovers.isEmpty)
    }

    // MARK: Release signature

    @Test func aTamperedDownloadIsRefusedBeforeAnythingIsMounted() async throws {
        let fixture = try makeFixture(signingIdentities: "")
        try Data("something else entirely".utf8).write(to: fixture.dmg)
        await #expect(throws: UpdateError.badSignature) { try await fixture.install() }
        // Not attached, not staged, not swapped.
        #expect(fixture.runner.calls.isEmpty)
        #expect(try fixture.marker() == "old")
    }

    @Test func aDownloadWithNoSignatureIsRefused() async throws {
        let fixture = try makeFixture(signingIdentities: "").signed(nil)
        await #expect(throws: UpdateError.unsignedUpdate) { try await fixture.install() }
        #expect(fixture.runner.calls.isEmpty)
        #expect(try fixture.marker() == "old")
    }

    @Test func aMalformedSignatureIsRefused() async throws {
        let fixture = try makeFixture(signingIdentities: "").signed("AAAA")
        await #expect(throws: UpdateError.badSignature) { try await fixture.install() }
        #expect(fixture.runner.calls.isEmpty)
        #expect(try fixture.marker() == "old")
    }

    @Test func aDownloadSignedWithTheWrongKeyIsRefused() async throws {
        let signedByUs = try makeFixture(signingIdentities: "")
        let stranger = Curve25519.Signing.PrivateKey()
        let fixture = signedByUs.signed(
            try stranger.signature(for: Data(contentsOf: signedByUs.dmg)).base64EncodedString())
        await #expect(throws: UpdateError.badSignature) { try await fixture.install() }
        #expect(fixture.runner.calls.isEmpty)
        #expect(try fixture.marker() == "old")
    }

    @Test func theDefaultInstallerTrustsOnlyTheShippedReleaseKeys() async throws {
        // Same fixture, but the installer the app really builds: the
        // throwaway key is not one of figg's, so it must refuse.
        let fixture = try makeFixture(signingIdentities: "")
        let installer = UpdateInstaller(runner: fixture.runner)
        await #expect(throws: UpdateError.badSignature) {
            try await installer.install(fixture.release, dmg: fixture.dmg, over: fixture.app)
        }
        #expect(fixture.runner.calls.isEmpty)
    }

    @Test func anOlderSignedReleaseOfferedAsNewIsRefused() async throws {
        // A genuine, correctly signed dmg of 0.3.0, replayed under 0.4.0's name.
        let fixture = try makeFixture(signingIdentities: "", mountedVersion: "0.3.0")
        await #expect(throws: InstallError.wrongVersion(expected: "0.4.0", found: "0.3.0")) {
            try await fixture.install()
        }
        #expect(try fixture.marker() == "old")
        #expect(fixture.runner.tools() == ["hdiutil", "hdiutil"])  // attached, then detached
    }

    @Test func aDmgWhoseAppHasNoVersionIsRefused() async throws {
        let fixture = try makeFixture(signingIdentities: "", mountedVersion: nil)
        await #expect(throws: InstallError.wrongVersion(expected: "0.4.0", found: nil)) {
            try await fixture.install()
        }
        #expect(try fixture.marker() == "old")
    }
}
