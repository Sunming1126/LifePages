import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

final automaticReplyAudio = ValueNotifier<bool>(true);
final replyAudioConsentRevision = ValueNotifier<int>(0);
const _key = 'automatic_reply_audio';
Future<void> restoreAutomaticReplyAudio() async {
  try {
    automaticReplyAudio.value =
        await const FlutterSecureStorage().read(key: _key) != 'off';
  } catch (_) {}
}

Future<void> saveAutomaticReplyAudio(bool enabled) async {
  await const FlutterSecureStorage().write(
    key: _key,
    value: enabled ? 'on' : 'off',
  );
  automaticReplyAudio.value = enabled;
}
