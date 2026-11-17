import 'dart:async';

import 'package:flutter/material.dart';

import 'account/login_sheet.dart';
import 'account/profile_editor.dart';
import 'account/social_sign_in.dart';
import 'bookshelf.dart' show BookRecord, showRecentlyDeleted;
import 'chat_sheet.dart';
import 'legal_urls.dart';
import 'main.dart'
    show Api, aiConsentKey, paper, replyConsentKey, secure, showError;
import 'membership/membership_sheet.dart';
import 'reading_preferences.dart';

enum PageBackground {
  paperTone('窗光暖纸', paper, AssetImage('assets/backgrounds/warm-paper.webp')),
  celadon(
    '青岚远山',
    Color(0xffe9efea),
    AssetImage('assets/backgrounds/celadon-mist.webp'),
  ),
  album(
    '旧相册',
    Color(0xfff4e8db),
    AssetImage('assets/backgrounds/photo-album.webp'),
  );

  const PageBackground(this.label, this.color, this.image);
  final String label;
  final Color color;
  final AssetImage image;
}

class MyPage extends StatefulWidget {
  const MyPage({
    super.key,
    required this.active,
    this.navigationClearance = 0,
    required this.trash,
    this.books = const [],
    required this.client,
    required this.background,
    required this.busy,
    required this.onBackgroundChanged,
    required this.onRestore,
    this.email,
    this.accountProvider,
    this.onSignIn,
    this.onSignOut,
  });

  final bool active;
  final double navigationClearance;
  final List<BookRecord> trash;
  final List<BookRecord> books;
  final Api client;
  final PageBackground background;
  final bool busy;
  final ValueChanged<PageBackground> onBackgroundChanged;
  final ValueChanged<String> onRestore;
  final String? email, accountProvider;
  final Future<void> Function(Map<String, dynamic>)? onSignIn;
  final Future<void> Function()? onSignOut;

  @override
  State<MyPage> createState() => _MyPageState();
}

class _MyPageState extends State<MyPage> with WidgetsBindingObserver {
  var _profile = const AccountProfile();
  var _voice = ReplyVoice.vivi;
  Timer? _midnight;
  int _profileRequest = 0;
  bool _savingScale = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.active) _activate();
  }

  @override
  void didUpdateWidget(covariant MyPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.active && widget.active) _activate();
    if (oldWidget.active && !widget.active) _midnight?.cancel();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && widget.active) _activate();
  }

  @override
  void dispose() {
    _midnight?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _activate() {
    unawaited(_loadProfile());
    unawaited(_loadVoice());
    _scheduleRefresh();
  }

  void _scheduleRefresh() {
    _midnight?.cancel();
    const offset = Duration(hours: 8);
    final now = DateTime.now().toUtc().add(offset);
    final next = DateTime.utc(now.year, now.month, now.day + 1);
    _midnight = Timer(next.difference(now), () {
      if (!mounted || !widget.active) return;
      unawaited(_loadProfile());
      _scheduleRefresh();
    });
  }

  Future<void> _loadProfile() async {
    final request = ++_profileRequest;
    try {
      final data = await widget.client.call('GET', '/api/profile');
      if (mounted && request == _profileRequest) {
        setState(
          () => _profile = AccountProfile.fromApi(data as Map<String, dynamic>),
        );
      }
    } catch (_) {
      // Offline browsing still shows the free plan and the last known profile.
    }
  }

  Future<void> _loadVoice() async {
    final voice = await ReplyVoice.load();
    if (mounted) setState(() => _voice = voice);
  }

  Future<void> _changeScale(bool enabled) async {
    setState(() => _savingScale = true);
    try {
      await saveReadingScale(enabled);
    } catch (_) {
      if (mounted) showError(context, '暂时无法保存大字模式');
    } finally {
      if (mounted) setState(() => _savingScale = false);
    }
  }

  Future<void> _chooseVoice() async {
    final selected = await showChatSheet<ReplyVoice>(
      context: context,
      builder: (sheet) => ListView(
        shrinkWrap: true,
        children: [
          const ListTile(title: Text('朗读声音')),
          for (final voice in ReplyVoice.values)
            ListTile(
              title: Text(voice.label),
              subtitle: Text(voice.gender),
              selected: voice == _voice,
              trailing: voice == _voice
                  ? const Icon(Icons.check_rounded)
                  : null,
              onTap: () => Navigator.pop(sheet, voice),
            ),
        ],
      ),
    );
    if (!mounted || selected == null || selected == _voice) return;
    try {
      await selected.save();
      if (mounted) setState(() => _voice = selected);
    } catch (_) {
      if (mounted) showError(context, '暂时无法保存朗读声音');
    }
  }

  String get _accountLabel => switch (widget.accountProvider) {
    'apple.com' => 'Apple 账号',
    'google.com' => 'Google 账号',
    'email' => '邮箱账号',
    _ => '未登录',
  };

  void _settings() {
    final settings = _AccountSettingsPage(
      client: widget.client,
      background: widget.background.color,
      signedIn: widget.accountProvider != null,
      books: [...widget.books, ...widget.trash],
      onSignIn: widget.onSignIn,
      onSignOut: widget.onSignOut,
    );
    Navigator.of(
      context,
    ).push<void>(MaterialPageRoute(builder: (_) => settings));
  }

  Future<void> _openProfile() async {
    if (widget.accountProvider == null) {
      await showAccountLogin(
        context,
        client: widget.client,
        onSignedIn: widget.onSignIn,
      );
      return;
    }
    final updated = await showChatSheet<AccountProfile>(
      context: context,
      builder: (_) => ProfileEditor(client: widget.client, profile: _profile),
    );
    if (mounted && updated != null) {
      _profileRequest++;
      setState(() => _profile = updated);
    }
  }

  Future<void> _pickBackground(BuildContext context) async {
    final next = await showChatSheet<PageBackground>(
      context: context,
      builder: (sheet) => Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(0, 12, 0, 14),
                child: Text(
                  '页面背景',
                  style: Theme.of(sheet).textTheme.titleLarge,
                ),
              ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 8,
                children: [
                  for (final choice in PageBackground.values)
                    Expanded(
                      child: _BackgroundOption(
                        background: choice,
                        selected: choice == widget.background,
                        onTap: () => Navigator.pop(sheet, choice),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (context.mounted && next != null) {
      widget.onBackgroundChanged(next);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: widget.navigationClearance),
      child: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 17),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '我的',
                      style: theme.textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  IconButton.filledTonal(
                    tooltip: '设置',
                    onPressed: _settings,
                    icon: const Icon(Icons.settings_outlined),
                    style: IconButton.styleFrom(
                      backgroundColor: const Color(0xfffffdfa),
                      foregroundColor: _profileAccent,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                children: [
                  Material(
                    type: MaterialType.transparency,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: _openProfile,
                      child: Semantics(
                        onTapHint: widget.accountProvider == null
                            ? '登录账号'
                            : '编辑用户名和头像',
                        child: Row(
                          children: [
                            ProfileAvatar(image: _profile.avatar, size: 64),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _profile.name.isEmpty
                                        ? _accountLabel
                                        : _profile.name,
                                    style: theme.textTheme.titleLarge?.copyWith(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    widget.email ??
                                        (widget.accountProvider == null
                                            ? '登录后可自定义个人资料'
                                            : '$_accountLabel · 已登录'),
                                    style: theme.textTheme.bodyMedium,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            Icon(
                              widget.accountProvider == null
                                  ? Icons.chevron_right_rounded
                                  : Icons.edit_outlined,
                              size: 18,
                              color: _profileAccent,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 22),
                  _FreePlanCard(
                    remaining: _profile.remaining,
                    limit: _profile.limit,
                    onTap: () => showMembership(context),
                  ),
                  const SizedBox(height: 23),
                  Text(
                    '使用偏好',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: _profileAccent,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _ProfileGroup(
                    children: [
                      ValueListenableBuilder(
                        valueListenable: largeTextMode,
                        builder: (_, enabled, _) => SwitchListTile(
                          secondary: const Icon(
                            Icons.format_size_rounded,
                            color: _profileAccent,
                          ),
                          title: const Text('大字模式'),
                          subtitle: const Text('放大文字、按钮和导航栏'),
                          value: enabled,
                          onChanged: _savingScale ? null : _changeScale,
                        ),
                      ),
                      const Divider(height: 1, indent: 54, endIndent: 16),
                      _entry(
                        Icons.volume_up_outlined,
                        '朗读声音',
                        _chooseVoice,
                        subtitle: '${_voice.label} · ${_voice.gender}',
                      ),
                      const Divider(height: 1, indent: 54, endIndent: 16),
                      _entry(
                        Icons.palette_outlined,
                        '页面背景',
                        () => _pickBackground(context),
                        subtitle: widget.background.label,
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _ProfileGroup(
                    children: [
                      _entry(
                        Icons.delete_outline_rounded,
                        '最近删除',
                        widget.busy
                            ? null
                            : () => showRecentlyDeleted(
                                context,
                                books: widget.trash,
                                onRestore: widget.onRestore,
                              ),
                        subtitle: widget.trash.isEmpty
                            ? null
                            : '${widget.trash.length} 本书',
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Widget _entry(
  IconData icon,
  String label,
  VoidCallback? onTap, {
  String? subtitle,
}) => ListTile(
  leading: Icon(icon, color: _profileAccent),
  title: Text(label),
  subtitle: subtitle == null ? null : Text(subtitle),
  trailing: const Icon(Icons.chevron_right_rounded),
  onTap: onTap,
);
const _profileAccent = Color(0xff745832);

class _BackgroundOption extends StatelessWidget {
  const _BackgroundOption({
    required this.background,
    required this.selected,
    required this.onTap,
  });

  final PageBackground background;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(14);
    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 0.5,
              child: Ink(
                decoration: BoxDecoration(
                  color: background.color,
                  borderRadius: radius,
                  image: DecorationImage(
                    image: ResizeImage(background.image, width: 320),
                    fit: BoxFit.cover,
                  ),
                  border: Border.all(
                    color: selected ? _profileAccent : const Color(0xffded6ca),
                    width: selected ? 2 : 1,
                  ),
                ),
                child: selected
                    ? const Align(
                        alignment: Alignment.topRight,
                        child: Padding(
                          padding: EdgeInsets.all(7),
                          child: CircleAvatar(
                            radius: 11,
                            backgroundColor: _profileAccent,
                            foregroundColor: Colors.white,
                            child: Icon(Icons.check_rounded, size: 16),
                          ),
                        ),
                      )
                    : null,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(2, 8, 2, 4),
              child: Text(
                background.label,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AccountSettingsPage extends StatelessWidget {
  const _AccountSettingsPage({
    required this.client,
    required this.background,
    required this.signedIn,
    required this.books,
    required this.onSignIn,
    required this.onSignOut,
  });

  final Api client;
  final Color background;
  final bool signedIn;
  final List<BookRecord> books;
  final Future<void> Function(Map<String, dynamic>)? onSignIn;
  final Future<void> Function()? onSignOut;

  void _returnAfterAccountChange(BuildContext context) {
    if (ModalRoute.of(context)?.isCurrent == true) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _login(BuildContext context) async {
    var didSignIn = false;
    final callback = onSignIn;
    await showAccountLogin(
      context,
      client: client,
      onSignedIn: callback == null
          ? null
          : (session) async {
              await callback(session);
              didSignIn = true;
            },
    );
    if (didSignIn && context.mounted) _returnAfterAccountChange(context);
  }

  Future<void> _logout(BuildContext context) async {
    final confirmed = await showChatSheet<bool>(
      context: context,
      builder: (sheet) => ChatSheetDialog(
        title: const Text('退出登录'),
        content: const Text('退出后会回到访客身份。使用已绑定的登录方式，可以再次查看此账号的书稿。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(sheet),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(sheet, true),
            child: const Text('退出登录'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await onSignOut?.call();
      if (context.mounted) _returnAfterAccountChange(context);
    } catch (error) {
      if (context.mounted) showError(context, error);
    }
  }

  void _orders(BuildContext context) {
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (context) => Scaffold(
          backgroundColor: background,
          appBar: AppBar(
            title: const Text('我的订单'),
            backgroundColor: background,
          ),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: const [
                _ProfileGroup(
                  children: [
                    ListTile(
                      leading: Icon(
                        Icons.receipt_long_outlined,
                        color: _profileAccent,
                      ),
                      title: Text('订单功能尚未开放。'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: background,
    appBar: AppBar(title: const Text('设置'), backgroundColor: background),
    body: SafeArea(
      top: false,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _ProfileGroup(
            children: [
              if (!signedIn)
                _entry(Icons.login_rounded, '登录账号', () => _login(context))
              else ...[
                if (SocialSignIn.available) ...[
                  _entry(
                    Icons.link_rounded,
                    '绑定登录方式',
                    () => showAccountLink(context, client: client),
                  ),
                  const Divider(height: 1, indent: 54, endIndent: 16),
                ],
                _entry(Icons.logout_rounded, '退出登录', () => _logout(context)),
              ],
              const Divider(height: 1, indent: 54, endIndent: 16),
              _entry(
                Icons.receipt_long_outlined,
                '我的订单',
                () => _orders(context),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _ProfileGroup(
            children: [
              _entry(Icons.auto_awesome_outlined, 'AI 数据授权', () {
                Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (_) =>
                        _AIPrivacyPage(client: client, books: books),
                  ),
                );
              }),
              _entry(Icons.mic_none, '权限说明', () {
                AppLegalUrls.open(context, AppLegalUrls.permissions);
              }),
              _entry(Icons.privacy_tip_outlined, '隐私政策', () {
                AppLegalUrls.open(context, AppLegalUrls.privacy);
              }),
              _entry(Icons.article_outlined, '使用条款（Apple EULA）', () {
                AppLegalUrls.open(context, AppLegalUrls.terms);
              }),
              _entry(Icons.help_outline, '帮助与反馈', () {
                AppLegalUrls.open(context, AppLegalUrls.support);
              }),
            ],
          ),
        ],
      ),
    ),
  );
}

class _AIPrivacyPage extends StatefulWidget {
  const _AIPrivacyPage({required this.client, required this.books});

  final Api client;
  final List<BookRecord> books;

  @override
  State<_AIPrivacyPage> createState() => _AIPrivacyPageState();
}

class _AIPrivacyPageState extends State<_AIPrivacyPage> {
  bool? _background;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final state = await widget.client.call(
        'GET',
        '/api/profile/background-ai',
      );
      if (mounted) setState(() => _background = state['enabled'] == true);
    } catch (error) {
      if (mounted) showError(context, error);
    }
  }

  Future<void> _setBackground(bool enabled) async {
    setState(() => _saving = true);
    try {
      if (enabled) {
        final allowed = await showDialog<bool>(
          context: context,
          builder: (dialog) => AlertDialog(
            title: const Text('允许后台 AI 整理？'),
            content: const Text(
              'LifePages 会把此账号各本书的相关讲述、人物资料和已有正文发给阿里云百炼，'
              '用于在后台生成草稿或提取长期记忆。请先取得各位讲述者的同意。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialog),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialog, true),
                child: const Text('同意并开启'),
              ),
            ],
          ),
        );
        if (allowed != true || !mounted) return;
      }
      await widget.client.call('PUT', '/api/profile/background-ai', {
        'enabled': enabled,
      });
      if (mounted) setState(() => _background = enabled);
    } catch (error) {
      if (mounted) showError(context, error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _revoke() async {
    setState(() => _saving = true);
    try {
      for (final book in widget.books) {
        final id = book['id'] as String;
        await secure.delete(key: aiConsentKey(id));
        await secure.delete(key: replyConsentKey(id));
      }
      if (mounted) showError(context, '已撤回本机的聊天、转写与播报授权');
    } catch (error) {
      if (mounted) showError(context, error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('AI 数据授权')),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _ProfileGroup(
            children: [
              SwitchListTile(
                title: const Text('后台 AI 整理'),
                subtitle: Text(
                  _background == null ? '授权状态暂不可用' : '应用关闭时也可生成草稿和提取长期记忆',
                ),
                value: _background ?? false,
                onChanged: _saving || _background == null
                    ? null
                    : _setBackground,
              ),
              if (_background == null)
                TextButton(onPressed: _load, child: const Text('重新加载')),
            ],
          ),
          const SizedBox(height: 16),
          _ProfileGroup(
            children: [
              ListTile(
                title: const Text('撤回本机 AI 授权'),
                subtitle: const Text('下次使用聊天、转写、手动 AI 整理或语音播报时会重新询问。'),
                onTap: _saving ? null : _revoke,
              ),
            ],
          ),
          TextButton(
            onPressed: () => AppLegalUrls.open(context, AppLegalUrls.privacy),
            child: const Text('查看隐私政策'),
          ),
        ],
      ),
    ),
  );
}

class _FreePlanCard extends StatelessWidget {
  const _FreePlanCard({
    required this.remaining,
    required this.limit,
    required this.onTap,
  });

  final int? remaining;
  final int limit;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Material(
      color: const Color(0xfffaf0df),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(19),
        side: const BorderSide(color: Color(0xffe8dac5)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(17),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '免费版',
                          style: text.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '查看会员方案',
                          style: text.bodyMedium?.copyWith(
                            color: _profileAccent,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Icon(
                    Icons.chevron_right_rounded,
                    color: _profileAccent,
                  ),
                ],
              ),
              const SizedBox(height: 9),
              const Divider(color: Color(0xffe8dac5)),
              const SizedBox(height: 6),
              Row(
                children: [
                  const Expanded(child: Text('今日 AI 追问')),
                  Text(
                    remaining == null
                        ? '每日 $limit 次'
                        : '剩余 $remaining / $limit 次',
                    style: text.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProfileGroup extends StatelessWidget {
  const _ProfileGroup({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Material(
    color: const Color(0xfffffdfa),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
      side: const BorderSide(color: Color(0xffe9e3d8)),
    ),
    clipBehavior: Clip.antiAlias,
    child: Column(children: children),
  );
}
