import FiggDictation
import Foundation
import Testing

@Suite struct HoldToTalkTests {
    let t0 = Date(timeIntervalSince1970: 1000)

    @Test func holdThenReleaseStartsAndStops() {
        var h = HoldToTalk(key: .fn)
        #expect(h.flagsChanged(keyCode: 63, keyIsDown: true, otherModifiers: false, now: t0) == .start)
        #expect(h.isActive)
        #expect(h.flagsChanged(keyCode: 63, keyIsDown: false, otherModifiers: false, now: t0 + 2) == .stop)
        #expect(!h.isActive)
    }

    @Test func aTapLocksRecordingOnUntilTheNextPress() {
        var h = HoldToTalk(key: .fn)
        #expect(h.flagsChanged(keyCode: 63, keyIsDown: true, otherModifiers: false, now: t0) == .start)
        #expect(h.flagsChanged(keyCode: 63, keyIsDown: false, otherModifiers: false, now: t0 + 0.1) == .handsFree)
        #expect(h.isHandsFree)
        // Typing other keys while hands-free does not stop it.
        #expect(h.keyDown(keyCode: 0) == nil)
        // The second press stops on release, so nothing is typed while the key is held.
        #expect(h.flagsChanged(keyCode: 63, keyIsDown: true, otherModifiers: false, now: t0 + 5) == nil)
        #expect(h.flagsChanged(keyCode: 63, keyIsDown: false, otherModifiers: false, now: t0 + 5.1) == .stop)
        #expect(!h.isActive)
        #expect(h.flagsChanged(keyCode: 63, keyIsDown: true, otherModifiers: false, now: t0 + 6) == .start)
    }

    @Test func anOrdinaryTapCountsAsATap() {
        var h = HoldToTalk(key: .rightOption)
        _ = h.flagsChanged(keyCode: 61, keyIsDown: true, otherModifiers: false, now: t0)
        #expect(h.flagsChanged(keyCode: 61, keyIsDown: false, otherModifiers: false, now: t0 + 0.4) == .handsFree)
    }

    @Test func escapeCancelsEitherWay() {
        var h = HoldToTalk(key: .fn)
        _ = h.flagsChanged(keyCode: 63, keyIsDown: true, otherModifiers: false, now: t0)
        #expect(h.keyDown(keyCode: HoldToTalk.escapeKeyCode) == .cancel)
        #expect(h.flagsChanged(keyCode: 63, keyIsDown: false, otherModifiers: false, now: t0 + 2) == nil)

        _ = h.flagsChanged(keyCode: 63, keyIsDown: true, otherModifiers: false, now: t0 + 3)
        _ = h.flagsChanged(keyCode: 63, keyIsDown: false, otherModifiers: false, now: t0 + 3.1)
        #expect(h.keyDown(keyCode: HoldToTalk.escapeKeyCode) == .cancel)
        #expect(!h.isActive)
        #expect(h.keyDown(keyCode: HoldToTalk.escapeKeyCode) == nil)
    }

    @Test func pressingAnotherKeyWhileHoldingMeansAShortcut() {
        var h = HoldToTalk(key: .fn)
        _ = h.flagsChanged(keyCode: 63, keyIsDown: true, otherModifiers: false, now: t0)
        #expect(h.keyDown(keyCode: 123) == .cancel)
        // Releasing afterwards says nothing more.
        #expect(h.flagsChanged(keyCode: 63, keyIsDown: false, otherModifiers: false, now: t0 + 3) == nil)
        // And the next hold works again.
        #expect(h.flagsChanged(keyCode: 63, keyIsDown: true, otherModifiers: false, now: t0 + 4) == .start)
    }

    @Test func addingAModifierCancels() {
        var h = HoldToTalk(key: .rightOption)
        _ = h.flagsChanged(keyCode: 61, keyIsDown: true, otherModifiers: false, now: t0)
        #expect(h.flagsChanged(keyCode: 56, keyIsDown: true, otherModifiers: true, now: t0 + 1) == .cancel)
    }

    @Test func keyWithAModifierAlreadyHeldDoesNotStart() {
        var h = HoldToTalk(key: .fn)
        #expect(h.flagsChanged(keyCode: 63, keyIsDown: true, otherModifiers: true, now: t0) == nil)
        #expect(h.flagsChanged(keyCode: 63, keyIsDown: false, otherModifiers: true, now: t0 + 2) == nil)
    }

    @Test func otherKeysAloneDoNothing() {
        var h = HoldToTalk(key: .fn)
        #expect(h.keyDown(keyCode: 0) == nil)
        #expect(h.keyDown(keyCode: HoldToTalk.escapeKeyCode) == nil)
        #expect(h.flagsChanged(keyCode: 56, keyIsDown: false, otherModifiers: true, now: t0) == nil)
    }

    @Test func unknownSettingFallsBackToFn() {
        #expect(HoldKey(setting: "caps") == .rightOption)
        #expect(HoldKey(setting: "right_option") == .rightOption)
    }
}

@Suite struct InsertionTests {
    @Test func passwordFieldsAreNeverFilled() {
        let f = FocusedField(bundleID: "com.apple.mail", role: "AXTextField", subrole: "AXSecureTextField")
        #expect(InsertionRouter.method(for: f, trusted: true) == .none(.passwordField))
    }

    @Test func withoutPermissionNothingIsInserted() {
        let f = FocusedField(bundleID: "com.apple.Notes", role: "AXTextArea")
        #expect(InsertionRouter.method(for: f, trusted: false) == .none(.noPermission))
    }

    @Test func browsersAndElectronGetKeystrokes() {
        for id in ["com.google.Chrome", "com.tinyspeck.slackmacgap", "com.electron.something", "com.googlecode.iterm2"] {
            #expect(InsertionRouter.method(for: FocusedField(bundleID: id, role: "AXTextArea"), trusted: true) == .keystrokes)
        }
    }

    @Test func nativeFieldsUseAccessibility() {
        let f = FocusedField(bundleID: "com.apple.Notes", role: "AXTextArea")
        #expect(InsertionRouter.method(for: f, trusted: true) == .accessibility)
    }

    @Test func noVisibleElementStillTypes() {
        #expect(InsertionRouter.method(for: FocusedField(bundleID: "com.example.app"), trusted: true) == .keystrokes)
    }

    @Test func anAXWriteThatChangedNothingIsAFailure() {
        #expect(!InsertionRouter.axWriteTookEffect(before: "hi", after: "hi", inserted: "there"))
        #expect(!InsertionRouter.axWriteTookEffect(before: "hi", after: nil, inserted: "there"))
        #expect(InsertionRouter.axWriteTookEffect(before: "hi", after: "hi there", inserted: " there"))
    }

    @Test func chunksNeverSplitACharacter() {
        let text = String(repeating: "a", count: 19) + "👍🏽" + "bc"
        let pieces = KeystrokeChunks.split(text)
        #expect(pieces.joined() == text)
        #expect(pieces.allSatisfy { $0.utf16.count <= 20 })
        #expect(pieces[1].hasPrefix("👍🏽"))
    }

    @Test func textGetsASpaceAfterAWord() {
        #expect(DictationText.prepare(["Hello  world."], precedingCharacter: "x") == " Hello world.")
        #expect(DictationText.prepare(["Hello", "world."], precedingCharacter: " ") == "Hello world.")
        #expect(DictationText.prepare(["Hi"], precedingCharacter: "(") == "Hi")
        #expect(DictationText.prepare(["  "]) == "")
    }
}

@Suite struct DictationCueTests {
    @Test func cancelIsSofterAndVolumeIsClamped() {
        #expect(DictationCue.start.volume(setting: 0.5) == 0.5)
        #expect(DictationCue.cancel.volume(setting: 0.5) < DictationCue.stop.volume(setting: 0.5))
        #expect(DictationCue.start.volume(setting: 3) == 1)
        #expect(DictationCue.start.volume(setting: -1) == 0)
    }

    @Test func everyChoiceHasAFile() {
        #expect(DictationSound.all.count == 10)
        // app/Resources, which scripts/bundle.sh copies into the .app.
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources").path
        for sound in DictationSound.all {
            #expect(FileManager.default.fileExists(atPath: sound.path(resources: resources)), "\(sound.name)")
        }
        for cue in DictationCue.allCases {
            #expect(DictationSound.named(cue.defaultSound) != nil)
        }
    }

    @Test func noneTyposAndCaseInTheSetting() {
        #expect(DictationCue.stop.sound(setting: "none") == nil)
        #expect(DictationCue.stop.sound(setting: "None") == nil)
        #expect(DictationCue.start.sound(setting: "morse")?.name == "Morse")
        // A name this Mac does not have falls back to the cue's default.
        #expect(DictationCue.start.sound(setting: "Tinkk")?.name == "Soft Start")
        #expect(DictationCue.cancel.sound(setting: "Tinkk")?.name == "Soft Stop")
        #expect(DictationCue.stop.sound(setting: "soft stop")?.source == .bundled(file: "SoftStop"))
    }

    @Test func theStartSoundIsSilencedForAsLongAsItCanBeHeard() throws {
        let tink = try #require(DictationSound.named("Tink"))
        let glass = try #require(DictationSound.named("Glass"))
        #expect(tink.isQuick && !glass.isQuick)
        #expect(glass.muteSeconds > tink.muteSeconds)
        #expect(tink.muteSeconds == tink.audibleSeconds + DictationSound.outputLatency)
    }

    @Test func theStartCueIsSilencedButTimingIsKept() {
        let samples = [Float](repeating: 0.5, count: 16_000)
        let out = DictationCue.silencingStart(samples, seconds: 0.25)
        #expect(out.count == samples.count)
        #expect(out[0..<4_000].allSatisfy { $0 == 0 })
        #expect(out[4_000...].allSatisfy { $0 == 0.5 })
    }

    @Test func aShortRecordingIsAllSilencedWithoutCrashing() {
        #expect(DictationCue.silencingStart([0.5, 0.5], seconds: 0.25) == [0, 0])
        #expect(DictationCue.silencingStart([], seconds: 0.25) == [])
        #expect(DictationCue.silencingStart([0.5], seconds: 0) == [0.5])
    }
}

@Suite struct KeyComboTests {
    @Test func theDefaultReadsAndWritesBack() throws {
        let c = try #require(KeyCombo(setting: "ctrl+option+cmd+v"))
        #expect(c == .pasteLastDefault)
        #expect(c.setting == "ctrl+option+cmd+v")
        #expect(c.label == "⌃⌥⌘V")
    }

    @Test func parsingIsLenientAboutNamesCaseAndOrder() {
        #expect(KeyCombo(setting: "Cmd + Opt + Ctrl + V") == .pasteLastDefault)
        #expect(KeyCombo(setting: "command+alt+control+v") == .pasteLastDefault)
        #expect(KeyCombo(setting: "⌃⌥⌘+v") == nil)
        #expect(KeyCombo(setting: "ctrl+shift+f5")?.label == "⌃⇧F5")
        #expect(KeyCombo(setting: "option+space")?.label == "⌥Space")
    }

    @Test func offTyposAndRiskyCombosAreRejected() {
        #expect(KeyCombo(setting: "") == nil)
        #expect(KeyCombo(setting: "none") == nil)
        #expect(KeyCombo(setting: "v") == nil)
        #expect(KeyCombo(setting: "shift+v") == nil)
        #expect(KeyCombo(setting: "cmd+banana") == nil)
        #expect(KeyCombo(setting: "hyper+v") == nil)
    }

    @Test func everyKeyRoundTrips() {
        for code in KeyCombo.keyNames.keys {
            let c = KeyCombo(keyCode: code, modifiers: [.command, .shift])
            #expect(KeyCombo(setting: c.setting) == c, "\(c.setting)")
        }
    }
}

@Suite struct KeyComboClashTests {
    @Test func figgsOwnAndStandardShortcutsAreCaught() throws {
        #expect(try #require(KeyCombo(setting: "ctrl+option+cmd+r")).clash() == "figg's Start/Stop Recording")
        #expect(try #require(KeyCombo(setting: "cmd+v")).clash() == "Paste")
        #expect(try #require(KeyCombo(setting: "shift+option+cmd+v")).clash() == "Paste and Match Style")
        #expect(KeyCombo.pasteLastDefault.clash() == nil)
    }

    @Test func turnedOnMacOSShortcutsAreCaughtAndTurnedOffOnesAreNot() {
        // Shaped like com.apple.symbolichotkeys: ctrl+option+cmd+V (key 9,
        // mask 0x1C0000) on, ctrl+F5 (key 0x60) off.
        let hotKeys: [String: Any] = [
            "500": ["enabled": true, "value": ["parameters": [118, 9, 0x1C0000], "type": "standard"]],
            "501": ["enabled": false, "value": ["parameters": [65535, 0x60, 0x40000], "type": "standard"]],
            "502": ["enabled": true, "value": ["parameters": [65535, 65535, 0], "type": "standard"]],
        ]
        #expect(KeyCombo.pasteLastDefault.clash(systemHotKeys: hotKeys) == "a macOS shortcut")
        #expect(KeyCombo(setting: "ctrl+f5")!.clash(systemHotKeys: hotKeys) == nil)
    }
}

@Suite struct KeyComboStandardListTests {
    @Test func everyListedShortcutParses() {
        // `standard` force-unwraps each entry; reaching it at all proves they parse.
        #expect(KeyCombo(setting: "shift+cmd+4")!.clash() == "a macOS screenshot shortcut")
        #expect(KeyCombo(setting: "ctrl+space")!.clash() == "the input source switcher")
    }
}
