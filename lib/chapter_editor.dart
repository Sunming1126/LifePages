import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:uuid/uuid.dart';

import 'chat_sheet.dart';
import 'directory_page.dart';
import 'platform_capabilities.dart';
import 'main.dart'
    show
        Api,
        ApiFailure,
        BookPage,
        hasAiConsent,
        consent,
        errorText,
        paper,
        secure,
        showError;
import 'onesay_voice_widgets.dart';
import 'voice_io.dart';
import 'wav.dart';

typedef _Row = Map<String, dynamic>;

enum _EditorAction { text, voice, draft, insert, rename, chapter }

String chapterImagePath(String bookId, String topicId, String imageId) =>
    '/api/books/$bookId/topics/$topicId/images/$imageId';

Future<String> loadChapterImage(Api client, String path) async =>
    (await client.call('GET', path))['data'] as String;

class EmptyBookDirectory implements Exception {
  @override
  String toString() => '目录已移除，可在管理目录中恢复或添加。';
}

class ChapterOpening {
  const ChapterOpening._(
    this._topics,
    this._manuscript,
    this._draft,
    this._combined, [
    this.organizing = false,
  ]);

  final List<_Row> _topics;
  final _Row _manuscript;
  final _Row? _draft;
  final bool _combined;
  final bool organizing;

  static Future<ChapterOpening> load(
    Api client,
    String bookId, {
    Future<Directory> Function()? documentsDirectory,
    String? preferred,
    bool interview = false,
  }) async {
    final last =
        preferred ??
        await secure
            .read(key: 'editor_chapter_$bookId')
            .catchError((Object _) => null);
    final path = '/api/books/$bookId/topics';
    final query = Uri(
      queryParameters: {
        'editor': 'true',
        'include_manuscript': 'true',
        'preferred_id': ?last,
        if (interview) 'interview_only': 'true',
      },
    ).query;
    final data = await client.call('GET', '$path?$query') as Map;
    final topics = _readRows(data['topics']);
    if (topics.isEmpty) {
      if (!interview) throw EmptyBookDirectory();
      throw StateError('请先在访谈中整理并保存书稿');
    }
    final initial =
        topics.where((row) => row['id'] == last).firstOrNull ??
        topics.where((row) => row['id'] == data['active_id']).firstOrNull ??
        topics.first;
    final tid = initial['id'] as String;
    final combined = data['manuscript'] as Map?;
    final remote = combined != null && combined['id'] == tid
        ? Future.value(_Row.from(combined))
        : client
              .call('GET', '$path/$tid/manuscript')
              .then((value) => _Row.from(value as Map));
    final local =
        (documentsDirectory?.call() ?? getApplicationDocumentsDirectory()).then(
          (dir) => _readDraft(_draftFile(dir, bookId, tid)),
        );
    final result = await Future.wait<_Row?>([remote, local]);
    return ChapterOpening._(
      topics,
      result[0]!,
      result[1],
      combined != null,
      data['organizing'] == true,
    );
  }
}

List<_Row> _readRows(dynamic value) =>
    (value as List).map((row) => _Row.from(row as Map)).toList();

File _draftFile(Directory dir, String bookId, String tid) => File(
  '${dir.path}/manuscript-${Uri.encodeComponent(bookId)}-${Uri.encodeComponent(tid)}.json',
);

Future<_Row?> _readDraft(File file) async => await file.exists()
    ? _Row.from(jsonDecode(await file.readAsString()) as Map)
    : null;

class ChapterEditor extends StatefulWidget {
  const ChapterEditor({
    super.key,
    required this.bookId,
    required this.title,
    required this.name,
    required this.client,
    this.author,
    this.onChaptersChanged,
    this.onDirectoryChanged,
    this.documentsDirectory,
    this.voiceCapture,
    this.initialOpening,
    this.loadOpening,
    this.onOpeningChanged,
    this.interview = false,
  });

  final String bookId, title, name;
  final String? author;
  final Api client;
  final bool interview;
  final VoidCallback? onChaptersChanged;
  final VoidCallback? onDirectoryChanged;
  final Future<Directory> Function()? documentsDirectory;
  final VoiceCapture? voiceCapture;
  final ChapterOpening? initialOpening;
  final Future<ChapterOpening> Function()? loadOpening;
  final ValueChanged<ChapterOpening>? onOpeningChanged;

  @override
  State<ChapterEditor> createState() => _ChapterEditorState();
}

class _ChapterEditorState extends State<ChapterEditor>
    with WidgetsBindingObserver {
  static const _photos = MethodChannel('life_pages/photos');
  static const _gold = Color(0xff836332);
  static const _dark = Color(0xff29251f);

  List<_Row> _topics = [], _blocks = [];
  _Row? _topic;
  String? _selected, _loadError;
  Timer? _organizationPoll;
  bool _organizing = false;
  bool _emptyDirectory = false;
  String? _insertId, _insertFingerprint;
  Object? _saveError;
  bool _working = false, _dirty = false, _saving = false;
  bool _supportsCombinedLoad = false;
  _EditorAction? _progress;
  _Row? _pendingInsert;
  late final _documents =
      widget.documentsDirectory?.call() ?? getApplicationDocumentsDirectory();
  int _generation = 0, _fieldsVersion = 0;
  Timer? _localTimer, _saveTimer;
  Future<void> _localWrite = Future.value();
  Future<bool>? _remoteWrite;
  final _imageCache = <String, Future<Uint8List>>{};

  VoiceCapture? _recorder;
  StreamSubscription<List<int>>? _mic;
  BytesBuilder? _pcm;
  Timer? _recordLimit;
  bool _holding = false, _cancelVoice = false, _startingVoice = false;

  Api get _client => widget.client;
  String get _path => '/api/books/${widget.bookId}/topics';
  String get _tid => _topic!['id'] as String;
  String get _topicPath => '$_path/$_tid';
  String get _lastChapter => 'editor_chapter_${widget.bookId}';

  String _id() => const Uuid().v4().replaceAll('-', '');
  String _label(_Row topic) {
    final index = widget.interview
        ? _topics.indexWhere((row) => row['id'] == topic['id'])
        : -1;
    return '第 ${index >= 0 ? index + 1 : topic['number']} 章 · ${topic['title']}';
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.initialOpening case final opening?) _applyOpening(opening);
    unawaited(_load());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) return;
    if (_holding || _startingVoice) unawaited(_finishVoice(cancel: true));
    if (_dirty) unawaited(_keepLocal());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _organizationPoll?.cancel();
    _localTimer?.cancel();
    _saveTimer?.cancel();
    _recordLimit?.cancel();
    unawaited(_mic?.cancel());
    unawaited(_recorder?.dispose());
    super.dispose();
  }

  Future<File> _fileFor(String tid) async =>
      _draftFile(await _documents, widget.bookId, tid);

  Future<void> _writeLocal() {
    final tid = _tid;
    final value = _dirty
        ? jsonEncode({'revision': _topic!['revision'], 'blocks': _blocks})
        : null;
    final write = _localWrite.then((_) async {
      final file = await _fileFor(tid);
      if (value == null) {
        if (await file.exists()) await file.delete();
        return;
      }
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(value, flush: true);
      await temporary.rename(file.path);
    });
    _localWrite = write.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return write;
  }

  Future<bool> _keepLocal() async {
    try {
      await _writeLocal();
      return true;
    } catch (error) {
      if (mounted) setState(() => _saveError = error);
      return false;
    }
  }

  Future<void> _openDirectory(String preferred) async {
    final opening = await ChapterOpening.load(
      _client,
      widget.bookId,
      documentsDirectory: () => _documents,
      preferred: preferred,
      interview: widget.interview,
    );
    if (mounted) _applyOpening(opening);
  }

  void _applyOpening(ChapterOpening opening) {
    _organizing = opening.organizing;
    _topics = opening._topics.map(_Row.from).toList();
    _supportsCombinedLoad = opening._combined;
    _applyTopic(opening._manuscript, opening._draft);
  }

  Future<void> _load() async {
    final cold = _topic == null;
    final generation = _generation;
    final fieldsVersion = _fieldsVersion;
    if (cold) {
      setState(() {
        _working = true;
        _loadError = null;
        _emptyDirectory = false;
      });
    }
    try {
      final opening =
          await (widget.loadOpening?.call() ??
              ChapterOpening.load(
                _client,
                widget.bookId,
                documentsDirectory: () => _documents,
                interview: widget.interview,
              ));
      if (!mounted) return;
      _organizationPoll?.cancel();
      setState(() => _organizing = opening.organizing);
      if (opening.organizing) {
        _organizationPoll = Timer(const Duration(seconds: 2), () {
          if (mounted) unawaited(_load());
        });
      }
      if (!cold) {
        setState(() => _topics = opening._topics.map(_Row.from).toList());
      }
      if (cold) {
        _applyOpening(opening);
      } else if (_generation == generation &&
          _fieldsVersion == fieldsVersion &&
          !_working &&
          !_dirty &&
          !_holding &&
          !_startingVoice) {
        if (opening._draft == null &&
            opening._manuscript['id'] == _tid &&
            opening._manuscript['revision'] == _topic!['revision']) {
          // Refresh availability and directory without resetting the cursor.
          setState(() {
            _topics = opening._topics.map(_Row.from).toList();
            _topic = _Row.from(opening._manuscript);
            _supportsCombinedLoad = opening._combined;
          });
        } else if (_selected == null) {
          _applyOpening(opening);
        }
      }
    } catch (error) {
      if (mounted && error is EmptyBookDirectory && !_dirty) {
        setState(() {
          _topic = null;
          _blocks = [];
          _selected = null;
          _emptyDirectory = true;
          _loadError = null;
        });
      } else if (mounted && cold) {
        setState(() {
          _emptyDirectory = error is EmptyBookDirectory;
          _loadError = _emptyDirectory ? null : errorText(error);
        });
      }
    } finally {
      if (mounted && cold) setState(() => _working = false);
    }
  }

  Future<void> _loadTopic(String tid, {bool restoreLocal = true}) async {
    final results = await Future.wait<_Row?>([
      _client
          .call('GET', '$_path/$tid/manuscript')
          .then((value) => _Row.from(value as Map)),
      if (restoreLocal)
        _fileFor(tid).then(_readDraft)
      else
        Future<_Row?>.value(null),
    ]);
    if (mounted) _applyTopic(results[0]!, results[1]);
  }

  void _applyTopic(_Row row, _Row? draft) {
    setState(() {
      _topic = _Row.from(row);
      _blocks = _readRows(draft?['blocks'] ?? row['blocks']);
      _selected = null;
      _fieldsVersion++;
      _dirty = draft != null;
      _saveError = null;
      if (draft != null) _topic!['revision'] = draft['revision'];
      _syncDirectory(_topic!);
    });
    if (_dirty) _scheduleSave();
    _publishOpening();
    unawaited(
      secure.write(key: _lastChapter, value: _tid).catchError((Object _) {}),
    );
  }

  void _publishOpening() {
    final callback = widget.onOpeningChanged;
    final topic = _topic;
    if (callback == null || topic == null) return;
    callback(
      ChapterOpening._(
        _topics.map(_Row.from).toList(),
        _Row.from(topic),
        _dirty
            ? {
                'revision': topic['revision'],
                'blocks': _blocks.map(_Row.from).toList(),
              }
            : null,
        _supportsCombinedLoad,
        _organizing,
      ),
    );
  }

  void _syncDirectory(_Row row) {
    final index = _topics.indexWhere((topic) => topic['id'] == row['id']);
    if (index >= 0) _topics[index] = row;
  }

  void _scheduleSave() {
    _localTimer?.cancel();
    _saveTimer?.cancel();
    _localTimer = Timer(
      const Duration(milliseconds: 200),
      () => unawaited(_keepLocal()),
    );
    _saveTimer = Timer(
      const Duration(milliseconds: 700),
      () => unawaited(_flush()),
    );
  }

  void _changed(VoidCallback change) {
    setState(() {
      change();
      _generation++;
      _dirty = true;
      _saveError = null;
    });
    _scheduleSave();
  }

  Future<bool> _flush() async {
    _localTimer?.cancel();
    _saveTimer?.cancel();
    final active = _remoteWrite;
    if (active != null && !await active) return false;
    if (!mounted) return false;
    if (!_dirty) return true;
    // Multiple callers may resume after the same write.
    if (_remoteWrite case final existing?) return existing;
    final write = _save();
    _remoteWrite = write;
    try {
      return await write;
    } finally {
      _remoteWrite = null;
      if (mounted && _dirty && _saveError == null) _scheduleSave();
    }
  }

  Future<bool> _save() async {
    final generation = _generation;
    final revision = _topic!['revision'];
    final blocks = _blocks.map(_Row.from).toList();
    final path = _topicPath;
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      if (!await _keepLocal()) return false;
      for (final block in blocks) {
        final pendingPhoto = block.remove('local_image');
        if (pendingPhoto != null) {
          await _client.call('PUT', '$path/images', {
            'id': block['image_id'],
            'data': pendingPhoto,
          });
        }
      }
      final row = _Row.from(
        await _client.call('PUT', '$path/manuscript', {
              'revision': revision,
              'blocks': blocks,
            })
            as Map,
      );
      if (!mounted) return false;
      setState(() {
        _topic = row;
        _syncDirectory(row);
        _dirty = generation != _generation;
        if (!_dirty) _blocks = _readRows(row['blocks']);
      });
      final stored = await _keepLocal();
      if (mounted && stored && !_dirty) _publishOpening();
      return stored;
    } catch (error) {
      if (mounted) setState(() => _saveError = error);
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<bool> _readyToPreview() async {
    do {
      if (!await _flush()) return false;
    } while (mounted && _dirty);
    return mounted;
  }

  Future<bool> _canLeaveChapter() async =>
      await _readyToPreview() || (mounted && await _keepLocal());

  Future<void> _work(Future<void> Function() action) async {
    if (_working || !mounted) return;
    setState(() => _working = true);
    try {
      await action();
    } catch (error) {
      if (mounted) showError(context, error);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<T> _withProgress<T>(
    _EditorAction action,
    Future<T> Function() operation,
  ) async {
    setState(() => _progress = action);
    try {
      return await operation();
    } finally {
      if (mounted) setState(() => _progress = null);
    }
  }

  Future<void> _back() => _work(() async {
    if (_topic != null && !await _canLeaveChapter()) return;
    if (mounted) {
      if (_dirty) _publishOpening();
      Navigator.pop(context);
    }
  });

  Future<void> _chooseChapter() => _work(() async {
    final id = await showChatSheet<String>(
      context: context,
      builder: (sheet) => ListView(
        shrinkWrap: true,
        children: [
          const ListTile(title: Text('选择章节')),
          for (final topic in _topics)
            ListTile(
              title: Text(_label(topic)),
              trailing: topic['id'] == _tid
                  ? const Icon(Icons.check_rounded)
                  : null,
              onTap: () => Navigator.pop(sheet, topic['id'] as String),
            ),
        ],
      ),
    );
    if (id != null && id != _tid && await _canLeaveChapter() && mounted) {
      await _withProgress(_EditorAction.chapter, () => _loadTopic(id));
    }
  });

  Future<void> _chapterMetadata({required bool insert}) => _work(() async {
    final result = await showChatSheet<_Row>(
      context: context,
      builder: (_) => _ChapterMetadataSheet(
        insert: insert,
        title: insert
            ? (_pendingInsert?['title'] as String? ?? '')
            : _topic!['title'] as String,
        question: insert ? (_pendingInsert?['question'] as String? ?? '') : '',
      ),
    );
    if (result == null || !mounted) return;
    if (insert) {
      _pendingInsert = result;
      final generateQuestion = (result['question'] as String).isEmpty;
      if (generateQuestion && !_supportsCombinedLoad) {
        throw Exception('请更新 LifePages 服务后自动生成问题，或手动填写');
      }
      if (generateQuestion && !await consent(context, widget.bookId)) return;
      if (!mounted || !await _canLeaveChapter() || !mounted) return;
      final fingerprint = jsonEncode([_tid, result]);
      if (_insertFingerprint != fingerprint) {
        _insertFingerprint = fingerprint;
        _insertId = _id();
      }
      await _withProgress(_EditorAction.insert, () async {
        final row = await _client.call('POST', _path, {
          ...result,
          'after_id': _tid,
          'id': _insertId,
          'generate_question': generateQuestion,
        });
        if (mounted) await _openDirectory(row['id'] as String);
        _pendingInsert = null;
        _insertFingerprint = null;
      });
    } else {
      if (!await _readyToPreview()) return;
      final row = await _withProgress(
        _EditorAction.rename,
        () async => _Row.from(
          await _client.call('PATCH', _topicPath, {
                ...result,
                if (!_supportsCombinedLoad) 'question': _topic!['question'],
                'revision': _topic!['revision'],
              })
              as Map,
        ),
      );
      if (mounted) {
        setState(() {
          _topic = row;
          _syncDirectory(row);
        });
        _publishOpening();
      }
    }
    widget.onChaptersChanged?.call();
  });

  Future<void> _preview() => _work(() async {
    if (!await _readyToPreview()) return;
    if (!mounted) return;
    var changed = false;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BookPage(
          bookId: widget.bookId,
          name: widget.name,
          title: widget.title,
          author: widget.author,
          client: _client,
          interview: widget.interview,
          onChaptersChanged: () {
            changed = true;
            widget.onChaptersChanged?.call();
          },
        ),
      ),
    );
    if (mounted && changed) await _loadTopic(_tid);
  });

  Future<void> _resolveConflict() => _work(() async {
    final server = _Row.from(
      await _client.call('GET', '$_topicPath/manuscript') as Map,
    );
    if (!mounted) return;
    final action = await showChatSheet<String>(
      context: context,
      builder: (sheet) => ChatSheetDialog(
        title: const Text('服务器上的版本'),
        content: SelectableText(
          _readRows(server['blocks'])
              .map(
                (block) =>
                    block['kind'] == 'image' ? '［图片］' : block['text'] as String,
              )
              .join('\n\n'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(sheet),
            child: const Text('稍后处理'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(sheet, 'server'),
            child: const Text('使用服务器稿'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(sheet, 'local'),
            child: const Text('用本机稿替换'),
          ),
        ],
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'server') {
      final file = await _fileFor(_tid);
      if (await file.exists()) await file.delete();
      if (mounted) await _loadTopic(_tid, restoreLocal: false);
    } else {
      _topic = server;
      _changed(() {});
      await _flush();
    }
  });

  void _addBlock(_Row block) => _changed(() {
    final index = _blocks.indexWhere((value) => value['id'] == _selected);
    _blocks.insert(index < 0 ? _blocks.length : index + 1, block);
    _selected = block['id'] as String;
  });

  void _addText([String text = '']) =>
      _addBlock({'id': _id(), 'kind': 'text', 'text': text});

  Future<void> _pickPhoto() => _work(() async {
    final bytes = await _photos.invokeMethod<Uint8List>('pick');
    if (!mounted || bytes == null) return;
    final id = _id();
    _imageCache[id] = Future.value(bytes);
    _addBlock({
      'id': id,
      'kind': 'image',
      'image_id': id,
      'local_image': base64Encode(bytes),
    });
    await _keepLocal();
  });

  Future<Uint8List> _photo(_Row block) {
    final id = block['image_id'] as String;
    return _imageCache.putIfAbsent(id, () async {
      if (block['local_image'] case final String local) {
        return base64Decode(local);
      }
      final path = chapterImagePath(widget.bookId, _tid, id);
      return base64Decode(await loadChapterImage(_client, path));
    });
  }

  Future<void> _draft() => _work(() async {
    if (!await _readyToPreview() || !mounted) return;
    final path = '$_topicPath/draft';
    final draft = await _withProgress(_EditorAction.draft, () async {
      if (_topic!['draft_id'] != null) {
        final existing = (await _client.call('GET', path))['draft'];
        if (existing != null) return existing;
      }
      if (!mounted || !await consent(context, widget.bookId)) return null;
      final result = await _client.call('POST', '$path?include_draft=true');
      if (result['outcome'] == 'insufficient' ||
          result['outcome'] == 'no_story') {
        if (mounted) showError(context, '本章还没有可以整理的新讲述');
        return null;
      }
      return result['draft'] ?? (await _client.call('GET', path))['draft'];
    });
    if (!mounted || draft == null) return;
    setState(() => _topic!['draft_id'] = draft['id']);
    final action = await showChatSheet<String>(
      context: context,
      builder: (sheet) => ChatSheetDialog(
        title: const Text('核对本章草稿'),
        content: SelectableText(draft['body'] as String),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(sheet),
            child: const Text('稍后核对'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(sheet, 'DELETE'),
            child: const Text('放弃草稿'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(sheet, 'PUT'),
            child: const Text('采用正文'),
          ),
        ],
      ),
    );
    if (action == null || !mounted) return;
    await _client.call(action, "$path/${draft['id']}");
    if (mounted) await _loadTopic(_tid);
    widget.onChaptersChanged?.call();
  });

  Future<void> _manageDirectory() => _work(() async {
    if (_topic != null && !await _flush() || !mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DirectoryPage(
          bookId: widget.bookId,
          title: widget.title,
          client: widget.client,
          onChanged: () {
            widget.onDirectoryChanged?.call();
            widget.onChaptersChanged?.call();
          },
        ),
      ),
    );
    if (!mounted) return;
    setState(() {
      _topic = null;
      _blocks = [];
      _selected = null;
    });
    await _load();
  });

  Future<void> _organize() {
    if (!widget.interview && _topic?['has_narrations'] == true) return _draft();
    return _work(() async {
      if (!await _flush() || !mounted) return;
      final updated = await _withProgress(
        _EditorAction.draft,
        () => _client.call('POST', '$_topicPath/organize', {
          'revision': _topic!['revision'],
        }),
      );
      if (!mounted) return;
      _applyTopic(_Row.from(updated as Map), null);
      widget.onChaptersChanged?.call();
    });
  }

  Future<void> _aiText() => _work(() async {
    final request = await showChatSheet<String>(
      context: context,
      builder: (_) => const _InstructionSheet(),
    );
    if (!mounted || request == null || !await consent(context, widget.bookId)) {
      return;
    }
    await _suggest(request, _EditorAction.text);
  });

  Future<void> _suggest(String instruction, _EditorAction action) async {
    if (!await _readyToPreview()) return;
    final textBlocks = _blocks
        .where((block) => block['kind'] == 'text')
        .toList();
    final target =
        textBlocks.where((block) => block['id'] == _selected).firstOrNull ??
        (_selected == null && textBlocks.length == 1
            ? textBlocks.single
            : null);
    if (target == null && textBlocks.isNotEmpty) {
      throw Exception('请先选择一张要修改的文字卡片');
    }
    final proposal = await _withProgress(
      action,
      () => _client.call('POST', '$_topicPath/suggest', {
        'revision': _topic!['revision'],
        'block_id': target?['id'],
        'instruction': instruction,
      }),
    );
    if (!mounted) return;
    final body = proposal['text'] as String;
    final accepted = await showChatSheet<bool>(
      context: context,
      builder: (sheet) => ChatSheetDialog(
        title: const Text('预览 AI 修改'),
        content: SelectableText(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(sheet),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(sheet, true),
            child: const Text('应用修改'),
          ),
        ],
      ),
    );
    if (!mounted || accepted != true) return;
    if (target == null) {
      _addText(body);
    } else {
      // The save response may have replaced the local map instances.
      _changed(() {
        _blocks.firstWhere((block) => block['id'] == target['id'])['text'] =
            body;
        _fieldsVersion++;
      });
    }
    await _flush();
    widget.onChaptersChanged?.call();
  }

  Future<void> _startVoice() async {
    if (_working || _startingVoice || _holding || _pcm != null) return;
    setState(() {
      _holding = true;
      _startingVoice = true;
      _cancelVoice = false;
    });
    try {
      if (!await hasAiConsent(widget.bookId)) {
        if (mounted && await consent(context, widget.bookId) && mounted) {
          showError(context, '请再长按一次开始录音');
        }
        return;
      }
      if (!mounted || !_holding) return;
      final recorder = _recorder ??=
          widget.voiceCapture ?? DeviceVoiceCapture();
      if (!await recorder.hasPermission()) throw Exception('请允许麦克风权限');
      if (!mounted || !_holding) return;
      final stream = await recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
        ),
      );
      if (!mounted || !_holding) {
        await recorder.stop();
        return;
      }
      final pcm = _pcm = BytesBuilder(copy: false);
      _mic = stream.listen(pcm.add);
      _recordLimit = Timer(
        const Duration(minutes: 1),
        () => unawaited(_finishVoice()),
      );
    } catch (error) {
      if (mounted) showError(context, error);
    } finally {
      if (mounted) {
        setState(() {
          _startingVoice = false;
          if (_pcm == null) _holding = false;
        });
      }
    }
  }

  Future<void> _finishVoice({bool cancel = false}) async {
    if (!_holding || !mounted) return;
    setState(() => _holding = false);
    _recordLimit?.cancel();
    final pcm = _pcm;
    if (pcm == null) return;
    _pcm = null;
    await _work(() async {
      await _mic?.cancel();
      _mic = null;
      await _recorder?.stop();
      final bytes = pcm.takeBytes();
      if (cancel || !mounted) return;
      if (bytes.length < 3200) throw Exception('没有录到声音，请重新长按');
      final response = await _withProgress(
        _EditorAction.voice,
        () => _client.call('POST', '/api/transcribe', {
          'audio_base64': base64Encode(pcmToWav(bytes)),
        }),
      );
      final instruction = (response['text'] as String).trim();
      if (instruction.isEmpty) throw Exception('没有识别到修改要求，请重试');
      if (mounted) await _suggest(instruction, _EditorAction.voice);
    });
  }

  Widget _card(_Row block, int index) {
    final id = block['id'] as String;
    final text = block['kind'] == 'text';
    final enabled = !_working && !_holding && !_startingVoice;
    return Card(
      key: ValueKey(id),
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: _selected == id ? _gold : const Color(0xffe8e1d6),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: enabled
                        ? () => setState(() => _selected = id)
                        : null,
                    style: TextButton.styleFrom(
                      alignment: Alignment.centerLeft,
                    ),
                    child: Text(text ? '文字' : '图片'),
                  ),
                ),
                IconButton(
                  tooltip: '上移',
                  onPressed: !enabled || index == 0
                      ? null
                      : () => _move(index, index - 1),
                  icon: const Icon(Icons.arrow_upward_rounded),
                ),
                IconButton(
                  tooltip: '下移',
                  onPressed: !enabled || index == _blocks.length - 1
                      ? null
                      : () => _move(index, index + 1),
                  icon: const Icon(Icons.arrow_downward_rounded),
                ),
                IconButton(
                  tooltip: '删除卡片',
                  onPressed: enabled ? () => _deleteCard(id) : null,
                  icon: const Icon(
                    Icons.delete_outline,
                    color: Color(0xff9d4136),
                  ),
                ),
              ],
            ),
            if (text)
              TextFormField(
                key: ValueKey('$id:$_fieldsVersion'),
                initialValue: block['text'] as String,
                readOnly: !enabled,
                minLines: 3,
                maxLines: null,
                onTap: () => setState(() => _selected = id),
                onChanged: (value) => _changed(() {
                  _blocks.firstWhere((row) => row['id'] == id)['text'] = value;
                  _selected = id;
                }),
                decoration: const InputDecoration(
                  hintText: '从一个画面、一句话或一个人开始写……',
                ),
              )
            else
              FutureBuilder<Uint8List>(
                future: _photo(block),
                builder: (context, photo) {
                  if (photo.hasError) {
                    return TextButton(
                      onPressed: () =>
                          setState(() => _imageCache.remove(block['image_id'])),
                      child: const Text('图片加载失败，重试'),
                    );
                  }
                  if (!photo.hasData) {
                    return const Center(
                      child: Padding(
                        padding: EdgeInsets.all(16),
                        child: SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    );
                  }
                  return GestureDetector(
                    onTap: () => setState(() => _selected = id),
                    child: Image.memory(
                      photo.data!,
                      fit: BoxFit.contain,
                      semanticLabel: '章节图片',
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  void _move(int from, int to) {
    FocusManager.instance.primaryFocus?.unfocus();
    _changed(() {
      final block = _blocks.removeAt(from);
      _blocks.insert(to, block);
      _selected = block['id'] as String;
    });
  }

  Future<void> _deleteCard(String id) => _work(() async {
    final remove = await showChatSheet<bool>(
      context: context,
      builder: (sheet) => ChatSheetDialog(
        title: const Text('删除这张卡片？'),
        content: const Text('保存后，这张卡片将从本章移除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(sheet),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(sheet, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (mounted && remove == true) {
      _changed(() {
        _blocks.removeWhere((block) => block['id'] == id);
        if (_selected == id) _selected = null;
      });
    }
  });

  @override
  Widget build(BuildContext context) {
    final topic = _topic;
    final keyboard = MediaQuery.viewInsetsOf(context).bottom > 0;
    final enabled = !_working && !_holding && !_startingVoice;
    final conflict =
        _saveError is ApiFailure && (_saveError as ApiFailure).status == 409;
    final header = <Widget>[
      if (topic != null) ...[
        Text(
          topic['title'] as String,
          style: const TextStyle(fontSize: 29, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xffe2ebe5),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.lightbulb_outline, size: 21),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    topic['question'] as String,
                    style: const TextStyle(height: 1.5),
                  ),
                ),
              ],
            ),
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: _saveError != null
              ? TextButton(
                  onPressed: !enabled
                      ? null
                      : conflict
                      ? _resolveConflict
                      : _flush,
                  child: Text(conflict ? '保存冲突 · 查看服务器版本' : '保存失败 · 重试'),
                )
              : Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Text(
                    _dirty || _saving ? '正在保存…' : '已保存',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
        ),
        if (_organizing)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('正在自动整理已完成的章节，完成后会显示在章节目录中。'),
          ),
        if (_blocks.isEmpty)
          Card(
            color: Colors.white,
            child: ListTile(
              title: const Text('从一个画面、一句话或一个人开始写……'),
              trailing: const Icon(Icons.add),
              onTap: enabled ? () => _addText() : null,
            ),
          ),
      ],
    ];
    return PopScope<void>(
      canPop: topic == null || (!_dirty && enabled),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && enabled) unawaited(_back());
      },
      child: Scaffold(
        backgroundColor: paper,
        appBar: AppBar(
          backgroundColor: paper,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          title: Text(widget.title, overflow: TextOverflow.ellipsis),
          centerTitle: true,
          leading: BackButton(
            onPressed: topic == null
                ? () => Navigator.pop(context)
                : enabled
                ? _back
                : () {},
          ),
          actions: [
            if (!widget.interview && topic == null && !_emptyDirectory)
              IconButton(
                tooltip: '管理目录',
                onPressed: enabled ? _manageDirectory : null,
                icon: const Icon(Icons.playlist_add_check),
              ),
            TextButton.icon(
              onPressed: topic == null || !enabled ? null : _preview,
              icon: const Icon(Icons.menu_book_outlined, size: 20),
              label: const Text('预览'),
              style: TextButton.styleFrom(foregroundColor: _gold),
            ),
          ],
        ),
        bottomNavigationBar:
            keyboard || _emptyDirectory || (topic == null && _loadError != null)
            ? null
            : _toolbar(topic != null && enabled),
        body: topic == null
            ? Center(
                child: _emptyDirectory
                    ? Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('还没有目录，先添加一章吧。'),
                          TextButton(
                            onPressed: enabled ? _manageDirectory : null,
                            child: const Text('管理目录'),
                          ),
                        ],
                      )
                    : _loadError == null
                    ? const _OpeningPlaceholder()
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(_loadError!),
                          TextButton(onPressed: _load, child: const Text('重试')),
                        ],
                      ),
              )
            : Column(
                children: [
                  Material(
                    color: paper,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 6, 8, 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: enabled ? _chooseChapter : null,
                              icon: _actionIcon(
                                _EditorAction.chapter,
                                Icons.format_list_numbered,
                              ),
                              label: Text(
                                _label(topic),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                          if (!widget.interview)
                            TextButton.icon(
                              onPressed: enabled ? _manageDirectory : null,
                              icon: const Icon(
                                Icons.playlist_add_check,
                                size: 20,
                              ),
                              label: const Text('管理目录'),
                            )
                          else ...[
                            IconButton(
                              tooltip: '编辑章节',
                              onPressed: enabled
                                  ? () => _chapterMetadata(insert: false)
                                  : null,
                              icon: _actionIcon(
                                _EditorAction.rename,
                                Icons.edit_outlined,
                              ),
                            ),
                            IconButton(
                              tooltip: '添加章节',
                              onPressed: enabled
                                  ? () => _chapterMetadata(insert: true)
                                  : null,
                              icon: _actionIcon(
                                _EditorAction.insert,
                                Icons.playlist_add_rounded,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  Expanded(
                    child: ListView.builder(
                      key: ValueKey(topic['id']),
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      padding: const EdgeInsets.fromLTRB(16, 18, 16, 22),
                      itemCount: header.length + _blocks.length,
                      findChildIndexCallback: (key) {
                        if (key is! ValueKey<String>) return null;
                        final index = _blocks.indexWhere(
                          (block) => block['id'] == key.value,
                        );
                        return index < 0 ? null : header.length + index;
                      },
                      itemBuilder: (_, index) => index < header.length
                          ? header[index]
                          : _card(
                              _blocks[index - header.length],
                              index - header.length,
                            ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _toolbar(bool enabled) => Material(
    color: const Color(0xfffdfcf8),
    child: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: enabled || _holding ? _dark : Colors.black26,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: HoldToTalkButton(
                      active: _holding,
                      label: 'AI 语音',
                      hint: '长按说出修改要求，松手生成修改稿，上滑取消',
                      onStart: _startVoice,
                      onSlide: (cancel) {
                        if (_holding) setState(() => _cancelVoice = cancel);
                      },
                      onEnd: () => _finishVoice(cancel: _cancelVoice),
                      onCancel: () => _finishVoice(cancel: true),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _actionIcon(
                            _EditorAction.voice,
                            Icons.mic_none_rounded,
                            color: Colors.white,
                          ),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              _holding
                                  ? (_cancelVoice ? '松开取消' : '松手结束')
                                  : 'AI 语音',
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _action(
                    Icons.auto_awesome_outlined,
                    'AI 文字',
                    enabled ? _aiText : null,
                    progress: _EditorAction.text,
                  ),
                ),
              ],
            ),
            if (_topic?['draft_id'] != null)
              TextButton(
                onPressed: enabled ? _draft : null,
                child: const Text('查看本章草稿'),
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: enabled ? _organize : null,
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 48),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    icon: _actionIcon(
                      _EditorAction.draft,
                      Icons.auto_awesome_outlined,
                    ),
                    label: const Text('整理本章'),
                  ),
                ),
                if (supportsNativePhotos) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: _action(
                      Icons.add_photo_alternate_outlined,
                      '插入图片',
                      enabled ? _pickPhoto : null,
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    ),
  );

  Widget _actionIcon(_EditorAction action, IconData icon, {Color? color}) =>
      _progress == action
      ? SizedBox.square(
          dimension: 20,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: color,
            semanticsLabel: '正在处理',
          ),
        )
      : Icon(icon, size: 20, color: color);

  Widget _action(
    IconData icon,
    String text,
    VoidCallback? action, {
    _EditorAction? progress,
  }) => FilledButton.icon(
    onPressed: action,
    style: FilledButton.styleFrom(
      backgroundColor: _dark,
      minimumSize: const Size(0, 48),
      padding: const EdgeInsets.symmetric(horizontal: 8),
    ),
    icon: progress == null ? Icon(icon, size: 20) : _actionIcon(progress, icon),
    label: Text(text),
  );
}

class _OpeningPlaceholder extends StatelessWidget {
  const _OpeningPlaceholder();

  @override
  Widget build(BuildContext context) => Semantics(
    label: '正在获取章节',
    child: Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: 42,
              decoration: BoxDecoration(
                color: const Color(0xffeee8dd),
                borderRadius: BorderRadius.circular(18),
              ),
            ),
            const SizedBox(height: 20),
            Container(
              height: 84,
              decoration: BoxDecoration(
                color: const Color(0xffe2ebe5),
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _ChapterMetadataSheet extends StatefulWidget {
  const _ChapterMetadataSheet({
    required this.insert,
    required this.title,
    required this.question,
  });
  final bool insert;
  final String title, question;

  @override
  State<_ChapterMetadataSheet> createState() => _ChapterMetadataSheetState();
}

class _ChapterMetadataSheetState extends State<_ChapterMetadataSheet> {
  late final _title = TextEditingController(text: widget.title);
  late final _question = TextEditingController(text: widget.question);
  final _form = GlobalKey<FormState>();

  @override
  void dispose() {
    _title.dispose();
    _question.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ChatSheetDialog(
    title: Text(widget.insert ? '在本章后添加章节' : '编辑章节'),
    content: Form(
      key: _form,
      child: Column(
        children: [
          TextFormField(
            controller: _title,
            maxLength: 100,
            validator: (value) => value!.trim().isEmpty ? '请填写章节标题' : null,
            decoration: const InputDecoration(labelText: '章节标题'),
          ),
          if (widget.insert)
            TextFormField(
              controller: _question,
              minLines: 2,
              maxLines: 4,
              maxLength: 1000,
              decoration: const InputDecoration(labelText: '讲述问题（留空由 AI 生成）'),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () {
          if (_form.currentState!.validate()) {
            Navigator.pop(context, <String, dynamic>{
              'title': _title.text.trim(),
              if (widget.insert) 'question': _question.text.trim(),
            });
          }
        },
        child: const Text('保存'),
      ),
    ],
  );
}

class _InstructionSheet extends StatefulWidget {
  const _InstructionSheet();

  @override
  State<_InstructionSheet> createState() => _InstructionSheetState();
}

class _InstructionSheetState extends State<_InstructionSheet> {
  final _instruction = TextEditingController();

  @override
  void dispose() {
    _instruction.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ChatSheetDialog(
    title: const Text('告诉 AI 怎么改'),
    content: TextField(
      controller: _instruction,
      autofocus: true,
      maxLength: 4000,
      minLines: 2,
      maxLines: 5,
      onChanged: (_) => setState(() {}),
      decoration: const InputDecoration(hintText: '例如：把这一段改得更口语'),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _instruction.text.trim().isEmpty
            ? null
            : () => Navigator.pop(context, _instruction.text.trim()),
        child: const Text('生成修改稿'),
      ),
    ],
  );
}
