import Foundation
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

    /// A prompt figg already showed that still reads as never asked is a
    /// stale entry macOS skips the prompt for, so the row offers Fix.
    @Test func askedButStillNotAskedOffersFix() {
        #expect(PermissionStep.next(for: .notAsked, fixedThisLaunch: false, askedBefore: true) == .fix)
        #expect(PermissionStep.next(for: .notAsked, fixedThisLaunch: true, askedBefore: true) == .openSettings)
        #expect(PermissionStep.next(for: .granted, fixedThisLaunch: false, askedBefore: true) == .none)
    }
}

struct AskedPermissionsTests {
    @Test func remembersAskedPermissionsAcrossLoads() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AskedPermissions(in: dir)
        #expect(store.load().isEmpty)
        store.record(.screenRecording)
        store.record(.calendar)
        store.record(.screenRecording)
        #expect(AskedPermissions(in: dir).load() == [.screenRecording, .calendar])
    }
}

struct PermissionResetTests {
    @Test func resetsOneServiceForFiggOnly() {
        let reset = PermissionReset(.systemAudio, bundleID: "dev.adamclark.figg")
        #expect(reset.executable == "/usr/bin/tccutil")
        #expect(reset.arguments == ["reset", "AudioCapture", "dev.adamclark.figg"])
    }

    @Test func serviceNames() {
        #expect(Permission.allCases.map(\.tccService) == ["Microphone", "AudioCapture", "Accessibility", "Calendar", "ScreenCapture"])
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

    /// Calendars is optional too.
    @Test func calendarAloneStaysQuiet() {
        var statuses = allGranted
        statuses[.calendar] = .denied
        #expect(!SignerCheck.shouldOpenPermissions(current: "new", stored: "old", statuses: statuses))
    }

    @Test func readsThisProcessRequirement() {
        #expect(SignerCheck.currentRequirement()?.isEmpty == false)
    }
}
