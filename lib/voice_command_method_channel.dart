import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'voice_command_event.dart';
import 'voice_command_platform_interface.dart';

class MethodChannelVoiceCommand extends VoiceCommandPlatform {
  @visibleForTesting
  final methodChannel = const MethodChannel('voice_command');

  @visibleForTesting
  final eventChannel = const EventChannel('voice_command/events');

  Stream<VoiceCommandEvent>? _eventStream;

  @override
  Stream<VoiceCommandEvent> get eventStream {
    _eventStream ??= eventChannel
        .receiveBroadcastStream()
        .map((event) => VoiceCommandEvent.fromMap(
              Map<dynamic, dynamic>.from(event as Map),
            ));
    return _eventStream!;
  }

  @override
  Future<bool> requestPermissions() async {
    final result = await methodChannel.invokeMethod<bool>('requestPermissions');
    return result ?? false;
  }

  @override
  Future<void> startListening({
    double debounceDuration = 1.5,
    double sessionFlushInterval = 59.0,
    String? locale,
  }) async {
    await methodChannel.invokeMethod('startListening', {
      'debounceDuration': debounceDuration,
      'sessionFlushInterval': sessionFlushInterval,
      'locale': locale,
    });
  }

  @override
  Future<void> stopListening() async {
    await methodChannel.invokeMethod('stopListening');
  }

  @override
  Future<void> pauseListening() async {
    await methodChannel.invokeMethod('pauseListening');
  }

  @override
  Future<void> resumeListening() async {
    await methodChannel.invokeMethod('resumeListening');
  }

  @override
  Future<void> clearBuffer() async {
    await methodChannel.invokeMethod('clearBuffer');
  }

  @override
  Future<bool> isListening() async {
    final result = await methodChannel.invokeMethod<bool>('isListening');
    return result ?? false;
  }

  @override
  Future<void> reapplyAudioSession() async {
    await methodChannel.invokeMethod('reapplyAudioSession');
  }

  @override
  Future<void> startWakeWordDetection({
    String? modelPath,
    double threshold = 0.5,
    int inputSize = 1280,
  }) async {
    await methodChannel.invokeMethod('startWakeWordDetection', {
      'modelPath': modelPath,
      'threshold': threshold,
      'inputSize': inputSize,
    });
  }

  @override
  Future<void> stopWakeWordDetection() async {
    await methodChannel.invokeMethod('stopWakeWordDetection');
  }

  @override
  Future<bool> isWakeWordActive() async {
    final result = await methodChannel.invokeMethod<bool>('isWakeWordActive');
    return result ?? false;
  }
}
