import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../chat_sheet.dart';
import '../legal_urls.dart';
import '../main.dart' show Api, errorText;
import 'social_sign_in.dart';

const _sheetColor = Color(0xfff5f2fa);
const _accent = Color(0xfff76f57);
const _foreground = Color(0xff2a2528);
const _muted = Color(0xff716b76);

Future<void> showAccountLogin(
  BuildContext context, {
  required Api client,
  Future<void> Function(Map<String, dynamic>)? onSignedIn,
}) => showModalBottomSheet<void>(
  context: context,
  useRootNavigator: true,
  useSafeArea: true,
  isScrollControlled: true,
  backgroundColor: Colors.transparent,
  barrierColor: Colors.black.withValues(alpha: .22),
  builder: (_) => _AccountLogin(client: client, onSignedIn: onSignedIn),
);

Future<void> showAccountLink(BuildContext context, {required Api client}) =>
    showChatSheet<void>(
      context: context,
      builder: (_) => _AccountLogin(client: client, link: true),
    );

enum _EmailMode {
  code('验证码登录'),
  password('密码登录'),
  register('注册账号'),
  reset('重设密码');

  const _EmailMode(this.label);
  final String label;

  bool get signingIn => this == code || this == password;
  bool get usesCode => this != password;
  String get purpose => signingIn ? 'login' : name;
}

enum _Action { sendCode, email, apple, google }

class _AccountLogin extends StatefulWidget {
  const _AccountLogin({
    required this.client,
    this.onSignedIn,
    this.link = false,
  });

  final Api client;
  final Future<void> Function(Map<String, dynamic>)? onSignedIn;
  final bool link;

  @override
  State<_AccountLogin> createState() => _AccountLoginState();
}

class _AccountLoginState extends State<_AccountLogin> {
  final _email = TextEditingController();
  final _code = TextEditingController();
  final _password = TextEditingController();
  final _confirmation = TextEditingController();
  var _mode = _EmailMode.code;
  _Action? _action;
  Timer? _timer;
  int _seconds = 0;
  bool _hidePassword = true;
  bool _messageIsError = false;
  String? _sentTo, _sentPurpose, _message;

  bool get _busy => _action != null;
  bool get _enabled => !_busy && widget.onSignedIn != null;
  String get _address => _email.text.trim().toLowerCase();

  @override
  void dispose() {
    _timer?.cancel();
    _email.dispose();
    _code.dispose();
    _password.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  void _switchMode(_EmailMode next) {
    if (_busy || _mode == next) return;
    setState(() {
      _mode = next;
      _code.clear();
      _password.clear();
      _confirmation.clear();
      _hidePassword = true;
      _message = null;
    });
  }

  Future<void> _run(_Action action, Future<void> Function() task) async {
    if (_busy) return;
    setState(() {
      _action = action;
      _message = null;
    });
    try {
      await task();
    } catch (error) {
      if (mounted) _feedback(errorText(error), error: true);
    } finally {
      if (mounted) setState(() => _action = null);
    }
  }

  void _feedback(String message, {bool error = false}) {
    setState(() {
      _message = message;
      _messageIsError = error;
    });
  }

  void _validateEmail(String address) {
    if (!RegExp(r'^\S+@\S+\.\S+$').hasMatch(address)) {
      throw Exception('请输入有效的邮箱地址');
    }
  }

  Future<void> _send() => _run(_Action.sendCode, () async {
    final address = _address;
    final purpose = _mode.purpose;
    _validateEmail(address);
    final result = await widget.client.call(
      'POST',
      '/api/auth/email-code/send',
      {'email': address, if (purpose != 'login') 'purpose': purpose},
    );
    if (!mounted) return;
    final seconds = result['retry_after'] as int? ?? 60;
    setState(() {
      _sentTo = address;
      _sentPurpose = purpose;
      _seconds = seconds;
    });
    _feedback('验证码已发送，请查收邮箱。');
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      setState(() => _seconds--);
      if (_seconds <= 0) timer.cancel();
    });
  });

  Future<void> _finishSignIn(dynamic result) async {
    if (!mounted) return;
    await widget.onSignedIn!(Map<String, dynamic>.from(result as Map));
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _submit() => _run(_Action.email, () async {
    final address = _address;
    _validateEmail(address);
    if (_mode.usesCode) {
      if (_sentTo != address || _sentPurpose != _mode.purpose) {
        throw Exception('请先发送验证码');
      }
      if (_code.text.length != 6) throw Exception('请输入 6 位验证码');
    }
    final password = _password.text;
    if (_mode != _EmailMode.code && password.isEmpty) throw Exception('请输入密码');
    if (!_mode.signingIn) {
      if (password.runes.length < 8) throw Exception('请输入至少 8 个字符的密码');
      if (password != _confirmation.text) throw Exception('两次输入的密码不一致');
    }
    final endpoint = switch (_mode) {
      _EmailMode.code => 'email-code/login',
      _EmailMode.password => 'email-password/login',
      _EmailMode.register => 'email-password/register',
      _EmailMode.reset => 'email-password/reset',
    };
    final result = await widget.client.call('POST', '/api/auth/$endpoint', {
      'email': address,
      if (_mode.usesCode) 'code': _code.text,
      if (_mode != _EmailMode.code) 'password': password,
    });
    await _finishSignIn(result);
  });

  Future<void> _social(SocialSignIn provider) => _run(
    provider == SocialSignIn.apple ? _Action.apple : _Action.google,
    () async {
      final token = await provider.idToken();
      if (token == null || !mounted) return;
      final result = await widget.client.call(
        'POST',
        '/api/auth/firebase/login',
        {'id_token': token, 'link': widget.link},
      );
      if (!mounted) return;
      if (widget.link) {
        _feedback('已绑定 ${provider.label} 登录。');
      } else {
        await _finishSignIn(result);
      }
    },
  );

  List<Widget> _socialButtons() => [
    for (final provider in SocialSignIn.values) ...[
      if (provider == SocialSignIn.google) const SizedBox(height: 10),
      _SocialAuthButton(
        provider: provider,
        label: widget.link ? '绑定 ${provider.label}' : '使用 ${provider.label} 登录',
        loading:
            _action ==
            (provider == SocialSignIn.apple ? _Action.apple : _Action.google),
        onPressed: SocialSignIn.available && !_busy && (widget.link || _enabled)
            ? () => _social(provider)
            : null,
      ),
    ],
  ];

  void _clearMessage(String _) {
    if (_message != null) setState(() => _message = null);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.link) {
      return ChatSheetDialog(
        title: const Text('绑定登录方式'),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [..._socialButtons(), if (_message != null) _messageBox()],
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      );
    }

    final media = MediaQuery.of(context);
    return AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: Material(
        color: _sheetColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
        clipBehavior: Clip.antiAlias,
        child: SafeArea(
          top: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: media.size.height * .88),
            child: SingleChildScrollView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: const EdgeInsets.fromLTRB(22, 12, 22, 24),
              child: AutofillGroup(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Container(
                        width: 38,
                        height: 5,
                        margin: const EdgeInsets.only(bottom: 20),
                        decoration: BoxDecoration(
                          color: const Color(0xffded9e3),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                    if (_mode.signingIn) ...[
                      ..._socialButtons(),
                      const SizedBox(height: 18),
                      const _EmailDivider(),
                      const SizedBox(height: 16),
                      _modePicker(),
                      const SizedBox(height: 14),
                    ] else ...[
                      Text(
                        _mode.label,
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w900,
                          color: _foreground,
                        ),
                      ),
                      const SizedBox(height: 14),
                    ],
                    _field(
                      _email,
                      '邮箱',
                      Icons.alternate_email_rounded,
                      keyboard: TextInputType.emailAddress,
                      autofill: const [AutofillHints.email],
                      onChanged: (text) {
                        _code.clear();
                        _clearMessage(text);
                      },
                    ),
                    if (_mode.usesCode) ...[
                      const SizedBox(height: 12),
                      _field(
                        _code,
                        '验证码',
                        Icons.pin_outlined,
                        keyboard: TextInputType.number,
                        autofill: const [AutofillHints.oneTimeCode],
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                          LengthLimitingTextInputFormatter(6),
                        ],
                        suffix: TextButton(
                          onPressed: _enabled && _seconds == 0 ? _send : null,
                          style: TextButton.styleFrom(
                            foregroundColor: _accent,
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                          ),
                          child: _action == _Action.sendCode
                              ? const _Loading(color: _accent, size: 14)
                              : Text(
                                  _seconds > 0 ? '${_seconds}s 后重发' : '发送验证码',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                        ),
                      ),
                    ],
                    if (_mode != _EmailMode.code) ...[
                      const SizedBox(height: 12),
                      _field(
                        _password,
                        _mode == _EmailMode.reset ? '新密码' : '密码',
                        Icons.lock_outline_rounded,
                        obscure: _hidePassword,
                        autofill: [
                          _mode.signingIn
                              ? AutofillHints.password
                              : AutofillHints.newPassword,
                        ],
                        inputFormatters: [
                          LengthLimitingTextInputFormatter(128),
                        ],
                        suffix: IconButton(
                          tooltip: _hidePassword ? '显示密码' : '隐藏密码',
                          onPressed: _enabled
                              ? () => setState(
                                  () => _hidePassword = !_hidePassword,
                                )
                              : null,
                          icon: Icon(
                            _hidePassword
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                          ),
                        ),
                      ),
                      if (!_mode.signingIn) ...[
                        const SizedBox(height: 12),
                        _field(
                          _confirmation,
                          '确认密码',
                          Icons.verified_user_outlined,
                          obscure: _hidePassword,
                          inputFormatters: [
                            LengthLimitingTextInputFormatter(128),
                          ],
                        ),
                      ],
                    ],
                    if (_message != null) _messageBox(),
                    const SizedBox(height: 18),
                    FilledButton(
                      key: const ValueKey('submit-email-auth'),
                      onPressed: _enabled ? _submit : null,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 54),
                        backgroundColor: _accent,
                        disabledBackgroundColor: _accent.withValues(alpha: .5),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(18),
                        ),
                      ),
                      child: _action == _Action.email
                          ? const _Loading(color: Colors.white)
                          : Text(
                              _mode.label,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                    ),
                    const SizedBox(height: 10),
                    if (_mode.signingIn) ...[
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => _switchMode(_EmailMode.register),
                        style: TextButton.styleFrom(foregroundColor: _accent),
                        child: const Text(
                          '没有账号？去注册',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => _switchMode(_EmailMode.reset),
                        style: TextButton.styleFrom(foregroundColor: _muted),
                        child: const Text(
                          '忘记密码？',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                    ] else
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => _switchMode(_EmailMode.code),
                        style: TextButton.styleFrom(foregroundColor: _muted),
                        child: const Text('返回登录'),
                      ),
                    Wrap(
                      alignment: WrapAlignment.center,
                      children: [
                        TextButton(
                          onPressed: () =>
                              AppLegalUrls.open(context, AppLegalUrls.privacy),
                          child: const Text('隐私政策'),
                        ),
                        TextButton(
                          onPressed: () =>
                              AppLegalUrls.open(context, AppLegalUrls.terms),
                          child: const Text('使用条款'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _modePicker() => DecoratedBox(
    decoration: BoxDecoration(
      color: const Color(0xffeeebf2),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Padding(
      padding: const EdgeInsets.all(4),
      child: Row(
        children: [
          for (final mode in [_EmailMode.code, _EmailMode.password])
            Expanded(
              child: Semantics(
                selected: _mode == mode,
                child: TextButton(
                  key: ValueKey('email-mode-${mode.name}'),
                  onPressed: _busy ? null : () => _switchMode(mode),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 38),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 8,
                    ),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(11),
                    ),
                    backgroundColor: _mode == mode
                        ? _accent
                        : Colors.transparent,
                    foregroundColor: _mode == mode ? Colors.white : _muted,
                  ),
                  child: Text(
                    mode.label,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );

  Widget _field(
    TextEditingController controller,
    String hint,
    IconData icon, {
    TextInputType? keyboard,
    List<String>? autofill,
    List<TextInputFormatter>? inputFormatters,
    Widget? suffix,
    ValueChanged<String>? onChanged,
    bool obscure = false,
  }) {
    OutlineInputBorder outline(Color color, [double width = 1]) =>
        OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: color, width: width),
        );
    return TextField(
      controller: controller,
      enabled: _enabled,
      keyboardType: keyboard,
      autofillHints: autofill,
      inputFormatters: inputFormatters,
      obscureText: obscure,
      autocorrect: false,
      enableSuggestions: !obscure,
      onChanged: onChanged ?? _clearMessage,
      style: const TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        color: _foreground,
      ),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w500,
          color: _muted,
        ),
        prefixIcon: Icon(icon, size: 20, color: _muted),
        suffixIcon: suffix == null
            ? null
            : Padding(padding: const EdgeInsets.only(right: 6), child: suffix),
        suffixIconConstraints: const BoxConstraints(
          minWidth: 44,
          minHeight: 44,
        ),
        filled: true,
        fillColor: Colors.white.withValues(alpha: .86),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 15,
        ),
        border: outline(const Color(0x0a000000)),
        enabledBorder: outline(const Color(0x0a000000)),
        disabledBorder: outline(const Color(0x08000000)),
        focusedBorder: outline(_accent, 1.4),
      ),
    );
  }

  Widget _messageBox() {
    final color = _messageIsError
        ? const Color(0xff9a3732)
        : const Color(0xff316447);
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Semantics(
        liveRegion: true,
        child: Text(_message!, style: TextStyle(color: color, fontSize: 13)),
      ),
    );
  }
}

class _EmailDivider extends StatelessWidget {
  const _EmailDivider();

  @override
  Widget build(BuildContext context) => const Row(
    children: [
      Expanded(child: Divider(color: Color(0x1f2a2528), height: 1)),
      Padding(
        padding: EdgeInsets.symmetric(horizontal: 12),
        child: Text(
          '邮箱登录',
          style: TextStyle(
            color: _muted,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      Expanded(child: Divider(color: Color(0x1f2a2528), height: 1)),
    ],
  );
}

class _SocialAuthButton extends StatelessWidget {
  const _SocialAuthButton({
    required this.provider,
    required this.label,
    required this.loading,
    required this.onPressed,
  });

  final SocialSignIn provider;
  final String label;
  final bool loading;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final apple = provider == SocialSignIn.apple;
    final color = apple ? Colors.white : _foreground;
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        minimumSize: const Size(double.infinity, 54),
        backgroundColor: apple ? const Color(0xff121214) : Colors.white,
        foregroundColor: color,
        side: const BorderSide(color: Color(0x14000000)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (loading)
            _Loading(color: apple ? Colors.white : _accent)
          else if (apple)
            const Icon(Icons.apple_rounded, size: 24)
          else
            Image.asset(
              'assets/images/google_g_logo.png',
              width: 20,
              height: 20,
              fit: BoxFit.contain,
              excludeFromSemantics: true,
              filterQuality: FilterQuality.high,
            ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              label,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading({required this.color, this.size = 20});
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CircularProgressIndicator(strokeWidth: 2, color: color),
  );
}
