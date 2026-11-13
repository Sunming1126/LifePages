import 'package:flutter_test/flutter_test.dart';
import 'package:life_pages/account/social_sign_in.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final provider in SocialSignIn.values) {
    test(
      '${provider.label} explains an unavailable native login component',
      () async {
        await expectLater(
          provider.idToken(),
          throwsA(
            isA<Exception>().having(
              (error) => error.toString(),
              'message',
              contains('请重新编译安装后再试'),
            ),
          ),
        );
      },
    );
  }
}
