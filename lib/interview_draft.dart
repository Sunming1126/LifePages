import 'package:flutter/material.dart';

import 'chat_sheet.dart';
import 'main.dart' show Api, errorText;

Future<bool> reviewInterviewDraft(
  BuildContext context, {
  required Api client,
  required String path,
  required Map draft,
}) async =>
    await showChatSheet<bool>(
      context: context,
      expanded: true,
      builder: (_) => _DraftReview(
        client: client,
        path: '$path/${draft['id']}',
        chapters: draft['chapters'] as List,
      ),
    ) ??
    false;

class _DraftReview extends StatefulWidget {
  const _DraftReview({
    required this.client,
    required this.path,
    required this.chapters,
  });

  final Api client;
  final String path;
  final List chapters;

  @override
  State<_DraftReview> createState() => _DraftReviewState();
}

class _DraftReviewState extends State<_DraftReview> {
  late final _titles = [
    for (final chapter in widget.chapters)
      TextEditingController(text: chapter['title'] as String),
  ];
  late final _bodies = [
    for (final chapter in widget.chapters)
      TextEditingController(text: chapter['body'] as String),
  ];
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final controller in [..._titles, ..._bodies]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _submit({required bool save}) async {
    final chapters = [
      for (var i = 0; i < _titles.length; i++)
        {'title': _titles[i].text.trim(), 'body': _bodies[i].text.trim()},
    ];
    if (save &&
        chapters.any((row) => row.values.any((value) => value.isEmpty))) {
      setState(() => _error = '章节标题和正文需要填写完整');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.client.call(
        save ? 'PUT' : 'DELETE',
        widget.path,
        save ? {'chapters': chapters} : null,
      );
      if (mounted) Navigator.pop(context, save);
    } catch (error) {
      if (mounted) setState(() => _error = errorText(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Expanded(
            child: Text('书稿草稿', style: Theme.of(context).textTheme.titleLarge),
          ),
          IconButton(
            tooltip: '稍后处理',
            onPressed: _busy ? null : () => Navigator.pop(context),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
      Expanded(
        child: ListView.separated(
          itemCount: widget.chapters.length,
          separatorBuilder: (_, _) => const SizedBox(height: 22),
          itemBuilder: (context, index) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.chapters[index]['append_to'] != null)
                const Text('补充到已有章节'),
              TextField(
                key: ValueKey('draft-title-$index'),
                controller: _titles[index],
                enabled: !_busy,
                maxLength: 100,
                decoration: const InputDecoration(labelText: '章节标题'),
              ),
              TextField(
                key: ValueKey('draft-body-$index'),
                controller: _bodies[index],
                enabled: !_busy,
                maxLines: null,
                decoration: const InputDecoration(labelText: '正文'),
              ),
            ],
          ),
        ),
      ),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      const SizedBox(height: 12),
      Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton(
            onPressed: _busy ? null : () => _submit(save: false),
            child: const Text('放弃草稿'),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: _busy ? null : () => _submit(save: true),
            child: Text(_busy ? '处理中…' : '保存到书架'),
          ),
        ],
      ),
    ],
  );
}
