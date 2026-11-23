import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'chat_sheet.dart';
import 'main.dart' show Api, errorText;

class DirectoryPage extends StatefulWidget {
  const DirectoryPage({
    super.key,
    required this.bookId,
    required this.title,
    required this.client,
    this.onChanged,
  });
  final String bookId, title;
  final Api client;
  final VoidCallback? onChanged;
  @override
  State<DirectoryPage> createState() => _DirectoryPageState();
}

class _DirectoryPageState extends State<DirectoryPage> {
  List<Map<String, dynamic>> _items = [], _archived = [];
  int _revision = 0;
  bool _busy = true;
  String? _error;
  String get _path => '/api/books/${widget.bookId}/directory';
  @override
  void initState() {
    super.initState();
    _load();
  }

  void _apply(dynamic value) {
    _revision = value['revision'] as int;
    _items = (value['topics'] as List)
        .map((r) => Map<String, dynamic>.from(r as Map))
        .toList();
    _archived = (value['archived'] as List)
        .map((r) => Map<String, dynamic>.from(r as Map))
        .toList();
  }

  Future<void> _load() async {
    try {
      final value = await widget.client.call('GET', _path);
      if (mounted) {
        setState(() {
          _apply(value);
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _mutate(
    String method,
    String suffix,
    Map<String, dynamic> values,
  ) async {
    if (_busy) return false;
    setState(() => _busy = true);
    try {
      final value = await widget.client.call(method, '$_path$suffix', {
        'revision': _revision,
        ...values,
      });
      if (!mounted) return false;
      setState(() {
        _apply(value);
        _error = null;
      });
      widget.onChanged?.call();
      return true;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(errorText(e))));
      }
      await _load();
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit([Map<String, dynamic>? row]) async {
    var title = row?['title'] as String? ?? '';
    var question = row?['question'] as String? ?? '';
    final form = GlobalKey<FormState>();
    final id = row?['id'] as String? ?? const Uuid().v4().replaceAll('-', '');
    var saving = false;
    await showChatSheet<void>(
      context: context,
      builder: (sheet) => StatefulBuilder(
        builder: (_, update) => ChatSheetDialog(
          title: Text(row == null ? '添加目录' : '修改目录'),
          content: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  initialValue: title,
                  onChanged: (value) => title = value,
                  maxLength: 100,
                  decoration: const InputDecoration(labelText: '目录名称'),
                  validator: (v) =>
                      v?.trim().isNotEmpty == true ? null : '请填写目录名称',
                ),
                TextFormField(
                  initialValue: question,
                  onChanged: (value) => question = value,
                  maxLength: 1000,
                  minLines: 2,
                  maxLines: 5,
                  decoration: const InputDecoration(labelText: '预设问题'),
                  validator: (v) =>
                      v?.trim().isNotEmpty == true ? null : '请填写预设问题',
                ),
                const Text('修改预设问题不会改写已经保存的聊天。'),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: saving ? null : () => Navigator.pop(sheet),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: saving
                  ? null
                  : () async {
                      if (!form.currentState!.validate()) return;
                      update(() => saving = true);
                      final ok = await _mutate(
                        row == null ? 'POST' : 'PATCH',
                        row == null ? '/items' : '/items/$id',
                        {
                          if (row == null) 'id': id,
                          'title': title.trim(),
                          'question': question.trim(),
                        },
                      );
                      if (sheet.mounted) {
                        if (ok) {
                          Navigator.pop(sheet);
                        } else {
                          update(() => saving = false);
                        }
                      }
                    },
              child: Text(saving ? '正在保存…' : '保存'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _remove(Map<String, dynamic> row) async {
    final confirmed = await showChatSheet<bool>(
      context: context,
      builder: (sheet) => ChatSheetDialog(
        title: const Text('移除这个目录？'),
        content: const Text('文字和录音会保留，可从本页的“已移除目录”恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(sheet),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(sheet, true),
            child: const Text('移除目录'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _mutate('POST', '/items/${row['id']}/archive', {});
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('管理目录'),
      actions: [
        IconButton(
          tooltip: '添加目录',
          onPressed: _busy ? null : _edit,
          icon: const Icon(Icons.add),
        ),
      ],
    ),
    body: Column(
      children: [
        ListTile(
          title: Text(widget.title),
          subtitle: const Text('长按拖动调整顺序，点击编辑名称和预设问题。'),
        ),
        if (_busy) const LinearProgressIndicator(),
        if (_error != null)
          ListTile(
            title: Text(_error!),
            trailing: TextButton(onPressed: _load, child: const Text('重试')),
          ),
        if (!_busy && _items.isEmpty && _error == null)
          TextButton.icon(
            onPressed: _edit,
            icon: const Icon(Icons.add),
            label: const Text('添加第一个目录'),
          ),
        Expanded(
          child: ReorderableListView.builder(
            itemCount: _items.length,
            onReorderItem: (old, next) async {
              if (_busy) return;
              final ids = _items.map((e) => e['id'] as String).toList();
              ids.insert(next, ids.removeAt(old));
              await _mutate('PUT', '/order', {'ids': ids});
            },
            itemBuilder: (_, index) {
              final row = _items[index];
              return ListTile(
                key: ValueKey(row['id']),
                leading: Text('${index + 1}'),
                title: Text(row['title'] as String),
                subtitle: Text(
                  row['question'] as String,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: _busy ? null : () => _edit(row),
                trailing: IconButton(
                  tooltip: '移除目录',
                  icon: const Icon(Icons.remove_circle_outline),
                  onPressed: _busy ? null : () => _remove(row),
                ),
              );
            },
          ),
        ),
        if (_archived.isNotEmpty)
          ExpansionTile(
            title: Text('已移除目录（${_archived.length}）'),
            children: [
              SizedBox(
                height: (_archived.length * 64.0).clamp(0, 240).toDouble(),
                child: ListView(
                  children: [
                    for (final row in _archived)
                      ListTile(
                        title: Text(row['title'] as String),
                        trailing: TextButton(
                          onPressed: _busy
                              ? null
                              : () => _mutate(
                                  'POST',
                                  '/items/${row['id']}/restore',
                                  {},
                                ),
                          child: const Text('恢复'),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
      ],
    ),
  );
}
