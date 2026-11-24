import Foundation
import Testing
@testable import FiggStartup

struct LaunchStepsTests {
    enum Fault: CaseIterable { case hangs, throwsError }

    private func tempLog() -> (StartupLog, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let log = StartupLog(folder: dir)
        log.begin()
        log.reached(.windowDrawn)
        return (log, dir)
    }

    /// Fakes for every step that record their name, with `faulty` (if any)
    /// hanging or throwing instead. The watcher fake also records the stage
    /// it sees, to show when `permissions-read` lands.
    private func steps(ran: Recorder, log: StartupLog, faulty: LaunchSteps.Step? = nil, fault: Fault = .hangs) -> LaunchSteps {
        func action(_ step: LaunchSteps.Step) -> LaunchSteps.Action {
            {
                if step == faulty {
                    switch fault {
                    case .hangs: try await hang()
                    case .throwsError: throw FakeStartupError()
                    }
                }
                if step == .watcher { ran.add("stage \(log.current?.stage.rawValue ?? "none")") }
                ran.add(step.rawValue)
            }
        }
        return LaunchSteps(
            keychain: action(.keychain), permissions: action(.permissions), watcher: action(.watcher),
            widget: action(.widget), calendar: action(.calendar), model: action(.model),
            recovery: action(.recovery), updates: action(.updates), timeout: 0.25
        )
    }

    @Test func allStepsSucceedingGiveNoBannerAndReachReady() async {
        let (log, dir) = tempLog()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ran = Recorder()
        let banners = Recorder()
        await steps(ran: ran, log: log).run(log: log) { banners.add($0) }
        #expect(banners.all.isEmpty)
        #expect(ran.all == [
            "keychain", "permissions", "stage permissions-read", "watcher",
            "widget", "calendar", "model", "recovery", "updates",
        ])
        #expect(log.current == StartupRecord(stage: .ready))
    }

    @Test(arguments: LaunchSteps.Step.allCases, Fault.allCases)
    func faultyStepGivesItsBannerAndLaterStepsRun(step: LaunchSteps.Step, fault: Fault) async {
        let (log, dir) = tempLog()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ran = Recorder()
        let banners = Recorder()
        await steps(ran: ran, log: log, faulty: step, fault: fault).run(log: log) { banners.add($0) }

        #expect(banners.all == [
            "figg could not finish starting: \(step.label) did not respond. Some features may not work until you reopen figg.",
        ])
        let expected = LaunchSteps.Step.allCases.filter { $0 != step }.map(\.rawValue)
        #expect(ran.all.filter { !$0.hasPrefix("stage ") } == expected)
        #expect(log.current?.stage == .ready)
    }

    /// A permission check that does not finish leaves the stage at
    /// `window-drawn` while the later steps run.
    @Test(arguments: Fault.allCases)
    func failedPermissionCheckDoesNotRecordPermissionsRead(fault: Fault) async {
        let (log, dir) = tempLog()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ran = Recorder()
        await steps(ran: ran, log: log, faulty: .permissions, fault: fault).run(log: log) { _ in }
        #expect(ran.all.contains("stage window-drawn"))
        #expect(!ran.all.contains("stage permissions-read"))
    }

    @Test func bannerTextNamesTheStep() {
        #expect(LaunchSteps.bannerText(for: .keychain)
            == "figg could not finish starting: the Keychain did not respond. Some features may not work until you reopen figg.")
        #expect(Set(LaunchSteps.Step.allCases.map(\.label)).count == LaunchSteps.Step.allCases.count)
    }

    @Test func stepOrderIsFixed() {
        #expect(LaunchSteps.Step.allCases.map(\.rawValue) == [
            "keychain", "permissions", "watcher", "widget", "calendar", "model", "recovery", "updates",
        ])
    }
}
