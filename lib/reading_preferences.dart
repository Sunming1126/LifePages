import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const _storage = FlutterSecureStorage();
const _largeTextKey = 'large_text_mode';
final largeTextMode = ValueNotifier<bool>(false);
final replyVoiceRevision = ValueNotifier<int>(0);

Future<void> restoreReadingScale() async {
  try {
    largeTextMode.value = await _storage.read(key: _largeTextKey) == 'true';
  } catch (_) {
    // The normal scale remains available if storage cannot be opened.
  }
}

Future<void> saveReadingScale(bool enabled) async {
  await _storage.write(key: _largeTextKey, value: enabled.toString());
  largeTextMode.value = enabled;
}

/// Magnifies the Navigator and its overlays in the same coordinate system.
class ReadingScale extends StatelessWidget {
  const ReadingScale({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return ValueListenableBuilder(
      valueListenable: largeTextMode,
      child: child,
      builder: (context, enabled, child) {
        // Leave enough logical width for controls on compact phones.
        final scale = enabled
            ? (media.size.width / 300).clamp(1.0, 1.20).toDouble()
            : 1.0;
        final size = media.size / scale;
        return FittedBox(
          fit: BoxFit.contain,
          child: SizedBox.fromSize(
            size: size,
            child: MediaQuery(
              data: media.copyWith(
                size: size,
                devicePixelRatio: media.devicePixelRatio * scale,
                padding: media.padding / scale,
                viewPadding: media.viewPadding / scale,
                viewInsets: media.viewInsets / scale,
                systemGestureInsets: media.systemGestureInsets / scale,
              ),
              child: child!,
            ),
          ),
        );
      },
    );
  }
}

enum ReplyVoice {
  vivi('Vivi', '女声'),
  xiaohe('小何', '女声'),
  yunzhou('云舟', '男声'),
  xiaotian('小天', '男声');

  const ReplyVoice(this.label, this.gender);
  final String label;
  final String gender;
  static const _key = 'rtc_reply_voice';

  static Future<ReplyVoice> load() async {
    try {
      final id = await _storage.read(key: _key);
      return values.where((voice) => voice.name == id).firstOrNull ?? vivi;
    } catch (_) {
      return vivi;
    }
  }

  Future<void> save() async {
    await _storage.write(key: _key, value: name);
    replyVoiceRevision.value++;
  }
}
