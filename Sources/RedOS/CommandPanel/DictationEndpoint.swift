/// Ends hands-free dictation when the speaker pauses: 1.5 s without new words, 6 s without any (counted once
/// RedOS stops talking), 20 s after the first word at most.
@MainActor
final class DictationEndpoint {
    private var task: Task<Void, Never>?

    /// `onPause` gets whether anything was heard.
    func start(
        transcript: @escaping @MainActor () -> String,
        isSpeaking: @escaping @MainActor () -> Bool = { false },
        onPause: @escaping @MainActor (_ heard: Bool) -> Void
    ) {
        task?.cancel()
        task = Task {
            var heard = "", changed = ContinuousClock.now
            var firstWord: ContinuousClock.Instant?
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                let now = ContinuousClock.now
                if transcript() != heard {
                    heard = transcript()
                    changed = now
                    if firstWord == nil, !heard.isEmpty { firstWord = now }
                }
                if heard.isEmpty, isSpeaking() {
                    changed = now
                    continue
                }
                let quiet = now - changed
                let tooLong = firstWord.map { now - $0 > .seconds(20) } ?? false
                if quiet > (heard.isEmpty ? .seconds(6) : .seconds(1.5)) || tooLong {
                    guard !Task.isCancelled else { return }
                    onPause(!heard.isEmpty)
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
