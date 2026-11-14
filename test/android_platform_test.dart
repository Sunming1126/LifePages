import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_pages/account/profile_editor.dart';
import 'package:life_pages/main.dart';

class _BookApi extends Api {
  @override
  Future<dynamic> call(
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async => [
    {'id': 'test', 'title': '测试章节', 'content': '保留正文阅读。'},
  ];
}

void main() {
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    group(platform.name, () {
      setUp(() {
        FlutterSecureStorage.setMockInitialValues({});
      });

      testWidgets(
        'profile keeps name editing and gates native photo selection',
        (tester) async {
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: ProfileEditor(
                  client: Api(),
                  profile: const AccountProfile(name: '安卓测试'),
                ),
              ),
            ),
          );
          expect(find.text('安卓测试'), findsOneWidget);
          expect(find.text('保存'), findsOneWidget);
          expect(
            find.text('选择头像'),
            platform == TargetPlatform.iOS ? findsOneWidget : findsNothing,
          );
        },
        variant: TargetPlatformVariant.only(platform),
      );

      testWidgets(
        'book remains readable and gates native export actions',
        (tester) async {
          await tester.pumpWidget(
            MaterialApp(
              home: BookPage(
                name: '测试',
                bookId: 'test',
                title: '测试书稿',
                client: _BookApi(),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(
            find.text('成书'),
            platform == TargetPlatform.iOS ? findsOneWidget : findsNothing,
          );
          expect(
            find.text('导出 PDF'),
            platform == TargetPlatform.iOS ? findsOneWidget : findsNothing,
          );
          expect(tester.takeException(), isNull);
        },
        variant: TargetPlatformVariant.only(platform),
      );
    });
  }
}
