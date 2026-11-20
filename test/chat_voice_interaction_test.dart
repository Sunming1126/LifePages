import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_pages/chat_shell.dart';
import 'package:life_pages/chatchat_style.dart';
import 'package:life_pages/main.dart';
import 'package:life_pages/onesay_voice_widgets.dart';
import 'package:life_pages/rtc_reply_player.dart';
import 'package:life_pages/voice_io.dart';
import 'package:record/record.dart';

class Capture extends VoiceCapture {
  final audio = StreamController<List<int>>.broadcast();
  bool permitted = true;
  Completer<bool>? permission;
  int starts = 0;
  @override
  Future<bool> hasPermission() async => permission?.future ?? permitted;
  @override
  Future<Stream<List<int>>> startStream(RecordConfig config) async {
    starts++;
    return audio.stream;
  }

  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {
    await audio.close();
  }
}

class Wire extends VoiceWire {
  Wire({this.recognizes = true, this.finishes = true});

  final bool recognizes;
  final bool finishes;
  final incoming = StreamController<dynamic>.broadcast();
  int chunks = 0;
  bool finishRequested = false;
  void event(String event, [Map<String, dynamic>? sentence]) => incoming.add(
    jsonEncode({
      'header': {'event': event},
      if (sentence != null)
        'payload': {
          'output': {'sentence': sentence},
        },
    }),
  );
  @override
  Stream<dynamic> get events => incoming.stream;
  @override
  void add(dynamic data) {
    if (data is String) {
      final action = jsonDecode(data)['header']['action'];
      if (action == 'run-task') event('task-started');
      if (action == 'finish-task') {
        finishRequested = true;
        if (finishes) event('task-finished');
      }
    } else if (recognizes) {
      chunks++;
      event('result-generated', {
        'sentence_id': 0,
        'text': chunks == 1 ? '我小时候' : '我小时候住在海边。',
        'sentence_end': chunks > 1,
      });
    }
  }

  @override
  Future<void> close() async {
    if (!incoming.isClosed) await incoming.close();
  }
}

class ChatApi extends Api {
  final turns = <Map<String, dynamic>>[];
  final turnPaths = <String>[];
  final queuedOriginals = <String>[];
  bool supportsDeferredAudio = false;
  Completer<String>? nativeQueue;
  String? fallbackAudio;
  List<dynamic> history = [];
  final topics = [
    {
      'id': 'p',
      'number': 1,
      'title': '故乡的轮廓',
      'theme': '故土与根脉',
      'character_count': 0,
    },
    {
      'id': 'p2',
      'number': 2,
      'title': '家族的记忆',
      'theme': '故土与根脉',
      'character_count': 0,
    },
  ];
  final sessionMessages = <String, List<dynamic>>{};
  String activeSession = 'p';
  Completer<void>? responseBlock, topicBlock, historyBlock, activationBlock;
  Completer<String>? firstChunk;
  bool supportsCombinedActivation = false;
  bool emitSpeech = false;
  final refreshRequests = <String>[];
  int topicRequests = 0, historyRequests = 0;
  @override
  Future<String> enqueueVoiceUpload({
    required String book,
    required String message,
    required String request,
    required String path,
  }) async {
    queuedOriginals.add(path);
    expect(message, 'user-1');
    expect(request, turns.single['request_id']);
    return nativeQueue!.future;
  }

  @override
  Future<Map<String, PendingVoiceUpload>> pendingVoiceUploads(
    String book,
  ) async => {};

  @override
  Stream<Map<String, dynamic>> streamTurn(
    String path,
    Map<String, dynamic> body, {
    required bool speak,
  }) async* {
    if (firstChunk case final chunk?) {
      yield {'type': 'delta', 'text': await chunk.future};
    }
    if (emitSpeech && speak) yield {'type': 'speech', 'segment': 0};
    final reply = await call('POST', path, body) as Map<String, dynamic>;
    if (emitSpeech && speak) yield {'type': 'speech', 'segment': 1};
    yield {'type': 'done', ...reply};
  }

  @override
  Future<dynamic> call(
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    if (path == '/api/transcribe') {
      fallbackAudio = body!['audio_base64'] as String;
      return {'text': '我小时候住在海边。'};
    }
    if (path.endsWith('/voice/token')) {
      return {
        'token': 'st-test',
        'expires_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 120,
      };
    }
    final uri = Uri.parse(path);
    if (method == 'POST' && uri.path.endsWith('/refresh')) {
      refreshRequests.add(path);
      final id = uri.pathSegments[uri.pathSegments.length - 2];
      final message = history.singleWhere((row) => row['id'] == id) as Map;
      expect(body!['text'], message['text']);
      message['text'] = '谁最常陪您在院子里坐一坐？';
      return {'id': id, 'text': message['text']};
    }
    if (uri.path.endsWith('/topics')) {
      topicRequests++;
      await topicBlock?.future;
      return {
        'active_id': activeSession,
        'topics': topics,
        if (supportsDeferredAudio) 'deferred_voice_upload': true,
      };
    }
    if (method == 'PUT' && uri.path.endsWith('/active')) {
      await activationBlock?.future;
      activeSession = uri.pathSegments[uri.pathSegments.length - 2];
      return {
        'active_id': activeSession,
        if (supportsCombinedActivation &&
            uri.queryParameters['include_messages'] == 'true')
          'messages': activeSession == 'p'
              ? history
              : sessionMessages[activeSession] ?? [],
      };
    }
    if (method == 'GET') {
      historyRequests++;
      await historyBlock?.future;
      final id = uri.queryParameters['session_id'] ?? 'p';
      return {
        'messages': id == 'p' ? history : sessionMessages[id] ?? [],
        'chapters': [],
      };
    }
    if (path.endsWith('/turns') || path.endsWith('/voice-turns')) {
      turnPaths.add(path);
      turns.add(Map<String, dynamic>.from(body!));
      await responseBlock?.future;
      final id = body['session_id'] as String? ?? 'p';
      final messages = id == 'p'
          ? history
          : sessionMessages.putIfAbsent(id, () => []);
      messages.addAll([
        {
          'id': 'user-${turns.length}',
          'request_id': body['request_id'],
          'role': 'user',
          'text': body['text'],
        },
        {'id': 'ai-${turns.length}', 'role': 'assistant', 'text': '我在听。'},
      ]);
      return {
        'text': '我在听。',
        if (path.endsWith('/voice-turns')) ...{
          'user_id': 'user-${turns.length}',
          'assistant_id': 'ai-${turns.length}',
        },
      };
    }
    throw StateError('Unexpected API request $path');
  }
}

class ReplyPlayerProbe extends RtcReplyPlayer {
  int stops = 0;
  final segments = <List<int>>[];

  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<void> playTurn(
    String bookId,
    String requestId,
    Stream<int> audio,
    RtcRequest request, {
    required String voiceId,
    required Future<RtcReplayMessage?> replayMessage,
  }) async {
    final playback = <int>[];
    segments.add(playback);
    await for (final segment in audio) {
      playback.add(segment);
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    final font = File('/System/Library/Fonts/STHeiti Medium.ttc');
    if (font.existsSync()) {
      final loader = FontLoader('AcceptanceChinese')
        ..addFont(Future.value(ByteData.sublistView(font.readAsBytesSync())));
      await loader.load();
    }
  });
  late Directory dir;
  late Capture capture;
  late ChatApi api;
  final wires = <Wire>[];
  setUp(() async {
    dir = Directory.systemTemp.createTempSync('lifepages-ui-');
    capture = Capture();
    api = ChatApi();
    wires.clear();
    FlutterSecureStorage.setMockInitialValues({'ai_consent_v2_p': 'yes'});
  });
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Widget harness({
    double keyboard = 0,
    int tab = 0,
    RtcReplyPlayer? player,
    bool recognizes = true,
    bool finishes = true,
  }) => MaterialApp(
    theme: ThemeData(
      useMaterial3: true,
      fontFamily: 'AcceptanceChinese',
      scaffoldBackgroundColor: paper,
    ),
    home: MediaQuery(
      data: MediaQueryData(
        size: const Size(390, 844),
        viewInsets: EdgeInsets.only(bottom: keyboard),
      ),
      child: Scaffold(
        body: RepaintBoundary(
          key: const ValueKey('screen'),
          child: Stack(
            children: [
              const Positioned.fill(child: ColoredBox(color: paper)),
              IndexedStack(
                index: tab,
                children: [
                  FreeChatPage(
                    personId: 'p',
                    bookTitle: '我的回忆录',
                    active: tab == 0,
                    showNavigation: keyboard == 0,
                    voiceCapture: capture,
                    replyPlayer: player,
                    client: api,
                    documentsDirectory: () async => dir,
                    voiceConnector: (url, headers) async {
                      final w = Wire(
                        recognizes: recognizes,
                        finishes: finishes,
                      );
                      wires.add(w);
                      return w;
                    },
                  ),
                  const SizedBox.expand(),
                ],
              ),
              if (keyboard == 0)
                Positioned(
                  left: OneSayChatNavigation.horizontalInset,
                  right: OneSayChatNavigation.horizontalInset,
                  bottom: OneSayChatNavigation.bottomGap,
                  height: OneSayChatNavigation.height,
                  child: OneSayChatNavigation(
                    selectedIndex: tab,
                    onTabSelected: (_) {},
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
  Future<void> flush(WidgetTester tester) async {
    for (var i = 0; i < 16; i++) {
      await tester.pump();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 15));
      });
      await tester.pump();
    }
  }

  Future<void> captureLayout(
    WidgetTester tester,
    String name, {
    String boundaryKey = 'screen',
  }) async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(ValueKey(boundaryKey)),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory('artifacts').create();
        await File(
          'artifacts/$name.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });
  }

  Future<TestGesture> hold(WidgetTester tester) async {
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(HoldToTalkButton)),
    );
    await tester.pump(const Duration(milliseconds: 650));
    await flush(tester);
    return gesture;
  }

  testWidgets(
    'assistant text comes first and can be selected, copied and refreshed',
    (tester) async {
      const original = '您最记得故乡的什么地方？';
      api.history = [
        {'id': 'opening', 'role': 'assistant', 'text': original},
      ];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      String? clipboard;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard = call.arguments['text'] as String;
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await tester.pumpWidget(harness(player: ReplyPlayerProbe()));
      await flush(tester);
      final message = find.widgetWithText(SelectableText, original);
      final speaker = find.byTooltip('播放 AI 语音');
      expect(
        tester.getBottomLeft(message).dy,
        lessThanOrEqualTo(tester.getTopLeft(speaker).dy),
      );
      expect(find.text('AI'), findsNothing);
      await tester.tap(find.byTooltip('复制消息'));
      await tester.pumpAndSettle();
      expect(clipboard, original);
      await tester.longPress(message);
      await tester.pumpAndSettle();
      final editable = tester.widget<EditableText>(
        find.descendant(of: message, matching: find.byType(EditableText)),
      );
      expect(editable.controller.selection.isCollapsed, isFalse);
      editable.focusNode.unfocus();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('换一个问题'));
      await tester.pumpAndSettle();
      expect(api.refreshRequests, [
        '/api/books/p/topics/p/messages/opening/refresh',
      ]);
      expect(find.text('谁最常陪您在院子里坐一坐？'), findsOneWidget);
    },
  );

  for (final failFirst in [false, true]) {
    testWidgets(
      'hold interrupts audio and queues a follow-up; previous failure: $failFirst',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        FlutterSecureStorage.setMockInitialValues({
          'ai_consent_v2_p': 'yes',
          'rtc_reply_consent_v2_p': 'yes',
        });
        final player = ReplyPlayerProbe();
        final waiting = Completer<void>();
        api
          ..firstChunk = (Completer<String>()..complete('回复第一段正在显示'))
          ..emitSpeech = true
          ..responseBlock = waiting;
        await tester.pumpWidget(harness(player: player));
        await flush(tester);

        Future<void> record() async {
          final gesture = await hold(tester);
          capture.audio.add(List<int>.filled(3200, 1));
          await flush(tester);
          capture.audio.add(List<int>.filled(3200, 2));
          await flush(tester);
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 650)),
          );
          await gesture.up();
          await flush(tester);
          await flush(tester);
          for (
            var i = 0;
            i < 4 && find.text('正在确认').evaluate().isNotEmpty;
            i++
          ) {
            await flush(tester);
          }
        }

        await record();
        expect(capture.starts, 1);
        // Windows may complete the WAV write after the fixed frame flushes.
        // Wait for the observable request, while keeping the exact count below.
        for (var i = 0; i < 20 && api.turns.isEmpty; i++) {
          await flush(tester);
        }
        expect(api.turns, hasLength(1));
        expect(player.segments, [
          [0],
        ]);
        final before = player.stops;
        if (!failFirst) {
          final cancelled = await hold(tester);
          await cancelled.moveBy(const Offset(0, -80));
          await tester.pump();
          await cancelled.up();
          await flush(tester);
          expect(api.turns, hasLength(1));
        }
        await record();
        expect(capture.starts, failFirst ? 2 : 3);
        expect(player.stops, greaterThan(before));
        expect(api.turns, hasLength(1));
        expect(find.text('已录好，等待上一条回复'), findsOneWidget);
        expect(find.text('回复第一段正在显示'), findsOneWidget);
        api
          ..responseBlock = null
          ..firstChunk = null;
        if (failFirst) {
          waiting.completeError(Exception('上一轮失败'));
          await flush(tester);
          expect(api.turns, hasLength(1));
          expect(find.text('已录好，请先重试上一条回复'), findsOneWidget);
          final retry = find.text('重试').hitTestable();
          await tester.ensureVisible(retry);
          await tester.tap(retry);
        } else {
          waiting.complete();
        }
        await flush(tester);
        await flush(tester);
        expect(api.turns, hasLength(failFirst ? 3 : 2));
        expect(api.turns.last['session_id'], api.turns.first['session_id']);
        expect(
          api.turns.last['request_id'],
          isNot(api.turns.first['request_id']),
        );
        if (failFirst) {
          expect(api.turns[1]['request_id'], api.turns.first['request_id']);
        }
        expect(player.segments, [
          [0],
          [0, 1],
        ]);
        expect(
          api.history.where((message) => message['role'] == 'assistant'),
          hasLength(2),
        );
      },
    );
  }

  testWidgets(
    'Android recovers a stalled realtime transcript with the saved WAV',
    (tester) async {
      await tester.pumpWidget(harness(finishes: false));
      await flush(tester);
      final gesture = await hold(tester);
      capture.audio.add(List<int>.filled(3200, 1));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 650)),
      );
      await gesture.up();
      for (var i = 0; i < 5 && !wires.single.finishRequested; i++) {
        await flush(tester);
      }
      expect(wires.single.finishRequested, isTrue);
      expect(api.turns, isEmpty);
      await tester.pump(const Duration(milliseconds: 3100));
      for (var i = 0; i < 5 && api.turns.isEmpty; i++) {
        await flush(tester);
      }
      final turn = api.turns.single;
      expect(turn['text'], '我小时候住在海边。');
      expect(turn['audio_base64'], api.fallbackAudio);
      expect(
        utf8.decode(base64Decode(api.fallbackAudio!).take(4).toList()),
        'RIFF',
      );
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'Android displays the streamed reply before native audio upload',
    (tester) async {
      api.supportsDeferredAudio = true;
      api.firstChunk = Completer<String>();
      api.responseBlock = Completer<void>();
      api.nativeQueue = Completer<String>();
      await tester.pumpWidget(harness());
      await flush(tester);
      final gesture = await hold(tester);
      capture.audio.add(List<int>.filled(3200, 1));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 650)),
      );
      await gesture.up();
      await flush(tester);
      api.firstChunk!.complete('先收到文字');
      for (var i = 0; i < 5 && api.turns.isEmpty; i++) {
        await flush(tester);
      }
      expect(api.turnPaths.single, '/api/people/p/voice-turns');
      expect(api.turns.single['payload_hash'], matches(r'^[0-9a-f]{64}$'));
      expect(api.turns.single.containsKey('audio_base64'), isFalse);
      expect(find.text('先收到文字'), findsOneWidget);
      expect(api.queuedOriginals, isEmpty);

      api.responseBlock!.complete();
      for (var i = 0; i < 5 && api.queuedOriginals.isEmpty; i++) {
        await flush(tester);
      }
      expect(find.text('我在听。'), findsOneWidget);
      expect(File(api.queuedOriginals.single).existsSync(), isTrue);
      api.nativeQueue!.complete('${dir.path}/native.wav');
      await flush(tester);
      expect(File(api.queuedOriginals.single).existsSync(), isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets('unrecognized voice is kept on disk and is not submitted', (
    tester,
  ) async {
    await tester.pumpWidget(harness(recognizes: false));
    await flush(tester);
    final gesture = await hold(tester);
    capture.audio.add(List<int>.filled(3200, 1));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 650)),
    );
    await gesture.up();
    await flush(tester);
    await flush(tester);
    expect(api.turns, isEmpty);
    expect(find.text('没有识别到内容，录音已保留。'), findsOneWidget);
    final saved = jsonDecode(
      File('${dir.path}/book-outbox-p.json').readAsStringSync(),
    );
    final turn = (saved['turns'] as List).single;
    expect(turn['text'], isEmpty);
    expect(File(turn['audio_path'] as String).existsSync(), isTrue);
  });

  testWidgets(
    'failed draft does not disable mic; hold shows live text and release sends WAV',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      File('${dir.path}/book-outbox-p.json').writeAsStringSync(
        jsonEncode({
          'request_id': 'a' * 32,
          'text': '',
          'audio_path': '${dir.path}/old.wav',
        }),
      );
      await tester.pumpWidget(harness());
      await flush(tester);
      expect(find.text('语音已保存'), findsNothing);
      final mic = tester.getRect(find.byType(HoldToTalkButton));
      final nav = tester.getRect(find.byType(OneSayChatNavigation));
      expect(find.text('长按说话'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(mic.bottom, lessThan(nav.top));
      expect(mic.width, greaterThan(200));
      final gesture = await hold(tester);
      expect(find.byType(OneSayVoiceDock), findsOneWidget);
      expect(capture.starts, 1);
      capture.audio.add(List<int>.filled(3200, 1));
      await flush(tester);
      expect(find.text('我小时候'), findsOneWidget);
      capture.audio.add(List<int>.filled(3200, 2));
      await flush(tester);
      expect(find.text('我小时候住在海边。'), findsOneWidget);
      // Capture the actual widget tree without launching an app or simulator.
      await tester.pump(const Duration(milliseconds: 800));
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('screen')),
      );
      final bytes = await tester.runAsync(() async {
        final image = await boundary.toImage();
        return image.toByteData(format: ui.ImageByteFormat.png);
      });
      await tester.runAsync(() async {
        await Directory('artifacts').create();
        await File(
          'artifacts/voice-recording-headless.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        await Future<void>.delayed(const Duration(milliseconds: 650));
      });
      await gesture.up();
      await flush(tester);
      await flush(tester);
      expect(api.turns.length, 1);
      expect(api.turns.single['text'], '我小时候住在海边。');
      expect(
        String.fromCharCodes(
          base64Decode(api.turns.single['audio_base64'] as String).take(4),
        ),
        'RIFF',
      );
      expect(find.text('语音已保存'), findsNothing);
      for (
        var i = 0;
        i < 8 && find.byType(ChatChatThinkingBubble).evaluate().isNotEmpty;
        i++
      ) {
        await flush(tester);
      }
      final saved =
          jsonDecode(File('${dir.path}/book-outbox-p.json').readAsStringSync())
              as Map;
      expect(
        (saved['turns'] as List).single['request_id'],
        'a' * 32,
      ); // Hidden draft remains recoverable.
      await tester.pumpWidget(const SizedBox());
      await flush(tester);
    },
  );

  testWidgets(
    'dragging away cancels without sending or leaving the dock stuck',
    (tester) async {
      await tester.pumpWidget(harness());
      await flush(tester);
      final gesture = await hold(tester);
      capture.audio.add(List<int>.filled(3200, 1));
      await flush(tester);
      await gesture.moveBy(const Offset(0, -80));
      await tester.pump();
      expect(find.text('松开取消'), findsOneWidget);
      await gesture.up();
      await flush(tester);
      expect(api.turns, isEmpty);
      expect(find.byType(OneSayVoiceDock), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await flush(tester);
    },
  );

  testWidgets(
    'release while permission is pending cannot start a hidden recording',
    (tester) async {
      capture.permission = Completer<bool>();
      await tester.pumpWidget(harness());
      await flush(tester);
      final gesture = await hold(tester);
      expect(find.byType(OneSayVoiceDock), findsOneWidget);
      await gesture.up();
      capture.permission!.complete(true);
      await flush(tester);
      expect(capture.starts, 0);
      expect(find.byType(OneSayVoiceDock), findsNothing);
      expect(api.turns, isEmpty);
      await tester.pumpWidget(const SizedBox());
      await flush(tester);
    },
  );
  testWidgets('permission denial is visible and a new press can recover', (
    tester,
  ) async {
    capture.permitted = false;
    await tester.pumpWidget(harness());
    await flush(tester);
    final first = await hold(tester);
    expect(find.textContaining('请允许麦克风权限'), findsOneWidget);
    await first.up();
    await flush(tester);
    capture.permitted = true;
    final second = await hold(tester);
    expect(capture.starts, 1);
    capture.audio.add(List<int>.filled(3200, 1));
    await flush(tester);
    expect(find.text('我小时候'), findsOneWidget);
    await second.moveBy(const Offset(0, -80));
    await second.up();
    await flush(tester);
    expect(api.turns, isEmpty);
    await tester.pumpWidget(const SizedBox());
    await flush(tester);
  });
  testWidgets('keyboard and voice switch both ways and retain the text draft', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    api.history = [
      for (var i = 0; i < 24; i++)
        {'id': 'old-$i', 'role': 'assistant', 'text': '回忆片段 $i'},
    ];
    const keyboard = ValueKey('assistant-keyboard-mode');
    const voice = ValueKey('assistant-voice-mode');
    const send = ValueKey('assistant-send-button');
    const composer = ValueKey('assistant-composer-surface');
    await tester.pumpWidget(harness());
    await flush(tester);
    final chatNavigation = tester.getRect(find.byType(OneSayChatNavigation));
    final voiceIsland = tester.getRect(find.byKey(composer));
    expect(chatNavigation, const Rect.fromLTWH(18, 766, 354, 64));
    expect(voiceIsland.left, 16);
    expect(voiceIsland.right, 374);
    expect(voiceIsland.bottom, 750);
    expect(chatNavigation.top - voiceIsland.bottom, 16);
    expect(tester.getRect(find.byType(ListView)).bottom, 844);
    expect(
      find.descendant(
        of: find.byType(HoldToTalkButton),
        matching: find.byType(DecoratedBox),
      ),
      findsNothing,
    );
    await captureLayout(tester, 'chat-voice-islands-headless');
    await tester.pumpWidget(harness(tab: 1));
    await tester.pump();
    expect(tester.getRect(find.byType(OneSayChatNavigation)), chatNavigation);
    expect(find.byType(HoldToTalkButton), findsNothing);
    await tester.pumpWidget(harness());
    await tester.pump();

    expect(find.byKey(keyboard), findsOneWidget);
    expect(find.byKey(send), findsNothing);
    expect(find.byKey(voice), findsNothing);
    await tester.tap(find.byKey(keyboard));
    await tester.pump();
    expect(tester.testTextInput.isVisible, isTrue);
    expect(find.byKey(keyboard), findsNothing);
    expect(find.byKey(send), findsOneWidget);
    const draft = '一段还没发出的文字\n第二行\n第三行';
    await tester.enterText(find.byType(TextField), draft);
    await tester.pumpWidget(harness(keyboard: 310));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    expect(find.byType(OneSayChatNavigation), findsNothing);
    final voiceButton = tester.getRect(find.byKey(voice));
    final textIsland = tester.getRect(find.byKey(composer));
    expect(voiceButton.size, const Size(44, 44));
    expect(textIsland.top - voiceButton.bottom, 10);
    expect(
      voiceButton.center.dx,
      closeTo(tester.getCenter(find.byKey(send)).dx, 2),
    );
    expect(textIsland.height, greaterThan(voiceIsland.height));
    expect(textIsland.bottom, 844 - 310 - 12);
    final list = tester.widget<ListView>(find.byType(ListView));
    list.controller!.jumpTo(list.controller!.position.maxScrollExtent);
    await tester.pump();
    expect(
      tester.getRect(find.text('回忆片段 23')).bottom,
      lessThan(voiceButton.top),
    );
    await captureLayout(tester, 'chat-text-islands-headless');

    await tester.tap(find.byKey(voice));
    await tester.pumpWidget(harness());
    await tester.pump();
    expect(tester.testTextInput.isVisible, isFalse);
    expect(find.text('长按说话'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.byKey(voice), findsNothing);
    expect(api.turns, isEmpty);

    await tester.tap(find.byKey(keyboard));
    await tester.pump();
    expect(find.text(draft), findsOneWidget);
    expect(capture.starts, 0);
  });

  testWidgets('chapter directory switches history and routes new messages', (
    tester,
  ) async {
    api.history = [
      {'id': 'old', 'role': 'user', 'text': '只属于第一章'},
    ];
    for (var number = 3; number <= 26; number++) {
      api.topics.add({
        'id': 'p$number',
        'number': number,
        'title': '测试章节 $number',
        'theme': '故土与根脉',
        'character_count': 0,
      });
    }
    await tester.pumpWidget(
      RepaintBoundary(key: const ValueKey('modal-screen'), child: harness()),
    );
    await flush(tester);
    expect(find.text('只属于第一章'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('assistant-keyboard-mode')));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '留在第一章的草稿');

    Future<void> openSessionSheet() async {
      await tester.tap(find.byKey(const ValueKey('assistant-history-button')));
      await tester.pumpAndSettle();
      expect(find.text('章节目录'), findsOneWidget);
      final sheet = tester.getRect(
        find.byKey(const ValueKey('chat-bottom-sheet')),
      );
      final nav = tester.getRect(find.byType(OneSayChatNavigation));
      expect(sheet.left, lessThanOrEqualTo(nav.left));
      expect(sheet.right, greaterThanOrEqualTo(nav.right));
      expect(sheet.top, lessThan(nav.top));
      expect(sheet.bottom, greaterThan(nav.bottom));
    }

    final delayed = Completer<void>();
    api.topicBlock = delayed;
    await openSessionSheet();
    expect(find.text('家族的记忆'), findsOneWidget);
    final scrollbar = find.byKey(const ValueKey('chapter-directory-scrollbar'));
    final widget = tester.widget<RawScrollbar>(scrollbar);
    expect(widget.thumbVisibility, isTrue);
    expect(widget.scrollbarOrientation, ScrollbarOrientation.right);
    final controller = widget.controller!;
    expect(controller.position.maxScrollExtent, greaterThan(0));
    final listBounds = tester.getRect(scrollbar);
    await tester.dragFrom(
      Offset(listBounds.right - 4, listBounds.top + 24),
      const Offset(0, 120),
    );
    await tester.pumpAndSettle();
    expect(controller.offset, greaterThan(0));
    controller.jumpTo(0);
    await tester.pumpAndSettle();
    final inFlight = api.topicRequests;
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    await openSessionSheet();
    expect(api.topicRequests, inFlight);
    delayed.completeError(Exception('离线'));
    api.topicBlock = null;
    await tester.pumpAndSettle();
    expect(find.text('家族的记忆'), findsOneWidget);
    await captureLayout(
      tester,
      'chat-topic-sheet-headless',
      boundaryKey: 'modal-screen',
    );
    final beforeSwitch = api.historyRequests;
    api.supportsCombinedActivation = true;
    api.sessionMessages['p2'] = [
      {'id': 'opener', 'role': 'assistant', 'text': '说说家里的长辈吧。'},
    ];
    final firstActivation = api.activationBlock = Completer<void>();
    await tester.tap(find.text('家族的记忆'));
    await tester.pumpAndSettle();
    expect(find.text('第 2 章 · 家族的记忆'), findsOneWidget);
    expect(find.text('正在加载本章聊天…'), findsOneWidget);
    expect(find.text('只属于第一章'), findsNothing);
    firstActivation.complete();
    api.activationBlock = null;
    await tester.pumpAndSettle();
    expect(find.text('说说家里的长辈吧。'), findsOneWidget);
    expect(api.historyRequests, beforeSwitch);
    final newId = api.activeSession;
    expect(newId, isNot('p'));
    expect(find.text('只属于第一章'), findsNothing);

    expect(find.text('留在第一章的草稿'), findsNothing);
    await tester.enterText(find.byType(TextField), '只属于第二章');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('assistant-send-button')));
    await flush(tester);
    expect(api.turns.single['session_id'], newId);

    await openSessionSheet();
    final returnActivation = api.activationBlock = Completer<void>();
    await tester.tap(find.text('故乡的轮廓'));
    await tester.pumpAndSettle();
    expect(api.activeSession, newId);
    expect(find.text('第 1 章 · 故乡的轮廓'), findsOneWidget);
    expect(find.text('只属于第一章'), findsOneWidget);
    expect(find.text('留在第一章的草稿'), findsOneWidget);
    expect(find.text('只属于第二章'), findsNothing);
    returnActivation.completeError(Exception('离线'));
    api.activationBlock = null;
    await tester.pumpAndSettle();
    expect(find.text('只属于第一章'), findsOneWidget);
    api.supportsCombinedActivation = false;
    final beforeRetry = api.historyRequests;
    await tester.tap(find.text('本章未同步，点此重试'));
    await tester.pumpAndSettle();
    expect(api.activeSession, 'p');
    expect(api.historyRequests, beforeRetry + 1);
    expect(find.text('只属于第一章'), findsOneWidget);
  });

  testWidgets('cancelled pointer ends the in-composer recording', (
    tester,
  ) async {
    await tester.pumpWidget(harness());
    await flush(tester);
    final gesture = await hold(tester);
    expect(find.byType(OneSayVoiceDock), findsOneWidget);
    await gesture.cancel();
    await flush(tester);
    expect(find.byType(OneSayVoiceDock), findsNothing);
    expect(find.text('长按说话'), findsOneWidget);
    expect(api.turns, isEmpty);
    await tester.pumpWidget(const SizedBox());
    await flush(tester);
  });

  testWidgets(
    'ChatChat bubbles and thinking animation follow the reply lifecycle',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      api.history = [
        {'id': 'first', 'role': 'user', 'text': '小时候我住在海边。', 'has_audio': 1},
        {'id': 'second', 'role': 'assistant', 'text': '海边的生活是什么样的？你愿意讲讲吗？'},
      ];
      api.responseBlock = Completer<void>();
      api.firstChunk = Completer<String>();
      await tester.pumpWidget(harness());
      await flush(tester);
      expect(find.text('我'), findsNothing);
      expect(find.text('播放原声'), findsNothing);
      expect(find.byType(ChatChatMessageBubble), findsNWidgets(2));
      await tester.tap(find.byKey(const ValueKey('assistant-keyboard-mode')));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '夏天常和伙伴去赶海。');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('assistant-send-button')));
      await flush(tester);
      expect(find.text('夏天常和伙伴去赶海。'), findsOneWidget);
      expect(find.byType(ChatChatThinkingBubble), findsOneWidget);
      List<Color?> dotColors() => tester
          .widgetList<Container>(
            find.descendant(
              of: find.byType(ChatChatThinkingBubble),
              matching: find.byType(Container),
            ),
          )
          .where(
            (c) =>
                c.decoration is BoxDecoration &&
                (c.decoration as BoxDecoration).shape == BoxShape.circle,
          )
          .map((c) => (c.decoration as BoxDecoration).color)
          .toList();
      final before = dotColors();
      await tester.pump(const Duration(milliseconds: 220));
      expect(dotColors(), isNot(equals(before)));
      expect(find.text('语音已保存'), findsNothing);
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('screen')),
      );
      final bytes = await tester.runAsync(() async {
        final image = await boundary.toImage();
        return image.toByteData(format: ui.ImageByteFormat.png);
      });
      await tester.runAsync(() async {
        await Directory('artifacts').create();
        await File(
          'artifacts/chatchat-thinking-headless.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
      });
      api.firstChunk!.complete('我在');
      await flush(tester);
      expect(find.byType(ChatChatThinkingBubble), findsNothing);
      expect(find.text('我在'), findsOneWidget);
      api.historyBlock = Completer<void>();
      api.responseBlock!.complete();
      await flush(tester);
      expect(find.text('夏天常和伙伴去赶海。'), findsOneWidget);
      expect(find.text('我在'), findsOneWidget);
      api.historyBlock!.complete();
      await flush(tester);
      expect(find.text('夏天常和伙伴去赶海。'), findsOneWidget);
      expect(find.byType(ChatChatThinkingBubble), findsNothing);
      expect(find.text('我在听。'), findsOneWidget);
      expect(find.text('我在'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await flush(tester);
    },
  );
}
