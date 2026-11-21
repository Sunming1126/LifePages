import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart';

enum SocialSignIn {
  apple('Apple'),
  google('Google');

  const SocialSignIn(this.label);
  final String label;

  static bool get available =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);

  Future<String?> idToken() async {
    FirebaseAuth? auth;
    GoogleSignIn? google;
    try {
      if (Firebase.apps.isEmpty) await Firebase.initializeApp();
      final firebase = auth = FirebaseAuth.instance;
      final UserCredential result;
      switch (this) {
        case SocialSignIn.apple:
          final provider = AppleAuthProvider()..addScope('email');
          result = await firebase.signInWithProvider(provider);
        case SocialSignIn.google:
          final signIn = google = GoogleSignIn();
          final account = await signIn.signIn();
          if (account == null) return null;
          final credentials = await account.authentication;
          result = await firebase.signInWithCredential(
            GoogleAuthProvider.credential(
              idToken: credentials.idToken,
              accessToken: credentials.accessToken,
            ),
          );
      }
      final token = await result.user?.getIdToken();
      if (token == null || token.isEmpty) {
        throw Exception('没有收到登录凭证，请重试。');
      }
      return token;
    } on FirebaseAuthException catch (error) {
      switch (error.code) {
        case 'canceled':
        case 'cancelled':
        case 'web-context-canceled':
        case 'web-context-cancelled':
          return null;
        case 'network-request-failed':
          throw Exception('登录网络连接失败，请重试。');
        case 'account-exists-with-different-credential':
          throw Exception('请先使用原登录方式进入 LifePages，再尝试绑定。');
        default:
          throw Exception('$label 登录暂时无法完成，请重试。');
      }
    } on MissingPluginException {
      throw Exception('当前 App 缺少登录组件，请重新编译安装后再试。');
    } on PlatformException catch (error) {
      if (error.code == 'channel-error') {
        throw Exception('当前 App 缺少登录组件，请重新编译安装后再试。');
      }
      if (error.code == 'sign_in_canceled') return null;
      if (error.code == 'network_error') {
        throw Exception('登录网络连接失败，请重试。');
      }
      throw Exception('$label 登录暂时无法完成，请重试。');
    } finally {
      // LifePages uses the exchanged server session for its account state.
      try {
        await auth?.signOut();
      } catch (_) {}
      try {
        await google?.signOut();
      } catch (_) {}
    }
  }
}
