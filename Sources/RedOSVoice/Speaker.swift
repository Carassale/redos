import AVFoundation

/// Spoken feedback with the best installed system voice for the language.
@MainActor
public final class Speaker {
    private let synthesizer = AVSpeechSynthesizer()

    public init() {}

    public func speak(_ text: String, locale: Locale) {
        synthesizer.stopSpeaking(at: .immediate)
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
