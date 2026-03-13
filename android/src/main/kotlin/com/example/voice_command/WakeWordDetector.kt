package com.example.voice_command

import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Orchestrates the 3-stage openWakeWord pipeline:
 *   AudioFeatures (mel + embedding) -> classifier -> detection event
 *
 * All inference runs on a dedicated background thread.
 * The first [INIT_SKIP_FRAMES] predictions are discarded (model warm-up).
 */
internal class WakeWordDetector(
    melModelPath: String,
    embeddingModelPath: String,
    classifierModelPath: String,
    private val threshold: Float = 0.5f,
    private val cooldownIntervalMs: Long = 2000L
) {
    companion object {
        private const val INIT_SKIP_FRAMES = 5
    }

    private val audioFeatures = AudioFeatures(melModelPath, embeddingModelPath)
    private val classifier = TFLiteInterpreterHelper(classifierModelPath)

    private var frameCount = 0
    private var cooldownUntil = 0L
    private val audioAccumulator = mutableListOf<Float>()

    private val inferenceThread = HandlerThread("WakeWordInference").apply { start() }
    private val inferenceHandler = Handler(inferenceThread.looper)
    private val mainHandler = Handler(Looper.getMainLooper())

    /** Called on the main thread when the wake word is detected. */
    var onDetection: ((Float) -> Unit)? = null

    fun reset() {
        inferenceHandler.post {
            audioAccumulator.clear()
            audioFeatures.reset()
            frameCount = 0
            cooldownUntil = 0L
        }
    }

    /** Feed any amount of resampled 16 kHz mono Float32 audio ([-1, 1]). */
    fun processAudio(samples: FloatArray) {
        inferenceHandler.post {
            accumulateAndInfer(samples)
        }
    }

    fun close() {
        inferenceThread.quitSafely()
        audioFeatures.close()
        classifier.close()
    }

    // -- Internal --

    private fun accumulateAndInfer(samples: FloatArray) {
        for (s in samples) audioAccumulator.add(s)

        while (audioAccumulator.size >= AudioFeatures.FRAME_SIZE) {
            val chunk = FloatArray(AudioFeatures.FRAME_SIZE) { audioAccumulator[it] }
            repeat(AudioFeatures.FRAME_SIZE) { audioAccumulator.removeAt(0) }

            if (!audioFeatures.processAudioChunk(chunk)) continue
            frameCount++

            if (frameCount <= INIT_SKIP_FRAMES) continue
            if (System.currentTimeMillis() < cooldownUntil) continue

            val score = runClassifier() ?: continue

            if (score >= threshold) {
                vcpLog("Wake word detected! score=$score (threshold=$threshold)")
                cooldownUntil = System.currentTimeMillis() + cooldownIntervalMs
                val cb = onDetection
                mainHandler.post { cb?.invoke(score) }
            }
        }
    }

    private fun runClassifier(): Float? {
        return try {
            val embBuf = audioFeatures.embeddingBuffer
            val flat = FloatArray(AudioFeatures.EMBEDDING_DEPTH * AudioFeatures.EMBEDDING_DIM)
            var offset = 0
            for (emb in embBuf) {
                emb.copyInto(flat, destinationOffset = offset)
                offset += emb.size
            }

            classifier.resizeInput(
                0,
                intArrayOf(1, AudioFeatures.EMBEDDING_DEPTH, AudioFeatures.EMBEDDING_DIM)
            )
            val buf = ByteBuffer.allocateDirect(flat.size * 4).order(ByteOrder.nativeOrder())
            buf.asFloatBuffer().put(flat)
            buf.rewind()
            classifier.copyInput(buf, 0)
            classifier.invoke()

            val output = classifier.outputFloats(0)
            output.firstOrNull()
        } catch (e: Exception) {
            vcpLog("Classifier inference error: ${e.message}")
            null
        }
    }
}
