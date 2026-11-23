import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_pages/bookshelf.dart';
import 'package:life_pages/directory_page.dart';
import 'package:life_pages/main.dart' show Api;

class DirectoryApi extends Api {
  int revision = 0;
  final rows = <Map<String, dynamic>>[
    {'id': 'a', 'title': '故乡', 'question': '您小时候住在哪里？', 'number': 1},
    {'id': 'b', 'title': '本领', 'question': '您学会了哪门本领？', 'number': 2},
  ];
  final archived = <Map<String, dynamic>>[];
  final writes = <String>[];
  Map<String, dynamic> snapshot() =>
      jsonDecode(
            jsonEncode({
              'revision': revision,
              'topics': rows,
              'archived': archived,
            }),
          )
          as Map<String, dynamic>;
  @override
  Future<dynamic> call(
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    if (method == 'GET') return snapshot();
    expect(body!['revision'], revision);
    writes.add(path);
    if (path.endsWith('/items')) {
      rows.add({
        'id': body['id'],
        'title': body['title'],
        'question': body['question'],
        'number': rows.length + 1,
      });
    } else if (path.endsWith('/order')) {
      final ordered = [
        for (final id in body['ids']) rows.singleWhere((r) => r['id'] == id),
      ];
      rows
        ..clear()
        ..addAll(ordered);
    } else if (path.endsWith('/archive')) {
      final row = rows.singleWhere(
        (r) => r['id'] == Uri.parse(path).pathSegments[5],
      );
      rows.remove(row);
      archived.add(row);
    } else if (path.endsWith('/restore')) {
      final row = archived.singleWhere(
        (r) => r['id'] == Uri.parse(path).pathSegments[5],
      );
      archived.remove(row);
      rows.add(row);
    } else {
      final row = rows.singleWhere(
        (r) => r['id'] == Uri.parse(path).pathSegments.last,
      );
      row.addAll({'title': body['title'], 'question': body['question']});
    }
    revision++;
    return snapshot();
  }
}

void main() {
  for (final mode in ['目录模式', '陪伴模式']) {
    testWidgets(
      'new book chooses $mode before book details',
      (tester) async {
        Map<String, dynamic>? created;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  created = await newBookSheet(
                    context,
                    Api(),
                    allowModes: true,
                    interview: true,
                  );
                },
                child: const Text('建书'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('建书'));
        await tester.pumpAndSettle();
        expect(find.text('选择创作方式'), findsOneWidget);
        expect(find.byType(TextFormField), findsNothing);
        await tester.tap(find.text(mode));
        await tester.pumpAndSettle();
        expect(
          find.text('章节模板'),
          mode == '目录模式' ? findsOneWidget : findsNothing,
        );
        final fields = find.byType(TextFormField);
        await tester.enterText(fields.at(0), '虚构回忆录');
        await tester.enterText(fields.at(1), '测试');
        await tester.enterText(fields.at(2), '测试');
        await tester.tap(find.text('创建书籍'));
        await tester.pumpAndSettle();
        expect(
          created!['book_mode'],
          mode == '目录模式' ? 'directory' : 'companion',
        );
        expect(created!['interview'], mode == '目录模式' ? isNull : isTrue);
        if (mode == '陪伴模式') expect(created!['interview_version'], 2);
      },
      variant: TargetPlatformVariant({
        TargetPlatform.iOS,
        TargetPlatform.android,
      }),
    );
  }

  testWidgets(
    'directory edits questions reorders removes and restores stable items',
    (tester) async {
      final api = DirectoryApi();
      await tester.pumpWidget(
        MaterialApp(
          home: DirectoryPage(bookId: 'book', title: '虚构书', client: api),
        ),
      );
      await tester.pumpAndSettle();
      final list = tester.widget<ReorderableListView>(
        find.byType(ReorderableListView),
      );
      list.onReorderItem!(0, 1);
      await tester.pumpAndSettle();
      expect(api.rows.map((r) => r['id']), ['b', 'a']);
      await tester.tap(find.text('本领'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).at(0), '跟师傅学手艺');
      await tester.enterText(find.byType(TextFormField).at(1), '第一次练习时哪一步最难？');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(api.rows.first['question'], '第一次练习时哪一步最难？');
      expect(api.rows.first['id'], 'b');
      await tester.tap(find.byTooltip('移除目录').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('移除目录'));
      await tester.pumpAndSettle();
      expect(api.rows.length, 1);
      await tester.tap(find.text('已移除目录（1）'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('恢复'));
      await tester.pumpAndSettle();
      expect(api.rows.last['id'], 'b');
      expect(api.rows.last['question'], '第一次练习时哪一步最难？');
    },
    variant: TargetPlatformVariant({
      TargetPlatform.iOS,
      TargetPlatform.android,
    }),
  );
}
