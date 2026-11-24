import 'chat_sheet.dart';
import 'voice_preferences.dart';
import 'bookshelf.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'onesay_voice_widgets.dart';
import 'onesay_transcript.dart';
import 'dart:typed_data' show BytesBuilder;
import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:crypto/crypto.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:uuid/uuid.dart';

import 'main.dart';
import 'wav.dart';
import 'voice_io.dart';
import 'rtc_reply_player.dart';
import 'chatchat_style.dart';
import 'my_page.dart';
import 'reading_preferences.dart';
import 'legal_urls.dart';
import 'interview_draft.dart';

class ChatShell extends StatefulWidget {
  const ChatShell({
    super.key,
    this.client,
    this.documentsDirectory,
    this.email,
    this.accountProvider,
    this.onSignIn,
    this.onSignOut,
  });
  final Api? client;
  final Future<Directory> Function()? documentsDirectory;
  final String? email, accountProvider;
  final Future<void> Function(Map<String, dynamic>)? onSignIn;
  final Future<void> Function()? onSignOut;
  @override
  State<ChatShell> createState() => _ChatShellState();
}

class _ChatShellState extends State<ChatShell> {
  GlobalKey<_FreeChatPageState> _chatKey = GlobalKey<_FreeChatPageState>();
  final _drafts = <String, Map<String, TextEditingValue>>{};
  List<BookRecord> _books = [], _trash = [];
  String? _activeId, _error;
  String? _createFingerprint, _createId;
  Api get _api => widget.client ?? api;
  bool _loading = true, _busy = false;
  bool _interviewAvailable = false;
  bool _themeInterviewAvailable = false;
  bool _bookModesAvailable = false;
  int _tab = 0, _shelfEpoch = 0;
  PageBackground _background = PageBackground.paperTone;
  bool _backgroundChosen = false;
  static const _backgroundKey = 'page_background';

  BookRecord? get _book =>
      _books.where((book) => book['id'] == _activeId).firstOrNull;

  @override
  void initState() {
    super.initState();
    _load();
    unawaited(_restoreBackground());
  }

  Future<void> _restoreBackground() async {
    try {
      final value = await secure.read(key: _backgroundKey);
      final saved = PageBackground.values
          .where((tone) => tone.name == value)
          .firstOrNull;
      if (mounted && !_backgroundChosen && saved != null) {
        setState(() => _background = saved);
      }
    } catch (_) {
      // The default remains usable if device storage is unavailable.
    }
  }

  void _selectBackground(PageBackground next) {
    _backgroundChosen = true;
    setState(() => _background = next);
    unawaited(
      secure.write(key: _backgroundKey, value: next.name).catchError((
        Object error,
      ) {
        if (mounted && _background == next) showError(context, '暂时无法保存背景偏好');
      }),
    );
  }

  void _applyRecords(dynamic state) {
    _bookModesAvailable =
        (state['book_modes'] as List?)?.contains('directory') == true;
    _interviewAvailable = state['interview_version'] != null;
    _themeInterviewAvailable =
        (state['interview_versions'] as List?)?.contains(2) == true;
    final previousInterview = _books
        .where((book) => book['id'] == _activeId)
        .firstOrNull?['interview_version'];
    unawaited(_api.writeSnapshot('/api/books', state));
    _books = List<BookRecord>.from(
      (state['books'] as List).map(
        (row) => Map<String, dynamic>.from(row as Map),
      ),
    );
    _trash = List<BookRecord>.from(
      (state['trash'] as List).map(
        (row) => Map<String, dynamic>.from(row as Map),
      ),
    );
    final nextInterview = _books
        .where((book) => book['id'] == _activeId)
        .firstOrNull?['interview_version'];
    if (previousInterview != nextInterview) {
      _chatKey = GlobalKey<_FreeChatPageState>();
    }
  }

  void _apply(dynamic state) {
    _applyRecords(state);
    final next = state['active_id'] as String?;
    if (_activeId != next) _chatKey = GlobalKey<_FreeChatPageState>();
    _activeId = next;
  }

  Future<void> _cleanRetiredDrafts(dynamic state) async {
    final retired = state['retired_ids'] as List? ?? [];
    if (retired.isEmpty) return;
    try {
      final dir =
          await (widget.documentsDirectory?.call() ??
              getApplicationDocumentsDirectory());
      final retiredBooks = retired
          .whereType<String>()
          .where((id) => RegExp(r'^[0-9a-f]{32}$').hasMatch(id))
          .toSet();
      for (final id in retiredBooks) {
        _drafts.remove(id);
        await _removeOutbox(dir, 'book-outbox-$id.json');
        await _removeOutbox(dir, 'book-outbox-$id.json.tmp');
        unawaited(
          secure.delete(key: 'editor_chapter_$id').catchError((Object _) {}),
        );
      }
      final draftName = RegExp(r'^manuscript-([0-9a-f]{32})-');
      await for (final file in dir.list(followLinks: false)) {
        if (file is File &&
            retiredBooks.contains(
              draftName.firstMatch(file.uri.pathSegments.last)?.group(1),
            )) {
          await file.delete();
        }
      }
    } on FileSystemException {
      // A later shelf refresh can retry local cleanup.
    }
  }

  Future<void> _load() async {
    try {
      final saved = await _api.readSnapshot('/api/books');
      if (saved is Map && saved['books'] is List && mounted) {
        setState(() {
          _apply(saved);
          _loading = false;
        });
      }
    } catch (_) {
      // Ignore obsolete snapshots and try the server.
    }
    try {
      final state = await _api.call('GET', '/api/books');
      unawaited(_cleanRetiredDrafts(state));
      if (mounted) {
        setState(() {
          _apply(state);
          _error = null;
        });
      }
    } catch (error) {
      if (mounted && _books.isEmpty) setState(() => _error = errorText(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  bool get _canChangeBook {
    if (_busy) return false;
    if (_chatKey.currentState?._chatBusy ?? false) {
      showError(context, '请等本章当前操作结束');
      return false;
    }
    return true;
  }

  Future<void> _changeBook(
    String method,
    String path, {
    BookRecord? data,
    bool openChat = false,
  }) async {
    if (!_canChangeBook) return;
    _shelfEpoch++;
    setState(() => _busy = true);
    try {
      final state = await _api.call(method, path, data);
      unawaited(_cleanRetiredDrafts(state));
      if (mounted) {
        setState(() {
          _apply(state);
          if (openChat) {
            _tab = 0;
            _createFingerprint = null;
            _createId = null;
          }
        });
      }
    } catch (error) {
      if (mounted) showError(context, error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _restoreBook(String id) => _changeBook('POST', '/api/books/$id/restore');

  Future<void> _create() async {
    if (!_canChangeBook) return;
    final data = await newBookSheet(
      context,
      _api,
      interview: _interviewAvailable,
      allowModes: _bookModesAvailable,
      interviewVersion: _themeInterviewAvailable ? 2 : 1,
    );
    if (mounted && data != null) {
      final fingerprint = jsonEncode(data);
      if (_createFingerprint != fingerprint || _createId == null) {
        _createFingerprint = fingerprint;
        _createId = const Uuid().v4().replaceAll('-', '');
      }
      await _changeBook(
        'POST',
        '/api/books',
        data: {'id': _createId, ...data},
        openChat: true,
      );
    }
  }

  void _continue(String id) {
    if (!_canChangeBook) return;
    setState(() {
      if (_activeId != id) _chatKey = GlobalKey<_FreeChatPageState>();
      _activeId = id;
      _tab = 0;
    });
  }

  Future<void> _openChatSettings() async {
    if (!_canChangeBook) return;
    final currentVoice = await ReplyVoice.load();
    if (!mounted || !_canChangeBook) return;
    var pickingVoice = false;
    final selection = await showChatSheet<Object>(
      context: context,
      builder: (sheet) => StatefulBuilder(
        builder: (_, setSheetState) => pickingVoice
            ? ListView(
                key: const ValueKey('reply-voice-menu'),
                shrinkWrap: true,
                children: [
                  ListTile(
                    leading: IconButton(
                      tooltip: '返回聊天设置',
                      onPressed: () =>
                          setSheetState(() => pickingVoice = false),
                      icon: const Icon(Icons.arrow_back_rounded),
                    ),
                    title: const Text('AI 播报音色'),
                    subtitle: const Text('选择后，下次播报生效'),
                  ),
                  for (final voice in ReplyVoice.values)
                    ListTile(
                      key: ValueKey('reply-voice-${voice.name}'),
                      title: Text(voice.label),
                      subtitle: Text(voice.gender),
                      selected: voice == currentVoice,
                      trailing: voice == currentVoice
                          ? const Icon(Icons.check_rounded)
                          : null,
                      onTap: () => Navigator.pop(sheet, voice),
                    ),
                ],
              )
            : ListView(
                key: const ValueKey('chat-settings-menu'),
                shrinkWrap: true,
                children: [
                  const ListTile(title: Text('聊天设置')),
                  if (_book != null)
                    ListTile(
                      leading: const Icon(Icons.person_outline_rounded),
                      title: const Text('讲述者设置'),
                      onTap: () => Navigator.pop(sheet, 'narrator'),
                    ),
                  ListTile(
                    leading: const Icon(Icons.volume_up_outlined),
                    title: const Text('AI 播报音色'),
                    subtitle: Text(currentVoice.label),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => setSheetState(() => pickingVoice = true),
                  ),
                ],
              ),
      ),
    );
    if (!mounted || selection == null) return;
    if (selection is ReplyVoice) {
      try {
        await selection.save();
      } catch (_) {
        if (mounted) showError(context, '音色选择暂时无法保存，请重试');
      }
    } else if (selection == 'chat-outbox') {
      await _chatKey.currentState?._openChapterOutbox();
    } else if (selection == 'chat-topics') {
      await _chatKey.currentState?._openTopics();
    } else if (selection == 'narrator') {
      final bookId = _activeId;
      try {
        final chapter = _chatKey.currentState?._sessionId;
        final path = '/api/people/$bookId';
        final person = await _api
            .call('GET', chapter == null ? path : '$path?session_id=$chapter')
            .timeout(const Duration(seconds: 15));
        if (!mounted || bookId != _activeId) return;
        final saved = await showChatSheet<bool>(
          context: context,
          builder: (_) => EditPersonSheet(
            person: Map<String, dynamic>.from(person as Map),
            client: _api,
          ),
        );
        if (saved == true && mounted) unawaited(_refreshCounts());
      } catch (error) {
        if (mounted) showError(context, error);
      }
    }
  }

  Future<void> _renameBook(String id, BookRecord data) async {
    if (_busy) throw Exception('请等当前操作完成');
    _shelfEpoch++;
    setState(() => _busy = true);
    try {
      final state = await _api
          .call('PATCH', '/api/books/$id', data)
          .timeout(const Duration(seconds: 15));
      if (mounted) setState(() => _applyRecords(state));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _chaptersChanged(String bookId) {
    if (!mounted) return;
    unawaited(_refreshCounts());
    if (_activeId != bookId) return;
    final chat = _chatKey.currentState;
    if (chat != null && !chat.widget.interview) {
      unawaited(chat._refreshTopics(afterEdit: true).catchError((_) {}));
    }
  }

  Future<void> _refreshCounts() async {
    final epoch = ++_shelfEpoch;
    try {
      final data = await _api.call('GET', '/api/books');
      unawaited(_cleanRetiredDrafts(data));
      if (mounted && !_busy && epoch == _shelfEpoch) {
        setState(() => _applyRecords(data));
      }
    } catch (_) {
      // Keep the current shelf available if its counts cannot refresh.
    }
  }

  Widget _empty() => Center(
    child: FilledButton.icon(
      onPressed: _busy ? null : _create,
      icon: const Icon(Icons.add_rounded),
      label: const Text('新建书籍'),
    ),
  );

  Widget? _shelfStatus() {
    if (_loading) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('正在加载书架…'),
            SizedBox(height: 16),
            CircularProgressIndicator(),
          ],
        ),
      );
    }
    if (_error == null) return null;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_error!, textAlign: TextAlign.center),
          TextButton(onPressed: _load, child: const Text('重试')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final status = _shelfStatus();
    final book = _book;
    final inset = MediaQuery.viewPaddingOf(context).bottom;
    final showNavigation = MediaQuery.viewInsetsOf(context).bottom == 0;
    return DecoratedBox(
      key: const ValueKey('main-page-background'),
      decoration: BoxDecoration(
        color: _background.color,
        image: DecorationImage(image: _background.image, fit: BoxFit.cover),
      ),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        resizeToAvoidBottomInset: true,
        body: Stack(
          children: [
            Positioned.fill(
              child: IndexedStack(
                index: _tab,
                children: [
                  if (status != null)
                    status
                  else if (book == null)
                    _empty()
                  else
                    KeyedSubtree(
                      key: ValueKey("chat-${book['id']}"),
                      child: FreeChatPage(
                        key: _chatKey,
                        personId: book['id'] as String,
                        bookTitle: book['title'] as String,
                        interview: isCompanionBook(book),
                        companion: _bookModesAvailable && isCompanionBook(book),
                        bookDrafts: _drafts.putIfAbsent(
                          book['id'] as String,
                          () => {},
                        ),
                        onChooseBook: _openChatSettings,
                        client: _api,
                        documentsDirectory: widget.documentsDirectory,
                        active: _tab == 0,
                        showNavigation: showNavigation,
                        onChapterChanged: _refreshCounts,
                      ),
                    ),
                  status ??
                      Bookshelf(
                        books: _books,
                        activeId: _activeId,
                        client: _api,
                        busy: _busy,
                        documentsDirectory: widget.documentsDirectory,
                        onCreate: _create,
                        onContinue: _continue,
                        onRecentlyDeleted: () => showRecentlyDeleted(
                          context,
                          books: _trash,
                          onRestore: _restoreBook,
                        ),
                        onRename: _renameBook,
                        onChaptersChanged: _chaptersChanged,
                        onDelete: (id) =>
                            _changeBook('DELETE', '/api/books/$id'),
                      ),
                  MyPage(
                    books: _books,
                    active: _tab == 2,
                    navigationClearance: showNavigation
                        ? inset +
                              OneSayChatNavigation.bottomGap +
                              OneSayChatNavigation.height
                        : 0,
                    trash: _trash,
                    client: _api,
                    email: widget.email,
                    accountProvider: widget.accountProvider,
                    onSignIn: widget.onSignIn,
                    onSignOut: widget.onSignOut,
                    background: _background,
                    busy: _busy,
                    onBackgroundChanged: _selectBackground,
                    onRestore: _restoreBook,
                  ),
                ],
              ),
            ),
            if (showNavigation)
              Positioned(
                key: const ValueKey('main-liquid-glass-navigation'),
                left: OneSayChatNavigation.horizontalInset,
                right: OneSayChatNavigation.horizontalInset,
                bottom: inset + OneSayChatNavigation.bottomGap,
                height: OneSayChatNavigation.height,
                child: OneSayChatNavigation(
                  selectedIndex: _tab,
                  onTabSelected: (value) {
                    setState(() => _tab = value);
                    if (value == 1 && status == null) {
                      unawaited(_refreshCounts());
                    }
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

Future<void> _removeOutbox(Directory dir, String filename) async {
  final legacy = File('${dir.path}/$filename');
  if (!await legacy.exists()) return;
  try {
    final data = jsonDecode(await legacy.readAsString()) as Map;
    final turns = data['turns'] as List? ?? [data];
    for (final turn in turns.whereType<Map>()) {
      final path = turn['audio_path'];
      if (path is String &&
          File(path).parent.path == dir.path &&
          RegExp(r'^voice-[0-9a-f]{32}\.wav$').hasMatch(path.split('/').last)) {
        final audio = File(path);
        if (await audio.exists()) await audio.delete();
      }
    }
  } on FormatException {
    // The unreadable outbox is still retired.
  } on TypeError {
    // An old format without turn records has no attached files to remove.
  }
  await legacy.delete();
}

class OneSayChatNavigation extends StatelessWidget {
  static const horizontalInset = 18.0;
  static const bottomGap = 14.0;
  static const height = 64.0;

  final int selectedIndex;
  final ValueChanged<int> onTabSelected;

  const OneSayChatNavigation({
    super.key,
    required this.selectedIndex,
    required this.onTabSelected,
  });

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(32),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .12),
            blurRadius: 32,
            spreadRadius: -8,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(32),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 7, sigmaY: 7),
                  child: const ColoredBox(color: Color(0x26FFFFFF)),
                ),
              ),
            ),
          ),
          GlassTabBar.bottom(
            selectedIndex: selectedIndex,
            onTabSelected: onTabSelected,
            barHeight: height,
            horizontalPadding: 0,
            verticalPadding: 0,
            selectedIconColor: accent,
            selectedLabelColor: accent,
            tabs: const [
              GlassTab(icon: Icon(Icons.forum_outlined), label: '聊天'),
              GlassTab(icon: Icon(Icons.auto_stories_outlined), label: '书架'),
              GlassTab(icon: Icon(Icons.person_outline_rounded), label: '我的'),
            ],
          ),
        ],
      ),
    ),
  );
}

class FreeChatPage extends StatefulWidget {
  final String personId;
  final String bookTitle;
  final Map<String, TextEditingValue>? bookDrafts;
  final VoidCallback? onChooseBook;
  final bool active;
  final bool showNavigation;
  final VoidCallback? onChapterChanged;
  final VoiceCapture? voiceCapture;
  final RtcReplyPlayer? replyPlayer;
  final VoiceConnector? voiceConnector;
  final Api? client;
  final Future<Directory> Function()? documentsDirectory;
  const FreeChatPage({
    super.key,
    required this.personId,
    required this.bookTitle,
    this.bookDrafts,
    this.onChooseBook,
    this.active = true,
    this.showNavigation = true,
    this.onChapterChanged,
    this.voiceCapture,
    this.replyPlayer,
    this.voiceConnector,
    this.client,
    this.documentsDirectory,
    this.interview = false,
    this.companion = false,
    this.clock,
  });
  final bool interview;
  final bool companion;
  final DateTime Function()? clock;
  @override
  State<FreeChatPage> createState() => _FreeChatPageState();
}

class _FreeChatPageState extends State<FreeChatPage>
    with WidgetsBindingObserver {
  final input = TextEditingController();
  final inputFocus = FocusNode();
  bool textMode = false;
  final scroll = ScrollController();
  final _inputOverlay = GlobalKey();
  double _inputOverlayHeight = 62;
  bool _inputMeasurementScheduled = false;
  VoiceCapture? _recorder;
  late final _replyPlayer = widget.replyPlayer ?? RtcReplyPlayer();
  String? _speakingReply;
  String? _refreshingReply;
  String _streamText = '';
  int _replyEpoch = 0;
  bool _allowReplyAudioPrompt = false;
  bool _foreground = true;
  bool _awayMarked = false, _checkingReturn = false;
  Future<void> _awayWrite = Future.value();
  DateTime get _now => widget.clock?.call() ?? DateTime.now();
  String get _awayKey =>
      'companion-away-${sha256.convert(utf8.encode("${chatApi.base}\u0000${chatApi.token}"))}';
  VoiceCapture get recorder =>
      _recorder ??= widget.voiceCapture ?? DeviceVoiceCapture();
  Api get chatApi => widget.client ?? api;
  Future<Directory> documents() =>
      widget.documentsDirectory?.call() ?? getApplicationDocumentsDirectory();
  final _chapterHistory = <String, List<dynamic>>{};
  List<dynamic> get messages => _chapterHistory[_session] ?? const [];
  final _outbox = <Map<String, dynamic>>[];
  final _handingOffOriginals = <Map<String, dynamic>>{};
  Map<String, PendingVoiceUpload> _pendingOriginals = const {};
  Timer? _originalStatusTimer;
  bool _checkingOriginals = false;
  bool _deferredVoice = false;
  Map<String, dynamic>? _sendingTurn;
  String? _voiceAfter;
  Future<void> _outboxWrite = Future.value();
  String? voiceError;
  String? _sessionId;
  bool _switchingSession = false;
  bool _chapterLoading = false, _chapterLoadFailed = false;
  late final _sessionDrafts = widget.bookDrafts ?? <String, TextEditingValue>{};
  final _topicUpdates = ValueNotifier<List<BookRecord>>([]);
  List<BookRecord> get _topics => _topicUpdates.value;
  Future<void>? _topicsRequest;
  bool _topicsSheetOpen = false;
  String get _topicsPath => '/api/books/${widget.personId}/topics';
  String get _interviewPath => '/api/books/${widget.personId}/interview';
  Map<String, dynamic>? _interview;
  bool get _hiddenThemes => _interview?['version'] == 2;
  Map<String, dynamic>? _pendingInterviewRefresh;
  List<Map<String, dynamic>> get _visibleOutbox =>
      (widget.interview ? _outbox : _sessionOutbox).toList();
  BookRecord? get _topic =>
      _topics.where((row) => row['id'] == _session).firstOrNull;

  String get _session => _sessionId ?? widget.personId;
  String get _personPath => '/api/people/${widget.personId}';
  String _turnSession(Map<String, dynamic> turn) =>
      turn['session_id'] as String? ?? widget.personId;
  Iterable<Map<String, dynamic>> get _sessionOutbox =>
      _outbox.where((turn) => _turnSession(turn) == _session);
  bool _onlyOriginal(Map<String, dynamic> turn) =>
      turn['audio_message_id'] is String;
  bool get _chatBusy =>
      loading ||
      sending ||
      preparing ||
      starting ||
      recording ||
      isStopping ||
      _chapterLoading ||
      _switchingSession;
  bool get _canSend =>
      _sessionId != null && !_chatBusy && !_chapterLoadFailed && !_offline;
  bool get _canSubmitText =>
      _canSend &&
      !_sessionOutbox.any(
        (turn) => !_onlyOriginal(turn) && turn['after_request'] != null,
      );

  bool loading = true,
      sending = false,
      awaitingReply = false,
      preparing = false,
      starting = false,
      recording = false;
  bool cancelZone = false,
      pointerDown = false,
      finishRequested = false,
      isStopping = false;
  String partial = '';
  double amplitude = .05;
  Map<String, dynamic>? voiceCredential;
  Future<Map<String, dynamic>>? fetchingCredential;
  SttTranscriptAssembler transcript = SttTranscriptAssembler();
  String providerTask = '';
  DateTime? startedAt;
  Timer? recordLimit;
  StreamSubscription<List<int>>? micSub;
  VoiceWire? socket;
  Completer<bool>? socketReady;
  Future<bool>? connecting;
  final BytesBuilder awaitingNetwork = BytesBuilder(copy: true);
  bool socketStreaming = false, cancelledVoice = false;
  int voiceEpoch = 0;
  Completer<String>? socketFinal;
  IOSink? pcmSink;
  String? pcmPath;
  String? wavPath;
  bool voiceFailed = false;
  int _warmEpoch = 0;

  Future<void> _preconnectReplyAudio() async {
    if ((defaultTargetPlatform != TargetPlatform.android &&
            defaultTargetPlatform != TargetPlatform.iOS) ||
        !widget.active ||
        !_foreground ||
        !automaticReplyAudio.value ||
        _offline) {
      return;
    }
    final epoch = ++_warmEpoch;
    try {
      if (!await hasReplyConsent(widget.personId)) {
        return;
      }
      final voice = await ReplyVoice.load();
      if (mounted && epoch == _warmEpoch) {
        await _replyPlayer.preconnect(
          widget.personId,
          chatApi.call,
          voiceId: voice.name,
        );
      }
    } catch (_) {
      // A failed preconnection must not prevent chat or normal playback.
    }
  }

  void _releaseReplyRoom({Duration grace = Duration.zero}) {
    _warmEpoch++;
    _replyPlayer.releaseWarm(grace: grace);
  }

  void _replyAudioRevoked() {
    _releaseReplyRoom();
    unawaited(_stopReply());
  }

  void _replyVoiceChanged() => unawaited(_preconnectReplyAudio());

  void _automaticAudioChanged() {
    if (!automaticReplyAudio.value) {
      final turn = _sendingTurn;
      if (turn != null) turn['muted'] = true;
      unawaited(_stopReply());
      _releaseReplyRoom();
    } else {
      unawaited(_preconnectReplyAudio());
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    automaticReplyAudio.addListener(_automaticAudioChanged);
    replyAudioConsentRevision.addListener(_replyAudioRevoked);
    replyVoiceRevision.addListener(_replyVoiceChanged);
    load();
    unawaited(warmVoice());
    unawaited(_preconnectReplyAudio());
  }

  @override
  void dispose() {
    automaticReplyAudio.removeListener(_automaticAudioChanged);
    replyAudioConsentRevision.removeListener(_replyAudioRevoked);
    replyVoiceRevision.removeListener(_replyVoiceChanged);
    WidgetsBinding.instance.removeObserver(this);
    _replyEpoch++;
    unawaited(_replyPlayer.stop());
    _releaseReplyRoom();
    _replyPlayer.clearCache();
    _originalStatusTimer?.cancel();
    voiceEpoch++;
    cancelledVoice = true;
    recordLimit?.cancel();
    micSub?.cancel();
    socket?.close();
    pcmSink?.close();
    _recorder?.dispose();
    if (_sessionId != null) _saveTextDraft();
    inputFocus.dispose();
    input.dispose();
    scroll.dispose();
    _topicUpdates.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant FreeChatPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active && !widget.active) {
      inputFocus.unfocus();
      unawaited(_stopReply());
      _releaseReplyRoom(grace: const Duration(seconds: 10));
      if (pointerDown) unawaited(finishVoice(cancel: true));
    }
    if (!oldWidget.active && widget.active) {
      unawaited(_checkReturn());
      unawaited(_preconnectReplyAudio());
      unawaited(_syncOriginals());
      WidgetsBinding.instance.addPostFrameCallback((_) => _sendQueuedVoice());
    }
  }

  void openTextInput() {
    if (starting || recording) return;
    setState(() {
      textMode = true;
      voiceError = null;
    });
    inputFocus.requestFocus();
  }

  void openVoiceInput() {
    inputFocus.unfocus();
    setState(() => textMode = false);
  }

  Future<void> _rememberAway() async {
    final stamp = jsonEncode({
      'book_id': widget.personId,
      'left_at': _now.millisecondsSinceEpoch ~/ 1000,
      'request_id': const Uuid().v4().replaceAll('-', ''),
      'last_user_id': messages
          .where((m) => m['role'] == 'user')
          .lastOrNull?['id'],
    });
    final key = _awayKey;
    _awayWrite = _awayWrite
        .then(
          (_) => widget.companion
              ? secure.write(key: key, value: stamp)
              : secure.delete(key: key),
        )
        .catchError((Object _) {});
    await _awayWrite;
  }

  Future<void> _checkReturn() async {
    if (_checkingReturn || !mounted || !_foreground) return;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) return;
    _checkingReturn = true;
    final key = _awayKey;
    try {
      await _awayWrite;
      final raw = await secure.read(key: key);
      if (raw == null) return;
      final stamp = jsonDecode(raw) as Map;
      final left = stamp['left_at'] as int;
      final elapsed = _now.millisecondsSinceEpoch ~/ 1000 - left;
      if (!widget.companion ||
          stamp['book_id'] != widget.personId ||
          elapsed < 3600) {
        if (await secure.read(key: key) == raw) await secure.delete(key: key);
        return;
      }
      if (!widget.active ||
          loading ||
          !_canSend ||
          input.text.trim().isNotEmpty ||
          _sessionOutbox.isNotEmpty ||
          !await hasAiConsent(widget.personId)) {
        return;
      }
      final result = await chatApi.call('POST', '$_interviewPath/resume', {
        'request_id': stamp['request_id'],
        'left_at': left,
        'last_user_id': stamp['last_user_id'],
      });
      if (await secure.read(key: key) == raw) await secure.delete(key: key);
      if (!mounted ||
          !_foreground ||
          !widget.active ||
          _chatBusy ||
          _sessionOutbox.isNotEmpty) {
        return;
      }
      setState(() {
        _chapterHistory[_session] = List<dynamic>.from(
          result['messages'] as List,
        );
        _readInterview(result['interview']);
      });
      unawaited(_saveOpening());
      scrollToEnd();
    } catch (_) {
      // Keep the same return request ID for a safe retry; never interrupt ordinary chat.
    } finally {
      _checkingReturn = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if ((state == AppLifecycleState.paused ||
            state == AppLifecycleState.hidden ||
            state == AppLifecycleState.detached) &&
        !_awayMarked) {
      _awayMarked = true;
      unawaited(_rememberAway());
    }
    if (_foreground) {
      _awayMarked = false;
      unawaited(_checkReturn());
    }
    if (!_foreground) {
      unawaited(_stopReply());
      _releaseReplyRoom();
    } else {
      unawaited(_preconnectReplyAudio());
      unawaited(_syncOriginals());
      _sendQueuedVoice();
    }
    if (state != AppLifecycleState.resumed && (starting || recording)) {
      pointerDown = false;
      cancelZone = true;
      finishRequested = true;
      if (recording) unawaited(finishVoice(cancel: true));
    }
  }

  Future<File> pendingFile() async {
    final dir = await documents();
    return File('${dir.path}/book-outbox-${widget.personId}.json');
  }

  Future<void> persistOutbox() {
    final snapshot = _outbox.isEmpty ? null : jsonEncode({'turns': _outbox});
    final write = _outboxWrite.then((_) async {
      final file = await pendingFile();
      if (snapshot == null) {
        if (await file.exists()) await file.delete();
        return;
      }
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(snapshot, flush: true);
      await temp.rename(file.path);
    });
    _outboxWrite = write.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return write;
  }

  Future<void> savePending(Map<String, dynamic> value) async {
    if (!_outbox.contains(value)) _outbox.add(value);
    await persistOutbox();
    if (mounted) setState(() {});
  }

  Future<void> _removeTurn(
    Map<String, dynamic> turn, {
    bool discard = false,
  }) async {
    final index = _outbox.indexOf(turn);
    if (index < 0) return;
    _outbox.removeAt(index);
    final dependents = discard
        ? _outbox
              .where(
                (next) =>
                    next['queued'] == true &&
                    next['after_request'] == turn['request_id'],
              )
              .toList()
        : <Map<String, dynamic>>[];
    for (final next in dependents) {
      next['queued'] = false;
    }
    try {
      await persistOutbox();
    } catch (_) {
      _outbox.insert(index.clamp(0, _outbox.length), turn);
      for (final next in dependents) {
        next['queued'] = true;
      }
      rethrow;
    }
    final path = turn['audio_path'] as String?;
    if (path != null) {
      try {
        await File(path).delete();
      } on FileSystemException {
        // The audio file may already have been removed.
      }
    }
    if (mounted) setState(() {});
  }

  bool _waitingForEarlierTurn(Map<String, dynamic> turn) =>
      turn['after_request'] != null &&
      _outbox.any(
        (earlier) =>
            !_onlyOriginal(earlier) &&
            earlier['request_id'] == turn['after_request'],
      );

  void _sendQueuedVoice() {
    if (!mounted ||
        !widget.active ||
        !_foreground ||
        _chatBusy ||
        _chapterLoadFailed) {
      return;
    }
    final turn = _sessionOutbox
        .where(
          (turn) =>
              turn['queued'] == true &&
              turn['failed'] != true &&
              !_onlyOriginal(turn) &&
              !_waitingForEarlierTurn(turn),
        )
        .firstOrNull;
    if (turn != null) unawaited(_sendTurn(turn));
  }

  Future<void> retryTurn(Map<String, dynamic> turn) async {
    if (_onlyOriginal(turn)) {
      if (await consent(context, widget.personId)) await _queueOriginal(turn);
      return;
    }
    if (_chatBusy) {
      showError(context, '正在处理当前消息，请稍等');
      return;
    }
    if (_chapterLoadFailed) {
      showError(context, '请先重新加载本章');
      return;
    }
    if (_waitingForEarlierTurn(turn)) {
      showError(context, '请先重试上一条回复');
      return;
    }
    if (await consent(context, widget.personId)) await _sendTurn(turn);
  }

  bool _outboxLoaded = false;
  bool _offline = false;
  String? _topicLoadError;
  String get _openingCacheKey =>
      '${widget.interview ? 'interview-opening' : 'chat-opening'}:${widget.personId}';
  Future<void> _saveOpening() => chatApi.writeSnapshot(_openingCacheKey, {
    'active_id': _sessionId,
    'topics': _topicUpdates.value,
    'messages': messages,
    if (widget.interview) 'interview': _interview,
    if (_pendingInterviewRefresh != null)
      'pending_interview_refresh': _pendingInterviewRefresh,
  });

  void _readInterview(dynamic state) {
    if (state is Map && mounted) {
      final next = Map<String, dynamic>.from(state);
      if ((next['revision'] as int) >=
          (_interview?['revision'] as int? ?? -1)) {
        setState(() => _interview = next);
      }
    }
  }

  Future<void> load() async {
    if (_sessionId != null) _saveTextDraft();
    setState(() {
      loading = true;
      _topicLoadError = null;
    });
    var restored = false;
    try {
      final saved = await chatApi.readSnapshot(_openingCacheKey);
      if (saved is Map &&
          saved['active_id'] is String &&
          saved['messages'] is List &&
          mounted) {
        final topics = _decodeTopics(saved);
        final history = List<dynamic>.from(saved['messages'] as List);
        setState(() {
          _sessionId = saved['active_id'] as String;
          _topicUpdates.value = topics;
          _chapterHistory[_session] = history;
          loading = false;
          if (widget.interview) _offline = true;
        });
        restored = true;
        if (widget.interview) _readInterview(saved['interview']);
        if (saved['pending_interview_refresh'] is Map) {
          _pendingInterviewRefresh = Map<String, dynamic>.from(
            saved['pending_interview_refresh'] as Map,
          );
        }
      }
    } catch (_) {
      // Ignore obsolete snapshots and try the server.
    }
    try {
      if (!_outboxLoaded) {
        final file = await pendingFile();
        if (await file.exists()) {
          final value = jsonDecode(await file.readAsString());
          if (value is Map<String, dynamic>) {
            final turns = value['turns'] is List
                ? List<Map<String, dynamic>>.from(
                    (value['turns'] as List).map(
                      (x) => Map<String, dynamic>.from(x),
                    ),
                  )
                : [value];
            for (final turn in turns) {
              if (turn['submitted'] == true && turn['queued'] != true) {
                turn['failed'] = true;
              }
              _outbox.add(turn);
            }
            if (mounted) setState(() {});
          }
        }
        _outboxLoaded = true;
      }
      final state = widget.interview
          ? await chatApi
                .call('POST', _interviewPath)
                .timeout(
                  Platform.isAndroid
                      ? const Duration(seconds: 8)
                      : const Duration(seconds: 15),
                )
          : await chatApi.call('GET', _topicsPath);
      if (!mounted) return;
      _deferredVoice = state['deferred_voice_upload'] == true;
      final sid = state['active_id'] as String?;
      if (sid == null && !widget.interview) {
        setState(() {
          _topicUpdates.value = _decodeTopics(state);
          _sessionId = null;
          _offline = false;
          _topicLoadError = null;
        });
        return;
      }
      if (sid == null) throw Exception('聊天进度尚未准备好');
      final loaded = widget.interview
          ? List<dynamic>.from(state['messages'] as List)
          : await _activateTopic(sid);
      if (!mounted) return;
      _sessionId = sid;
      if (widget.interview) {
        _readInterview(state['interview']);
      } else {
        _topicUpdates.value = _decodeTopics(state);
      }
      _chapterHistory[sid] = loaded;
      _offline = false;
      unawaited(_saveOpening());
      input.value = _sessionDrafts[sid] ?? TextEditingValue.empty;
      scrollToEnd();
      try {
        await _retireLegacyOutbox();
      } on FileSystemException {
        // A separate outbox path prevents replay even if file cleanup needs a retry.
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _offline = restored;
          _topicLoadError = restored ? null : '暂时无法加载聊天，请联网后重试';
        });
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
    if (mounted && _topicLoadError == null && !_offline) {
      unawaited(_preconnectReplyAudio());
      unawaited(_syncOriginals());
      for (final turn in _outbox.where(_onlyOriginal).toList()) {
        unawaited(_queueOriginal(turn));
      }
      _sendQueuedVoice();
      unawaited(_checkReturn());
    }
  }

  List<BookRecord> _decodeTopics(dynamic state) => (state['topics'] as List)
      .map((row) => Map<String, dynamic>.from(row as Map))
      .toList();

  void _saveTextDraft() {
    _sessionDrafts[_session] = input.value.copyWith(composing: TextRange.empty);
  }

  Future<void> _retireLegacyOutbox() async {
    final dir = await documents();
    final oldRecording = File('${dir.path}/draft-${widget.personId}.wav');
    if (await oldRecording.exists()) await oldRecording.delete();
    await _removeOutbox(dir, 'pending-turn-${widget.personId}.json');
    await _removeOutbox(dir, 'pending-turn-${widget.personId}.json.tmp');
  }

  Future<List<dynamic>> _messagesFor(String session) async {
    final p = await chatApi.call('GET', '$_personPath?session_id=$session');
    if (widget.interview && session == _session) {
      _readInterview(p['interview']);
    }
    return List<dynamic>.from(p['messages']);
  }

  Future<List<dynamic>> _activateTopic(String session) async {
    final result = await chatApi
        .call('PUT', '$_topicsPath/$session/active?include_messages=true')
        .timeout(
          Platform.isAndroid
              ? const Duration(seconds: 8)
              : const Duration(minutes: 4),
        );
    if (result['messages'] case final List messages) {
      return List<dynamic>.of(messages);
    }
    return _messagesFor(session);
  }

  Future<void> _refreshSentTurn(Map<String, dynamic> turn) async {
    final session = _turnSession(turn);
    final loaded = await _messagesFor(session);
    if (!loaded.any((message) => message['request_id'] == turn['request_id'])) {
      throw Exception('暂时无法更新聊天记录，请重试');
    }
    await _removeTurn(turn);
    if (!mounted || session != _session) return;
    setState(() {
      _chapterHistory[session] = loaded;
      _streamText = '';
      awaitingReply = false;
    });
    unawaited(_saveOpening());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (scroll.hasClients) {
        scroll.animateTo(
          scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _nextChapter() async {
    if (!_canSend) return;
    if (_interview?['can_advance'] != true) {
      final skip = await showChatSheet<bool>(
        context: context,
        builder: (sheet) => ChatSheetDialog(
          title: const Text('提前进入下一章节？'),
          content: Text(
            (_interview?['characters'] as int? ?? 0) >= 30
                ? '已记录的有效内容达到 30 字，提前跳过后会按现有内容自动整理成章。'
                : '已记录的内容会保留。有效内容不足 30 字，暂不生成章节。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(sheet, false),
              child: const Text('继续这段'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(sheet, true),
              child: const Text('保留并跳过'),
            ),
          ],
        ),
      );
      if (skip != true || !mounted || !_canSend) return;
    }
    await sendText(interviewAction: 'next', nextChapter: true);
  }

  Future<void> _showInterviewProgress() => showChatSheet<void>(
    context: context,
    builder: (sheet) => ChatSheetDialog(
      title: Text('已记录 ${_interview?['characters'] ?? 0} 字'),
      content: Text(
        _interview?['can_advance'] == true
            ? '这段素材已经达到成章条件。'
            : '成章至少需要 ${_interview?['minimum_characters'] ?? 301} 字，并有完整的故事经过或生活细节。提前进入下一章节时，有效内容达到 30 字也会按现有内容整理。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(sheet),
          child: const Text('知道了'),
        ),
      ],
    ),
  );

  Future<void> sendText({
    String? interviewAction,
    bool nextChapter = false,
  }) async {
    final text = nextChapter
        ? '下一章节'
        : switch (interviewAction) {
            'begin' => '开始访谈',
            'skip' => '跳过这题',
            'next' => '下一题',
            _ => input.text.trim(),
          };
    if (text.isEmpty || !_canSubmitText) {
      return;
    }
    setState(() => preparing = true);
    try {
      unawaited(_stopReply());
      if (!await consent(context, widget.personId) || !mounted) return;
      final turn = <String, dynamic>{
        'request_id': const Uuid().v4().replaceAll('-', ''),
        'session_id': _session,
        'text': text,
        if (interviewAction != null) ...{
          'interview_action': interviewAction,
          'interview_revision': _interview!['revision'],
        },
      };
      await savePending(turn);
      if (!mounted) return;
      if (interviewAction == null) input.clear();
      setState(() => preparing = false);
      await _sendTurn(turn);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => preparing = false);
    }
  }

  Future<void> editTurn(Map<String, dynamic> turn) async {
    final editor = TextEditingController(text: turn['text'] as String? ?? '');
    final action = await showChatSheet<String>(
      context: context,
      builder: (c) => ChatSheetDialog(
        title: const Text('处理未完成的消息'),
        content: TextField(
          controller: editor,
          minLines: 2,
          maxLines: 6,
          decoration: const InputDecoration(hintText: '补写这段录音的文字'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, 'delete'),
            child: const Text('移除本地草稿'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, 'save'),
            child: const Text('保存文字'),
          ),
        ],
      ),
    );
    if (action == 'save' && editor.text.trim().isNotEmpty) {
      final saved =
          turn['submitted'] == true ||
          messages.any((m) => m['request_id'] == turn['request_id']);
      if (saved) {
        if (mounted) showError(context, '这条消息已发出，请直接重试回复');
      } else {
        turn['text'] = editor.text.trim();
        final id = const Uuid().v4().replaceAll('-', '');
        for (final next in _outbox.where(
          (next) => next['after_request'] == turn['request_id'],
        )) {
          next['after_request'] = id;
        }
        turn['request_id'] = id;
        await persistOutbox();
      }
    } else if (action == 'delete') {
      await _removeTurn(turn, discard: true);
    }
    editor.dispose();
    if (mounted) setState(() {});
  }

  Future<void> _sendTurn(Map<String, dynamic> turn) async {
    if (!mounted || sending || _waitingForEarlierTurn(turn)) return;
    if (!await hasAiConsent(widget.personId)) {
      // Restored recordings wait for explicit approval on retry.
      if (turn['queued'] == true || !mounted) return;
      if (!await consent(context, widget.personId)) return;
    }
    if (!mounted || sending || _waitingForEarlierTurn(turn)) return;
    unawaited(_stopReply());
    _sendingTurn = turn;
    setState(() => sending = true);
    RtcReplayMessage? replyToPlay;
    final replayMessage = Completer<RtcReplayMessage?>();
    StreamController<int>? speech;
    var streamedSpeech = false;
    try {
      var text = (turn['text'] as String? ?? '').trim();
      final path = turn['audio_path'] as String?;
      String? encoded;
      String? payloadHash;
      if (path != null) {
        final audio = await File(path).readAsBytes();
        if (text.isEmpty) {
          final transcribe = chatApi.call('POST', '/api/transcribe', {
            'audio_base64': base64Encode(audio),
          });
          // The fallback service streams the recording at roughly real-time pace.
          // Allow for its duration, plus connection and recognition overhead.
          final transcribed =
              await (defaultTargetPlatform == TargetPlatform.android
                  ? transcribe.timeout(
                      Duration(seconds: 35 + audio.length ~/ (16000 * 2)),
                      onTimeout: () => throw Exception('语音转写超时，录音已保留，可点重试。'),
                    )
                  : transcribe);
          text = (transcribed['text'] as String? ?? '').trim();
          if (text.isEmpty) throw Exception('没有识别到文字，录音已保留，请重试');
          turn['text'] = text;
        }
        // Freeze the transport before the first request. A retried old turn
        // must keep its original audio contract even after a server upgrade.
        final deferred =
            turn['deferred_audio'] == true ||
            (turn['submitted'] != true &&
                defaultTargetPlatform == TargetPlatform.android &&
                _deferredVoice);
        if (deferred) {
          turn['deferred_audio'] = true;
          final digest = BytesBuilder(copy: false)
            ..add(utf8.encode(text))
            ..addByte(0)
            ..add(audio);
          payloadHash = sha256.convert(digest.takeBytes()).toString();
        } else {
          encoded = base64Encode(audio);
        }
      }
      final body = <String, dynamic>{
        'request_id': turn['request_id'],
        'session_id': _turnSession(turn),
        'text': text,
        'audio_base64': ?encoded,
        'payload_hash': ?payloadHash,
        if (turn['interview_action'] != null) ...{
          'interview_action': turn['interview_action'],
          'interview_revision': turn['interview_revision'],
        },
      };
      turn['submitted'] = true;
      await savePending(turn);
      if (mounted) setState(() => awaitingReply = true);
      scrollToEnd();
      final requestId = turn['request_id'] as String;
      final streamSpeech = turn['muted'] != true && await _canStreamSpeech();
      if (streamSpeech && turn['muted'] != true) {
        speech = StreamController<int>();
        unawaited(
          _playStreamSpeech(requestId, speech.stream, replayMessage.future),
        );
      }
      Map<String, dynamic>? reply;
      await for (final event in chatApi.streamTurn(
        '$_personPath/${payloadHash == null ? 'turns' : 'voice-turns'}',
        body,
        speak: speech != null,
      )) {
        switch (event['type']) {
          case 'delta':
            if (mounted && _turnSession(turn) == _session) {
              final follow =
                  !scroll.hasClients || scroll.position.extentAfter <= 36;
              setState(() => _streamText += event['text'] as String);
              if (follow) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted && scroll.hasClients) {
                    scroll.jumpTo(scroll.position.maxScrollExtent);
                  }
                });
              }
            }
          case 'speech':
            streamedSpeech = true;
            if (turn['muted'] != true) speech?.add(event['segment'] as int);
          case 'error':
            if (event['status'] case final int status) {
              throw ApiFailure(status, event['detail'] as String);
            }
            throw Exception(event['detail']);
          case 'done':
            reply = event;
        }
        if (reply != null) break;
      }
      if (reply == null) throw Exception('AI 回复未完成，请点击重试。');
      if (widget.interview && _turnSession(turn) == _session) {
        _readInterview(reply['interview']);
      }
      if (speech != null) unawaited(speech.close());
      if (!streamedSpeech && speech != null) unawaited(_stopReply());
      final assistantId = reply['assistant_id'] as String?;
      final assistantText = reply['text'] as String?;
      final saved = assistantId != null && assistantText != null
          ? (id: assistantId, text: assistantText)
          : null;
      replayMessage.complete(saved);
      if (mounted && _speakingReply == requestId) {
        setState(() => _speakingReply = assistantId);
      }
      if ((widget.interview || Platform.isAndroid || payloadHash != null) &&
          saved != null &&
          reply['user_id'] is String) {
        // The stream's done event is sent after the server commits both messages.
        // Render that acknowledgement immediately instead of waiting for another GET.
        final session = _turnSession(turn);
        final history = List<dynamic>.of(_chapterHistory[session] ?? const []);
        for (final message in [
          {
            'id': reply['user_id'],
            'role': 'user',
            'text': text,
            'request_id': turn['request_id'],
            'has_audio': path != null,
          },
          {'id': saved.id, 'role': 'assistant', 'text': saved.text},
        ]) {
          if (!history.any((old) => old['id'] == message['id'])) {
            history.add(message);
          }
        }
        _chapterHistory[session] = history;
        if (payloadHash != null) {
          turn['audio_message_id'] = reply['user_id'];
          unawaited(_queueOriginal(turn));
        } else {
          await _removeTurn(turn);
        }
        if (mounted) {
          setState(() {
            _streamText = '';
            awaitingReply = false;
          });
        }
        unawaited(_saveOpening());
      } else {
        if (payloadHash != null) throw StateError('语音消息确认不完整，请重试');
        await _refreshSentTurn(turn);
      }
      if (widget.interview && _turnSession(turn) != _session && mounted) {
        final history = await _messagesFor(_session);
        if (mounted) setState(() => _chapterHistory[_session] = history);
        unawaited(_saveOpening());
      }
      if (!streamedSpeech &&
          turn['muted'] != true &&
          _turnSession(turn) == _session) {
        replyToPlay = saved;
      }
    } catch (e) {
      if (speech != null) {
        unawaited(_stopReply());
        if (!speech.isClosed) unawaited(speech.close());
      }
      if (widget.interview &&
          turn['interview_action'] != null &&
          e is ApiFailure &&
          e.status == 409) {
        await _removeTurn(turn);
        if (mounted) {
          showError(context, e);
          await load();
        }
        return;
      }
      turn['failed'] = true;
      try {
        await persistOutbox();
        if (mounted) showError(context, errorText(e));
      } on FileSystemException {
        if (mounted) showError(context, '暂时无法保存发送状态，请重试');
      }
    } finally {
      if (!replayMessage.isCompleted) replayMessage.complete(null);
      _sendingTurn = null;
      if (mounted) {
        setState(() {
          sending = false;
          awaitingReply = false;
          _streamText = '';
        });
      }
    }
    if (replyToPlay != null && mounted) unawaited(_playReply(replyToPlay));
    _sendQueuedVoice();
  }

  Future<void> _queueOriginal(Map<String, dynamic> turn) async {
    if (!_handingOffOriginals.add(turn)) return;
    try {
      await persistOutbox();
      if (!await hasAiConsent(widget.personId)) {
        return;
      }
      final id = turn['audio_message_id'] as String;
      final path = await chatApi.enqueueVoiceUpload(
        book: widget.personId,
        message: id,
        request: turn['request_id'] as String,
        path: turn['audio_path'] as String,
      );
      if (mounted) {
        setState(
          () => _pendingOriginals = {
            ..._pendingOriginals,
            id: (path: path, blocked: false),
          },
        );
        _originalStatusTimer?.cancel();
        _originalStatusTimer = Timer(
          const Duration(seconds: 4),
          _syncOriginals,
        );
      }
      await _removeTurn(turn);
    } catch (_) {
      if (mounted) showError(context, '回复已送达，原声已保留，请重试上传');
    } finally {
      _handingOffOriginals.remove(turn);
    }
  }

  Future<void> _syncOriginals() async {
    if (defaultTargetPlatform != TargetPlatform.android ||
        !mounted ||
        !widget.active ||
        !_foreground ||
        _checkingOriginals) {
      return;
    }
    _originalStatusTimer?.cancel();
    _checkingOriginals = true;
    try {
      final pending = await chatApi.pendingVoiceUploads(widget.personId);
      if (!mounted) return;
      final uploaded = _pendingOriginals.keys
          .where((id) => !pending.containsKey(id))
          .toSet();
      setState(() {
        _pendingOriginals = pending;
        if (uploaded.isNotEmpty) {
          _chapterHistory.updateAll(
            (_, history) => [
              for (final message in history)
                if (uploaded.contains(message['id']))
                  {...(message as Map), 'has_audio': true}
                else
                  message,
            ],
          );
        }
      });
      if (uploaded.isNotEmpty) unawaited(_saveOpening());
    } catch (_) {
      // Pending files stay in the system queue when the foreground cannot query it.
    } finally {
      _checkingOriginals = false;
      if (mounted &&
          widget.active &&
          _foreground &&
          _pendingOriginals.values.any((upload) => !upload.blocked)) {
        _originalStatusTimer = Timer(
          const Duration(seconds: 4),
          _syncOriginals,
        );
      }
    }
  }

  Future<bool> _canStreamSpeech() async {
    if (!(Platform.isIOS || Platform.isAndroid || widget.replyPlayer != null) ||
        !_foreground ||
        !widget.active ||
        !mounted) {
      return false;
    }
    final epoch = _replyEpoch;
    try {
      if (!automaticReplyAudio.value) return false;
      final allowed = await _ensureReplyAudio(prompt: Platform.isAndroid);
      return allowed &&
          mounted &&
          widget.active &&
          _foreground &&
          epoch == _replyEpoch;
    } catch (_) {
      return false;
    }
  }

  Future<void> _playStreamSpeech(
    String requestId,
    Stream<int> segments,
    Future<RtcReplayMessage?> replayMessage,
  ) async {
    final epoch = ++_replyEpoch;
    setState(() => _speakingReply = requestId);
    try {
      final voice = await ReplyVoice.load();
      if (!mounted || epoch != _replyEpoch) return;
      await _replyPlayer.playTurn(
        widget.personId,
        requestId,
        segments,
        chatApi.call,
        voiceId: voice.name,
        replayMessage: replayMessage,
      );
    } catch (_) {
      // Streaming text continues if voice is unavailable.
    } finally {
      if (mounted && epoch == _replyEpoch) {
        setState(() => _speakingReply = null);
      }
    }
  }

  Future<void> _stopReply() {
    _replyEpoch++;
    if (mounted && _speakingReply != null) {
      setState(() => _speakingReply = null);
    }
    return _replyPlayer.stop();
  }

  Future<bool> _ensureReplyAudio({required bool prompt}) async {
    if (await hasReplyConsent(widget.personId)) return true;
    if (!prompt || !mounted || _allowReplyAudioPrompt) return false;
    _allowReplyAudioPrompt = true;
    try {
      final allowed = await showChatSheet<bool>(
        context: context,
        builder: (sheet) => ChatSheetDialog(
          title: const Text('开启 AI 语音回复'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '开启后，AI 回复文字（可能包含回忆录中的个人信息）会发送给火山引擎合成语音，并通过实时音频房间播报。'
                '请先取得讲述者同意。可在「我的 → 设置 → AI 数据授权」撤回。',
              ),
              TextButton(
                onPressed: () =>
                    AppLegalUrls.open(context, AppLegalUrls.privacy),
                child: const Text('查看隐私政策'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(sheet, false),
              child: const Text('暂不开启'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(sheet, true),
              child: const Text('同意并播放'),
            ),
          ],
        ),
      );
      if (allowed != true) {
        if (Platform.isAndroid) await saveAutomaticReplyAudio(false);
        return false;
      }
      await secure.write(key: localReplyConsentKey, value: 'yes');
      unawaited(_preconnectReplyAudio());
      return true;
    } finally {
      _allowReplyAudioPrompt = false;
    }
  }

  Future<void> _playReply(
    RtcReplayMessage message, {
    bool requested = false,
  }) async {
    final id = message.id;
    if (!(Platform.isIOS || Platform.isAndroid || widget.replyPlayer != null) ||
        !widget.active ||
        !_foreground ||
        recording ||
        starting ||
        _allowReplyAudioPrompt) {
      return;
    }
    if (requested && _speakingReply == id) {
      await _stopReply();
      return;
    }
    final epoch = ++_replyEpoch;
    try {
      if (!requested && !automaticReplyAudio.value) {
        return;
      }
      if (!await _ensureReplyAudio(prompt: requested)) return;
      final voice = await ReplyVoice.load();
      if (!mounted || epoch != _replyEpoch || !widget.active || !_foreground) {
        return;
      }
      setState(() => _speakingReply = id);
      await _replyPlayer.play(message, chatApi.call, voiceId: voice.name);
    } catch (error) {
      if (requested && mounted && epoch == _replyEpoch) {
        showError(
          context,
          error is RtcReplyFailure ? error : '语音暂时无法播放，可以阅读文字回复',
        );
      }
    } finally {
      if (mounted && epoch == _replyEpoch && _speakingReply == id) {
        setState(() => _speakingReply = null);
      }
    }
  }

  Future<Map<String, dynamic>> getVoiceCredential() async {
    final cached = voiceCredential;
    if (cached != null &&
        (cached['expires_at'] as num) * 1000 >
            DateTime.now().millisecondsSinceEpoch + 65000) {
      return cached;
    }
    return fetchingCredential ??= () async {
      try {
        final value = Map<String, dynamic>.from(
          await chatApi.call('POST', '/api/voice/token'),
        );
        voiceCredential = value;
        return value;
      } finally {
        fetchingCredential = null;
      }
    }();
  }

  Future<void> warmVoice() async {
    if (!await hasAiConsent(widget.personId)) {
      return;
    }
    try {
      await getVoiceCredential();
    } catch (_) {
      /* Retry on the next press. */
    }
  }

  void sendPcm(List<int> bytes) {
    final ws = socket;
    if (ws == null || voiceFailed) return;
    try {
      for (var offset = 0; offset < bytes.length; offset += 16000) {
        final end = (offset + 16000).clamp(0, bytes.length);
        ws.add(bytes.sublist(offset, end));
      }
    } catch (_) {
      voiceFailed = true;
    }
  }

  Future<bool> connectVoice(int epoch) async {
    final readySignal = Completer<bool>();
    final finalSignal = Completer<String>();
    socketReady = readySignal;
    socketFinal = finalSignal;
    try {
      final credential = await getVoiceCredential();
      if (cancelledVoice || epoch != voiceEpoch) return false;
      final ws = await (widget.voiceConnector ?? connectDirectVoice)(
        'wss://dashscope.aliyuncs.com/api-ws/v1/inference/',
        {'Authorization': 'Bearer ${credential['token']}'},
      );
      if (cancelledVoice || epoch != voiceEpoch) {
        await ws.close();
        return false;
      }
      socket = ws;
      ws.events.listen(
        (data) {
          if (epoch != voiceEpoch || data is! String) return;
          try {
            final event = jsonDecode(data) as Map<String, dynamic>;
            final type = event['header']?['event'];
            if (type == 'task-started' && !readySignal.isCompleted) {
              readySignal.complete(true);
            }
            if (type == 'result-generated') {
              final sentence =
                  event['payload']?['output']?['sentence']
                      as Map<String, dynamic>?;
              if (sentence != null) {
                final text = transcript.update(
                  rawText: sentence['text'] as String? ?? '',
                  sentenceId: sentence['sentence_id'] as int?,
                  sentenceEnd: sentence['sentence_end'] == true,
                  heartbeat: sentence['heartbeat'] == true,
                );
                if (mounted) setState(() => partial = text);
              }
            }
            if (type == 'task-finished' && !finalSignal.isCompleted) {
              finalSignal.complete(transcript.text);
            }
            if (type == 'task-failed') {
              voiceFailed = true;
              if (!readySignal.isCompleted) readySignal.complete(false);
              if (!finalSignal.isCompleted) finalSignal.complete('');
            }
          } catch (_) {
            voiceFailed = true;
          }
        },
        onError: (_) {
          if (epoch != voiceEpoch) return;
          voiceFailed = true;
          if (!readySignal.isCompleted) readySignal.complete(false);
          if (!finalSignal.isCompleted) finalSignal.complete('');
        },
        onDone: () {
          if (epoch != voiceEpoch) return;
          if (!readySignal.isCompleted) readySignal.complete(false);
          if (!finalSignal.isCompleted) {
            voiceFailed = true;
            finalSignal.complete('');
          }
        },
      );
      ws.add(
        jsonEncode({
          'header': {
            'action': 'run-task',
            'task_id': providerTask,
            'streaming': 'duplex',
          },
          'payload': {
            'task_group': 'audio',
            'task': 'asr',
            'function': 'recognition',
            'model': 'fun-asr-realtime',
            'parameters': {'sample_rate': 16000, 'format': 'pcm'},
            'input': {},
          },
        }),
      );
      final ready = await readySignal.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () => false,
      );
      if (!ready || cancelledVoice || epoch != voiceEpoch) {
        if (epoch == voiceEpoch) voiceFailed = true;
        await ws.close();
        return false;
      }
      final buffered = awaitingNetwork.takeBytes();
      sendPcm(buffered);
      socketStreaming = true;
      return !voiceFailed;
    } catch (_) {
      if (epoch == voiceEpoch) voiceFailed = true;
      return false;
    }
  }

  Future<void> startVoice() async {
    if (!widget.active || textMode || _sessionId == null) return;
    if (loading ||
        preparing ||
        starting ||
        recording ||
        isStopping ||
        _chapterLoading ||
        _switchingSession ||
        (sending && !awaitingReply)) {
      showError(context, '正在处理当前消息，请稍等');
      return;
    }
    if (_chapterLoadFailed) {
      showError(context, '请先重新加载本章');
      return;
    }
    final speakingTurn = _sendingTurn;
    _voiceAfter =
        _sessionOutbox
                .where(
                  (turn) =>
                      !_onlyOriginal(turn) &&
                      (turn['after_request'] != null ||
                          identical(turn, speakingTurn)),
                )
                .lastOrNull?['request_id']
            as String?;
    if (speakingTurn != null) speakingTurn['muted'] = true;
    final releaseAudio = _stopReply();
    setState(() {
      starting = true;
      voiceError = null;
      partial = '';
    });
    HapticFeedback.mediumImpact();
    pointerDown = true;
    finishRequested = false;
    cancelZone = false;
    cancelledVoice = false;
    if (!await hasAiConsent(widget.personId)) {
      if (mounted) await consent(context, widget.personId);
      pointerDown = false;
      if (mounted) setState(() => starting = false);
      unawaited(warmVoice());
      if (mounted) showError(context, '请再长按一次开始录音');
      return;
    }
    if (!pointerDown || finishRequested || !mounted) {
      if (mounted) setState(() => starting = false);
      return;
    }
    setState(() {
      starting = true;
      partial = '';
      voiceFailed = false;
      transcript = SttTranscriptAssembler();
      providerTask = const Uuid().v4().replaceAll('-', '');
    });
    try {
      await releaseAudio;
      if (!pointerDown || finishRequested || !mounted) return;
      if (!await recorder.hasPermission()) {
        pointerDown = false;
        throw Exception('请允许麦克风权限，然后重新按住说话');
      }
      if (!pointerDown || finishRequested) return;
      final dir = await documents();
      final id = const Uuid().v4().replaceAll('-', '');
      pcmPath = '${dir.path}/voice-$id.pcm';
      wavPath = '${dir.path}/voice-$id.wav';
      pcmSink = File(pcmPath!).openWrite();
      awaitingNetwork.clear();
      socketStreaming = false;
      final stream = await recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
        ),
      );
      startedAt = DateTime.now();
      micSub = stream.listen(
        (bytes) {
          pcmSink?.add(bytes);
          double energy = 0;
          for (var i = 0; i + 1 < bytes.length; i += 2) {
            var sample = bytes[i] | (bytes[i + 1] << 8);
            if (sample >= 32768) sample -= 65536;
            energy += sample * sample;
          }
          if (mounted && bytes.length >= 2) {
            setState(
              () => amplitude = (math.sqrt(energy / (bytes.length ~/ 2)) / 3200)
                  .clamp(.04, 1),
            );
          }
          if (socketStreaming) {
            sendPcm(bytes);
          } else {
            awaitingNetwork.add(bytes);
          }
        },
        onError: (_) {
          voiceFailed = true;
        },
      );
      if (!mounted) return;
      setState(() {
        recording = true;
        starting = false;
      });
      // Capture starts before the connection so the beginning is retained and sent.
      final epoch = ++voiceEpoch;
      connecting = connectVoice(epoch);
      recordLimit = Timer(const Duration(seconds: 59), () {
        if (recording) unawaited(finishVoice(cancel: false));
      });
      if (!pointerDown || finishRequested) {
        await finishVoice(cancel: cancelZone);
      }
    } catch (e) {
      await pcmSink?.close();
      pcmSink = null;
      if (pcmPath != null) {
        final file = File(pcmPath!);
        if (await file.exists()) await file.delete();
      }
      if (mounted) setState(() => voiceError = '无法开始录音：${errorText(e)}');
    } finally {
      if (mounted && !recording) setState(() => starting = false);
    }
  }

  Future<void> finishVoice({required bool cancel}) async {
    pointerDown = false;
    finishRequested = true;
    if (starting && !recording) {
      cancelZone = cancel;
      return;
    }
    if (!recording || isStopping) return;
    setState(() => isStopping = true);
    recordLimit?.cancel();
    try {
      await micSub?.cancel();
      micSub = null;
      await recorder.stop().timeout(const Duration(seconds: 3));
      await pcmSink?.flush();
      await pcmSink?.close();
      pcmSink = null;
      final tooShort =
          startedAt == null ||
          DateTime.now().difference(startedAt!) <
              const Duration(milliseconds: 600);
      final pcm = pcmPath == null ? null : File(pcmPath!);
      if (cancel || tooShort || pcm == null || !await pcm.exists()) {
        cancelledVoice = true;
        if (pcm != null && await pcm.exists()) await pcm.delete();
        if (!cancel && mounted) showError(context, '长按说话，松开发送');
        return;
      }
      final bytes = await pcm.readAsBytes();
      await pcm.delete();
      if (bytes.isEmpty) throw Exception('没有录到声音，请重试');
      await File(wavPath!).writeAsBytes(pcmToWav(bytes), flush: true);
      final turn = <String, dynamic>{
        'request_id': const Uuid().v4().replaceAll('-', ''),
        'session_id': _session,
        'text': '',
        'audio_path': wavPath!,
        if (_voiceAfter != null) 'after_request': _voiceAfter,
      };
      await savePending(turn);
      var text = '';
      final android = defaultTargetPlatform == TargetPlatform.android;
      final connection = connecting ?? Future.value(false);
      final connected = await (android
          ? connection.timeout(
              const Duration(seconds: 2),
              onTimeout: () => false,
            )
          : connection);
      if (android && !connected) voiceFailed = true;
      if (connected && !voiceFailed) {
        try {
          socket?.add(
            jsonEncode({
              'header': {
                'action': 'finish-task',
                'task_id': providerTask,
                'streaming': 'duplex',
              },
              'payload': {'input': {}},
            }),
          );
          text = (await socketFinal!.future.timeout(
            Duration(seconds: android ? 3 : 5),
            onTimeout: () {
              if (!android) return transcript.text;
              voiceFailed = true;
              return '';
            },
          )).trim();
        } catch (_) {
          voiceFailed = true;
        }
      }
      if (text.isEmpty && !(android && voiceFailed)) {
        if (mounted) {
          setState(
            () => voiceError = voiceFailed ? '语音连接中断，录音已保留。' : '没有识别到内容，录音已保留。',
          );
        }
      } else {
        turn['text'] = text;
        turn['queued'] = true;
        await savePending(turn);
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      cancelledVoice = true;
      voiceEpoch++;
      final closed = socket?.close();
      socket = null;
      if (closed != null) unawaited(closed.catchError((Object _) {}));
      awaitingNetwork.clear();
      socketStreaming = false;
      isStopping = false;
      if (mounted) {
        setState(() {
          recording = false;
          starting = false;
          cancelZone = false;
          partial = '';
        });
      }
      _sendQueuedVoice();
    }
  }

  void scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (scroll.hasClients) {
        scroll.animateTo(
          scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _switchTopic(String target) async {
    if (_chatBusy || (target == _session && !_chapterLoadFailed)) return;
    final alreadyVisited = _chapterHistory.containsKey(target);
    if (target != _session) {
      unawaited(_stopReply());
      inputFocus.unfocus();
      _saveTextDraft();
      input.value = _sessionDrafts[target] ?? TextEditingValue.empty;
    }
    setState(() {
      _sessionId = target;
      _chapterLoading = true;
      _chapterLoadFailed = false;
      voiceError = null;
    });
    if (alreadyVisited) scrollToEnd();
    try {
      final loaded = await _activateTopic(
        target,
      ).timeout(const Duration(seconds: 12));
      if (!mounted) return;
      setState(() => _chapterHistory[target] = loaded);
      if (!alreadyVisited) scrollToEnd();
    } catch (_) {
      if (mounted) setState(() => _chapterLoadFailed = true);
    } finally {
      if (mounted) setState(() => _chapterLoading = false);
    }
    _sendQueuedVoice();
  }

  Future<void> _openTopics() async {
    if (_chatBusy || _topicsSheetOpen) return;
    inputFocus.unfocus();
    _topicsSheetOpen = true;
    final selection = showChatSheet<String>(
      context: context,
      expanded: true,
      builder: (sheet) {
        final directoryScroll = PrimaryScrollController.of(sheet);
        return ValueListenableBuilder(
          valueListenable: _topicUpdates,
          builder: (_, topics, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ListTile(
                title: const Text('章节目录'),
                trailing: IconButton(
                  tooltip: '关闭',
                  onPressed: () => Navigator.pop(sheet),
                  icon: const Icon(Icons.close_rounded),
                ),
              ),
              Wrap(
                spacing: 8,
                children: [
                  TextButton.icon(
                    onPressed: () => Navigator.pop(sheet, 'draft'),
                    icon: const Icon(Icons.edit_note_rounded),
                    label: const Text('整理本章'),
                  ),
                  if (_topic?['chapter_id'] != null)
                    TextButton(
                      onPressed: () => Navigator.pop(sheet, 'read'),
                      child: const Text('阅读正文'),
                    ),
                ],
              ),
              Expanded(
                child: RawScrollbar(
                  key: const ValueKey('chapter-directory-scrollbar'),
                  controller: directoryScroll,
                  thumbVisibility: true,
                  trackVisibility: true,
                  interactive: true,
                  scrollbarOrientation: ScrollbarOrientation.right,
                  thickness: 6,
                  radius: const Radius.circular(4),
                  mainAxisMargin: 4,
                  crossAxisMargin: 1,
                  thumbColor: const Color(0xff947455),
                  trackColor: const Color(0x26947455),
                  child: ListView.builder(
                    controller: directoryScroll,
                    padding: const EdgeInsets.only(right: 14),
                    itemCount: topics.length,
                    itemBuilder: (context, index) {
                      final topic = topics[index];
                      return ListTile(
                        selected: topic['id'] == _session,
                        selectedColor: chatAccent,
                        selectedTileColor: chatAccent.withValues(alpha: .08),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        leading: CircleAvatar(
                          backgroundColor: chatAccent.withValues(alpha: .13),
                          child: Text('${topic['number']}'),
                        ),
                        title: Text(topic['title'] as String),
                        subtitle: Text(
                          "${topic['theme']} · ${topic['character_count']} 字${topic['draft_id'] == null ? '' : ' · 待核对'}",
                        ),
                        onTap: () =>
                            Navigator.pop(sheet, topic['id'] as String),
                      );
                    },
                  ),
                ),
              ),
              if (_sessionOutbox.isNotEmpty)
                TextButton(
                  onPressed: () => Navigator.pop(sheet, 'outbox'),
                  child: const Text('当前章节未完成的输入'),
                ),
            ],
          ),
        );
      },
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _topicsSheetOpen) {
        unawaited(_refreshTopics().catchError((_) {}));
      }
    });
    final tid = await selection.whenComplete(() => _topicsSheetOpen = false);
    if (!mounted || tid == null) return;
    if (tid == 'draft') {
      await _reviewDraft();
    } else if (tid == 'read') {
      try {
        await openBookChapter(
          context,
          chatApi,
          widget.personId,
          _topic!['chapter_id'] as String,
          onSaved: widget.onChapterChanged,
        );
        if (mounted) await _refreshTopics(afterEdit: true);
      } catch (e) {
        if (mounted) showError(context, e);
      }
    } else if (tid == 'outbox') {
      await _openChapterOutbox();
    } else {
      await _switchTopic(tid);
    }
  }

  Future<void> _refreshTopics({bool afterEdit = false}) async {
    final pending = _topicsRequest;
    if (pending != null) {
      if (!afterEdit) return pending;
      try {
        await pending;
      } catch (_) {
        // Fetch again to include the completed edit.
      }
    }
    if (!mounted) return;
    await (_topicsRequest ??= _fetchTopics().whenComplete(
      () => _topicsRequest = null,
    ));
  }

  Future<void> _fetchTopics() async {
    final state = await chatApi
        .call('GET', _topicsPath)
        .timeout(const Duration(seconds: 15));
    if (!mounted) return;
    setState(() => _topicUpdates.value = _decodeTopics(state));
    if (!_topics.any((row) => row['id'] == _sessionId)) {
      if (_topics.isEmpty) {
        setState(() => _sessionId = null);
      } else {
        await _switchTopic(
          state['active_id'] as String? ?? _topics.first['id'] as String,
        );
      }
    }
  }

  Future<void> _reviewDraft() async {
    if (_chatBusy) return;
    final path = '$_topicsPath/$_session/draft';
    setState(() => _switchingSession = true);
    try {
      var data = await chatApi.call('GET', path);
      if (data['draft'] == null) {
        if (!mounted || !await consent(context, widget.personId)) return;
        final result = await chatApi.call('POST', path);
        if (result['outcome'] == 'no_story' ||
            result['outcome'] == 'insufficient') {
          if (mounted) showError(context, '可以再讲一段与本章相关的往事');
          return;
        }
        data = await chatApi.call('GET', path);
      }
      final proposal = data['draft'];
      if (!mounted || proposal == null) return;
      final action = await showChatSheet<String>(
        context: context,
        builder: (sheet) => ChatSheetDialog(
          title: const Text('核对本章草稿'),
          content: SelectableText(proposal['body'] as String),
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
      if (action != null) await chatApi.call(action, "$path/${proposal['id']}");
      if (mounted) {
        if (action == 'PUT') widget.onChapterChanged?.call();
        await _refreshTopics(afterEdit: true);
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _switchingSession = false);
    }
  }

  Future<void> _organizeInterview() async {
    if (!_canSend || _interview?['can_draft'] != true) return;
    setState(() => _switchingSession = true);
    try {
      if (!await consent(context, widget.personId) || !mounted) return;
      final path = '$_interviewPath/draft';
      final response = await chatApi.call('POST', path);
      if (!mounted) return;
      final saved = await reviewInterviewDraft(
        context,
        client: chatApi,
        path: path,
        draft: response['draft'] as Map,
      );
      if (saved && mounted) {
        widget.onChapterChanged?.call();
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('书稿已保存到书架')));
        await _messagesFor(_session);
        if (mounted) unawaited(_saveOpening());
      }
    } catch (error) {
      if (mounted) showError(context, error);
    } finally {
      if (mounted) setState(() => _switchingSession = false);
    }
  }

  Future<void> _openChapterOutbox() => showChatSheet<void>(
    context: context,
    builder: (sheet) => ListView(
      shrinkWrap: true,
      children: [
        ListTile(title: Text(widget.interview ? '未完成的输入' : '本章未完成的输入')),
        for (final turn in _visibleOutbox)
          ListTile(
            title: Text(
              (turn['text'] as String).isEmpty
                  ? '录音草稿'
                  : turn['text'] as String,
            ),
            trailing: Wrap(
              children: [
                if (!_onlyOriginal(turn))
                  IconButton(
                    tooltip: '编辑草稿',
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: () {
                      Navigator.pop(sheet);
                      unawaited(editTurn(turn));
                    },
                  ),
                IconButton(
                  tooltip: _onlyOriginal(turn) ? '重试上传原声' : '重试',
                  icon: const Icon(Icons.refresh_rounded),
                  onPressed: () {
                    Navigator.pop(sheet);
                    unawaited(retryTurn(turn));
                  },
                ),
              ],
            ),
          ),
      ],
    ),
  );

  String? _localOriginal(String id) =>
      _pendingOriginals[id]?.path ??
      _outbox
              .where((turn) => turn['audio_message_id'] == id)
              .firstOrNull?['audio_path']
          as String?;

  Future<void> messageActions(dynamic message) async {
    final id = message['id'] as String;
    final local = _localOriginal(id);
    if (local == null &&
        message['has_audio'] != 1 &&
        message['has_audio'] != true) {
      return;
    }
    await _stopReply();
    if (!mounted) return;
    final upload = _pendingOriginals[id];
    final player = AudioButton(id: id, client: chatApi, localPath: local);
    await showChatSheet<void>(
      context: context,
      builder: (sheet) => upload == null
          ? player
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                player,
                if (upload.blocked)
                  TextButton(
                    onPressed: () async {
                      Navigator.pop(sheet);
                      if (!await consent(context, widget.personId) ||
                          !mounted) {
                        return;
                      }
                      try {
                        await chatApi.retryVoiceUpload(widget.personId, id);
                        await _syncOriginals();
                      } catch (error) {
                        if (mounted) showError(context, error);
                      }
                    },
                    child: const Text('重试上传原声'),
                  )
                else
                  const Padding(
                    padding: EdgeInsets.only(bottom: 12),
                    child: Text('原声等待同步'),
                  ),
              ],
            ),
    );
  }

  Future<void> _refreshQuestion(
    String id,
    String text, {
    required bool opening,
  }) async {
    if (_chatBusy || _sessionId == null || text.isEmpty) return;
    final session = _session;
    setState(() {
      _switchingSession = true;
      _refreshingReply = id;
    });
    try {
      if ((!opening || _hiddenThemes) &&
          !await consent(context, widget.personId)) {
        return;
      }
      if (!mounted) return;
      if (_speakingReply == id) unawaited(_stopReply());
      if (_hiddenThemes &&
          (_pendingInterviewRefresh?['message_id'] != id ||
              _pendingInterviewRefresh?['text'] != text)) {
        _pendingInterviewRefresh = {
          'message_id': id,
          'text': text,
          'revision': _interview!['revision'],
          'request_id': const Uuid().v4().replaceAll('-', ''),
        };
        await _saveOpening();
      }
      final result = await chatApi.call(
        'POST',
        _hiddenThemes
            ? '$_interviewPath/messages/$id/refresh'
            : '$_topicsPath/$session/messages/$id/refresh',
        _hiddenThemes ? _pendingInterviewRefresh : {'text': text},
      );
      if (!mounted || session != _session) return;
      if (_hiddenThemes) {
        _pendingInterviewRefresh = null;
        final progress = result['interview'] as Map;
        if ((progress['revision'] as int) <
            (_interview?['revision'] as int? ?? -1)) {
          return;
        }
        _readInterview(progress);
      }
      final replacement = result['text'] as String;
      setState(() {
        _chapterHistory[session] = [
          for (final row in messages)
            if (row['id'] == id)
              {...(row as Map), 'text': replacement}
            else
              row,
        ];
      });
      await _saveOpening();
    } catch (error) {
      if (_hiddenThemes && error is ApiFailure && error.status == 409) {
        _pendingInterviewRefresh = null;
        if (mounted) await load();
      }
      if (mounted) {
        showError(
          context,
          error is ApiFailure &&
                  error.status == 404 &&
                  error.message == 'Not Found'
              ? '请更新 LifePages 服务后再使用换问题'
              : error,
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _switchingSession = false;
          _refreshingReply = null;
        });
        _sendQueuedVoice();
      }
    }
  }

  void _measureInputOverlay() {
    if (_inputMeasurementScheduled) return;
    _inputMeasurementScheduled = true;
    // Size notifications arrive during layout. Apply the scroll inset after it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _inputMeasurementScheduled = false;
      if (!mounted) return;
      final height = _inputOverlay.currentContext?.size?.height;
      if (height == null || height == _inputOverlayHeight) return;
      final wasAtEnd = scroll.hasClients && scroll.position.extentAfter <= 24;
      setState(() => _inputOverlayHeight = height);
      if (wasAtEnd) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && scroll.hasClients) {
            scroll.jumpTo(scroll.position.maxScrollExtent);
          }
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final bottom = widget.showNavigation
        ? MediaQuery.viewPaddingOf(context).bottom + 94
        : 12.0;
    _measureInputOverlay();
    final showVoiceDock = starting || recording || voiceError != null;
    final VoidCallback? dismissVoiceError = voiceError == null
        ? null
        : () => setState(() => voiceError = null);
    final localTurns = _sessionOutbox
        .where(
          (t) =>
              (t['text'] as String? ?? '').trim().isNotEmpty &&
              !messages.any((m) => m['request_id'] == t['request_id']),
        )
        .toList();
    final question = _interview?['question'] as int?;
    final questionCount = _interview?['total'] as int?;
    final answering =
        question != null &&
        questionCount != null &&
        question > 0 &&
        question <= questionCount;
    final characters = (_interview?['characters'] as int?) ?? 0;
    final minimum = (_interview?['minimum_characters'] as int?) ?? 301;
    final ready = _interview?['can_advance'] == true;
    final progress = ready
        ? 1.0
        : (characters / (minimum > 0 ? minimum : 301))
              .clamp(0.0, .95)
              .toDouble();
    final canSkip =
        _canSend && !_sessionOutbox.any((turn) => !_onlyOriginal(turn));
    return Theme(
      data: chatChatTheme(context),
      child: SafeArea(
        bottom: false,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                  child: SizedBox(
                    height: 48,
                    child: Row(
                      children: [
                        SizedBox(
                          width: 92,
                          child: answering && widget.interview
                              ? Row(
                                  children: [
                                    SizedBox(
                                      width: 48,
                                      height: 48,
                                      child: OutlinedButton(
                                        key: const ValueKey(
                                          'next-chapter-button',
                                        ),
                                        onPressed: canSkip
                                            ? _nextChapter
                                            : null,
                                        style: OutlinedButton.styleFrom(
                                          padding: const EdgeInsets.all(5),
                                          foregroundColor: chatAccent,
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                          ),
                                        ),
                                        child: const Text(
                                          '下一\n章节',
                                          semanticsLabel: '下一章节',
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                            fontSize: 12,
                                            height: 1.1,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    SizedBox(
                                      width: 36,
                                      height: 36,
                                      child: IconButton(
                                        key: const ValueKey(
                                          'interview-progress-ring',
                                        ),
                                        tooltip: '查看已记录字数',
                                        padding: EdgeInsets.zero,
                                        onPressed: _showInterviewProgress,
                                        icon: SizedBox(
                                          width: 32,
                                          height: 32,
                                          child: Stack(
                                            alignment: Alignment.center,
                                            children: [
                                              CircularProgressIndicator(
                                                value: progress,
                                                strokeWidth: 3,
                                                color: chatAccent,
                                                backgroundColor: chatAccent
                                                    .withValues(alpha: .14),
                                              ),
                                              if (ready)
                                                const Icon(
                                                  Icons.check_rounded,
                                                  size: 16,
                                                )
                                              else
                                                Text(
                                                  '${(progress * 100).floor()}%',
                                                  style: const TextStyle(
                                                    fontSize: 9,
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                )
                              : !widget.interview
                              ? IconButton(
                                  key: const ValueKey(
                                    'chapter-directory-button',
                                  ),
                                  tooltip: '章节目录',
                                  onPressed: _chatBusy ? null : _openTopics,
                                  icon: const Icon(Icons.menu_rounded),
                                )
                              : null,
                        ),
                        Expanded(
                          child: Text(
                            widget.bookTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 21,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                        SizedBox(
                          width: 92,
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: GlassIconButton(
                              key: const ValueKey('assistant-settings-button'),
                              size: 48,
                              iconSize: 26,
                              useOwnLayer: true,
                              glowColor: chatAccent.withValues(alpha: .18),
                              onPressed:
                                  widget.onChooseBook ?? _openChapterOutbox,
                              icon: const Icon(
                                Icons.tune_rounded,
                                semanticLabel: '聊天设置',
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (widget.interview && question != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Wrap(
                      spacing: 8,
                      alignment: WrapAlignment.center,
                      children: [
                        if (question == 0)
                          TextButton(
                            onPressed: canSkip
                                ? () => sendText(interviewAction: 'begin')
                                : null,
                            child: const Text('开始聊故事'),
                          ),
                        if (_interview?['can_draft'] == true)
                          TextButton(
                            onPressed: _canSend ? _organizeInterview : null,
                            child: Text(_switchingSession ? '正在整理…' : '整理成书'),
                          ),
                      ],
                    ),
                  ),
                if (_offline)
                  TextButton.icon(
                    onPressed: load,
                    icon: const Icon(Icons.wifi_off),
                    label: const Text('正在显示离线内容，点此重新连接'),
                  ),
                if (_chapterLoadFailed)
                  TextButton.icon(
                    onPressed: () => _switchTopic(_session),
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('本章未同步，点此重试'),
                  ),
                Expanded(
                  child: loading
                      ? const Center(child: CircularProgressIndicator())
                      : _topicLoadError != null
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                _topicLoadError!,
                                textAlign: TextAlign.center,
                              ),
                              TextButton(
                                onPressed: load,
                                child: Text(
                                  widget.interview ? '重试加载访谈' : '重试加载章节',
                                ),
                              ),
                            ],
                          ),
                        )
                      : _chapterLoading &&
                            messages.isEmpty &&
                            localTurns.isEmpty
                      ? const Center(child: Text('正在加载本章聊天…'))
                      : messages.isEmpty &&
                            localTurns.isEmpty &&
                            !awaitingReply &&
                            !_chapterLoadFailed
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(32, 24, 32, 54),
                            child: Text(
                              !widget.interview && _topics.isEmpty
                                  ? '还没有目录，请先到书架添加一章。'
                                  : '有什么我能帮你的吗？',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 30,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        )
                      : ListView(
                          controller: scroll,
                          padding: EdgeInsets.fromLTRB(
                            16,
                            16,
                            16,
                            bottom + _inputOverlayHeight + 12,
                          ),
                          children: [
                            for (final (index, message) in messages.indexed)
                              _bubble(message, opening: index == 0),
                            for (final turn in localTurns) ...[
                              ChatChatMessageBubble(
                                outgoing: true,
                                text: turn['text'],
                              ),
                              if (identical(turn, _sendingTurn)) ...[
                                if (_streamText.isNotEmpty)
                                  ChatChatMessageBubble(
                                    outgoing: false,
                                    text: _streamText,
                                    selectable: false,
                                  )
                                else if (awaitingReply)
                                  const ChatChatThinkingBubble(),
                              ],
                              if (turn['queued'] == true &&
                                  _waitingForEarlierTurn(turn))
                                Text(sending ? '已录好，等待上一条回复' : '已录好，请先重试上一条回复'),
                              if (turn['failed'] == true && !sending)
                                Row(
                                  children: [
                                    const Expanded(child: Text('回复未完成')),
                                    TextButton(
                                      onPressed: _canSend
                                          ? () => retryTurn(turn)
                                          : null,
                                      child: const Text('重试'),
                                    ),
                                  ],
                                ),
                            ],
                            if (!localTurns.contains(_sendingTurn) &&
                                awaitingReply)
                              if (_streamText.isNotEmpty)
                                ChatChatMessageBubble(
                                  outgoing: false,
                                  text: _streamText,
                                  selectable: false,
                                )
                              else
                                const ChatChatThinkingBubble(),
                          ],
                        ),
                ),
              ],
            ),
            if (showVoiceDock)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: dismissVoiceError,
                  child: ColoredBox(
                    color: cancelZone
                        ? Colors.red.withValues(alpha: .055)
                        : Colors.black.withValues(alpha: .08),
                  ),
                ),
              ),
            Positioned(
              left: 16,
              right: 16,
              bottom: bottom,
              child: NotificationListener<SizeChangedLayoutNotification>(
                onNotification: (_) {
                  _measureInputOverlay();
                  return false;
                },
                child: SizeChangedLayoutNotifier(
                  key: _inputOverlay,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      if (showVoiceDock)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: GestureDetector(
                            onTap: dismissVoiceError,
                            child: _voiceDock(),
                          ),
                        ),
                      if (textMode) _voiceModeButton(context),
                      _composer(),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _voiceModeButton(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 8, bottom: 10),
    child: TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: Transform.translate(
          offset: Offset(0, 6 * (1 - value)),
          child: child,
        ),
      ),
      child: Tooltip(
        message: '切换到语音输入',
        child: DecoratedBox(
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: Color(0x1A000000),
                blurRadius: 16,
                spreadRadius: -5,
                offset: Offset(0, 6),
              ),
            ],
          ),
          child: GlassIconButton(
            key: const ValueKey('assistant-voice-mode'),
            size: 44,
            iconSize: 23,
            useOwnLayer: true,
            glowColor: const Color(0x33FFFFFF),
            onPressed: openVoiceInput,
            icon: const Icon(Icons.mic_rounded),
          ),
        ),
      ),
    ),
  );

  Widget _voiceDock() => OneSayVoiceDock(
    text:
        voiceError ??
        (partial.isNotEmpty
            ? partial
            : starting
            ? '正在启动麦克风…'
            : isStopping
            ? '正在确认识别结果…'
            : '正在听，松手自动发送'),
    status: voiceError != null
        ? '识别未完成'
        : cancelZone
        ? '松开取消'
        : isStopping
        ? '正在确认'
        : '正在听',
    hint: voiceError != null
        ? '轻点关闭'
        : cancelZone
        ? '移回继续说话'
        : '上滑取消 · 松开发送',
    amp: amplitude,
    isCancel: cancelZone,
    isProcessing: isStopping,
    hasError: voiceError != null,
  );

  Widget _bubble(dynamic m, {required bool opening}) {
    final id = m['id'] as String?;
    final text = m['text'] as String? ?? '';
    final assistant = m['role'] == 'assistant';
    final canPlay =
        (Platform.isIOS || Platform.isAndroid || widget.replyPlayer != null) &&
        assistant &&
        id != null;
    final hasRecording =
        !assistant &&
        id != null &&
        (m['has_audio'] == 1 ||
            m['has_audio'] == true ||
            _localOriginal(id) != null);
    return ChatChatMessageBubble(
      key: id == null ? null : ValueKey(id),
      text: text,
      outgoing: m['role'] == 'user',
      playing: canPlay && _speakingReply == id,
      refreshing: _refreshingReply != null && _refreshingReply == id,
      canRefresh: !_chatBusy,
      onRefresh:
          (!widget.interview ||
                  (_hiddenThemes && _interview?['refresh_message_id'] == id)) &&
              assistant &&
              id != null &&
              text.isNotEmpty
          ? () => unawaited(_refreshQuestion(id, text, opening: opening))
          : null,
      onPlay: canPlay
          ? () {
              if (!_chatBusy || _speakingReply == id) {
                unawaited(_playReply((id: id, text: text), requested: true));
              }
            }
          : hasRecording
          ? () => unawaited(messageActions(m))
          : null,
    );
  }

  Widget _composer() => ChatChatComposer(
    key: const ValueKey('chat-composer'),
    controller: input,
    focusNode: inputFocus,
    canSubmit: _canSubmitText,
    onSend: () => unawaited(sendText()),
    onKeyboard: starting || recording ? null : openTextInput,
    holdToTalk: textMode
        ? null
        : HoldToTalkButton(
            active: starting || recording,
            onStart: () => unawaited(startVoice()),
            onSlide: (cancel) {
              if (pointerDown && cancelZone != cancel) {
                setState(() => cancelZone = cancel);
              }
            },
            onEnd: () => unawaited(finishVoice(cancel: cancelZone)),
            onCancel: () {
              if (pointerDown) unawaited(finishVoice(cancel: true));
            },
          ),
  );
}

class EditPersonSheet extends StatefulWidget {
  final Map<String, dynamic> person;
  final Api? client;
  const EditPersonSheet({super.key, required this.person, this.client});
  @override
  State<EditPersonSheet> createState() => _EditPersonSheetState();
}

class _EditPersonSheetState extends State<EditPersonSheet> {
  late final TextEditingController name, background;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    name = TextEditingController(text: widget.person['name']);
    background = TextEditingController(text: widget.person['background']);
  }

  @override
  void dispose() {
    name.dispose();
    background.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (name.text.trim().isEmpty) {
      showError(context, '请填写称呼');
      return;
    }
    setState(() => busy = true);
    try {
      await (widget.client ?? api).call(
        'PUT',
        '/api/people/${widget.person['id']}',
        {'name': name.text.trim(), 'background': background.text.trim()},
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListView(
    shrinkWrap: true,
    children: [
      const Text(
        '让我们更了解你',
        style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 10),
      const Text('这些信息可随时更改。', style: TextStyle(color: Colors.black54)),
      const SizedBox(height: 24),
      TextField(
        controller: name,
        decoration: const InputDecoration(labelText: '称呼'),
      ),
      const SizedBox(height: 15),
      TextField(
        controller: background,
        minLines: 4,
        maxLines: 7,
        decoration: const InputDecoration(
          labelText: '经历（选填）',
          hintText: '家乡、成长年代或其他想分享的事',
        ),
      ),
      const SizedBox(height: 24),
      FilledButton(onPressed: busy ? null : save, child: const Text('保存')),
    ],
  );
}
