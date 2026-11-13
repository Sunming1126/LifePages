import 'package:flutter_test/flutter_test.dart';
import 'package:life_pages/onesay_transcript.dart';

void main() {
  test(
    'OneSay replaces interim sentences and preserves repeated sentences',
    () {
      final s = SttTranscriptAssembler();
      expect(
        s.update(
          rawText: '小时',
          sentenceId: 0,
          sentenceEnd: false,
          heartbeat: false,
        ),
        '小时',
      );
      expect(
        s.update(
          rawText: '小时候',
          sentenceId: 0,
          sentenceEnd: true,
          heartbeat: false,
        ),
        '小时候',
      );
      expect(
        s.update(
          rawText: '小时候',
          sentenceId: 1,
          sentenceEnd: true,
          heartbeat: false,
        ),
        '小时候小时候',
      );
      expect(
        s.update(
          rawText: '忽略',
          sentenceId: 2,
          sentenceEnd: false,
          heartbeat: true,
        ),
        '小时候小时候',
      );
    },
  );
}
