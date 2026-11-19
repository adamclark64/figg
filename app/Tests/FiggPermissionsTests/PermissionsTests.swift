import Testing
@testable import FiggPermissions

struct PermissionStepTests {
    @Test func grantedNeedsNothing() {
        #expect(PermissionStep.next(for: .granted, fixedThisLaunch: false) == .none)
        #expect(PermissionStep.next(for: .granted, fixedThisLaunch: true) == .none)
    }

    @Test func neverAskedShowsThePrompt() {
        #expect(PermissionStep.next(for: .notAsked, fixedThisLaunch: false) == .ask)
    }

    /// A refused or stale entry is cleared and asked again, once.
    @Test func deniedIsFixedOnceThenSentToSettings() {
        #expect(PermissionStep.next(for: .denied, fixedThisLaunch: false) == .fix)
        #expect(PermissionStep.next(for: .denied, fixedThisLaunch: true) == .openSettings)
        #expect(PermissionStep.next(for: .notAsked, fixedThisLaunch: true) == .openSettings)
    }
}

struct PermissionResetTests {
    @Test func resetsOneServiceForFiggOnly() {
        let reset = PermissionReset(.systemAudio, bundleID: "dev.adamclark.figg")
        #expect(reset.executable == "/usr/bin/tccutil")
        #expect(reset.arguments == ["reset", "AudioCapture", "dev.adamclark.figg"])
    }

    @Test func serviceNames() {
        #expect(Permission.allCases.map(\.tccService) == ["Microphone", "AudioCapture", "Accessibility", "ScreenCapture"])
    }
}

struct SignerCheckTests {
    let allGranted: [Permission: PermissionStatus] = Dictionary(uniqueKeysWithValues: Permission.allCases.map { ($0, .granted) })

    @Test func newSignerWithSomethingMissingOpensPermissions() {
        var statuses = allGranted
        statuses[.accessibility] = .denied
        #expect(SignerCheck.shouldOpenPermissions(current: "new", stored: "old", statuses: statuses))
        #expect(SignerCheck.shouldOpenPermissions(current: "new", stored: nil, statuses: statuses))
    }

    @Test func sameSignerOrAllGrantedStaysQuiet() {
        var statuses = allGranted
        statuses[.systemAudio] = .denied
        #expect(!SignerCheck.shouldOpenPermissions(current: "same", stored: "same", statuses: statuses))
        #expect(!SignerCheck.shouldOpenPermissions(current: "new", stored: "old", statuses: allGranted))
        #expect(!SignerCheck.shouldOpenPermissions(current: nil, stored: "old", statuses: statuses))
    }

    /// Screen Recording only powers screenshots, so it never opens the screen.
    @Test func screenRecordingAloneStaysQuiet() {
        var statuses = allGranted
        statuses[.screenRecording] = .denied
        #expect(!SignerCheck.shouldOpenPermissions(current: "new", stored: "old", statuses: statuses))
    }

    @Test func readsThisProcessRequirement() {
        #expect(SignerCheck.currentRequirement()?.isEmpty == false)
    }
}
