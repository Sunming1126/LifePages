import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_pages/chat_shell.dart';
import 'package:life_pages/chapter_editor.dart';
import 'package:life_pages/bookshelf.dart' show newBookSheet;
import 'package:life_pages/main.dart' show Api, BookPage, paper, secure;
import 'package:life_pages/book_cover.dart';

class ShelfApi extends Api {
  final books = <Map<String, dynamic>>[
    {
      'id': 'first',
      'title': '我的回忆录',
      'name': '您',
      'author': '我',
      'chapter_count': 0,
      'topic_count': 26,
      'completed_topic_count': 0,
      'character_count': 0,
    },
  ];
  final trash = <Map<String, dynamic>>[];
  String? active = 'first';
  Completer<List<Map<String, dynamic>>>? previewResponse;
  Completer<void>? editorGate;
  int editorRequests = 0;
  int editorRevision = 0;
  String editorText = '这是已保存的正文。';
  final previewRows = <Map<String, dynamic>>[];
  final compiledTopics = <String>[];
  final exportShares = <String>[];
  bool rejectRename = false;

  @override
  Future<dynamic> call(
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    final uri = Uri.parse(path);
    final parts = uri.pathSegments;
    if (path == '/api/books/templates') {
      return [
        {
          'id': 'family',
          'name': '家庭故事',
          'chapters': ['家族来历', '长辈故事'],
        },
      ];
    }
    if (uri.path == '/api/books' && method == 'POST') {
      books.add({
        ...body!,
        'chapter_count': 0,
        'topic_count': 26,
        'completed_topic_count': 0,
        'character_count': 0,
      });
      active = body['id'] as String;
    }
    if (parts.length == 3 && parts[1] == 'books' && method == 'PATCH') {
      if (rejectRename) throw Exception('保存失败，请重试');
      books.firstWhere((row) => row['id'] == parts[2]).addAll(body!);
      return {'books': books, 'trash': trash, 'active_id': active};
    }
    if (uri.path.endsWith('/chapters')) {
      return previewResponse?.future ?? previewRows;
    }
    if (uri.path.endsWith('/compile')) {
      final topic = parts[4];
      compiledTopics.add(topic);
      final entry = previewRows.singleWhere((row) => row['topic_id'] == topic);
      entry.addAll({'id': 'compiled', 'content': 'AI 整理后的正文。'});
      return {'id': 'compiled'};
    }
    if (uri.path.endsWith('/share')) {
      exportShares.add(path);
      return {'url': 'https://test/listen/exported', 'audio_count': 2};
    }
    if (parts.length == 3 && parts[1] == 'books' && method == 'DELETE') {
      final book = books.firstWhere((row) => row['id'] == parts[2]);
      books.remove(book);
      trash.add(book);
      if (active == parts[2]) active = books.firstOrNull?['id'] as String?;
    }
    if (uri.path.endsWith('/restore')) {
      final book = trash.firstWhere((row) => row['id'] == parts[2]);
      trash.remove(book);
      books.add(book);
    }
    if (uri.path == '/api/books' ||
        method == 'DELETE' ||
        uri.path.endsWith('/restore')) {
      return {'books': books, 'trash': trash, 'active_id': active};
    }
    if (uri.path.endsWith('/manuscript')) {
      return {
        'id': parts[4],
        'title': '故乡的轮廓',
        'theme': '故土与根脉',
        'question': '您记忆中的故乡是什么样的？',
        'number': 1,
        'revision': 0,
        'blocks': [],
      };
    }
    if (uri.path.endsWith('/topics')) {
      final id = '${parts[2]}-1';
      final entry = {
        'id': id,
        'title': '故乡的轮廓',
        'theme': '故土与根脉',
        'number': 1,
        'character_count': 0,
      };
      final editor = uri.queryParameters['editor'] == 'true';
      if (editor) {
        editorRequests++;
        await editorGate?.future;
      }
      return {
        'active_id': id,
        'topics': [entry],
        if (editor)
          'manuscript': {
            ...entry,
            'question': '您记忆中的故乡是什么样的？',
            'revision': editorRevision,
            'blocks': [
              {'id': 'block-$id', 'kind': 'text', 'text': editorText},
            ],
          },
      };
    }
    if (uri.path.endsWith('/active')) {
      active = parts[2];
      return {'active_id': parts[4]};
    }
    if (uri.path.endsWith('/memoir')) {
      return {
        'person': books.firstWhere((row) => row['id'] == parts[2]),
        'chapters': [],
        'people': books,
        'stats': {'stories': 0, 'recordings': 0, 'chapters': 0},
      };
    }
    if (uri.queryParameters.containsKey('session_id')) {
      return {
        'messages': [
          {'role': 'assistant', 'text': '您记忆中的故乡是什么样的？'},
        ],
      };
    }
    throw StateError('Unexpected $method $path');
  }
}

Future<void> settleShelf(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
  }
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('new book previews a template before choosing it', (
    tester,
  ) async {
    final client = ShelfApi();
    Map<String, dynamic>? submitted;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  submitted = await newBookSheet(context, client),
              child: const Text('打开新建'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开新建'));
    await tester.pumpAndSettle();
    expect(find.text('完整人生（26 章）'), findsOneWidget);
    await tester.tap(find.text('章节模板'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('家庭故事（2 章）'));
    await tester.pumpAndSettle();
    expect(find.text('第 1 章 · 家族来历'), findsOneWidget);
    await tester.tap(find.text('使用这套模板'));
    await tester.pumpAndSettle();
    expect(find.text('家庭故事（2 章）'), findsOneWidget);
    for (final (index, text) in ['家族回忆', '奶奶', '小林'].indexed) {
      await tester.enterText(find.byType(TextFormField).at(index), text);
    }
    await tester.tap(find.text('创建书籍'));
    await tester.pumpAndSettle();
    expect(submitted?['template_id'], 'family');
  });

  testWidgets('book preview shows raw stories and opens the finished PDF', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({'ai_consent_v2_first': 'yes'});
    final client = ShelfApi();
    client.previewRows.addAll([
      {
        'id': 'topic-1',
        'topic_id': 'topic-1',
        'topic_number': 1,
        'title': '聊过的章节',
        'content': '',
        'has_audio': true,
        'audio_count': 2,
        'narrations': [
          {'id': 'm1', 'text': '我小时候住在河边。', 'has_audio': true},
        ],
      },
      {
        'id': 'existing',
        'topic_number': 2,
        'title': '已成稿章节',
        'content': '我手工编辑过的正文。',
        'has_audio': false,
      },
    ]);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const printChannel = MethodChannel('life_pages/print');
    MethodCall? export;
    messenger.setMockMethodCallHandler(printChannel, (call) async {
      export = call;
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(printChannel, null));
    await tester.pumpWidget(
      MaterialApp(
        home: BookPage(
          name: '您',
          bookId: 'first',
          title: '我的回忆录',
          client: client,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('第 1 章 · 已讲述，待整理'), findsOneWidget);
    expect(find.text('我小时候住在河边。'), findsOneWidget);
    expect(find.text('播放原声'), findsOneWidget);
    await tester.tap(find.text('成书'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始成书'));
    await tester.pumpAndSettle();
    expect(client.compiledTopics, ['topic-1']);
    expect(client.exportShares, [
      '/api/chapters/compiled/share?include_topic_audio=true',
    ]);
    expect(export?.method, 'previewBook');
    final chapters = (export!.arguments as Map)['chapters'] as List;
    expect(chapters.map((chapter) => chapter['content']), [
      'AI 整理后的正文。',
      '我手工编辑过的正文。',
    ]);
    expect(chapters.map((chapter) => chapter['url']), [
      'https://test/listen/exported',
      '',
    ]);
  });

  testWidgets('shelf creates, switches, trashes and restores books', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    final dir = Directory.systemTemp.createTempSync('lifepages-shelf-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final client = ShelfApi();
    await tester.pumpWidget(
      MaterialApp(
        home: ChatShell(client: client, documentsDirectory: () async => dir),
      ),
    );
    await settleShelf(tester);
    expect(find.text('我的回忆录'), findsOneWidget);
    expect(find.text('您记忆中的故乡是什么样的？'), findsOneWidget);
    final nav = find.byType(OneSayChatNavigation);
    final shelfTab = find.descendant(of: nav, matching: find.text('书架'));
    await tester.tap(shelfTab.first);
    await settleShelf(tester);
    final recentlyDeleted = find.text('最近删除').hitTestable();
    await tester.tap(recentlyDeleted);
    await tester.pumpAndSettle();
    expect(find.text('还没有删除的书籍'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建一本书'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('创建书籍'));
    await tester.pumpAndSettle();
    expect(find.text('请填写作者'), findsOneWidget);
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), '奶奶的岁月');
    await tester.enterText(fields.at(1), '奶奶');
    await tester.enterText(fields.at(2), '小林');
    await tester.tap(find.text('创建书籍'));
    await settleShelf(tester);
    expect(find.text('奶奶的岁月'), findsOneWidget);

    final settings = find.byKey(const ValueKey('assistant-settings-button'));
    final voiceMenu = find.text('AI 播报音色');
    final vivi = find.byKey(const ValueKey('reply-voice-vivi'));
    final yunzhou = find.byKey(const ValueKey('reply-voice-yunzhou'));
    await tester.tap(settings);
    await tester.pumpAndSettle();
    expect(find.text('切换书籍'), findsOneWidget);
    expect(find.text('讲述者设置'), findsOneWidget);
    expect(vivi, findsNothing);
    expect(yunzhou, findsNothing);
    await tester.tap(voiceMenu);
    await tester.pumpAndSettle();
    expect(find.text('切换书籍'), findsNothing);
    expect(find.text('女声'), findsNWidgets(2));
    expect(find.text('男声'), findsNWidgets(2));
    expect(tester.widget<ListTile>(vivi).selected, isTrue);
    await tester.tap(yunzhou);
    await tester.pumpAndSettle();
    expect(await secure.read(key: 'rtc_reply_voice'), 'yunzhou');
    await tester.tap(settings);
    await tester.pumpAndSettle();
    expect(find.text('云舟'), findsOneWidget);
    expect(yunzhou, findsNothing);
    await tester.tap(voiceMenu);
    await tester.pumpAndSettle();
    expect(tester.widget<ListTile>(yunzhou).selected, isTrue);
    await tester.tap(find.byTooltip('返回切换书籍'));
    await tester.pumpAndSettle();
    expect(find.text('切换书籍'), findsOneWidget);
    await tester.tap(find.text('我的回忆录'));
    await settleShelf(tester);
    expect(client.active, 'first');
    await tester.tap(shelfTab.first);
    await settleShelf(tester);
    final tile = find.ancestor(
      of: find.text('奶奶的岁月').last,
      matching: find.byType(Card),
    );
    await tester.tap(
      find.descendant(of: tile, matching: find.byTooltip('书籍选项')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除书籍'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('移入最近删除'));
    await settleShelf(tester);
    expect(find.text('奶奶的岁月'), findsNothing);
    await tester.tap(recentlyDeleted);
    await tester.pumpAndSettle();
    expect(find.text('奶奶的岁月'), findsOneWidget);
    await tester.tap(find.text('恢复'));
    await settleShelf(tester);
    expect(find.text('0/26 章 · 0 字'), findsNWidgets(2));
  });

  testWidgets(
    'cold entry opens immediately and reentry shows cached text while offline',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      final dir = Directory.systemTemp.createTempSync('lifepages-prefetch-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final gate = Completer<void>();
      final client = ShelfApi()..editorGate = gate;
      await tester.pumpWidget(
        MaterialApp(
          home: ChatShell(client: client, documentsDirectory: () async => dir),
        ),
      );
      await settleShelf(tester);
      expect(client.editorRequests, 1);
      final nav = find.byType(OneSayChatNavigation);
      await tester.tap(
        find.descendant(of: nav, matching: find.text('书架')).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(BookCover));
      await tester.pumpAndSettle();
      final editor = find.byType(ChapterEditor);
      expect(editor, findsOneWidget);
      expect(
        find.descendant(
          of: editor,
          matching: find.byType(CircularProgressIndicator),
        ),
        findsNothing,
      );
      expect(client.editorRequests, 1);
      gate.complete();
      await settleShelf(tester);
      expect(find.text('这是已保存的正文。'), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      final retry = Completer<void>();
      client.editorGate = retry;
      await tester.tap(find.byType(BookCover));
      await tester.pumpAndSettle();
      expect(find.text('这是已保存的正文。'), findsOneWidget);
      expect(client.editorRequests, 2);
      retry.completeError(Exception('临时离线'));
      await tester.pumpAndSettle();
      expect(find.text('这是已保存的正文。'), findsOneWidget);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      final delayed = Completer<void>();
      client.editorGate = delayed;
      await tester.tap(find.byType(BookCover));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), '刚刚写下的新内容。');
      client
        ..editorRevision = 1
        ..editorText = '另一台设备写下的内容。';
      delayed.complete();
      await settleShelf(tester);
      expect(find.text('刚刚写下的新内容。'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('shelf opens editor directly, with preview in the book menu', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({
      'share_c1': 'https://test/listen/one',
    });
    final dir = Directory.systemTemp.createTempSync('lifepages-preview-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final client = ShelfApi()
      ..previewResponse = Completer<List<Map<String, dynamic>>>();
    client.books.add({
      ...client.books.first,
      'id': 'other',
      'title': '另一本',
      'author': '讲述人',
    });
    await tester.pumpWidget(
      MaterialApp(
        home: ChatShell(client: client, documentsDirectory: () async => dir),
      ),
    );
    await settleShelf(tester);
    final nav = find.byType(OneSayChatNavigation);
    await tester.tap(find.descendant(of: nav, matching: find.text('书架')).first);
    await tester.pumpAndSettle();
    final otherCard = find.byType(Card).last;
    await tester.tap(
      find.descendant(of: otherCard, matching: find.byType(BookCover)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await settleShelf(tester);
    expect(find.widgetWithText(AppBar, '另一本'), findsOneWidget);
    expect(find.byType(ChapterEditor), findsOneWidget);
    final header = tester.widget<AppBar>(find.byType(AppBar));
    expect(header.backgroundColor, paper);
    expect(header.scrolledUnderElevation, 0);
    expect(find.byType(BookPage), findsNothing);
    expect(find.text('第 1 章 · 故乡的轮廓'), findsOneWidget);
    expect(client.active, 'first');
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(Card).last,
        matching: find.byTooltip('书籍选项'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('预览全书'));

    client.previewResponse!.complete([
      {
        'id': 'c1',
        'title': '第一篇',
        'topic_number': 1,
        'content': '关于从前的一段正文。',
        'has_audio': true,
      },
      {'id': 'blank', 'title': '空标题', 'topic_number': 2, 'content': '  '},
      {'id': 'c3', 'title': '第三篇', 'topic_number': 3, 'content': '这是另一段正文。'},
    ]);
    await tester.pumpAndSettle();
    expect(find.byType(BookPage), findsOneWidget);
    final scroll = find.byType(SingleChildScrollView);
    await tester.scrollUntilVisible(
      find.text('目录'),
      140,
      scrollable: find
          .descendant(of: scroll, matching: find.byType(Scrollable))
          .first,
    );
    expect(find.text('空标题'), findsNothing);
    await tester.ensureVisible(find.widgetWithText(ListTile, '第三篇'));
    await tester.tap(find.widgetWithText(ListTile, '第三篇'));
    await tester.pumpAndSettle();
    expect(find.textContaining('这是另一段正文。').hitTestable(), findsOneWidget);
    expect(find.text('导出 PDF'), findsOneWidget);
    await tester.ensureVisible(find.text('扫码聆听原声'));
    expect(find.text('扫码聆听原声').hitTestable(), findsOneWidget);
    const printChannel = MethodChannel('life_pages/print');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    Map<Object?, Object?>? exported;
    messenger.setMockMethodCallHandler(printChannel, (call) async {
      expect(call.method, 'printBook');
      exported = call.arguments as Map;
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(printChannel, null));
    await tester.tap(find.text('导出 PDF'));
    await tester.pumpAndSettle();
    final exportedChapters = exported!['chapters'] as List;
    expect(exported!['title'], '另一本');
    expect(exportedChapters.map((chapter) => chapter['title']), ['第一篇', '第三篇']);
    expect(exportedChapters.first['url'], 'https://test/listen/one');
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(
      find.descendant(
        of: find.byType(Card).last,
        matching: find.byTooltip('书籍选项'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('修改书名和作者'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextFormField, '讲述人'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField).first, '新书名');
    client.rejectRename = true;
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('保存失败，请重试'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, '新书名'), findsOneWidget);
    client.rejectRename = false;
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextFormField, '新书名'), findsNothing);
    expect(client.books.last['title'], '新书名');
    expect(client.active, 'first');

    client.previewResponse = null;
    await tester.tap(
      find.descendant(
        of: find.byType(Card).last,
        matching: find.byType(BookCover),
      ),
    );
    await settleShelf(tester);
    expect(find.byType(ChapterEditor), findsOneWidget);
    expect(find.widgetWithText(AppBar, '新书名'), findsOneWidget);
  });
}
