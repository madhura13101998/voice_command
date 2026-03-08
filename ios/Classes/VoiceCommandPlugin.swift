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
    
    // Configuration
    private var debounceDuration: TimeInterval = 1.5
    private var sessionFlushInterval: TimeInterval = 5.0
    
    // State
    private var debounceTimer: Timer?
    private var sessionFlushTimer: Timer?
    private var speechBuffer: String = ""
    private var isCurrentlyListening: Bool = false
    private var isPaused: Bool = false
    private var isRestarting: Bool = false
    
    private var hasSentResult: Bool = false
    
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
            vcpLog("Requesting permissions")
            requestPermissions(result: result)
            
        case "startListening":
            let args = call.arguments as? [String: Any]
            let debounce = args?["debounceDuration"] as? Double ?? debounceDuration
            let flush    = args?["sessionFlushInterval"] as? Double ?? sessionFlushInterval
            let locale   = args?["locale"] as? String
            vcpLog("Start listening with debounceDuration=\(debounce), sessionFlushInterval=\(flush), locale=\(locale ?? "default")")
            startListening(debounceDuration: debounce,
                           sessionFlushInterval: flush,
                           locale: locale,
                           result: result)
            
        case "stopListening":
            vcpLog("Stop listening requested")
            stopListening(result: result)
            
        case "pauseListening":
            vcpLog("Pause listening requested")
            pauseListening(result: result)
            
        case "resumeListening":
            vcpLog("Resume listening requested")
            resumeListening(result: result)
            
        case "clearBuffer":
            vcpLog("Clear buffer requested")
            clearBuffer(result: result)
            
        case "isListening":
            let listeningState = isCurrentlyListening && !isPaused
            vcpLog("isListening queried: \(listeningState)")
            result(listeningState)
            
        default:
            vcpLog("Unhandled method: \(call.method)")
            result(FlutterMethodNotImplemented)
        }
    }
    
    // MARK: - Permissions
    
    private func requestPermissions(result: @escaping FlutterResult) {
        vcpLog("requestPermissions called")
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                vcpLog("Speech recognizer authorization status: \(status.rawValue)")
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
            vcpLog("startListening aborted: Already listening")
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
            vcpLog("Speech recognizer is not available")
            result(FlutterError(code: "UNAVAILABLE",
                                message: "Speech recognizer is not available",
                                details: nil))
            return
        }
        
        do {
            try configureAudioSession()
            try installAudioTap()
            audioEngine.prepare()
            try audioEngine.start()
            startRecognitionTask()
//            startSessionFlushTimer()
            isCurrentlyListening = true
            isPaused = false
            vcpLog("Listening started")
            sendEvent(type: "listeningStarted")
            result(nil)
        } catch {
            vcpLog("Error starting listening: \(error.localizedDescription)")
            result(FlutterError(code: "AUDIO_ERROR",
                                message: error.localizedDescription,
                                details: nil))
        }
    }
    
    // MARK: - Stop
    
    private func stopListening(result: @escaping FlutterResult) {
        vcpLog("stopListening called")
        guard isCurrentlyListening else {
            vcpLog("stopListening: Not currently listening, no action taken")
            result(nil)
            return
        }
        firePendingDebounce()
        tearDown()
        isCurrentlyListening = false
        isPaused = false
        isRestarting = false
        vcpLog("Listening stopped")
        sendEvent(type: "listeningStopped")
        result(nil)
    }
    
    // MARK: - Pause / Resume
    
    private func pauseListening(result: @escaping FlutterResult) {
        vcpLog("pauseListening called")
        guard isCurrentlyListening, !isPaused else {
            vcpLog("pauseListening: Either not listening or already paused")
            result(nil)
            return
        }
        isRestarting = true
        firePendingDebounce()
        vcpLog("Cancelling recognition task for pause")
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning {
            vcpLog("Stopping audio engine for pause")
            audioEngine.stop()
        }
        sessionFlushTimer?.invalidate()
        sessionFlushTimer = nil
        isPaused = true
        isRestarting = false
        vcpLog("Listening paused")
        sendEvent(type: "listeningPaused")
        result(nil)
    }
    
    private func resumeListening(result: @escaping FlutterResult) {
        vcpLog("resumeListening called")
        guard isCurrentlyListening, isPaused else {
            vcpLog("resumeListening: Not currently paused or not listening")
            result(nil)
            return
        }
        do {
            try configureAudioSession()
            try installAudioTap()
            audioEngine.prepare()
            try audioEngine.start()
            startRecognitionTask()
//            startSessionFlushTimer()
            isPaused = false
            speechBuffer = ""
            vcpLog("Listening resumed")
            sendEvent(type: "listeningResumed")
            result(nil)
        } catch {
            vcpLog("Error resuming listening: \(error.localizedDescription)")
            result(FlutterError(code: "AUDIO_ERROR",
                                message: error.localizedDescription,
                                details: nil))
        }
    }
    
    // MARK: - Clear Buffer
    
    private func clearBuffer(result: @escaping FlutterResult) {
        vcpLog("clearBuffer called, clearing speechBuffer and debounceTimer")
        speechBuffer = ""
        debounceTimer?.invalidate()
        debounceTimer = nil
        vcpLog("Buffer cleared and debounce timer invalidated")
        result(nil)
    }
    
    // MARK: - Audio Engine
    
    private func configureAudioSession() throws {
        vcpLog("Configuring audio session")
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        vcpLog("Audio session configured and activated")
    }
    
    private func installAudioTap() throws {
        vcpLog("Installing audio tap on input node")
        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }
        vcpLog("Audio tap installed")
    }
    
    // MARK: - Recognition Task
    
    private func startRecognitionTask() {
        vcpLog("startRecognitionTask called")
        recognitionTask?.cancel()
        vcpLog("Cancelled existing recognition task (if any)")
        recognitionTask = nil
        isRestarting = false
        hasSentResult = false
        
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request
        
        recognitionTask = speechRecognizer?.recognitionTask(with: request) { [weak self] taskResult, error in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                if let taskResult = taskResult {
                    let text = taskResult.bestTranscription.formattedString
                    if !text.isEmpty {
                        self.speechBuffer = text
                        vcpLog("Partial result received: '\(text)'")
                        self.sendEvent(type: "partialResult", text: text)
                        self.resetDebounceTimer()
                    }
                }
                
                if error != nil {
                    if let error = error {
                        let nsError = error as NSError
                        let silenced: Set<Int> = [216, 209, 301, 1107, 1110]
                        if !silenced.contains(nsError.code) {
                            vcpLog("Recognition error occurred: \(error.localizedDescription) (code: \(nsError.code))")
                            self.sendEvent(type: "error",
                                           errorMessage: error.localizedDescription,
                                           errorCode: "\(nsError.code)")
                        } else {
                            vcpLog("Recognition error silenced with code: \(nsError.code)")
                        }
                    }
                    if self.isCurrentlyListening && !self.isPaused && !self.isRestarting {
                        vcpLog("Scheduling recognition restart due to error")
                        self.scheduleRecognitionRestart()
                    }
                }
            }
        }
        vcpLog("Recognition task started")
    }
    
    private func scheduleRecognitionRestart() {
        vcpLog("scheduleRecognitionRestart called")
        guard !isRestarting else {
            vcpLog("scheduleRecognitionRestart aborted: already restarting")
            return
        }
        isRestarting = true
        recognitionRequest = nil
        recognitionTask = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            guard self.isCurrentlyListening, !self.isPaused else {
                vcpLog("scheduleRecognitionRestart aborted: Not listening or paused")
                self.isRestarting = false
                return
            }
            vcpLog("Restarting recognition task")
            self.startRecognitionTask()
        }
    }
    
    // MARK: - Debounce
    
    private func resetDebounceTimer() {
        vcpLog("resetDebounceTimer called - invalidating previous timer if exists")
        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(
            withTimeInterval: debounceDuration,
            repeats: false
        ) { [weak self] _ in
            guard let self = self else { return }
            let text = self.speechBuffer.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return }
            self.sendEvent(type: "result", text: text)
            self.speechBuffer = ""
            speechBuffer = ""
            self.isRestarting = true
            self.recognitionTask?.cancel()
            self.recognitionRequest = nil
            self.recognitionTask?.cancel()
            self.recognitionTask=nil;
            self.flushSession()
            //            if self.isCurrentlyListening && !self.isPaused {
            //                self.isRestarting = true
            //                self.recognitionTask?.cancel()
            //                self.recognitionRequest = nil
            //                self.recognitionTask = nil
            //                self.scheduleRecognitionRestart()
            //            }
        }
    }
    
    private func firePendingDebounce() {
        guard debounceTimer != nil else {
            vcpLog("firePendingDebounce called but no debounce timer active")
            return
        }
        vcpLog("Firing pending debounce timer immediately")
        debounceTimer?.fire()
        debounceTimer?.invalidate()
        debounceTimer = nil
        vcpLog("Debounce timer fired and invalidated")
    }
    
    // MARK: - Session Flush
    
    private func startSessionFlushTimer() {
        vcpLog("startSessionFlushTimer called")
        sessionFlushTimer?.invalidate()
        sessionFlushTimer = Timer.scheduledTimer(
            withTimeInterval: sessionFlushInterval,
            repeats: true
        ) { [weak self] _ in
            guard let self = self,
                  self.isRestarting
            else {
                vcpLog("Session flush timer triggered but isRestarting is false, skipping flush")
                return
            }
            vcpLog("Session flush timer triggered, flushing session")
            self.flushSession()
        }
        vcpLog("Session flush timer started with interval: \(sessionFlushInterval)")
    }
    
    private func flushSession() {
        vcpLog("flushSession called")
//        firePendingDebounce()
      
        
        isRestarting = true
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            guard self.isCurrentlyListening, !self.isPaused else {
                vcpLog("flushSession aborted: Not listening or paused")
                self.isRestarting = false
                return
            }
            vcpLog("Restarting recognition task after session flush")
            self.startRecognitionTask()
            self.sendEvent(type: "sessionFlushed")
            vcpLog("Session flushed event sent")
        }
    }
    
    // MARK: - Teardown
    
    private func tearDown() {
        vcpLog("tearDown called, cleaning up resources")
        debounceTimer?.invalidate()
        debounceTimer = nil
        sessionFlushTimer?.invalidate()
        sessionFlushTimer = nil
        
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning {
            vcpLog("Stopping audio engine during teardown")
            audioEngine.stop()
        }
        
        speechBuffer = ""
        
        do {
            try AVAudioSession.sharedInstance()
                .setActive(false, options: .notifyOthersOnDeactivation)
            vcpLog("Audio session deactivated during teardown")
        } catch {
            vcpLog("Error deactivating audio session during teardown: \(error.localizedDescription)")
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

