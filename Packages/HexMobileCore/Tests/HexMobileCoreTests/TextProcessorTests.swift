import Foundation
import Testing
@testable import HexMobileCore

@Suite("Phrase rewriting rules")
struct PhraseRewriterTests {
    private func rewrite(_ text: String, _ rules: [(String, String)]) -> String {
        PhraseRewriter(rules: rules.map { PhraseRewriter.Rule(pattern: $0.0, output: $0.1) }).rewrite(text).text
    }

    @Test("Case-insensitive match keeps the output's own spelling", arguments: [
        ("ho usato example kid ieri", "ho usato Example Kit ieri"),
        ("Example Kid è ottimo", "Example Kit è ottimo"),
        ("EXAMPLE KID", "Example Kit"),
    ])
    func caseInsensitive(input: String, expected: String) {
        #expect(rewrite(input, [("example kid", "Example Kit")]) == expected)
    }

    @Test("Whole words only, using Unicode letter and digit boundaries", arguments: [
        ("example kidx", "example kidx"),
        ("myexample kid", "myexample kid"),
        ("example kid2", "example kid2"),
        ("2example kid", "2example kid"),
        ("example kidè", "example kidè"),
        ("example kid_x", "Example Kit_x"),
        ("example kid-x", "Example Kit-x"),
    ])
    func wholeWord(input: String, expected: String) {
        #expect(rewrite(input, [("example kid", "Example Kit")]) == expected)
    }

    @Test("Accented letters are word characters: no match inside città")
    func accentedLettersAreWordCharacters() {
        #expect(rewrite("città e citt", [("citt", "X")]) == "città e X")
    }

    @Test("Diacritic-sensitive: perche and perché are different phrases")
    func diacriticSensitive() {
        #expect(rewrite("perche lo dici", [("perche", "perché")]) == "perché lo dici")
        #expect(rewrite("perché lo dici", [("perche", "PERCHE")]) == "perché lo dici")
        #expect(rewrite("PERCHÉ lo dici", [("perché", "Perché")]) == "Perché lo dici")
        #expect(rewrite("È vero, è così", [("è", "e")]) == "e vero, e così")
    }

    @Test("Decomposed accents match precomposed patterns")
    func canonicalEquivalence() {
        #expect(rewrite("perche\u{301} no", [("perch\u{E9}", "OK")]) == "OK no")
    }

    @Test("Apostrophes are boundaries; typographic apostrophes match ASCII ones")
    func apostrophes() {
        #expect(rewrite("l'a p i è pronta", [("a p i", "API")]) == "l'API è pronta")
        #expect(rewrite("l’a p i è pronta", [("a p i", "API")]) == "l’API è pronta")
        #expect(rewrite("uso l’api nuova", [("l'api", "l'API")]) == "uso l'API nuova")
        #expect(rewrite("dell'esempio", [("esempio", "Esempio")]) == "dell'Esempio")
    }

    @Test("Longest phrase wins regardless of declaration order")
    func longestFirst() {
        let rules = [("new york", "NY"), ("new york city", "NYC"), ("york", "Y")]
        #expect(rewrite("new york city e new york e york", rules) == "NYC e NY e Y")
    }

    @Test("Equal length: first declaration wins")
    func tieBreak() {
        #expect(rewrite("abc", [("abc", "first"), ("ABC", "second")]) == "first")
    }

    @Test("Overlapping phrases: leftmost match wins, scan resumes after it")
    func overlapping() {
        #expect(rewrite("alfa beta gamma", [("alfa beta", "X"), ("beta gamma", "Y")]) == "X gamma")
        #expect(rewrite("beta gamma alfa beta", [("alfa beta", "X"), ("beta gamma", "Y")]) == "Y X")
    }

    @Test("Single pass: output is never re-matched")
    func singlePass() {
        let rules = [("foo", "foo bar"), ("bar", "baz")]
        #expect(rewrite("foo", rules) == "foo bar")
        #expect(rewrite("bar foo bar", rules) == "baz foo bar baz")
        #expect(rewrite("aa", [("a", "aa")]) == "aa")
        #expect(rewrite("a a", [("a", "aa")]) == "aa aa")
    }

    @Test("Surrounding whitespace and punctuation are preserved", arguments: [
        ("  example kid\n", "  Example Kit\n"),
        ("(example kid),", "(Example Kit),"),
        ("«example kid»!", "«Example Kit»!"),
        ("\"example kid\".", "\"Example Kit\"."),
        ("example kid?example kid", "Example Kit?Example Kit"),
        ("\texample kid\t", "\tExample Kit\t"),
    ])
    func punctuationAdjacency(input: String, expected: String) {
        #expect(rewrite(input, [("example kid", "Example Kit")]) == expected)
    }

    @Test("Digits are word characters", arguments: [
        ("v2", "version 2"), ("v22", "v22"), ("av2", "av2"), ("(v2)", "(version 2)"),
    ])
    func digits(input: String, expected: String) {
        #expect(rewrite(input, [("v2", "version 2")]) == expected)
    }

    @Test("Patterns starting or ending with punctuation need no boundary on that side")
    func punctuationEdgedPatterns() {
        #expect(rewrite("sito.com e sito .com", [(".com", " dot com")]) == "sito dot com e sito  dot com")
        #expect(rewrite("ciao!!", [("!!", "!")]) == "ciao!")
    }

    @Test("Blank patterns are ignored; empty text is returned unchanged")
    func blanks() {
        let rewriter = PhraseRewriter(rules: [PhraseRewriter.Rule(pattern: "  ", output: "X"), .init(pattern: "", output: "Y")])
        #expect(rewriter.isEmpty)
        #expect(rewriter.rewrite("a b").text == "a b")
        #expect(PhraseRewriter(rules: [.init(pattern: "a", output: "b")]).rewrite("") == .init(text: "", matchCount: 0))
    }

    @Test("Patterns are trimmed before matching")
    func trimmedPatterns() {
        #expect(rewrite("a example kid b", [("  example kid ", "CC")]) == "a CC b")
    }

    @Test("Empty output deletes the phrase")
    func deletion() {
        #expect(rewrite("ehm allora ehm", [("ehm", "")]) == " allora ")
    }

    @Test("Match count is reported")
    func matchCount() {
        let outcome = PhraseRewriter(rules: [.init(pattern: "x", output: "y")]).rewrite("x x xx x")
        #expect(outcome == .init(text: "y y xx y", matchCount: 3))
    }
}

@Suite("Built-in transformations")
struct BuiltInTransformationTests {
    @Test("Ids match Hex built-ins")
    func ids() {
        #expect(BuiltInTransformation.allCases.map(\.rawValue) == ["lowercase", "no-trailing-punctuation", "spongebob-case"])
    }

    @Test("lowercase handles accented capitals")
    func lowercase() {
        #expect(BuiltInTransformation.lowercase.apply(to: "PERCHÉ È COSÌ? L'API") == "perché è così? l'api")
    }

    @Test("no-trailing-punctuation", arguments: [
        ("Ciao.", "Ciao"),
        ("Davvero?!", "Davvero"),
        ("Fine…", "Fine"),
        ("Fine... ", "Fine "),
        ("Ciao .", "Ciao"),
        ("Allora, ", "Allora "),
        ("Ok;\n", "Ok\n"),
        ("un po'", "un po'"),
        ("un po'.", "un po'"),
        ("Ha detto \"sì.\"", "Ha detto \"sì.\""),
        ("(nota)", "(nota)"),
        ("«ciao»", "«ciao»"),
        ("sconto 50%", "sconto 50%"),
        ("Ciao, mondo", "Ciao, mondo"),
        ("こんにちは。", "こんにちは"),
        ("...", ""),
        ("", ""),
        ("   ", "   "),
    ])
    func noTrailingPunctuation(input: String, expected: String) {
        #expect(BuiltInTransformation.noTrailingPunctuation.apply(to: input) == expected)
    }

    @Test("spongebob-case alternates letters only, starting lowercase", arguments: [
        ("ciao mondo", "cIaO mOnDo"),
        ("PERCHÉ è", "pErChÉ è"),
        ("l'API 2 volte", "l'ApI 2 vOlTe"),
        ("", ""),
    ])
    func spongebob(input: String, expected: String) {
        #expect(BuiltInTransformation.spongebobCase.apply(to: input) == expected)
    }
}

@Suite("Text processor pipeline")
struct TextProcessorTests {
    private let vocabulary = [
        VocabularyEntry(term: "Example Kit", soundsLike: ["example kid", "sample kit"]),
        VocabularyEntry(term: "perché", soundsLike: ["perche"]),
        VocabularyEntry(term: "API", soundsLike: ["a p i"]),
    ]

    @Test("Empty input stays empty")
    func emptyInput() {
        let result = TextProcessor(vocabulary: vocabulary, mode: ProcessingMode(name: "M", transformations: ["lowercase"]))
            .process("")
        #expect(result.text == "")
        #expect(result.vocabularyRewriteCount == 0)
        #expect(result.replacementCount == 0)
    }

    @Test("Passthrough mode only rewrites vocabulary")
    func vocabularyOnly() {
        let result = TextProcessor(vocabulary: vocabulary).process("Perche example kid usa l'a p i?")
        #expect(result.text == "perché Example Kit usa l'API?")
        #expect(result.vocabularyRewriteCount == 3)
        #expect(result.skippedTransformations.isEmpty)
    }

    @Test("Replacements see the vocabulary output (step order)")
    func stepOrder() {
        let mode = ProcessingMode(name: "M", replacements: [Replacement(matchedPhrase: "Example Kit", output: "CC")])
        let result = TextProcessor(vocabulary: vocabulary, mode: mode).process("apri example kid")
        #expect(result.text == "apri CC")
        #expect(result.vocabularyRewriteCount == 1)
        #expect(result.replacementCount == 1)
    }

    @Test("Vocabulary rewrite does not re-match its own output")
    func vocabularySinglePass() {
        let vocabulary = [
            VocabularyEntry(term: "code review", soundsLike: ["code"]),
            VocabularyEntry(term: "X", soundsLike: ["review"]),
        ]
        #expect(TextProcessor(vocabulary: vocabulary).process("code").text == "code review")
    }

    @Test("Transformations run in order after replacements; unknown ids are skipped and reported")
    func transformations() {
        let mode = ProcessingMode(
            name: "Chat",
            replacements: [Replacement(matchedPhrase: "punto", output: ".")],
            transformations: ["spongebob-case", "my-personal-command", "lowercase", "no-trailing-punctuation", " "]
        )
        let processor = TextProcessor(vocabulary: vocabulary, mode: mode)
        let result = processor.process("Example Kid PERCHE punto")
        #expect(result.text == "example kit perché")
        #expect(result.appliedTransformations == ["spongebob-case", "lowercase", "no-trailing-punctuation"])
        #expect(result.skippedTransformations == ["my-personal-command", " "])
        #expect(processor.unsupportedTransformations == ["my-personal-command", " "])
    }

    @Test("Italian dictation with accents, apostrophes and replacements")
    func italianSentence() throws {
        let bundle = try SyncCodec.decodeBundle(from: fixtureData("bundle-v1"))
        let processor = TextProcessor(bundle: bundle)
        let result = processor.process("Perche l'esempio studio usa postgres q l punto e virgola a capo è così")
        #expect(result.text == "perché l'Example Studio usa PostgreSQL ; \n è così")
        #expect(result.vocabularyRewriteCount == 3)
        #expect(result.replacementCount == 2)
    }

    @Test("Bundle mode override selects the mode's rules")
    func modeOverride() throws {
        let bundle = try SyncCodec.decodeBundle(from: fixtureData("bundle-v1"))
        let terminal = TextProcessor(bundle: bundle, modeOverride: "Terminal")
        #expect(terminal.mode.name == "Terminal")
        #expect(terminal.process("cd slash tmp slash cooper netties.").text == "cd / tmp / Kubernetes")

        let chat = TextProcessor(bundle: bundle, modeOverride: "Chat").process("Usa PostgreSQL!")
        #expect(chat.text == "usa postgresql!")
        #expect(chat.skippedTransformations == ["my-personal-command"])
    }

    @Test("Pending iPhone terms are applied after synced vocabulary")
    func pendingTerms() {
        let bundle = SyncBundle(vocabulary: [VocabularyEntry(term: "Synced", soundsLike: ["sinked"])])
        let pending = [
            PendingVocabularyEntry(term: "Nuovo Termine", soundsLike: ["nuovo termin"]),
            PendingVocabularyEntry(term: "Other", soundsLike: ["sinked"]),
        ]
        let result = TextProcessor(bundle: bundle, pendingVocabulary: pending).process("sinked e nuovo termin")
        #expect(result.text == "Synced e Nuovo Termine")
    }
}

@Suite("Personal context corrections")
struct ContextualCorrectionTests {
    let rule = ContextualCorrection(heard: "零零二", replacement: "Linear", following: "上", context: "任务单")

    @Test func correctsChineseWithoutSpaces() {
        let p = TextProcessor(vocabulary: [], contextualCorrections: [rule])
        #expect(p.process("我们看一下我们零零二上的任务单还有哪些？").text == "我们看一下我们Linear上的任务单还有哪些？")
    }

    @Test func correctsObservedMixedLanguageVariantsOnlyWithContext() {
        let rules = ["Lin2", "Lin二", "002"].map {
            ContextualCorrection(heard: $0, replacement: "Linear", following: "上", context: "任务单")
        }
        let p = TextProcessor(vocabulary: [], contextualCorrections: rules)
        #expect(p.process("我们打开我们Lin2上的任务单。").text == "我们打开我们Linear上的任务单。")
        #expect(p.process("我们看一下我们Lin二上的任务单还有哪一些。").text == "我们看一下我们Linear上的任务单还有哪一些。")
        #expect(p.process("我们看一下我们 002上面的任务单。").text == "我们看一下我们 Linear上面的任务单。")
        #expect(p.process("编号002。").text == "编号002。")
        #expect(p.process("1002上的任务单。").text == "1002上的任务单。")
        #expect(p.process("Lin2上的数字").text == "Lin2上的数字")
        #expect(p.process("任务单 Lin二").text == "任务单 Lin二")
    }

    @Test func leavesUnrelatedNumbersAndAliasesAlone() {
        let p = TextProcessor(vocabulary: [VocabularyEntry(term: "OpenCode")], contextualCorrections: [rule])
        #expect(p.process("数字是零零二").text == "数字是零零二")
        #expect(p.process("零零二上的编号").text == "零零二上的编号")
        #expect(p.process("任务单编号零零二").text == "任务单编号零零二")
        #expect(p.process("用OpenCL进行计算").text == "用OpenCL进行计算")
    }
}
