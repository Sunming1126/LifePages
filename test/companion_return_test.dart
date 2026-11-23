import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_pages/chat_shell.dart';
import 'interview_v2_test.dart' show ThemeShelfApi;
import 'bookshelf_test.dart' show settleShelf;

class ReturnApi extends ThemeShelfApi {
  final returns = <Map<String, dynamic>>[];
  @override
  Future<dynamic> call(
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    if (path.endsWith('/interview/resume')) {
      returns.add(Map<String, dynamic>.from(body!));
      if (!history.any((m) => m['id'] == 'welcome')) {
        history.add({
          'id': 'welcome',
          'role': 'assistant',
          'text': '又见面啦。想继续刚才的聊天，还是换个新话题？',
        });
      }
      return {
        'message_id': 'welcome',
        'messages': List<Map<String, dynamic>>.from(history),
        'interview': progress,
      };
    }
    return super.call(method, path, body);
  }
}

void background(WidgetTester tester) {
  for (final state in [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
}

void foreground(WidgetTester tester) {
  if (tester.binding.lifecycleState == AppLifecycleState.resumed) {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    return;
  }
  for (final state in [
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
}

void main() {
  testWidgets(
    'one hour in background welcomes once; short return stays quiet',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({'ai_consent_v2_first': 'yes'});
      final dir = Directory.systemTemp.createTempSync('lifepages-return-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final api = ReturnApi();
      var now = DateTime.utc(2026, 11, 23, 9);
      await tester.pumpWidget(
        MaterialApp(
          home: FreeChatPage(
            personId: 'first',
            bookTitle: '虚构书',
            client: api,
            interview: true,
            companion: true,
            clock: () => now,
            documentsDirectory: () async => dir,
          ),
        ),
      );
      await settleShelf(tester);
      background(tester);
      await settleShelf(tester);
      now = now.add(const Duration(minutes: 59));
      foreground(tester);
      await settleShelf(tester);
      expect(api.returns, isEmpty);
      background(tester);
      await settleShelf(tester);
      now = now.add(const Duration(hours: 1));
      foreground(tester);
      await settleShelf(tester);
      expect(api.returns.length, 1);
      expect(api.returns.single['last_user_id'], 'user');
      expect(find.textContaining('又见面啦'), findsOneWidget);
      foreground(tester);
      await settleShelf(tester);
      expect(api.returns.length, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: TargetPlatformVariant({
      TargetPlatform.iOS,
      TargetPlatform.android,
    }),
  );

  testWidgets('cold restart restores the persisted return marker', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('lifepages-return-cold-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final api = ReturnApi();
    final now = DateTime.utc(2026, 11, 23, 11);
    final key =
        'companion-away-${sha256.convert(utf8.encode('${api.base}\u0000${api.token}'))}';
    final stamp = jsonEncode({
      'book_id': 'first',
      'left_at':
          now.subtract(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000,
      'request_id': 'a' * 32,
      'last_user_id': 'user',
    });
    FlutterSecureStorage.setMockInitialValues({
      'ai_consent_v2_first': 'yes',
      key: stamp,
    });
    await tester.pumpWidget(
      MaterialApp(
        home: FreeChatPage(
          personId: 'first',
          bookTitle: '虚构书',
          client: api,
          interview: true,
          companion: true,
          clock: () => now,
          documentsDirectory: () async => dir,
        ),
      ),
    );
    await settleShelf(tester);
    expect(api.returns.length, 1);
    expect(api.returns.single['request_id'], 'a' * 32);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'directory mode restores its selector and never posts companion returns',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      final dir = Directory.systemTemp.createTempSync(
        'lifepages-directory-chat-',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      final api = ReturnApi();
      var now = DateTime.utc(2026, 11, 23, 9);
      await tester.pumpWidget(
        MaterialApp(
          home: FreeChatPage(
            personId: 'first',
            bookTitle: '虚构书',
            client: api,
            clock: () => now,
            documentsDirectory: () async => dir,
          ),
        ),
      );
      await settleShelf(tester);
      expect(
        find.byKey(const ValueKey('chapter-directory-button')),
        findsOneWidget,
      );
      background(tester);
      await settleShelf(tester);
      now = now.add(const Duration(hours: 2));
      foreground(tester);
      await settleShelf(tester);
      expect(api.returns, isEmpty);
      await tester.tap(find.byKey(const ValueKey('chapter-directory-button')));
      await tester.pumpAndSettle();
      expect(find.text('章节目录'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: TargetPlatformVariant({
      TargetPlatform.iOS,
      TargetPlatform.android,
    }),
  );
}
