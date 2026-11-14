import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../chat_sheet.dart';
import '../platform_capabilities.dart';
import '../main.dart' show Api, errorText;

class AccountProfile {
  const AccountProfile({
    this.name = '',
    this.avatar,
    this.remaining,
    this.limit = 3,
  });

  factory AccountProfile.fromApi(Map<String, dynamic> data) {
    final encoded = data['avatar'] as String?;
    final quota = data['follow_ups'] as Map?;
    return AccountProfile(
      name: data['display_name'] as String? ?? '',
      avatar: encoded == null ? null : base64Decode(encoded),
      remaining: quota?['remaining'] as int?,
      limit: quota?['limit'] as int? ?? 3,
    );
  }

  final String name;
  final Uint8List? avatar;
  final int? remaining;
  final int limit;
}

class ProfileAvatar extends StatelessWidget {
  const ProfileAvatar({super.key, this.image, this.size = 56});
  final Uint8List? image;
  final double size;

  @override
  Widget build(BuildContext context) => ClipOval(
    child: SizedBox.square(
      dimension: size,
      child: ColoredBox(
        color: const Color(0xffecddca),
        child: image == null
            ? _placeholder()
            : Image.memory(
                image!,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => _placeholder(),
              ),
      ),
    ),
  );

  Widget _placeholder() => Icon(
    Icons.person_outline_rounded,
    size: size * .52,
    color: const Color(0xff745832),
  );
}

class ProfileEditor extends StatefulWidget {
  const ProfileEditor({super.key, required this.client, required this.profile});
  final Api client;
  final AccountProfile profile;

  @override
  State<ProfileEditor> createState() => _ProfileEditorState();
}

class _ProfileEditorState extends State<ProfileEditor> {
  static const _photos = MethodChannel('life_pages/photos');
  late final _name = TextEditingController(text: widget.profile.name);
  late Uint8List? _image = widget.profile.avatar;
  bool _changedAvatar = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _work(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is MissingPluginException
              ? '请重新编译安装新版后再选择头像'
              : errorText(error),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pick() => _work(() async {
    final photo = await _photos.invokeMethod<Uint8List>('pickAvatar');
    if (!mounted || photo == null) return;
    setState(() {
      _image = photo;
      _changedAvatar = true;
    });
  });

  Future<void> _save() => _work(() async {
    final displayName = _name.text.trim();
    final patch = <String, dynamic>{
      if (displayName != widget.profile.name) 'display_name': displayName,
      if (_changedAvatar)
        'avatar': _image == null ? null : base64Encode(_image!),
    };
    final updated = patch.isEmpty
        ? widget.profile
        : AccountProfile.fromApi(
            await widget.client.call('PATCH', '/api/profile', patch)
                as Map<String, dynamic>,
          );
    if (mounted) Navigator.pop(context, updated);
  });

  @override
  Widget build(BuildContext context) => ChatSheetDialog(
    title: const Text('编辑资料'),
    content: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(child: ProfileAvatar(image: _image, size: 72)),
        Wrap(
          alignment: WrapAlignment.center,
          children: [
            if (supportsNativePhotos)
              TextButton(
                onPressed: _busy ? null : _pick,
                child: const Text('选择头像'),
              ),
            if (_image != null)
              TextButton(
                onPressed: _busy
                    ? null
                    : () => setState(() {
                        _image = null;
                        _changedAvatar = true;
                      }),
                child: const Text('移除头像'),
              ),
          ],
        ),
        TextField(
          controller: _name,
          maxLength: 30,
          enabled: !_busy,
          decoration: const InputDecoration(labelText: '用户名'),
        ),
        if (_error != null) Text(_error!),
      ],
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _busy ? null : _save,
        child: Text(_busy ? '处理中…' : '保存'),
      ),
    ],
  );
}
