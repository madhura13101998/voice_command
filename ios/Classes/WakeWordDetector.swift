import Foundation

/// Orchestrates the 3-stage openWakeWord pipeline:
///   AudioFeatures (mel + embedding) → classifier → detection event
///
/// All inference runs on a dedicated background queue.
/// The first `initSkipFrames` predictions are discarded (model warm-up).
final class WakeWordDetector {
    private let audioFeatures: AudioFeatures
    private let classifier: TFLiteInterpreterHelper
    private let threshold: Float
    private let cooldownInterval: TimeInterval
    private let initSkipFrames = 5

    private var frameCount = 0
    private var cooldownDate: Date?
    private var audioAccumulator: [Float] = []

    private let inferenceQueue = DispatchQueue(
        label: "com.voicecommand.wakeword",
        qos: .userInitiated
    )

    /// Called on the main queue when the wake word is detected.
    var onDetection: ((Float) -> Void)?

    init(
        melModelPath: String,
        embeddingModelPath: String,
        classifierModelPath: String,
        threshold: Float = 0.5,
        cooldownInterval: TimeInterval = 2.0
    ) throws {
        audioFeatures = try AudioFeatures(
            melModelPath: melModelPath,
            embeddingModelPath: embeddingModelPath
        )
        classifier = try TFLiteInterpreterHelper(modelPath: classifierModelPath)
        self.threshold = threshold
        self.cooldownInterval = cooldownInterval
    }

    func reset() {
        inferenceQueue.async { [weak self] in
            self?.audioAccumulator.removeAll()
            self?.audioFeatures.reset()
            self?.frameCount = 0
            self?.cooldownDate = nil
        }
    }

    /// Feed any amount of resampled 16 kHz mono Float32 audio ([-1, 1]).
    /// Internally accumulates into 1280-sample chunks before processing.
    func processAudio(_ samples: [Float]) {
        inferenceQueue.async { [weak self] in
            self?.accumulateAndInfer(samples)
        }
    }

    // MARK: - Internal

    private func accumulateAndInfer(_ samples: [Float]) {
        audioAccumulator.append(contentsOf: samples)

        while audioAccumulator.count >= AudioFeatures.frameSize {
            let chunk = Array(audioAccumulator.prefix(AudioFeatures.frameSize))
            audioAccumulator.removeFirst(AudioFeatures.frameSize)

            guard audioFeatures.processAudioChunk(chunk) else { continue }
            frameCount += 1

            guard frameCount > initSkipFrames else { continue }
            if let cd = cooldownDate, Date() < cd { continue }

            guard let score = runClassifier() else { continue }

            if score >= threshold {
                vcpLog("Wake word detected! score=\(score) (threshold=\(threshold))")
                cooldownDate = Date().addingTimeInterval(cooldownInterval)
                let cb = onDetection
                DispatchQueue.main.async { cb?(score) }
            }
        }
    }

    private func runClassifier() -> Float? {
        do {
            var flat = [Float]()
            flat.reserveCapacity(AudioFeatures.embeddingDepth * AudioFeatures.embeddingDim)
            for emb in audioFeatures.embeddingBuffer {
                flat.append(contentsOf: emb)
            }

            try classifier.resizeInput(
                at: 0,
                to: [1, AudioFeatures.embeddingDepth, AudioFeatures.embeddingDim]
            )
            let data = Data(bytes: flat, count: flat.count * MemoryLayout<Float>.size)
            try classifier.copyInput(data, at: 0)
            try classifier.invoke()

            let output = try classifier.outputFloats(at: 0)
            return output.first
        } catch {
            vcpLog("Classifier inference error: \(error.localizedDescription)")
            return nil
        }
    }
}
