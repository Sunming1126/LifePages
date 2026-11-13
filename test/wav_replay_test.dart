import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:life_pages/wav.dart';

void main() {
  test('RTC recording replays without its original connection silence', () {
    const silenceBytes = 32000;
    final speech = Uint8List(16000);
    final samples = ByteData.sublistView(speech);
    for (var i = 0; i < speech.length; i += 2) {
      samples.setInt16(i, -1000, Endian.little);
    }
    final original = pcmToWav([...Uint8List(silenceBytes), ...speech]);
    final trimmed = trimWavLeadIn(original)!;
    const leadInBytes = 1280;
    final header = ByteData.sublistView(trimmed);
    expect(header.getUint32(4, Endian.little), trimmed.length - 8);
    expect(header.getUint32(40, Endian.little), speech.length + leadInBytes);
    expect(trimmed.sublist(44 + leadInBytes), speech);
  });

  test('silent or incomplete recordings are not reusable', () {
    final original = pcmToWav(Uint8List(32000));
    expect(trimWavLeadIn(original), isNull);
    expect(trimWavLeadIn(Uint8List.sublistView(original, 0, 100)), isNull);
  });
}
