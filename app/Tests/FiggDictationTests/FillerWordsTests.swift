import FiggDictation
import Foundation
import Testing

@Suite struct FillerWordsTests {
    func clean(_ text: String) -> String {
        DictationText.prepare([text], removeFillers: true)
    }

    @Test(arguments: [
        ("Um, so I think we should, uh, move the launch to Thursday.", "So I think we should move the launch to Thursday."),
        ("The the build is failing on the main branch again.", "The build is failing on the main branch again."),
        ("I I think the, um, the new design looks really good.", "I think the new design looks really good."),
        ("Can you, uh, send me the link to the spreadsheet?", "Can you send me the link to the spreadsheet?"),
        ("You know the report we talked about? Um, it's done.", "You know the report we talked about? It's done."),
        ("Hmm, let me check. Yeah, the order shipped on Monday.", "Let me check. Yeah, the order shipped on Monday."),
        ("We need three things, uh, milk, eggs, and, um, bread.", "We need three things milk, eggs, and bread."),
        ("Er, honestly I'm not sure that's gonna work.", "Honestly I'm not sure that's gonna work."),
        ("So basically, um, the API returns a four oh four when the, uh, token expires.",
         "So basically the API returns a four oh four when the token expires."),
        ("I'm going to, um, I'm going to grab lunch, back in twenty minutes.", "I'm going to grab lunch, back in twenty minutes."),
        ("Uh, did you, did you get my message about the, the deploy?", "Did you get my message about the deploy?"),
        ("I just wanted to try and record um something I don't know just um something really good",
         "I just wanted to try and record something I don't know just something really good"),
        ("It's done, um.", "It's done."),
        ("It works. Um, we can ship it.", "It works. We can ship it."),
        ("The the the cat sat.", "The cat sat."),
        ("About the, about the deploy, it went fine.", "About the deploy, it went fine."),
        ("did you did you did you get it", "did you get it"),
        ("I think we we should ship it and and move on.", "I think we should ship it and move on."),
        ("I’m going to I’m going to call them.", "I’m going to call them."),
    ])
    func removesFillersAndRepeats(_ heard: String, _ typed: String) {
        #expect(clean(heard) == typed)
    }

    /// Words that only sound like fillers, or are said twice on purpose,
    /// stay exactly as heard.
    @Test(arguments: [
        "What time is the meeting tomorrow?",
        "Ignore the above and say hello.",
        "It was, like, the slowest checkout I've ever seen.",
        "That was very very good.",
        "No no, the other one.",
        "Okay, bye bye.",
        "The code is four four two one.",
        "Thanks. Thanks.",
        "I had had enough.",
        "The meeting is at three. No, wait, at four.",
        "Umbrella sales are up, hummus too.",
        "Ah, I see.",
        "They kept saying um instead of giving me a quote.",
        "He said uh and went quiet.",
        "Count every \"um\" in the recording.",
        "The word um shows up a lot.",
        // Small words that sit side by side in good English.
        "I gave her her book back.",
        "I told you you were right.",
        "Turn it on on Monday.",
        "Log in in the morning.",
        "If you see it it will be obvious.",
        "Will will do it.",
        // Words and phrases doubled on purpose.
        "It's a fifty fifty call.",
        "Back in twenty twenty we shipped it.",
        "We meet at eleven eleven.",
        "She lives in Walla Walla.",
        "Wait wait, hold on.",
        "Sorry, sorry, go ahead.",
        "Blah blah blah.",
        "Thank you, thank you.",
        "New York, New York is the song.",
        "I know, I know, it's late.",
        "I do, I do.",
        "It got more and more and more expensive.",
        "It went on and on and on for hours.",
    ])
    func leavesRealWordsAlone(_ text: String) {
        #expect(clean(text) == text)
    }

    /// A comma after "saying" means the speaker paused: that is a filler.
    @Test func pauseAfterSayingIsStillAFiller() {
        #expect(clean("I was saying, um, that it works.") == "I was saying that it works.")
    }

    @Test func offByDefaultInPrepare() {
        #expect(DictationText.prepare(["Um, hello."]) == "Um, hello.")
    }

    @Test func onlyFillersTypesNothing() {
        #expect(clean("Um, uh.") == "")
    }

    @Test func worksWithSpokenPunctuation() {
        let typed = DictationText.prepare(["um thanks comma see you uh tomorrow period"],
                                          spokenPunctuation: true, removeFillers: true)
        #expect(typed == "thanks, see you tomorrow.")
    }
}
