import FluidAudio
import Foundation

/// `~/.config/rec/vocab.json`: names and jargon the models get wrong, e.g.
/// `[{"text": "Oskar", "aliases": ["Oscar"]}]`. Parakeet is boosted towards
/// them with FluidAudio's CTC keyword spotter; then, whatever the engine, any
/// alias left in the transcript becomes its canonical `text`.
struct Vocabulary {
    struct Term: Codable {
        var text: String
        var aliases: [String]?
    }

    static let url = Paths.home.appendingPathComponent(".config/rec/vocab.json")
    static let starter = [Term(text: "Oskar", aliases: ["Oscar"]), Term(text: "Biteable", aliases: ["bite able", "bitable"])]

    let terms: [Term]
    /// (alias words, canonical), most words first so "bite able" wins over a one-word alias of "bite".
    private let replacements: [(words: [String], text: String)]

    init(terms: [Term]) {
        self.terms = terms
        replacements = terms.flatMap { term in
            (term.aliases ?? []).compactMap { alias -> ([String], String)? in
                let words = alias.split(whereSeparator: \.isWhitespace).map { Self.core(String($0)).lowercased() }
                return words.isEmpty || words.contains(where: \.isEmpty) ? nil : (words, term.text)
            }
        }.sorted { $0.0.count > $1.0.count }
    }

    /// Reads the file, writing the starter list first if there isn't one.
    static func load() throws -> Vocabulary {
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            try encoder.encode(starter).write(to: url, options: .atomic)
        }
        do {
            return Vocabulary(terms: try JSONDecoder().decode([Term].self, from: Data(contentsOf: url)))
        } catch {
            throw TranscribeError("cannot read \(url.path): \(error.localizedDescription)")
        }
    }

    /// For FluidAudio's spotter and rescorer. The similarity floor stops a
    /// clean common word being swapped for a term that merely sounds a bit like
    /// it ("Okay," → "Oskar" is 0.6); a listed alias scores 1.0.
    var context: CustomVocabularyContext {
        CustomVocabularyContext(terms: terms.map { CustomVocabularyTerm(text: $0.text, aliases: $0.aliases) }, minSimilarity: 0.7)
    }

    /// Replaces aliases with their canonical text: whole words, any case, keeping
    /// the punctuation around them ("oscar's." → "Oskar's."). A multi-word
    /// alias becomes one word spanning the originals' time.
    func canonicalize(_ words: [Word]) -> (words: [Word], replaced: Int) {
        var out: [Word] = []
        var replaced = 0
        var i = 0
        next: while i < words.count {
            for (alias, text) in replacements where i + alias.count <= words.count {
                let span = words[i..<i + alias.count]
                let last = Self.core(span.last!.word)
                // A possessive on the last word stays with the replacement.
                let suffix = ["'s", "’s"].first { last.lowercased().hasSuffix($0) && !alias.last!.hasSuffix($0) } ?? ""
                let cores = span.dropLast().map { Self.core($0.word) } + [String(last.dropLast(suffix.count))]
                guard cores.map({ $0.lowercased() }) == alias else { continue }
                let first = span.first!.word, end = span.last!.word
                let before = first.prefix { !$0.isLetter && !$0.isNumber }
                let after = end.reversed().prefix { !$0.isLetter && !$0.isNumber }.reversed()
                let word = String(before) + text + last.suffix(suffix.count) + String(after)
                if word != span.map(\.word).joined(separator: " ") { replaced += 1 }
                out.append(Word(word: word, startTime: span.first!.startTime, endTime: span.last!.endTime))
                i += alias.count
                continue next
            }
            out.append(words[i])
            i += 1
        }
        return (out, replaced)
    }

    /// The word without leading or trailing punctuation.
    private static func core(_ word: String) -> String {
        let chars = Array(word)
        guard let lo = chars.firstIndex(where: { $0.isLetter || $0.isNumber }),
              let hi = chars.lastIndex(where: { $0.isLetter || $0.isNumber }) else { return "" }
        return String(chars[lo...hi])
    }
}
