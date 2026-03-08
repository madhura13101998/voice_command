import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:voice_command/voice_command.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('VoiceCommand instance can be created', (WidgetTester tester) async {
    final plugin = VoiceCommand();
    final listening = await plugin.isListening;
    expect(listening, false);
  });
}
