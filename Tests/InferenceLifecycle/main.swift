import Foundation

@main
struct InferenceLifecycleChecks {
    @MainActor
    static func completion(_ inference: LocalInference) async throws -> String {
        let context = PredictionContext(before: "The capital of France is", after: "",
                                        appName: "Lifecycle check", appID: "app.freecomplete.check",
                                        visibleText: nil, clipboard: nil, siteDomain: nil)
        let options = PredictionOptions(globalInstructions: "", appInstructions: "", domainInstructions: "",
                                        vocabularyStrength: 0, vocabulary: "", maxWords: 4)
        return try await inference.generate(
            prompt: PredictionPrompt.make(context: context, options: options, kind: .continuation),
            maxTokens: 4, maxWords: 4, kind: .continuation)
    }

    @MainActor
    static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(60)
        while !condition() {
            precondition(ContinuousClock.now < deadline, "Lifecycle transition did not finish")
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    @MainActor
    static func main() async throws {
        let inference = LocalInference()
        defer { inference.stop() }
        let scenario = CommandLine.arguments.dropFirst().first ?? "stop"
        switch scenario {
        case "stop":
            let result = try await completion(inference)
            precondition(result.contains("Paris"), "The real model must still answer the writing prompt")
            inference.stop()
            inference.stop()
        case "restart":
            let before = try await completion(inference)
            precondition(before.contains("Paris"), "The initial completion must answer the writing prompt")
            inference.stop()
            let after = try await completion(inference)
            precondition(after == before, "Unloading and reloading must preserve the completion")
        case "cancel":
            let cancelled = Task { try await completion(inference) }
            cancelled.cancel()
            inference.stop()
            switch await cancelled.result {
            case .failure(let error) where error is CancellationError:
                break
            default:
                fatalError("A cancelled request must not return a completion")
            }
            let fresh = try await completion(inference)
            precondition(fresh.contains("Paris"), "Cancellation and stop must not poison a fresh request")
        case "cancel-preload":
            let preload = Task { await inference.prepare() }
            try await waitUntil { inference.state == "Loading model" }
            preload.cancel()
            await preload.value
            precondition(inference.state == "Ready",
                         "A cancelled waiter must still publish the successfully loaded session as Ready")
            let result = try await completion(inference)
            precondition(result.contains("Paris"), "Cancelling a preload waiter must leave the loaded model usable")
        case "unload-loading":
            let retired = Task { try await completion(inference) }
            try await waitUntil { inference.state == "Loading model" }
            precondition(inference.activeRequests == 1, "The load belongs to an active generation")
            inference.unload()
            // This request arrives before the retired queue-owned engine has closed.
            let fresh = try await completion(inference)
            switch await retired.result {
            case .failure(let error) where error is CancellationError:
                break
            default:
                fatalError("A retired load must not return or publish a completion")
            }
            precondition(fresh.contains("Paris") && inference.state == "Ready",
                         "Queued teardown must not close or overwrite the new session")
            precondition(inference.activeRequests == 0,
                         "A retired request must not decrement the new session's request count")
        case "idle":
            // A zero idle interval exercises the boundary between every await/round:
            // only completion of the entire request can permit unloading.
            inference.configureIdleUnload(after: .zero)
            await inference.prepare()
            let result = try await completion(inference)
            precondition(result.contains("Paris"), "Idle expiry must not interrupt an active multi-round generation")
            try await waitUntil { inference.state == "Unloaded" }
            precondition(inference.activeRequests == 0, "Idle release must follow, not overlap, active work")
            let preload = Task { await inference.prepare() }
            try await waitUntil { inference.state == "Loading model" }
            precondition(inference.activeRequests == 1, "Proactive preparation must hold an activity lease")
            inference.configureIdleUnload(after: nil)
            await preload.value
            try await Task.sleep(for: .milliseconds(20))
            precondition(inference.state == "Ready" && inference.activeRequests == 0,
                         "Switching to Performance must cancel the old idle deadline")
        default:
            fatalError("Unknown lifecycle scenario: \(scenario)")
        }
        print("Completed lifecycle scenario: \(scenario)")
        // The runner requires a clean process exit too. The original bug crashed in
        // Metal teardown after main returned, even when generation had succeeded.
    }
}
