// OneSay's realtime sentence revision assembler.
import 'dart:collection';

class SttTranscriptAssembler {
  final SplayTreeMap<int, String> _finalizedSentences =
      SplayTreeMap<int, String>();
  final SplayTreeMap<int, String> _inProgressSentences =
      SplayTreeMap<int, String>();
  String _untaggedCommittedText = '';
  String _untaggedCurrentText = '';
  String _text = '';

  String get text => _text;

  String update({
    required String rawText,
    required int? sentenceId,
    required bool sentenceEnd,
    required bool heartbeat,
  }) {
    if (heartbeat) return _text;

    final nextText = rawText.trim();
    if (nextText.isEmpty) return _text;

    if (sentenceId != null) {
      // `sentence.text` is the current revision of this one sentence. Only a
      // sentence_end event solidifies it; all preceding events replace the
      // in-progress version for the same id.
      if (sentenceEnd) {
        _finalizedSentences[sentenceId] = nextText;
        _inProgressSentences.remove(sentenceId);
      } else if (!_finalizedSentences.containsKey(sentenceId)) {
        _inProgressSentences[sentenceId] = nextText;
      }
    } else {
      // A sentence id is part of the normal Fun-ASR contract. Keep a small,
      // replacement-only fallback for malformed/legacy frames rather than
      // guessing whether two arbitrary strings should be concatenated.
      _untaggedCurrentText = nextText;
      if (sentenceEnd) {
        _untaggedCommittedText = _joinTranscript(
          _untaggedCommittedText,
          _untaggedCurrentText,
        );
        _untaggedCurrentText = '';
      }
    }

    _text = _normalizeFillers(_combinedTranscript).trim();
    return _text;
  }

  String get _combinedTranscript {
    final sentences = SplayTreeMap<int, String>.from(_inProgressSentences)
      ..addAll(_finalizedSentences);
    var combined = '';
    for (final sentence in sentences.values) {
      combined = _joinTranscript(combined, sentence);
    }
    combined = _joinTranscript(combined, _untaggedCommittedText);
    return _joinTranscript(combined, _untaggedCurrentText);
  }

  static String _joinTranscript(String first, String second) {
    final left = first.trim();
    final right = second.trim();
    if (left.isEmpty) return right;
    if (right.isEmpty) return left;

    if (_shouldInsertJoinSpace(left, right)) {
      return '$left $right';
    }
    return '$left$right';
  }

  static bool _shouldInsertJoinSpace(String left, String right) {
    final leftCode = left.runes.last;
    final rightCode = right.runes.first;
    if (_isCjkCode(leftCode) || _isCjkCode(rightCode)) return false;
    if (_isLeadingPunctuation(rightCode) || _isTrailingPunctuation(leftCode)) {
      return false;
    }
    return true;
  }

  static bool _isCjkCode(int code) =>
      (code >= 0x3400 && code <= 0x9FFF) || (code >= 0xF900 && code <= 0xFAFF);

  static bool _isLeadingPunctuation(int code) {
    const chars = '，。！？；：、,.!?;:)]}）】》」』';
    return chars.contains(String.fromCharCode(code));
  }

  static bool _isTrailingPunctuation(int code) {
    const chars = '([{（【《「『';
    return chars.contains(String.fromCharCode(code));
  }

  /// Retains the existing cleanup for drawn-out filler words. It intentionally
  /// does not deduplicate whole sentences, because equal sentence ids—not text
  /// similarity—are the reliable signal for ASR revisions.
  static final _fillerRepetition = RegExp(
    r'(嗯|呃|额|啊|哈|哦|噢|喔|唉|哎|诶|嘛|呢|呀|哟|嗨|咳|那个|这个|然后)\1+',
  );
  static final _onlyFiller = RegExp(
    r'^[\s，,。；;！!？?、~～…·]*'
    r'(?:嗯|呃|额|啊|哈|哦|噢|喔|唉|哎|诶|嘛|呢|呀|哟|嗨|咳|那个|这个|然后)'
    r'(?:[\s，,。；;！!？?、~～…·]*'
    r'(?:嗯|呃|额|啊|哈|哦|噢|喔|唉|哎|诶|嘛|呢|呀|哟|嗨|咳|那个|这个|然后))*'
    r'[\s，,。；;！!？?、~～…·]*$',
  );

  static String _normalizeFillers(String text) {
    if (text.isEmpty) return text;
    final collapsed = text.replaceAllMapped(
      _fillerRepetition,
      (m) => m.group(1)!,
    );
    if (_onlyFiller.hasMatch(collapsed)) return '';
    return collapsed;
  }
}
