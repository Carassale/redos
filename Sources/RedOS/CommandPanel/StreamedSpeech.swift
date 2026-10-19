import Foundation
import RedOSCore
import RedOSVoice

/// Speaks an answer sentence by sentence while the model writes it, up to about `limit` characters.
@MainActor
final class StreamedSpeech {
    let sink: AsyncStream<String>.Continuation
    private let stream: AsyncStream<String>
    private let speaker: Speaker
    private let locale: Locale
    private let limit: Int
    private var sentences = SpokenSentences()
    private var spoken = 0
    private var listening: Task<Void, Never>?

    init(speaker: Speaker, locale: Locale, limit: Int = 400) {
        (stream, sink) = AsyncStream<String>.makeStream()
        self.speaker = speaker
        self.locale = locale
        self.limit = limit
        listening = Task { [weak self, stream] in
            for await text in stream {
                guard let self else { return }
                sentences.append(text).forEach(speak)
            }
        }
    }

    /// Whether anything was said; the last piece is said too unless the work was cancelled. Without
    /// streaming (another provider, a failure) nothing was said and the caller speaks the answer.
    func finish(speaksRest: Bool) async -> Bool {
        sink.finish()
        await listening?.value
        if spoken > 0, speaksRest, let rest = sentences.finish() { speak(rest) }
        return spoken > 0
    }

    private func speak(_ sentence: String) {
        guard spoken < limit else { return }
        let text = MarkdownText.plain(sentence)
        if spoken == 0 {
            speaker.speak(text, locale: locale)
        } else {
            speaker.enqueue(text, locale: locale)
        }
        spoken += sentence.count
    }
}
