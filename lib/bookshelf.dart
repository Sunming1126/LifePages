import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'book_cover.dart';
import 'chapter_editor.dart';
import 'directory_page.dart';
import 'chat_sheet.dart';
import 'main.dart' show Api, BookPage, ChapterPage, errorText;

typedef BookRecord = Map<String, dynamic>;

bool isCompanionBook(BookRecord book) => book['book_mode'] == null
    ? book['interview_version'] != null
    : book['book_mode'] == 'companion';

enum _BookAction { rename, preview, directory, delete }

const _bookAccent = Color(0xff836332);

Future<BookRecord?> newBookSheet(
  BuildContext context,
  Api client, {
  bool interview = false,
  int interviewVersion = 1,
  bool allowModes = false,
}) async {
  var companion = interview;
  if (allowModes) {
    final chosen = await showChatSheet<String>(
      context: context,
      builder: (sheet) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const ListTile(title: Text('选择创作方式')),
          ListTile(
            leading: const Icon(Icons.list_alt),
            title: const Text('目录模式'),
            subtitle: const Text('按目录聊故事，自由管理章节和预设问题。'),
            onTap: () => Navigator.pop(sheet, 'directory'),
          ),
          ListTile(
            leading: const Icon(Icons.chat_bubble_outline),
            title: const Text('陪伴模式'),
            subtitle: const Text('自然聊天，AI 在后台整理成章。'),
            onTap: () => Navigator.pop(sheet, 'companion'),
          ),
        ],
      ),
    );
    if (chosen == null || !context.mounted) return null;
    companion = chosen == 'companion';
  }
  final form = GlobalKey<FormState>();
  final data = <String, dynamic>{
    if (allowModes) 'book_mode': companion ? 'companion' : 'directory',
    if (companion) ...{
      'interview': true,
      if (allowModes || interviewVersion == 2) 'interview_version': 2,
    } else
      'template_id': 'life',
  };
  List? templates;
  var templateName = '完整人生（26 章）';
  return showChatSheet<BookRecord>(
    context: context,
    builder: (sheet) => StatefulBuilder(
      builder: (_, update) => ChatSheetDialog(
        title: const Text('新建书籍'),
        content: Form(
          key: form,
          child: Column(
            children: [
              for (final field in const {
                'title': '书名',
                'name': '称呼',
                'author': '作者',
              }.entries)
                TextFormField(
                  maxLength: 100,
                  decoration: InputDecoration(labelText: field.value),
                  onSaved: (value) => data[field.key] = value!.trim(),
                  validator: (value) => (value?.trim().isEmpty ?? true)
                      ? '请填写${field.value}'
                      : null,
                ),
              if (!companion)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.view_list_outlined),
                  title: const Text('章节模板'),
                  subtitle: Text(templateName),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () async {
                    try {
                      templates ??=
                          await client.call('GET', '/api/books/templates')
                              as List;
                      if (!sheet.mounted) return;
                      final chosen = await showChatSheet<Map>(
                        context: sheet,
                        builder: (menu) => ListView(
                          shrinkWrap: true,
                          children: [
                            const ListTile(title: Text('选择章节模板')),
                            for (final template in templates!)
                              ExpansionTile(
                                title: Text(
                                  '${template['name']}（${(template['chapters'] as List).length} 章）',
                                ),
                                leading: template['id'] == data['template_id']
                                    ? const Icon(Icons.check_rounded)
                                    : const Icon(Icons.auto_stories_outlined),
                                children: [
                                  for (final (index, title)
                                      in (template['chapters'] as List).indexed)
                                    ListTile(
                                      dense: true,
                                      title: Text('第 ${index + 1} 章 · $title'),
                                    ),
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.pop(menu, template),
                                    child: const Text('使用这套模板'),
                                  ),
                                ],
                              ),
                          ],
                        ),
                      );
                      if (!sheet.mounted || chosen == null) return;
                      update(() {
                        data['template_id'] = chosen['id'];
                        templateName =
                            '${chosen['name']}（${(chosen['chapters'] as List).length} 章）';
                      });
                    } catch (error) {
                      if (sheet.mounted) {
                        ScaffoldMessenger.of(sheet).showSnackBar(
                          SnackBar(content: Text(errorText(error))),
                        );
                      }
                    }
                  },
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(sheet),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (!(form.currentState?.validate() ?? false)) return;
              form.currentState!.save();
              Navigator.pop(sheet, data);
            },
            child: const Text('创建书籍'),
          ),
        ],
      ),
    ),
  );
}

Future<void> showRecentlyDeleted(
  BuildContext context, {
  required List<BookRecord> books,
  required ValueChanged<String> onRestore,
}) async {
  final id = await showChatSheet<String>(
    context: context,
    expanded: true,
    builder: (sheet) => ListView(
      children: [
        const ListTile(title: Text('最近删除'), subtitle: Text('书籍保留 30 天')),
        if (books.isEmpty) const ListTile(title: Text('还没有删除的书籍')),
        for (final book in books)
          ListTile(
            title: Text(book['title'] as String),
            trailing: TextButton(
              onPressed: () => Navigator.pop(sheet, book['id'] as String),
              child: const Text('恢复'),
            ),
          ),
      ],
    ),
  );
  if (context.mounted && id != null) onRestore(id);
}

class Bookshelf extends StatefulWidget {
  const Bookshelf({
    super.key,
    required this.books,
    required this.activeId,
    required this.client,
    required this.busy,
    required this.onCreate,
    required this.onRecentlyDeleted,
    required this.onRename,
    required this.onChaptersChanged,
    required this.onDelete,
    this.documentsDirectory,
    this.onContinue,
  });

  final List<BookRecord> books;
  final String? activeId;
  final Api client;
  final bool busy;
  final VoidCallback onCreate;
  final VoidCallback onRecentlyDeleted;
  final ValueChanged<String> onChaptersChanged;
  final Future<void> Function(String, BookRecord) onRename;
  final ValueChanged<String> onDelete;
  final ValueChanged<String>? onContinue;
  final Future<Directory> Function()? documentsDirectory;

  @override
  State<Bookshelf> createState() => _BookshelfState();
}

class _BookshelfState extends State<Bookshelf> {
  final _openings = <String, ChapterOpening>{};
  final _requests = <String, Future<ChapterOpening>>{};
  late String _token;

  @override
  void initState() {
    super.initState();
    _token = widget.client.token;
    for (final id in _priorityBooks(widget)) {
      _warm(id);
    }
  }

  @override
  void didUpdateWidget(covariant Bookshelf oldWidget) {
    super.didUpdateWidget(oldWidget);
    final accountChanged =
        oldWidget.client != widget.client || _token != widget.client.token;
    if (accountChanged) {
      _token = widget.client.token;
      _openings.clear();
      _requests.clear();
    }
    _openings.removeWhere((id, _) => !_hasBook(id));
    final previous = accountChanged ? <String>{} : _priorityBooks(oldWidget);
    for (final id in _priorityBooks(widget).difference(previous)) {
      _warm(id);
    }
  }

  bool _hasBook(String id) => widget.books.any((book) => book['id'] == id);

  Set<String> _priorityBooks(Bookshelf shelf) {
    final ids = shelf.books.map((book) => book['id'] as String).toSet();
    final active = shelf.activeId;
    return {
      if (active != null && ids.remove(active)) active,
      ...ids,
    }.take(3).toSet();
  }

  void _warm(String id) {
    if (_openings.containsKey(id) || _requests.containsKey(id)) return;
    unawaited(
      _requestOpening(
        id,
      ).then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
  }

  void _rememberOpening(String id, ChapterOpening opening) {
    _openings.remove(id);
    _openings[id] = opening;
    if (_openings.length > 6) _openings.remove(_openings.keys.first);
  }

  Future<ChapterOpening> _requestOpening(String id) {
    if (_requests[id] case final pending?) return pending;
    final current = _openings[id];
    late final Future<ChapterOpening> request;
    request =
        ChapterOpening.load(
              widget.client,
              id,
              documentsDirectory: widget.documentsDirectory,
              interview: isCompanionBook(
                widget.books.firstWhere((book) => book['id'] == id),
              ),
            )
            .then((opening) {
              if (mounted &&
                  identical(_requests[id], request) &&
                  identical(_openings[id], current) &&
                  _hasBook(id)) {
                _rememberOpening(id, opening);
              }
              return opening;
            })
            .whenComplete(() {
              if (identical(_requests[id], request)) _requests.remove(id);
            });
    return _requests[id] = request;
  }

  Future<void> _openEditor(BuildContext context, BookRecord book) async {
    final id = book['id'] as String;
    final interview = isCompanionBook(book);
    await Navigator.of(context).push(
      PageRouteBuilder<void>(
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
        pageBuilder: (_, _, _) => ChapterEditor(
          bookId: id,
          name: book['name'] as String,
          title: book['title'] as String,
          author: book['author'] as String,
          client: widget.client,
          interview: interview,
          documentsDirectory: widget.documentsDirectory,
          initialOpening: _openings[id],
          loadOpening: () => _requestOpening(id),
          onOpeningChanged: (opening) {
            if (mounted && _hasBook(id)) _rememberOpening(id, opening);
          },
          onChaptersChanged: () => widget.onChaptersChanged(id),
          onDirectoryChanged: () {
            _openings.remove(id);
            _requests.remove(id);
          },
        ),
      ),
    );
    if (context.mounted) widget.onChaptersChanged(id);
  }

  void _openPreview(BuildContext context, BookRecord book) {
    final id = book['id'] as String;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BookPage(
          bookId: id,
          name: book['name'] as String,
          title: book['title'] as String,
          author: book['author'] as String,
          client: widget.client,
          interview: isCompanionBook(book),
          onChaptersChanged: () => widget.onChaptersChanged(id),
        ),
      ),
    );
  }

  Future<void> _openActions(BuildContext context, BookRecord book) async {
    final action = await showChatSheet<_BookAction>(
      context: context,
      builder: (sheet) => ListView(
        shrinkWrap: true,
        children: [
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: const Text('修改书名和作者'),
            onTap: () => Navigator.pop(sheet, _BookAction.rename),
          ),
          if (book['book_mode'] == 'directory')
            ListTile(
              leading: const Icon(Icons.format_list_numbered),
              title: const Text('管理目录'),
              onTap: () => Navigator.pop(sheet, _BookAction.directory),
            ),
          ListTile(
            leading: const Icon(Icons.auto_stories_outlined),
            title: const Text('预览全书'),
            onTap: () => Navigator.pop(sheet, _BookAction.preview),
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline_rounded),
            title: const Text('删除书籍'),
            onTap: () => Navigator.pop(sheet, _BookAction.delete),
          ),
        ],
      ),
    );
    if (context.mounted && action != null) _action(context, book, action);
  }

  void _action(BuildContext context, BookRecord book, _BookAction action) {
    switch (action) {
      case _BookAction.rename:
        showChatSheet<void>(
          context: context,
          builder: (_) => _RenameBookSheet(
            book: book,
            onSave: (data) => widget.onRename(book['id'] as String, data),
          ),
        );
      case _BookAction.directory:
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => DirectoryPage(
              bookId: book['id'] as String,
              title: book['title'] as String,
              client: widget.client,
              onChanged: () {
                _openings.remove(book['id']);
                _requests.remove(book['id']);
                widget.onChaptersChanged(book['id'] as String);
              },
            ),
          ),
        );
      case _BookAction.preview:
        _openPreview(context, book);
      case _BookAction.delete:
        _confirmDelete(context, book);
    }
  }

  Future<void> _confirmDelete(BuildContext context, BookRecord book) async {
    final confirmed = await showChatSheet<bool>(
      context: context,
      builder: (sheet) => ChatSheetDialog(
        title: Text('删除《${book['title']}》？'),
        content: const Text('这本书会移入「最近删除」，分享暂停。30 天内可以恢复整本书。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(sheet),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(sheet, true),
            child: const Text('移入最近删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) widget.onDelete(book['id'] as String);
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    bottom: false,
    child: ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 120),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '书架',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
            ),
            TextButton.icon(
              onPressed: widget.busy ? null : widget.onRecentlyDeleted,
              icon: const Icon(Icons.delete_outline_rounded),
              label: const Text('最近删除'),
            ),
          ],
        ),
        if (widget.busy) const LinearProgressIndicator(),
        if (widget.books.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 30),
            child: Text('新建一本书，就能开始讲述。'),
          ),
        for (final book in widget.books) _bookCard(context, book),
        const SizedBox(height: 18),
        OutlinedButton.icon(
          onPressed: widget.busy ? null : widget.onCreate,
          icon: const Icon(Icons.add_circle_outline_rounded),
          label: const Text('新建一本书'),
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xff453827),
            minimumSize: const Size.fromHeight(52),
          ),
        ),
      ],
    ),
  );

  Widget _bookCard(BuildContext context, BookRecord book) {
    final title = book['title'] as String;
    final author = '${book['author']} 著';
    final total = book['topic_count'] as int? ?? 26;
    final completed = book['completed_topic_count'] as int?;
    final characters = book['character_count'] as int?;
    final current = book['id'] == widget.activeId;
    final interview = isCompanionBook(book);
    return Card(
      color: const Color(0xfffffdfa),
      elevation: 0,
      margin: const EdgeInsets.only(top: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Color(0xffe9e3d8)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTapDown: (_) => _warm(book['id'] as String),
        onTap: () => _openEditor(context, book),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: LayoutBuilder(
            builder: (context, size) => Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: (size.maxWidth * .29).clamp(58.0, 112.0),
                  child: ExcludeSemantics(
                    child: BookCover(
                      title: title,
                      author: author,
                      thumbnail: true,
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text(
                                title,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleLarge
                                    ?.copyWith(
                                      fontFamily: 'Songti SC',
                                      fontWeight: FontWeight.w700,
                                    ),
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: '书籍选项',
                            icon: const Icon(Icons.more_horiz_rounded),
                            onPressed: widget.busy
                                ? null
                                : () => _openActions(context, book),
                          ),
                        ],
                      ),
                      Text(
                        author,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (book['book_mode'] != null)
                        Text(
                          interview ? '陪伴模式' : '目录模式',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      const SizedBox(height: 12),
                      if (!interview)
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: LinearProgressIndicator(
                            value: total > 0
                                ? ((completed ?? 0) / total).clamp(0.0, 1.0)
                                : 0,
                            minHeight: 5,
                            color: _bookAccent,
                            backgroundColor: const Color(0xffeee7d9),
                          ),
                        ),
                      const SizedBox(height: 8),
                      Text(
                        interview || completed == null || characters == null
                            ? '${book['chapter_count']} 章已成稿'
                            : '$completed/$total 章 · $characters 字',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      if (widget.onContinue != null)
                        TextButton(
                          onPressed: widget.busy
                              ? null
                              : () => widget.onContinue!(book['id'] as String),
                          child: Text(interview ? '继续访谈' : '继续聊天'),
                        ),
                      if (current) ...[
                        const SizedBox(height: 8),
                        const Text(
                          '当前创作',
                          style: TextStyle(
                            color: _bookAccent,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RenameBookSheet extends StatefulWidget {
  const _RenameBookSheet({required this.book, required this.onSave});
  final BookRecord book;
  final Future<void> Function(BookRecord) onSave;

  @override
  State<_RenameBookSheet> createState() => _RenameBookSheetState();
}

class _RenameBookSheetState extends State<_RenameBookSheet> {
  final _form = GlobalKey<FormState>();
  late final _title = TextEditingController(
    text: widget.book['title'] as String,
  );
  late final _author = TextEditingController(
    text: widget.book['author'] as String,
  );
  bool _saving = false;
  String? _error;

  Future<void> _save() async {
    if (_saving || !_form.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSave({
        'title': _title.text.trim(),
        'author': _author.text.trim(),
      });
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) setState(() => _error = errorText(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _author.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: ChatSheetDialog(
      title: const Text('修改书名和作者'),
      content: Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (label, controller) in [('书名', _title), ('作者', _author)])
              TextFormField(
                controller: controller,
                enabled: !_saving,
                maxLength: 100,
                decoration: InputDecoration(labelText: label),
                validator: (value) =>
                    (value?.trim().isEmpty ?? true) ? '请填写$label' : null,
              ),
            if (_error case final error?)
              Text(
                error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? '正在保存…' : '保存'),
        ),
      ],
    ),
  );
}

Future<void> openBookChapter(
  BuildContext context,
  Api client,
  String bookId,
  String chapterId, {
  VoidCallback? onSaved,
}) async {
  final chapters =
      await client.call('GET', '/api/books/$bookId/chapters') as List;
  final chapter = chapters.firstWhere((row) => row['id'] == chapterId);
  if (!context.mounted) return;
  await Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => ChapterPage(
        chapter: Map<String, dynamic>.from(chapter as Map),
        client: client,
        onSaved: onSaved,
      ),
    ),
  );
}
