import 'book_cover.dart';
import 'offline_cache.dart';
import 'voice_preferences.dart';
import 'platform_capabilities.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'chat_sheet.dart';
import 'chapter_editor.dart';
import 'reading_preferences.dart';
import 'legal_urls.dart';
import 'dart:async';
import 'chat_shell.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:qr/qr.dart';
import 'package:record/record.dart';

const ink = Color(0xFF2A2528);
const accent = Color(0xFFE8735A);
const paper = Color(0xfff8f5ee);
const secure = FlutterSecureStorage();
final api = Api();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  unawaited(restoreAutomaticReplyAudio());
  if (Platform.isAndroid) {
    runApp(const LifePages());
    unawaited(restoreReadingScale());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(LiquidGlassWidgets.initialize(enablePerformanceMonitor: false));
    });
  } else {
    await Future.wait([LiquidGlassWidgets.initialize(), restoreReadingScale()]);
    runApp(const LifePages());
  }
}

class LifePages extends StatelessWidget {
  const LifePages({super.key});
  @override
  Widget build(BuildContext context) => LiquidGlassWidgets.wrap(
    child: MaterialApp(
      title: 'LifePages',
      debugShowCheckedModeBanner: false,
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      builder: (context, child) => ReadingScale(child: child!),
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: accent, surface: paper),
        scaffoldBackgroundColor: paper,
        appBarTheme: const AppBarTheme(
          backgroundColor: paper,
          foregroundColor: ink,
          centerTitle: false,
        ),
        textTheme: ThemeData.light().textTheme.apply(
          bodyColor: ink,
          displayColor: ink,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
          contentPadding: const EdgeInsets.all(18),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: accent,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 17),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
        ),
      ),
      home: const Startup(),
    ),
  );
}

class ApiFailure implements Exception {
  const ApiFailure(this.status, this.message);

  final int status;
  final Object message;

  @override
  String toString() => '$message';
}

typedef PendingVoiceUpload = ({String path, bool blocked});

class Api {
  Api({http.Client? client, ReadCache? cache, bool? offlineReads})
    : _client = client ?? http.Client(),
      _cache = cache ?? ReadCache(getApplicationSupportDirectory),
      offlineReads = offlineReads ?? Platform.isAndroid;
  final http.Client _client;
  final ReadCache _cache;
  final bool offlineReads;
  static const _voiceUploads = MethodChannel('life_pages/voice_uploads');
  String get _scope => '$base\u0000$token';
  Future<dynamic> readSnapshot(String path) async =>
      offlineReads && token.isNotEmpty ? _cache.read(_scope, path) : null;
  Future<void> writeSnapshot(String path, dynamic data) async {
    if (offlineReads && token.isNotEmpty) {
      await _cache.write(_scope, path, data);
    }
  }

  String base = 'https://onesay.top/lifepages';
  String token = '';
  Map<String, String> get headers => {
    'Authorization': 'Bearer $token',
    'Content-Type': 'application/json',
  };
  Future<dynamic> call(
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    final request = http.Request(method, Uri.parse('$base$path'))
      ..headers.addAll(headers);
    if (body != null) request.body = jsonEncode(body);
    try {
      final response =
          await (() async => http.Response.fromStream(
            await _client.send(request),
          ))().timeout(
            offlineReads && method == 'GET'
                ? const Duration(seconds: 8)
                : const Duration(minutes: 4),
          );
      final data = _responseData(response);
      if (method == 'GET') await writeSnapshot(path, data);
      return data;
    } on ApiFailure {
      rethrow;
    } catch (_) {
      if (method == 'GET') {
        final saved = await readSnapshot(path);
        if (saved != null) return saved;
      }
      rethrow;
    }
  }

  dynamic _responseData(http.Response response) {
    dynamic data;
    try {
      data = jsonDecode(utf8.decode(response.bodyBytes));
    } catch (_) {
      data = null;
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiFailure(
        response.statusCode,
        data is Map
            ? (data['detail'] ?? '请求失败')
            : '请求失败（${response.statusCode}）',
      );
    }
    return data;
  }

  Stream<Map<String, dynamic>> streamTurn(
    String path,
    Map<String, dynamic> body, {
    required bool speak,
  }) async* {
    final request = http.Request('POST', Uri.parse('$base$path/stream'))
      ..headers.addAll(headers)
      ..body = jsonEncode({...body, 'speak': speak});
    final response = await _client
        .send(request)
        .timeout(const Duration(seconds: 50));
    if (response.statusCode != 200) {
      final buffered = await http.Response.fromStream(
        response,
      ).timeout(const Duration(seconds: 15));
      // A client installed before its server is upgraded can still send turns.
      if (response.statusCode == 404 && path.endsWith('/turns')) {
        final reply = await call('POST', path, body) as Map;
        yield {'type': 'done', ...Map<String, dynamic>.from(reply)};
        return;
      }
      _responseData(buffered);
      return;
    }
    await for (final line
        in response.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .timeout(const Duration(seconds: 50))) {
      if (line.isNotEmpty) yield jsonDecode(line) as Map<String, dynamic>;
    }
  }

  Future<String> enqueueVoiceUpload({
    required String book,
    required String message,
    required String request,
    required String path,
  }) async => (await _voiceUploads.invokeMethod<String>('enqueue', {
    'base': base,
    'token': token,
    'book': book,
    'message': message,
    'request': request,
    'path': path,
  }))!;

  Future<Map<String, PendingVoiceUpload>> pendingVoiceUploads(
    String book,
  ) async {
    final uploads = await _voiceUploads.invokeMapMethod<String, dynamic>(
      'pending',
      {'base': base, 'book': book},
    );
    return {
      for (final entry in (uploads ?? const <String, dynamic>{}).entries)
        entry.key: (
          path: entry.value['path'] as String,
          blocked: entry.value['blocked'] == true,
        ),
    };
  }

  Future<void> retryVoiceUpload(String book, String message) =>
      _voiceUploads.invokeMethod<void>('retry', {
        'base': base,
        'token': token,
        'book': book,
        'message': message,
      });

  Future<void> pauseVoiceUploads(String book) =>
      _voiceUploads.invokeMethod<void>('pause', {'base': base, 'book': book});

  Future<String> audio(String id) async {
    final response = await http.get(
      Uri.parse('$base/api/messages/$id/audio'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (response.statusCode != 200) throw Exception('录音无法播放');
    final dir = await getTemporaryDirectory();
    final file = File(
      '${dir.path}/lifepages-playback-${Uri.encodeComponent(id)}.wav',
    );
    await file.writeAsBytes(response.bodyBytes, flush: true);
    return file.path;
  }
}

String errorText(Object e) => e.toString().replaceFirst('Exception: ', '');
void showError(BuildContext context, Object e) =>
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(errorText(e)),
        duration: const Duration(seconds: 5),
      ),
    );

class Startup extends StatefulWidget {
  const Startup({super.key});
  @override
  State<Startup> createState() => _StartupState();
}

class _StartupState extends State<Startup> {
  static const _accountSessionKey = 'lifepages_email_session';
  bool loading = true;
  String? error;
  Map<String, dynamic>? _accountSession;
  String _guestToken = '';
  int _accountEpoch = 0;
  bool _signingOut = false;
  late Api _client;
  @override
  void initState() {
    super.initState();
    connect();
  }

  Future<void> connect() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      _guestToken = await secure.read(key: 'device_token') ?? '';
      final saved = await secure.read(key: _accountSessionKey);
      _accountSession = saved == null
          ? null
          : Map<String, dynamic>.from(jsonDecode(saved) as Map);
      if (_guestToken.isEmpty && _accountSession == null) {
        await _newGuest();
      }
      _useToken(_accountSession?['token'] as String? ?? _guestToken);
    } catch (_) {
      if (mounted) setState(() => error = '暂时无法连接服务，请检查网络后重试。');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  void _useToken(String token) {
    _client = Api()
      ..base = api.base
      ..token = token;
    _accountEpoch++;
  }

  Future<void> _newGuest() async {
    final bootstrapClient = Api()..base = api.base;
    final result = await bootstrapClient
        .call('POST', '/api/bootstrap')
        .timeout(
          Platform.isAndroid
              ? const Duration(seconds: 8)
              : const Duration(minutes: 4),
        );
    final token = result['token'] as String;
    await secure.write(key: 'device_token', value: token);
    _guestToken = token;
  }

  Future<void> _signIn(Map<String, dynamic> session) async {
    final token = session['token'] as String;
    await secure.write(key: _accountSessionKey, value: jsonEncode(session));
    if (!mounted) return;
    setState(() {
      _accountSession = session;
      _useToken(token);
    });
  }

  Future<void> _signOut() async {
    final session = _accountSession;
    if (_signingOut || session == null) return;
    _signingOut = true;
    try {
      if (session['uses_current_account'] == true || _guestToken.isEmpty) {
        await _newGuest();
        final updated = {...session, 'uses_current_account': false};
        await secure.write(key: _accountSessionKey, value: jsonEncode(updated));
        _accountSession = updated;
      }
      await _client.call('POST', '/api/auth/logout');
      await secure.delete(key: _accountSessionKey);
      if (!mounted) return;
      setState(() {
        _accountSession = null;
        _useToken(_guestToken);
      });
    } finally {
      _signingOut = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'LifePages',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
              ),
              SizedBox(height: 20),
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('正在打开你的回忆录…'),
            ],
          ),
        ),
      );
    }
    if (error != null) {
      return Scaffold(
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.cloud_off_outlined, color: accent, size: 48),
                  const SizedBox(height: 20),
                  Text(
                    error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 17),
                  ),
                  const SizedBox(height: 24),
                  FilledButton(onPressed: connect, child: const Text('重试')),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return ChatShell(
      key: ValueKey(_accountEpoch),
      client: _client,
      email: _accountSession?['email'] as String?,
      accountProvider: _accountSession == null
          ? null
          : _accountSession?['provider'] as String? ?? 'email',
      onSignIn: _signIn,
      onSignOut: _signOut,
    );
  }
}

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});
  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  List<dynamic> people = [];
  bool busy = true;
  @override
  void initState() {
    super.initState();
    refresh();
  }

  Future<void> refresh() async {
    try {
      final v = await api.call('GET', '/api/people');
      if (mounted) {
        setState(() {
          people = v;
          busy = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => busy = false);
        showError(context, e);
      }
    }
  }

  Future<void> create() async {
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const NewPerson()),
    );
    if (result == true) refresh();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text(
        'LifePages',
        style: TextStyle(fontWeight: FontWeight.w700),
      ),
    ),
    body: RefreshIndicator(
      onRefresh: refresh,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(24, 18, 24, 32),
        children: [
          const Text(
            '每个人的一生，\n都值得被好好讲述。',
            style: TextStyle(
              fontSize: 28,
              height: 1.4,
              fontWeight: FontWeight.w700,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            '从一个问题开始，把声音和回忆留给未来。',
            style: TextStyle(fontSize: 15, color: Colors.black54),
          ),
          const SizedBox(height: 32),
          Row(
            children: [
              const Expanded(
                child: Text(
                  '我的回忆录',
                  style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
                ),
              ),
              Text(
                '${people.length} 本',
                style: const TextStyle(color: Colors.black45),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (busy)
            const Center(child: CircularProgressIndicator())
          else if (people.isEmpty)
            Container(
              padding: const EdgeInsets.all(28),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(22),
              ),
              child: const Column(
                children: [
                  Icon(Icons.menu_book_rounded, size: 42, color: accent),
                  SizedBox(height: 16),
                  Text(
                    '还没有回忆录',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                  SizedBox(height: 8),
                  Text(
                    '为一位亲人创建一本，慢慢记录。',
                    style: TextStyle(color: Colors.black54),
                  ),
                ],
              ),
            )
          else
            ...people.map(
              (p) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Material(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(18),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(18),
                    onTap: () async {
                      await Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => PersonPage(id: p['id']),
                        ),
                      );
                      refresh();
                    },
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Row(
                        children: [
                          Container(
                            width: 53,
                            height: 62,
                            decoration: BoxDecoration(
                              color: const Color(0xffead9c8),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Icon(
                              Icons.auto_stories_outlined,
                              color: accent,
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${p['name']}的回忆录',
                                  style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 5),
                                const Text(
                                  '继续聆听与记录',
                                  style: TextStyle(color: Colors.black54),
                                ),
                              ],
                            ),
                          ),
                          const Icon(Icons.chevron_right),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          const SizedBox(height: 22),
          FilledButton.icon(
            onPressed: create,
            icon: const Icon(Icons.add),
            label: const Text('创建一本回忆录'),
          ),
        ],
      ),
    ),
  );
}

class NewPerson extends StatefulWidget {
  const NewPerson({super.key});
  @override
  State<NewPerson> createState() => _NewPersonState();
}

class _NewPersonState extends State<NewPerson> {
  final name = TextEditingController(), background = TextEditingController();
  bool busy = false;
  @override
  void dispose() {
    name.dispose();
    background.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (name.text.trim().isEmpty) {
      showError(context, '请先填写称呼');
      return;
    }
    setState(() => busy = true);
    try {
      await api.call('POST', '/api/people', {
        'name': name.text.trim(),
        'background': background.text.trim(),
      });
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('创建回忆录')),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Text(
          '先认识一下讲述者',
          style: TextStyle(fontSize: 25, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 10),
        const Text(
          '这些信息会帮助 AI 找到更适合的话题。可以只填写称呼。',
          style: TextStyle(height: 1.6, color: Colors.black54),
        ),
        const SizedBox(height: 28),
        TextField(
          controller: name,
          decoration: const InputDecoration(
            labelText: '怎么称呼这位长辈？',
            hintText: '例如：外婆、王爷爷',
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: background,
          minLines: 4,
          maxLines: 7,
          decoration: const InputDecoration(
            labelText: '想先告诉我们的经历（选填）',
            hintText: '家乡、成长年代、工作或其他你想分享的事',
          ),
        ),
        const SizedBox(height: 26),
        FilledButton(
          onPressed: busy ? null : save,
          child: Text(busy ? '正在创建…' : '创建回忆录'),
        ),
      ],
    ),
  );
}

class PersonPage extends StatefulWidget {
  final String id;
  const PersonPage({super.key, required this.id});
  @override
  State<PersonPage> createState() => _PersonPageState();
}

class _PersonPageState extends State<PersonPage> {
  Map<String, dynamic>? person;
  bool busy = false;
  int tab = 0;
  @override
  void initState() {
    super.initState();
    refresh();
  }

  Future<void> refresh() async {
    try {
      final p = await api.call('GET', '/api/people/${widget.id}');
      if (mounted) setState(() => person = Map<String, dynamic>.from(p));
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> question({bool skip = false}) async {
    if (!await consent(context, widget.id) || !mounted) return;
    setState(() => busy = true);
    try {
      await api.call(
        'POST',
        '/api/people/${widget.id}/question${skip ? '?skip=true' : ''}',
      );
      await refresh();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> generate() async {
    final yes = await showChatSheet<bool>(
      context: context,
      builder: (c) => ChatSheetDialog(
        title: const Text('整理成回忆录'),
        content: const Text('AI 将根据尚未整理的新访谈生成一章草稿，并关联对应录音。请在成书前核对和编辑。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('稍后'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('开始整理'),
          ),
        ],
      ),
    );
    if (yes != true ||
        !mounted ||
        !await consent(context, widget.id) ||
        !mounted) {
      return;
    }
    setState(() => busy = true);
    try {
      await api.call('POST', '/api/people/${widget.id}/chapters/generate');
      await refresh();
      if (mounted) setState(() => tab = 1);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = person;
    if (p == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final messages = List<dynamic>.from(p['messages']);
    final chapters = List<dynamic>.from(p['chapters']);
    return Scaffold(
      appBar: AppBar(title: Text('${p['name']}的回忆录')),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (i) => setState(() => tab = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.forum_outlined),
            selectedIcon: Icon(Icons.forum),
            label: '访谈',
          ),
          NavigationDestination(
            icon: Icon(Icons.menu_book_outlined),
            selectedIcon: Icon(Icons.menu_book),
            label: '回忆录',
          ),
        ],
      ),
      body: tab == 0
          ? Column(
              children: [
                Expanded(
                  child: messages.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(32),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.wb_sunny_outlined,
                                  color: accent,
                                  size: 50,
                                ),
                                const SizedBox(height: 20),
                                const Text(
                                  '故事从一次聊天开始',
                                  style: TextStyle(
                                    fontSize: 21,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                const Text(
                                  '不用一次讲完，每天聊一点就好。',
                                  style: TextStyle(color: Colors.black54),
                                ),
                                const SizedBox(height: 24),
                                FilledButton(
                                  onPressed: busy ? null : question,
                                  child: const Text('听听第一个问题'),
                                ),
                              ],
                            ),
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.all(20),
                          itemCount: messages.length,
                          itemBuilder: (context, i) {
                            final m = messages[i];
                            final isUser = m['role'] == 'user';
                            return Align(
                              alignment: isUser
                                  ? Alignment.centerRight
                                  : Alignment.centerLeft,
                              child: Container(
                                constraints: BoxConstraints(
                                  maxWidth:
                                      MediaQuery.sizeOf(context).width * .84,
                                ),
                                margin: const EdgeInsets.only(bottom: 14),
                                padding: const EdgeInsets.all(17),
                                decoration: BoxDecoration(
                                  color: isUser
                                      ? const Color(0xffead9c8)
                                      : Colors.white,
                                  borderRadius: BorderRadius.circular(18),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      isUser ? p['name'] : 'LifePages 提问',
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: accent,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    const SizedBox(height: 7),
                                    Text(
                                      m['text'],
                                      style: const TextStyle(
                                        fontSize: 17,
                                        height: 1.6,
                                      ),
                                    ),
                                    if (m['has_audio'] == 1)
                                      AudioButton(id: m['id']),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
                if (busy)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text('正在整理思绪，请稍等…'),
                  ),
                if (messages.isNotEmpty &&
                    messages.last['role'] == 'user' &&
                    !busy)
                  TextButton(
                    onPressed: question,
                    child: const Text('继续生成下一个问题'),
                  ),
                if (messages.isNotEmpty)
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                      child: Row(
                        children: [
                          OutlinedButton(
                            onPressed: busy ? null : () => question(skip: true),
                            child: const Text('换个话题'),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: busy
                                  ? null
                                  : () async {
                                      final done = await Navigator.push<bool>(
                                        context,
                                        MaterialPageRoute(
                                          builder: (_) =>
                                              AnswerPage(personId: widget.id),
                                        ),
                                      );
                                      if (done == true) {
                                        await refresh();
                                        await question();
                                      }
                                    },
                              icon: const Icon(Icons.mic_none),
                              label: const Text('讲述或输入'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            )
          : ListView(
              padding: const EdgeInsets.all(22),
              children: [
                const Text(
                  '把声音，写进故事里',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 9),
                const Text(
                  '整理后的文字可以继续修改。每一章都值得仔细核对。',
                  style: TextStyle(color: Colors.black54, height: 1.6),
                ),
                const SizedBox(height: 24),
                if (chapters.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 28),
                    child: Center(
                      child: Text(
                        '还没有章节，聊过之后就可以整理。',
                        style: TextStyle(color: Colors.black54),
                      ),
                    ),
                  )
                else
                  ...chapters.asMap().entries.map((entry) {
                    final ch = entry.value;
                    return Card(
                      color: Colors.white,
                      elevation: 0,
                      margin: const EdgeInsets.only(bottom: 12),
                      child: ListTile(
                        contentPadding: const EdgeInsets.all(16),
                        leading: Text(
                          '${entry.key + 1}'.padLeft(2, '0'),
                          style: const TextStyle(color: accent, fontSize: 20),
                        ),
                        title: Text(
                          ch['title'],
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        subtitle: const Text('阅读、编辑与原声分享'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () async {
                          await Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => ChapterPage(
                                chapter: Map<String, dynamic>.from(ch),
                              ),
                            ),
                          );
                          refresh();
                        },
                      ),
                    );
                  }),
                const SizedBox(height: 14),
                FilledButton.icon(
                  onPressed: busy ? null : generate,
                  icon: const Icon(Icons.auto_awesome),
                  label: Text(busy ? '正在整理…' : '根据访谈整理一章'),
                ),
                if (chapters.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => BookPage(
                          name: p['name'],
                          chapters: chapters
                              .map((c) => Map<String, dynamic>.from(c))
                              .toList(),
                        ),
                      ),
                    ),
                    icon: const Icon(Icons.import_contacts),
                    label: const Text('阅读与导出整本书'),
                  ),
                ],
              ],
            ),
    );
  }
}

class AudioButton extends StatefulWidget {
  final String id;
  final Api? client;
  final String? localPath;
  const AudioButton({super.key, required this.id, this.client, this.localPath});
  @override
  State<AudioButton> createState() => _AudioButtonState();
}

class _AudioButtonState extends State<AudioButton> {
  AudioPlayer? player;
  bool busy = false;
  @override
  void dispose() {
    player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextButton.icon(
    onPressed: busy
        ? null
        : () async {
            setState(() => busy = true);
            try {
              final path = widget.localPath;
              final source = path != null && await File(path).exists()
                  ? path
                  : await (widget.client ?? api).audio(widget.id);
              if (!mounted) return;
              await (player ??= AudioPlayer()).play(DeviceFileSource(source));
            } catch (e) {
              if (context.mounted) showError(context, e);
            } finally {
              if (mounted) setState(() => busy = false);
            }
          },
    icon: const Icon(Icons.play_circle_outline),
    label: Text(busy ? '加载中' : '播放原声'),
  );
}

String aiConsentKey(String bookId) => 'ai_consent_v2_$bookId';
String replyConsentKey(String bookId) => 'rtc_reply_consent_v2_$bookId';
const localAiConsentKey = 'ai_consent_device';
const localReplyConsentKey = 'rtc_reply_consent_device';

Future<bool> hasLocalConsent(String key, String legacyKey) async {
  final value = await secure.read(key: key);
  return value == null
      ? await secure.read(key: legacyKey) == 'yes'
      : value == 'yes';
}

Future<bool> hasAiConsent(String bookId) =>
    hasLocalConsent(localAiConsentKey, aiConsentKey(bookId));

Future<bool> hasReplyConsent(String bookId) =>
    hasLocalConsent(localReplyConsentKey, replyConsentKey(bookId));

Future<bool> consent(BuildContext context, String personId) async {
  if (await hasAiConsent(personId)) return true;
  if (!context.mounted) return false;
  final yes = await showChatSheet<bool>(
    context: context,
    builder: (c) => ChatSheetDialog(
      title: const Text('允许 AI 处理讲述内容'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '使用 AI 聊天、转写和整理时，LifePages 会把语音发送给阿里云百炼进行转写，并发送相关讲述、聊天上下文、人物资料和书稿文字，用于生成回复、问题或整理稿。'
            '发送的讲述和保留的原声会保存到 LifePages 服务。',
          ),
          const SizedBox(height: 8),
          const Text(
            '同意后，本机新建的书籍也可使用 AI。请先取得讲述者同意。您可在「我的 → 设置 → AI 数据授权」撤回本机授权。手动编辑书稿无需开启 AI。',
          ),
          TextButton(
            onPressed: () => AppLegalUrls.open(context, AppLegalUrls.privacy),
            child: const Text('查看隐私政策'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(c, false),
          child: const Text('暂不同意'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(c, true),
          child: const Text('同意并使用'),
        ),
      ],
    ),
  );
  if (yes == true) {
    await secure.write(key: localAiConsentKey, value: 'yes');
  }
  return yes == true;
}

class AnswerPage extends StatefulWidget {
  final String personId;
  const AnswerPage({super.key, required this.personId});
  @override
  State<AnswerPage> createState() => _AnswerPageState();
}

class _AnswerPageState extends State<AnswerPage> {
  final recorder = AudioRecorder();
  final player = AudioPlayer();
  final text = TextEditingController();
  String? path;
  bool recording = false, busy = false;
  bool hasAudio = false;
  Timer? recordingLimit;
  @override
  void initState() {
    super.initState();
    prepare();
  }

  Future<void> prepare() async {
    final dir = await getApplicationDocumentsDirectory();
    final p = '${dir.path}/draft-${widget.personId}.wav';
    final exists = await File(p).exists();
    if (mounted) {
      setState(() {
        path = p;
        hasAudio = exists;
      });
    }
  }

  @override
  void dispose() {
    recordingLimit?.cancel();
    recorder.dispose();
    player.dispose();
    text.dispose();
    super.dispose();
  }

  Future<void> start() async {
    if (!await consent(context, widget.personId) || !mounted) return;
    if (hasAudio) {
      final replace = await showChatSheet<bool>(
        context: context,
        builder: (c) => ChatSheetDialog(
          title: const Text('替换未提交的录音？'),
          content: const Text('原来的录音将被删除。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('保留'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('替换'),
            ),
          ],
        ),
      );
      if (replace != true) return;
    }
    try {
      if (path == null) throw Exception('录音目录尚未准备好');
      if (!await recorder.hasPermission()) throw Exception('请在系统设置中允许使用麦克风');
      await recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
        ),
        path: path!,
      );
      if (mounted) {
        setState(() {
          recording = true;
          hasAudio = false;
        });
        recordingLimit = Timer(const Duration(minutes: 3), () {
          if (recording) stop();
        });
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> stop() async {
    recordingLimit?.cancel();
    try {
      final result = await recorder.stop();
      if (mounted) {
        setState(() {
          recording = false;
          hasAudio = result != null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => recording = false);
        showError(context, e);
      }
    }
  }

  Future<void> transcribe() async {
    if (!await consent(context, widget.personId) || !mounted) return;
    setState(() => busy = true);
    try {
      final raw = await File(path!).readAsBytes();
      final response = await api.call('POST', '/api/transcribe', {
        'audio_base64': base64Encode(raw),
      });
      final result = (response['text'] as String).trim();
      if (result.isEmpty) throw Exception('没有识别到文字，可以重试或手动输入');
      text.text = result;
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> submit() async {
    if (text.text.trim().isEmpty) {
      showError(context, '请先转写或输入讲述内容');
      return;
    }
    if (!await consent(context, widget.personId) || !mounted) return;
    setState(() => busy = true);
    try {
      final body = <String, dynamic>{'text': text.text.trim()};
      if (hasAudio) {
        body['audio_base64'] = base64Encode(await File(path!).readAsBytes());
      }
      await api.call('POST', '/api/people/${widget.personId}/answers', body);
      if (hasAudio) {
        try {
          await File(path!).delete();
        } on FileSystemException {
          /* The answer is already saved. */
        }
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !recording,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop && recording) showError(context, '请先结束录音');
    },
    child: Scaffold(
      appBar: AppBar(title: const Text('记录这一刻')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Text(
            '慢慢说，我们在听。',
            style: TextStyle(fontSize: 25, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 10),
          const Text(
            '录音保留您的原声，每段最长 3 分钟。转写后可以修改，也可以直接输入文字。',
            style: TextStyle(color: Colors.black54, height: 1.6),
          ),
          const SizedBox(height: 25),
          Container(
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              children: [
                Icon(
                  recording ? Icons.graphic_eq : Icons.mic_none_rounded,
                  size: 48,
                  color: accent,
                ),
                const SizedBox(height: 10),
                Text(
                  recording
                      ? '正在录音…'
                      : hasAudio
                      ? '录音已保存在这台设备'
                      : '点按开始录音',
                  style: const TextStyle(fontSize: 16),
                ),
                const SizedBox(height: 16),
                FilledButton.tonalIcon(
                  onPressed: busy
                      ? null
                      : recording
                      ? stop
                      : start,
                  icon: Icon(recording ? Icons.stop : Icons.mic),
                  label: Text(
                    recording
                        ? '结束录音'
                        : hasAudio
                        ? '重新录音'
                        : '开始录音',
                  ),
                ),
                if (hasAudio && !recording)
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 10,
                    children: [
                      TextButton.icon(
                        onPressed: busy
                            ? null
                            : () async {
                                try {
                                  await player.play(DeviceFileSource(path!));
                                } catch (e) {
                                  if (context.mounted) showError(context, e);
                                }
                              },
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('试听'),
                      ),
                      TextButton.icon(
                        onPressed: busy ? null : transcribe,
                        icon: const Icon(Icons.text_fields),
                        label: Text(busy ? '处理中…' : '转成文字'),
                      ),
                    ],
                  ),
              ],
            ),
          ),
          const SizedBox(height: 22),
          const Text(
            '讲述内容',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: text,
            minLines: 6,
            maxLines: 12,
            decoration: const InputDecoration(hintText: '转写结果会出现在这里，也可以直接输入…'),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: busy || recording ? null : submit,
            child: const Text('保存并继续'),
          ),
          const SizedBox(height: 12),
          const Text(
            '离开后，未提交的录音仍保存在设备上，重新进入可试听或转写。',
            style: TextStyle(color: Colors.black54, height: 1.5),
          ),
        ],
      ),
    ),
  );
}

class ChapterPage extends StatefulWidget {
  final Map<String, dynamic> chapter;
  final Api? client;
  final VoidCallback? onSaved;
  const ChapterPage({
    super.key,
    required this.chapter,
    this.client,
    this.onSaved,
  });
  @override
  State<ChapterPage> createState() => _ChapterPageState();
}

class _ChapterPageState extends State<ChapterPage> {
  late final TextEditingController title, content;
  bool busy = false;
  String? url;
  @override
  void initState() {
    super.initState();
    title = TextEditingController(text: widget.chapter['title']);
    content = TextEditingController(text: widget.chapter['content']);
    loadUrl();
  }

  Future<void> loadUrl() async {
    final value = await secure.read(key: 'share_${widget.chapter['id']}');
    if (mounted) setState(() => url = value);
  }

  @override
  void dispose() {
    title.dispose();
    content.dispose();
    super.dispose();
  }

  Future<void> save() async {
    setState(() => busy = true);
    try {
      await (widget.client ?? api).call(
        'PUT',
        '/api/chapters/${widget.chapter['id']}',
        {'title': title.text.trim(), 'content': content.text.trim()},
      );
      widget.onSaved?.call();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('章节已保存')));
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> share() async {
    setState(() => busy = true);
    try {
      final result = await (widget.client ?? api).call(
        'POST',
        '/api/chapters/${widget.chapter['id']}/share',
      );
      final value = result['url'] as String;
      await secure.delete(key: 'share_audio_count_${widget.chapter['id']}');
      await secure.write(key: 'share_${widget.chapter['id']}', value: value);
      if (mounted) setState(() => url = value);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> revoke() async {
    final yes = await showChatSheet<bool>(
      context: context,
      builder: (c) => ChatSheetDialog(
        title: const Text('撤销本章所有分享？'),
        content: const Text('已印在电子书里的二维码也将无法播放。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('撤销'),
          ),
        ],
      ),
    );
    if (yes != true) return;
    setState(() => busy = true);
    try {
      await (widget.client ?? api).call(
        'DELETE',
        '/api/chapters/${widget.chapter['id']}/shares',
      );
      await secure.delete(key: 'share_${widget.chapter['id']}');
      await secure.delete(key: 'share_audio_count_${widget.chapter['id']}');
      if (mounted) setState(() => url = null);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('编辑章节'),
      actions: [
        TextButton(onPressed: busy ? null : save, child: const Text('保存')),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(22),
      children: [
        const Text(
          '章节标题',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        TextField(controller: title),
        const SizedBox(height: 20),
        const Text(
          '故事正文',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: content,
          minLines: 10,
          maxLines: null,
          style: const TextStyle(fontSize: 17, height: 1.8),
        ),
        const SizedBox(height: 25),
        const Text(
          '原声回听',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        const Text(
          '持二维码的人可以阅读整章正文和图片，查看每段录音对应的提问，并收听原声。请在分享前征得讲述者同意。',
          style: TextStyle(color: Colors.black54, height: 1.6),
        ),
        const SizedBox(height: 15),
        if (url != null) ...[
          Center(
            child: Container(
              color: Colors.white,
              padding: const EdgeInsets.all(12),
              child: SizedBox(
                width: 180,
                height: 180,
                child: CustomPaint(painter: QrPainter(url!)),
              ),
            ),
          ),
          const SizedBox(height: 10),
          TextButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: url!));
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('链接已复制')));
            },
            icon: const Icon(Icons.copy),
            label: const Text('复制回听链接'),
          ),
          TextButton(
            onPressed: busy ? null : revoke,
            child: const Text('撤销本章所有分享'),
          ),
        ] else
          OutlinedButton.icon(
            onPressed: busy ? null : share,
            icon: const Icon(Icons.qr_code),
            label: const Text('生成原声二维码'),
          ),
      ],
    ),
  );
}

List<List<bool>> bookQrModules(String url) {
  if (url.isEmpty) return const [];
  final image = QrImage(
    QrCode.fromData(data: url, errorCorrectLevel: QrErrorCorrectLevel.M),
  );
  return List.generate(
    image.moduleCount,
    (y) => List.generate(image.moduleCount, (x) => image.isDark(y, x)),
  );
}

class QrPainter extends CustomPainter {
  final String data;
  QrPainter(this.data);
  @override
  void paint(Canvas canvas, Size size) {
    final qr = QrCode.fromData(
      data: data,
      errorCorrectLevel: QrErrorCorrectLevel.M,
    );
    final image = QrImage(qr);
    final cell = math.min(size.width, size.height) / (image.moduleCount + 8);
    final p = Paint()..color = Colors.black;
    for (var y = 0; y < image.moduleCount; y++) {
      for (var x = 0; x < image.moduleCount; x++) {
        if (image.isDark(y, x)) {
          canvas.drawRect(
            Rect.fromLTWH((x + 4) * cell, (y + 4) * cell, cell + .1, cell + .1),
            p,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant QrPainter oldDelegate) =>
      oldDelegate.data != data;
}

class BookPage extends StatefulWidget {
  final String name;
  final String? title, author, bookId;
  final Api? client;
  final List<Map<String, dynamic>> chapters;
  final VoidCallback? onChaptersChanged;
  final bool interview;
  const BookPage({
    super.key,
    required this.name,
    this.chapters = const [],
    this.title,
    this.author,
    this.client,
    this.bookId,
    this.onChaptersChanged,
    this.interview = false,
  });

  @override
  State<BookPage> createState() => _BookPageState();
}

class _BookPageState extends State<BookPage> {
  final _chapterAnchors = <String, GlobalKey>{};
  late List<Map<String, dynamic>> chapters;
  Map<String, String> urls = {};
  bool loading = true, busy = false;
  String? loadError;
  String? _bookProgress;
  final _chapterPhotos = <String, Future<String>>{};
  Api get client => widget.client ?? api;

  @override
  void initState() {
    super.initState();
    chapters = widget.chapters;
    load();
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      loadError = null;
    });
    try {
      final id = widget.bookId;
      final rows = id == null
          ? widget.chapters
          : (await client
                        .call(
                          'GET',
                          '/api/books/$id/chapters?include_material=true'
                              '${widget.interview ? '&interview_only=true' : ''}',
                        )
                        .timeout(const Duration(seconds: 15))
                    as List)
                .map((row) => Map<String, dynamic>.from(row as Map))
                .toList();
      if (!mounted) return;
      setState(() {
        _chapterPhotos.clear();
        chapters = rows
            .where((row) => _hasBody(row) || _narrations(row).isNotEmpty)
            .toList();
      });
      final found = await Future.wait(
        chapters.map((chapter) async {
          final id = chapter['id'] as String;
          try {
            return MapEntry(id, await secure.read(key: 'share_$id'));
          } catch (_) {
            return MapEntry<String, String?>(id, null);
          }
        }),
      );
      if (mounted) {
        setState(
          () => urls = {
            for (final item in found)
              if (item.value != null) item.key: item.value!,
          },
        );
      }
    } catch (_) {
      if (mounted) setState(() => loadError = '暂时无法加载书稿');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _editChapter() async {
    final chapter = await showChatSheet<Map<String, dynamic>>(
      context: context,
      builder: (sheet) => ListView(
        shrinkWrap: true,
        children: [
          const ListTile(title: Text('选择要编辑的章节')),
          for (final chapter in chapters.where(_hasBody))
            ListTile(
              title: Text(chapter['title'] as String),
              onTap: () => Navigator.pop(sheet, chapter),
            ),
        ],
      ),
    );
    if (!mounted || chapter == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChapterPage(
          chapter: chapter,
          client: client,
          onSaved: widget.onChaptersChanged,
        ),
      ),
    );
    if (mounted) await load();
  }

  void _jumpToChapter(String id) {
    final target = _chapterAnchors[id]?.currentContext;
    if (target != null) {
      Scrollable.ensureVisible(
        target,
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
      );
    }
  }

  bool _hasAudio(Map<String, dynamic> chapter) =>
      chapter['has_audio'] == 1 || chapter['has_audio'] == true;

  bool _hasBody(Map<String, dynamic> chapter) =>
      (chapter['content'] as String? ?? '').trim().isNotEmpty ||
      _blocks(chapter).any((block) => block['kind'] == 'image');

  List<Map> _blocks(Map<String, dynamic> chapter) =>
      (chapter['blocks'] as List?)?.cast<Map>() ?? const [];

  String _photoPath(Map<String, dynamic> chapter, Map block) =>
      chapterImagePath(
        widget.bookId!,
        chapter['topic_id'] as String,
        block['image_id'] as String,
      );

  Future<String> _photoData(Map<String, dynamic> chapter, Map block) {
    final path = _photoPath(chapter, block);
    return _chapterPhotos.putIfAbsent(
      path,
      () => loadChapterImage(client, path),
    );
  }

  Iterable<Widget> _paragraphs(String content) sync* {
    for (final paragraph
        in content.split(RegExp(r'\n+')).where((s) => s.trim().isNotEmpty)) {
      yield Padding(
        padding: const EdgeInsets.only(bottom: 15),
        child: Text(
          '　　${paragraph.trim()}',
          style: const TextStyle(fontSize: 17, height: 1.9),
        ),
      );
    }
  }

  Iterable<Widget> _manuscript(Map<String, dynamic> chapter) sync* {
    final blocks = _blocks(chapter);
    if (blocks.isEmpty) {
      yield* _paragraphs(chapter['content'] as String);
      return;
    }
    for (final block in blocks) {
      if (block['kind'] == 'text') {
        yield* _paragraphs(block['text'] as String);
      } else if (widget.bookId != null) {
        yield Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: FutureBuilder<String>(
            future: _photoData(chapter, block),
            builder: (context, result) {
              if (result.hasError) {
                return TextButton(
                  onPressed: () => setState(
                    () => _chapterPhotos.remove(_photoPath(chapter, block)),
                  ),
                  child: const Text('图片加载失败，重试'),
                );
              }
              if (!result.hasData) return const LinearProgressIndicator();
              return Image.memory(
                base64Decode(result.data!),
                semanticLabel: '章节图片',
              );
            },
          ),
        );
      }
    }
  }

  List<dynamic> _narrations(Map<String, dynamic> chapter) =>
      chapter['narrations'] as List? ?? const [];

  Future<void> _createQr(
    Map<String, dynamic> chapter, {
    bool includeTopicAudio = true,
  }) async {
    final id = chapter['id'] as String;
    final includeTopic = includeTopicAudio && chapter['audio_count'] != null;
    final share = await client.call(
      'POST',
      '/api/chapters/$id/share${includeTopic ? '?include_topic_audio=true' : ''}',
    );
    final url = share['url'] as String;
    await secure.delete(key: 'share_audio_count_$id');
    await secure.write(key: 'share_$id', value: url);
    if (share['audio_count'] case final int count) {
      await secure.write(key: 'share_audio_count_$id', value: '$count');
    }
    urls[id] = url;
  }

  Future<void> _previewQr(Map<String, dynamic> chapter) async {
    if (busy || loading || loadError != null) return;
    setState(() => busy = true);
    try {
      await _createQr(chapter);
    } catch (error) {
      if (mounted) showError(context, error);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  String _chapterLabel(Map<String, dynamic> chapter, int index) {
    if (widget.interview || widget.title == null) return '第 ${index + 1} 章';
    final number = chapter['topic_number'];
    return number == null ? '原有章节' : '第 $number 章';
  }

  Future<void> printBook() async {
    if (busy || loading || loadError != null) return;
    setState(() => busy = true);
    try {
      await _exportPdf();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _makeBook() async {
    if (busy || loading || loadError != null || chapters.isEmpty) return;
    setState(() => busy = true);
    var attemptedChapter = false;
    try {
      final confirmed = await showChatSheet<bool>(
        context: context,
        builder: (sheet) => ChatSheetDialog(
          title: const Text('制作这本回忆录'),
          content: Text(
            widget.interview
                ? '用已保存的书稿生成 PDF。含原声的章节会附上二维码，可查看整章内容并收听录音。'
                : 'AI 会整理未成稿的章节，已有正文会保留。PDF 的原声二维码可查看整章内容和对应提问，并收听录音。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(sheet),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(sheet, true),
              child: const Text('开始成书'),
            ),
          ],
        ),
      );
      if (!mounted || confirmed != true) return;
      final unedited = chapters.where((chapter) => !_hasBody(chapter)).toList();
      if (unedited.isNotEmpty) {
        final bookId = widget.bookId!;
        if (!await consent(context, bookId) || !mounted) return;
        for (final (index, chapter) in unedited.indexed) {
          if (!mounted) return;
          setState(() {
            _bookProgress =
                '正在整理 ${index + 1}/${unedited.length} · ${chapter['title']}';
          });
          attemptedChapter = true;
          await client.call(
            'POST',
            "/api/books/$bookId/topics/${chapter['topic_id']}/compile",
          );
        }
        if (!mounted) return;
        await load();
        widget.onChaptersChanged?.call();
        if (!mounted || loadError != null) return;
        if (chapters.any((chapter) => !_hasBody(chapter))) {
          throw Exception('有章节尚未整理，请重新点「成书」');
        }
      }
      if (!mounted) return;
      setState(() => _bookProgress = '正在排版并准备原声二维码…');
      await _exportPdf(preview: true);
    } catch (error) {
      if (mounted && attemptedChapter) {
        await load();
        widget.onChaptersChanged?.call();
      }
      if (mounted) showError(context, error);
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          _bookProgress = null;
        });
      }
    }
  }

  Future<void> _exportPdf({bool preview = false}) async {
    final body = chapters.where(_hasBody).toList();
    if (body.isEmpty) return;
    if (widget.title != null) {
      final includeTopicAudio = preview || widget.bookId != null;
      for (final chapter in body.where(
        (chapter) => includeTopicAudio
            ? _hasAudio(chapter)
            : (chapter['has_chapter_audio'] as bool? ?? _hasAudio(chapter)),
      )) {
        if (!mounted) return;
        final id = chapter['id'] as String;
        final count = includeTopicAudio ? chapter['audio_count'] : null;
        final current =
            urls.containsKey(id) &&
            (count == null ||
                await secure.read(key: 'share_audio_count_$id') == '$count');
        if (!current) {
          await _createQr(chapter, includeTopicAudio: includeTopicAudio);
        }
      }
    }
    final exportChapters = <Map<String, dynamic>>[];
    for (final (index, chapter) in body.indexed) {
      final blocks = _blocks(chapter);
      final url = widget.interview && !_hasAudio(chapter)
          ? ''
          : urls[chapter['id']] ?? '';
      exportChapters.add({
        'title': chapter['title'],
        'content': chapter['content'],
        'url': url,
        if (defaultTargetPlatform == TargetPlatform.android)
          'qr': bookQrModules(url),
        'label': _chapterLabel(chapter, index),
        if (blocks.any((block) => block['kind'] == 'image'))
          'blocks': [
            for (final block in blocks)
              if (block['kind'] == 'image')
                {'image': await _photoData(chapter, block)}
              else
                {'text': block['text']},
          ],
      });
    }
    if (!mounted) return;
    await const MethodChannel(
      'life_pages/print',
    ).invokeMethod(preview ? 'previewBook' : 'printBook', {
      'name': widget.name,
      'title': ?widget.title,
      'author': ?widget.author,
      'chapters': exportChapters,
    });
  }

  Widget _paperPanel(Widget child, {Key? key}) => Material(
    key: key,
    color: const Color(0xfffffdfa),
    shape: RoundedRectangleBorder(
      side: const BorderSide(color: Color(0xffe9e3d8)),
      borderRadius: BorderRadius.circular(14),
    ),
    clipBehavior: Clip.antiAlias,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(22, 24, 22, 24),
      child: child,
    ),
  );

  List<Widget> _narrationEntries(Map<String, dynamic> chapter) => [
    for (final item in _narrations(chapter))
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(item['text'] as String, style: const TextStyle(height: 1.65)),
            if (item['has_audio'] == true || item['has_audio'] == 1)
              AudioButton(id: item['id'] as String, client: client),
          ],
        ),
      ),
  ];

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: paper,
    appBar: AppBar(
      title: const Text('预览全书'),
      centerTitle: true,
      backgroundColor: paper,
      actions: [
        if (widget.bookId == null && chapters.any(_hasBody))
          IconButton(
            tooltip: '编辑章节',
            onPressed: loading || busy || loadError != null
                ? null
                : _editChapter,
            icon: const Icon(Icons.edit_outlined),
          ),
        if (widget.bookId != null && supportsNativeBookExport)
          TextButton(
            onPressed: loading || busy || loadError != null || chapters.isEmpty
                ? null
                : _makeBook,
            child: const Text('成书'),
          ),
      ],
      bottom: _bookProgress == null
          ? null
          : PreferredSize(
              preferredSize: const Size.fromHeight(48),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 2, 20, 8),
                child: Column(
                  children: [
                    Text(
                      _bookProgress!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    const LinearProgressIndicator(),
                  ],
                ),
              ),
            ),
    ),
    bottomNavigationBar: !supportsNativeBookExport || !chapters.any(_hasBody)
        ? null
        : SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 10, 18, 12),
              child: FilledButton.icon(
                onPressed: busy || loading || loadError != null
                    ? null
                    : printBook,
                icon: const Icon(Icons.picture_as_pdf_outlined),
                label: const Text('导出 PDF'),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xff40372b),
                ),
              ),
            ),
          ),
    body: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          BookCover(
            title: widget.title ?? '${widget.name}的回忆录',
            author: widget.author == null ? '时光有声，故事有迹' : '${widget.author} 著',
          ),
          const SizedBox(height: 16),
          _paperPanel(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '目录',
                  style: TextStyle(
                    fontFamily: 'Songti SC',
                    fontSize: 27,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (loading && chapters.isEmpty) ...[
                  const SizedBox(height: 14),
                  const LinearProgressIndicator(),
                ] else if (loadError != null) ...[
                  const SizedBox(height: 10),
                  Text(loadError!),
                  TextButton(onPressed: load, child: const Text('重试')),
                ] else if (chapters.isEmpty) ...[
                  const SizedBox(height: 10),
                  const Text('已有正文的章节会显示在这里。'),
                ] else
                  for (final (index, chapter) in chapters.indexed)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(chapter['title'] as String),
                      subtitle: Text(
                        _hasBody(chapter)
                            ? _chapterLabel(chapter, index)
                            : '${_chapterLabel(chapter, index)} · 已讲述，待整理',
                      ),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => _jumpToChapter(chapter['id'] as String),
                    ),
              ],
            ),
          ),
          if (!loading && loadError == null && chapters.isEmpty) ...[
            const SizedBox(height: 16),
            _paperPanel(
              const Column(
                children: [
                  Icon(Icons.notes_rounded, size: 36, color: Color(0xff8b7659)),
                  SizedBox(height: 12),
                  Text(
                    '书稿还没有正文',
                    style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
                  ),
                  SizedBox(height: 8),
                  Text('讲一段往事，整理成第一篇正文。', textAlign: TextAlign.center),
                ],
              ),
            ),
          ],
          ...chapters.asMap().entries.map((e) {
            final ch = e.value;
            final url = urls[ch['id']];
            return Padding(
              padding: const EdgeInsets.only(top: 16),
              child: _paperPanel(
                key: _chapterAnchors.putIfAbsent(
                  ch['id'] as String,
                  GlobalKey.new,
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _chapterLabel(ch, e.key),
                      style: const TextStyle(color: accent, letterSpacing: 2),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      ch['title'],
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 25),
                    ..._manuscript(ch),
                    if (_narrations(ch).isNotEmpty)
                      if (_hasBody(ch))
                        ExpansionTile(
                          tilePadding: EdgeInsets.zero,
                          title: const Text('查看讲述原文'),
                          children: _narrationEntries(ch),
                        )
                      else ...[
                        const Text('讲述原文 · 待整理'),
                        const SizedBox(height: 8),
                        ..._narrationEntries(ch),
                      ],
                    if (url != null) ...[
                      const SizedBox(height: 16),
                      Center(
                        child: SizedBox(
                          width: 140,
                          height: 140,
                          child: CustomPaint(painter: QrPainter(url)),
                        ),
                      ),
                      const Center(
                        child: Text(
                          '扫码聆听原声',
                          style: TextStyle(color: Colors.black54),
                        ),
                      ),
                    ] else if (_hasBody(ch) && _hasAudio(ch))
                      TextButton.icon(
                        onPressed: busy || loading || loadError != null
                            ? null
                            : () => _previewQr(ch),
                        icon: const Icon(Icons.qr_code_rounded),
                        label: const Text('生成原声二维码'),
                      ),
                  ],
                ),
              ),
            );
          }),
          if (supportsNativeBookExport && chapters.any(_hasAudio)) ...[
            const SizedBox(height: 20),
            const Text(
              '点「成书」可将各章录音加入 PDF 的原声二维码。',
              style: TextStyle(color: Colors.black54, height: 1.6),
            ),
          ],
        ],
      ),
    ),
  );
}
