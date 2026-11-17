import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:life_pages/main.dart' show Api, ApiFailure;
import 'package:life_pages/offline_cache.dart';
import 'package:life_pages/voice_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late ReadCache cache;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('lifepages-cache-test');
    cache = ReadCache(() async => dir);
  });
  tearDown(() async => dir.delete(recursive: true));

  test(
    'online snapshot survives offline and isolates accounts and servers',
    () async {
      var online = true;
      final api = Api(
        cache: cache,
        offlineReads: true,
        client: MockClient((_) async {
          if (!online) throw const SocketException('offline');
          return http.Response('{"books":[{"id":"fictional"}]}', 200);
        }),
      )..token = 'test-account-a';
      final saved = await api.call('GET', '/api/books');
      online = false;
      expect(await api.call('GET', '/api/books'), saved);
      api.token = 'test-account-b';
      expect(api.call('GET', '/api/books'), throwsA(isA<SocketException>()));
      api.token = 'test-account-a';
      api.base = 'https://other.example';
      expect(api.call('GET', '/api/books'), throwsA(isA<SocketException>()));
      final files = await dir
          .list(recursive: true)
          .where((f) => f is File)
          .toList();
      expect(files.every((f) => !f.path.contains('test-account')), isTrue);
    },
  );

  test(
    'cached content never conceals revoked authentication or failed edits',
    () async {
      var status = 200;
      final api = Api(
        cache: cache,
        offlineReads: true,
        client: MockClient((_) async {
          return http.Response(
            status == 200 ? '{"books":[]}' : '{"detail":"unauthorized"}',
            status,
          );
        }),
      )..token = 'test-account';
      await api.call('GET', '/api/books');
      status = 401;
      expect(api.call('GET', '/api/books'), throwsA(isA<ApiFailure>()));
      expect(api.call('PATCH', '/api/books', {}), throwsA(isA<ApiFailure>()));
    },
  );

  test('partial cache corruption is ignored', () async {
    await cache.write('scope', '/api/books', {'books': []});
    final file = await dir.list(recursive: true).where((f) => f is File).first;
    await File(file.path).writeAsString('{truncated');
    expect(await cache.read('scope', '/api/books'), isNull);
  });

  test(
    'automatic reply audio defaults on and remembers an explicit opt out',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      automaticReplyAudio.value = false;
      await restoreAutomaticReplyAudio();
      expect(automaticReplyAudio.value, isTrue);
      await saveAutomaticReplyAudio(false);
      automaticReplyAudio.value = true;
      await restoreAutomaticReplyAudio();
      expect(automaticReplyAudio.value, isFalse);
      await saveAutomaticReplyAudio(true);
    },
  );
}
