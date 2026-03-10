enum VoiceCommandEventType {
  listeningStarted,
  listeningStopped,
  listeningPaused,
  listeningResumed,
  partialResult,
  result,
  error,
  sessionFlushed,
  wakeWordDetected,
  wakeWordListeningStarted,
  wakeWordListeningStopped,
}

class VoiceCommandEvent {
  final VoiceCommandEventType type;
  final String? text;
  final String? errorMessage;
  final String? errorCode;

  const VoiceCommandEvent({
    required this.type,
    this.text,
    this.errorMessage,
    this.errorCode,
  });

  factory VoiceCommandEvent.fromMap(Map<dynamic, dynamic> map) {
    return VoiceCommandEvent(
      type: VoiceCommandEventType.values.firstWhere(
        (e) => e.name == map['type'],
        orElse: () => VoiceCommandEventType.error,
      ),
      text: map['text'] as String?,
      errorMessage: map['errorMessage'] as String?,
      errorCode: map['errorCode'] as String?,
    );
  }

  @override
  String toString() {
    switch (type) {
      case VoiceCommandEventType.result:
        return '[RESULT] $text';
      case VoiceCommandEventType.partialResult:
        return '[PARTIAL] $text';
      case VoiceCommandEventType.error:
        return '[ERROR] $errorMessage ($errorCode)';
      case VoiceCommandEventType.sessionFlushed:
        return '[SESSION FLUSHED]';
      case VoiceCommandEventType.listeningStarted:
        return '[STARTED]';
      case VoiceCommandEventType.listeningStopped:
        return '[STOPPED]';
      case VoiceCommandEventType.listeningPaused:
        return '[PAUSED]';
      case VoiceCommandEventType.listeningResumed:
        return '[RESUMED]';
      case VoiceCommandEventType.wakeWordDetected:
        return '[WAKE WORD DETECTED]';
      case VoiceCommandEventType.wakeWordListeningStarted:
        return '[WAKE WORD STARTED]';
      case VoiceCommandEventType.wakeWordListeningStopped:
        return '[WAKE WORD STOPPED]';
    }
  }
}
