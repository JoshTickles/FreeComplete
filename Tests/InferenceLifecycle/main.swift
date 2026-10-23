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
        default:
            fatalError("Unknown lifecycle scenario: \(scenario)")
        }
        print("Completed lifecycle scenario: \(scenario)")
        // The runner requires a clean process exit too. The original bug crashed in
        // Metal teardown after main returned, even when generation had succeeded.
    }
}
