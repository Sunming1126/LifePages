// Manual Android PDF acceptance fixture: no server access or real user books.
// flutter build apk --profile --target-platform android-arm64 -t tool/book_print_smoke.dart
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:life_pages/main.dart' show Api, BookPage;

const smokeVoiceUrl = 'https://example.org/lifepages/fictional-audio-check';
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final cover = await rootBundle.load('assets/memoir-cover.jpg');
  runApp(MaterialApp(home: BookPage(
    name: '虚构测试', title: '安卓成书二维码验收', bookId: 'pdf-smoke',
    client: _FixtureApi(base64Encode(cover.buffer.asUint8List())),
  )));
}

class _FixtureApi extends Api {
  _FixtureApi(this.photo);
  final String photo;
  @override
  Future<dynamic> call(String method, String path, [Map<String, dynamic>? body]) async {
    if (method == 'GET' && path.contains('/images/')) return {'data': photo};
    if (method == 'POST' && path.contains('/share')) {
      return {'url': smokeVoiceUrl, 'audio_count': 1};
    }
    if (method == 'GET' && path.startsWith('/api/books/pdf-smoke/chapters')) {
      final text = List.generate(100, (i) => '第${i + 1}段虚构经历：小时候，我们常在河边散步。这是用于分页和二维码验收的测试正文。').join('\n');
      return [
        {'id': 'pdf-smoke-audio', 'topic_id': 'audio', 'title': '含原声的长章节', 'topic_number': 1,
          'content': text, 'has_audio': true, 'audio_count': 1,
          'blocks': [{'kind': 'text', 'text': text}, {'kind': 'image', 'image_id': 'cover'}]},
        {'id': 'pdf-smoke-text', 'title': '无原声的章节', 'topic_number': 2,
          'content': '无原声章节不应出现空白或伪造的二维码。', 'has_audio': false},
      ];
    }
    throw StateError('Unexpected fixture request: $method $path');
  }
}
