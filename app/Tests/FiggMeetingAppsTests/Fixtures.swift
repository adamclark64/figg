@testable import FiggMeetingApps
import Foundation

/// Loads a captured (or hand-written) meeting app tree from `Fixtures/`.
enum Fixture {
    static func capture(_ name: String) throws -> MeetingAppCapture {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try MeetingAppCapture.decode(Data(contentsOf: url))
    }
}
