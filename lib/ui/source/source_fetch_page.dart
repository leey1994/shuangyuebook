// 网络书源 · 获取与测试：从公开合集地址下载书源，全链路测试（搜索→目录→正文），
// 然后一键导入可用源。双端（Android / Windows）同一条纯 Dart 路径。
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shuangyue/legado/batch_tester.dart';
import 'package:shuangyue/legado/models.dart';
import 'package:shuangyue/legado/source_fetcher.dart';
import 'package:shuangyue/legado/source_store.dart';
import 'package:shuangyue/pet/pet_event.dart';
import 'package:shuangyue/pet/pet_store.dart';

/// 网络书源获取与测试页。
///
/// [store] 省略时用全局 [SourceStore.shared]。
class SourceFetchPage extends StatefulWidget {
  const SourceFetchPage({super.key, this.store});

  final SourceStore? store;

  @override
  State<SourceFetchPage> createState() => _SourceFetchPageState();
}

class _SourceFetchPageState extends State<SourceFetchPage> {
  late final SourceStore _store =
      widget.store ?? SourceStore.shared ?? SourceStore();

  final _urlCtrl = TextEditingController();
  final _limitCtrl = TextEditingController(text: '100');

  bool _fetching = false;
  String? _fetchError;
  List<BookSource> _fetched = const [];
  int _alreadyInStore = 0;

  bool _testing = false;
  bool _cancel = false;
  int _done = 0;
  int _total = 0;
  final List<BatchTestResult> _results = [];

  @override
  void dispose() {
    _urlCtrl.dispose();
    _limitCtrl.dispose();
    super.dispose();
  }

  void _snack(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(s)));
  }

  Future<void> _fetch() async {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty) {
      _snack('先填一个书源合集地址，或点上方预设');
      return;
    }
    setState(() {
      _fetching = true;
      _fetchError = null;
      _fetched = const [];
      _results.clear();
      _done = 0;
      _total = 0;
    });
    try {
      final list = await fetchSourceCollection(url);
      if (!mounted) return;
      // 用仓库的 url 索引直接判重（O(1) 一次），不再 map 出整张 Set。
      final already = list.where((s) => _store.containsUrl(s.bookSourceUrl)).length;
      setState(() {
        _fetching = false;
        _fetched = list;
        _alreadyInStore = already;
      });
      _snack('获取到 ${list.length} 条书源（$_alreadyInStore 条已在库中）');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _fetching = false;
        _fetchError = '$e';
      });
    }
  }

  Future<void> _test() async {
    final testable = [
      for (final s in _fetched)
        if (s.bookSourceType == 0 && (s.searchUrl?.trim().isNotEmpty ?? false))
          s,
    ];
    if (testable.isEmpty) {
      _snack('没有可测试的文本小说源（缺搜索地址或非文本类型）');
      return;
    }
    final limit = int.tryParse(_limitCtrl.text.trim()) ?? 0;
    var targets = testable;
    if (limit > 0 && testable.length > limit) {
      targets = List.of(testable)..shuffle(math.Random());
      targets = targets.sublist(0, limit);
    }
    setState(() {
      _testing = true;
      _cancel = false;
      _results.clear();
      _done = 0;
      _total = targets.length;
    });
    await BatchTester().run(
      targets,
      isCancelled: () => _cancel,
      onProgress: (done, total, r) {
        if (!mounted) return;
        setState(() {
          _done = done;
          _results.add(r);
        });
      },
    );
    if (!mounted) return;
    setState(() => _testing = false);
    final ok = _results.where((r) => r.fullOk).length;
    _snack('测试结束：完全可用 $ok/${_results.length}'
        '${_cancel ? '（已提前停止）' : ''}');
  }

  void _import({required bool onlyPassed}) {
    final passed = {
      for (final r in _results.where((r) => r.fullOk)) r.source.bookSourceUrl,
    };
    final tested = {for (final r in _results) r.source.bookSourceUrl};
    final list = <BookSource>[
      for (final s in _fetched)
        if (s.bookSourceType == 0)
          if (!onlyPassed || passed.contains(s.bookSourceUrl))
            passed.contains(s.bookSourceUrl) || !tested.contains(s.bookSourceUrl)
                ? s
                : s.copyWith(enabled: false),
    ];
    if (list.isEmpty) {
      _snack(onlyPassed ? '没有通过全链路测试的书源' : '没有可导入的文本源');
      return;
    }
    // 这里已经是 BookSource 对象，直接批量入库：
    // 不再「编码成 JSON 再解析回来」（1000 条白跑一次 encode+decode），
    // 并且只发一次通知、只排一次落盘。
    final r = _store.addAll(list);
    final report = SourceImportReport(added: r.added, updated: r.updated);
    _snack(report.summary);
    if (report.hasAny) PetStore.I.emit(PetAction.sourceImport);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fullOkCount = _results.where((r) => r.fullOk).length;
    return Scaffold(
      appBar: AppBar(title: const Text('网络获取书源 · 自动测试')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _urlCtrl,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: '书源合集地址（订阅链接）',
                    hintText: 'https://…（书源 JSON 直链）',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final p in kSourceCollectionPresets)
                      ActionChip(
                        label: Text(p.name),
                        onPressed: _fetching || _testing
                            ? null
                            : () {
                                _urlCtrl.text = p.url;
                                setState(() {});
                              },
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    FilledButton.icon(
                      onPressed: _fetching || _testing ? null : _fetch,
                      icon: _fetching
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.download),
                      label: Text(_fetching ? '获取中…' : '获取'),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _limitCtrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: '最多测试条数（0=全部）',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ],
                ),
                if (_fetchError != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    '获取失败：$_fetchError',
                    style: TextStyle(
                      color: theme.colorScheme.error,
                      fontSize: 12,
                    ),
                  ),
                ],
                if (_fetched.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    '已获取 ${_fetched.length} 条（$_alreadyInStore 条已在库中）',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      FilledButton.tonalIcon(
                        onPressed: _testing ? null : _test,
                        icon: const Icon(Icons.science_outlined),
                        label: Text(_testing ? '测试中…' : '全链路测试'),
                      ),
                      if (_testing)
                        OutlinedButton(
                          onPressed: () => setState(() => _cancel = true),
                          child: const Text('停止'),
                        )
                      else ...[
                        FilledButton(
                          onPressed: fullOkCount == 0
                              ? null
                              : () => _import(onlyPassed: true),
                          child: Text('导入可用（$fullOkCount）'),
                        ),
                        OutlinedButton(
                          onPressed: () => _import(onlyPassed: false),
                          child: const Text('全部导入'),
                        ),
                      ],
                    ],
                  ),
                  if (_testing) ...[
                    const SizedBox(height: 8),
                    LinearProgressIndicator(
                      value: _total == 0 ? null : _done / _total,
                    ),
                    const SizedBox(height: 4),
                    Text('$_done / $_total', style: theme.textTheme.bodySmall),
                  ],
                  if (_results.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      '完全可用 $fullOkCount · '
                      '仅搜索可用 ${_results.where((r) => r.searchOk && !r.fullOk).length} · '
                      '不可用 ${_results.where((r) => !r.searchOk).length}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ],
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _results.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        _fetched.isEmpty
                            ? '输入合集地址后点「获取」，再点「全链路测试」。\n'
                                '测试会把每个源真跑一遍：搜索 → 目录 → 首章正文。'
                            : '点「全链路测试」开始批量检测',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  )
                : ListView.builder(
                    itemCount: _results.length,
                    itemBuilder: (_, i) => _tile(_results[i]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _tile(BatchTestResult r) {
    final scheme = Theme.of(context).colorScheme;
    final color =
        r.fullOk ? Colors.green : (r.searchOk ? Colors.orange : scheme.error);
    final icon = r.fullOk
        ? Icons.check_circle
        : (r.searchOk ? Icons.error_outline : Icons.cancel);
    final parts = <String>[
      r.verdict,
      if (r.sample.isNotEmpty) '如「${r.sample}」',
      if (r.failReason != null) r.failReason!,
      '${(r.ms / 1000).toStringAsFixed(1)}s',
    ];
    return ListTile(
      dense: true,
      leading: Icon(icon, color: color, size: 20),
      title: Text(
        r.source.bookSourceName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        parts.join(' · '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12),
      ),
    );
  }
}
