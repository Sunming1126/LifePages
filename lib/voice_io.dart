import 'dart:async';
import 'dart:io';
import 'package:record/record.dart';

/// Device and network boundaries. The chat uses the same state machine for
/// physical recording and headless interaction acceptance tests.
abstract class VoiceCapture {
  Future<bool> hasPermission();
  Future<Stream<List<int>>> startStream(RecordConfig config);
  Future<void> stop();
  Future<void> dispose();
}

class DeviceVoiceCapture implements VoiceCapture {
  final _recorder = AudioRecorder();
  @override
  Future<bool> hasPermission() => _recorder.hasPermission();
  @override
  Future<Stream<List<int>>> startStream(RecordConfig config) =>
      _recorder.startStream(config);
  @override
  Future<void> stop() async {
    await _recorder.stop();
  }

  @override
  Future<void> dispose() => _recorder.dispose();
}

abstract class VoiceWire {
  Stream<dynamic> get events;
  void add(dynamic data);
  Future<void> close();
}

class DirectVoiceWire implements VoiceWire {
  final WebSocket socket;
  DirectVoiceWire(this.socket);
  @override
  Stream<dynamic> get events => socket;
  @override
  void add(dynamic data) => socket.add(data);
  @override
  Future<void> close() async {
    await socket.close();
  }
}

typedef VoiceConnector =
    Future<VoiceWire> Function(String url, Map<String, String> headers);
Future<VoiceWire> connectDirectVoice(
  String url,
  Map<String, String> headers,
) async => DirectVoiceWire(
  await WebSocket.connect(
    url,
    headers: headers,
  ).timeout(const Duration(seconds: 10)),
);
