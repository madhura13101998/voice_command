import TensorFlowLite

func vcpLog(_ message: String) {
    print("[VoiceCommandPlugin] \(message)")
}

final class TFLiteInterpreterHelper {
    private var interpreter: Interpreter
    private var currentInputShape: [Int]?

    init(modelPath: String) throws {
        interpreter = try Interpreter(modelPath: modelPath)
        // Some models (e.g. melspectrogram) have a default input shape that
        // overflows on allocateTensors -- they must be resized first.
        // Try eagerly; fall back to deferred allocation on first resizeInput.
        do {
            try interpreter.allocateTensors()
            let inputTensor = try interpreter.input(at: 0)
            currentInputShape = inputTensor.shape.dimensions
            vcpLog("TFLite model loaded: \(modelPath)")
            vcpLog("  Input shape: \(inputTensor.shape.dimensions), dtype: \(inputTensor.dataType)")
        } catch {
            currentInputShape = nil
            vcpLog("TFLite model loaded (deferred alloc): \(modelPath)")
        }
    }

    var inputShape: [Int]? { currentInputShape }

    func resizeInput(at index: Int, to shape: [Int]) throws {
        guard currentInputShape != shape else { return }
        try interpreter.resizeInput(at: index, to: Tensor.Shape(shape))
        try interpreter.allocateTensors()
        currentInputShape = shape
    }

    func copyInput(_ data: Data, at index: Int) throws {
        try interpreter.copy(data, toInputAt: index)
    }

    func invoke() throws {
        try interpreter.invoke()
    }

    func outputData(at index: Int) throws -> Data {
        return try interpreter.output(at: index).data
    }

    func outputFloats(at index: Int) throws -> [Float] {
        let data = try outputData(at: index)
        let count = data.count / MemoryLayout<Float>.size
        return data.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return [Float]() }
            return Array(UnsafeBufferPointer(
                start: base.assumingMemoryBound(to: Float.self),
                count: count
            ))
        }
    }

    func outputShape(at index: Int) throws -> [Int] {
        return try interpreter.output(at: index).shape.dimensions
    }
}
