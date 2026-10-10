import Foundation
import OnnxRuntimeBindings

/// openWakeWord on ONNX Runtime: 16 kHz audio → mel spectrogram → speech embeddings → wake word score.
/// Audio is processed in 80 ms chunks, the same streaming steps as openWakeWord's Python package.
public actor WakeWordDetector {
    static let chunk = 1280
    /// Extra samples before each chunk so the mel frames line up across chunks.
    static let context = 480
    static let melFrames = 76
    static let melBins = 32
    static let embeddings = 16
    static let embeddingSize = 96

    private let melspectrogram: ONNXModel
    private let embedding: ONNXModel
    private let classifier: ONNXModel
    private var pending: [Float] = []
    private var recent: [Float] = []
    private var mels: [Float] = []
    private var features: [Float] = []

    /// `model` is the wake word classifier; `featureModels` holds melspectrogram.onnx and embedding_model.onnx.
    public init(model: URL, featureModels: URL) throws {
        let env = try ORTEnv(loggingLevel: .warning)
        melspectrogram = try ONNXModel(env: env, url: featureModels.appending(path: "melspectrogram.onnx"))
        embedding = try ONNXModel(env: env, url: featureModels.appending(path: "embedding_model.onnx"))
        classifier = try ONNXModel(env: env, url: model)
        mels = Self.initialMels
    }

    private static var initialMels: [Float] { Array(repeating: 1, count: melFrames * melBins) }

    /// Feeds 16 kHz mono samples in the Int16 range; returns the best score (0…1) of the completed chunks.
    public func process(_ samples: [Float]) throws -> Float {
        pending += samples
        var best: Float = 0
        while pending.count >= Self.chunk {
            recent = Array((recent + pending.prefix(Self.chunk)).suffix(Self.chunk + Self.context))
            pending.removeFirst(Self.chunk)
            guard recent.count == Self.chunk + Self.context else { continue }
            let mel = try melspectrogram.run(recent, shape: [1, recent.count]).map { $0 / 10 + 2 }
            mels = Array((mels + mel).suffix(Self.melFrames * Self.melBins))
            let vector = try embedding.run(mels, shape: [1, Self.melFrames, Self.melBins, 1])
            features = Array((features + vector).suffix(Self.embeddings * Self.embeddingSize))
            guard features.count == Self.embeddings * Self.embeddingSize else { continue }
            let score = try classifier.run(features, shape: [1, Self.embeddings, Self.embeddingSize])
            best = max(best, score.first ?? 0)
        }
        return best
    }

    /// Forgets the audio heard so far (after a detection, so the same words do not trigger twice).
    public func reset() {
        pending = []
        recent = []
        mels = Self.initialMels
        features = []
    }
}

/// One ONNX model with a single float input and output.
struct ONNXModel {
    private let session: ORTSession
    private let input: String
    private let output: String

    init(env: ORTEnv, url: URL) throws {
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(1)
        // Idle threads must sleep between the 80 ms chunks instead of spinning.
        try options.addConfigEntry(withKey: "session.intra_op.allow_spinning", value: "0")
        try options.addConfigEntry(withKey: "session.inter_op.allow_spinning", value: "0")
        session = try ORTSession(env: env, modelPath: url.path, sessionOptions: options)
        guard let input = try session.inputNames().first, let output = try session.outputNames().first else {
            throw WakeWordError.invalidModel(url.lastPathComponent)
        }
        self.input = input
        self.output = output
    }

    func run(_ values: [Float], shape: [Int]) throws -> [Float] {
        let data = values.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress, length: $0.count) }
        let tensor = try ORTValue(tensorData: data, elementType: .float, shape: shape.map { NSNumber(value: $0) })
        let outputs = try session.run(withInputs: [input: tensor], outputNames: [output], runOptions: nil)
        guard let result = try outputs[output]?.tensorData() else { return [] }
        let count = result.length / MemoryLayout<Float>.stride
        return Array(UnsafeBufferPointer(start: result.bytes.assumingMemoryBound(to: Float.self), count: count))
    }
}

public enum WakeWordError: Error, LocalizedError, Equatable {
    case invalidModel(String)
    case modelNotFound

    public var errorDescription: String? {
        switch self {
        case .invalidModel(let name): String(localized: "The wake word model \(name) is not valid.")
        case .modelNotFound: String(localized: "The wake word model was not found.")
        }
    }
}
