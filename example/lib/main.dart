import 'dart:async';
import 'package:flutter/material.dart';
import 'package:voice_command/voice_command.dart';

void main() => runApp(const MyApp());

class MyApp extends StatefulWidget {
  const MyApp({super.key});
  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final _vc = VoiceCommand();
  bool _listening = false;
  bool _paused = false;
  bool _permitted = true;
  bool _wakeWordActive = false;
  int _wakeWordDetectedCount = 0;
  String _partial = '';
  String _lastResult = '';
  final List<String> _log = [];
  StreamSubscription<VoiceCommandEvent>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = _vc.onEvent.listen(_onEvent);
    _stopWakeWord();
  }

  void _onEvent(VoiceCommandEvent e) {
    setState(() {
      _log.insert(0, e.toString());
      if (_log.length > 100) _log.removeLast();

      switch (e.type) {
        case VoiceCommandEventType.partialResult:
          _partial = e.text ?? '';
        case VoiceCommandEventType.result:
          _lastResult = e.text ?? '';
          _partial = '';
        case VoiceCommandEventType.listeningStarted:
          _listening = true;
          _paused = false;
        case VoiceCommandEventType.listeningStopped:
          _listening = false;
          _paused = false;
        case VoiceCommandEventType.listeningPaused:
          _paused = true;
        case VoiceCommandEventType.listeningResumed:
          _paused = false;
        case VoiceCommandEventType.wakeWordDetected:
          _wakeWordDetectedCount++;
        case VoiceCommandEventType.wakeWordListeningStarted:
          _wakeWordActive = true;
        case VoiceCommandEventType.wakeWordListeningStopped:
          _wakeWordActive = false;
        default:
          break;
      }
    });
  }

  Future<void> _requestPermission() async {
    final ok = await _vc.requestPermissions();
    setState(() => _permitted = ok);
  }

  Future<void> _start() async {
    await _vc.startListening(
      debounceDuration: Duration(seconds: 5),
      sessionFlushInterval: Duration(seconds: 5),
    );
  }

  Future<void> _stop() async {
    await _vc.stopListening();
  }

  Future<void> _pause() async {
    await _vc.pauseListening();
  }

  Future<void> _resume() async {
    await _vc.resumeListening();
  }

  Future<void> _clear() async {
    await _vc.clearBuffer();
    setState(() {
      _partial = '';
      _lastResult = '';
    });
  }

  Future<void> _startWakeWord() async {
    await _vc.startWakeWordDetection(threshold: 0.5);
  }

  Future<void> _stopWakeWord() async {
    await _vc.stopWakeWordDetection();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _vc.stopListening();
    _vc.stopWakeWordDetection();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return MaterialApp(
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Voice Command Demo'),
          actions: [
            IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: _clear,
              tooltip: 'Clear buffer',
            ),
          ],
        ),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!_permitted)
                FilledButton.tonal(
                  onPressed: _requestPermission,
                  child: const Text('Grant Microphone & Speech Permission'),
                ),
              if (_permitted) ...[
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Wake word',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Icon(
                              Icons.record_voice_over,
                              size: 16,
                              color: _wakeWordActive
                                  ? Colors.green
                                  : Colors.grey,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              _wakeWordActive
                                  ? 'Listening for wake word…'
                                  : 'Stopped',
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                            if (_wakeWordDetectedCount > 0) ...[
                              const SizedBox(width: 12),
                              Text(
                                'Detected: $_wakeWordDetectedCount',
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(color: cs.primary),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            if (!_wakeWordActive)
                              FilledButton.tonalIcon(
                                onPressed: _startWakeWord,
                                icon: const Icon(Icons.hearing),
                                label: const Text('Start wake word'),
                              ),
                            if (_wakeWordActive)
                              FilledButton.icon(
                                onPressed: _stopWakeWord,
                                icon: const Icon(Icons.hearing_disabled),
                                label: const Text('Stop wake word'),
                                style: FilledButton.styleFrom(
                                  backgroundColor: cs.error,
                                  foregroundColor: cs.onError,
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.circle,
                              size: 12,
                              color: !_listening
                                  ? Colors.grey
                                  : _paused
                                  ? Colors.orange
                                  : Colors.green,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              !_listening
                                  ? 'Stopped'
                                  : _paused
                                  ? 'Paused'
                                  : 'Listening...',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Partial',
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                        Text(_partial.isEmpty ? '—' : _partial),
                        const SizedBox(height: 12),
                        Text(
                          'Last Result',
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                        Text(
                          _lastResult.isEmpty ? '—' : _lastResult,
                          style: Theme.of(
                            context,
                          ).textTheme.titleLarge?.copyWith(color: cs.primary),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (!_listening)
                      FilledButton.icon(
                        onPressed: _start,
                        icon: const Icon(Icons.mic),
                        label: const Text('Start'),
                      ),
                    if (_listening && !_paused)
                      FilledButton.tonalIcon(
                        onPressed: _pause,
                        icon: const Icon(Icons.pause),
                        label: const Text('Pause'),
                      ),
                    if (_listening && _paused)
                      FilledButton.tonalIcon(
                        onPressed: _resume,
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('Resume'),
                      ),
                    if (_listening)
                      FilledButton.icon(
                        onPressed: _stop,
                        icon: const Icon(Icons.stop),
                        label: const Text('Stop'),
                        style: FilledButton.styleFrom(
                          backgroundColor: cs.error,
                          foregroundColor: cs.onError,
                        ),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              Text('Event Log', style: Theme.of(context).textTheme.titleSmall),
              const Divider(),
              Expanded(
                child: ListView.builder(
                  itemCount: _log.length,
                  itemBuilder: (_, i) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 1),
                    child: Text(
                      _log[i],
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
