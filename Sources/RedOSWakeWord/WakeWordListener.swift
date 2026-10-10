@preconcurrency import AVFoundation
import RedOSVoice

/// Listens to the microphone for the wake word while enabled; audio never leaves this Mac.
@MainActor
public final class WakeWordListener {
    public var onDetect: (() -> Void)?
    /// Minimum score (0…1) that counts as the wake word.
    public var threshold: Float

    private let detector: WakeWordDetector
    private let engine = AVAudioEngine()
    private var processing: Task<Void, Never>?
    private var feed: AsyncStream<[Float]>.Continuation?
    private var lastDetection = ContinuousClock.now - .seconds(10)

    public init(model: URL, featureModels: URL, threshold: Float = 0.5) throws {
        detector = try WakeWordDetector(model: model, featureModels: featureModels)
        self.threshold = threshold
    }

    public var isRunning: Bool { engine.isRunning }

    public func start() throws {
        guard !engine.isRunning else { return }
        let input = engine.inputNode
        let microphoneFormat = input.outputFormat(forBus: 0)
        guard microphoneFormat.channelCount > 0,
              let format = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false
              ),
              let converter = AVAudioConverter(from: microphoneFormat, to: format)
        else { throw VoiceError.microphoneUnavailable }
        // A slow model must not queue up old audio: keep at most ~2 s.
        let (stream, feed) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .bufferingNewest(20))
        self.feed = feed
        input.installTap(
            onBus: 0, bufferSize: 4096, format: microphoneFormat,
            block: Self.tap(converter: converter, format: format, feed: feed)
        )
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            feed.finish()
            throw error
        }
        processing = Task { [detector, weak self] in
            await detector.reset()
            for await samples in stream {
                guard let score = try? await detector.process(samples) else { continue }
                if let self, score >= threshold { await detected() }
            }
        }
    }

    public func stop() {
        guard engine.isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        feed?.finish()
        feed = nil
        processing?.cancel()
        processing = nil
    }

    private func detected() async {
        // One utterance gives several high scores in a row.
        guard ContinuousClock.now - lastDetection > .seconds(2) else { return }
        lastDetection = .now
        await detector.reset()
        onDetect?()
    }

    /// Built outside the main actor: the tap runs on the realtime audio thread.
    private nonisolated static func tap(
        converter: AVAudioConverter, format: AVAudioFormat, feed: AsyncStream<[Float]>.Continuation
    ) -> AVAudioNodeTapBlock {
        let converter = UncheckedBox(converter)
        return { buffer, _ in
            let ratio = format.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
            guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
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
            guard error == nil, converted.frameLength > 0, let channel = converted.floatChannelData?[0] else { return }
            // openWakeWord expects 16-bit PCM values.
            feed.yield(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)).map { $0 * 32767 })
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
