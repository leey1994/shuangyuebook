import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../dom.dart';
import '../models.dart';
import '../sources/source.dart';
import '../widgets.dart';
import 'book_detail_screen.dart';
import 'search_screen.dart';

/// 书单详情：头部卡 + 正文卡（书名可点跳搜索）+ 关联书籍卡。
class BooklistScreen extends StatefulWidget {
  final BooklistEntry entry;
  final NovelSource source;
  const BooklistScreen({super.key, required this.entry, required this.source});

  @override
  State<BooklistScreen> createState() => _BooklistScreenState();
}

class _BooklistScreenState extends State<BooklistScreen> {
  Booklist? _data;
  Object? _error;

  /// 书名提及：`《书名》` 或 `书名_作者`（52书库书单惯用写法）。
  static final _mention = RegExp(
      r'《([^》]{1,30})》|([^\s，。；、（）()]{2,30}_[^\s，。；、（）()【】]{1,20})');

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
      _data = null;
    });
    try {
      final d = await widget.source.fetchBooklist(widget.entry);
      if (mounted) setState(() => _data = d);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  void _searchBook(String q) {
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => SearchScreen(initialQuery: q)));
  }

  /// 渲染一段正文，命中书名的片段染色可点（点击跳到全源书籍搜索）。
  Widget _paragraph(String p) {
    final theme = Theme.of(context);
    final spans = <InlineSpan>[];
    var last = 0;
    for (final m in _mention.allMatches(p)) {
      if (m.start > last) spans.add(TextSpan(text: p.substring(last, m.start)));
      final query = m.group(1) != null
          ? m.group(1)!.trim()
          : splitTitleAuthor(m.group(2)!).title;
      spans.add(TextSpan(
        text: m.group(0),
        style: TextStyle(color: theme.colorScheme.primary),
        recognizer: TapGestureRecognizer()
          ..onTap = () => _searchBook(query),
      ));
      last = m.end;
    }
    if (last < p.length) spans.add(TextSpan(text: p.substring(last)));
    return Text.rich(
      TextSpan(
        style: theme.textTheme.bodyLarge?.copyWith(height: 1.9),
        children: spans,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final data = _data;
    return Scaffold(
      appBar: AppBar(title: Text(widget.entry.title, maxLines: 1)),
      body: data == null
          ? (_error == null
              ? const Center(child: CircularProgressIndicator())
              : Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('加载失败：$_error'),
                      const SizedBox(height: 8),
                      OutlinedButton(onPressed: _load, child: const Text('重试')),
                    ],
                  ),
                ))
          : ListView(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 32),
              children: [
                // 头部卡：来源/日期标签 + 书单标题
                Card(
                  margin: EdgeInsets.zero,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          children: [
                            TagPill(widget.source.name),
                            if (widget.entry.date != null &&
                                widget.entry.date!.isNotEmpty)
                              TagPill(widget.entry.date!, dim: true),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Text(data.title, style: theme.textTheme.titleLarge),
                        const SizedBox(height: 6),
                        Text(
                          '正文中的书名可点击，直接跳转全源搜索',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                // 正文卡
                Card(
                  margin: EdgeInsets.zero,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final p in data.paragraphs)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: _paragraph(p),
                          ),
                      ],
                    ),
                  ),
                ),
                if (data.books.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Text('书单中的书', style: theme.textTheme.titleMedium),
                      const SizedBox(width: 8),
                      Text('共 ${data.books.length} 本',
                          style: theme.textTheme.bodySmall),
                    ],
                  ),
                  const SizedBox(height: 8),
                  // 书籍卡：统一卡片内分隔，标题加大加粗
                  Card(
                    margin: EdgeInsets.zero,
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      children: [
                        for (var i = 0; i < data.books.length; i++) ...[
                          if (i > 0) const Divider(indent: 16, endIndent: 16),
                          BookTile(
                            book: data.books[i],
                            showSource: true,
                            bigTitle: true,
                            onTap: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                    builder: (_) => BookDetailScreen(
                                        book: data.books[i]))),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ],
            ),
    );
  }
}
