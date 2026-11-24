import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_pages/chapter_editor.dart';
import 'package:life_pages/main.dart';
import 'package:life_pages/onesay_voice_widgets.dart';

import 'chat_voice_interaction_test.dart' show Capture;

class ManuscriptApi extends Api {
  ManuscriptApi({required bool hasBody}) {
    if (hasBody) {
      rows['a']!['blocks'] = [
        {'id': 'old', 'kind': 'text', 'text': 'AI 整理的正文。'},
      ];
    }
  }

  final rows = {
    for (final (i, id) in ['a', 'b'].indexed)
      id: <String, dynamic>{
        'id': id,
        'number': i + 1,
        'title': i == 0 ? '故乡' : '家人',
        'theme': '回忆',
        'question': '您还记得什么？',
        'revision': 0,
        'blocks': <Map<String, dynamic>>[],
      },
  };
  final images = <String, String>{};
  final suggestions = <Map<String, dynamic>>[];
  int saves = 0;
  int manuscriptReads = 0;
  Completer<void>? suggestionGate;
  bool offline = false;
  bool emptyDirectory = false;
  bool organizing = false;

  @override
  Future<dynamic> call(
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    final uri = Uri.parse(path);
    final parts = uri.pathSegments;
    if (path == '/api/transcribe') {
      expect(
        base64Decode(body!['audio_base64'] as String).length,
        greaterThan(3200),
      );
      return {'text': '保留原话的意思'};
    }
    if (uri.path.endsWith('/directory')) {
      return {'revision': 0, 'topics': rows.values.toList(), 'archived': []};
    }
    if (uri.path.endsWith('/chapters')) {
      return [
        for (final row in rows.values)
          if ((row['blocks'] as List).isNotEmpty)
            {
              'id': 'chapter-${row['id']}',
              'title': row['title'],
              'topic_id': row['id'],
              'topic_number': row['number'],
              'content': (row['blocks'] as List)
                  .where((block) => block['kind'] == 'text')
                  .map((block) => block['text'])
                  .join('\n\n'),
              'blocks': row['blocks'],
            },
      ];
    }
    if (uri.path.endsWith('/topics')) {
      if (method == 'GET' && emptyDirectory) {
        return {'active_id': null, 'topics': []};
      }
      if (method == 'POST') {
        expect(body!['generate_question'], isTrue);
        final id = body['id'] as String;
        final position = (rows[body['after_id']]!['number'] as int) + 1;
        for (final row in rows.values.where(
          (row) => (row['number'] as int) >= position,
        )) {
          row['number'] = (row['number'] as int) + 1;
        }
        rows[id] = {
          ...body,
          'question': '您最想从这段经历的哪一幕说起？',
          'number': position,
          'theme': '自定义章节',
          'revision': 0,
          'blocks': <Map<String, dynamic>>[],
        };
        return {'id': id};
      }
      return {
        'active_id': 'a',
        'organizing': organizing,
        'manuscript': rows[uri.queryParameters['preferred_id']] ?? rows['a'],
        'topics': rows.values.toList()
          ..sort((a, b) => (a['number'] as int).compareTo(b['number'] as int)),
      };
    }
    final row = rows[parts[4]]!;
    if (method == 'PATCH') {
      expect(body!.containsKey('question'), isFalse);
      row['title'] = body['title'];
      return Map<String, dynamic>.of(row);
    }
    if (uri.path.endsWith('/manuscript')) {
      if (method == 'GET') manuscriptReads++;
      if (method == 'PUT') {
        if (offline) throw const ApiFailure(503, '临时离线');
        saves++;
        expect(body!['revision'], row['revision']);
        row['blocks'] = jsonDecode(jsonEncode(body['blocks']));
        row['revision'] = (row['revision'] as int) + 1;
      }
      return Map<String, dynamic>.of(row);
    }
    if (uri.path.endsWith('/organize')) {
      expect(body!['revision'], row['revision']);
      row['title'] = '石桥边的清晨';
      row['revision'] = (row['revision'] as int) + 1;
      row['blocks'] = [
        {'id': 'organized', 'kind': 'text', 'text': '整理后的完整章节。'},
      ];
      return Map<String, dynamic>.of(row);
    }
    if (uri.path.endsWith('/suggest')) {
      suggestions.add(body!);
      await suggestionGate?.future;
      return {'revision': body['revision'], 'text': '更口语的正文。'};
    }
    if (parts[5] == 'images') {
      if (method == 'PUT') {
        images[body!['id'] as String] = body['data'] as String;
        return {'id': body['id']};
      }
      return {'data': images[parts.last]};
    }
    throw StateError('Unexpected $method $path');
  }
}

Future<void> flushEditor(WidgetTester tester) async {
  for (var i = 0; i < 22; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
}

void main() {
  testWidgets(
    'cached directory chapter is cleared when all directories were removed',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      final dir = Directory.systemTemp.createTempSync(
        'lifepages-empty-directory-',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      final client = ManuscriptApi(hasBody: true);
      final opening = await tester.runAsync(
        () => ChapterOpening.load(
          client,
          'book',
          documentsDirectory: () async => dir,
        ),
      );
      client.emptyDirectory = true;
      await tester.pumpWidget(
        MaterialApp(
          home: ChapterEditor(
            name: '测试',
            bookId: 'book',
            title: '虚构书',
            client: client,
            initialOpening: opening,
            documentsDirectory: () async => dir,
          ),
        ),
      );
      await flushEditor(tester);
      expect(find.text('还没有目录，先添加一章吧。'), findsOneWidget);
      expect(find.text('AI 整理的正文。'), findsNothing);
      expect(find.text('管理目录'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'automatic chapter appears in directory without reopening editor',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      final dir = Directory.systemTemp.createTempSync(
        'lifepages-auto-directory-',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      final api = ManuscriptApi(hasBody: true)..organizing = true;
      await tester.pumpWidget(
        MaterialApp(
          home: ChapterEditor(
            name: '测试',
            bookId: 'book',
            title: '虚构书',
            interview: true,
            client: api,
            documentsDirectory: () async => dir,
          ),
        ),
      );
      await flushEditor(tester);
      expect(find.text('正在自动整理已完成的章节，完成后会显示在章节目录中。'), findsOneWidget);
      api.rows['b']!['title'] = '自动生成的新章名';
      api.organizing = false;
      await tester.pump(const Duration(seconds: 2));
      await flushEditor(tester);
      await tester.tap(find.text('第 1 章 · 故乡'));
      await tester.pumpAndSettle();
      expect(find.text('第 2 章 · 自动生成的新章名'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'interview chapter can organize title and body from editor',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      final dir = Directory.systemTemp.createTempSync('lifepages-organize-');
      addTearDown(() => dir.deleteSync(recursive: true));
      await tester.pumpWidget(
        MaterialApp(
          home: ChapterEditor(
            name: '测试',
            bookId: 'book',
            title: '虚构书',
            interview: true,
            client: ManuscriptApi(hasBody: true),
            documentsDirectory: () async => dir,
          ),
        ),
      );
      await flushEditor(tester);
      expect(find.text('整理本章'), findsOneWidget);
      await tester.tap(find.text('整理本章'));
      await flushEditor(tester);
      expect(find.text('整理后的完整章节。'), findsOneWidget);
      expect(find.text('第 1 章 · 石桥边的清晨'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: TargetPlatformVariant({
      TargetPlatform.iOS,
      TargetPlatform.android,
    }),
  );

  for (final hasBody in [false, true]) {
    testWidgets(
      'chapter editor restores the last chapter with existing body: $hasBody',
      (tester) async {
        FlutterSecureStorage.setMockInitialValues({
          'ai_consent_v2_book': 'yes',
        });
        final dir = Directory.systemTemp.createTempSync('lifepages-editor-');
        addTearDown(() => dir.deleteSync(recursive: true));
        final client = ManuscriptApi(hasBody: hasBody);
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => ChapterEditor(
                      name: '讲述者',
                      bookId: 'book',
                      title: '我的回忆录',
                      client: client,
                      documentsDirectory: () async => dir,
                    ),
                  ),
                ),
                child: const Text('继续创作'),
              ),
            ),
          ),
        );
        await flushEditor(tester);
        expect(find.text('导出 PDF'), findsNothing);
        await tester.tap(find.text('继续创作'));
        await flushEditor(tester);
        expect(find.byType(ChapterEditor), findsOneWidget);
        expect(client.manuscriptReads, 0);
        expect(find.text('添加文字'), findsNothing);
        expect(find.text('整理本章'), findsOneWidget);
        expect(find.text('第 1 章 · 故乡'), findsOneWidget);
        expect(find.text('AI 整理的正文。'), hasBody ? findsOneWidget : findsNothing);
        expect(find.text('从一个画面、一句话或一个人开始写……'), findsOneWidget);
        await tester.tap(find.text('第 1 章 · 故乡'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('第 2 章 · 家人'));
        await flushEditor(tester);
        expect(find.text('第 2 章 · 家人'), findsOneWidget);
        await tester.tap(find.byType(BackButton));
        await flushEditor(tester);
        expect(find.text('继续创作'), findsOneWidget);
        await tester.tap(find.text('继续创作'));
        await flushEditor(tester);
        expect(find.text('第 2 章 · 家人'), findsOneWidget);
        if (!hasBody) {
          await tester.tap(find.text('第 2 章 · 家人'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('第 1 章 · 故乡'));
          await flushEditor(tester);
          expect(find.byTooltip('添加章节'), findsNothing);
          expect(find.byTooltip('编辑章节'), findsNothing);
          expect(find.text('管理目录'), findsOneWidget);
          expect(find.text('回忆'), findsNothing);
          expect(find.text('故乡'), findsOneWidget);
          expect(find.text('您还记得什么？'), findsOneWidget);
          await tester.tap(find.text('管理目录'));
          await tester.pumpAndSettle();
          expect(find.text('管理目录'), findsOneWidget);
          expect(find.byTooltip('添加目录'), findsOneWidget);
          await tester.tap(find.byType(BackButton));
          await flushEditor(tester);
          expect(find.text('第 1 章 · 故乡'), findsOneWidget);
        }
      },
      variant: TargetPlatformVariant({
        TargetPlatform.iOS,
        TargetPlatform.android,
      }),
    );
  }

  testWidgets(
    'editor keeps failed local edits, applies AI on confirmation and exports ordered photos',
    (tester) async {
      tester.view.physicalSize = const Size(430, 930);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      FlutterSecureStorage.setMockInitialValues({'ai_consent_v2_book': 'yes'});
      final dir = Directory.systemTemp.createTempSync('lifepages-editor-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final client = ManuscriptApi(hasBody: true);
      final recorder = Capture();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const photos = MethodChannel('life_pages/photos');
      const pdf = MethodChannel('life_pages/print');
      MethodCall? export;
      final sample = Uint8List.fromList(
        File('assets/memoir-cover.jpg').readAsBytesSync(),
      );
      messenger.setMockMethodCallHandler(photos, (_) async => sample);
      messenger.setMockMethodCallHandler(pdf, (call) async {
        export = call;
        return null;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(photos, null);
        messenger.setMockMethodCallHandler(pdf, null);
      });
      await tester.pumpWidget(
        MaterialApp(
          home: ChapterEditor(
            bookId: 'book',
            title: '我的回忆录',
            name: '讲述者',
            client: client,
            documentsDirectory: () async => dir,
            voiceCapture: recorder,
          ),
        ),
      );
      await flushEditor(tester);
      client.offline = true;
      await tester.enterText(find.byType(TextFormField), '亲手改的正文。');
      await tester.pump(const Duration(milliseconds: 750));
      await flushEditor(tester);
      expect(find.text('保存失败 · 重试'), findsOneWidget);
      expect(
        File('${dir.path}/manuscript-book-a.json').readAsStringSync(),
        contains('亲手改的正文。'),
      );
      client.offline = false;
      await tester.tap(find.text('保存失败 · 重试'));
      await flushEditor(tester);
      expect((client.rows['a']!['blocks'] as List).single['text'], '亲手改的正文。');

      Future<void> suggest({required bool apply}) async {
        await tester.tap(find.text('AI 文字'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).last, '更口语');
        await tester.pump();
        final gate = client.suggestionGate = Completer<void>();
        await tester.tap(find.text('生成修改稿'));
        await flushEditor(tester);
        expect(find.byType(LinearProgressIndicator), findsNothing);
        expect(
          find.descendant(
            of: find.widgetWithText(FilledButton, 'AI 文字'),
            matching: find.byType(CircularProgressIndicator),
          ),
          findsOneWidget,
        );
        gate.complete();
        await flushEditor(tester);
        expect(find.text('预览 AI 修改'), findsOneWidget);
        await tester.tap(find.text(apply ? '应用修改' : '取消').last);
        await flushEditor(tester);
      }

      await suggest(apply: false);
      expect((client.rows['a']!['blocks'] as List).single['text'], '亲手改的正文。');
      await suggest(apply: true);
      expect(client.suggestions.last['block_id'], 'old');
      expect((client.rows['a']!['blocks'] as List).single['text'], '更口语的正文。');

      final press = await tester.startGesture(
        tester.getCenter(find.byType(HoldToTalkButton)),
      );
      await tester.pump(const Duration(milliseconds: 650));
      await flushEditor(tester);
      expect(recorder.starts, 1);
      recorder.audio.add(List<int>.filled(3200, 1));
      await tester.pump();
      await press.up();
      await flushEditor(tester);
      expect(find.text('预览 AI 修改'), findsOneWidget);
      expect(client.suggestions.last['instruction'], '保留原话的意思');
      await tester.tap(find.text('取消').last);
      await flushEditor(tester);

      await tester.tap(find.text('插入图片'));
      await tester.pump(const Duration(milliseconds: 750));
      await flushEditor(tester);
      final up = find.byTooltip('上移').last;
      await tester.ensureVisible(up);
      await tester.tap(up);
      await tester.pump(const Duration(milliseconds: 750));
      await flushEditor(tester);
      final blocks = client.rows['a']!['blocks'] as List;
      expect(blocks.map((b) => b['kind']), ['image', 'text']);
      await tester.tap(find.text('预览'));
      await flushEditor(tester);
      expect(find.text('预览全书'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (widget) => widget is Image && widget.semanticLabel == '章节图片',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('导出 PDF'));
      await flushEditor(tester);
      expect(export?.method, 'printBook');
      final exported =
          ((export!.arguments as Map)['chapters'] as List).single as Map;
      expect((exported['blocks'] as List).first['image'], base64Encode(sample));
      expect((exported['blocks'] as List).last['text'], '更口语的正文。');
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}
