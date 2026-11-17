import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_pages/account/profile_editor.dart';
import 'package:life_pages/chat_shell.dart';
import 'package:life_pages/main.dart' show Api;
import 'package:life_pages/my_page.dart' show PageBackground;
import 'package:life_pages/reading_preferences.dart';

class _UnavailableShelf extends Api {
  final requests = <String>[];

  @override
  Future<dynamic> call(
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    requests.add(path);
    throw Exception('离线');
  }
}

class _EmailApi extends Api {
  final requests = <String>[];

  @override
  Future<dynamic> call(
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    if (path == '/api/books') return {'books': [], 'trash': []};
    if (path == '/api/profile') return <String, dynamic>{};
    requests.add(path);
    expect(body?['email'], 'reader@example.test');
    if (path.endsWith('/send')) return {'retry_after': 60};
    if (path == '/api/auth/email-password/login') {
      expect(body?['password'], 'MyPass123');
    } else {
      expect(body?['code'], '123456');
    }
    return {'email': 'reader@example.test', 'token': 'test-session'};
  }
}

class _ProfileApi extends Api {
  final data = <String, dynamic>{
    'display_name': '小林',
    'avatar': null,
    'follow_ups': {'limit': 3, 'remaining': 2},
  };

  @override
  Future<dynamic> call(
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    if (path != '/api/profile') return {'books': [], 'trash': []};
    if (method == 'PATCH') data.addAll(body!);
    return Map<String, dynamic>.from(data);
  }
}

void main() {
  testWidgets('profile saves settings and large text magnifies navigation', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    largeTextMode.value = false;
    addTearDown(() => largeTextMode.value = false);
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const photos = MethodChannel('life_pages/photos');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(photos, (call) async {
      expect(call.method, 'pickAvatar');
      return Uint8List.fromList([255, 216, 255, 0, 255, 217]);
    });
    addTearDown(() => messenger.setMockMethodCallHandler(photos, null));
    final api = _ProfileApi();
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => ReadingScale(child: child!),
        home: ChatShell(client: api, accountProvider: 'google.com'),
      ),
    );
    await tester.pumpAndSettle();
    final nav = find.byType(OneSayChatNavigation);
    await tester.tap(find.descendant(of: nav, matching: find.text('我的')).first);
    await tester.pumpAndSettle();
    expect(find.text('小林'), findsOneWidget);
    expect(find.text('剩余 2 / 3 次'), findsOneWidget);
    await tester.tap(find.byType(ProfileAvatar));
    await tester.pumpAndSettle();
    expect(find.text('编辑资料'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('小林'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '小周');
    await tester.tap(find.text('选择头像'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(api.data['display_name'], '小周');
    expect(api.data['avatar'], isNotNull);
    expect(find.text('小周'), findsOneWidget);
    final normalHeight = tester.getRect(nav).height;
    await tester.ensureVisible(find.text('大字模式'));
    await tester.tap(find.text('大字模式'));
    await tester.pumpAndSettle();
    expect(tester.getRect(nav).height, closeTo(normalHeight * 1.2, 1));
    expect(largeTextMode.value, isTrue);
    await tester.ensureVisible(find.text('朗读声音'));
    await tester.tap(find.text('朗读声音'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('云舟'));
    await tester.pumpAndSettle();
    expect(await ReplyVoice.load(), ReplyVoice.yunzhou);
    expect(find.text('云舟 · 男声'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'settings returns to the app after email login switches the account',
    (tester) async {
      final api = _EmailApi();
      Map<String, dynamic>? session;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (_, update) => ChatShell(
              key: ValueKey(session?['token']),
              client: api,
              email: session?['email'] as String?,
              accountProvider: session == null ? null : 'email',
              onSignIn: (result) async => update(() => session = result),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final navigation = find.byType(OneSayChatNavigation);
      Future<void> openProfile() async {
        await tester.tap(
          find.descendant(of: navigation, matching: find.text('我的')).first,
        );
        await tester.pumpAndSettle();
      }

      await openProfile();
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, '设置'), findsOneWidget);
      await tester.tap(find.text('登录账号'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField).first,
        'reader@example.test',
      );
      await tester.tap(find.text('发送验证码'));
      await tester.pumpAndSettle();
      expect(find.text('验证码已发送，请查收邮箱。'), findsOneWidget);
      expect(session, isNull);
      await tester.enterText(find.byType(TextField).last, '123456');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('submit-email-auth')));
      await tester.pumpAndSettle();
      expect(session?['token'], 'test-session');
      expect(find.widgetWithText(AppBar, '设置'), findsNothing);
      await openProfile();
      expect(find.text('reader@example.test'), findsOneWidget);
      expect(api.requests, [
        '/api/auth/email-code/send',
        '/api/auth/email-code/login',
      ]);
    },
  );

  testWidgets('guest profile opens the login sheet and submits a password', (
    tester,
  ) async {
    final api = _EmailApi();
    Map<String, dynamic>? session;
    await tester.pumpWidget(
      MaterialApp(
        home: ChatShell(
          client: api,
          onSignIn: (result) async => session = result,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final nav = find.byType(OneSayChatNavigation);
    await tester.tap(find.descendant(of: nav, matching: find.text('我的')).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(ProfileAvatar));
    await tester.pumpAndSettle();
    expect(find.text('欢迎回来'), findsNothing);
    expect(find.text('编辑资料'), findsNothing);
    expect(find.text('邮箱登录'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('email-mode-password')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'reader@example.test');
    await tester.enterText(find.byType(TextField).last, 'MyPass123');
    await tester.tap(find.byKey(const ValueKey('submit-email-auth')));
    await tester.pumpAndSettle();
    expect(session?['token'], 'test-session');
    expect(api.requests, ['/api/auth/email-password/login']);
  });

  testWidgets('personal center opens offline and saves the shared background', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    final api = _UnavailableShelf();

    Future<void> openApp() async {
      await tester.pumpWidget(MaterialApp(home: ChatShell(client: api)));
      await tester.pumpAndSettle();
    }

    Future<void> openProfile() async {
      final navigation = find.byType(OneSayChatNavigation);
      await tester.tap(
        find.descendant(of: navigation, matching: find.text('我的')).first,
      );
      await tester.pumpAndSettle();
    }

    ImageProvider<Object>? pageImage() {
      final background = tester.widget<DecoratedBox>(
        find.byKey(const ValueKey('main-page-background')),
      );
      return (background.decoration as BoxDecoration).image?.image;
    }

    await openApp();
    expect(pageImage(), PageBackground.paperTone.image);
    await openProfile();
    expect(find.text('未登录'), findsOneWidget);
    expect(find.text('登录账号'), findsNothing);
    expect(find.text('免费版'), findsOneWidget);
    expect(find.text('记忆簿'), findsNothing);
    expect(find.text('每日 3 次'), findsOneWidget);
    expect(find.text('我的订单'), findsNothing);
    expect(api.requests, ['/api/books', '/api/profile']);

    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, '设置'), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-bottom-sheet')), findsNothing);
    expect(find.text('编辑资料'), findsNothing);
    await tester.tap(find.text('登录账号'));
    await tester.pumpAndSettle();
    expect(find.text('使用 Apple 登录'), findsOneWidget);
    expect(find.text('使用 Google 登录'), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '使用 Apple 登录'))
          .onPressed,
      isNull,
    );
    await tester.tap(find.byKey(const ValueKey('email-mode-password')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widgetList<TextField>(find.byType(TextField))
          .every((field) => field.enabled == false),
      isTrue,
    );
    expect(find.widgetWithText(FilledButton, '密码登录'), findsOneWidget);
    await tester.ensureVisible(find.text('没有账号？去注册'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('没有账号？去注册'));
    await tester.pumpAndSettle();
    expect(find.text('确认密码'), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, '设置'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(find.text('免费版'));
    await tester.pumpAndSettle();
    expect(find.text('月卡方案'), findsOneWidget);
    await tester.ensureVisible(find.text('年卡'));
    await tester.tap(find.text('年卡'));
    await tester.pumpAndSettle();
    expect(find.text('年卡方案'), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '恢复购买'))
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('继续免费记录'));
    await tester.pumpAndSettle();
    expect(api.requests, ['/api/books', '/api/profile']);

    await tester.ensureVisible(find.text('页面背景'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('页面背景'));
    await tester.pumpAndSettle();
    final sheet = find.byKey(const ValueKey('chat-bottom-sheet'));
    for (final background in PageBackground.values) {
      expect(
        find.descendant(of: sheet, matching: find.text(background.label)),
        findsOneWidget,
      );
    }
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    await tester.tap(find.text('青岚远山'));
    await tester.pumpAndSettle();
    expect(pageImage(), PageBackground.celadon.image);
    expect(find.text('青岚远山'), findsOneWidget);
    final navigation = find.byType(OneSayChatNavigation);
    await tester.tap(
      find.descendant(of: navigation, matching: find.text('书架')).first,
    );
    await tester.pumpAndSettle();
    expect(pageImage(), PageBackground.celadon.image);

    await tester.pumpWidget(const SizedBox.shrink());
    await openApp();
    expect(pageImage(), PageBackground.celadon.image);
    await openProfile();
    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('我的订单'));
    await tester.pumpAndSettle();
    expect(find.text('订单功能尚未开放。'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    FlutterSecureStorage.setMockInitialValues({'page_background': 'mist'});
    await openApp();
    expect(pageImage(), PageBackground.paperTone.image);
  });
}
