import FiggFeedback
import Foundation
import Testing

/// The app puts `StartupLog.shared.summary` in the payload's `extra` under
/// `startup`; this checks that line lands in the issue's Context section.
@Suite struct StartupContextTests {
    @Test func startupExtraRendersUnderContext() {
        let payload = BugReportPayload(
            type: .bug,
            description: "The main window stayed blank",
            appVersion: "0.9.0 (90)",
            extra: [
                "macOS": "macOS 26.1",
                "startup": "this launch: ready; last launch: stalled at window-drawn for 12 s",
            ])
        let body = GitHubIssueURL.fullBody(for: payload)
        let line = "- **startup:** this launch: ready; last launch: stalled at window-drawn for 12 s"
        let context = body.range(of: "### Context")
        let startup = body.range(of: line)
        #expect(context != nil)
        #expect(startup != nil)
        if let context, let startup {
            #expect(context.upperBound <= startup.lowerBound)
        }
    }
}
