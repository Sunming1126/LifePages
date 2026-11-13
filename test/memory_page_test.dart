import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_pages/main.dart' show Api;
import 'package:life_pages/memory_page.dart';

class MemoryApi extends Api {
  bool enabled = true;
  Map<String, dynamic>? edited;
  bool failEdit = true;

  @override
  Future<dynamic> call(
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    const root = '/api/people/p';
    if (path == '$root/memory-settings' && method == 'PATCH') {
      enabled = body!['enabled'] as bool;
      return {'enabled': enabled};
    }
    if (path == '$root/memories/1' && method == 'PATCH') {
      if (failEdit) throw Exception('暂时无法保存');
      edited = body;
      return body;
    }
    if (path == '$root/memories/1/source' && method == 'GET') {
      return {'text': '我小时候跟爷爷在海边修船。那天有风。'};
    }
    expect(path, '$root/memories');
    expect(method, 'GET');
    return {
      'enabled': enabled,
      'total': 2,
      'processed': 1,
      'items': [
        {
          'id': '1',
          'title': edited?['title'] ?? '儿时在海边',
          'content': edited?['content'] ?? '小时候在海边修船',
          'status': 'active',
          'quote': '我小时候跟爷爷在海边修船。',
          'revision': 1,
        },
      ],
      'next': null,
    };
  }
}

void main() {
  testWidgets('记忆簿查看原文、暂停和失败后保留更正', (tester) async {
    final api = MemoryApi();
    await tester.pumpWidget(
      MaterialApp(
        home: MemoryPage(client: api, personId: 'p', name: '张奶奶'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('已检查 1 / 2 条聊天消息'), findsOneWidget);

    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    expect(api.enabled, isFalse);
    expect(find.text('已暂停整理和引用，保留已有记忆'), findsOneWidget);

    await tester.tap(find.text('儿时在海边'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('查看完整原文'));
    await tester.pumpAndSettle();
    expect(find.text('我小时候跟爷爷在海边修船。那天有风。'), findsOneWidget);

    await tester.tap(find.text('更正'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).last, '小时候在海边补渔网');
    await tester.ensureVisible(find.text('保存更正'));
    await tester.tap(find.text('保存更正'));
    await tester.pumpAndSettle();
    expect(find.text('暂时无法保存'), findsOneWidget);
    expect(find.text('小时候在海边补渔网'), findsOneWidget);

    api.failEdit = false;
    await tester.tap(find.text('保存更正'));
    await tester.pumpAndSettle();
    expect(api.edited?['revision'], 1);
    expect(find.text('记忆簿'), findsOneWidget);
    expect(find.text('小时候在海边补渔网'), findsOneWidget);
  });
}
