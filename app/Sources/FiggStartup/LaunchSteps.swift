import Foundation

/// The steps figg runs after the main window has drawn, as data.
///
/// The app passes the real work as closures and tests pass fakes, so the
/// order, the stages recorded and the banner for each failure are tested
/// here rather than in the app target. Every closure that calls the system
/// (TCC, Keychain, EventKit) should do that work off the main actor: a
/// timeout only helps a step that suspends.
public struct LaunchSteps: Sendable {
    public typealias Action = @Sendable () async throws -> Void

    /// The launch steps, in the order they run.
    public enum Step: String, CaseIterable, Sendable {
        case keychain, permissions, watcher, widget, calendar, model, recovery, updates

        /// The name the banner shows for this step.
        public var label: String {
            switch self {
            case .keychain: return "the Keychain"
            case .permissions: return "the permission check"
            case .watcher: return "meeting detection"
            case .widget: return "the recording widget"
            case .calendar: return "the calendar"
            case .model: return "the transcription model"
            case .recovery: return "crash recovery"
            case .updates: return "the update check"
            }
        }
    }

    /// The warning shown when `step` throws or times out.
    public static func bannerText(for step: Step) -> String {
        "figg could not finish starting: \(step.label) did not respond. Some features may not work until you reopen figg."
    }

    private let actions: [Step: Action]
    public let timeout: TimeInterval

    public init(
        keychain: @escaping Action,
        permissions: @escaping Action,
        watcher: @escaping Action,
        widget: @escaping Action,
        calendar: @escaping Action,
        model: @escaping Action,
        recovery: @escaping Action,
        updates: @escaping Action,
        timeout: TimeInterval = 10
    ) {
        actions = [
            .keychain: keychain, .permissions: permissions, .watcher: watcher, .widget: widget,
            .calendar: calendar, .model: model, .recovery: recovery, .updates: updates,
        ]
        self.timeout = timeout
    }

    /// Runs every step in order. Records `permissions-read` into `log` when
    /// the permission step finishes in time (a hung check leaves the stage
    /// at `window-drawn`, which is what a report should show), then
    /// `services-started` and `ready` once every step has run or been given
    /// up on. Each failed step gives one banner through `onBanner`.
    public func run(log: StartupLog, onBanner: @Sendable (String) async -> Void) async {
        let steps = Step.allCases.map { step -> StartupStep in
            let action: Action = actions[step] ?? {}
            return StartupStep(step.rawValue, run: action)
        }
        await StartupSequence(steps: steps, defaultTimeout: timeout).run(
            onSuccess: { name in
                if name == Step.permissions.rawValue { log.reached(.permissionsRead) }
            },
            onFailure: { name, _ in
                guard let step = Step(rawValue: name) else { return }
                await onBanner(Self.bannerText(for: step))
            }
        )
        log.reached(.servicesStarted)
        log.reached(.ready)
    }
}
