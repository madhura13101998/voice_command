import Flutter
import UIKit
import Speech
import AVFoundation

private func vcpLog(_ message: String) {
    print("[VoiceCommandPlugin] \(message)")
}

public class VoiceCommandPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    
    private var methodChannel: FlutterMethodChannel?
    private var eventChannel: FlutterEventChannel?
    private var eventSink: FlutterEventSink?
    
    private var speechRecognizer: SFSpeechRecognizer?
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    
    private var debounceDuration: TimeInterval = 1.5
    private var sessionFlushInterval: TimeInterval = 5.0
    
    private var debounceTimer: Timer?
    private var sessionFlushTimer: Timer?
    private var speechBuffer: String = ""
    private var isCurrentlyListening: Bool = false
    private var isPaused: Bool = false
    private var isRestarting: Bool = false
    private var isReapplying: Bool = false
    
    // MARK: - Registration
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = VoiceCommandPlugin()
        
        let methodChannel = FlutterMethodChannel(
            name: "voice_command",
            binaryMessenger: registrar.messenger()
        )
        let eventChannel = FlutterEventChannel(
            name: "voice_command/events",
            binaryMessenger: registrar.messenger()
        )
        
        instance.methodChannel = methodChannel
        instance.eventChannel = eventChannel
        
        registrar.addMethodCallDelegate(instance, channel: methodChannel)
        eventChannel.setStreamHandler(instance)
    }
    
    // MARK: - FlutterStreamHandler
    
    public func onListen(withArguments arguments: Any?,
                         eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        vcpLog("onListen called, setting eventSink")
        eventSink = events
        return nil
    }
    
    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        vcpLog("onCancel called, removing eventSink")
        eventSink = nil
        return nil
    }
    
    // MARK: - Method Dispatch
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        vcpLog("handle method call: \(call.method)")
        switch call.method {
        case "requestPermissions":
            requestPermissions(result: result)
            
        case "startListening":
            let args = call.arguments as? [String: Any]
            let debounce = args?["debounceDuration"] as? Double ?? debounceDuration
            let flush    = args?["sessionFlushInterval"] as? Double ?? sessionFlushInterval
            let locale   = args?["locale"] as? String
            startListening(debounceDuration: debounce,
                           sessionFlushInterval: flush,
                           locale: locale,
                           result: result)
            
        case "stopListening":
            stopListening(result: result)
            
        case "pauseListening":
            pauseListening(result: result)
            
        case "resumeListening":
            resumeListening(result: result)
            
        case "clearBuffer":
            clearBuffer(result: result)
            
        case "isListening":
            let listeningState = isCurrentlyListening && !isPaused
            result(listeningState)
            
        case "reapplyAudioSession":
            reapplyAudioSession(result: result)
            
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    // MARK: - Permissions
    
    private func requestPermissions(result: @escaping FlutterResult) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                guard status == .authorized else {
                    vcpLog("Speech recognition permission denied")
                    result(false)
                    return
                }
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    DispatchQueue.main.async {
                        vcpLog("Microphone permission granted: \(granted)")
                        result(granted)
                    }
                }
            }
        }
    }
    
    // MARK: - Start
    
    private func startListening(debounceDuration: Double,
                                sessionFlushInterval: Double,
                                locale: String?,
                                result: @escaping FlutterResult) {
        vcpLog("startListening called")
        guard !isCurrentlyListening else {
            result(FlutterError(code: "ALREADY_LISTENING",
                                message: "Already listening", details: nil))
            return
        }
        
        self.debounceDuration = debounceDuration
        self.sessionFlushInterval = sessionFlushInterval
        
        speechRecognizer = locale != nil
        ? SFSpeechRecognizer(locale: Locale(identifier: locale!))
        : SFSpeechRecognizer()
        
        guard let sr = speechRecognizer, sr.isAvailable else {
            result(FlutterError(code: "UNAVAILABLE",
                                message: "Speech recognizer is not available",
                                details: nil))
            return
        }
        
        if startRecognitionPipeline() {
            registerInterruptionObserver()
            isCurrentlyListening = true
            isPaused = false
            sendEvent(type: "listeningStarted")
            result(nil)
        } else {
            result(FlutterError(code: "AUDIO_ERROR",
                                message: "Failed to start audio pipeline",
                                details: nil))
        }
    }
    
    // MARK: - Stop
    
    private func stopListening(result: @escaping FlutterResult) {
        guard isCurrentlyListening else {
            result(nil)
            return
        }
        tearDown()
        isCurrentlyListening = false
        isPaused = false
        isRestarting = false
        sendEvent(type: "listeningStopped")
        result(nil)
    }
    
    // MARK: - Pause / Resume
    
    private func pauseListening(result: @escaping FlutterResult) {
        guard isCurrentlyListening, !isPaused else {
            result(nil)
            return
        }
        isRestarting = true
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        sessionFlushTimer?.invalidate()
        sessionFlushTimer = nil
        isPaused = true
        isRestarting = false
        sendEvent(type: "listeningPaused")
        result(nil)
    }
    
    private func resumeListening(result: @escaping FlutterResult) {
        guard isCurrentlyListening, isPaused else {
            result(nil)
            return
        }
        if startRecognitionPipeline() {
            registerInterruptionObserver()
            isPaused = false
            speechBuffer = ""
            sendEvent(type: "listeningResumed")
            result(nil)
        } else {
            result(FlutterError(code: "AUDIO_ERROR",
                                message: "Failed to resume audio pipeline",
                                details: nil))
        }
    }
    
    // MARK: - Clear Buffer
    
    private func clearBuffer(result: @escaping FlutterResult) {
        speechBuffer = ""
        debounceTimer?.invalidate()
        debounceTimer = nil
        result(nil)
    }
    
    // MARK: - Reapply Audio Session
    
    private func reapplyAudioSession(result: @escaping FlutterResult) {
        vcpLog("reapplyAudioSession called")
        reapplyAudioSessionInternalWithRetry(attempt: 1, maxAttempts: 3) { success in
            result(success ? nil : FlutterError(
                code: "AUDIO_ERROR",
                message: "Failed to reapply audio session after retries",
                details: nil))
        }
    }
    
    private func reapplyAudioSessionInternalWithRetry(
        attempt: Int, maxAttempts: Int,
        completion: ((Bool) -> Void)? = nil
    ) {
        vcpLog("reapplyAudioSession attempt \(attempt)/\(maxAttempts)")
        guard !isReapplying else {
            vcpLog("reapply skipped: already in progress")
            completion?(true)
            return
        }
        guard isCurrentlyListening, !isPaused else {
            vcpLog("reapply skipped: not listening or paused")
            completion?(true)
            return
        }
        
        isReapplying = true
        
        let success = rebuildPipeline()
        
        isReapplying = false
        
        if success {
            vcpLog("reapplyAudioSession: pipeline restored on attempt \(attempt)")
            completion?(true)
        } else if attempt < maxAttempts {
            let delay = Double(attempt) * 2.0
            vcpLog("reapplyAudioSession: attempt \(attempt) failed, retrying in \(delay)s")
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.reapplyAudioSessionInternalWithRetry(
                    attempt: attempt + 1,
                    maxAttempts: maxAttempts,
                    completion: completion)
            }
        } else {
            vcpLog("reapplyAudioSession: all \(maxAttempts) attempts failed")
            completion?(false)
        }
    }
    
    /// Tear down the current recognition pipeline and rebuild it from scratch.
    /// Returns true on success.
    private func rebuildPipeline() -> Bool {
        isRestarting = true
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.reset()
        
        let ok = startRecognitionPipeline()
        if ok {
            speechBuffer = ""
        }
        return ok
    }
    
    // MARK: - Audio Session Interruption Observer
    
    private func registerInterruptionObserver() {
        removeInterruptionObserver()
        NotificationCenter.default.addObserver(self,
            selector: #selector(handleAudioSessionInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance())
        NotificationCenter.default.addObserver(self,
            selector: #selector(handleAudioRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance())
        vcpLog("Interruption and route-change observers registered")
    }
    
    private func removeInterruptionObserver() {
        NotificationCenter.default.removeObserver(self,
            name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.removeObserver(self,
            name: AVAudioSession.routeChangeNotification, object: nil)
    }
    
    @objc private func handleAudioSessionInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }
        
        if type == .ended {
            vcpLog("Audio session interruption ended, will reapply in 1.5s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.reapplyAudioSessionInternalWithRetry(attempt: 1, maxAttempts: 3)
            }
        } else {
            vcpLog("Audio session interruption began")
        }
    }
    
    @objc private func handleAudioRouteChange(_ notification: Notification) {
        guard !isReapplying else { return }
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }
        
        switch reason {
        case .override, .newDeviceAvailable, .oldDeviceUnavailable:
            vcpLog("Audio route changed (reason: \(reason.rawValue)), reapplying in 1.5s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.reapplyAudioSessionInternalWithRetry(attempt: 1, maxAttempts: 3)
            }
        default:
            vcpLog("Audio route changed (reason: \(reason.rawValue)), no action")
        }
    }
    
    // MARK: - Audio Pipeline
    
    /// Configures the audio session, installs the tap, starts the engine and
    /// recognition task. Returns true on success.
    private func startRecognitionPipeline() -> Bool {
        do {
            try configureAudioSession()
        } catch {
            vcpLog("configureAudioSession failed: \(error.localizedDescription)")
            return false
        }
        
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request
        
        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)
        
        var recordingFormat = inputNode.outputFormat(forBus: 0)
        if recordingFormat.sampleRate == 0 {
            vcpLog("Warning: outputFormat is 0Hz, falling back to inputFormat")
            recordingFormat = inputNode.inputFormat(forBus: 0)
        }
        
        guard recordingFormat.sampleRate > 0 && recordingFormat.channelCount > 0 else {
            vcpLog("⚠️ Invalid audio format: \(recordingFormat.sampleRate)Hz, \(recordingFormat.channelCount)ch")
            recognitionRequest = nil
            return false
        }
        
        vcpLog("Installing tap: \(recordingFormat.sampleRate)Hz, \(recordingFormat.channelCount)ch")
        
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) {
            [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }
        
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            vcpLog("audioEngine.start() failed: \(error.localizedDescription)")
            inputNode.removeTap(onBus: 0)
            recognitionRequest = nil
            return false
        }
        
        startRecognitionTask()
        isRestarting = false
        vcpLog("Recognition pipeline started successfully")
        return true
    }
    
    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord,
                                mode: .default,
                                options: [.allowBluetooth, .defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        vcpLog("Audio session configured and activated")
    }
    
    // MARK: - Recognition Task
    
    private func startRecognitionTask() {
        guard let request = recognitionRequest else {
            vcpLog("startRecognitionTask: no recognitionRequest, skipping")
            return
        }
        
        recognitionTask = speechRecognizer?.recognitionTask(with: request) { [weak self] taskResult, error in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                if let taskResult = taskResult {
                    let text = taskResult.bestTranscription.formattedString
                    if !text.isEmpty {
                        self.speechBuffer = text
                        self.sendEvent(type: "partialResult", text: text)
                        self.resetDebounceTimer()
                    }
                }
                
                if let error = error {
                    let nsError = error as NSError
                    let silenced: Set<Int> = [216, 209, 301, 1107, 1110]
                    if !silenced.contains(nsError.code) {
                        vcpLog("Recognition error: \(error.localizedDescription) (code: \(nsError.code))")
                        self.sendEvent(type: "error",
                                       errorMessage: error.localizedDescription,
                                       errorCode: "\(nsError.code)")
                    }
                    if self.isCurrentlyListening && !self.isPaused && !self.isRestarting {
                        self.scheduleRecognitionRestart()
                    }
                }
            }
        }
        
        if recognitionTask == nil {
            vcpLog("⚠️ recognitionTask is nil after creation, will retry in 1s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self = self, self.isCurrentlyListening, !self.isPaused else { return }
                self.rebuildPipeline()
            }
        }
    }
    
    private func scheduleRecognitionRestart() {
        guard !isRestarting else { return }
        isRestarting = true
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }
            guard self.isCurrentlyListening, !self.isPaused else {
                self.isRestarting = false
                return
            }
            _ = self.rebuildPipeline()
        }
    }
    
    // MARK: - Debounce
    
    private func resetDebounceTimer() {
        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(
            withTimeInterval: debounceDuration,
            repeats: false
        ) { [weak self] _ in
            guard let self = self else { return }
            let text = self.speechBuffer.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return }
            self.flushSession()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                [weak self] in
                guard let self = self else { return }
                self.sendEvent(type: "result", text: text)
                self.speechBuffer = ""
            }
        }
    }
    
    // MARK: - Session Flush
    
    private func flushSession() {
        vcpLog("flushSession called")
        isRestarting = true
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            guard self.isCurrentlyListening, !self.isPaused else {
                self.isRestarting = false
                return
            }
            _ = self.rebuildPipeline()
            self.sendEvent(type: "sessionFlushed")
        }
    }
    
    // MARK: - Teardown
    
    private func tearDown() {
        vcpLog("tearDown called")
        removeInterruptionObserver()
        debounceTimer?.invalidate()
        debounceTimer = nil
        sessionFlushTimer?.invalidate()
        sessionFlushTimer = nil
        
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.reset()
        
        speechBuffer = ""
        
        do {
            try AVAudioSession.sharedInstance()
                .setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            vcpLog("Error deactivating audio session: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Event Dispatch
    
    private func sendEvent(type: String,
                           text: String? = nil,
                           errorMessage: String? = nil,
                           errorCode: String? = nil) {
        DispatchQueue.main.async { [weak self] in
            var payload: [String: Any] = ["type": type]
            if let t = text         { payload["text"] = t }
            if let m = errorMessage { payload["errorMessage"] = m }
            if let c = errorCode    { payload["errorCode"] = c }
            vcpLog("Sending event: \(payload)")
            self?.eventSink?(payload)
        }
    }
}
