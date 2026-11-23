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

@Suite struct SpokenPunctuationTests {
    func say(_ text: String, after: Character? = nil) -> String {
        DictationText.prepare([text], precedingCharacter: after, spokenPunctuation: true)
    }

    @Test func offByDefaultAndTextWithoutCommandsIsUntouched() {
        #expect(DictationText.prepare(["hello comma world"]) == "hello comma world")
        let plain = "Thanks for the notes.  I read them, and the plan looks good."
        #expect(say(plain) == DictationText.prepare([plain]))
    }

    @Test func marksSitAgainstTheWordBefore() {
        #expect(say("hi Sam comma thanks for the notes period") == "hi Sam, thanks for the notes.")
        #expect(say("can we meet on Tuesday question mark") == "can we meet on Tuesday?")
        #expect(say("great exclamation mark") == "great!")
        #expect(say("great exclamation point") == "great!")
        #expect(say("three things colon tables semicolon snacks") == "three things: tables; snacks")
        #expect(say("that is all full stop") == "that is all.")
        #expect(say("really question mark exclamation mark") == "really?!")
    }

    @Test func theNextWordIsCapitalisedAfterASentenceEnd() {
        #expect(say("it works period now ship it") == "it works. Now ship it")
        #expect(say("ready question mark yes") == "ready? Yes")
        #expect(say("one comma two") == "one, two")
    }

    @Test func theTranscribersOwnPunctuationIsReplaced() {
        // Parakeet hears the pause and writes its own marks around the words.
        #expect(say("Hi Sam, comma, thanks for the notes. Period.") == "Hi Sam, thanks for the notes.")
        #expect(say("Can we meet on Tuesday? Question mark.") == "Can we meet on Tuesday?")
        #expect(say("Hello comma. How are you") == "Hello, how are you")
        #expect(say("Hello comma. I think so") == "Hello, I think so")
        #expect(say("Ask comma. NASA knows") == "Ask, NASA knows")
    }

    @Test func breaks() {
        #expect(say("first line new line second line") == "first line\nSecond line")
        #expect(say("Dear Sam, new paragraph. Thanks for the notes.") == "Dear Sam,\n\nThanks for the notes.")
        #expect(say("done period new paragraph next") == "done.\n\nNext")
        #expect(say("one new line new line two") == "one\n\nTwo")
        #expect(say("one newline two") == "one\nTwo")
    }

    @Test func quotesBracketsDashAndHyphen() {
        #expect(say("she said open quote hello close quote and left") == "she said \"hello\" and left")
        #expect(say("the fair open parenthesis on Saturday close parenthesis is on") == "the fair (on Saturday) is on")
        #expect(say("see open bracket one close bracket.") == "see [one].")
        #expect(say("tables dash snacks") == "tables - snacks")
        #expect(say("a well hyphen known place") == "a well-known place")
    }

    @Test func emojiNeedTheWordEmoji() {
        #expect(say("thank you heart emoji") == "thank you ❤️")
        #expect(say("nice thumbs up emoji.") == "nice 👍.")
        #expect(say("my heart is full") == "my heart is full")
    }

    @Test func talkingAboutAMarkKeepsTheWords() {
        #expect(say("remove the comma after Sam") == "remove the comma after Sam")
        #expect(say("it was a period of calm") == "it was a period of calm")
        #expect(say("after a long period of rain") == "after a long period of rain")
        #expect(say("put a question mark there") == "put a question mark there")
        #expect(say("the trial period ends on Friday") == "the trial period ends on Friday")
        #expect(say("there is an extra full stop") == "there is an extra full stop")
        #expect(say("I will dash to the shop") == "I will dash to the shop")
        #expect(say("a dash of salt") == "a dash of salt")
        #expect(say("start a new paragraph") == "start a new paragraph")
    }

    @Test func onlyWholeWordsAndWholePhrasesMatch() {
        #expect(say("three periods and two commas") == "three periods and two commas")
        #expect(say("the periodic table") == "the periodic table")
        #expect(say("a good question. Mark agrees") == "a good question. Mark agrees")
        #expect(say("that is new") == "that is new")
        #expect(say("open the door") == "open the door")
    }

    @Test func sentenceFinalWordsStillGetTheirMark() {
        #expect(say("did you see that question mark") == "did you see that?")
        #expect(say("thanks for your time period") == "thanks for your time.")
        #expect(say("which one question mark") == "which one?")
    }

    @Test func aMarkSaidFirstJoinsTheTextBeforeTheCursor() {
        #expect(say("period", after: "x") == ".")
        #expect(say("Period.", after: "x") == ".")
        #expect(say("new line and more", after: "x") == "\nAnd more")
        #expect(say("comma and more", after: "x") == ", and more")
        #expect(say("open quote hi", after: "x") == " \"hi")
        #expect(say("hello", after: "x") == " hello")
    }

    @Test func aTableForAnotherLanguageWorksTheSameWay() {
        let german = SpokenPunctuation(rules: [
            SpokenRule(["punkt"], .mark(".", endsSentence: true)),
            SpokenRule(["neue zeile"], .lineBreak("\n")),
        ])
        let words = "das ist gut punkt neue zeile danke".split(separator: " ")
        #expect(german.apply(words) == "das ist gut.\nDanke")
    }

    @Test func oneLineFieldsAndTerminalsGetASpaceForABreak() {
        #expect(DictationText.singleLine("one.\n\nTwo\nthree") == "one. Two three")
        #expect(DictationText.singleLine("no breaks") == "no breaks")
        let slack = FocusedField(bundleID: "com.tinyspeck.slackmacgap", role: "AXTextArea")
        #expect(InsertionRouter.typedLineBreak(for: slack) == .shiftReturn)
        #expect(InsertionRouter.typedLineBreak(for: FocusedField(bundleID: "com.apple.Terminal", role: "AXTextArea")) == .space)
        #expect(InsertionRouter.typedLineBreak(for: FocusedField(bundleID: "com.google.Chrome", role: "AXTextField")) == .space)
        #expect(InsertionRouter.typedLineBreak(for: FocusedField(bundleID: "com.unknown.app")) == .shiftReturn)
        #expect(InsertionRouter.isSingleLine(FocusedField(bundleID: "com.apple.finder", role: "AXTextField")))
        #expect(!InsertionRouter.isSingleLine(FocusedField(bundleID: "com.apple.TextEdit", role: "AXTextArea")))
    }
}
