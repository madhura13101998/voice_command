import Flutter
import UIKit
import Speech
import AVFoundation

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
        eventSink = events
        return nil
    }
    
    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }
    
    // MARK: - Method Dispatch
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
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
            result(isCurrentlyListening && !isPaused)
            
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    // MARK: - Permissions
    
    private func requestPermissions(result: @escaping FlutterResult) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                guard status == .authorized else {
                    result(false)
                    return
                }
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    DispatchQueue.main.async { result(granted) }
                }
            }
        }
    }
    
    // MARK: - Start
    
    private func startListening(debounceDuration: Double,
                                sessionFlushInterval: Double,
                                locale: String?,
                                result: @escaping FlutterResult) {
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
        
        do {
            try configureAudioSession()
            try installAudioTap()
            audioEngine.prepare()
            try audioEngine.start()
            startRecognitionTask()
            startSessionFlushTimer()
            isCurrentlyListening = true
            isPaused = false
            sendEvent(type: "listeningStarted")
            result(nil)
        } catch {
            result(FlutterError(code: "AUDIO_ERROR",
                                message: error.localizedDescription,
                                details: nil))
        }
    }
    
    // MARK: - Stop
    
    private func stopListening(result: @escaping FlutterResult) {
        guard isCurrentlyListening else { result(nil); return }
        firePendingDebounce()
        tearDown()
        isCurrentlyListening = false
        isPaused = false
        isRestarting = false
        sendEvent(type: "listeningStopped")
        result(nil)
    }
    
    // MARK: - Pause / Resume
    
    private func pauseListening(result: @escaping FlutterResult) {
        guard isCurrentlyListening, !isPaused else { result(nil); return }
        isRestarting = true
        firePendingDebounce()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning { audioEngine.stop() }
        sessionFlushTimer?.invalidate()
        sessionFlushTimer = nil
        isPaused = true
        isRestarting = false
        sendEvent(type: "listeningPaused")
        result(nil)
    }
    
    private func resumeListening(result: @escaping FlutterResult) {
        guard isCurrentlyListening, isPaused else { result(nil); return }
        do {
            try configureAudioSession()
            try installAudioTap()
            audioEngine.prepare()
            try audioEngine.start()
            startRecognitionTask()
            startSessionFlushTimer()
            isPaused = false
            speechBuffer = ""
            sendEvent(type: "listeningResumed")
            result(nil)
        } catch {
            result(FlutterError(code: "AUDIO_ERROR",
                                message: error.localizedDescription,
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
    
    // MARK: - Audio Engine
    
    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }
    
    private func installAudioTap() throws {
        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }
    }
    
    // MARK: - Recognition Task
    
    private func startRecognitionTask() {
        recognitionTask?.cancel()
        recognitionTask = nil
        isRestarting = false
        
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
                        self.sendEvent(type: "partialResult", text: text)
                        self.resetDebounceTimer()
                    }
                }
                
                if error != nil {
                    if let error = error {
                        let nsError = error as NSError
                        let silenced: Set<Int> = [216, 209, 301, 1107, 1110]
                        if !silenced.contains(nsError.code) {
                            self.sendEvent(type: "error",
                                           errorMessage: error.localizedDescription,
                                           errorCode: "\(nsError.code)")
                        }
                    }
                    if self.isCurrentlyListening && !self.isPaused && !self.isRestarting {
                        self.scheduleRecognitionRestart()
                    }
                }
            }
        }
    }
    
    private func scheduleRecognitionRestart() {
        guard !isRestarting else { return }
        isRestarting = true
        recognitionRequest = nil
        recognitionTask = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            guard self.isCurrentlyListening, !self.isPaused else {
                self.isRestarting = false
                return
            }
            self.startRecognitionTask()
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
            self.sendEvent(type: "result", text: text)
            self.speechBuffer = ""
            self.isRestarting = true
            self.recognitionTask?.cancel()
            self.recognitionRequest = nil
            self.recognitionTask = nil
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
        guard debounceTimer != nil else { return }
        debounceTimer?.fire()
        debounceTimer?.invalidate()
        debounceTimer = nil
    }
    
    // MARK: - Session Flush
    
    private func startSessionFlushTimer() {
        sessionFlushTimer?.invalidate()
        sessionFlushTimer = Timer.scheduledTimer(
            withTimeInterval: sessionFlushInterval,
            repeats: true
        ) {
            [weak self] _ in
            guard let self = self,
                  isRestarting
            else {
                return
            }
            self.flushSession()
        }
    }
    
    private func flushSession() {
        firePendingDebounce()
        speechBuffer = ""
        
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
            self.startRecognitionTask()
            self.sendEvent(type: "sessionFlushed")
        }
    }
    
    // MARK: - Teardown
    
    private func tearDown() {
        debounceTimer?.invalidate()
        debounceTimer = nil
        sessionFlushTimer?.invalidate()
        sessionFlushTimer = nil
        
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning { audioEngine.stop() }
        
        speechBuffer = ""
        
        try? AVAudioSession.sharedInstance()
            .setActive(false, options: .notifyOthersOnDeactivation)
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
            self?.eventSink?(payload)
        }
    }
}
