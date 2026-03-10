import Foundation

/// Ports the openWakeWord streaming pipeline:
///   raw audio → melspectrogram.tflite → mel / 10 + 2 → embedding_model.tflite → 96-dim embeddings
///
/// Key constants (from openwakeword/utils.py):
///   Frame size:       1280 samples (80 ms at 16 kHz)
///   Raw overlap:      480 samples  (3 × 160)
///   Mel bins:         32
///   Mel window:       76 frames
///   Embedding dim:    96
///   Embedding depth:  16  (classifier lookback)
///   Mel transform:    x / 10 + 2
final class AudioFeatures {
    static let melBins        = 32
    static let melWindow      = 76
    static let embeddingDim   = 96
    static let embeddingDepth = 16
    static let rawOverlap     = 480   // 3 × 160
    static let frameSize      = 1280  // 80 ms at 16 kHz

    private let melModel: TFLiteInterpreterHelper
    private let embeddingModel: TFLiteInterpreterHelper

    private var rawOverlapBuffer: [Float]
    private var melBuffer: [[Float]]
    private(set) var embeddingBuffer: [[Float]]

    init(melModelPath: String, embeddingModelPath: String) throws {
        melModel      = try TFLiteInterpreterHelper(modelPath: melModelPath)
        embeddingModel = try TFLiteInterpreterHelper(modelPath: embeddingModelPath)

        rawOverlapBuffer = [Float](repeating: 0, count: Self.rawOverlap)
        melBuffer = (0..<Self.melWindow).map { _ in
            [Float](repeating: 1.0, count: Self.melBins)
        }
        embeddingBuffer = (0..<Self.embeddingDepth).map { _ in
            [Float](repeating: 0, count: Self.embeddingDim)
        }
    }

    func reset() {
        rawOverlapBuffer = [Float](repeating: 0, count: Self.rawOverlap)
        melBuffer = (0..<Self.melWindow).map { _ in
            [Float](repeating: 1.0, count: Self.melBins)
        }
        embeddingBuffer = (0..<Self.embeddingDepth).map { _ in
            [Float](repeating: 0, count: Self.embeddingDim)
        }
    }

    /// Process exactly `frameSize` (1280) new audio samples (Float32 in [-1, 1]).
    /// Returns `true` when a new embedding was produced.
    @discardableResult
    func processAudioChunk(_ newSamples: [Float]) -> Bool {
        // Scale Float32 [-1, 1] → Int16 range (mel model expects this)
        let scaled = newSamples.map { max(-32768.0, min(32767.0, $0 * 32768.0)) }

        // Build mel input: 480 overlap + 1280 new = 1760
        var melInput = rawOverlapBuffer
        melInput.append(contentsOf: scaled)

        // Store last 480 samples for next chunk's overlap
        rawOverlapBuffer = Array(scaled.suffix(Self.rawOverlap))

        // --- Mel spectrogram ---
        guard let melOutput = runMelSpectrogram(melInput) else { return false }

        let newFrames = melOutput.count / Self.melBins
        guard newFrames > 0 else { return false }

        // Shift mel buffer left and append transformed frames
        melBuffer.removeFirst(min(newFrames, melBuffer.count))
        for i in 0..<newFrames {
            let start = i * Self.melBins
            let frame = (0..<Self.melBins).map { j in
                melOutput[start + j] / 10.0 + 2.0
            }
            melBuffer.append(frame)
        }
        while melBuffer.count < Self.melWindow {
            melBuffer.insert([Float](repeating: 1.0, count: Self.melBins), at: 0)
        }

        // --- Embedding ---
        guard let embedding = runEmbedding(melBuffer) else { return false }

        embeddingBuffer.removeFirst(1)
        embeddingBuffer.append(embedding)

        return true
    }

    // MARK: - TFLite Inference

    private func runMelSpectrogram(_ samples: [Float]) -> [Float]? {
        do {
            try melModel.resizeInput(at: 0, to: [1, samples.count])
            let data = Data(bytes: samples, count: samples.count * MemoryLayout<Float>.size)
            try melModel.copyInput(data, at: 0)
            try melModel.invoke()
            return try melModel.outputFloats(at: 0)
        } catch {
            vcpLog("Mel spectrogram inference error: \(error.localizedDescription)")
            return nil
        }
    }

    private func runEmbedding(_ window: [[Float]]) -> [Float]? {
        do {
            var flat = [Float]()
            flat.reserveCapacity(Self.melWindow * Self.melBins)
            for frame in window { flat.append(contentsOf: frame) }

            try embeddingModel.resizeInput(at: 0, to: [1, Self.melWindow, Self.melBins, 1])
            let data = Data(bytes: flat, count: flat.count * MemoryLayout<Float>.size)
            try embeddingModel.copyInput(data, at: 0)
            try embeddingModel.invoke()
            return try embeddingModel.outputFloats(at: 0)
        } catch {
            vcpLog("Embedding inference error: \(error.localizedDescription)")
            return nil
        }
    }
}
