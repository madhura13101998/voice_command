import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voice_command/voice_command_method_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final platform = MethodChannelVoiceCommand();
  const channel = MethodChannel('voice_command');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      switch (methodCall.method) {
        case 'requestPermissions':
          return true;
        case 'isListening':
          return false;
        case 'startListening':
        case 'stopListening':
        case 'pauseListening':
        case 'resumeListening':
        case 'clearBuffer':
          return null;
        default:
          return null;
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('requestPermissions', () async {
    expect(await platform.requestPermissions(), true);
  });

  test('isListening', () async {
    expect(await platform.isListening(), false);
  });

  test('startListening completes', () async {
    await platform.startListening();
  });

  test('stopListening completes', () async {
    await platform.stopListening();
  });

  test('pauseListening completes', () async {
    await platform.pauseListening();
  });

  test('resumeListening completes', () async {
    await platform.resumeListening();
  });

  test('clearBuffer completes', () async {
    await platform.clearBuffer();
  });
}
