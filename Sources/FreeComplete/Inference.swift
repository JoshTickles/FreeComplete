import Foundation

private enum InferenceError: LocalizedError {
    case missingModel, stopped, retryAfter(Int), invalidResponse, invalidTokenCount, invalidWordCount
    case capacity(prompt: Int, reserve: Int), incompleteReplacement

    var errorDescription: String? {
        switch self {
        case .missingModel: "Bundled model.gguf is missing. Rebuild the app."
        case .stopped: "Local inference was stopped."
        case .retryAfter(let seconds): "Local inference failed; retrying in \(seconds) seconds."
        case .invalidResponse: "Local inference returned an invalid result."
        case .invalidTokenCount: "The token count must be positive."
        case .invalidWordCount: "The word count must be positive."
        case let .capacity(prompt, reserve):
            "This request needs \(prompt) prompt tokens plus \(reserve) reserved context positions; the local model supports \(LocalInference.contextSize). Shorten the input or instructions."
        case .incompleteReplacement: "The local model did not finish a complete replacement. Your selected text was preserved."
        }
    }
}

/// Runs the bundled model in this process through llama.cpp, like a native app: no
/// helper process, no HTTP. Every model call runs on one serial queue, one search round
/// at a time, so a newer request waits at most one round and stale work stops early.
@MainActor final class LocalInference {
    private(set) var state = "Stopped"
    nonisolated static let contextSize = Int(LlamaEngine.contextSize)

    private nonisolated static let queue = DispatchQueue(label: "app.freecomplete.llama", qos: .userInteractive)
    /// The serial queue owns native resources, even while a load result is still
    /// waiting for the main actor. Tasks may retain the Swift engine after stop.
    private final class ModelSession: @unchecked Sendable {
        var engine: LlamaEngine?
        var stopped = false

        func load(_ path: String) throws -> LlamaEngine {
            guard !stopped else { throw CancellationError() }
            if let engine { return engine }
            let loaded = try LlamaEngine(modelPath: path)
            engine = loaded
            return loaded
        }

        func stop() {
            stopped = true
            engine?.close()
            engine = nil
        }
    }

    private var session = ModelSession()
    private var modelTask: Task<LlamaEngine, Error>?
    private var consecutiveFailures = 0
    private var nextAttempt = Date.distantPast

    /// Loads the model ahead of the first request.
    func prepare() async {
        _ = try? await ready()
    }

    func stop() {
        let stoppedSession = session
        session = ModelSession()
        modelTask?.cancel()
        modelTask = nil
        // Termination cannot leave teardown queued behind process exit. Drain native
        // work and close resources before returning, including a just-finished load.
        Self.queue.sync { stoppedSession.stop() }
        state = "Stopped"
        consecutiveFailures = 0
        nextAttempt = .distantPast
    }

    private func ready() async throws -> LlamaEngine {
        if Date() < nextAttempt {
            throw InferenceError.retryAfter(max(1, Int(nextAttempt.timeIntervalSinceNow.rounded(.up))))
        }
        try Task.checkCancellation()
        let session = self.session
        if modelTask == nil {
            var model = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/model.gguf")
            #if DEBUG
            // Explicit development-only override; release bundles always use their own model.
            if let path = ProcessInfo.processInfo.environment["FREECOMPLETE_MODEL"] { model = URL(fileURLWithPath: path) }
            #endif
            guard FileManager.default.fileExists(atPath: model.path) else { throw InferenceError.missingModel }
            state = "Loading model"
            let path = model.path
            modelTask = Task { try await Self.onQueue { try session.load(path) } }
        }
        guard let pending = modelTask else { throw InferenceError.stopped }
        do {
            let loaded = try await pending.value
            guard self.session === session else { throw CancellationError() }
            try Task.checkCancellation()
            state = "Ready"
            consecutiveFailures = 0
            return loaded
        } catch {
            guard self.session === session else { throw CancellationError() }
            if error is CancellationError { throw error }
            modelTask = nil
            consecutiveFailures += 1
            nextAttempt = Date().addingTimeInterval(min(60, pow(2, Double(consecutiveFailures))))
            state = "Model failed to load"
            throw error
        }
    }

    private nonisolated static func onQueue<T>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try body() }) }
        }
    }

    private func run<T>(_ engine: LlamaEngine, _ body: @escaping @Sendable (LlamaEngine) throws -> T) async throws -> T {
        try Task.checkCancellation()
        let session = self.session
        let value = try await Self.onQueue {
            guard !session.stopped, session.engine === engine else { throw CancellationError() }
            return try body(engine)
        }
        try Task.checkCancellation()
        guard self.session === session else { throw CancellationError() }
        return value
    }

    func generate(prompt request: PredictionRequest, maxTokens: Int? = nil, maxWords: Int, kind: PredictionKind) async throws -> String {
        if let maxTokens, maxTokens <= 0 { throw InferenceError.invalidTokenCount }
        guard maxWords > 0 else { throw InferenceError.invalidWordCount }
        try Task.checkCancellation()
        let session = self.session
        let engine = try await ready()
        let prompt: String
        var tokenPrefix: [UInt8] = []
        var prefixTokenCount = 0
        switch kind {
        case .continuation, .alternatives:
            if let writing = request.writing {
                let source = try await run(engine) { try $0.tokenize(writing, addSpecial: false) }
                let split = WritingTokenPrefix.split(source: writing, tokens: source,
                    bytes: { engine.pieceBytes(Int($0)) }, isControl: { Self.gemmaControlIDs.contains(Int($0)) })
                prompt = request.prefix + split.base
                tokenPrefix = split.bytes
                prefixTokenCount = split.removedTokens
            } else {
                prompt = request.text
            }
        case .synonym, .correction:
            prompt = request.text
        }
        // Add only the model BOS and parse special-looking user text literally.
        // Every expansion appends original token IDs, never retokenized generated bytes.
        let promptTokens = try await run(engine) { try $0.tokenize(prompt, addSpecial: true) }
        guard !promptTokens.isEmpty else { throw InferenceError.invalidResponse }
        let generationReserve: Int
        switch kind {
        case .continuation, .alternatives:
            guard let maxTokens else { throw InferenceError.invalidTokenCount }
            guard maxTokens <= Int.max - prefixTokenCount else {
                throw InferenceError.capacity(prompt: promptTokens.count, reserve: Int.max)
            }
            generationReserve = maxTokens + prefixTokenCount
        case .synonym:
            generationReserve = 32
        case .correction:
            guard let encoded = request.correctionJSON else { throw InferenceError.invalidResponse }
            let selection = try await run(engine) { try $0.tokenize(encoded, addSpecial: false) }
            generationReserve = selection.count + max(64, selection.count / 2)
        }
        let branches: Int
        switch kind {
        case .continuation, .alternatives: branches = 9
        case .synonym, .correction: branches = 1
        }
        let aggregateReserve = CompletionContextCapacity.reserve(generation: generationReserve, branches: branches)
        // Preserve all caller text and leave one additional context position.
        guard CompletionContextCapacity.fits(prompt: promptTokens.count, reserve: aggregateReserve,
                                             context: Self.contextSize) else {
            throw InferenceError.capacity(prompt: promptTokens.count, reserve: aggregateReserve)
        }
        let text: String
        switch kind {
        case .continuation, .alternatives:
            let alternatives: Bool
            if case .alternatives = kind { alternatives = true } else { alternatives = false }
            let results = try await rankedCompletions(engine, tokens: promptTokens.map(Int.init), tokenPrefix: tokenPrefix,
                                                      maxTokens: generationReserve,
                                                      maxWords: alternatives ? 1 : maxWords, distinctWords: alternatives)
            text = alternatives
                ? PredictionPrompt.sameSlotAlternatives(results.map(\.text)).joined(separator: "\n")
                : results.first?.text ?? ""
        case .synonym, .correction:
            let stops = request.stops
            let completion = try await run(engine) { try $0.greedy(promptTokens, maxTokens: generationReserve, stops: stops) }
            guard completion.stop == .eos || completion.stop == .word else { throw InferenceError.incompleteReplacement }
            if case .synonym = kind {
                let replacement = completion.text.trimmingCharacters(in: .whitespacesAndNewlines)
                // Reject an overlong phrase instead of silently cutting a replacement.
                guard !replacement.contains(where: \.isNewline),
                      replacement.split(whereSeparator: \.isWhitespace).count <= 4 else {
                    throw InferenceError.incompleteReplacement
                }
                text = completion.text
            } else {
                guard let replacement = PredictionPrompt.decodeCorrection(completion.text) else {
                    throw InferenceError.incompleteReplacement
                }
                text = replacement
            }
        }
        try Task.checkCancellation()
        guard self.session === session else { throw CancellationError() }
        return text
    }

    // Independent bounded beam design. Width nine and phase-specific gates follow
    // observed selector evidence. Cumulative ordinary log probability follows the
    // observed rank choice; top twenty, original prefix likelihood, ties and word
    // delivery remain our policies, not complete target-search parity.
    private func rankedCompletions(_ engine: LlamaEngine, tokens: [Int], tokenPrefix: [UInt8], maxTokens: Int,
                                   maxWords: Int, distinctWords: Bool) async throws -> [RankedInsertion] {
        var frontier = [SearchSequence(tokens: tokens, requiredPrefix: tokenPrefix)]
        var finished: [RankedInsertion] = []
        for depth in 0..<maxTokens {
            let sequences = frontier.map { $0.tokens.map(Int32.init) }
            let prefixes = frontier.map { Array($0.requiredPrefix.dropFirst($0.matchedPrefix)) }
            // One batched decode evaluates every branch of this round.
            let distributions = try await run(engine) { try $0.next(sequences, prefixes: prefixes) }
            var expanded: [SearchSequence] = []
            for (frontierIndex, sequence) in frontier.enumerated() {
                let expandedStart = expanded.count
                let finishedStart = finished.count
                let prefixPending = sequence.matchedPrefix < sequence.requiredPrefix.count
                let distribution = distributions[frontierIndex].map {
                    CompletionCandidate(id: $0.id, bytes: $0.bytes, prob: $0.prob, model_logprob: $0.modelLogprob)
                }
                guard !distribution.isEmpty, distribution.allSatisfy({ $0.isValid(prefixPending: prefixPending) }) else {
                    throw InferenceError.invalidResponse
                }
                let sorted = distribution.sorted {
                    $0.prob == $1.prob ? $0.id < $1.id : $0.prob > $1.prob
                }
                let total = sorted.reduce(Float32(0)) { $0 + $1.prob }
                guard total.isFinite, total > 0 else { throw InferenceError.invalidResponse }
                var firstAcceptedProbability: Float32?
                // Alternatives exist to offer what the 0.05 gate would hide: the first word
                // choice considers the whole retained top twenty, ranked by score.
                let choosingAlternative = distinctWords && !prefixPending && sequence.bytes.isEmpty
                for (index, token) in sorted.enumerated() {
                    let probability = token.prob / total
                    guard choosingAlternative || CompletionProbabilityGate.accepts(probability, scannedIndex: index,
                        prefixPending: prefixPending, firstAcceptedProbability: firstAcceptedProbability) else { break }
                    var next = sequence
                    if prefixPending {
                        guard let modelLogProbability = token.model_logprob else {
                            throw InferenceError.invalidResponse
                        }
                        next.score.recordPrefix(logProbability: modelLogProbability)
                    } else {
                        next.score.recordCompletion(probability: probability)
                    }
                    if Self.gemmaControlIDs.contains(token.id) || token.bytes.isEmpty {
                        if let result = next.insertion(terminal: true, maxWords: maxWords) {
                            finished.append(result)
                        }
                        continue
                    }
                    guard let skipped = WritingTokenPrefix.matchingByteCount(token.bytes,
                        remaining: sequence.requiredPrefix.dropFirst(sequence.matchedPrefix)) else {
                        throw InferenceError.invalidResponse
                    }
                    let carriesSpace = token.bytes.contains(0x20)
                    let repeatsLast = sequence.tokens.last == token.id
                    let repeatsPair = sequence.tokens.count >= 2 && sequence.tokens[sequence.tokens.count - 2] == token.id
                    guard prefixPending || !(repeatsLast && (repeatsPair || carriesSpace)) else { continue }
                    if firstAcceptedProbability == nil { firstAcceptedProbability = probability }
                    next.tokens.append(token.id)
                    next.matchedPrefix += skipped
                    next.bytes.append(contentsOf: token.bytes.dropFirst(skipped))
                    // Newline is an ASCII byte and cannot occur inside a UTF-8 scalar.
                    if let newline = next.bytes.firstIndex(where: { $0 == 0x0a || $0 == 0x0d }) {
                        next.bytes.removeSubrange(newline...)
                        if let result = next.insertion(terminal: true, maxWords: maxWords) {
                            finished.append(result)
                        }
                    } else if next.updateBoundary(maxWords: maxWords) {
                        if let result = next.checkpoint { finished.append(result) }
                    } else if depth == maxTokens - 1 {
                        // A token budget is not evidence that the final word is complete.
                        if let result = next.checkpoint { finished.append(result) }
                    } else {
                        expanded.append(next)
                    }
                }
                if expanded.count == expandedStart, finished.count == finishedStart,
                   let result = sequence.checkpoint {
                    // A fully suppressed branch may still have a complete-word prefix.
                    finished.append(result)
                }
            }
            // Stable lexicographic token tie-breaking is our policy, not target tie parity.
            // Pending and prefix-complete paths share the same bounded beam. Partial costs can
            // displace viable completed-prefix paths; this is not an exact prefix marginalization.
            expanded.sort {
                $0.rank == $1.rank ? $0.tokens.lexicographicallyPrecedes($1.tokens) : $0.rank > $1.rank
            }
            frontier = Array(expanded.prefix(9))
            finished.sort(by: Self.betterInsertion)
            // Preserve distinct alternatives before bounding completed results. A
            // continuation must contain a letter or digit: a lone ":" or "." before a
            // line break otherwise wins the summed score over every real phrase.
            var seen = Set<String>()
            finished = Array(finished.filter {
                let identity = distinctWords ? PredictionPrompt.alternativeIdentity($0.text)
                    : ($0.text.contains(where: { $0.isLetter || $0.isNumber }) ? $0.text : nil)
                guard let identity else { return false }
                return seen.insert(identity).inserted
            }.prefix(distinctWords ? 18 : 9))
            if frontier.isEmpty { break }
            // Every remaining prefix/completion increment is nonpositive. A
            // strictly better completed result cannot be overtaken by descendants.
            // Keep equal scores alive for deterministic tie-breaking.
            // Alternatives settle on three choices for the best result's slot (new word or
            // word ending); choices for the other slot are dropped and must not count.
            let sameSlot = distinctWords ? PredictionPrompt.sameSlotAlternatives(finished.map(\.text)) : []
            let settledScore = distinctWords
                ? (sameSlot.count >= 3 ? finished.first(where: { $0.text == sameSlot[2] })?.score : nil)
                : finished.first?.score
            if let settledScore, let bestActive = frontier.first,
               settledScore > bestActive.rank { break }
        }
        return finished.sorted(by: Self.betterInsertion)
    }

    private static func betterInsertion(_ lhs: RankedInsertion, _ rhs: RankedInsertion) -> Bool {
        lhs.score == rhs.score ? lhs.text < rhs.text : lhs.score > rhs.score
    }

    // Public google/gemma-4-E2B tokenizer.json added_tokens (including EOS=1).
    // These are IDs of known control tokens, never a heuristic on "<..." text.
    private static let gemmaControlIDs: Set<Int> = [
        0, 1, 2, 3, 4, 46, 47, 48, 49, 50, 51, 52, 98, 100, 101, 105, 106,
        255999, 256000, 258880, 258881, 258882, 258883, 258884
    ]

    private struct RankedInsertion {
        let text: String
        let score: Double
    }

    private struct SearchSequence {
        var tokens: [Int]
        let requiredPrefix: [UInt8]
        var matchedPrefix = 0
        var bytes: [UInt8] = []
        var score = CompletionScore()
        var checkpointText: String?
        var checkpointBytes = 0
        var rank: Double { score.rank }
        var checkpoint: RankedInsertion? {
            guard let checkpointText else { return nil }
            return RankedInsertion(text: checkpointText, score: rank)
        }

        // Linguistic checkpoints share word units with Tab acceptance and alternatives.
        // A token cap never confirms the unfinished last word.
        mutating func updateBoundary(maxWords: Int) -> Bool {
            guard let text = validPrefix,
                  let complete = WritingWordBoundary.checkpoint(text, maxWords: maxWords, terminal: false) else {
                return false
            }
            let count = complete.text.utf8.count
            if count > checkpointBytes {
                checkpointText = complete.text
                checkpointBytes = count
            }
            return complete.limitReached
        }

        mutating func insertion(terminal: Bool, maxWords: Int) -> RankedInsertion? {
            guard matchedPrefix == requiredPrefix.count,
                  let text = String(bytes: bytes, encoding: .utf8),
                  let complete = WritingWordBoundary.checkpoint(text, maxWords: maxWords, terminal: terminal) else {
                return checkpoint
            }
            return RankedInsertion(text: complete.text, score: rank)
        }

        // Inspect a valid prefix without replacing or losing any pending UTF-8 bytes.
        // A split scalar can leave at most three trailing bytes awaiting its next token.
        private var validPrefix: String? {
            if let text = String(bytes: bytes, encoding: .utf8) { return text }
            guard !bytes.isEmpty else { return nil }
            for pending in 1...min(3, bytes.count) {
                if let text = String(bytes: bytes.dropLast(pending), encoding: .utf8) { return text }
            }
            return nil
        }
    }
}
