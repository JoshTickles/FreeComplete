import Foundation

@main
struct SuggestionLifetimeChecks {
    @MainActor
    static func main() async {
        let deadline = AcceptanceDeadline()
        let past = Date(timeIntervalSince1970: 0)
        var events: [String] = []
        await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
            deadline.schedule(at: past) { events.append("superseded") }
            deadline.schedule(at: past) {
                events.append("replacement")
                finished.resume()
            }
        }
        precondition(events == ["replacement"],
                     "Replacing an already-due deadline must suppress its old queued callback")

        events.removeAll()
        let barrier = AcceptanceDeadline()
        await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
            deadline.schedule(at: past) { events.append("cancelled") }
            deadline.cancel()
            barrier.schedule(at: past) { finished.resume() }
        }
        precondition(events.isEmpty, "Hard invalidation must cancel even an already-due acceptance deadline")

        await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
            deadline.schedule(at: past) {
                events.append("first")
                deadline.schedule(at: past) {
                    events.append("second")
                    finished.resume()
                }
            }
        }
        for _ in 0..<4 { await Task.yield() }
        precondition(events == ["first", "second"],
                     "A callback may install the next deadline; each deadline fires only once")
        print("Suggestion deadline behavior checks passed")
    }
}
