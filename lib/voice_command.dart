export 'voice_command_event.dart';

import 'voice_command_event.dart';
import 'voice_command_platform_interface.dart';

class VoiceCommand {
  VoiceCommandPlatform get _platform => VoiceCommandPlatform.instance;

  /// Request microphone and speech recognition permissions.
  Future<bool> requestPermissions() {
    return _platform.requestPermissions();
  }

  /// Begin continuous listening.
  ///
  /// [debounceDuration] – silence gap before a final [result] is emitted.
  /// [sessionFlushInterval] – how often the native recognizer resets to stay
  ///   accurate and free memory.
  /// [locale] – BCP-47 locale (e.g. "en-US"). Uses device default if null.
  Future<void> startListening({
    Duration debounceDuration = const Duration(milliseconds: 1500),
    Duration sessionFlushInterval = const Duration(seconds: 59),
    String? locale,
  }) {
    return _platform.startListening(
      debounceDuration: debounceDuration.inMilliseconds / 1000.0,
      sessionFlushInterval: sessionFlushInterval.inMilliseconds / 1000.0,
      locale: locale,
    );
  }

  /// Stop listening and release all native resources.
  Future<void> stopListening() {
    return _platform.stopListening();
  }

  /// Pause recognition. Audio engine stays warm for fast resume.
  Future<void> pauseListening() {
    return _platform.pauseListening();
  }

  /// Resume a paused session.
  Future<void> resumeListening() {
    return _platform.resumeListening();
  }

  /// Clear accumulated speech buffer and cancel pending debounce.
  Future<void> clearBuffer() {
    return _platform.clearBuffer();
  }

  /// Whether the plugin is currently in a listening session (not paused).
  Future<bool> get isListening {
    return _platform.isListening();
  }

  /// Raw event stream.
  Stream<VoiceCommandEvent> get onEvent => _platform.eventStream;

  /// Debounced final speech text.
  Stream<String> get onResult => onEvent
      .where((e) => e.type == VoiceCommandEventType.result)
      .map((e) => e.text ?? '');

  /// Intermediate recognition text (real-time).
  Stream<String> get onPartialResult => onEvent
      .where((e) => e.type == VoiceCommandEventType.partialResult)
      .map((e) => e.text ?? '');

  /// Error messages.
  Stream<String> get onError => onEvent
      .where((e) => e.type == VoiceCommandEventType.error)
      .map((e) => e.errorMessage ?? 'Unknown error');
}
