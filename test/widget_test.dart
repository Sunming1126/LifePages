import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_pages/main.dart';

void main() {
  test('error messages omit the generic exception prefix', () {
    expect(errorText(Exception('暂时不可用')), '暂时不可用');
  });

  testWidgets(
    'AI consent applies to new books and revocation overrides legacy consent',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({
        aiConsentKey('legacy'): 'yes',
      });
      bool? allowed;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async =>
                    allowed = await consent(context, 'first-new-book'),
                child: const Text('使用 AI'),
              ),
            ),
          ),
        ),
      );
      expect(await hasAiConsent('legacy'), isTrue);
      expect(await hasAiConsent('first-new-book'), isFalse);
      await tester.tap(find.text('使用 AI'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('同意并使用'));
      await tester.pumpAndSettle();
      expect(allowed, isTrue);
      expect(await hasAiConsent('second-new-book'), isTrue);
      expect(await hasReplyConsent('second-new-book'), isFalse);
      await secure.write(key: localAiConsentKey, value: 'no');
      expect(await hasAiConsent('legacy'), isFalse);
    },
  );
}
