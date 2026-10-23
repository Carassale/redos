import AVFoundation

/// Spoken feedback with the best installed system voice for the language.
@MainActor
public final class Speaker {
    private let synthesizer = AVSpeechSynthesizer()
    private let observer = SpeakingObserver()

    /// RedOS started (true) or stopped (false) talking.
    public var onSpeakingChange: (@MainActor (Bool) -> Void)? {
        get { observer.onChange }
        set { observer.onChange = newValue }
    }

    public init() {
        synthesizer.delegate = observer
    }

    public func speak(_ text: String, locale: Locale) {
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.voice(for: locale)
        synthesizer.speak(utterance)
    }

    /// Speaks after what is already being said (a streamed answer, sentence by sentence).
    public func enqueue(_ text: String, locale: Locale) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.voice(for: locale)
        synthesizer.speak(utterance)
    }

    public func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    public var isSpeaking: Bool { synthesizer.isSpeaking }

    static func voice(for locale: Locale) -> AVSpeechSynthesisVoice? {
        let language = locale.language.languageCode?.identifier ?? "en"
        let region = locale.region?.identifier
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(language) }
        // Prefer the exact region, then premium/enhanced quality.
        let score = { (voice: AVSpeechSynthesisVoice) in
            (region.map { voice.language.hasSuffix($0) } == true ? 10 : 0) + voice.quality.rawValue
        }
        return candidates.max { score($0) < score($1) } ?? AVSpeechSynthesisVoice(language: locale.identifier)
    }
}

private final class SpeakingObserver: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    var onChange: (@MainActor (Bool) -> Void)?

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        report(true)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        report(false)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        report(false)
    }

    private func report(_ speaking: Bool) {
        let onChange = onChange
        Task { @MainActor in onChange?(speaking) }
    }
}
