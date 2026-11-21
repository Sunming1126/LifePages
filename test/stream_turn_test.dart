import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:life_pages/main.dart' show Api, ApiFailure;

class StreamClient extends http.BaseClient {
  StreamClient(this.events);
  final Stream<List<int>> events;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(events, 200);
}

void main() {
  test(
    'processing events extend the idle window without replacing reply text',
    () async {
      final data = StreamController<List<int>>();
      final api = Api(
        client: StreamClient(data.stream),
        turnIdleTimeout: const Duration(seconds: 2),
      );
      final result = api.streamTurn('/api/people/fictional/turns', {
        'request_id': 'synthetic',
      }, speak: false).toList();
      var ticks = 0;
      final timer = Timer.periodic(const Duration(milliseconds: 500), (timer) {
        data.add(utf8.encode('{"type":"processing"}\n'));
        if (++ticks == 6) {
          timer.cancel();
          data.add(utf8.encode('{"type":"done","text":"真实回复"}\n'));
          unawaited(data.close());
        }
      });
      try {
        final events = await result.timeout(const Duration(seconds: 8));
        expect(events.where((e) => e['type'] == 'processing').length, 6);
        expect(events.last['text'], '真实回复');
      } finally {
        timer.cancel();
        unawaited(data.close());
      }
    },
  );
  test('a silent broken stream shows a readable retry error', () async {
    final data = StreamController<List<int>>();
    final api = Api(
      client: StreamClient(data.stream),
      turnIdleTimeout: const Duration(milliseconds: 100),
    );
    try {
      await expectLater(
        api
            .streamTurn('/api/people/fictional/turns', {}, speak: false)
            .toList()
            .timeout(const Duration(seconds: 2)),
        throwsA(
          isA<ApiFailure>().having(
            (e) => e.message.toString(),
            'message',
            contains('内容已保留'),
          ),
        ),
      );
    } finally {
      unawaited(data.close());
    }
  });
}
