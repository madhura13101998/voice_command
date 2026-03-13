package com.example.voice_command

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry
import java.io.File
import java.io.FileOutputStream

class VoiceCommandPlugin :
    FlutterPlugin,
    MethodCallHandler,
    EventChannel.StreamHandler,
    ActivityAware,
    PluginRegistry.RequestPermissionsResultListener {

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private var eventSink: EventChannel.EventSink? = null

    private var context: Context? = null
    private var activity: Activity? = null
    private var flutterAssets: FlutterPlugin.FlutterAssets? = null
    private var speechRecognizer: SpeechRecognizer? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    // STT Configuration
    private var debounceDuration: Long = 1500L
    private var sessionFlushInterval: Long = 59000L
    private var locale: String? = null

    // STT State
    private var isCurrentlyListening = false
    private var isPaused = false
    private var speechBuffer = ""
    private var debounceRunnable: Runnable? = null
    private var sessionFlushRunnable: Runnable? = null
    private var pendingPermissionResult: Result? = null

    // Wake Word State
    private var isWakeWordActive = false
    private var wakeWordDetector: WakeWordDetector? = null
    private var audioRecord: AudioRecord? = null
    @Volatile private var wakeWordCaptureRunning = false
    private var wakeWordThread: Thread? = null
    private val modelFileCache = mutableMapOf<String, String>()

    companion object {
        private const val PERMISSION_REQUEST_CODE = 9001
        private const val SAMPLE_RATE = 16000
        private const val AUDIO_BUFFER_SIZE = 1280
    }

    // ── Plugin lifecycle ────────────────────────────────────────────────

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        flutterAssets = binding.flutterAssets
        methodChannel = MethodChannel(binding.binaryMessenger, "voice_command")
        eventChannel = EventChannel(binding.binaryMessenger, "voice_command/events")
        methodChannel.setMethodCallHandler(this)
        eventChannel.setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        tearDown()
        flutterAssets = null
    }

    // ── EventChannel.StreamHandler ──────────────────────────────────────

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    // ── ActivityAware ───────────────────────────────────────────────────

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() { activity = null }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivity() { activity = null }

    // ── Permission callback ─────────────────────────────────────────────

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ): Boolean {
        if (requestCode != PERMISSION_REQUEST_CODE) return false
        val granted = grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
        pendingPermissionResult?.success(granted)
        pendingPermissionResult = null
        return true
    }

    // ── Method dispatch ─────────────────────────────────────────────────

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "requestPermissions" -> requestPermissions(result)

            "startListening" -> {
                val debounce = call.argument<Double>("debounceDuration") ?: 1.5
                val flush = call.argument<Double>("sessionFlushInterval") ?: 59.0
                val loc = call.argument<String>("locale")
                startListening(debounce, flush, loc, result)
            }

            "stopListening"   -> stopListening(result)
            "pauseListening"  -> pauseListening(result)
            "resumeListening" -> resumeListening(result)
            "clearBuffer"     -> clearBuffer(result)
            "isListening"     -> result.success(isCurrentlyListening && !isPaused)

            "reapplyAudioSession" -> reapplyAudioSession(result)

            "startWakeWordDetection" -> {
                val args = call.arguments as? Map<*, *>
                val modelPath = args?.get("modelPath") as? String
                val threshold = (args?.get("threshold") as? Double)?.toFloat() ?: 0.5f
                @Suppress("UNUSED_VARIABLE")
                val inputSize = args?.get("inputSize") as? Int ?: 1280
                startWakeWordDetection(modelPath, threshold, result)
            }

            "stopWakeWordDetection" -> stopWakeWordDetection(result)
            "isWakeWordActive"      -> result.success(isWakeWordActive)

            else -> result.notImplemented()
        }
    }

    // ── Permissions ─────────────────────────────────────────────────────

    private fun requestPermissions(result: Result) {
        val act = activity ?: run {
            result.error("NO_ACTIVITY", "No activity available", null)
            return
        }
        if (ContextCompat.checkSelfPermission(act, Manifest.permission.RECORD_AUDIO)
            == PackageManager.PERMISSION_GRANTED
        ) {
            result.success(true)
        } else {
            pendingPermissionResult = result
            ActivityCompat.requestPermissions(
                act,
                arrayOf(Manifest.permission.RECORD_AUDIO),
                PERMISSION_REQUEST_CODE
            )
        }
    }

    // ── Start Listening (STT) ───────────────────────────────────────────

    private fun startListening(
        debounceDuration: Double,
        sessionFlushInterval: Double,
        locale: String?,
        result: Result
    ) {
        if (isWakeWordActive) {
            vcpLog("Transitioning from wake-word to STT")
            stopWakeWordEngine()
        }

        if (isCurrentlyListening) {
            result.error("ALREADY_LISTENING", "Already listening", null)
            return
        }
        if (!SpeechRecognizer.isRecognitionAvailable(context ?: return)) {
            result.error("UNAVAILABLE",
                "Speech recognition is not available on this device", null)
            return
        }

        this.debounceDuration = (debounceDuration * 1000).toLong()
        this.sessionFlushInterval = (sessionFlushInterval * 1000).toLong()
        this.locale = locale

        isCurrentlyListening = true
        isPaused = false
        speechBuffer = ""
        startRecognizer()
        scheduleSessionFlush()
        sendEvent("listeningStarted")
        result.success(null)
    }

    // ── Stop Listening (STT) ────────────────────────────────────────────

    private fun stopListening(result: Result) {
        if (!isCurrentlyListening) { result.success(null); return }
        firePendingDebounce()
        tearDownStt()
        isCurrentlyListening = false
        isPaused = false
        sendEvent("listeningStopped")
        result.success(null)
    }

    // ── Pause / Resume ──────────────────────────────────────────────────

    private fun pauseListening(result: Result) {
        if (!isCurrentlyListening || isPaused) { result.success(null); return }
        firePendingDebounce()
        speechRecognizer?.cancel()
        speechRecognizer?.destroy()
        speechRecognizer = null
        sessionFlushRunnable?.let { mainHandler.removeCallbacks(it) }
        sessionFlushRunnable = null
        isPaused = true
        sendEvent("listeningPaused")
        result.success(null)
    }

    private fun resumeListening(result: Result) {
        if (!isCurrentlyListening || !isPaused) { result.success(null); return }
        isPaused = false
        speechBuffer = ""
        startRecognizer()
        scheduleSessionFlush()
        sendEvent("listeningResumed")
        result.success(null)
    }

    // ── Clear buffer ────────────────────────────────────────────────────

    private fun clearBuffer(result: Result) {
        speechBuffer = ""
        debounceRunnable?.let { mainHandler.removeCallbacks(it) }
        debounceRunnable = null
        result.success(null)
    }

    // ── Reapply Audio Session ───────────────────────────────────────────

    private fun reapplyAudioSession(result: Result) {
        vcpLog("reapplyAudioSession called")
        if (isWakeWordActive) {
            stopWakeWordEngine()
            mainHandler.postDelayed({
                // Restart wake word pipeline if it was active
                // The caller is expected to call startWakeWordDetection again if needed
            }, 300)
            result.success(null)
        } else if (isCurrentlyListening && !isPaused) {
            speechRecognizer?.cancel()
            speechRecognizer?.destroy()
            speechRecognizer = null
            mainHandler.postDelayed({
                if (isCurrentlyListening && !isPaused) {
                    startRecognizer()
                    vcpLog("reapplyAudioSession: STT pipeline restarted")
                }
            }, 300)
            result.success(null)
        } else {
            result.success(null)
        }
    }

    // ── Wake Word Detection ─────────────────────────────────────────────

    private fun startWakeWordDetection(
        modelPath: String?,
        threshold: Float,
        result: Result
    ) {
        requestPermissions(result);

        vcpLog("startWakeWordDetection called (3-stage pipeline)")

        if (isWakeWordActive) {
            result.error("ALREADY_ACTIVE", "Wake word detection already active", null)
            return
        }

        if (isCurrentlyListening) {
            vcpLog("Stopping STT before starting wake-word detection")
            firePendingDebounce()
            tearDownStt()
            isCurrentlyListening = false
            isPaused = false
        }

        val ctx = context ?: run {
            result.error("NO_CONTEXT", "No application context available", null)
            return
        }

        val melPath = resolveModelPath(ctx, "melspectrogram")
        if (melPath == null) {
            result.error("MODEL_ERROR",
                "melspectrogram.tflite not found. Declare it as a Flutter asset.", null)
            return
        }
        val embPath = resolveModelPath(ctx, "embedding_model")
        if (embPath == null) {
            result.error("MODEL_ERROR",
                "embedding_model.tflite not found. Declare it as a Flutter asset.", null)
            return
        }
        val clsPath = resolveModelPath(ctx, "wake_word", explicitPath = modelPath)
        if (clsPath == null) {
            result.error("MODEL_ERROR",
                "wake_word.tflite not found. Declare it as a Flutter asset or pass modelPath.", null)
            return
        }

        try {
            val detector = WakeWordDetector(
                melModelPath = melPath,
                embeddingModelPath = embPath,
                classifierModelPath = clsPath,
                threshold = threshold,
                cooldownIntervalMs = 2000L
            )
            detector.onDetection = { _ ->
                sendEvent("wakeWordDetected")
            }
            wakeWordDetector = detector
        } catch (e: Exception) {
            vcpLog("Failed to create WakeWordDetector: ${e.message}")
            result.error("MODEL_ERROR",
                "Failed to initialize wake word models: ${e.message}", null)
            return
        }

        if (startWakeWordPipeline()) {
            isWakeWordActive = true
            sendEvent("wakeWordListeningStarted")
            result.success(null)
        } else {
            wakeWordDetector?.close()
            wakeWordDetector = null
            result.error("AUDIO_ERROR", "Failed to start wake word audio pipeline", null)
        }
    }

    private fun stopWakeWordDetection(result: Result) {
        if (!isWakeWordActive) {
            result.success(null)
            return
        }
        stopWakeWordEngine()
        sendEvent("wakeWordListeningStopped")
        result.success(null)
    }

    private fun stopWakeWordEngine() {
        vcpLog("stopWakeWordEngine called")
        wakeWordCaptureRunning = false
        wakeWordThread?.let { thread ->
            try { thread.join(1000) } catch (_: InterruptedException) {}
        }
        wakeWordThread = null

        audioRecord?.let { rec ->
            try {
                if (rec.recordingState == AudioRecord.RECORDSTATE_RECORDING) {
                    rec.stop()
                }
                rec.release()
            } catch (e: Exception) {
                vcpLog("Error releasing AudioRecord: ${e.message}")
            }
        }
        audioRecord = null

        wakeWordDetector?.close()
        wakeWordDetector = null
        isWakeWordActive = false
    }

    @Suppress("MissingPermission")
    private fun startWakeWordPipeline(): Boolean {
        val minBufSize = AudioRecord.getMinBufferSize(
            SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT
        )
        if (minBufSize == AudioRecord.ERROR || minBufSize == AudioRecord.ERROR_BAD_VALUE) {
            vcpLog("AudioRecord.getMinBufferSize failed: $minBufSize")
            return false
        }

        val bufferSize = maxOf(minBufSize, AUDIO_BUFFER_SIZE * 2 * 2) // at least 2 frames worth
        val record = try {
            AudioRecord(
                MediaRecorder.AudioSource.MIC,
                SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                bufferSize
            )
        } catch (e: Exception) {
            vcpLog("Failed to create AudioRecord: ${e.message}")
            return false
        }

        if (record.state != AudioRecord.STATE_INITIALIZED) {
            vcpLog("AudioRecord not initialized")
            record.release()
            return false
        }

        audioRecord = record
        record.startRecording()
        wakeWordCaptureRunning = true

        wakeWordThread = Thread({
            val shortBuffer = ShortArray(AUDIO_BUFFER_SIZE)
            while (wakeWordCaptureRunning) {
                val read = record.read(shortBuffer, 0, shortBuffer.size)
                if (read > 0) {
                    val floatSamples = FloatArray(read) { shortBuffer[it] / 32768.0f }
                    wakeWordDetector?.processAudio(floatSamples)
                }
            }
        }, "WakeWordCapture").apply {
            priority = Thread.MAX_PRIORITY
            start()
        }

        vcpLog("Wake word pipeline started (AudioRecord ${SAMPLE_RATE}Hz mono)")
        return true
    }

    // ── Model Path Resolution ───────────────────────────────────────────

    /**
     * Resolves a .tflite model to an absolute file path that TFLite Interpreter can load.
     * Strategy:
     *   1. If an explicit path is given, try it as a Flutter asset key first, then as an absolute path.
     *   2. Look up the default asset key "assets/<name>.tflite" via FlutterLoader.
     *   3. Copy from APK assets to a cache file (TFLite needs a real File, not an InputStream).
     */
    private fun resolveModelPath(ctx: Context, name: String, ext: String = "tflite", explicitPath: String? = null): String? {
        // Try explicit path first
        if (explicitPath != null) {
            val resolved = resolveFlutterAssetToFile(ctx, explicitPath)
            if (resolved != null) return resolved
            if (File(explicitPath).exists()) return explicitPath
        }

        // Try common Flutter asset locations
        val candidates = listOf(
            "assets/$name.$ext",
            "assets/models/$name.$ext",
            "$name.$ext"
        )
        for (candidate in candidates) {
            val resolved = resolveFlutterAssetToFile(ctx, candidate)
            if (resolved != null) return resolved
        }

        return null
    }

    /**
     * Given a Flutter asset key, resolves it to a filesystem path by copying from APK assets
     * into the app's cache directory. Results are cached for the session.
     */
    private fun resolveFlutterAssetToFile(ctx: Context, assetKey: String): String? {
        modelFileCache[assetKey]?.let { cached ->
            if (File(cached).exists()) return cached
        }

        val lookupKey = flutterAssets?.getAssetFilePathByName(assetKey) ?: assetKey

        return try {
            val inputStream = ctx.assets.open(lookupKey)
            val cacheFile = File(ctx.cacheDir, "voice_command_models/${File(lookupKey).name}")
            cacheFile.parentFile?.mkdirs()
            FileOutputStream(cacheFile).use { out ->
                inputStream.use { it.copyTo(out) }
            }
            modelFileCache[assetKey] = cacheFile.absolutePath
            vcpLog("Model cached: $assetKey -> ${cacheFile.absolutePath}")
            cacheFile.absolutePath
        } catch (e: Exception) {
            null
        }
    }

    // ── SpeechRecognizer ────────────────────────────────────────────────

    private fun buildRecognizerIntent(): Intent =
        Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
            putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_MINIMUM_LENGTH_MILLIS,
                sessionFlushInterval)
            putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS,
                10_000L)
            putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS,
                10_000L)
            locale?.let { putExtra(RecognizerIntent.EXTRA_LANGUAGE, it) }
        }

    private fun startRecognizer() {
        mainHandler.post {
            try {
                speechRecognizer?.destroy()
                speechRecognizer = SpeechRecognizer.createSpeechRecognizer(context ?: return@post).apply {
                    setRecognitionListener(recognitionListener)
                }
                speechRecognizer?.startListening(buildRecognizerIntent())
            } catch (e: Exception) {
                sendEvent("error",
                    errorMessage = e.localizedMessage ?: "Failed to start recognizer",
                    errorCode = "START_ERROR")
            }
        }
    }

    private fun scheduleRecognizerRestart() {
        mainHandler.postDelayed({
            if (isCurrentlyListening && !isPaused) startRecognizer()
        }, 300)
    }

    private val recognitionListener = object : RecognitionListener {
        override fun onReadyForSpeech(params: Bundle?) {}
        override fun onBeginningOfSpeech() {}
        override fun onRmsChanged(rmsdB: Float) {}
        override fun onBufferReceived(buffer: ByteArray?) {}
        override fun onEndOfSpeech() {}
        override fun onEvent(eventType: Int, params: Bundle?) {}

        override fun onPartialResults(partial: Bundle?) {
            partial?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                ?.firstOrNull()
                ?.takeIf { it.isNotEmpty() }
                ?.let { processResult(it) }
        }

        override fun onResults(results: Bundle?) {
            results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                ?.firstOrNull()
                ?.takeIf { it.isNotEmpty() }
                ?.let { processResult(it) }
            if (isCurrentlyListening && !isPaused) scheduleRecognizerRestart()
        }

        override fun onError(error: Int) {
            if (error != SpeechRecognizer.ERROR_NO_MATCH &&
                error != SpeechRecognizer.ERROR_SPEECH_TIMEOUT
            ) {
                sendEvent("error",
                    errorMessage = speechErrorMessage(error),
                    errorCode = error.toString())
            }
            if (isCurrentlyListening && !isPaused) scheduleRecognizerRestart()
        }
    }

    // ── Processing ──────────────────────────────────────────────────────

    private fun processResult(text: String) {
        speechBuffer = text
        sendEvent("partialResult", text = text)
        resetDebounceTimer()
    }

    // ── Debounce ────────────────────────────────────────────────────────

    private fun resetDebounceTimer() {
        debounceRunnable?.let { mainHandler.removeCallbacks(it) }
        debounceRunnable = Runnable {
            val text = speechBuffer.trim()
            if (text.isEmpty()) return@Runnable
            sendEvent("result", text = text)
            speechBuffer = ""
            if (isCurrentlyListening && !isPaused) {
                speechRecognizer?.cancel()
                scheduleRecognizerRestart()
            }
        }
        mainHandler.postDelayed(debounceRunnable!!, debounceDuration)
    }

    private fun firePendingDebounce() {
        debounceRunnable?.let {
            mainHandler.removeCallbacks(it)
            it.run()
        }
        debounceRunnable = null
    }

    // ── Session flush ───────────────────────────────────────────────────

    private fun scheduleSessionFlush() {
        sessionFlushRunnable?.let { mainHandler.removeCallbacks(it) }
        sessionFlushRunnable = Runnable {
            if (isCurrentlyListening && !isPaused) {
                flushSession()
                scheduleSessionFlush()
            }
        }
        mainHandler.postDelayed(sessionFlushRunnable!!, sessionFlushInterval)
    }

    private fun flushSession() {
        firePendingDebounce()
        speechBuffer = ""
        speechRecognizer?.cancel()
        mainHandler.postDelayed({
            if (isCurrentlyListening && !isPaused) {
                startRecognizer()
                sendEvent("sessionFlushed")
            }
        }, 300)
    }

    // ── Teardown ────────────────────────────────────────────────────────

    private fun tearDownStt() {
        debounceRunnable?.let { mainHandler.removeCallbacks(it) }
        debounceRunnable = null
        sessionFlushRunnable?.let { mainHandler.removeCallbacks(it) }
        sessionFlushRunnable = null
        speechRecognizer?.cancel()
        speechRecognizer?.destroy()
        speechRecognizer = null
        speechBuffer = ""
    }

    private fun tearDown() {
        tearDownStt()
        if (isWakeWordActive) {
            stopWakeWordEngine()
        }
    }

    // ── Event dispatch ──────────────────────────────────────────────────

    private fun sendEvent(
        type: String,
        text: String? = null,
        errorMessage: String? = null,
        errorCode: String? = null
    ) {
        mainHandler.post {
            val payload = mutableMapOf<String, Any>("type" to type)
            text?.let { payload["text"] = it }
            errorMessage?.let { payload["errorMessage"] = it }
            errorCode?.let { payload["errorCode"] = it }
            eventSink?.success(payload)
        }
    }

    private fun speechErrorMessage(code: Int): String = when (code) {
        SpeechRecognizer.ERROR_AUDIO                -> "Audio recording error"
        SpeechRecognizer.ERROR_CLIENT               -> "Client error"
        SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "Insufficient permissions"
        SpeechRecognizer.ERROR_NETWORK              -> "Network error"
        SpeechRecognizer.ERROR_NETWORK_TIMEOUT      -> "Network timeout"
        SpeechRecognizer.ERROR_NO_MATCH             -> "No speech detected"
        SpeechRecognizer.ERROR_RECOGNIZER_BUSY      -> "Recognizer busy"
        SpeechRecognizer.ERROR_SERVER               -> "Server error"
        SpeechRecognizer.ERROR_SPEECH_TIMEOUT       -> "No speech input"
        else                                        -> "Unknown error ($code)"
    }
}
