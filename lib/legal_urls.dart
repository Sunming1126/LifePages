import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

abstract final class AppLegalUrls {
  static const _base = 'https://onesay.top/lifepages';
  static const privacy = '$_base/privacy';
  static const support = '$_base/support';
  static const permissions = '$_base/permissions';
  static const terms =
      'https://www.apple.com/legal/internet-services/itunes/dev/stdeula/';

  static Future<void> open(BuildContext context, String url) async {
    try {
      if (await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      )) {
        return;
      }
    } catch (_) {
      // Show the same feedback if the system has no available handler.
    }
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('暂时无法打开链接，请稍后重试')));
    }
  }
}
