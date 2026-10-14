import Foundation
import Darwin

private enum InferenceError: LocalizedError {
    case missingRunner, missingModel, noPort, stopped, launch(String), retryAfter(Int)
    case exited(Int32), timedOut, invalidIdentity, invalidResponse, http(Int), invalidTokenCount, invalidWordCount
    case capacity(prompt: Int, reserve: Int), incompleteReplacement

    var errorDescription: String? {
        switch self {
        case .missingRunner: "Bundled llama-server is missing or not executable. Rebuild the app."
        case .missingModel: "Bundled model.gguf is missing. Rebuild the app."
        case .noPort: "Could not allocate a local inference port."
        case .stopped: "Local inference was stopped."
        case .launch(let detail): "Could not start local inference: \(detail)"
        case .retryAfter(let seconds): "Local inference failed; retrying in \(seconds) seconds."
        case .exited(let status): "Local inference exited with status \(status)."
        case .timedOut: "Timed out while loading the local model."
        case .invalidIdentity: "The local inference endpoint did not identify as this app's child."
        case .invalidResponse: "Local inference returned an invalid response."
        case .http(let status): "Local inference returned HTTP \(status)."
        case .invalidTokenCount: "The token count must be positive."
        case .invalidWordCount: "The word count must be positive."
        case let .capacity(prompt, reserve):
            "This request needs \(prompt) prompt tokens plus \(reserve) reserved context positions; the local model supports \(LocalInference.contextSize). Shorten the input or instructions."
        case .incompleteReplacement: "The local model did not finish a complete replacement. Your selected text was preserved."
        }
    }
}

/// Owns one authenticated, loopback-only llama-server. The app never discovers or reuses other servers.
@MainActor final class LocalInference {
    private(set) var state = "Stopped"
    nonisolated static let contextSize = 8192

    private var child: Process?
    private var session: URLSession?
    private var startup: Task<Void, Error>?
    private var startupID: UUID?
    private var endpoint: URL?
    private var key: String?
    private var alias: String?
    private var runnerPath: String?
    private var consecutiveFailures = 0
    private var nextAttempt = Date.distantPast
    private var runID: UUID?

    deinit {
        session?.invalidateAndCancel()
        if child?.isRunning == true { child?.terminate() }
    }

    private static let supervisorScript = """
        expected=$1
        shift
        # A changed parent ID cannot become the original parent again, even if its PID is reused.
        [ "$(ps -o ppid= -p "$$")" -eq "$expected" ] 2>/dev/null || exit 1
        server=
        cleanup() {
            # TERM may arrive between starting the background job and assigning $!.
            [ -n "$server" ] || server=$(jobs -p)
            [ -n "$server" ] || return 0
            # Never signal a reused PID: only the wrapper's own live child may be killed.
            [ "$(ps -o ppid= -p "$server")" -eq "$$" ] 2>/dev/null &&
                kill -KILL "$server" 2>/dev/null
            wait "$server"
        }
        trap 'cleanup; exit 0' TERM INT
        "$@" >/dev/null 2>&1 &
        server=$!
        while [ "$(ps -o ppid= -p "$$")" -eq "$expected" ] 2>/dev/null &&
              [ "$(ps -o ppid= -p "$server")" -eq "$$" ] 2>/dev/null; do
            sleep 1
        done
        cleanup
        """

    /// Starts and loads the runtime ahead of the first request. Failures surface on
    /// the next real request through the normal retry and status path.
    func prepare() async {
        try? await ensureReady()
    }

    func generate(prompt request: PredictionRequest, maxTokens: Int? = nil, maxWords: Int, kind: PredictionKind) async throws -> String {
        if let maxTokens, maxTokens <= 0 { throw InferenceError.invalidTokenCount }
        guard maxWords > 0 else { throw InferenceError.invalidWordCount }
        try Task.checkCancellation()
        try await ensureReady()
        try Task.checkCancellation()
        guard let child, child.isRunning, let session, let endpoint, let key, let runnerPath else {
            throw InferenceError.stopped
        }
        let connection = Connection(child: child, session: session, endpoint: endpoint, key: key, runnerPath: runnerPath)
        let prompt: String
        var tokenPrefix: [UInt8] = []
        var prefixTokenCount = 0
        switch kind {
        case .continuation, .alternatives:
            if let writing = request.writing {
                let source: Tokenization = try await post("tokenize", body: [
                    "content": writing, "add_special": false, "parse_special": false, "with_pieces": true
                ], connection: connection)
                let split = WritingTokenPrefix.split(source: writing, tokens: source.tokens,
                    bytes: { $0.bytes }, isControl: { Self.gemmaControlIDs.contains($0.id) })
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
        let tokenized: Tokenization = try await post("tokenize", body: [
            "content": prompt, "add_special": true, "parse_special": false, "with_pieces": true
        ], connection: connection)
        guard !tokenized.tokens.isEmpty else { throw InferenceError.invalidResponse }
        let generationReserve: Int
        switch kind {
        case .continuation, .alternatives:
            guard let maxTokens else { throw InferenceError.invalidTokenCount }
            guard maxTokens <= Int.max - prefixTokenCount else {
                throw InferenceError.capacity(prompt: tokenized.tokens.count, reserve: Int.max)
            }
            generationReserve = maxTokens + prefixTokenCount
        case .synonym:
            generationReserve = 32
        case .correction:
            guard let encoded = request.correctionJSON else { throw InferenceError.invalidResponse }
            let selection: Tokenization = try await post("tokenize", body: [
                "content": encoded, "add_special": false, "parse_special": false, "with_pieces": true
            ], connection: connection)
            generationReserve = selection.tokens.count + max(64, selection.tokens.count / 2)
        }
        let branches: Int
        switch kind {
        case .continuation, .alternatives: branches = 9
        case .synonym, .correction: branches = 1
        }
        let aggregateReserve = CompletionContextCapacity.reserve(generation: generationReserve, branches: branches)
        // Preserve all caller text and leave one additional context position.
        guard CompletionContextCapacity.fits(prompt: tokenized.tokens.count, reserve: aggregateReserve,
                                             context: Self.contextSize) else {
            throw InferenceError.capacity(prompt: tokenized.tokens.count, reserve: aggregateReserve)
        }
        let promptTokens = tokenized.tokens.map(\.id)
        let text: String
        switch kind {
        case .continuation, .alternatives:
            let wordLimit: Int
            let distinctWords: Bool
            if case .alternatives = kind {
                wordLimit = 1
                distinctWords = true
            } else {
                wordLimit = maxWords
                distinctWords = false
            }
            let results = try await rankedCompletions(tokens: promptTokens, tokenPrefix: tokenPrefix,
                                                      maxTokens: generationReserve, maxWords: wordLimit,
                                                      distinctWords: distinctWords, connection: connection)
            if case .alternatives = kind {
                text = results.prefix(3).map(\.text).joined(separator: "\n")
            } else {
                text = results.first?.text ?? ""
            }
        case .synonym, .correction:
            var body: [String: Any] = [
                "prompt": promptTokens, "n_predict": generationReserve,
                "top_k": 1, "samplers": ["top_k"], "stream": false
            ]
            if !request.stops.isEmpty { body["stop"] = request.stops }
            let completion: RawCompletion = try await post("completion", body: body, connection: connection)
            guard !completion.truncated, completion.stop_type == .eos || completion.stop_type == .word else {
                throw InferenceError.incompleteReplacement
            }
            if case .synonym = kind {
                let replacement = completion.content.trimmingCharacters(in: .whitespacesAndNewlines)
                // Reject an overlong phrase instead of silently cutting a replacement.
                guard !replacement.contains(where: \.isNewline),
                      replacement.split(whereSeparator: \.isWhitespace).count <= 4 else {
                    throw InferenceError.incompleteReplacement
                }
                text = completion.content
            } else {
                guard let replacement = PredictionPrompt.decodeCorrection(completion.content) else {
                    throw InferenceError.incompleteReplacement
                }
                text = replacement
            }
        }
        try Task.checkCancellation()
        consecutiveFailures = 0
        nextAttempt = .distantPast
        return text
    }

    private struct Connection {
        let child: Process
        let session: URLSession
        let endpoint: URL
        let key: String
        let runnerPath: String
    }

    private func verify(_ connection: Connection) throws {
        guard connection.child === child, connection.child.isRunning,
              connection.endpoint == endpoint else { throw InferenceError.stopped }
        guard Self.ownsListener(supervisor: connection.child.processIdentifier,
                                runnerPath: connection.runnerPath,
                                port: UInt16(connection.endpoint.port ?? 0)) else {
            let error = InferenceError.invalidIdentity
            halt()
            recordFailure(error)
            throw error
        }
    }

    private func post<Response: Decodable>(_ path: String, body: [String: Any],
                                           connection: Connection) async throws -> Response {
        try Task.checkCancellation()
        try verify(connection)
        var request = URLRequest(url: connection.endpoint.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(connection.key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await connection.session.data(for: request)
        } catch {
            try Task.checkCancellation()
            throw error
        }
        try Task.checkCancellation()
        try verify(connection)
        guard let response = response as? HTTPURLResponse else { throw InferenceError.invalidResponse }
        guard response.statusCode == 200 else { throw InferenceError.http(response.statusCode) }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    // Independent bounded beam design. Width nine and phase-specific gates follow
    // observed selector evidence. Cumulative ordinary log probability follows the
    // observed rank choice; top twenty, original prefix likelihood, ties and word
    // delivery remain our policies, not complete target-search parity.
    private func rankedCompletions(tokens: [Int], tokenPrefix: [UInt8], maxTokens: Int, maxWords: Int,
                                   distinctWords: Bool, connection: Connection) async throws -> [RankedInsertion] {
        var frontier = [SearchSequence(tokens: tokens, requiredPrefix: tokenPrefix)]
        var finished: [RankedInsertion] = []
        for depth in 0..<maxTokens {
            try Task.checkCancellation()
            let groups = CompletionRequestGroup.make(remainingPrefixes: frontier.lazy.map {
                $0.requiredPrefix.dropFirst($0.matchedPrefix)
            })
            var completions = [RankedCompletion?](repeating: nil, count: frontier.count)
            for group in groups {
                try Task.checkCancellation()
                let prompts = group.frontierIndices.map { frontier[$0].tokens }
                var body: [String: Any] = [
                    "prompt": prompts.count == 1 ? prompts[0] as Any : prompts as Any,
                    "share_prompt": prompts.count >= 2, "cache_prompt": true,
                    "n_predict": 1, "top_k": 20,
                    "samplers": ["top_k"], "n_probs": 20, "post_sampling_probs": true,
                    // Original token IDs and bytes never enter a text serializer.
                    "response_fields": ["index", "completion_probabilities"],
                    "stream": false, "seed": 0, "backend_sampling": false
                ]
                if !group.remainingPrefix.isEmpty {
                    body["token_prefix"] = Array(group.remainingPrefix)
                    body["model_logprobs"] = true
                }
                let response: CompletionGroupResponse = try await post("completion", body: body, connection: connection)
                do { try response.store(in: &completions, for: group) }
                catch { throw InferenceError.invalidResponse }
            }
            var expanded: [SearchSequence] = []
            for (frontierIndex, sequence) in frontier.enumerated() {
                let expandedStart = expanded.count
                let finishedStart = finished.count
                let prefixPending = sequence.matchedPrefix < sequence.requiredPrefix.count
                guard let completion = completions[frontierIndex] else { throw InferenceError.invalidResponse }
                // The selected output/content is deliberately ignored. llama.cpp applies
                // top_k then Float32 softmax; normalize its retained array in Float32.
                guard let distribution = completion.completion_probabilities.first?.top_probs,
                      !distribution.isEmpty, distribution.count <= 20,
                      distribution.allSatisfy({ $0.isValid(prefixPending: prefixPending) }) else {
                    throw InferenceError.invalidResponse
                }
                let sorted = distribution.sorted {
                    $0.prob == $1.prob ? $0.id < $1.id : $0.prob > $1.prob
                }
                let total = sorted.reduce(Float32(0)) { $0 + $1.prob }
                guard total.isFinite, total > 0 else { throw InferenceError.invalidResponse }
                var firstAcceptedProbability: Float32?
                for (index, token) in sorted.enumerated() {
                    let probability = token.prob / total
                    guard CompletionProbabilityGate.accepts(probability, scannedIndex: index,
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
            }.prefix(9))
            if frontier.isEmpty { break }
            // Every remaining prefix/completion increment is nonpositive. A
            // strictly better completed result cannot be overtaken by descendants.
            // Keep equal scores alive for deterministic tie-breaking.
            let settledScore = distinctWords
                ? (finished.count >= 3 ? finished[2].score : nil)
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

    func stop() {
        startup?.cancel()
        startupID = nil
        startup = nil
        halt()
        state = "Stopped"
        consecutiveFailures = 0
        nextAttempt = .distantPast
    }

    private func ensureReady() async throws {
        if child?.isRunning == true, session != nil, startup == nil, state == "Ready" { return }
        if Date() < nextAttempt {
            throw InferenceError.retryAfter(max(1, Int(nextAttempt.timeIntervalSinceNow.rounded(.up))))
        }
        if startup == nil {
            // Shared startup prevents overlapping launches when several fields request a completion.
            let id = UUID()
            startupID = id
            startup = Task {
                do {
                    try await launchAndWait()
                } catch {
                    // An older, cancelled startup must not terminate a replacement child.
                    if startupID == id {
                        halt()
                        if !Task.isCancelled { recordFailure(error) }
                    }
                    throw error
                }
            }
        }
        guard let pending = startup, let id = startupID else { throw InferenceError.stopped }
        do {
            try await pending.value
            if startupID == id { startup = nil; startupID = nil }
            if child?.isRunning != true {
                let error = InferenceError.stopped
                halt()
                recordFailure(error)
                throw error
            }
        } catch {
            if startupID == id { startup = nil; startupID = nil }
            throw error
        }
    }

    private func launchAndWait() async throws {
        try Task.checkCancellation()
        let fm = FileManager.default
        let bundle = Bundle.main.bundleURL
        var runner = bundle.appendingPathComponent("Contents/MacOS/llama-server")
        var model = bundle.appendingPathComponent("Contents/Resources/model.gguf")
        #if DEBUG
        // Explicit development-only overrides; release bundles always use their own assets.
        if let path = ProcessInfo.processInfo.environment["FREECOMPLETE_RUNNER"] { runner = URL(fileURLWithPath: path) }
        if let path = ProcessInfo.processInfo.environment["FREECOMPLETE_MODEL"] { model = URL(fileURLWithPath: path) }
        #endif
        guard fm.isExecutableFile(atPath: runner.path) else { throw InferenceError.missingRunner }
        guard fm.fileExists(atPath: model.path) else { throw InferenceError.missingModel }

        let port = try Self.availablePort()
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let modelAlias = "freecomplete-\(UUID().uuidString)"
        let id = UUID()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", Self.supervisorScript, "freecomplete-supervisor", String(getpid()), runner.path,
            "--model", model.path, "--host", "127.0.0.1", "--port", String(port),
            "--alias", modelAlias, "--ctx-size", String(Self.contextSize), "--parallel", "9",
            "--kv-unified", "--swa-full", "--no-context-shift", "--cache-ram", "1024", "--cache-idle-slots",
            "--no-ui", "--no-mmproj", "--offline", "--reasoning", "off",
            "--cors-origins", "localhost", "--no-cors-credentials", "--log-disable"
        ]
        let original = ProcessInfo.processInfo.environment
        process.environment = [
            "HOME": original["HOME"] ?? NSHomeDirectory(),
            "TMPDIR": original["TMPDIR"] ?? NSTemporaryDirectory(),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "en_US.UTF-8",
            "LLAMA_API_KEY": token
        ]
        // Do not accumulate prompts or block on a full pipe.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self, weak process] _ in
            Task { @MainActor [weak self, weak process] in
                guard let self, let process, self.child === process else { return }
                if self.startup == nil {
                    self.halt()
                    self.recordFailure(InferenceError.exited(process.terminationStatus))
                } else {
                    self.session?.invalidateAndCancel()
                    self.session = nil
                }
            }
        }
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 120
        let session = URLSession(configuration: config)
        child = process
        self.session = session
        endpoint = URL(string: "http://127.0.0.1:\(port)/")!
        key = token
        alias = modelAlias
        runnerPath = runner.resolvingSymlinksInPath().path
        runID = id
        state = "Loading model…"
        do {
            try Task.checkCancellation()
            try process.run()
        } catch {
            if child === process { halt() }
            if error is CancellationError { throw error }
            throw InferenceError.launch(error.localizedDescription)
        }
        // stop() can invalidate the startup ID; clean up only this startup's child.
        defer {
            if Task.isCancelled {
                if child === process { halt() }
                else if process.isRunning { process.terminate() }
            }
        }
        try Task.checkCancellation()

        // Health is public. Only disclose the bearer token after verifying that this
        // wrapper's own llama-server child owns the loopback listener on this port.
        // The random alias and unauthenticated rejection provide additional checks.
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            try Task.checkCancellation()
            guard runID == id else { throw InferenceError.stopped }
            guard process.isRunning else { throw InferenceError.exited(process.terminationStatus) }
            do {
                let health = try await get("health", token: nil, timeout: 2, session: session)
                if health.0 == 200 {
                    let payload = try JSONDecoder().decode(Health.self, from: health.1)
                    guard payload.status == "ok" else { throw InferenceError.invalidIdentity }
                    let denied = try await get("v1/models", token: nil, timeout: 3, session: session)
                    guard denied.0 == 401 else { throw InferenceError.invalidIdentity }
                    let models = try await get("v1/models", token: token, timeout: 3, session: session)
                    guard models.0 == 200 else { throw InferenceError.invalidIdentity }
                    let identity = try JSONDecoder().decode(Models.self, from: models.1)
                    guard identity.data.count == 1, identity.data[0].id == modelAlias else {
                        throw InferenceError.invalidIdentity
                    }
                    guard runID == id, process.isRunning else { throw InferenceError.stopped }
                    state = "Ready"
                    return
                }
                guard health.0 == 503 else { throw InferenceError.invalidIdentity }
            } catch let error as URLError where error.code == .cannotConnectToHost || error.code == .timedOut || error.code == .networkConnectionLost {
                // The child is not listening yet.
            }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        throw InferenceError.timedOut
    }

    private func get(_ path: String, token: String?, timeout: TimeInterval, session: URLSession) async throws -> (Int, Data) {
        try Task.checkCancellation()
        guard let endpoint, let child, child.isRunning else { throw InferenceError.stopped }
        let connection: Connection?
        if let token {
            guard let runnerPath else { throw InferenceError.stopped }
            let owned = Connection(child: child, session: session, endpoint: endpoint, key: token, runnerPath: runnerPath)
            connection = owned
            try verify(owned)
        } else {
            // Startup health is public: do not disclose credentials until identity is proven.
            connection = nil
        }
        var request = URLRequest(url: endpoint.appendingPathComponent(path))
        request.timeoutInterval = timeout
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            try Task.checkCancellation()
            throw error
        }
        try Task.checkCancellation()
        guard child === self.child, child.isRunning, endpoint == self.endpoint else {
            throw InferenceError.stopped
        }
        if let connection { try verify(connection) }
        guard let response = response as? HTTPURLResponse else { throw InferenceError.invalidResponse }
        return (response.statusCode, data)
    }

    private func halt() {
        runID = nil
        session?.invalidateAndCancel()
        session = nil
        endpoint = nil
        key = nil
        alias = nil
        runnerPath = nil
        let previous = child
        child = nil
        if previous?.isRunning == true { previous?.terminate() }
    }

    private func recordFailure(_ error: Error) {
        consecutiveFailures = min(consecutiveFailures + 1, 6)
        let delay = 1 << consecutiveFailures
        nextAttempt = Date().addingTimeInterval(TimeInterval(delay))
        state = "Error: \(error.localizedDescription) Retrying in \(delay)s."
    }

    private static func ownsListener(supervisor: pid_t, runnerPath: String, port: UInt16) -> Bool {
        // Enumerate direct children rather than trusting a PID copied from process output.
        var children = [pid_t](repeating: 0, count: 32)
        let count = children.withUnsafeMutableBufferPointer {
            proc_listchildpids(supervisor, $0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size))
        }
        // libproc returns a PID count here, unlike proc_pidinfo which returns bytes.
        guard count >= 0, count < children.count else { return false }
        for pid in children.prefix(Int(count)) {
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) ==
                    MemoryLayout<proc_bsdinfo>.size,
                  info.pbi_ppid == UInt32(supervisor) else { continue }
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0,
                  path.withUnsafeBufferPointer({ buffer in
                      runnerPath.withCString { strcmp(buffer.baseAddress!, $0) == 0 }
                  }) else { continue }
            var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: 256)
            let size = descriptors.withUnsafeMutableBufferPointer {
                proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count * MemoryLayout<proc_fdinfo>.size))
            }
            guard size >= 0, size < descriptors.count * MemoryLayout<proc_fdinfo>.size else { continue }
            for fd in descriptors.prefix(Int(size) / MemoryLayout<proc_fdinfo>.size) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
                var socket = socket_fdinfo()
                guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &socket,
                                     Int32(MemoryLayout<socket_fdinfo>.size)) == MemoryLayout<socket_fdinfo>.size else { continue }
                let details = socket.psi
                let tcp = details.soi_proto.pri_tcp
                if details.soi_family == AF_INET && details.soi_kind == SOCKINFO_TCP &&
                   tcp.tcpsi_state == TSI_S_LISTEN &&
                   UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)) == port &&
                   tcp.tcpsi_ini.insi_laddr.ina_46.i46a_addr4.s_addr == in_addr_t(0x0100007f) {
                    return true
                }
            }
        }
        return false
    }

    private static func availablePort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw InferenceError.noPort }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: in_addr_t(0x0100007f)) // 127.0.0.1 in network byte order
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw InferenceError.noPort }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard named == 0 else { throw InferenceError.noPort }
        return UInt16(bigEndian: address.sin_port)
    }
}

private struct Health: Decodable { let status: String }
private struct Models: Decodable {
    struct Model: Decodable { let id: String }
    let data: [Model]
}
private struct Tokenization: Decodable {
    struct Token: Decodable {
        let id: Int
        let bytes: [UInt8]
        private enum CodingKeys: String, CodingKey { case id, piece }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(Int.self, forKey: .id)
            if let piece = try? container.decode(String.self, forKey: .piece) {
                bytes = Array(piece.utf8)
            } else {
                bytes = try container.decode([UInt8].self, forKey: .piece)
            }
        }
    }
    let tokens: [Token]
}
private struct RawCompletion: Decodable {
    enum StopType: String, Decodable { case none, eos, word, limit }
    let content: String
    let stop_type: StopType
    let truncated: Bool
}
