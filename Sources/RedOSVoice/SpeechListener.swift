@preconcurrency import AVFoundation
import Speech

public enum VoiceError: Error, LocalizedError, Equatable {
    case unsupportedLocale(String)
    case microphoneUnavailable

    public var errorDescription: String? {
        switch self {
        case .unsupportedLocale(let id): String(localized: "Speech recognition is not available for \(id).")
        case .microphoneUnavailable: String(localized: "The microphone is not available.")
        }
    }
}

/// On-device speech to text with SpeechAnalyzer: start while the push-to-talk key is held, stop on release.
@MainActor
public final class SpeechListener {
    public var onTranscript: ((String) -> Void)?
    /// Called once while the on-device model for a new language is downloaded.
    public var onDownload: (() -> Void)?

    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var results: Task<Void, Never>?
    private var finalized = ""
    private var volatile = ""

    public init() {}

    public static var supportedLocales: [Locale] {
        get async { await SpeechTranscriber.supportedLocales }
    }

    public var transcript: String {
        (finalized + volatile).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func start(locale: Locale) async throws {
        await cancel()
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw VoiceError.unsupportedLocale(locale.identifier)
        }
        let transcriber = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            onDownload?()
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw VoiceError.unsupportedLocale(supported.identifier)
        }

        finalized = ""
        volatile = ""
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.analyzer = analyzer
        input = continuation
        results = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    guard let self else { return }
                    if result.isFinal {
                        finalized += text
                        volatile = ""
                    } else {
                        volatile = text
                    }
                    onTranscript?(transcript)
                }
            } catch {
                // Analysis ended (cancelled or finished early): keep what was transcribed.
            }
        }
        try await analyzer.start(inputSequence: stream)

        let inputNode = engine.inputNode
        let microphoneFormat = inputNode.outputFormat(forBus: 0)
        guard microphoneFormat.channelCount > 0,
              let converter = AVAudioConverter(from: microphoneFormat, to: format)
        else { throw VoiceError.microphoneUnavailable }
        inputNode.installTap(
            onBus: 0, bufferSize: 4096, format: microphoneFormat,
            block: Self.tap(converter: converter, format: format, continuation: continuation)
        )
        engine.prepare()
        try engine.start()
    }

    /// Stops listening and returns the final transcript.
    public func stop() async -> String {
        stopAudio()
        input?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await results?.value
        reset()
        return transcript
    }

    public func cancel() async {
        stopAudio()
        input?.finish()
        await analyzer?.cancelAndFinishNow()
        results?.cancel()
        reset()
    }

    private func stopAudio() {
        guard engine.isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func reset() {
        analyzer = nil
        input = nil
        results = nil
    }

    /// Built outside the main actor: the tap runs on the realtime audio thread.
    private nonisolated static func tap(
        converter: AVAudioConverter, format: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation
    ) -> AVAudioNodeTapBlock {
        let converter = UncheckedBox(converter)
        return { buffer, _ in
            let ratio = format.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
            guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
            // The input block runs synchronously inside convert(to:error:withInputFrom:).
            nonisolated(unsafe) var consumed = false
            var error: NSError?
            converter.value.convert(to: converted, error: &error) { _, status in
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
}

/// AVAudioConverter is only used from the audio thread that owns the tap.
private final class UncheckedBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
