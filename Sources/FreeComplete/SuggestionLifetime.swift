import Foundation

/// One task owns a pending acceptance deadline. Replacing or cancelling it also
/// suppresses a callback whose sleep has completed but has not reached the actor.
@MainActor
final class AcceptanceDeadline {
    private var task: Task<Void, Never>?

    func schedule(at deadline: Date, onExpire: @escaping @MainActor () -> Void) {
        cancel()
        task = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow))) }
            catch { return }
            guard let self, !Task.isCancelled else { return }
            self.task = nil
            onExpire()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
