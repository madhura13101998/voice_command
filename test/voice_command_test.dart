import 'package:flutter_test/flutter_test.dart';
import 'package:voice_command/voice_command.dart';
import 'package:voice_command/voice_command_platform_interface.dart';
import 'package:voice_command/voice_command_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockVoiceCommandPlatform
    with MockPlatformInterfaceMixin
    implements VoiceCommandPlatform {
  @override
  Future<bool> requestPermissions() => Future.value(true);

  @override
  Future<void> startListening({
    double debounceDuration = 1.5,
    double sessionFlushInterval = 15.0,
    String? locale,
  }) =>
      Future.value();

  @override
  Future<void> stopListening() => Future.value();

  @override
  Future<void> pauseListening() => Future.value();

  @override
  Future<void> resumeListening() => Future.value();

  @override
  Future<void> clearBuffer() => Future.value();

  @override
  Future<bool> isListening() => Future.value(false);

  @override
  Stream<VoiceCommandEvent> get eventStream => const Stream.empty();
}

void main() {
  final VoiceCommandPlatform initialPlatform = VoiceCommandPlatform.instance;

  test('$MethodChannelVoiceCommand is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelVoiceCommand>());
  });

  test('requestPermissions returns true from mock', () async {
    final plugin = VoiceCommand();
    VoiceCommandPlatform.instance = MockVoiceCommandPlatform();
    expect(await plugin.requestPermissions(), true);
  });

  test('isListening returns false from mock', () async {
    final plugin = VoiceCommand();
    VoiceCommandPlatform.instance = MockVoiceCommandPlatform();
    expect(await plugin.isListening, false);
  });
}
