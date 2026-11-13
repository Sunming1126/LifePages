import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_pages/wav.dart';

void main() {
  test('WAV retains the original PCM and has the supported speech format', () {
    final pcm = <int>[0, 0, 128, 127, 0, 128];
    final wav = pcmToWav(pcm);
    final header = ByteData.sublistView(wav);
    expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
    expect(header.getUint32(4, Endian.little), 36 + pcm.length);
    expect(header.getUint16(22, Endian.little), 1);
    expect(header.getUint32(24, Endian.little), 16000);
    expect(header.getUint16(34, Endian.little), 16);
    expect(header.getUint32(40, Endian.little), pcm.length);
    expect(wav.sublist(44), pcm);
  });
}
