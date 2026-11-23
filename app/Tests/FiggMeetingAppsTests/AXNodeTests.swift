@testable import FiggMeetingApps
import Foundation
import Testing

@Suite struct AXNodeTests {
    let tree = AXNode(role: "AXWindow", title: "Call", children: [
        AXNode(role: "AXGroup", description: "Participants", children: [
            AXNode(role: "AXButton", description: "Mute Bill"),
        ]),
        AXNode(role: "AXButton", title: "Leave"),
    ])

    @Test func roundTripsAndLeavesOutEmptyKeys() throws {
        let capture = MeetingAppCapture(tree: tree, width: 800, height: 600)
        let data = try capture.encoded()
        let back = try MeetingAppCapture.decode(data)
        #expect(back == capture)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("\"children\" : [\n\n]"))
        #expect(!text.contains("subrole"))
    }

    @Test func fixturesMayLeaveOutAnyKey() throws {
        let json = #"{"tree": {"role": "AXWindow", "frame": {"x": 0, "y": 0, "width": 640, "height": 480}}}"#
        let c = try MeetingAppCapture.decode(Data(json.utf8))
        #expect(c.tree.children.isEmpty)
        #expect(c.width == 640 && c.height == 480)
        #expect(c.otherWindows.isEmpty)
    }

    @Test func longValuesAreCut() throws {
        let long = String(repeating: "a", count: 500)
        #expect(AXNode(value: long).value?.count == AXNode.maxText)
        let decoded = try JSONDecoder().decode(AXNode.self, from: Data(#"{"value": "\#(long)"}"#.utf8))
        #expect(decoded.value?.count == AXNode.maxText)
    }

    @Test func searchesDepthFirst() {
        #expect(tree.all().map { $0.label ?? $0.role ?? "" } == ["Call", "Participants", "Mute Bill", "Leave"])
        #expect(tree.all { $0.role == "AXButton" }.count == 2)
        #expect(tree.first { $0.role == "AXButton" }?.label == "Mute Bill")
        #expect(tree.first { $0.role == "AXSlider" } == nil)
    }

    @Test func walkGivesAncestorsAndCanSkip() {
        var seen: [String: [String]] = [:]
        tree.walk { node, path in
            seen[node.label ?? "?"] = path.compactMap(\.label)
            return node.label != "Participants"
        }
        #expect(seen["Leave"] == ["Call"])
        #expect(seen["Participants"] == ["Call"])
        #expect(seen["Mute Bill"] == nil)
    }

    @Test func fixtureLoads() throws {
        let c = try Fixture.capture("zoom-speaker-view")
        #expect(c.tree.identifier == ZoomProfile.meetingWindowID)
        #expect(c.otherWindows.count == 1)
    }
}
