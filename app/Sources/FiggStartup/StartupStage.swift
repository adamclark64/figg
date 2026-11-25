import Foundation

/// How far a launch got, as a fixed label. These labels are the only text
/// the stage log ever writes and the only text a bug report carries about
/// startup, so a report can point at a step without sending logs or
/// anything the user typed. Cases are declared in launch order.
public enum StartupStage: String, CaseIterable, Sendable {
    case launched
    case storeOpened = "store-opened"
    case meetingsLoaded = "meetings-loaded"
    case windowDrawn = "window-drawn"
    case permissionsRead = "permissions-read"
    case servicesStarted = "services-started"
    case ready
}
