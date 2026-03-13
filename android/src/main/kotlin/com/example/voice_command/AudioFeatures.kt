package com.example.voice_command

import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Ports the openWakeWord streaming pipeline:
 *   raw audio -> melspectrogram.tflite -> mel / 10 + 2 -> embedding_model.tflite -> 96-dim embeddings
 *
 * Key constants (from openwakeword/utils.py):
 *   Frame size:       1280 samples (80 ms at 16 kHz)
 *   Raw overlap:      480 samples  (3 x 160)
 *   Mel bins:         32
 *   Mel window:       76 frames
 *   Embedding dim:    96
 *   Embedding depth:  16  (classifier lookback)
 *   Mel transform:    x / 10 + 2
 */
internal class AudioFeatures(
    melModelPath: String,
    embeddingModelPath: String
) {
    companion object {
        const val MEL_BINS = 32
        const val MEL_WINDOW = 76
        const val EMBEDDING_DIM = 96
        const val EMBEDDING_DEPTH = 16
        const val RAW_OVERLAP = 480   // 3 x 160
        const val FRAME_SIZE = 1280   // 80 ms at 16 kHz
    }

    private val melModel = TFLiteInterpreterHelper(melModelPath)
    private val embeddingModel = TFLiteInterpreterHelper(embeddingModelPath)

    private var rawOverlapBuffer = FloatArray(RAW_OVERLAP)
    private var melBuffer = MutableList(MEL_WINDOW) { FloatArray(MEL_BINS) { 1.0f } }
    var embeddingBuffer = MutableList(EMBEDDING_DEPTH) { FloatArray(EMBEDDING_DIM) }
        private set

    fun reset() {
        rawOverlapBuffer = FloatArray(RAW_OVERLAP)
        melBuffer = MutableList(MEL_WINDOW) { FloatArray(MEL_BINS) { 1.0f } }
        embeddingBuffer = MutableList(EMBEDDING_DEPTH) { FloatArray(EMBEDDING_DIM) }
    }

    /**
     * Process exactly [FRAME_SIZE] (1280) new audio samples (Float32 in [-1, 1]).
     * Returns `true` when a new embedding was produced.
     */
    fun processAudioChunk(newSamples: FloatArray): Boolean {
        // Scale Float32 [-1, 1] -> Int16 range (mel model expects this)
        val scaled = FloatArray(newSamples.size) { i ->
            (newSamples[i] * 32768.0f).coerceIn(-32768.0f, 32767.0f)
        }

        // Build mel input: 480 overlap + 1280 new = 1760
        val melInput = FloatArray(rawOverlapBuffer.size + scaled.size)
        rawOverlapBuffer.copyInto(melInput)
        scaled.copyInto(melInput, destinationOffset = rawOverlapBuffer.size)

        // Store last 480 samples for next chunk's overlap
        scaled.copyInto(rawOverlapBuffer, startIndex = scaled.size - RAW_OVERLAP)

        // --- Mel spectrogram ---
        val melOutput = runMelSpectrogram(melInput) ?: return false

        val newFrames = melOutput.size / MEL_BINS
        if (newFrames <= 0) return false

        // Shift mel buffer left and append transformed frames
        val toRemove = minOf(newFrames, melBuffer.size)
        repeat(toRemove) { melBuffer.removeAt(0) }
        for (i in 0 until newFrames) {
            val start = i * MEL_BINS
            val frame = FloatArray(MEL_BINS) { j -> melOutput[start + j] / 10.0f + 2.0f }
            melBuffer.add(frame)
        }
        while (melBuffer.size < MEL_WINDOW) {
            melBuffer.add(0, FloatArray(MEL_BINS) { 1.0f })
        }

        // --- Embedding ---
        val embedding = runEmbedding(melBuffer) ?: return false

        embeddingBuffer.removeAt(0)
        embeddingBuffer.add(embedding)

        return true
    }

    fun close() {
        melModel.close()
        embeddingModel.close()
    }

    // -- TFLite Inference --

    private fun runMelSpectrogram(samples: FloatArray): FloatArray? {
        return try {
            melModel.resizeInput(0, intArrayOf(1, samples.size))
            val buf = floatArrayToByteBuffer(samples)
            melModel.copyInput(buf, 0)
            melModel.invoke()
            melModel.outputFloats(0)
        } catch (e: Exception) {
            vcpLog("Mel spectrogram inference error: ${e.message}")
            null
        }
    }

    private fun runEmbedding(window: List<FloatArray>): FloatArray? {
        return try {
            val flat = FloatArray(MEL_WINDOW * MEL_BINS)
            var offset = 0
            for (frame in window) {
                frame.copyInto(flat, destinationOffset = offset)
                offset += frame.size
            }

            embeddingModel.resizeInput(0, intArrayOf(1, MEL_WINDOW, MEL_BINS, 1))
            val buf = floatArrayToByteBuffer(flat)
            embeddingModel.copyInput(buf, 0)
            embeddingModel.invoke()
            embeddingModel.outputFloats(0)
        } catch (e: Exception) {
            vcpLog("Embedding inference error: ${e.message}")
            null
        }
    }

    private fun floatArrayToByteBuffer(data: FloatArray): ByteBuffer {
        val buf = ByteBuffer.allocateDirect(data.size * 4).order(ByteOrder.nativeOrder())
        buf.asFloatBuffer().put(data)
        buf.rewind()
        return buf
    }
}
