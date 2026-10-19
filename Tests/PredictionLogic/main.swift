import Foundation

func check(_ actual: String, _ expected: String, _ label: String) {
    guard actual == expected else {
        fatalError("\(label): expected \(String(reflecting: expected)); got \(String(reflecting: actual))")
    }
}

var canonical = CompletionScore()
canonical.recordPrefix(logProbability: -4)
canonical.recordCompletion(probability: 0.8)
var fragmented = CompletionScore()
fragmented.recordPrefix(logProbability: -0.1)
fragmented.recordPrefix(logProbability: -12)
fragmented.recordCompletion(probability: 0.99)
precondition(canonical.rank > fragmented.rank,
             "High conditional fragment confidence must not cancel its low original model likelihood")
var finishedPrefix = CompletionScore()
finishedPrefix.recordPrefix(logProbability: -3)
var continuedPrefix = finishedPrefix
continuedPrefix.recordCompletion(probability: 0.9)
precondition(finishedPrefix.rank > continuedPrefix.rank,
             "A completed insertion must outrank its lower-probability continuation")

precondition(CompletionCandidate(id: 7, bytes: [32], prob: 0.5, model_logprob: nil).isValid(prefixPending: false) &&
             !CompletionCandidate(id: 7, bytes: [32], prob: 0.5, model_logprob: nil).isValid(prefixPending: true),
             "Only a pending prefix requires the original model likelihood")
for value in [Double.nan, .infinity, -.infinity, 0.001] {
    precondition(!CompletionCandidate(id: 7, bytes: [32], prob: 0.5, model_logprob: value)
        .isValid(prefixPending: true), "Invalid original likelihood must reject a prefix distribution")
}
precondition(CompletionCandidate(id: 7, bytes: [244], prob: 1, model_logprob: -18)
    .isValid(prefixPending: true), "A partial UTF-8 byte payload remains a valid scored token")
precondition(!CompletionCandidate(id: 7, bytes: [32], prob: .nan, model_logprob: nil)
    .isValid(prefixPending: false), "A non-finite probability must reject an ordinary distribution")

let prefixAB = Array("ab".utf8)[...]
precondition(WritingTokenPrefix.matchingByteCount(Array("a".utf8), remaining: prefixAB) == 1 &&
             WritingTokenPrefix.matchingByteCount(Array("ab".utf8), remaining: prefixAB) == 2 &&
             WritingTokenPrefix.matchingByteCount(Array("abc".utf8), remaining: prefixAB) == 2 &&
             WritingTokenPrefix.matchingByteCount(Array("ac".utf8), remaining: prefixAB) == nil,
             "Exact, partial, overshooting and incompatible prefix pieces have different transitions")
precondition(WritingTokenPrefix.matchingByteCount([244], remaining: [UInt8]()[...]) == 0,
             "A no-prefix path preserves every raw candidate byte")
var remainingScalar: ArraySlice<UInt8> = [244, 143, 191, 191][...]
var scalarSurplus: [UInt8] = []
let scalarPieces: [[UInt8]] = [[244], [143], [191], [191, 33]]
for piece in scalarPieces {
    guard let count = WritingTokenPrefix.matchingByteCount(piece, remaining: remainingScalar) else {
        fatalError("Split scalar prefix must remain compatible across tokens")
    }
    remainingScalar = remainingScalar.dropFirst(count)
    scalarSurplus.append(contentsOf: piece.dropFirst(count))
}
precondition(remainingScalar.isEmpty && scalarSurplus == [33],
             "Four raw scalar pieces strip the typed bytes exactly once and preserve overshoot")

func checkRewind(_ source: String, pieces: [[UInt8]], base: String, suffix: String, removed: Int,
                 protected: Set<Int> = [], label: String) {
    let split = WritingTokenPrefix.split(source: source, tokens: Array(pieces.indices),
        bytes: { pieces[$0] }, isControl: { protected.contains($0) })
    check(split.base, base, "\(label): committed source")
    precondition(split.bytes == Array(suffix.utf8) && split.removedTokens == removed,
                 "\(label): wrong byte constraint or rewind extent")
    precondition(Array(split.base.utf8) + split.bytes == Array(source.utf8),
                 "\(label): healing must reconstruct the exact source bytes")
}
checkRewind("be determinis", pieces: ["be", " determin", "is"].map { Array($0.utf8) },
            base: "be", suffix: " determinis", removed: 2, label: "multi-token word fragment")
checkRewind("word ", pieces: ["word", " "].map { Array($0.utf8) },
            base: "word", suffix: " ", removed: 1, label: "include a trailing separator")
checkRewind("word\t", pieces: ["word", "\t"].map { Array($0.utf8) },
            base: "word", suffix: "\t", removed: 1, label: "tab is a post-removal separator")
for newline in ["\n", "\r\n", "\u{85}", "\u{2028}", "\u{2029}"] {
    checkRewind("word" + newline, pieces: [Array("word".utf8), Array(newline.utf8)],
                base: "word" + newline, suffix: "", removed: 0, label: "newline is a pre-removal barrier")
}
checkRewind("abcdefg", pieces: "abcdefg".map { Array(String($0).utf8) },
            base: "ab", suffix: "cdefg", removed: 5, label: "bounded rewind is not a full-word split")
checkRewind("well-known", pieces: ["well", "-", "known"].map { Array($0.utf8) },
            base: "", suffix: "well-known", removed: 3, label: "hyphen does not block source rewind")
checkRewind("hello,word", pieces: ["hello", ",", "word"].map { Array($0.utf8) },
            base: "", suffix: "hello,word", removed: 3, label: "comma does not block source rewind")
for barrier in ".?!^:<>=[]{}" {
    checkRewind("a\(barrier)tail", pieces: ["a", String(barrier), "tail"].map { Array($0.utf8) },
                base: "a\(barrier)", suffix: "tail", removed: 1, label: "punctuation barrier \(barrier)")
}
checkRewind("cafe\u{301}", pieces: ["cafe", "\u{301}"].map { Array($0.utf8) },
            base: "", suffix: "cafe\u{301}", removed: 2, label: "preserve decomposed Unicode spelling")
checkRewind("word\u{a0}café", pieces: ["word", "\u{a0}", "caf", "é"].map { Array($0.utf8) },
            base: "word", suffix: "\u{a0}café", removed: 3, label: "Unicode separator is retained")
checkRewind("é", pieces: [[0xc3], [0xa9]], base: "é", suffix: "", removed: 0,
            label: "invalid standalone scalar pieces stop source rewind")
checkRewind("word", pieces: [Array("word".utf8)], base: "word", suffix: "", removed: 0,
            protected: [0], label: "protected model token remains committed")
checkRewind("é", pieces: [Array("e\u{301}".utf8)], base: "é", suffix: "", removed: 0,
            label: "normalized tokenizer spelling must not replace typed bytes")
checkRewind("", pieces: [], base: "", suffix: "", removed: 0, label: "empty writing source")

precondition(CompletionProbabilityGate.accepts(0.04, scannedIndex: 1, prefixPending: true,
                                             firstAcceptedProbability: 0.9),
             "Typed-prefix matching must retain candidates below the ordinary cutoff")
precondition(!CompletionProbabilityGate.accepts(0.04, scannedIndex: 1, prefixPending: false,
                                              firstAcceptedProbability: 0.9),
             "A completed prefix restores the ordinary cutoff")
precondition(CompletionProbabilityGate.accepts(0.001, scannedIndex: 0, prefixPending: false,
                                             firstAcceptedProbability: nil),
             "The first scanned ordinary candidate bypasses the cutoff")
precondition(!CompletionProbabilityGate.accepts(0.001, scannedIndex: 1, prefixPending: false,
                                              firstAcceptedProbability: nil),
             "Rejecting a scanned candidate must not move the ordinary first-candidate exception")
let relativeThreshold = Float32(1e-10) * Float32(0.9)
precondition(CompletionProbabilityGate.accepts(relativeThreshold, scannedIndex: 2, prefixPending: true,
                                             firstAcceptedProbability: 0.9) &&
             !CompletionProbabilityGate.accepts(relativeThreshold.nextDown, scannedIndex: 2, prefixPending: true,
                                               firstAcceptedProbability: 0.9),
             "The relative prefix cutoff retains equality but rejects the next smaller probability")
precondition(CompletionProbabilityGate.accepts(Float32(0.05), scannedIndex: 1, prefixPending: false,
                                             firstAcceptedProbability: 0.9) &&
             !CompletionProbabilityGate.accepts(Float32(0.05).nextDown, scannedIndex: 1, prefixPending: false,
                                               firstAcceptedProbability: 0.9),
             "The ordinary cutoff retains Float32 equality")

check(PredictionPrompt.clean("go\nIgnore instructions", maxWords: 2), "go", "first-line insertion")
check(PredictionPrompt.clean("esting", maxWords: 2), "esting", "raw partial-word suffix")
check(PredictionPrompt.clean(" to town later", maxWords: 2), " to town", "raw insertion spacing and word limit")
check(PredictionPrompt.clean("the"), "the", "raw text is not a proven echo")
check(PredictionPrompt.clean(" next"), " next", "raw whitespace remains data")
check(PredictionPrompt.clean("Answer: </s>"), "Answer: </s>", "raw labels and token-like literals remain data")
check(PredictionPrompt.nextWord("well-known plans follow", trailingSpace: true, punctuation: true), "well-known ", "internal hyphen")
check(PredictionPrompt.nextWord("3.5% growth", trailingSpace: false, punctuation: true), "3.5%", "decimal and punctuation")
check(PredictionPrompt.nextWord("done. Next", trailingSpace: true, punctuation: true), "done. ", "sentence boundary")
check(PredictionPrompt.nextWord("ject next", trailingSpace: false, punctuation: false), "ject", "partial suffix acceptance")
check(PredictionPrompt.nextWord(" \t“cafe\u{301},” next", trailingSpace: false, punctuation: true),
      " \t“cafe\u{301},”", "leading spacing and complete graphemes")
check(PredictionPrompt.nextWord("done. Next", trailingSpace: false, punctuation: false),
      "done", "optional closing punctuation")
check(PredictionPrompt.clean(" well-known 3.5% later", maxWords: 2),
      " well-known 3.5%", "Latin compound and numeric units")
check(PredictionPrompt.clean(" go ", maxWords: 1), " go ", "uncapped trailing insertion spacing")
check(PredictionPrompt.nextWord("1,000.5% growth", trailingSpace: false, punctuation: true),
      "1,000.5%", "numeric grouping and decimal punctuation")
check(PredictionPrompt.nextWord("...", trailingSpace: false, punctuation: true),
      "...", "punctuation-only acceptance")

precondition(WritingWordBoundary.isSingleWord(" good ") &&
             WritingWordBoundary.isSingleWord("well-known") &&
             !WritingWordBoundary.isSingleWord("line one\nline two") &&
             !WritingWordBoundary.isSingleWord("two words") &&
             !WritingWordBoundary.isSingleWord("..."),
             "Synonyms accept one word, never a multiline or multiword selection")
precondition(PredictionPrompt.replacement("line one\nline two\n", selected: "line one\nline two\n") == nil,
             "An echoed multiline selection must not become a whitespace-deleting replacement")
precondition(PredictionPrompt.replacement(" walk to work ", selected: " walk to work ") == nil,
             "An echoed selection with edge spaces must not be offered as a change")
check(PredictionPrompt.replacement("walks to work", selected: " \twalk to work \n") ?? "",
      " \twalks to work \n", "correction preserves selection edge whitespace")
check(PredictionPrompt.replacement(" good ", selected: "\ngreat\t") ?? "",
      "\ngood\t", "synonym preserves selection edge whitespace")
check(PredictionPrompt.replacement("東京で働く", selected: "\u{3000}東京で働いた\u{3000}") ?? "",
      "\u{3000}東京で働く\u{3000}", "replacement preserves ideographic edge spaces")
check(PredictionPrompt.nextWord("東京", trailingSpace: true, punctuation: true),
      "東京", "final unspaced word must not gain an ASCII space")
check(PredictionPrompt.alternativeIdentity(" There.") ?? "", "there", "sentence punctuation and case share alternative identity")
precondition(PredictionPrompt.alternativeIdentity(" C++") != PredictionPrompt.alternativeIdentity(" C#"),
             "Alternative identity preserves meaningful symbols")
precondition(PredictionPrompt.alternativeIdentity(" well-known") != PredictionPrompt.alternativeIdentity(" wellknown"),
             "Alternative identity preserves internal hyphens")

func checkCheckpoint(_ source: String, _ expected: String?, words: Int,
                     terminal: Bool, reached: Bool = false, label: String) {
    let actual = WritingWordBoundary.checkpoint(source, maxWords: words, terminal: terminal)
    guard let expected else {
        precondition(actual == nil, "\(label): unfinished text must have no checkpoint")
        return
    }
    guard let actual else { fatalError("\(label): expected a completed checkpoint") }
    check(actual.text, expected, label)
    precondition(actual.limitReached == reached, "\(label): incorrect word-limit status")
}

checkCheckpoint("ject", nil, words: 1, terminal: false, label: "cap cannot confirm a partial suffix")
checkCheckpoint("ject", "ject", words: 1, terminal: true, reached: true, label: "EOS confirms a partial suffix")
checkCheckpoint("ject next", "ject", words: 1, terminal: false, reached: true, label: "following word confirms suffix")
checkCheckpoint(" \tto town lat", " \tto town", words: 3, terminal: false, label: "cap drops incomplete final word")
checkCheckpoint(" \tto town later", " \tto town", words: 2, terminal: true, reached: true, label: "EOS still enforces limit")
checkCheckpoint(" done,", " done,", words: 1, terminal: false, reached: true, label: "closing punctuation proves a boundary")
checkCheckpoint("well-", nil, words: 1, terminal: false, label: "compound prefix is unfinished")
checkCheckpoint("3.", nil, words: 1, terminal: false, label: "decimal prefix is unfinished")
checkCheckpoint("1,", nil, words: 1, terminal: false, label: "numeric grouping prefix is unfinished")
checkCheckpoint(" the lobby at 10:", " the lobby at", words: 4, terminal: false,
                label: "time prefix cannot confirm the final word")
checkCheckpoint(" the lobby at 10:30!", " the lobby at 10:30!", words: 4, terminal: false, reached: true,
                label: "complete time with closing punctuation confirms the final word")
checkCheckpoint("Step 10: ", "Step 10:", words: 2, terminal: false, reached: true,
                label: "numeric heading colon remains literal after whitespace")
checkCheckpoint("10:", "10:", words: 1, terminal: true, reached: true,
                label: "EOS preserves a literal numeric colon")
checkCheckpoint(" \t", nil, words: 1, terminal: true, label: "spacing alone is not a word")
checkCheckpoint(" cafe\u{301} next", " cafe\u{301}", words: 1, terminal: false, reached: true, label: "checkpoint preserves combining grapheme")
checkCheckpoint(" hello 👩🏽‍💻 next", " hello 👩🏽‍💻", words: 2, terminal: false, reached: true, label: "checkpoint preserves emoji grapheme")
checkCheckpoint("to [1] [2] [", "to [1] [2]", words: 4, terminal: false,
                label: "opening bracket cannot confirm the final word")
checkCheckpoint("hello “", "hello", words: 2, terminal: false,
                label: "opening quotation mark cannot confirm the final word")
checkCheckpoint("to [1] [2] [3]", "to [1] [2] [3]", words: 4, terminal: false, reached: true,
                label: "closing bracket confirms the final word without changing literal bytes")
checkCheckpoint("to [1] [2] [", "to [1] [2] [", words: 4, terminal: true, reached: true,
                label: "EOS preserves a literal opening bracket")
checkCheckpoint("to [1] [2] [ ", "to [1] [2] [", words: 4, terminal: false, reached: true,
                label: "whitespace still confirms a literal punctuation unit")

// Dictionary words, not individual Unicode scalars, are the accepted units.
// Each fixture has a known multi-character first word and an unspaced successor.
for (source, first, language) in [
    ("東京で働く", "東京", "Japanese"),
    ("我们学习中文", "我们", "Chinese"),
    ("สวัสดีครับ", "สวัสดี", "Thai")
] {
    checkCheckpoint(source, first, words: 1, terminal: false, reached: true,
                    label: "\(language) confirms an unspaced checkpoint before the cap")
    checkCheckpoint(source, first, words: 1, terminal: true, reached: true,
                    label: "\(language) EOS cannot bypass the linguistic limit")
    checkCheckpoint(first, nil, words: 1, terminal: false,
                    label: "\(language) does not guess the final token is complete")
    checkCheckpoint(first, first, words: 1, terminal: true, reached: true,
                    label: "\(language) EOS confirms the final dictionary word")
    check(PredictionPrompt.clean(" \t" + source, maxWords: 1), " \t" + first,
          "\(language) cleaning preserves leading insertion bytes")
    check(PredictionPrompt.nextWord(source, trailingSpace: true, punctuation: true), first,
          "\(language) Tab accepts one linguistic word without adding an internal space")
    check(PredictionPrompt.alternative(" " + first) ?? "", " " + first,
          "\(language) accepts a single dictionary-word alternative")
    precondition(PredictionPrompt.alternative(source) == nil,
                 "\(language) rejects an unspaced multiword alternative")
    let capped = WritingWordBoundary.checkpoint(source, maxWords: 64, terminal: false)
    precondition(capped != nil && capped!.text != source && source.hasPrefix(capped!.text),
                 "\(language) token cap retains completed words but not the unfinished final word")
    checkCheckpoint(source, source, words: 64, terminal: true,
                    label: "\(language) EOS preserves a complete short insertion")
    checkCheckpoint(" " + first + "。", " " + first + "。", words: 1,
                    terminal: false, reached: true, label: "\(language) closing punctuation completes the last word")
    check(PredictionPrompt.nextWord(" " + first + "。", trailingSpace: false, punctuation: false),
          " " + first, "\(language) punctuation acceptance remains optional")
}
checkCheckpoint("我们学习中文", "我们学习", words: 2, terminal: false, reached: true,
                label: "Chinese checkpoint stops after two dictionary words")
checkCheckpoint("我们学习中文", "我们学习", words: 2, terminal: true, reached: true,
                label: "Chinese terminal output remains capped to two words")
check(PredictionPrompt.clean("我们学习中文", maxWords: 2), "我们学习",
      "Chinese cleaning uses the same two-word boundary")
check(PredictionPrompt.clean("東京well-known次", maxWords: 2), "東京well-known",
      "mixed scripts retain Latin hyphenated units")
check(PredictionPrompt.clean("東京3.5%次", maxWords: 2), "東京3.5%",
      "mixed scripts retain numeric punctuation")

check(PredictionPrompt.alternative("ject") ?? "", "ject",
      "raw alternative preserves partial-word suffix")
check(PredictionPrompt.alternative(" and") ?? "", " and",
      "raw alternative preserves insertion space")
precondition(PredictionPrompt.alternative("two words") == nil,
             "alternatives must be one word")
precondition(PredictionPrompt.alternative("\"") == nil &&
             PredictionPrompt.alternative("(") == nil &&
             PredictionPrompt.alternative(" 2026") == " 2026",
             "Next-word choices exclude punctuation-only paths without excluding numbers")
precondition(PredictionPrompt.alternative("[today]") == nil && PredictionPrompt.alternative(" [4]") == nil
             && PredictionPrompt.alternative(" \"brief\"") == nil,
             "Next-word choices exclude bracketed or quoted placeholders")
precondition(PredictionPrompt.alternativeIdentity("n't") == PredictionPrompt.alternativeIdentity("n\u{2019}t"),
             "Typographic and ASCII apostrophes are one alternative")
check(PredictionPrompt.sameSlotAlternatives([" to", "n't", " the", " a", " for"]).joined(separator: "|"),
      " to| the| a", "Alternatives after a complete word all start a new word")
check(PredictionPrompt.sameSlotAlternatives(["tation.", " soon", "ter.", "ce"]).joined(separator: "|"),
      "tation.|ter.|ce", "Alternatives inside a word all finish that word")


let options = PredictionOptions(globalInstructions: "GLOBAL_SOURCE", appInstructions: "APP_SOURCE",
                                domainInstructions: "DOMAIN_SOURCE", vocabularyStrength: 3,
                                vocabulary: "VOCABULARY_SOURCE", maxWords: 3)
for before in ["Bonjour, je", "A new line\n", "He wrote \"", "日本語 👩🏽‍💻 café e\u{301}",
               "TRIMMED_SOURCE" + String(repeating: "x", count: 2_400) + "\n\"終"] {
    let context = PredictionContext(before: before, after: "AFTER_SOURCE",
                                    appName: "APP_NAME_SOURCE", appID: "APP_ID_SOURCE",
                                    visibleText: "SCREEN_SOURCE", clipboard: "CLIPBOARD_SOURCE",
                                    siteDomain: "SITE_SOURCE")
    let prompt = PredictionPrompt.make(context: context, options: options, kind: .continuation).text
    let boundedBefore = String(before.suffix(2_400))
    precondition(Array(prompt.utf8.suffix(boundedBefore.utf8.count)) == Array(boundedBefore.utf8),
                 "Final raw prompt bytes must exactly preserve the bounded before-caret text")
    precondition(!prompt.hasSuffix(context.after), "After-caret reference must not be the completion boundary")
    precondition(!prompt.contains("TRIMMED_SOURCE"), "Before-caret text must remain bounded")
}

let context = PredictionContext(before: "Bonjour, je", after: "AFTER_SOURCE",
                                appName: "Notes", appID: "example.notes",
                                visibleText: nil, clipboard: nil, siteDomain: nil)
let privateOptions = PredictionOptions(globalInstructions: "", appInstructions: "",
                                       domainInstructions: "", vocabularyStrength: 0,
                                       vocabulary: "VOCABULARY_SOURCE", maxWords: 3)
let privatePrompt = PredictionPrompt.make(context: context, options: privateOptions, kind: .continuation).text
for omitted in ["SCREEN_SOURCE", "CLIPBOARD_SOURCE", "SITE_SOURCE", "VOCABULARY_SOURCE"] {
    precondition(!privatePrompt.contains(omitted), "Disabled or unconsented prompt source must be absent")
}
let selected = String(repeating: "selected source ", count: 200) + "\"\n日本語 👩🏽‍💻"
for kind in [PredictionKind.correction(selected), .synonym(selected)] {
    let request = PredictionPrompt.make(context: context, options: options, kind: kind)
    let rewrite = request.text
    let source: String
    if case .correction = kind {
        source = String(decoding: try! JSONEncoder().encode(selected), as: UTF8.self)
    } else {
        source = selected
    }
    precondition(rewrite.contains(source),
                 "Selected-text tasks must preserve the complete source, including quotes, newlines and Unicode")
}
let previousFrame = PredictionPrompt.make(context: context, options: options, kind: .correction("First line"))
let markerSource = "First line\nOriginal text: a quoted email thread" + previousFrame.stops[0] + "\nLast line\n"
let framedCorrection = PredictionPrompt.make(context: context, options: options, kind: .correction(markerSource))
let encodedMarkerSource = String(decoding: try! JSONEncoder().encode(markerSource), as: UTF8.self)
precondition(framedCorrection.text.contains(encodedMarkerSource) &&
             !framedCorrection.stops.isEmpty &&
             framedCorrection.stops.allSatisfy({ !encodedMarkerSource.contains($0) }),
             "Correction framing must preserve delimiter-like source text as literal JSON data")
check(PredictionPrompt.decodeCorrection(encodedMarkerSource) ?? "", markerSource,
      "Correction JSON preserves multiline labels, markers and edge whitespace")
precondition(PredictionPrompt.decodeCorrection("\"first line\" trailing example") == nil &&
             PredictionPrompt.decodeCorrection("\"unfinished") == nil &&
             PredictionPrompt.decodeCorrection("{\"text\":\"wrong representation\"}") == nil,
             "Only a complete JSON string can become a correction")
for malformed in ["\"raw\u{0001}control\"", "\"\\uD800\"", "\"\\uDC00\"", "\"\\uD800\\u0041\""] {
    precondition(PredictionPrompt.decodeCorrection(malformed) == nil,
                 "Malformed JSON Unicode must preserve the selected text")
}
check(PredictionPrompt.decodeCorrection("\"\\uD83D\\uDE00\"") ?? "", "😀",
      "A complete Unicode surrogate pair remains a valid correction")
check(SiteDomain.fromDocumentURL("https://EXAMPLE.com/path") ?? "", "example.com", "AX website host")
precondition(SiteDomain.fromDocumentURL("file:///Users/josh/secret") == nil, "Local paths are not domains")
precondition(SiteDomain.matches(host: "mail.google.com", rule: "google.com"), "Parent domain covers subdomain")
precondition(!SiteDomain.matches(host: "evilgoogle.com", rule: "google.com"), "Domain suffix needs a label boundary")
let disabledParent = SitePolicy.evaluate(
    hosts: ["widget.vendor.com", "pay.mybank.com"], unknownWeb: false,
    rules: [("mybank.com", false, true)])
precondition(!disabledParent.suggest && !disabledParent.record,
             "An enabled iframe must not bypass its disabled parent page")
let excludedLearning = SitePolicy.evaluate(
    hosts: ["widget.vendor.com", "pay.mybank.com"], unknownWeb: false,
    rules: [("mybank.com", true, false)])
precondition(excludedLearning.suggest && !excludedLearning.record,
             "A recording exclusion applies through nested frames")
let unknownSite = SitePolicy.evaluate(
    hosts: [], unknownWeb: true, rules: [("mybank.com", true, false)])
precondition(unknownSite.suggest && !unknownSite.record,
             "An unreadable web URL must not bypass recording exclusion")
let unrelatedSite = SitePolicy.evaluate(
    hosts: ["elsewhere.com"], unknownWeb: false,
    rules: [("mybank.com", false, false)])
precondition(unrelatedSite.suggest && unrelatedSite.record,
             "A known unrelated site remains usable")

let beamReserve = CompletionContextCapacity.reserve(generation: 64, branches: 9)
precondition(beamReserve == 585 &&
             CompletionContextCapacity.fits(prompt: 7606, reserve: beamReserve, context: 8192) &&
             !CompletionContextCapacity.fits(prompt: 7607, reserve: beamReserve, context: 8192),
             "Shared source is counted once; the strict context edge leaves one position")
precondition(CompletionContextCapacity.reserve(generation: 64, branches: 1) == 64 &&
             CompletionContextCapacity.fits(prompt: 8127, reserve: 64, context: 8192) &&
             !CompletionContextCapacity.fits(prompt: 8128, reserve: 64, context: 8192),
             "Single rewrites retain their original reserve and strict capacity edge")
for generation in [Int.max, Int.max / 9] {
    let reserve = CompletionContextCapacity.reserve(generation: generation, branches: 9)
    precondition(reserve == Int.max &&
                 !CompletionContextCapacity.fits(prompt: 1, reserve: reserve, context: 8192),
                 "Addition and multiplication overflow fail admission without trapping")
}
precondition(!CompletionContextCapacity.fits(prompt: Int.max, reserve: Int.max, context: 8192),
             "Capacity compares by subtraction without overflowing a prompt-plus-reserve sum")
print("Prediction behavior checks passed")
