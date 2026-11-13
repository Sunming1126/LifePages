import 'dart:typed_data';

/// Wrap the exact captured 16 kHz mono PCM16 samples in a playable WAV file.
Uint8List pcmToWav(List<int> pcm) {
  final head = ByteData(44);
  void ascii(int at, String text) {
    for (var i = 0; i < text.length; i++) {
      head.setUint8(at + i, text.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  head.setUint32(4, 36 + pcm.length, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  head.setUint32(16, 16, Endian.little);
  head.setUint16(20, 1, Endian.little);
  head.setUint16(22, 1, Endian.little);
  head.setUint32(24, 16000, Endian.little);
  head.setUint32(28, 32000, Endian.little);
  head.setUint16(32, 2, Endian.little);
  head.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  head.setUint32(40, pcm.length, Endian.little);
  return Uint8List.fromList([...head.buffer.asUint8List(), ...pcm]);
}

/// Keep a short lead-in before the first audible PCM frame in a recorded WAV.
/// Returns null for incomplete, unsupported, or silent recordings.
Uint8List? trimWavLeadIn(Uint8List wav) {
  if (wav.length < 44) return null;
  final data = ByteData.sublistView(wav);
  bool tag(int at, String value) {
    for (var i = 0; i < value.length; i++) {
      if (wav[at + i] != value.codeUnitAt(i)) return false;
    }
    return true;
  }

  if (!tag(0, 'RIFF') || !tag(8, 'WAVE')) return null;
  final end = data.getUint32(4, Endian.little) + 8;
  if (end > wav.length) return null;
  int? frameSize;
  int? sampleRate;
  for (var at = 12; at + 8 <= end;) {
    final length = data.getUint32(at + 4, Endian.little);
    final start = at + 8;
    if (start + length > end) return null;
    if (tag(at, 'fmt ')) {
      if (length < 16 ||
          data.getUint16(start, Endian.little) != 1 ||
          data.getUint16(start + 14, Endian.little) != 16) {
        return null;
      }
      sampleRate = data.getUint32(start + 4, Endian.little);
      frameSize = data.getUint16(start + 12, Endian.little);
      if (frameSize != 2 && frameSize != 4) return null;
    } else if (tag(at, 'data')) {
      if (frameSize == null ||
          sampleRate == null ||
          sampleRate < 8000 ||
          sampleRate > 192000 ||
          length % frameSize != 0) {
        return null;
      }
      for (var offset = 0; offset < length; offset += 2) {
        if (data.getInt16(start + offset, Endian.little).abs() < 96) continue;
        final firstFrame = offset ~/ frameSize;
        final leadFrames = sampleRate * 40 ~/ 1000;
        if (firstFrame <= leadFrames) return wav;
        final removed = (firstFrame - leadFrames) * frameSize;
        final trimmed = Uint8List(wav.length - removed)
          ..setRange(0, start, wav)
          ..setRange(start, wav.length - removed, wav, start + removed);
        ByteData.sublistView(trimmed)
          ..setUint32(4, end - 8 - removed, Endian.little)
          ..setUint32(at + 4, length - removed, Endian.little);
        return trimmed;
      }
      return null;
    }
    at = start + length + (length.isOdd ? 1 : 0);
  }
  return null;
}
