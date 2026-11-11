import CoreGraphics
import FiggWidget
import Testing

@Suite struct RecordingWidgetRulesTests {
    @Test func showsOnlyWhileRecordingInTheBackground() {
        func show(enabled: Bool = true, recording: String? = "m1", active: Bool = false, hiddenFor: String? = nil) -> Bool {
            RecordingWidgetRules.shouldShow(enabled: enabled, recordingId: recording, appIsActive: active, hiddenFor: hiddenFor)
        }
        #expect(show())
        #expect(!show(active: true))
        #expect(!show(recording: nil))
        #expect(!show(enabled: false))
    }

    @Test func hidingAppliesToOneMeetingOnly() {
        #expect(!RecordingWidgetRules.shouldShow(enabled: true, recordingId: "m1", appIsActive: false, hiddenFor: "m1"))
        #expect(RecordingWidgetRules.shouldShow(enabled: true, recordingId: "m2", appIsActive: false, hiddenFor: "m1"))
    }

    @Test func compactLevelsKeepTheLoudestOfEachGroup() {
        let bars: [Float] = [0.1, 0.9, 0.2, 0.3, 0, 0.5]
        #expect(RecordingWidgetRules.compactLevels(bars, count: 3, group: 2) == [0.9, 0.3, 0.5])
        // Only the newest bars are used.
        #expect(RecordingWidgetRules.compactLevels(bars, count: 2, group: 1) == [0, 0.5])
    }

    @Test func compactLevelsPadShortHistoryWithSilence() {
        #expect(RecordingWidgetRules.compactLevels([0.4, 0.7, 0.2], count: 4, group: 2) == [0, 0, 0.4, 0.7])
        #expect(RecordingWidgetRules.compactLevels([], count: 3, group: 2) == [0, 0, 0])
        #expect(RecordingWidgetRules.compactLevels([0.4], count: 0, group: 2).isEmpty)
    }

    @Test func silenceStaysFlat() {
        let silent = [Float](repeating: 0, count: 60)
        #expect(RecordingWidgetRules.compactLevels(silent, count: 9, group: 2).allSatisfy { $0 == 0 })
    }
}

@Suite struct WidgetPlacementTests {
    let size = CGSize(width: 60, height: 140)
    let screen = CGRect(x: 0, y: 40, width: 1440, height: 835)

    @Test func defaultIsTheRightEdgeWithThePillCentred() {
        let o = WidgetPlacement.defaultOrigin(size: size, in: screen, centreFromTop: 40)
        #expect(o.x == 1380)
        // The point 40 below the panel's top edge sits at mid height.
        #expect(o.y + size.height - 40 == screen.midY)
    }

    @Test func noSavedPositionUsesTheDefaultOnTheMainScreen() {
        let second = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let o = WidgetPlacement.origin(saved: nil, size: size, screens: [screen, second], main: second, centreFromTop: 40)
        #expect(o == WidgetPlacement.defaultOrigin(size: size, in: second, centreFromTop: 40))
    }

    @Test func savedPositionOnScreenIsKept() {
        let saved = CGPoint(x: 300, y: 500)
        #expect(WidgetPlacement.origin(saved: saved, size: size, screens: [screen], main: screen, centreFromTop: 40) == saved)
    }

    @Test func savedPositionIsClampedBackOnScreen() {
        // Dragged against the right edge of a wider display that has since shrunk.
        let o = WidgetPlacement.origin(saved: CGPoint(x: 1420, y: 850), size: size, screens: [screen], main: screen, centreFromTop: 40)
        #expect(o == CGPoint(x: 1380, y: 735))
        // Below the Dock line.
        let low = WidgetPlacement.origin(saved: CGPoint(x: 10, y: -20), size: size, screens: [screen], main: screen, centreFromTop: 40)
        #expect(low == CGPoint(x: 10, y: 40))
    }

    @Test func savedPositionStaysOnTheScreenItOverlapsMost() {
        let second = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        // Mostly on the second display, straddling the join.
        let o = WidgetPlacement.origin(saved: CGPoint(x: 1425, y: 300), size: size, screens: [screen, second], main: screen, centreFromTop: 40)
        #expect(o == CGPoint(x: 1440, y: 300))
    }

    @Test func positionOnAnUnpluggedDisplayFallsBackToTheDefault() {
        let o = WidgetPlacement.origin(saved: CGPoint(x: 3000, y: 300), size: size, screens: [screen], main: screen, centreFromTop: 40)
        #expect(o == WidgetPlacement.defaultOrigin(size: size, in: screen, centreFromTop: 40))
    }

    @Test func aPanelLargerThanTheScreenPinsToItsOrigin() {
        let tiny = CGRect(x: 0, y: 0, width: 40, height: 100)
        #expect(WidgetPlacement.clamp(CGPoint(x: 500, y: 500), size: size, to: tiny) == .zero)
    }
}

@Suite struct ScreenshotCommandTests {
    /// Screenshots go to the clipboard only: interactive, and never a file path.
    @Test func capturesInteractivelyToTheClipboardAndNeverToDisk() {
        #expect(ScreenshotCommand.tool == "/usr/sbin/screencapture")
        #expect(ScreenshotCommand.arguments.contains("-i"))
        #expect(ScreenshotCommand.arguments.contains("-c"))
        #expect(ScreenshotCommand.arguments.allSatisfy { $0.hasPrefix("-") })
    }

    @Test func outcomeFollowsTheClipboard() {
        #expect(ScreenshotCommand.outcome(clipboardBefore: 7, clipboardAfter: 8) == .copied)
        #expect(ScreenshotCommand.outcome(clipboardBefore: 7, clipboardAfter: 7) == .nothingCopied)
    }
}
