@preconcurrency import AVFoundation
import Speech

/// Receives audio from any source, on any thread.
public typealias AudioSink = @Sendable (AVAudioPCMBuffer) -> Void

/// Continuous on-device transcription of one audio source (a call can last an hour): every finished
/// sentence is reported once, the sentence in progress is reported as it changes.
@MainActor
public final class StreamTranscriber {
    /// Text of the sentence in progress, or "" once it is final.
    public var onVolatile: ((String) -> Void)?
    public var onFinal: ((String) -> Void)?

    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var results: Task<Void, Never>?

    public init() {}

    /// Returns where the source should send its audio.
    public func start(locale: Locale) async throws -> AudioSink {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw VoiceError.unsupportedLocale(locale.identifier)
        }
        let transcriber = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
        if await AssetInventory.status(forModules: [transcriber]) != .installed {
            try await AssetInventory.assetInstallationRequest(supporting: [transcriber])?.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw VoiceError.unsupportedLocale(supported.identifier)
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.analyzer = analyzer
        input = continuation
        results = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let self else { return }
                    if result.isFinal {
                        onVolatile?("")
                        if !text.isEmpty { onFinal?(text) }
                    } else {
                        onVolatile?(text)
                    }
                }
            } catch {
                // Analysis ended: what was final has been reported.
            }
        }
        try await analyzer.start(inputSequence: stream)
        return AudioConversion(format: format, continuation: continuation).sink
    }

    /// Finishes the sentence in progress, then stops.
    public func stop() async {
        input?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await results?.value
        analyzer = nil
        input = nil
        results = nil
    }
}

/// Converts whatever the source delivers to the analyzer's format; the converter is created on the first buffer.
private final class AudioConversion: @unchecked Sendable {
    private let format: AVAudioFormat
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let lock = NSLock()
    private var converter: AVAudioConverter?

    init(format: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation) {
        self.format = format
        self.continuation = continuation
    }

    var sink: AudioSink { { [self] buffer in convert(buffer) } }

    private func convert(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let converter, buffer.frameLength > 0 else { return }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
        guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        // The input block runs synchronously inside convert(to:error:withInputFrom:).
        nonisolated(unsafe) var consumed = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if error == nil, converted.frameLength > 0 {
            continuation.yield(AnalyzerInput(buffer: converted))
        }
    }
}
