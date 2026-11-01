// 书源调试器（对齐「阅读 3.0」的源调试页）：
//
// 选一本书源 + 一个地址 / 关键词，实地跑一遍解析，把每一步的结构和耗时摊开看。
// 写错规则时比「黑盒反复试」快得多 —— 搜索抽到了几条、详情书名对不对、
// 正文是不是壳页，一跑就知道。
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../legado/models.dart';
import '../../legado/online_book_service.dart';
import '../../legado/online_repo.dart';
import '../../legado/source_store.dart';
import '../../ui/brand.dart';

/// 打开书源调试器（预填某个导入书源）。
void showSourceDebugger(BuildContext context, BookSource source) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => SourceDebuggerPage(source: source)),
  );
}

enum _DebugMode { search, detail, chapter }

class SourceDebuggerPage extends StatefulWidget {
  const SourceDebuggerPage({super.key, required this.source});
  final BookSource source;

  @override
  State<SourceDebuggerPage> createState() => _SourceDebuggerPageState();
}

class _SourceDebuggerPageState extends State<SourceDebuggerPage> {
  final _url = TextEditingController();
  _DebugMode _mode = _DebugMode.detail;
  bool _running = false;
  String _out = '';

  Future<void> _run() async {
    final input = _url.text.trim();
    if (input.isEmpty) {
      setState(() => _out = '请输入关键词 / 地址');
      return;
    }
    setState(() => _running = true);
    final sw = Stopwatch()..start();
    try {
      final s = widget.source;
      final store = SourceStore(initial: [s]);
      if (_mode == _DebugMode.search) {
        final repo = OnlineRepo(store: store, offthreadParse: false);
        final res = await repo
            .searchOne(s, input, page: 1)
            .timeout(const Duration(seconds: 25));
        if (res.error != null) {
          _out = '解析出错：${res.error}\n\n';
        }
        _out += '搜索到 ${res.books.length} 条：\n'
            '${res.books.take(20).map((b) => jsonEncode(b.toJson())).join('\n')}';
      } else if (_mode == _DebugMode.detail) {
        final info = await OnlineBookService()
            .fetchInfo(s, input)
            .timeout(const Duration(seconds: 25));
        _out = '书名：${info.name ?? '（空）'}\n'
            '作者：${info.author ?? '（空）'}\n'
            '最新章：${info.lastChapter ?? '（空）'}\n'
            '目录 ${info.chapters.length} 章：\n'
            '${info.chapters.take(30).map((c) => c.title).join('\n')}';
      } else {
        final text = await OnlineBookService()
            .fetchChapterText(s, input)
            .timeout(const Duration(seconds: 25));
        final shown = text.length > 2000 ? '${text.substring(0, 2000)}…' : text;
        _out = '正文 ${text.length} 字：\n$shown';
      }
    } on TimeoutException {
      _out = '超时（25s）';
    } catch (e) {
      _out = '运行失败：$e';
    } finally {
      _out = '$_out\n\n— 用时 ${sw.elapsedMilliseconds} ms —';
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = _mode == _DebugMode.search ? '搜索关键词' : '书页地址（详情 / 正文）';
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text('调试 · ${widget.source.bookSourceName}'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('源：${widget.source.bookSourceUrl}',
                style: theme.textTheme.bodySmall),
            const SizedBox(height: 10),
            SegmentedButton<_DebugMode>(
              segments: const [
                ButtonSegment(value: _DebugMode.search, label: Text('搜索')),
                ButtonSegment(value: _DebugMode.detail, label: Text('详情/目录')),
                ButtonSegment(value: _DebugMode.chapter, label: Text('正文')),
              ],
              selected: {_mode},
              onSelectionChanged: (v) => setState(() => _mode = v.first),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _url,
              decoration: InputDecoration(hintText: hint),
              onSubmitted: (_) => _run(),
            ),
            const SizedBox(height: 12),
            BrandBtn('运行', onTap: _running ? null : _run),
            const SizedBox(height: 14),
            Expanded(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).cardColor,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: SingleChildScrollView(
                  child: Text(
                    _out.isEmpty ? '结果会显示在这里' : _out,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
