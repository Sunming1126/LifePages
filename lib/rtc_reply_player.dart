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
typedef _WarmSpec = ({String bookId, String voiceId, RtcRequest request});

class RtcReplyFailure implements Exception {
  const RtcReplyFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Plays saved and streaming replies. The receive-only SDK engine is process-wide.
class RtcReplyPlayer {
  static Future<void> _queue = Future<void>.value();
  static Future<void>? _nativeRelease;
  static Future<void>? _closingSession;
  static _RtcConnection? _warm;
  final _cache = <_ReplayKey, File>{};
  _Playback? _current;
  _WarmSpec? _warmSpec;
  Timer? _warmTimer;
  bool _warmSupported = false;

  Future<void> preconnect(
    String bookId,
    RtcRequest request, {
    required String voiceId,
  }) {
    final spec = _warmSpec = (
      bookId: bookId,
      request: request,
      voiceId: voiceId,
    );
    _warmTimer?.cancel();
    return _serialize(() => _prepareWarm(spec));
  }

  void releaseWarm({Duration grace = Duration.zero}) {
    _warmSpec = null;
    _warmTimer?.cancel();
    void release() {
      unawaited(
        _serialize(() async {
          if (_warmSpec == null && identical(_warm?.owner, this)) {
            await _dropWarm();
          }
        }),
      );
    }

    if (grace == Duration.zero) {
      release();
    } else {
      _warmTimer = Timer(grace, release);
    }
  }

  static Future<void> _serialize(Future<void> Function() action) {
    final task = _queue.then((_) => action());
    _queue = task.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return task;
  }

  Future<void> _prepareWarm(_WarmSpec spec) async {
    if (_warmSpec != spec) return;
    try {
      if (!_warmMatches(spec)) {
        await _dropWarm();
        if (_warmSpec != spec) return;
        _warm = await _connect(
          '/api/rtc/warm',
          {'book_id': spec.bookId, 'voice_id': spec.voiceId},
          spec.request,
          prepareAgent: true,
          warmSpec: spec,
        );
        _warmSupported = true;
      }
      if (_warmSpec != spec) return;
      // Refresh the room before its receive token expires. Serialized with playback.
      _warmTimer?.cancel();
      _warmTimer = Timer(
        _warm!.refreshIn,
        () => unawaited(_serialize(() => _prepareWarm(spec))),
      );
    } catch (_) {
      // The deployed server may not support warm rooms. Normal playback still works.
    }
  }

  bool _warmMatches(_WarmSpec spec) =>
      identical(_warm?.owner, this) && _warm?.spec == spec && _warm!.usable;

  static Future<void> _dropWarm() async {
    final connection = _warm;
    _warm = null;
    await connection?.close();
  }

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
    final task = _serialize(
      () => _play(
        playback,
        path,
        body,
        request,
        segments,
        voiceId,
        replayMessage,
      ),
    );
    return task.whenComplete(() {
      if (identical(_current, playback)) _current = null;
    });
  }

  Future<_RtcConnection> _connect(
    String path,
    Map<String, dynamic> body,
    RtcRequest request, {
    required bool prepareAgent,
    _WarmSpec? warmSpec,
    _Playback? playback,
  }) async {
    await _closingSession;
    if (playback?.cancelled == true) throw StateError('语音播报已取消');
    await RTCEngine.getSDKVersion();
    final session =
        await request('POST', path, body).timeout(const Duration(seconds: 8))
            as Map<String, dynamic>;
    final connection = _RtcConnection(this, session, request, warmSpec);
    connection.playback = playback;
    try {
      if (warmSpec != null && _warmSpec != warmSpec) {
        throw StateError('语音预连接已取消');
      }
      final engine = connection.engine = await RTCEngine.createRTCEngine(
        RTCVideoContext(
          appId: session['appId'] as String,
          eventHandler: IRTCEngineEventHandler(
            onAudioRecordingStateUpdate: (state, code) =>
                connection.capture?.onStateChanged(state, code),
          ),
        ),
      );
      if (playback != null) playback.engine = engine;
      await engine.setPlaybackVolume(warmSpec == null ? 100 : 0);
      await engine.setDefaultAudioRoute(AudioRoute.speakerphone);
      final room = connection.room = await engine.createRTCRoom(
        session['roomId'] as String,
      );
      if (room == null) throw StateError('无法连接播报房间');
      await room.setRTCRoomEventHandler(
        IRTCRoomEventHandler(
          onRoomStateChanged: (_, _, state, _) {
            if (!connection.joined.isCompleted) {
              connection.joined.complete(state == 0);
            } else if (state < 0) {
              connection.fail();
            }
          },
          onLeaveRoom: (_) {
            if (!connection.left.isCompleted) connection.left.complete();
          },
          onUserLeave: (uid, _) {
            if (uid == session['botUserId']) connection.fail();
          },
          onRoomBinaryMessageReceived: (_, _, message) {
            switch (_stage(message, session['taskId'] as String)) {
              case 5:
                connection.playback?.finishSegment(true);
              case 0:
              case 4:
                connection.playback?.finishSegment(false);
            }
          },
        ),
      );
      if (playback?.cancelled == true) return connection;
      if (warmSpec != null && _warmSpec != warmSpec) {
        throw StateError('语音预连接已取消');
      }
      connection.joinRequested = true;
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
      if (status != 0) throw StateError('无法连接播报房间');
      if (warmSpec != null && _warmSpec != warmSpec) {
        throw StateError('语音预连接已取消');
      }
      final started = prepareAgent && playback?.cancelled != true
          ? request('POST', '${connection.path}/start')
                .timeout(const Duration(seconds: 12))
                .then<bool>((_) => true, onError: (Object _) => false)
          : null;
      final joined = connection.joined.future.timeout(
        const Duration(seconds: 8),
      );
      if (!await (playback == null
          ? joined
          : Future.any([
              joined,
              playback.cancelSignal.future.then((_) => false),
            ]))) {
        if (playback?.cancelled == true) return connection;
        throw StateError('无法连接播报房间');
      }
      if (started != null) {
        final ready = await (playback == null
            ? started
            : Future.any([
                started,
                playback.cancelSignal.future.then((_) => false),
              ]));
        if (!ready && playback?.cancelled != true) {
          throw StateError('语音播报任务未就绪');
        }
      }
      if (connection.failed) throw StateError('语音播报连接已断开');
      return connection;
    } catch (_) {
      await connection.close();
      rethrow;
    }
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
    _RtcConnection? connection;
    final capture = _ReplyCapture();
    final spec = _warmSpec;
    final reuse =
        segments != null &&
        spec != null &&
        spec.bookId == body['book_id'] &&
        spec.voiceId == voiceId &&
        _warmMatches(spec);
    final turnId = reuse ? body['request_id'] as String : null;
    var sent = false;
    var completed = false;
    try {
      if (playback.cancelled) return;
      _nativeRelease = playback.released.future;
      if (reuse) {
        connection = _warm!;
      } else {
        await _dropWarm();
        if (playback.cancelled) return;
        connection = await _connect(
          path,
          body,
          request,
          prepareAgent: segments != null,
          playback: playback,
        );
      }
      final active = connection;
      final engine = active.engine!;
      if (playback.cancelled) return;
      active.playback = playback;
      active.capture = capture;
      playback.engine = engine;
      final queue = StreamIterator(
        segments ??
            Stream<int>.fromIterable(
              Iterable<int>.generate(active.session['segments'] as int),
            ),
      );
      try {
        while (!playback.cancelled &&
            await Future.any<bool>([
              queue.moveNext(),
              playback.cancelSignal.future.then((_) => false),
            ])) {
          if (playback.cancelled) return;
          if (playback.failed || active.failed) {
            throw StateError('语音播报连接已断开');
          }
          if (!capture.attempted) await capture.start(engine);
          if (playback.cancelled) return;
          if (reuse && !sent) await engine.setPlaybackVolume(100);
          if (playback.cancelled) return;
          final segment = playback.segment = Completer<bool>();
          sent = true;
          final accepted = await Future.any<bool>([
            request('POST', '${active.path}/speak', {
              'segment': queue.current,
              'request_id': ?turnId,
            }).timeout(const Duration(seconds: 20)).then((_) => true),
            playback.cancelSignal.future.then((_) => false),
          ]);
          if (!accepted || playback.cancelled) return;
          if (!await segment.future.timeout(const Duration(seconds: 80))) {
            if (playback.cancelled) return;
            throw StateError('语音播报未完成');
          }
          playback.segment = null;
        }
      } finally {
        await queue.cancel();
      }
      if (sent) {
        // Drain the last frames before muting or reusing the room.
        await Future.any<void>([
          Future<void>.delayed(const Duration(milliseconds: 350)),
          playback.cancelSignal.future,
        ]);
        if (turnId != null && !playback.cancelled && !playback.failed) {
          await request('POST', '${active.path}/finish', {
            'request_id': turnId,
          }).timeout(const Duration(seconds: 5));
        }
      }
      completed = !playback.cancelled && !playback.failed && !active.failed;
    } on MissingPluginException {
      if (!playback.cancelled) {
        throw const RtcReplyFailure('当前 App 缺少语音组件，请重新编译安装后再试');
      }
    } catch (_) {
      if (!playback.cancelled) rethrow;
    } finally {
      try {
        final engine = connection?.engine;
        if (engine != null) {
          await capture.stop(engine, keep: completed);
          if (reuse) {
            try {
              await engine.setPlaybackVolume(0);
            } catch (_) {
              connection?.fail();
            }
          }
        }
      } finally {
        connection?.playback = null;
        connection?.capture = null;
        playback.engine = null;
        if (reuse && sent && !completed) {
          // An interrupted segment can still emit callbacks. Retire its room
          // before playing the next turn so those callbacks cannot finish it.
          connection?.fail();
        }
        if (!reuse && connection != null) {
          await connection.closeNative();
          _closingSession = connection.closeServer();
        }
        if (identical(_nativeRelease, playback.released.future)) {
          _nativeRelease = null;
        }
        playback.released.complete();
      }
      final next = _warmSpec;
      if (_warmSupported &&
          next != null &&
          (!reuse || connection?.failed == true)) {
        unawaited(_serialize(() => _prepareWarm(next)));
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
}

class _RtcConnection {
  _RtcConnection(this.owner, this.session, this.request, this.spec)
    : refreshAt = Duration(
        seconds: ((session['ttlSeconds'] as int? ?? 180) - 30).clamp(1, 150),
      );

  final RtcReplyPlayer owner;
  final Map<String, dynamic> session;
  final RtcRequest request;
  final _WarmSpec? spec;
  final Duration refreshAt;
  final age = Stopwatch()..start();
  final joined = Completer<bool>();
  final left = Completer<void>();
  RTCEngine? engine;
  RTCRoom? room;
  _Playback? playback;
  _ReplyCapture? capture;
  bool joinRequested = false;
  bool failed = false;

  String get path => '/api/rtc/sessions/${session['sessionId']}';
  Duration get refreshIn => refreshAt - age.elapsed;
  bool get usable => !failed && refreshIn > Duration.zero;

  void fail() {
    failed = true;
    if (!joined.isCompleted) joined.complete(false);
    playback?.fail();
  }

  Future<void> close() async {
    await closeNative();
    await closeServer();
  }

  Future<void> closeNative() async {
    try {
      if (room != null && joinRequested) {
        await room!.leaveRoom().timeout(const Duration(seconds: 2));
        await left.future.timeout(const Duration(seconds: 1));
      }
    } catch (_) {
      // Continue destroying native resources and closing the server session.
    } finally {
      try {
        room?.destroy();
      } catch (_) {}
      try {
        engine?.destroy();
      } catch (_) {}
    }
  }

  Future<void> closeServer() async {
    try {
      await request('DELETE', path).timeout(const Duration(seconds: 8));
    } catch (_) {
      // The server will expire the room if it cannot be reached.
    }
  }
}

class _Playback {
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
