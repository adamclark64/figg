import Foundation

/// Drops filler words ("um", "uh") and words said twice by accident ("the
/// the", "did you, did you") from a dictation, without a model.
///
/// A fixed word list on purpose: it runs in microseconds, and it can only
/// take words away, so it never adds, reorders or rewrites what was said.
/// Words that are only sometimes fillers ("like", "you know") are left
/// alone, since telling the two apart needs a model. Repeats are kept
/// unless they are made of small words nobody doubles on purpose.
public enum FillerWords {
    /// Sounds that are never words the speaker meant to type.
    static let fillers: Set<String> = ["um", "umm", "ummm", "uh", "uhh", "uhhh", "uhm", "er", "erm", "hmm", "hmmm", "hm"]

    /// Small words that are almost never said twice on purpose, so a double
    /// is a stumble ("the the", "I I"). Only repeats built from these and
    /// `sometimesDoubled` are removed. Any other word said twice stays
    /// ("fifty fifty", "Walla Walla", "wait wait", "four four two one"):
    /// dropping a word that was meant is worse than leaving a stumble in.
    static let neverDoubled: Set<String> = bothApostrophes([
        "the", "a", "an", "i", "we", "she", "they", "our", "your", "their", "his", "its",
        "and", "but", "or", "if", "because", "of", "to", "with", "from", "for", "at", "as",
        "this", "these", "those", "did", "does", "could", "would", "should",
        "i'm", "i'll", "i've", "i'd", "we're", "we'll", "we've", "we'd", "you're", "you've", "you'll",
        "it's", "that's", "there's", "he's", "she's", "they're", "they've", "don't", "didn't", "can't",
    ])

    /// Small words that do sit side by side in good English ("gave her her
    /// book", "told you you were right", "turn it on on Monday", "Will will
    /// do it"), so a double of one is kept. They can still begin or end a
    /// longer restart ("did you, did you get").
    static let sometimesDoubled: Set<String> = [
        "you", "it", "her", "him", "me", "us", "them", "he", "my", "that", "there",
        "had", "have", "has", "is", "are", "was", "were", "be", "do", "will", "can",
        "in", "on", "up", "out", "over", "by", "about", "so", "not",
        "what", "when", "where", "which", "who", "how",
    ]

    /// The words with a curly apostrophe as well as a straight one.
    static func bothApostrophes(_ words: [String]) -> Set<String> {
        Set(words.flatMap { [$0, $0.replacingOccurrences(of: "'", with: "’")] })
    }

    /// Words after which a filler is being talked about, not used ("they
    /// kept saying um", "the word uh"), so it stays. "the" is left out on
    /// purpose: "the, um, the" is the commonest real filler of all.
    static let mentions: Set<String> = [
        "say", "says", "said", "saying", "word", "words", "write", "wrote", "writing",
        "type", "typed", "typing", "spell", "spelled", "called", "an",
    ]

    /// Longest phrase checked for an accidental repeat, in words.
    static let longestRepeat = 4

    /// The words with fillers and accidental repeats taken out. Each word
    /// may carry punctuation ("Um," "it."), as transcripts write it.
    public static func remove(_ words: [Substring]) -> [Substring] {
        removeRepeats(removeFillers(words))
    }

    // MARK: Fillers

    static func removeFillers(_ words: [Substring]) -> [Substring] {
        var out: [Substring] = []
        out.reserveCapacity(words.count)
        var capitalizeNext = false
        for word in words {
            if fillers.contains(core(word)), !isMentioned(word, after: out.last) {
                let marks = trailingMarks(word)
                if let end = marks.last, ".?!".contains(end) {
                    // "it's done, um." keeps the sentence's end.
                    if var last = out.popLast() {
                        last = Substring(stripTrailingMarks(last) + String(end))
                        out.append(last)
                    }
                } else if marks.contains(","), let last = out.last, last.hasSuffix(",") {
                    // "should, uh, move": the filler's pair of commas goes too.
                    out[out.count - 1] = last.dropLast()
                }
                // "Um, so..." at the start of a sentence: "So..."
                if startsSentence(at: out), word.first?.isUppercase == true { capitalizeNext = true }
                continue
            }
            if capitalizeNext {
                out.append(Substring(capitalized(word)))
                capitalizeNext = false
            } else {
                out.append(word)
            }
        }
        return out
    }

    /// True when the filler is quoted ("um") or follows a word like "said",
    /// so the speaker means the word itself.
    static func isMentioned(_ word: Substring, after previous: Substring?) -> Bool {
        if let first = word.first, "\"'“‘".contains(first) { return true }
        guard let previous else { return false }
        // "saying, um, that" is still a filler: a comma between them breaks it.
        if previous.hasSuffix(",") { return false }
        return mentions.contains(core(previous))
    }

    // MARK: Repeats

    static func removeRepeats(_ words: [Substring]) -> [Substring] {
        guard words.count > 1 else { return words }
        var out: [Substring] = []
        out.reserveCapacity(words.count)
        let cores = words.map(core)
        var i = 0
        var capitalizeNext = false
        while i < words.count {
            // Longest phrase first, so "I'm going to, I'm going to" goes
            // whole. Only the first copy is skipped: the second is checked
            // again, which takes care of "the the the".
            let longest = min(longestRepeat, (words.count - i) / 2)
            if let n = stride(from: longest, through: 1, by: -1).first(where: {
                isAccidentalRepeat(cores, words, at: i, length: $0)
            }) {
                // Keep the capital when the first copy started a sentence.
                if words[i].first?.isUppercase == true, startsSentence(at: out) { capitalizeNext = true }
                i += n
                continue
            }
            out.append(capitalizeNext ? Substring(capitalized(words[i])) : words[i])
            capitalizeNext = false
            i += 1
        }
        return out
    }

    static func isAccidentalRepeat(_ cores: [String], _ words: [Substring], at i: Int, length n: Int) -> Bool {
        let first = cores[i..<(i + n)], second = cores[(i + n)..<(i + 2 * n)]
        guard first.elementsEqual(second), let head = first.first, let tail = first.last else { return false }
        // A sentence that ends and starts again the same way is meant.
        if endsSentence(words[i + n - 1]) { return false }
        if n == 1 { return neverDoubled.contains(head) }
        // A restart breaks off on a small word and starts on one ("I'm
        // going to, I'm going to"). "New York, New York" and "thank you,
        // thank you" do neither.
        guard isSmall(head), isSmall(tail) else { return false }
        // It also carries on afterwards. "I do, I do." is finished both
        // times, so it was meant.
        let after = i + 2 * n
        if after == words.count || endsSentence(words[after - 1]) { return false }
        // "on and on and on" is one phrase, not "on and" said twice.
        if first.contains("and"), cores[after] == head || (i > 0 && cores[i - 1] == tail) { return false }
        return true
    }

    static func isSmall(_ core: String) -> Bool {
        neverDoubled.contains(core) || sometimesDoubled.contains(core)
    }

    static func endsSentence(_ word: Substring) -> Bool {
        trailingMarks(word).last.map { ".?!".contains($0) } ?? false
    }

    // MARK: Helpers

    /// The word lowercased with punctuation around it removed. Transcripts
    /// are plain words with marks only at the ends, so this trims by hand:
    /// `trimmingCharacters(in:)` was most of the filter's time.
    static func core(_ word: Substring) -> String {
        guard let start = word.firstIndex(where: { $0.isLetter || $0.isNumber }),
              let end = word.lastIndex(where: { $0.isLetter || $0.isNumber }) else { return "" }
        return word[start...end].lowercased()
    }

    static func trailingMarks(_ word: Substring) -> Substring {
        word[(word.lastIndex(where: { $0.isLetter || $0.isNumber }).map(word.index(after:)) ?? word.startIndex)...]
    }

    static func stripTrailingMarks(_ word: Substring) -> String {
        String(word.dropLast(trailingMarks(word).count))
    }

    static func startsSentence(at out: [Substring]) -> Bool {
        guard let last = out.last else { return true }
        return last.last.map { ".?!".contains($0) } ?? true
    }

    static func capitalized(_ word: Substring) -> String {
        guard let first = word.first else { return String(word) }
        return first.uppercased() + word.dropFirst()
    }
}
