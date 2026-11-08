import Foundation

// MARK: - Phrase rewriting

/// Rewrites whole-word phrases in a single left-to-right pass.
///
/// Matching rules (shared by the vocabulary rewrite and mode replacements):
/// - **Case-insensitive, diacritic-sensitive.** Characters are compared after
///   lowercasing; `è` never matches `e`. Precomposed and decomposed forms of
///   the same character are equal (Unicode canonical equivalence). The
///   typographic apostrophes `’` (U+2019) and `ʼ` (U+02BC) match `'`, so a
///   rule for `l'api` also matches `l’API`.
/// - **Whole word.** A word character is a letter or a digit
///   (`Character.isLetter || Character.isNumber`). When a pattern starts with
///   a word character, the character before the match must not be one; when it
///   ends with a word character, the character after must not be one. Edges of
///   the text count as boundaries. Patterns that start or end with punctuation
///   need no boundary on that side.
/// - **Longest first.** At each position the longest matching pattern
///   (in characters) wins; equal lengths keep declaration order.
/// - **Single pass.** After a match the scan resumes after the matched input;
///   inserted output is never re-scanned. Boundaries are judged on the input.
/// - Patterns are trimmed; blank patterns are ignored. Text outside matches,
///   including whitespace and punctuation next to a match, is kept verbatim.
public struct PhraseRewriter: Sendable {
    /// One rewrite rule.
    public struct Rule: Sendable, Hashable {
        /// The phrase to find.
        public var pattern: String
        /// The text written in place of each match.
        public var output: String

        /// Creates a rule.
        public init(pattern: String, output: String) {
            self.pattern = pattern
            self.output = output
        }
    }

    /// The result of ``rewrite(_:)``.
    public struct Outcome: Sendable, Equatable {
        /// The rewritten text.
        public var text: String
        /// How many matches were replaced.
        public var matchCount: Int
    }

    private struct CompiledRule: Sendable {
        let folded: [String]
        let startsWithWordCharacter: Bool
        let endsWithWordCharacter: Bool
        let output: String
    }

    private let rules: [CompiledRule]

    /// Compiles `rules`. Blank patterns are dropped.
    public init(rules: [Rule]) {
        let compiled: [(offset: Int, rule: CompiledRule)] = rules.enumerated().compactMap { offset, rule in
            let characters = Array(rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines))
            guard let first = characters.first, let last = characters.last else { return nil }
            return (offset, CompiledRule(
                folded: characters.map(Self.fold),
                startsWithWordCharacter: Self.isWordCharacter(first),
                endsWithWordCharacter: Self.isWordCharacter(last),
                output: rule.output
            ))
        }
        self.rules = compiled
            .sorted { lhs, rhs in
                lhs.rule.folded.count != rhs.rule.folded.count
                    ? lhs.rule.folded.count > rhs.rule.folded.count
                    : lhs.offset < rhs.offset
            }
            .map(\.rule)
    }

    /// Whether the rewriter has no usable rule.
    public var isEmpty: Bool { rules.isEmpty }

    /// Rewrites `text` according to the matching rules above.
    public func rewrite(_ text: String) -> Outcome {
        guard !rules.isEmpty, !text.isEmpty else { return Outcome(text: text, matchCount: 0) }
        let characters = Array(text)
        let folded = characters.map(Self.fold)
        var output = ""
        output.reserveCapacity(text.utf8.count)
        var index = 0
        var matchCount = 0

        while index < characters.count {
            let atWordStart = index == 0 || !Self.isWordCharacter(characters[index - 1])
            var matchedLength = 0
            for rule in rules {
                let length = rule.folded.count
                guard index + length <= characters.count else { continue }
                if rule.startsWithWordCharacter && !atWordStart { continue }
                if rule.endsWithWordCharacter,
                   index + length < characters.count,
                   Self.isWordCharacter(characters[index + length]) {
                    continue
                }
                var equal = true
                for offset in 0..<length where folded[index + offset] != rule.folded[offset] {
                    equal = false
                    break
                }
                if equal {
                    output += rule.output
                    matchedLength = length
                    matchCount += 1
                    break
                }
            }
            if matchedLength > 0 {
                index += matchedLength
            } else {
                output.append(characters[index])
                index += 1
            }
        }
        return Outcome(text: output, matchCount: matchCount)
    }

    /// Whether `character` is a word character (letter or digit) for boundary purposes.
    public static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    private static func fold(_ character: Character) -> String {
        switch character {
        case "\u{2019}", "\u{02BC}":
            return "'"
        default:
            return character.lowercased()
        }
    }
}

// MARK: - Built-in transformations

/// The transformations Hex ships as built-ins, implemented on iPhone.
/// Other ids (custom Hex commands) are skipped and reported by
/// ``TextProcessor``.
public enum BuiltInTransformation: String, CaseIterable, Sendable {
    /// Lowercases the whole text.
    case lowercase = "lowercase"
    /// Removes the punctuation at the end of the text.
    case noTrailingPunctuation = "no-trailing-punctuation"
    /// Alternates lowercase and uppercase letters.
    case spongebobCase = "spongebob-case"

    /// Applies the transformation.
    ///
    /// - `lowercase`: `String.lowercased()`.
    /// - `no-trailing-punctuation`: removes the trailing run of terminal
    ///   punctuation (Unicode `Terminal_Punctuation`, e.g. `. , ; : ! ?` and
    ///   their CJK/Arabic forms, plus `…`), together with whitespace inside
    ///   that run. Trailing whitespace after the run is kept. Closing quotes,
    ///   brackets, apostrophes (Italian `un po'`) and symbols such as `%` stop
    ///   the run and are never removed.
    /// - `spongebob-case`: walks the letters only, starting lowercase and
    ///   alternating; non-letters are copied and do not advance the alternation.
    public func apply(to text: String) -> String {
        switch self {
        case .lowercase:
            return text.lowercased()
        case .noTrailingPunctuation:
            return Self.removingTrailingPunctuation(text)
        case .spongebobCase:
            return Self.spongebob(text)
        }
    }

    private static func isTerminalPunctuation(_ character: Character) -> Bool {
        if character == "\u{2026}" { return true }
        let scalars = character.unicodeScalars
        guard let first = scalars.first else { return false }
        return first.properties.isTerminalPunctuation
            && scalars.dropFirst().allSatisfy { $0.properties.generalCategory == .nonspacingMark }
    }

    private static func removingTrailingPunctuation(_ text: String) -> String {
        let characters = Array(text)
        var contentEnd = characters.count
        while contentEnd > 0, characters[contentEnd - 1].isWhitespace { contentEnd -= 1 }
        var cut = contentEnd
        var removedPunctuation = false
        while cut > 0 {
            let character = characters[cut - 1]
            if isTerminalPunctuation(character) {
                removedPunctuation = true
            } else if !character.isWhitespace {
                break
            }
            cut -= 1
        }
        guard removedPunctuation else { return text }
        // `cut` now follows the last kept character, which is never whitespace:
        // whitespace that only preceded the removed punctuation goes with it.
        return String(characters[..<cut]) + String(characters[contentEnd...])
    }

    private static func spongebob(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        var uppercase = false
        for character in text {
            if character.isLetter {
                result += uppercase ? character.uppercased() : character.lowercased()
                uppercase.toggle()
            } else {
                result.append(character)
            }
        }
        return result
    }
}

// MARK: - Text processor

/// The result of ``TextProcessor/process(_:)``.
public struct ProcessingResult: Sendable, Equatable {
    /// The final text.
    public var text: String
    /// Number of vocabulary phrases rewritten to their term (step 1).
    public var vocabularyRewriteCount: Int
    /// Number of mode replacements applied (step 2).
    public var replacementCount: Int
    /// Transformation ids applied, in order (step 3).
    public var appliedTransformations: [String]
    /// Transformation ids that are not built-ins and were skipped, in order.
    /// These are Hex personal commands that only run on the Mac.
    public var skippedTransformations: [String]

    /// Creates a result.
    public init(
        text: String,
        vocabularyRewriteCount: Int = 0,
        replacementCount: Int = 0,
        appliedTransformations: [String] = [],
        skippedTransformations: [String] = []
    ) {
        self.text = text
        self.vocabularyRewriteCount = vocabularyRewriteCount
        self.replacementCount = replacementCount
        self.appliedTransformations = appliedTransformations
        self.skippedTransformations = skippedTransformations
    }
}

/// Hex's dictation text pipeline on iPhone: an independent reimplementation
/// of the semantics Hex documents and exports, written without Hex source
/// code.
///
/// For each transcript:
/// 1. **Vocabulary rewrite.** Every `sounds_like` phrase becomes its `term`.
/// 2. **Mode replacements.** Every `matched_phrase` becomes its `output`.
///    This step sees the output of step 1.
/// 3. **Mode transformations**, in order. Built-ins (``BuiltInTransformation``)
///    are applied; unknown ids are skipped and reported in
///    ``ProcessingResult/skippedTransformations``.
///
/// Steps 1 and 2 each use ``PhraseRewriter`` (whole word, case-insensitive,
/// diacritic-sensitive, longest first, single pass). When the same phrase is
/// declared twice, the first declaration wins.
public struct TextProcessor: Sendable {
    /// The mode whose replacements and transformations are applied.
    public let mode: ProcessingMode
    private let vocabularyRewriter: PhraseRewriter
    private let replacementRewriter: PhraseRewriter
    private let contextualCorrections: [ContextualCorrection]

    /// Creates a processor.
    /// - Parameters:
    ///   - vocabulary: Hex vocabulary (step 1).
    ///   - mode: the active mode (steps 2–3); ``ProcessingMode/passthrough`` applies none.
    public init(vocabulary: [VocabularyEntry], mode: ProcessingMode = .passthrough, contextualCorrections: [ContextualCorrection] = []) {
        self.mode = mode
        self.contextualCorrections = contextualCorrections
        vocabularyRewriter = PhraseRewriter(rules: vocabulary.flatMap { entry in
            entry.soundsLike.map { PhraseRewriter.Rule(pattern: $0, output: entry.term) }
        })
        replacementRewriter = PhraseRewriter(rules: mode.replacements.map {
            PhraseRewriter.Rule(pattern: $0.matchedPhrase, output: $0.output)
        })
    }

    /// Creates a processor from a synced bundle.
    /// - Parameters:
    ///   - bundle: the bundle exported by the Mac.
    ///   - modeOverride: name of one of the bundle's modes chosen by the user;
    ///     `nil` uses the default mode. See ``SyncBundle/activeMode(overrideName:)``.
    ///   - pendingVocabulary: terms added on iPhone and not yet applied on the
    ///     Mac; they are used after the synced vocabulary.
    public init(
        bundle: SyncBundle,
        modeOverride: String? = nil,
        pendingVocabulary: [PendingVocabularyEntry] = [],
        contextualCorrections: [ContextualCorrection] = []
    ) {
        self.init(
            vocabulary: bundle.vocabulary + pendingVocabulary.map(\.vocabularyEntry),
            mode: bundle.activeMode(overrideName: modeOverride),
            contextualCorrections: contextualCorrections
        )
    }

    /// Runs the pipeline on `text`. Empty input returns an empty result.
    public func process(_ text: String) -> ProcessingResult {
        let corrected = contextualCorrections.reduce(text) { $1.apply(to: $0) }
        let vocabularyOutcome = vocabularyRewriter.rewrite(corrected)
        let replacementOutcome = replacementRewriter.rewrite(vocabularyOutcome.text)
        var current = replacementOutcome.text
        var applied: [String] = []
        var skipped: [String] = []
        for rawID in mode.transformations {
            let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            if let transformation = BuiltInTransformation(rawValue: id) {
                current = transformation.apply(to: current)
                applied.append(id)
            } else {
                skipped.append(rawID)
            }
        }
        return ProcessingResult(
            text: current,
            vocabularyRewriteCount: vocabularyOutcome.matchCount,
            replacementCount: replacementOutcome.matchCount,
            appliedTransformations: applied,
            skippedTransformations: skipped
        )
    }

    /// The mode's transformation ids that this package cannot run
    /// (useful to warn the user once in Settings).
    public var unsupportedTransformations: [String] {
        mode.transformations.filter {
            BuiltInTransformation(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines)) == nil
        }
    }
}
