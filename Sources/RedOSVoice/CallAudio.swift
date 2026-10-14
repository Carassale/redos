@preconcurrency import AVFoundation
import CoreMedia
@preconcurrency import ScreenCaptureKit

/// The user's voice from the microphone. With echo cancellation, what the Mac plays (the other people in
/// a call) is removed, so it is not transcribed twice.
@MainActor
public final class MicrophoneCapture {
    private let engine = AVAudioEngine()

    public init() {}

    public func start(cancelsEcho: Bool, sink: @escaping AudioSink) throws {
        let input = engine.inputNode
        if input.isVoiceProcessingEnabled != cancelsEcho {
            try input.setVoiceProcessingEnabled(cancelsEcho)
        }
        if cancelsEcho {
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(
                enableAdvancedDucking: false, duckingLevel: .min
            )
        }
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0 else { throw VoiceError.microphoneUnavailable }
        input.installTap(onBus: 0, bufferSize: 4096, format: format, block: Self.tap(sink))
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    public func stop() {
        guard engine.isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// Built outside the main actor: the tap runs on the realtime audio thread.
    private nonisolated static func tap(_ sink: @escaping AudioSink) -> AVAudioNodeTapBlock {
        { buffer, _ in sink(buffer) }
    }
}

public enum SystemAudioError: Error, LocalizedError {
    case noDisplay

    public var errorDescription: String? {
        String(localized: "The call audio can't be captured: allow Screen Recording for RedOS.")
    }
}

/// What the Mac plays (the other people in a call), through ScreenCaptureKit; RedOS's own sounds are excluded.
/// Needs the Screen Recording permission. Audio only: the video is the smallest possible.
public final class SystemAudioCapture: NSObject, SCStreamOutput, @unchecked Sendable {
    private var stream: SCStream?
    private var sink: AudioSink?
    private let queue = DispatchQueue(label: "dev.redos.system-audio")

    override public init() {}

    public func start(sink: @escaping AudioSink) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw SystemAudioError.noDisplay }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48000
        configuration.channelCount = 1
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        self.sink = sink
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    public func stop() async {
        try? await stream?.stopCapture()
        stream = nil
        sink = nil
    }

    public func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType
    ) {
        guard type == .audio, let buffer = Self.pcmBuffer(sampleBuffer) else { return }
        sink?(buffer)
    }

    private static func pcmBuffer(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard sampleBuffer.isValid,
              var description = sampleBuffer.formatDescription?.audioStreamBasicDescription,
              let format = AVAudioFormat(streamDescription: &description)
        else { return nil }
        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList
        )
        return status == noErr ? buffer : nil
    }
}
