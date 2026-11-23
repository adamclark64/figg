import Foundation

/// The Zoom desktop app. The parsing rules are in `ZoomReading`; this maps
/// a captured Zoom meeting window onto them.
///
/// The walk is kept as it was before profiles existed: it does not go inside
/// video tiles or buttons (Zoom's toolbar buttons nest inside themselves),
/// stops at depth 8 and 4000 nodes, and asks for positions only on tiles
/// (their size picks Speaker view's main tile) and on mute buttons (their
/// height in the window tells the toolbar from the Participants panel).
public struct ZoomProfile: MeetingAppProfile {
    public static let bundleID = "us.zoom.xos"
    /// The meeting window's AXIdentifier (stable across title changes like "Zoom Meeting  40-minutes").
    public static let meetingWindowID = "zm.meeting.window.main"

    public let id = "zoom"
    public let displayName = "Zoom"
    public let bundleIDs: Set<String> = [ZoomProfile.bundleID]

    public init() {}

    public var policy: CapturePolicy {
        CapturePolicy(
            maxNodes: 4000, maxDepth: 8, otherWindowsDepth: 1,
            descend: { !Self.isTile($0) && !Self.isButton($0) },
            wantsFrame: { Self.isTile($0) || (Self.isButton($0) && $0.label.map(ZoomReading.isMuteLabel) == true) })
    }

    public func target(in windows: [AXWindowSummary]) -> AXTarget? {
        windows.first { $0.identifier == Self.meetingWindowID }.map { .window($0.index) }
    }

    public func snapshot(from capture: MeetingAppCapture) -> MeetingAppSnapshot? {
        var tiles: [ZoomReading.Tile] = []
        var buttons: [ZoomReading.Button] = []
        capture.tree.walk { node, path in
            if Self.isTile(node) {
                if let label = node.description {
                    tiles.append(.init(label: label, width: node.frame?.width ?? 0, height: node.frame?.height ?? 0))
                }
                return false
            }
            if Self.isButton(node) {
                if let label = node.label, ZoomReading.isMuteLabel(label) {
                    let inPanel = path.contains { [$0.description, $0.title].contains { $0?.hasPrefix("Participants") == true } }
                    buttons.append(.init(label: label, y: node.frame?.y ?? 0, inParticipantsPanel: inPanel))
                }
                return false
            }
            return true
        }
        return ZoomReading.snapshot(tiles: tiles, windowWidth: capture.width, windowHeight: capture.height,
                                    selfName: selfName(capture.otherWindows), buttons: buttons)
    }

    /// Your Zoom name from the main window's account button, if it is shown.
    func selfName(_ windows: [AXNode]) -> String? {
        for w in windows {
            for k in w.children {
                if let d = k.description, let name = ZoomReading.selfName(fromAccountButton: d) { return name }
            }
        }
        return nil
    }

    static func isTile(_ n: AXNode) -> Bool { n.roleDescription?.hasPrefix("Video") == true }
    static func isButton(_ n: AXNode) -> Bool { n.role == "AXButton" }
}
