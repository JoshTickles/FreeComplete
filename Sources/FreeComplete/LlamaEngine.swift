import Accelerate
import CLlama
import Foundation

/// The bundled model, loaded once inside the app and driven through llama.cpp's C API.
/// Callers confine every call to one serial queue; llama contexts are not thread-safe.
///
/// Search branches live as KV-cache sequences. A request names each branch by its full
/// token list. The engine finds the cached sequence sharing the longest prefix, copies
/// it (KV cells are shared, not duplicated), and decodes only the new tokens in one
/// batch. The previous prompt stays cached, so typing one more character re-evaluates
/// only the changed tail.
final class LlamaEngine: @unchecked Sendable {
    struct Candidate {
        let id: Int
        let bytes: [UInt8]
        let prob: Float32
        let modelLogprob: Double?
    }

    enum Stop { case eos, word, limit }

    enum Failure: LocalizedError {
        case load(String), decode(Int32), capacity, tokenize
        var errorDescription: String? {
            switch self {
            case .load(let path): "Could not load the local model at \(path)."
            case .decode(let status): "The local model failed to evaluate text (status \(status))."
            case .capacity: "The local model ran out of context space."
            case .tokenize: "Could not tokenize the text."
            }
        }
    }

    static let contextSize: Int32 = 8192
    private static let maxSequences: Int32 = 20   // 0 = base cache, 1…19 branches
    private static let batchCapacity: Int32 = 2048
    private static let topK = 20

    private let model: OpaquePointer
    private let context: OpaquePointer
    private let vocab: OpaquePointer
    private let memory: llama_memory_t
    private let vocabularySize: Int
    /// Raw UTF-8 bytes of every token; control tokens are empty.
    private let pieces: [[UInt8]]
    private var batch: llama_batch
    private var cached: [Int32: [Int32]] = [:]
    private var prefixMasks: [[UInt8]: [Int32]] = [:]
    private var closed = false

    /// Loads the model.
    init(modelPath: String) throws {
        llama_backend_init()
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = 999
        guard let model = llama_model_load_from_file(modelPath, modelParams) else { throw Failure.load(modelPath) }
        var params = llama_context_default_params()
        params.n_ctx = UInt32(Self.contextSize)
        params.n_batch = UInt32(Self.batchCapacity)
        params.n_ubatch = 512
        params.n_seq_max = UInt32(Self.maxSequences)
        params.kv_unified = true
        params.swa_full = true
        params.no_perf = true
        let threads = Int32(max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
        params.n_threads = threads
        params.n_threads_batch = threads
        guard let context = llama_init_from_model(model, params) else {
            llama_model_free(model)
            throw Failure.load(modelPath)
        }
        self.model = model
        self.context = context
        vocab = llama_model_get_vocab(model)
        memory = llama_get_memory(context)
        vocabularySize = Int(llama_vocab_n_tokens(vocab))
        var table: [[UInt8]] = []
        table.reserveCapacity(vocabularySize)
        var buffer = [CChar](repeating: 0, count: 256)
        for token in 0..<Int32(vocabularySize) {
            if llama_vocab_is_control(vocab, token) { table.append([]); continue }
            var count = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
            if count < 0 {
                buffer = [CChar](repeating: 0, count: Int(-count))
                count = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
            }
            table.append(count > 0 ? buffer[0..<Int(count)].map { UInt8(bitPattern: $0) } : [])
        }
        pieces = table
        batch = llama_batch_init(Self.batchCapacity, 0, 1)
    }

    deinit { close() }

    /// Release native resources on the owning queue, independently of Swift task
    /// references that can outlive a stopped inference session.
    func close() {
        guard !closed else { return }
        closed = true
        llama_batch_free(batch)
        llama_free(context)
        llama_model_free(model)
    }

    func pieceBytes(_ token: Int) -> [UInt8] { token >= 0 && token < pieces.count ? pieces[token] : [] }

    func tokenize(_ text: String, addSpecial: Bool) throws -> [Int32] {
        guard !closed else { throw CancellationError() }
        let utf8 = Array(text.utf8CString.dropLast())
        var tokens = [Int32](repeating: 0, count: utf8.count + 8)
        var count = llama_tokenize(vocab, utf8, Int32(utf8.count), &tokens, Int32(tokens.count), addSpecial, false)
        if count < 0 {
            tokens = [Int32](repeating: 0, count: Int(-count))
            count = llama_tokenize(vocab, utf8, Int32(utf8.count), &tokens, Int32(tokens.count), addSpecial, false)
        }
        guard count >= 0 else { throw Failure.tokenize }
        return Array(tokens.prefix(Int(count)))
    }

    /// Next-token candidates for each sequence. A non-empty `prefix` restricts that row to
    /// tokens whose bytes agree with the pending bytes and adds the unmasked model log
    /// probability. Probabilities are a Float32 softmax over the retained top twenty.
    func next(_ sequences: [[Int32]], prefixes: [[UInt8]]) throws -> [[Candidate]] {
        guard !closed else { throw CancellationError() }
        let rows = try evaluate(sequences)
        let logits = try rows.map { row -> UnsafeMutablePointer<Float> in
            guard let pointer = llama_get_logits_ith(context, row) else { throw Failure.decode(-1) }
            return pointer
        }
        // Prefix masks are shared state; build them before the parallel scan.
        for prefix in prefixes where !prefix.isEmpty { _ = allowed(prefix) }
        var results = [[Candidate]](repeating: [], count: rows.count)
        results.withUnsafeMutableBufferPointer { output in
            DispatchQueue.concurrentPerform(iterations: rows.count) { index in
                output[index] = candidates(logits[index], prefix: prefixes[index])
            }
        }
        return results
    }

    /// Greedy continuation with stop strings (rewrites).
    func greedy(_ prompt: [Int32], maxTokens: Int, stops: [String]) throws -> (text: String, stop: Stop) {
        guard !closed else { throw CancellationError() }
        var tokens = prompt
        var bytes: [UInt8] = []
        for _ in 0..<maxTokens {
            let row = try evaluate([tokens])[0]
            guard let logits = llama_get_logits_ith(context, row) else { throw Failure.decode(-1) }
            var best: Int32 = 0
            var bestValue = -Float.infinity
            for id in 0..<vocabularySize where logits[id] > bestValue {
                bestValue = logits[id]
                best = Int32(id)
            }
            if llama_vocab_is_eog(vocab, best) { return (String(decoding: bytes, as: UTF8.self), .eos) }
            bytes.append(contentsOf: pieces[Int(best)])
            tokens.append(best)
            let text = String(decoding: bytes, as: UTF8.self)
            if let stop = stops.compactMap({ text.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) {
                return (String(text[..<stop.lowerBound]), .word)
            }
        }
        return (String(decoding: bytes, as: UTF8.self), .limit)
    }

    // MARK: - KV sequences

    /// Brings every sequence into the cache and returns each one's batch row of logits.
    private func evaluate(_ sequences: [[Int32]]) throws -> [Int32] {
        var used = Set<Int32>()
        var plans: [(target: Int32, from: Int, tokens: [Int32])] = []
        let sources = cached
        var free = (1..<Self.maxSequences).filter { sources[$0] == nil }
        for (index, tokens) in sequences.enumerated() {
            // Longest cached prefix; always decode at least the final token for its logits.
            var source: Int32 = -1
            var shared = 0
            for (id, cachedTokens) in sources {
                let common = commonPrefix(cachedTokens, tokens)
                if common > shared { shared = common; source = id }
            }
            shared = min(shared, tokens.count - 1)
            // A single sequence becomes the new base cache (seq 0); branches use spares.
            let target: Int32
            if sequences.count == 1 && index == 0 {
                target = 0
            } else {
                guard !free.isEmpty else { throw Failure.capacity }
                target = free.removeFirst()
            }
            if target != source {
                _ = llama_memory_seq_rm(memory, target, -1, -1)
                if shared > 0 && source >= 0 { llama_memory_seq_cp(memory, source, target, 0, llama_pos(shared)) }
            } else if !llama_memory_seq_rm(memory, target, llama_pos(shared), -1) {
                _ = llama_memory_seq_rm(memory, target, -1, -1)
                shared = 0
            }
            used.insert(target)
            plans.append((target, shared, tokens))
        }
        // Release branches this request did not keep, except the base cache.
        for id in sources.keys where id != 0 && !used.contains(id) {
            _ = llama_memory_seq_rm(memory, id, -1, -1)
        }
        var rows = [Int32](repeating: -1, count: sequences.count)
        var nextCache: [Int32: [Int32]] = sources[0].map { [0: $0] } ?? [:]
        var pending: [(plan: Int, position: Int)] = []
        for (index, plan) in plans.enumerated() {
            for position in plan.from..<plan.tokens.count { pending.append((index, position)) }
            nextCache[plan.target] = plan.tokens
        }
        // Decode in batch-sized chunks; logits only for each sequence's final token.
        var start = 0
        while start < pending.count {
            let chunk = pending[start..<min(start + Int(Self.batchCapacity), pending.count)]
            batch.n_tokens = 0
            for item in chunk {
                let plan = plans[item.plan]
                let slot = Int(batch.n_tokens)
                batch.token[slot] = plan.tokens[item.position]
                batch.pos[slot] = llama_pos(item.position)
                batch.n_seq_id[slot] = 1
                batch.seq_id[slot]![0] = plan.target
                let last = item.position == plan.tokens.count - 1
                batch.logits[slot] = last ? 1 : 0
                if last { rows[item.plan] = Int32(slot) }
                batch.n_tokens += 1
            }
            let status = llama_decode(context, batch)
            guard status == 0 else {
                cached = [:]
                llama_memory_clear(memory, true)
                throw status == 1 ? Failure.capacity : Failure.decode(status)
            }
            start += chunk.count
            // Rows refer to the latest decoded batch only.
            if start < pending.count {
                for index in rows.indices where rows[index] >= 0 { rows[index] = -1 }
            }
        }
        cached = nextCache
        guard rows.allSatisfy({ $0 >= 0 }) else { throw Failure.decode(-2) }
        return rows
    }

    private func commonPrefix(_ a: [Int32], _ b: [Int32]) -> Int {
        var index = 0
        let limit = min(a.count, b.count)
        while index < limit && a[index] == b[index] { index += 1 }
        return index
    }

    // MARK: - Distributions

    private func allowed(_ prefix: [UInt8]) -> [Int32] {
        if let cached = prefixMasks[prefix] { return cached }
        var ids: [Int32] = []
        for (id, bytes) in pieces.enumerated() where !bytes.isEmpty {
            let count = min(bytes.count, prefix.count)
            if bytes.prefix(count).elementsEqual(prefix.prefix(count)) { ids.append(Int32(id)) }
        }
        if prefixMasks.count > 256 { prefixMasks.removeAll() }
        prefixMasks[prefix] = ids
        return ids
    }

    private func candidates(_ logits: UnsafeMutablePointer<Float>, prefix: [UInt8]) -> [Candidate] {
        // Top twenty by logit, among all tokens or the prefix-compatible ones.
        var top: [(id: Int32, logit: Float)] = []
        top.reserveCapacity(Self.topK + 1)
        func consider(_ id: Int32) {
            let value = logits[Int(id)]
            guard value.isFinite else { return }
            if top.count == Self.topK, let last = top.last, value <= last.logit { return }
            let at = top.firstIndex(where: { value > $0.logit }) ?? top.count
            top.insert((id, value), at: at)
            if top.count > Self.topK { top.removeLast() }
        }
        if prefix.isEmpty {
            for id in 0..<Int32(vocabularySize) { consider(id) }
        } else if let ids = prefixMasks[prefix] {
            for id in ids { consider(id) }
        }
        guard let maximum = top.first?.logit else { return [] }
        let exps = top.map { Float32(exp(Double($0.logit - maximum))) }
        let total = exps.reduce(0, +)
        // Unmasked full-vocabulary log-sum-exp for prefix reconstruction scores.
        var modelLogSum: Double?
        if !prefix.isEmpty {
            var maxAll: Float = 0
            vDSP_maxv(logits, 1, &maxAll, vDSP_Length(vocabularySize))
            var shift = -maxAll
            var scratch = [Float](repeating: 0, count: vocabularySize)
            scratch.withUnsafeMutableBufferPointer { buffer in
                vDSP_vsadd(logits, 1, &shift, buffer.baseAddress!, 1, vDSP_Length(vocabularySize))
                var n = Int32(vocabularySize)
                vvexpf(buffer.baseAddress!, buffer.baseAddress!, &n)
                var sum: Float = 0
                vDSP_sve(buffer.baseAddress!, 1, &sum, vDSP_Length(vocabularySize))
                modelLogSum = Double(maxAll) + log(Double(sum))
            }
        }
        return top.enumerated().map { index, entry in
            Candidate(id: Int(entry.id), bytes: pieces[Int(entry.id)], prob: exps[index] / total,
                      modelLogprob: modelLogSum.map { min(0, Double(entry.logit) - $0) })
        }
    }
}
