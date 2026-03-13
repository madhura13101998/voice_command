package com.example.voice_command

import android.util.Log
import org.tensorflow.lite.Interpreter
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

private const val TAG = "VoiceCommandPlugin"

internal fun vcpLog(message: String) {
    Log.d(TAG, message)
}

/**
 * Thin wrapper around TFLite [Interpreter] matching the iOS TFLiteInterpreterHelper API.
 * Supports resize → copy → invoke → read-output cycle for single-input / single-output models.
 */
internal class TFLiteInterpreterHelper(modelPath: String) {

    private val interpreter: Interpreter = Interpreter(File(modelPath))
    private var currentInputShape: IntArray? = null
    private var stagedInput: ByteBuffer? = null
    private var outputBuffer: ByteBuffer? = null

    val inputShape: IntArray? get() = currentInputShape

    init {
        try {
            interpreter.allocateTensors()
            currentInputShape = interpreter.getInputTensor(0).shape()
            vcpLog("TFLite model loaded: $modelPath")
            vcpLog("  Input shape: ${currentInputShape?.contentToString()}")
        } catch (e: Exception) {
            currentInputShape = null
            vcpLog("TFLite model loaded (deferred alloc): $modelPath")
        }
    }

    fun resizeInput(index: Int, shape: IntArray) {
        if (currentInputShape?.contentEquals(shape) == true) return
        interpreter.resizeInput(index, shape)
        interpreter.allocateTensors()
        currentInputShape = shape
    }

    fun copyInput(data: ByteBuffer, index: Int) {
        data.rewind()
        stagedInput = data
    }

    fun invoke() {
        val input = stagedInput ?: throw IllegalStateException("No input staged")
        input.rewind()

        val outTensor = interpreter.getOutputTensor(0)
        val outBuf = ByteBuffer.allocateDirect(outTensor.numBytes())
            .order(ByteOrder.nativeOrder())

        interpreter.run(input, outBuf)
        outBuf.rewind()
        outputBuffer = outBuf
        stagedInput = null
    }

    fun outputFloats(index: Int): FloatArray {
        val buf = outputBuffer ?: throw IllegalStateException("No output available at index $index")
        buf.rewind()
        val fb = buf.asFloatBuffer()
        val result = FloatArray(fb.remaining())
        fb.get(result)
        return result
    }

    fun close() {
        interpreter.close()
    }
}
