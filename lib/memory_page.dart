import 'chat_sheet.dart';
import 'package:flutter/material.dart';

import 'chatchat_style.dart';
import 'main.dart' show Api, AudioButton, showError;

class MemoryPage extends StatefulWidget {
  const MemoryPage({
    super.key,
    required this.client,
    required this.personId,
    required this.name,
  });

  final Api client;
  final String personId;
  final String name;

  @override
  State<MemoryPage> createState() => _MemoryPageState();
}

class _MemoryPageState extends State<MemoryPage> {
  final items = <Map<String, dynamic>>[];
  bool? enabled;
  bool loading = false, saving = false;
  int? next;
  int total = 0, processed = 0;
  String? error;

  String get personPath => '/api/people/${widget.personId}';
  String get memoriesPath => '$personPath/memories';

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load({bool more = false}) async {
    if (loading) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final response = await widget.client.call(
        'GET',
        more ? '$memoriesPath?before=$next' : memoriesPath,
      );
      if (!mounted) return;
      setState(() {
        enabled = response['enabled'] as bool;
        total = response['total'] as int;
        processed = response['processed'] as int;
        next = response['next'] as int?;
        if (!more) items.clear();
        for (final value in response['items'] as List) {
          final item = Map<String, dynamic>.from(value);
          if (!items.any((old) => old['id'] == item['id'])) items.add(item);
        }
      });
    } catch (_) {
      if (mounted) setState(() => error = '暂时无法加载记忆，请稍后重试。');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> change(
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    if (saving || loading) return;
    setState(() => saving = true);
    try {
      await widget.client.call(method, path, body);
      if (mounted) await load();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> open(Map<String, dynamic> item) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => _MemoryDetail(
          item: item,
          name: widget.name,
          client: widget.client,
          path: "$memoriesPath/${item['id']}",
        ),
      ),
    );
    if (mounted && changed == true) await load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('记忆簿'),
      actions: [
        IconButton(
          tooltip: '刷新记忆',
          onPressed: loading || saving ? null : () => load(),
          icon: const Icon(Icons.refresh_rounded),
        ),
      ],
    ),
    body: RefreshIndicator(
      onRefresh: () => load(),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
        children: [
          Text('账号长期记忆', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          const Text('从聊天中整理值得记住的人、地点和经历，方便以后接着聊。'),
          const SizedBox(height: 16),
          if (enabled != null)
            Card(
              child: SwitchListTile(
                title: const Text('长期记忆'),
                subtitle: Text(enabled! ? '会整理旧聊天和新消息' : '已暂停整理和引用，保留已有记忆'),
                value: enabled!,
                onChanged: loading || saving
                    ? null
                    : (value) => change(
                        'PATCH',
                        '$personPath/memory-settings',
                        {'enabled': value},
                      ),
              ),
            ),
          if (total > 0)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text('已检查 $processed / $total 条聊天消息'),
            ),
          if (loading) const LinearProgressIndicator(),
          if (error != null) ...[
            const SizedBox(height: 8),
            Text(error!),
            TextButton(
              onPressed: loading ? null : () => load(),
              child: const Text('重试'),
            ),
          ],
          if (enabled != null && items.isEmpty && !loading)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Text(
                enabled! ? '记忆会在后台逐步整理。聊天时也可以说「记住这个」。' : '开启后即可继续整理聊天。',
              ),
            ),
          for (final item in items)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                title: Text(item['title'] as String),
                subtitle: Text(
                  item['status'] == 'pending'
                      ? '待确认 · ${item['content']}'
                      : item['content'] as String,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                leading: Icon(
                  item['status'] == 'pending'
                      ? Icons.fact_check_outlined
                      : Icons.bookmark_outline_rounded,
                  color: chatAccent,
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: loading || saving ? null : () => open(item),
              ),
            ),
          if (next != null)
            TextButton(
              onPressed: loading || saving ? null : () => load(more: true),
              child: const Text('查看更多'),
            ),
        ],
      ),
    ),
  );
}

class _MemoryDetail extends StatefulWidget {
  const _MemoryDetail({
    required this.item,
    required this.name,
    required this.client,
    required this.path,
  });

  final Map<String, dynamic> item;
  final String path;
  final String name;
  final Api client;

  @override
  State<_MemoryDetail> createState() => _MemoryDetailState();
}

class _MemoryDetailState extends State<_MemoryDetail> {
  static const predicates = [
    '父亲',
    '母亲',
    '儿子',
    '女儿',
    '配偶',
    '兄弟',
    '姐妹',
    '参加',
    '居住于',
    '发生于',
  ];
  final form = GlobalKey<FormState>();
  late final item = widget.item;
  late final title = TextEditingController(text: item['title'] as String);
  late final content = TextEditingController(text: item['content'] as String);
  late final relationship = item['relationship'] as Map?;
  late final subject = TextEditingController(
    text: display(relationship?['subject'] as String?),
  );
  late final target = TextEditingController(
    text: display(relationship?['object'] as String?),
  );
  late String? predicate = relationship?['predicate'] as String?;
  bool editing = false, saving = false, loadingSource = false;
  String? sourceText;

  String display(String? name) => name == '@self' ? '讲述者本人' : name ?? '';
  String stored(String text) => text.trim() == '讲述者本人' ? '@self' : text.trim();

  @override
  void dispose() {
    title.dispose();
    content.dispose();
    subject.dispose();
    target.dispose();
    super.dispose();
  }

  Future<void> mutate(String method, [Map<String, dynamic>? body]) async {
    if (saving) return;
    setState(() => saving = true);
    try {
      await widget.client.call(method, widget.path, body);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> save({required bool confirm}) async {
    if (editing && !(form.currentState?.validate() ?? false)) return;
    await mutate('PATCH', {
      'revision': item['revision'],
      if (confirm) 'confirm': true,
      if (editing) ...{
        'title': title.text.trim(),
        'content': content.text.trim(),
        if (relationship != null) ...{
          'subject': stored(subject.text),
          'predicate': predicate,
          'object': stored(target.text),
        },
      },
    });
  }

  Future<void> openSource() async {
    setState(() => loadingSource = true);
    try {
      final response = await widget.client.call('GET', '${widget.path}/source');
      if (mounted) setState(() => sourceText = response['text'] as String);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => loadingSource = false);
    }
  }

  Future<void> remove() async {
    final yes = await showChatSheet<bool>(
      context: context,
      builder: (c) => ChatSheetDialog(
        title: const Text('删除这条记忆？'),
        content: const Text('聊天原文和录音会继续保留。之后聊天时，助手会从长期记忆中移除这条内容。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (yes == true && mounted) await mutate('DELETE');
  }

  Future<void> chooseRelationship() async {
    final value = await showChatSheet<String>(
      context: context,
      builder: (sheet) => ListView(
        shrinkWrap: true,
        children: [
          const ListTile(title: Text('选择关系')),
          for (final option in predicates)
            ListTile(
              title: Text(option),
              trailing: option == predicate
                  ? const Icon(Icons.check_rounded)
                  : null,
              onTap: () => Navigator.pop(sheet, option),
            ),
        ],
      ),
    );
    if (mounted && value != null) setState(() => predicate = value);
  }

  TextFormField field(
    TextEditingController controller,
    String label,
    int length, {
    int lines = 1,
  }) => TextFormField(
    controller: controller,
    decoration: InputDecoration(labelText: label),
    maxLength: length,
    minLines: lines,
    maxLines: lines == 1 ? 1 : 8,
    validator: (value) =>
        value == null || value.trim().isEmpty ? '请填写$label' : null,
  );

  @override
  Widget build(BuildContext context) {
    final pending = item['status'] == 'pending';
    final audioId = item['audio_id'] as String?;
    return Scaffold(
      appBar: AppBar(title: Text(editing ? '更正记忆' : '记忆详情')),
      body: Form(
        key: form,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            if (editing) ...[
              field(title, '标题', 100),
              field(content, '记忆内容', 1200, lines: 3),
              if (relationship != null) ...[
                field(subject, '人物或事件', 80),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('关系'),
                  subtitle: Text(predicate ?? '请选择'),
                  trailing: const Icon(Icons.expand_more_rounded),
                  onTap: chooseRelationship,
                ),
                field(target, '关联对象', 80),
              ],
            ] else ...[
              Text(
                item['title'] as String,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              Text(item['content'] as String),
              if (relationship != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    "${display(relationship?['subject'] as String?)} · $predicate · "
                    "${display(relationship?['object'] as String?)}",
                  ),
                ),
            ],
            const SizedBox(height: 20),
            const Divider(),
            Text(
              "原始聊天 · ${item['narrator'] ?? widget.name}",
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            SelectableText(sourceText ?? item['quote'] as String),
            if (sourceText == null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: loadingSource ? null : openSource,
                  child: Text(loadingSource ? '正在加载原文' : '查看完整原文'),
                ),
              ),
            if (audioId != null)
              Align(
                alignment: Alignment.centerLeft,
                child: AudioButton(id: audioId, client: widget.client),
              ),
            const SizedBox(height: 20),
            if (saving) const LinearProgressIndicator(),
            if (pending)
              FilledButton(
                onPressed: saving ? null : () => save(confirm: true),
                child: Text(editing ? '保存并确认' : '确认这条记忆'),
              ),
            if (editing)
              OutlinedButton(
                onPressed: saving ? null : () => save(confirm: false),
                child: const Text('保存更正'),
              )
            else
              OutlinedButton(
                onPressed: () => setState(() => editing = true),
                child: const Text('更正'),
              ),
            if (!editing)
              TextButton(
                onPressed: saving ? null : remove,
                child: const Text('删除记忆'),
              ),
          ],
        ),
      ),
    );
  }
}
