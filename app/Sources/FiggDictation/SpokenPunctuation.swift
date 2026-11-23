import Foundation

/// What a spoken command turns into.
public enum SpokenOutput: Equatable, Sendable {
    /// A mark that sits against the word before it: "." "," "?" "!" ":" ";".
    /// `endsSentence` capitalises the word after.
    case mark(String, endsSentence: Bool)
    /// Sits against the word after it: an opening quote or bracket.
    case opening(String)
    /// Sits against the word before it and keeps what follows apart: a
    /// closing quote or bracket.
    case closing(String)
    /// Joins the words on both sides with no spaces: a hyphen.
    case joiner(String)
    /// A word of its own with a space each side: a dash, an emoji.
    case word(String)
    /// A line break ("\n") or a paragraph break ("\n\n").
    case lineBreak(String)
}

/// One spoken command: the words that trigger it and what they become.
public struct SpokenRule: Sendable {
    public var phrases: [String]
    public var output: SpokenOutput
    /// Extra words that, said just before, mean the phrase is ordinary
    /// speech ("I will dash to the shop"), on top of `SpokenPunctuation.talkingAbout`.
    public var notAfter: Set<String>

    public init(_ phrases: [String], _ output: SpokenOutput, notAfter: Set<String> = []) {
        self.phrases = phrases
        self.output = output
        self.notAfter = notAfter
    }
}

/// Turns spoken punctuation into marks: "comma" becomes ",", "new
/// paragraph" a blank line. One pass over the words with a dictionary
/// lookup per word and no regular expressions, because it runs on every
/// live preview and again before the text is typed.
///
/// The words live in one table per language so another language can add
/// its own.
public struct SpokenPunctuation: Sendable {
    public static let english = SpokenPunctuation(rules: [
        SpokenRule(["period"], .mark(".", endsSentence: true), notAfter: ["trial", "grace", "notice", "waiting"]),
        SpokenRule(["full stop"], .mark(".", endsSentence: true)),
        SpokenRule(["comma"], .mark(",", endsSentence: false)),
        SpokenRule(["question mark"], .mark("?", endsSentence: true)),
        SpokenRule(["exclamation mark", "exclamation point"], .mark("!", endsSentence: true)),
        SpokenRule(["colon"], .mark(":", endsSentence: false)),
        SpokenRule(["semicolon", "semi colon"], .mark(";", endsSentence: false)),
        SpokenRule(["open quote", "open quotes"], .opening("\"")),
        SpokenRule(["close quote", "close quotes", "end quote", "unquote"], .closing("\"")),
        SpokenRule(["open bracket"], .opening("[")),
        SpokenRule(["close bracket"], .closing("]")),
        SpokenRule(["open parenthesis", "open paren"], .opening("(")),
        SpokenRule(["close parenthesis", "close paren"], .closing(")")),
        SpokenRule(["dash"], .word("-"),
                   notAfter: ["i", "i'll", "we", "we'll", "you", "they", "to", "will", "can", "could", "should", "must", "quick", "mad"]),
        SpokenRule(["hyphen"], .joiner("-")),
        SpokenRule(["new line", "newline"], .lineBreak("\n")),
        SpokenRule(["new paragraph"], .lineBreak("\n\n")),
        SpokenRule(["heart emoji"], .word("❤️")),
        SpokenRule(["smiley emoji", "smiley face emoji", "smile emoji"], .word("🙂")),
        SpokenRule(["laughing emoji"], .word("😂")),
        SpokenRule(["sad emoji", "sad face emoji"], .word("🙁")),
        SpokenRule(["wink emoji", "winking emoji"], .word("😉")),
        SpokenRule(["thumbs up emoji"], .word("👍")),
        SpokenRule(["thumbs down emoji"], .word("👎")),
        SpokenRule(["fire emoji"], .word("🔥")),
        SpokenRule(["party emoji"], .word("🎉")),
        SpokenRule(["thinking emoji"], .word("🤔")),
    ])

    /// Said just before a command word, these mean the user is talking
    /// about the mark, not asking for it: "remove the comma", "a period of
    /// calm". Only words that cannot end a sentence are here: "did you see
    /// that question mark" must still get its mark.
    public static let talkingAbout: Set<String> = [
        "the", "a", "an", "my", "your", "its", "our", "their", "every", "another",
        "extra", "missing", "trailing", "leading", "oxford", "word",
    ]

    /// Followed by one of these, a command word is ordinary speech too:
    /// "period of", "dash of".
    static let ordinaryBefore: Set<String> = ["of"]

    private struct Entry: Sendable {
        var words: [String]
        var output: SpokenOutput
        var notAfter: Set<String>
    }

    /// Phrases by their first word, longest first, so "new paragraph" is
    /// tried before a shorter phrase with the same start.
    private let byFirstWord: [String: [Entry]]

    public init(rules: [SpokenRule]) {
        var table: [String: [Entry]] = [:]
        for rule in rules {
            for phrase in rule.phrases {
                let words = phrase.split(separator: " ").map(String.init)
                guard let first = words.first else { continue }
                table[first, default: []].append(Entry(words: words, output: rule.output, notAfter: rule.notAfter))
            }
        }
        byFirstWord = table.mapValues { $0.sorted { $0.words.count > $1.words.count } }
    }

    private struct Piece {
        var text: String
        /// No space between this and the piece before / after it.
        var hugsLeft = false
        var hugsRight = false
        /// Came from a spoken command, not from the transcriber.
        var spoken = false
    }

    /// The punctuation the transcriber puts after a word on its own.
    private static let heardMarks: Set<Character> = [",", ".", ";", ":", "!", "?"]
    private static let sentenceEnds: Set<Character> = [".", "!", "?"]
    /// Capitalised wherever they are, so never lowered after a comma.
    private static let alwaysCapital: Set<String> = ["i", "i'm", "i'll", "i've", "i'd"]

    /// A word as it is looked up: lower case, without the punctuation the
    /// transcriber put around it. Apostrophes inside stay ("i'll").
    static func bare(_ token: Substring) -> String {
        var s = token
        while let c = s.first, !c.isLetter, !c.isNumber { s = s.dropFirst() }
        while let c = s.last, !c.isLetter, !c.isNumber { s = s.dropLast() }
        return s.lowercased()
    }

    /// Applies the table to whitespace-separated words and joins the result.
    /// Text with no command word in it comes back joined by single spaces,
    /// exactly as without this step.
    public func apply(_ tokens: [Substring]) -> String {
        let bare = tokens.map(Self.bare)
        // Nothing to do for most dictations: skip building pieces at all.
        guard bare.contains(where: { byFirstWord[$0] != nil }) else { return tokens.joined(separator: " ") }

        var out: [Piece] = []
        out.reserveCapacity(tokens.count)
        var capitaliseNext = false
        var lowerNext = false
        var i = 0
        while i < tokens.count {
            guard let entry = match(tokens, bare, at: i, afterSpoken: out.last?.spoken ?? false) else {
                var word = String(tokens[i])
                if capitaliseNext {
                    word = Self.capitalised(word)
                } else if lowerNext, !Self.alwaysCapital.contains(bare[i]) {
                    word = Self.lowered(word)
                }
                capitaliseNext = false
                lowerNext = false
                out.append(Piece(text: word))
                i += 1
                continue
            }
            let last = tokens[i + entry.words.count - 1]
            // What the transcriber put after the command word itself
            // ("comma," or "Period."): it heard a pause there, not a mark.
            let heardAfter = last.reversed().prefix(while: { !$0.isLetter && !$0.isNumber })
            let heardSentenceEnd = heardAfter.contains(where: Self.sentenceEnds.contains)
            switch entry.output {
            case .mark(let mark, let endsSentence):
                // "Hello, comma" and "Hello. Period." already carry the
                // transcriber's guess; the spoken mark replaces it.
                if let prev = out.indices.last, !out[prev].spoken {
                    while let c = out[prev].text.last, Self.heardMarks.contains(c) { out[prev].text.removeLast() }
                    if out[prev].text.isEmpty { out.removeLast() }
                }
                out.append(Piece(text: mark, hugsLeft: true, spoken: true))
                capitaliseNext = endsSentence
                // The transcriber started a new sentence after "comma."; a
                // comma does not.
                lowerNext = !endsSentence && heardSentenceEnd
            case .opening(let mark):
                out.append(Piece(text: mark, hugsRight: true, spoken: true))
                // The word after keeps the capital it had or was owed.
            case .closing(let mark):
                out.append(Piece(text: mark + String(heardAfter.reversed()), hugsLeft: true, spoken: true))
                capitaliseNext = heardSentenceEnd
            case .joiner(let mark):
                out.append(Piece(text: mark, hugsLeft: true, hugsRight: true, spoken: true))
            case .word(let word):
                out.append(Piece(text: word + String(heardAfter.reversed()), spoken: true))
                capitaliseNext = heardSentenceEnd
            case .lineBreak(let lineBreak):
                // "new line new line" is two breaks, one after the other.
                out.append(Piece(text: lineBreak, hugsLeft: true, hugsRight: true, spoken: true))
                capitaliseNext = true
            }
            i += entry.words.count
        }

        var text = ""
        text.reserveCapacity(tokens.reduce(0) { $0 + $1.utf8.count + 1 })
        for (n, piece) in out.enumerated() {
            if n > 0, !piece.hugsLeft, !out[n - 1].hugsRight { text.append(" ") }
            text.append(piece.text)
        }
        return text
    }

    /// The command that starts at `i`, unless the words around it say it is
    /// ordinary speech.
    private func match(_ tokens: [Substring], _ bare: [String], at i: Int, afterSpoken: Bool) -> Entry? {
        guard let entries = byFirstWord[bare[i]] else { return nil }
        for entry in entries {
            let end = i + entry.words.count
            guard end <= tokens.count else { continue }
            var matches = true
            for k in 1..<entry.words.count where bare[i + k] != entry.words[k] { matches = false; break }
            // "question. Mark" is two sentences, not a question mark.
            for k in 0..<(entry.words.count - 1) {
                guard let c = tokens[i + k].last, c.isLetter || c.isNumber else { matches = false; break }
            }
            guard matches else { continue }
            // The word before decides, unless it was itself a command
            // ("period new line": "period" is not what "new line" is about).
            if i > 0, !afterSpoken, Self.talkingAbout.contains(bare[i - 1]) || entry.notAfter.contains(bare[i - 1]) {
                return nil
            }
            if case .lineBreak = entry.output {} else if end < tokens.count, Self.ordinaryBefore.contains(bare[end]) {
                return nil
            }
            return entry
        }
        return nil
    }

    private static func capitalised(_ word: String) -> String {
        guard let i = word.firstIndex(where: { $0.isLetter }), word[i].isLowercase else { return word }
        return word.replacingCharacters(in: i...i, with: word[i].uppercased())
    }

    /// Lowers a capital the transcriber gave the start of a sentence. Words
    /// in capitals throughout ("NASA") are left alone.
    private static func lowered(_ word: String) -> String {
        guard let i = word.firstIndex(where: { $0.isLetter }), word[i].isUppercase else { return word }
        let rest = word[word.index(after: i)...]
        if let next = rest.first(where: { $0.isLetter }), next.isUppercase { return word }
        return word.replacingCharacters(in: i...i, with: word[i].lowercased())
    }
}
