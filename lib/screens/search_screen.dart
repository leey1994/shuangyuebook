import 'package:flutter/material.dart';

import '../feed_cache.dart';
import '../models.dart';
import '../pet/pet_event.dart';
import '../pet/pet_store.dart';
import '../sources/registry.dart';
import '../sources/source.dart';
import '../store.dart';
import '../widgets.dart';
import 'book_detail_screen.dart';

/// 搜索：多源可选（默认全部）。
/// [initialQuery] 非空时进入即自动搜索（书单正文点击书名跳转用）。
class SearchScreen extends StatefulWidget {
  final String? initialQuery;
  const SearchScreen({super.key, this.initialQuery});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _controller = TextEditingController();
  List<(NovelSource, Book)> _results = [];
  bool _loading = false;
  bool _searched = false;
  Object? _error;
  String _query = '';
  int _done = 0; // 已返回/失败的书源数（进度展示）
  int _total = 0;
  int _gen = 0; // 搜索代际：换查询后作废上一轮在途结果，防止旧结果混入/进度错乱

  @override
  void initState() {
    super.initState();
    final q = widget.initialQuery?.trim();
    if (q != null && q.isNotEmpty) {
      _controller.text = q;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _search(q);
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search(String raw) async {
    final q = raw.trim();
    if (q.isEmpty) return;
    FocusScope.of(context).unfocus();
    AppStore.I.pushSearch(q);
    PetStore.I.emit(PetAction.search);
    final targets = allSources;
    final gen = ++_gen;
    setState(() {
      _query = q;
      _loading = true;
      _searched = true;
      _error = null;
      _results = [];
      _done = 0;
      _total = targets.length;
    });
    Object? err;
    var remaining = targets.length;
    // 全源并行 + 每个源返回即上屏（原来逐个 await，慢源拖死整体）
    await Future.wait(targets.map((s) async {
      try {
        final r = await FeedCache.reach(
          FeedCache.key(['search', s.id, q]),
          () => s.search(q),
        );
        if (!mounted || gen != _gen) return;
        setState(() {
          _results = [..._results, for (final b in r) (s, b)];
        });
      } catch (e) {
        if (gen == _gen) err ??= e;
      } finally {
        remaining--;
        if (mounted && gen == _gen) {
          setState(() {
            _done++;
            if (remaining == 0) {
              _loading = false;
              _error = _results.isEmpty ? err : null;
            }
          });
        }
      }
    }));
    if (!mounted || gen != _gen) return;
    if (_loading) setState(() => _loading = false);
  }

  /// 清空：输入框、结果、进度一起归零，并作废在途的那轮搜索。
  void _clear() {
    _gen++; // 让在途搜索的回调作废，避免清空后又冒出新结果
    _controller.clear();
    PetStore.I.emit(PetAction.searchClear);
    setState(() {
      _results = [];
      _loading = false;
      _searched = false;
      _query = '';
      _error = null;
      _done = 0;
      _total = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final store = AppStore.I;
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          textInputAction: TextInputAction.search,
          onSubmitted: _search,
          decoration: InputDecoration(
            hintText: '输入书名或作者',
            border: InputBorder.none,
            suffixIcon: IconButton(
              icon: const Icon(Icons.clear),
              tooltip: '清空',
              // 连同搜索结果一起清掉，而不是只清输入框
              onPressed: _clear,
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => _search(_controller.text),
              child: const Text('搜索')),
        ],
        // 进度钉在输入框正下方：滚动时始终可见，
        // 且不占用结果列表的一行高度
        bottom: _loading ? _progressBar() : null,
      ),
      body: ListenableBuilder(
        listenable: store,
        builder: (context, _) {
          return Column(
            children: [
              Expanded(
                child: !_searched
                    ? _RecentSearches(
                        items: store.searchHistory,
                        onTap: (q) {
                          _controller.text = q;
                          _search(q);
                        },
                        onClear: () => AppStore.I.clearSearchHistory(),
                      )
                    // 已有结果就立刻展示，不等所有书源跑完
                    // （慢源可能十几秒，不能让快源的结果白等）
                    : _results.isNotEmpty
                        ? _resultList(store)
                        : _loading
                            ? Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const CircularProgressIndicator(),
                                    const SizedBox(height: 16),
                                    Text(
                                      '正在搜索…已完成 $_done/$_total 个书源',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodyMedium
                                          ?.copyWith(
                                              color:
                                                  Theme.of(context).hintColor),
                                    ),
                                  ],
                                ),
                              )
                            : _error != null
                                ? Center(child: Text('搜索失败：$_error'))
                                : Center(
                                    child: Text('「$_query」没有结果',
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodyLarge)),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 输入框下方的进度条：已完成 / 总数 + 文字说明。
  PreferredSizeWidget _progressBar() => PreferredSize(
        preferredSize: const Size.fromHeight(22),
        child: Container(
          height: 22,
          color: Theme.of(context).colorScheme.surface,
          child: Row(
            children: [
              Expanded(
                child: LinearProgressIndicator(
                  value: _total == 0 ? null : _done / _total,
                  minHeight: 22,
                  backgroundColor:
                      Theme.of(context).colorScheme.surfaceContainerHighest,
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Text(
                  '$_done/$_total · 已找到 ${_results.length} 本',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
            ],
          ),
        ),
      );

  Widget _resultList(AppStore store) => ListView.builder(
        itemCount: _results.length + (_loading ? 1 : 0),
        itemBuilder: (context, i) {
          if (i >= _results.length) {
            // 列表末尾一行「还在搜」，其余书源回来会自动插到它前面
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Center(
                child: Text('还在搜索…已完成 $_done/$_total 个书源',
                    style: Theme.of(context).textTheme.bodySmall),
              ),
            );
          }
          final (s, b) = _results[i];
          return BookTile(
            book: b,
            trailing: Chip(
              label: Text(s.name, style: const TextStyle(fontSize: 11)),
              padding: EdgeInsets.zero,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => BookDetailScreen(book: b))),
          );
        },
      );
}

class _RecentSearches extends StatelessWidget {
  final List<String> items;
  final void Function(String) onTap;
  final VoidCallback onClear;
  const _RecentSearches({
    required this.items,
    required this.onTap,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return Center(
        child:
            Text('输入书名或作者开始搜索', style: Theme.of(context).textTheme.bodyLarge),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Row(
          children: [
            Text('搜索历史', style: Theme.of(context).textTheme.titleSmall),
            const Spacer(),
            TextButton(onPressed: onClear, child: const Text('清空')),
          ],
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final q in items)
              ActionChip(label: Text(q), onPressed: () => onTap(q)),
          ],
        ),
      ],
    );
  }
}
