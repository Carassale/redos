/// Ends hands-free dictation when the speaker pauses: 1.5 s without new words, 6 s without any, 20 s at most.
@MainActor
final class DictationEndpoint {
    private var task: Task<Void, Never>?

    func start(transcript: @escaping @MainActor () -> String, onPause: @escaping @MainActor () -> Void) {
        task?.cancel()
        task = Task {
            let start = ContinuousClock.now
            var heard = "", changed = start
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                if transcript() != heard {
                    heard = transcript()
                    changed = .now
                }
                let quiet = ContinuousClock.now - changed
                if quiet > (heard.isEmpty ? .seconds(6) : .seconds(1.5)) || ContinuousClock.now - start > .seconds(20) {
                    guard !Task.isCancelled else { return }
                    onPause()
                    return
                }
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
