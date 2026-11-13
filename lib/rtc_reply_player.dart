import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:volc_engine_rtc/volc_engine_rtc.dart';

import 'wav.dart';

typedef RtcRequest =
    Future<dynamic> Function(
      String method,
      String path, [
      Map<String, dynamic>? body,
    ]);

typedef RtcReplayMessage = ({String id, String text});
typedef _ReplayKey = ({RtcReplayMessage message, String voiceId});

class RtcReplyFailure implements Exception {
  const RtcReplyFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Plays saved and streaming replies. The receive-only SDK engine is process-wide.
class RtcReplyPlayer {
  static Future<void> _queue = Future<void>.value();
  static Future<void>? _closingSession;
  static Future<void>? _nativeRelease;
  final _cache = <_ReplayKey, File>{};
  _Playback? _current;

  Future<void> stop() {
    final current = _current;
    current?.cancel();
    return current?.localStop ?? _nativeRelease ?? Future<void>.value();
  }

  void clearCache() {
    for (final file in _cache.values) {
      unawaited(_deleteCapture(file.parent));
    }
    _cache.clear();
  }

  Future<void> play(
    RtcReplayMessage message,
    RtcRequest request, {
    required String voiceId,
  }) async {
    final key = (message: message, voiceId: voiceId);
    final cached = _cache.remove(key);
    if (cached != null) {
      _cache[key] = cached;
      _current?.cancel();
      final playback = _current = _Playback();
      try {
        await _playCached(playback, cached);
        return;
      } catch (_) {
        if (playback.cancelled) return;
        if (identical(_cache[key], cached)) {
          _cache.remove(key);
          unawaited(_deleteCapture(cached.parent));
        }
      } finally {
        if (identical(_current, playback)) _current = null;
      }
    }
    return _enqueue(
      '/api/rtc/sessions',
      {'message_id': message.id, 'voice_id': voiceId},
      request,
      voiceId: voiceId,
      replayMessage: Future.value(message),
    );
  }

  Future<void> playTurn(
    String bookId,
    String requestId,
    Stream<int> segments,
    RtcRequest request, {
    required String voiceId,
    required Future<RtcReplayMessage?> replayMessage,
  }) {
    return _enqueue(
      '/api/rtc/turns',
      {'book_id': bookId, 'request_id': requestId, 'voice_id': voiceId},
      request,
      voiceId: voiceId,
      replayMessage: replayMessage,
      segments: segments,
    );
  }

  Future<void> _playCached(_Playback playback, File file) async {
    await _nativeRelease;
    if (playback.cancelled) return;
    final player = playback.localPlayer = AudioPlayer();
    final completed = Completer<void>();
    final subscription = player.onPlayerComplete.listen((_) {
      if (!completed.isCompleted) completed.complete();
    });
    try {
      await player.play(DeviceFileSource(file.path, mimeType: 'audio/wav'));
      await Future.any<void>([completed.future, playback.cancelSignal.future]);
    } finally {
      await playback.localStop;
      playback.localPlayer = null;
      await subscription.cancel();
      await player.dispose();
    }
  }

  Future<void> _enqueue(
    String path,
    Map<String, dynamic> body,
    RtcRequest request, {
    required String voiceId,
    required Future<RtcReplayMessage?> replayMessage,
    Stream<int>? segments,
  }) {
    _current?.cancel();
    final playback = _current = _Playback();
    final previous = _queue;
    final task = previous.then(
      (_) => _play(
        playback,
        path,
        body,
        request,
        segments,
        voiceId,
        replayMessage,
      ),
    );
    _queue = task.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return task.whenComplete(() {
      if (identical(_current, playback)) _current = null;
    });
  }

  Future<void> _play(
    _Playback playback,
    String path,
    Map<String, dynamic> body,
    RtcRequest request,
    Stream<int>? segments,
    String voiceId,
    Future<RtcReplayMessage?> replayMessage,
  ) async {
    RTCEngine? engine;
    RTCRoom? room;
    String? sessionPath;
    final left = Completer<void>();
    final capture = _ReplyCapture();
    var completed = false;
    var joinRequested = false;
    try {
      await _closingSession;
      if (playback.cancelled) return;
      // Native plugins are loaded by the installed build, independently of hot reload.
      await RTCEngine.getSDKVersion();
      if (playback.cancelled) return;
      final session =
          await request('POST', path, body).timeout(const Duration(seconds: 8))
              as Map<String, dynamic>;
      sessionPath = '/api/rtc/sessions/${session['sessionId']}';
      if (playback.cancelled) return;
      _nativeRelease = playback.released.future;
      engine = await RTCEngine.createRTCEngine(
        RTCVideoContext(
          appId: session['appId'] as String,
          eventHandler: IRTCEngineEventHandler(
            onAudioRecordingStateUpdate: capture.onStateChanged,
          ),
        ),
      );
      if (playback.cancelled) return;
      playback.engine = engine;
      await engine.setPlaybackVolume(100);
      await engine.setDefaultAudioRoute(AudioRoute.speakerphone);
      room = await engine.createRTCRoom(session['roomId'] as String);
      if (room == null) throw StateError('无法连接播报房间');
      if (playback.cancelled) return;
      await room.setRTCRoomEventHandler(
        IRTCRoomEventHandler(
          onRoomStateChanged: (_, _, state, _) {
            if (!playback.joined.isCompleted) {
              playback.joined.complete(state == 0);
            } else if (state < 0) {
              playback.fail();
            }
          },
          onLeaveRoom: (_) {
            if (!left.isCompleted) left.complete();
          },
          onUserLeave: (uid, _) {
            if (uid == session['botUserId']) playback.fail();
          },
          onRoomBinaryMessageReceived: (_, _, message) {
            switch (_stage(message, session['taskId'] as String)) {
              case 5:
                playback.finishSegment(true);
              case 0:
              case 4:
                playback.finishSegment(false);
            }
          },
        ),
      );
      if (playback.cancelled) return;
      joinRequested = true;
      final status = await room.joinRoom(
        token: session['token'] as String,
        userInfo: UserInfo(userId: session['userId'] as String, extraInfo: ''),
        userVisibility: true,
        roomConfig: RoomConfig(
          isPublishAudio: false,
          isPublishVideo: false,
          isAutoSubscribeAudio: true,
          isAutoSubscribeVideo: false,
        ),
      );
      // The native join has been issued. Prepare the bot while the SDK waits
      // for the room callback, but never send speech before both are ready.
      final startingAgent =
          segments != null && status == 0 && !playback.cancelled
          ? request('POST', '$sessionPath/start')
                .timeout(const Duration(seconds: 12))
                .then<bool>((_) => true, onError: (Object _) => false)
          : null;
      if (status != 0 ||
          !await playback.joined.future.timeout(const Duration(seconds: 8))) {
        if (playback.cancelled) return;
        throw StateError('无法连接播报房间');
      }

      if (startingAgent != null) {
        final ready = await Future.any<bool>([
          startingAgent,
          playback.cancelSignal.future.then((_) => false),
        ]);
        if (playback.cancelled) return;
        if (!ready) throw StateError('语音播报任务未就绪');
      }
      final queue = StreamIterator(
        segments ??
            Stream<int>.fromIterable(
              Iterable<int>.generate(session['segments'] as int),
            ),
      );
      try {
        while (!playback.cancelled &&
            await Future.any<bool>([
              queue.moveNext(),
              playback.cancelSignal.future.then((_) => false),
            ])) {
          if (playback.cancelled) return;
          if (playback.failed) throw StateError('语音播报连接已断开');
          if (!capture.attempted) await capture.start(engine);
          if (playback.cancelled) return;
          final segment = playback.segment = Completer<bool>();
          final accepted = await Future.any<bool>([
            request('POST', '$sessionPath/speak', {
              'segment': queue.current,
            }).timeout(const Duration(seconds: 20)).then((_) => true),
            playback.cancelSignal.future.then((_) => false),
          ]);
          if (!accepted || playback.cancelled) return;
          if (!await segment.future.timeout(const Duration(seconds: 80))) {
            if (playback.cancelled) return;
            throw StateError('语音播报未完成');
          }
        }
      } finally {
        await queue.cancel();
      }
      // Let the last audio frames in the jitter buffer drain before leaving.
      await Future.any<void>([
        Future<void>.delayed(const Duration(milliseconds: 350)),
        playback.cancelSignal.future,
      ]);
      completed = !playback.cancelled && !playback.failed;
    } on MissingPluginException {
      if (!playback.cancelled) {
        throw const RtcReplyFailure('当前 App 缺少语音组件，请重新编译安装后再试');
      }
    } catch (_) {
      if (!playback.cancelled) rethrow;
    } finally {
      try {
        if (engine != null) await capture.stop(engine, keep: completed);
        if (room != null && joinRequested) {
          await room.leaveRoom();
          await left.future.timeout(
            const Duration(seconds: 1),
            onTimeout: () {},
          );
        }
      } catch (_) {
        // Destroy the room and engine even if the network has gone away.
      } finally {
        try {
          room?.destroy();
        } finally {
          try {
            playback.engine = null;
            engine?.destroy();
          } finally {
            if (identical(_nativeRelease, playback.released.future)) {
              _nativeRelease = null;
            }
            playback.released.complete();
          }
        }
      }
      if (sessionPath != null) {
        // A new RTC reservation still waits for cloud cleanup. Local replay does not.
        _closingSession = _closeSession(request, sessionPath);
      }
      final file = await capture.takeFile();
      if (file != null) {
        final message = await replayMessage;
        if (message != null && !playback.cancelled) {
          final key = (message: message, voiceId: voiceId);
          final replaced = _cache.remove(key);
          if (replaced != null) unawaited(_deleteCapture(replaced.parent));
          _cache[key] = file;
          if (_cache.length > 8) {
            final evicted = _cache.remove(_cache.keys.first)!;
            unawaited(_deleteCapture(evicted.parent));
          }
        } else {
          unawaited(_deleteCapture(file.parent));
        }
      }
    }
  }

  Future<void> _closeSession(RtcRequest request, String path) async {
    try {
      await request('DELETE', path).timeout(const Duration(seconds: 10));
    } catch (_) {
      // The server also expires rooms and retries agent cleanup.
    }
  }
}

class _Playback {
  final joined = Completer<bool>();
  final cancelSignal = Completer<void>();
  final released = Completer<void>();
  Completer<bool>? segment;
  RTCEngine? engine;
  AudioPlayer? localPlayer;
  Future<void>? localStop;
  bool failed = false;
  bool get cancelled => cancelSignal.isCompleted;

  void finishSegment(bool ok) {
    final active = segment;
    if (active != null && !active.isCompleted) active.complete(ok);
  }

  void fail() {
    failed = true;
    if (!joined.isCompleted) joined.complete(false);
    finishSegment(false);
  }

  void cancel() {
    if (!cancelled) {
      final activeEngine = engine;
      if (activeEngine != null) unawaited(_mute(activeEngine));
      final player = localPlayer;
      if (player != null) {
        localStop = player.stop().catchError((Object _) {});
      }
      cancelSignal.complete();
    }
    fail();
  }

  Future<void> _mute(RTCEngine activeEngine) async {
    try {
      await activeEngine.setPlaybackVolume(0);
    } catch (_) {
      // Room teardown will also stop audio.
    }
  }
}

class _ReplyCapture {
  final _saved = Completer<bool>();
  Directory? _directory;
  File? _file;
  bool attempted = false;
  bool _started = false;
  bool _keep = false;

  void onStateChanged(AudioRecordingState state, AudioRecordingErrorCode code) {
    if (_saved.isCompleted) return;
    if (code != AudioRecordingErrorCode.ok ||
        state == AudioRecordingState.error) {
      _saved.complete(false);
    } else if (state == AudioRecordingState.success) {
      _saved.complete(true);
    }
  }

  Future<void> start(RTCEngine engine) async {
    attempted = true;
    try {
      final directory = _directory = await Directory.systemTemp.createTemp(
        'lifepages-rtc-',
      );
      final file = _file = File('${directory.path}/reply.wav');
      _started =
          await engine.startAudioRecording(
            AudioRecordingConfig(
              absoluteFileName: file.path,
              sampleRate: AudioSampleRate.rate24000,
              channel: AudioChannel.mono,
              frameSource: AudioFrameSource.playback,
              quality: AudioQuality.high,
            ),
          ) ==
          0;
    } catch (_) {
      // Live playback can continue without a cache.
    }
  }

  Future<void> stop(RTCEngine engine, {required bool keep}) async {
    if (!_started) return;
    try {
      final stopped = await engine.stopAudioRecording();
      _keep =
          keep &&
          stopped == 0 &&
          await _saved.future.timeout(
            const Duration(milliseconds: 700),
            onTimeout: () => false,
          );
    } catch (_) {
      // An unconfirmed recording is discarded.
    }
  }

  Future<File?> takeFile() async {
    final directory = _directory;
    final file = _file;
    if (directory == null || file == null) return null;
    try {
      if (_keep && await file.length() <= 6 * 1024 * 1024) {
        final wav = await file.readAsBytes();
        final trimmed = trimWavLeadIn(wav);
        if (trimmed != null) {
          if (!identical(trimmed, wav)) await file.writeAsBytes(trimmed);
          return file;
        }
      }
    } catch (_) {
      // Treat an unreadable recording as a cache miss.
    }
    await _deleteCapture(directory);
    return null;
  }
}

Future<void> _deleteCapture(Directory directory) async {
  try {
    await directory.delete(recursive: true);
  } on FileSystemException {
    // The system can already have reclaimed its temporary files.
  }
}

int? _stage(Uint8List bytes, String taskId) {
  if (bytes.length < 8 ||
      ascii.decode(bytes.sublist(0, 4), allowInvalid: true) != 'conv') {
    return null;
  }
  final length = ByteData.sublistView(bytes).getUint32(4);
  if (length != bytes.length - 8) return null;
  try {
    final data = jsonDecode(utf8.decode(bytes.sublist(8)));
    if (data is! Map || data['TaskId'] != taskId) return null;
    final stage = data['Stage'];
    return stage is Map ? stage['Code'] as int? : null;
  } catch (_) {
    return null;
  }
}
