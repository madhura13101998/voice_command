package com.example.voice_command

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
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
    private var speechRecognizer: SpeechRecognizer? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    // Configuration
    private var debounceDuration: Long = 1500L
    private var sessionFlushInterval: Long = 59000L
    private var locale: String? = null

    // State
    private var isCurrentlyListening = false
    private var isPaused = false
    private var speechBuffer = ""
    private var debounceRunnable: Runnable? = null
    private var sessionFlushRunnable: Runnable? = null
    private var pendingPermissionResult: Result? = null

    companion object {
        private const val PERMISSION_REQUEST_CODE = 9001
    }

    // ── Plugin lifecycle ────────────────────────────────────────────────

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, "voice_command")
        eventChannel = EventChannel(binding.binaryMessenger, "voice_command/events")
        methodChannel.setMethodCallHandler(this)
        eventChannel.setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        tearDown()
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
            else              -> result.notImplemented()
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

    // ── Start ───────────────────────────────────────────────────────────

    private fun startListening(
        debounceDuration: Double,
        sessionFlushInterval: Double,
        locale: String?,
        result: Result
    ) {
        if (isCurrentlyListening) {
            result.error("ALREADY_LISTENING", "Already listening", null)
            return
        }
        if (!SpeechRecognizer.isRecognitionAvailable(context)) {
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

    // ── Stop ────────────────────────────────────────────────────────────

    private fun stopListening(result: Result) {
        if (!isCurrentlyListening) { result.success(null); return }
        firePendingDebounce()
        tearDown()
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
                speechRecognizer = SpeechRecognizer.createSpeechRecognizer(context).apply {
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

    private fun tearDown() {
        debounceRunnable?.let { mainHandler.removeCallbacks(it) }
        debounceRunnable = null
        sessionFlushRunnable?.let { mainHandler.removeCallbacks(it) }
        sessionFlushRunnable = null
        speechRecognizer?.cancel()
        speechRecognizer?.destroy()
        speechRecognizer = null
        speechBuffer = ""
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
