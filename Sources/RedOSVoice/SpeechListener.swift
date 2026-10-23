import Accelerate
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
    /// Microphone level from 0 (silence) to 1 (loud voice), about ten times a second.
    public var onLevel: ((Float) -> Void)?

    private var engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var results: Task<Void, Never>?
    private var finalized = ""
    private var volatile = ""

    public init() {}

    public static var supportedLocales: [Locale] {
        get async { await SpeechTranscriber.supportedLocales }
    }

    /// The on-device speech model for `locale` is downloaded.
    public static func isInstalled(_ locale: Locale) async -> Bool {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return false }
        let installed = await SpeechTranscriber.installedLocales
        return installed.contains { $0.identifier(.bcp47) == supported.identifier(.bcp47) }
    }

    /// Downloads the on-device speech model for `locale` (otherwise done on first use).
    public static func install(_ locale: Locale) async throws {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw VoiceError.unsupportedLocale(locale.identifier)
        }
        let transcriber = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
        guard await AssetInventory.status(forModules: [transcriber]) != .installed else { return }
        try await AssetInventory.assetInstallationRequest(supporting: [transcriber])?.downloadAndInstall()
    }

    public var transcript: String {
        (finalized + volatile).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `cancelsEcho` removes what the Mac is playing (RedOS's own voice) from the microphone, so the user can
    /// talk over it.
    public func start(locale: Locale, cancelsEcho: Bool = false) async throws {
        // Callers may poll `transcript` before the model is ready: never show the previous one.
        finalized = ""
        volatile = ""
        await cancel()
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw VoiceError.unsupportedLocale(locale.identifier)
        }
        let transcriber = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
        // The installation request is not nil even when the model is already installed.
        if await AssetInventory.status(forModules: [transcriber]) != .installed,
           let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
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
        try startMicrophone(format: format, continuation: continuation, cancelsEcho: cancelsEcho)
    }

    private func startMicrophone(
        format: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation, cancelsEcho: Bool
    ) throws {
        let inputNode = engine.inputNode
        if inputNode.isVoiceProcessingEnabled != cancelsEcho {
            try inputNode.setVoiceProcessingEnabled(cancelsEcho)
        }
        if cancelsEcho {
            // By default voice processing also turns down every other sound, RedOS's voice included.
            inputNode.voiceProcessingOtherAudioDuckingConfiguration = .init(
                enableAdvancedDucking: false, duckingLevel: .min
            )
        }
        let microphoneFormat = inputNode.outputFormat(forBus: 0)
        guard microphoneFormat.channelCount > 0,
              let converter = AVAudioConverter(from: microphoneFormat, to: format)
        else { throw VoiceError.microphoneUnavailable }
        let level: @Sendable (Float) -> Void = { [weak self] rms in
            // -50 dB is silence, -10 dB a loud voice.
            let normalized = min(max((20 * log10(max(rms, 1e-6)) + 50) / 40, 0), 1)
            Task { @MainActor in self?.onLevel?(normalized) }
        }
        inputNode.installTap(
            onBus: 0, bufferSize: 4096, format: microphoneFormat,
            block: Self.tap(converter: converter, format: format, continuation: continuation, level: level)
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
        onLevel?(0)
        let inputNode = engine.inputNode
        if engine.isRunning {
            inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        // The voice-processing unit keeps every app's audio in voice-chat mode until its engine is released.
        guard inputNode.isVoiceProcessingEnabled else { return }
        try? inputNode.setVoiceProcessingEnabled(false)
        engine.reset()
        engine = AVAudioEngine()
    }

    private func reset() {
        analyzer = nil
        input = nil
        results = nil
    }

    /// Built outside the main actor: the tap runs on the realtime audio thread.
    private nonisolated static func tap(
        converter: AVAudioConverter, format: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation,
        level: @escaping @Sendable (Float) -> Void
    ) -> AVAudioNodeTapBlock {
        let converter = UncheckedBox(converter)
        return { buffer, _ in
            if let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 {
                var rms: Float = 0
                vDSP_rmsqv(samples, 1, &rms, vDSP_Length(buffer.frameLength))
                level(rms)
            }
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
