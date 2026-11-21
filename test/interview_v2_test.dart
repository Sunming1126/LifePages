import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_pages/bookshelf.dart' show newBookSheet;
import 'package:life_pages/chat_shell.dart';
import 'package:life_pages/main.dart' show ApiFailure;

import 'bookshelf_test.dart' show ShelfApi, settleShelf;

class ThemeShelfApi extends ShelfApi {
  ThemeShelfApi() {
    books.single['interview_version'] = 2;
  }

  int revision = 5;
  bool failFirstRefresh = false;
  bool conflictFirstRefresh = false;
  final refreshBodies = <Map<String, dynamic>>[];
  final history = <Map<String, dynamic>>[
    {'id': 'old', 'role': 'assistant', 'text': '小时候常走哪条路？'},
    {'id': 'user', 'role': 'user', 'text': '我沿着桥边去赶集。'},
    {'id': 'latest', 'role': 'assistant', 'text': '那天在桥边发生了什么？'},
  ];

  Map<String, dynamic> get progress => {
    'version': 2,
    'question': 1,
    'total': 30,
    'revision': revision,
    'characters': 48,
    'minimum_characters': 301,
    'can_draft': false,
    'refresh_message_id': 'latest',
  };

  @override
  Future<dynamic> call(
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    if (method == 'GET' && path == '/api/books') {
      return {
        'books': books,
        'trash': [],
        'active_id': 'first',
        'interview_version': 1,
        'interview_versions': [1, 2],
      };
    }
    if (path == '/api/books/first/interview') {
      return {
        'active_id': 'conversation',
        'messages': [for (final row in history) Map<String, dynamic>.of(row)],
        'interview': progress,
      };
    }
    if (path == '/api/books/first/interview/messages/latest/refresh') {
      refreshBodies.add(Map<String, dynamic>.of(body!));
      expect(body['text'], '那天在桥边发生了什么？');
      expect(body['revision'], 5);
      if (refreshBodies.length == 1) {
        revision++;
        history.last['text'] = '故乡最热闹的地方，您记得在那里经历过什么？';
        if (conflictFirstRefresh) throw ApiFailure(409, '访谈已有新进度');
        if (failFirstRefresh) throw Exception('测试网络中断');
      }
      return {
        'id': 'latest',
        'text': history.last['text'],
        'interview': progress,
      };
    }
    return super.call(method, path, body);
  }
}

void main() {
  for (final mode in ['success', 'network', 'conflict']) {
    final failFirst = mode == 'network';
    testWidgets(
      'iOS hidden themes refresh only the unanswered question; mode=$mode',
      (tester) async {
        FlutterSecureStorage.setMockInitialValues({'ai_consent_device': 'yes'});
        final client = ThemeShelfApi()
          ..failFirstRefresh = failFirst
          ..conflictFirstRefresh = mode == 'conflict';
        final directory = Directory.systemTemp.createTempSync(
          'lifepages-theme-ui-',
        );
        addTearDown(() => directory.delete(recursive: true));
        await tester.pumpWidget(
          MaterialApp(
            home: ChatShell(
              client: client,
              documentsDirectory: () async => directory,
            ),
          ),
        );
        await settleShelf(tester);
        expect(find.text('访谈 1 / 30'), findsNothing);
        expect(find.text('故乡的生活地图'), findsNothing);
        expect(
          find.byKey(const ValueKey('assistant-history-button')),
          findsNothing,
        );
        expect(find.text('第 1 章 · 故乡的轮廓'), findsNothing);
        expect(find.text('这段已记录 48 字'), findsNothing);
        expect(find.text('下一题'), findsNothing);
        expect(find.text('跳过这题'), findsNothing);
        expect(
          find.byKey(const ValueKey('next-chapter-button')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('interview-progress-ring')),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('interview-progress-ring')));
        await tester.pumpAndSettle();
        expect(find.text('已记录 48 字'), findsOneWidget);
        await tester.tap(find.text('知道了'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('next-chapter-button')));
        await tester.pumpAndSettle();
        expect(find.text('提前进入下一章节？'), findsOneWidget);
        await tester.tap(find.text('继续这段'));
        await tester.pumpAndSettle();
        expect(find.byTooltip('换一个问题'), findsOneWidget);
        final titleY = tester.getTopLeft(find.text('我的回忆录').first).dy;
        await tester.tap(find.byTooltip('换一个问题'));
        await settleShelf(tester);
        if (failFirst) {
          expect(find.text('那天在桥边发生了什么？'), findsOneWidget);
          await tester.tap(find.byTooltip('换一个问题'));
          await settleShelf(tester);
          expect(client.refreshBodies[0], client.refreshBodies[1]);
        }
        expect(find.text('故乡最热闹的地方，您记得在那里经历过什么？'), findsOneWidget);
        expect(find.text('小时候常走哪条路？'), findsOneWidget);
        expect(tester.getTopLeft(find.text('我的回忆录').first).dy, titleY);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  }

  testWidgets(
    'new iOS books explicitly request v2 without changing old clients',
    (tester) async {
      Map<String, dynamic>? created;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              return Scaffold(
                body: TextButton(
                  onPressed: () async {
                    created = await newBookSheet(
                      context,
                      ShelfApi(),
                      interview: true,
                      interviewVersion: 2,
                    );
                  },
                  child: const Text('新书'),
                ),
              );
            },
          ),
        ),
      );
      await tester.tap(find.text('新书'));
      await tester.pumpAndSettle();
      final fields = find.byType(TextFormField);
      for (var i = 0; i < 3; i++) {
        await tester.enterText(fields.at(i), ['我的往事', '林老师', '测试作者'][i]);
      }
      await tester.tap(find.text('创建书籍'));
      await tester.pumpAndSettle();
      expect(created?['interview'], true);
      expect(created?['interview_version'], 2);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}
