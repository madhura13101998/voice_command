import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'voice_command_event.dart';
import 'voice_command_method_channel.dart';

abstract class VoiceCommandPlatform extends PlatformInterface {
  VoiceCommandPlatform() : super(token: _token);

  static final Object _token = Object();

  static VoiceCommandPlatform _instance = MethodChannelVoiceCommand();

  static VoiceCommandPlatform get instance => _instance;

  static set instance(VoiceCommandPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<bool> requestPermissions() {
    throw UnimplementedError('requestPermissions() has not been implemented.');
  }

  Future<void> startListening({
    double debounceDuration = 1.5,
    double sessionFlushInterval = 59.0,
    String? locale,
  }) {
    throw UnimplementedError('startListening() has not been implemented.');
  }

  Future<void> stopListening() {
    throw UnimplementedError('stopListening() has not been implemented.');
  }

  Future<void> pauseListening() {
    throw UnimplementedError('pauseListening() has not been implemented.');
  }

  Future<void> resumeListening() {
    throw UnimplementedError('resumeListening() has not been implemented.');
  }

  Future<void> clearBuffer() {
    throw UnimplementedError('clearBuffer() has not been implemented.');
  }

  Future<bool> isListening() {
    throw UnimplementedError('isListening() has not been implemented.');
  }

  Future<void> reapplyAudioSession() {
    throw UnimplementedError('reapplyAudioSession() has not been implemented.');
  }

  Stream<VoiceCommandEvent> get eventStream {
    throw UnimplementedError('eventStream has not been implemented.');
  }
}
