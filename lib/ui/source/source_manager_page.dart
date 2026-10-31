// 书源管理：导入书源的启用/删除/批量管理/详情（查看网站・复制地址）/导入导出；
// 内置固化书源只读展示，不归本页管理。
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shuangyue/data/format.dart';
import 'package:shuangyue/legado/batch_tester.dart';
import 'package:shuangyue/legado/http_client.dart';
import 'package:shuangyue/legado/models.dart';
import 'package:shuangyue/legado/source_health.dart';
import 'package:shuangyue/legado/source_store.dart';
import 'package:shuangyue/pet/pet_event.dart';
import 'package:shuangyue/pet/pet_store.dart';
import 'package:shuangyue/platform/native_bridge.dart';
import 'package:shuangyue/sources/legado_source.dart';
import 'package:shuangyue/sources/registry.dart';
import 'package:shuangyue/sources/source.dart';
import 'package:shuangyue/store.dart';
import 'package:shuangyue/widgets.dart';
import 'package:url_launcher/url_launcher.dart';

import 'source_fetch_page.dart';
import 'source_file_pick_page.dart';
import 'source_list_filter.dart';

/// 书源管理页。
///
/// [store] 省略时用全局 [SourceStore.shared]（main.dart 启动时创建并已加载）。
class SourceManagerPage extends StatefulWidget {
  const SourceManagerPage({super.key, this.store});

  final SourceStore? store;

  /// 入口：其它页面用 `SourceManagerPage.show(context)` 打开。
  static Future<void> show(BuildContext context, {SourceStore? store}) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => SourceManagerPage(store: store),
        ),
      );

  @override
  State<SourceManagerPage> createState() => _SourceManagerPageState();
}

class _SourceManagerPageState extends State<SourceManagerPage> {
  /// main.dart 已监听 store 并同步登记表，这里不再重复调用 syncImportedSources。
  late final SourceStore _store =
      widget.store ?? SourceStore.shared ?? _fresh();

  /// 批量管理：非空表示正在多选（值为已选书源地址）。
  final Set<String> _selected = {};
  bool _bulkMode = false;

  /// 搜索 / 过滤状态（防抖 + 结果缓存，见 source_list_filter.dart）。
  final SourceListFilter _filter = SourceListFilter();
  final TextEditingController _searchCtrl = TextEditingController();
  bool _searching = false;

  static SourceStore _fresh() {
    final s = SourceStore();
    unawaited(s.load());
    return s;
  }

  @override
  void dispose() {
    _filter.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _appBar(),
      // 只监听仓库；列表本体交给 SliverList 懒构建。
      body: ListenableBuilder(
        listenable: _store,
        builder: (context, _) {
          // sourcesView 在仓库未变更时是同一个 List 实例（不复制整表）；
          // shown 在过滤条件与视图都没变时也是同一个实例（命中缓存）。
          final shown = _filter.apply(_store.sourcesView);
          return CustomScrollView(slivers: _slivers(context, shown));
        },
      ),
      bottomNavigationBar: _bulkMode ? _bulkBar() : null,
    );
  }

  /// 列表分片。
  ///
  /// 旧实现是 `ListView(children: [...for (s in store.sources) _tile(s)])`：
  /// 1000 条书源会在每一帧全部实例化（随便一次 setState = 1000 个 ListTile +
  /// 1000 个 Switch）。改成 Sliver 后只有可视区域（± 缓存区）会被 build，
  /// 滑动时按需创建/回收，1000 条与 30 条的帧开销基本一致。
  List<Widget> _slivers(BuildContext context, List<BookSource> shown) {
    final filtering = _filter.isActive;
    return [
      // 搜索时把与结果无关的设置项/内置源收起来，屏幕留给结果。
      if (!_bulkMode && !filtering)
        SliverToBoxAdapter(
          child: Column(
            children: [
              _recommendTile(context),
              _checkSpeedTile(context),
            ],
          ),
        ),
      SliverToBoxAdapter(child: _header(shown)),
      const SliverToBoxAdapter(child: Divider(height: 1)),
      SliverList.builder(
        itemCount: shown.length,
        itemBuilder: (context, i) => _tile(context, shown[i]),
      ),
      if (shown.isEmpty)
        SliverToBoxAdapter(
          child: _noImported(context, searching: filtering && !_store.isEmpty),
        ),
      if (!filtering) ...[
        const SliverToBoxAdapter(child: Divider(height: 1)),
        SliverToBoxAdapter(child: _builtinHeader()),
        SliverList.builder(
          itemCount: builtinSources.length,
          itemBuilder: (context, i) => _builtinTile(context, builtinSources[i]),
        ),
      ],
      // 列表底部留白（批量条 / 最后一行的安全距离）
      SliverToBoxAdapter(child: SizedBox(height: _bulkMode ? 100 : 32)),
    ];
  }

  PreferredSizeWidget _appBar() {
    if (_searching) return _searchAppBar();
    if (_bulkMode) {
      final total = _store.sourcesView.length;
      final all = _selected.length == total;
      return AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: '退出批量管理',
          onPressed: _exitBulkMode,
        ),
        title: Text('已选 ${_selected.length} / $total'),
        actions: [
          TextButton(
            onPressed: total == 0
                ? null
                : () => setState(() {
                      if (all) {
                        _selected.clear();
                      } else {
                        // urls 是缓存视图：全选不必再 map 一遍整表。
                        _selected
                          ..clear()
                          ..addAll(_store.urls);
                      }
                    }),
            child: Text(all ? '取消全选' : '全选'),
          ),
        ],
      );
    }
    return AppBar(
      title: const Text('书源管理'),
      actions: [
        IconButton(
          icon: const Icon(Icons.search),
          tooltip: '搜索书源',
          onPressed: _openSearch,
        ),
        IconButton(
          icon: const Icon(Icons.checklist),
          tooltip: '批量管理',
          onPressed: _store.isEmpty
              ? null
              : () => setState(() {
                    _bulkMode = true;
                    _selected.clear();
                  }),
        ),
        IconButton(
          icon: const Icon(Icons.ios_share),
          tooltip: '导出书源',
          onPressed: _export,
        ),
        IconButton(
          icon: const Icon(Icons.fact_check_outlined),
          tooltip: '检测书源可用性',
          onPressed: _manualCheck,
        ),
        IconButton(
          icon: const Icon(Icons.add),
          tooltip: '导入书源',
          onPressed: _showImportSheet,
        ),
      ],
    );
  }

  /// 搜索态 AppBar：输入框 + 「仅看已启用」+ 清空。
  ///
  /// 输入走 [SourceListFilter] 的防抖（260ms），不是每次按键都重建列表。
  PreferredSizeWidget _searchAppBar() {
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.arrow_back),
        tooltip: '退出搜索',
        onPressed: _closeSearch,
      ),
      titleSpacing: 0,
      title: TextField(
        controller: _searchCtrl,
        autofocus: true,
        textInputAction: TextInputAction.search,
        decoration: const InputDecoration(
          hintText: '搜索名称 / 地址 / 分组',
          border: InputBorder.none,
        ),
        onChanged: (v) => _filter.onInput(v, _onFilterChanged),
      ),
      actions: [
        IconButton(
          icon: Icon(_filter.enabledOnly
              ? Icons.filter_alt
              : Icons.filter_alt_outlined),
          tooltip: '仅看已启用',
          onPressed: () =>
              _filter.setEnabledOnly(!_filter.enabledOnly, _onFilterChanged),
        ),
        IconButton(
          icon: const Icon(Icons.clear),
          tooltip: '清空',
          onPressed: () {
            _searchCtrl.clear();
            _filter.onInput('', _onFilterChanged);
          },
        ),
      ],
    );
  }

  /// 过滤条件生效后刷新一次（防抖回调只到这里，重活已由缓存接住）。
  void _onFilterChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void _openSearch() {
    setState(() {
      _searching = true;
      _bulkMode = false;
      _selected.clear();
    });
  }

  void _closeSearch() {
    _filter.reset();
    _searchCtrl.clear();
    if (!mounted) return;
    setState(() => _searching = false);
  }

  void _exitBulkMode() {
    setState(() {
      _bulkMode = false;
      _selected.clear();
    });
  }

  /// 参与推荐页的书源：`（id, 名称）`（固化源 + 已启用的导入源）。
  ///
  /// 用位置记录（$1/$2）而不是具名记录：具名记录的类型注解在当前
  /// SDK 的分析器里会被当成位置型，全仓库也都用位置记录。
  List<(String, String)> _recommendCandidates() {
    return [
      for (final s in builtinSources) (s.id, s.name),
      // enabledSources 是缓存视图：这里不再整表 where + 复制。
      for (final s in _store.enabledSources) (s.bookSourceUrl, s.bookSourceName),
    ];
  }

  Widget _recommendTile(BuildContext context) => ListenableBuilder(
        listenable: AppStore.I,
        builder: (context, _) {
          final store = AppStore.I;
          final items = _recommendCandidates();
          final on = items.where((e) => store.recommendOn(e.$1)).length;
          return ListTile(
            leading: const Icon(Icons.auto_awesome_motion_outlined),
            title: const Text('推荐页来源'),
            subtitle: Text(
              store.recommendAll
                  ? '未限定 · 全部 ${items.length} 个书源'
                  : '已选 $on / ${items.length} 个',
            ),
            trailing: const Icon(Icons.chevron_right, size: 18),
            onTap: _pickRecommend,
          );
        },
      );

  void _pickRecommend() {
    final app = AppStore.I;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final items = _recommendCandidates();
          return SizedBox(
            height: MediaQuery.of(ctx).size.height * 0.7,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text('推荐页来源',
                            style: TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w700)),
                      ),
                      TextButton(
                        onPressed: () {
                          app.setRecommendAll(true);
                          setSheet(() {});
                        },
                        child: const Text('全选'),
                      ),
                      TextButton(
                        onPressed: () {
                          app.setRecommendAll(false);
                          setSheet(() {});
                        },
                        child: const Text('全不选'),
                      ),
                    ],
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '只勾选参与「发现 → 推荐」的书源。各源随机取半数到全部，再跨源交错。',
                      style: TextStyle(fontSize: 11.5),
                    ),
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  // 书源多时（1000+）弹层里同样只建可视行。
                  child: ListView.builder(
                    itemCount: items.length,
                    itemBuilder: (ctx, i) {
                      final e = items[i];
                      return CheckboxListTile(
                        dense: true,
                        title: Text(e.$2,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        value: app.recommendOn(e.$1),
                        onChanged: (v) {
                          app.setRecommendOn(e.$1, v == true);
                          setSheet(() {});
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _checkSpeedTile(BuildContext context) => ListenableBuilder(
        listenable: AppStore.I,
        builder: (context, _) {
          final store = AppStore.I;
          return ListTile(
            leading: const Icon(Icons.speed),
            title: const Text('检测速度'),
            subtitle: const Text('同时检测的书源数，越快对目标站压力越大'),
            trailing: DropdownButton<int>(
              value: const [4, 8, 16].contains(store.checkConcurrency)
                  ? store.checkConcurrency
                  : 8,
              items: const [
                DropdownMenuItem(value: 4, child: Text('慢 4')),
                DropdownMenuItem(value: 8, child: Text('标准 8')),
                DropdownMenuItem(value: 16, child: Text('极速 16')),
              ],
              onChanged: (v) {
                if (v != null) store.setCheckConcurrency(v);
              },
            ),
          );
        },
      );

  Widget _header(List<BookSource> shown) {
    final n = _store.sourcesView.length;
    final filtering = _filter.isActive;
    final String count;
    if (filtering) {
      count = '匹配 ${shown.length} / $n 个 · 已启用 ${_store.enabledCount}';
    } else {
      count = n == 0 ? '暂无' : '$n 个 · 已启用 ${_store.enabledCount}';
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
      child: Row(
        children: [
          Text('导入书源', style: Theme.of(context).textTheme.titleSmall),
          const Spacer(),
          Text(count, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }

  Widget _tile(BuildContext context, BookSource s) {
    final scheme = Theme.of(context).colorScheme;
    final chosen = _selected.contains(s.bookSourceUrl);
    return ListTile(
      selected: chosen,
      selectedTileColor: scheme.primary.withValues(alpha: 0.10),
      leading: _bulkMode
          ? Icon(
              chosen ? Icons.check_circle : Icons.radio_button_unchecked,
              color: chosen ? scheme.primary : scheme.onSurfaceVariant,
            )
          : CircleAvatar(
              backgroundColor: scheme.primary.withValues(alpha: 0.15),
              child: Text(
                s.bookSourceName.isEmpty ? '?' : s.bookSourceName[0],
                style: TextStyle(
                  color: scheme.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
      title: Text(
        s.bookSourceName.isEmpty ? s.bookSourceUrl : s.bookSourceName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        [
          _hostOf(s.bookSourceUrl),
          if (s.bookSourceGroup != null && s.bookSourceGroup!.isNotEmpty)
            s.bookSourceGroup!,
          if (!s.isTextSource) '${s.typeLabel}源',
          if (s.searchUrl == null) '未配置搜索',
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodySmall,
      ),
      trailing: _bulkMode
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Switch(
                  value: s.enabled,
                  onChanged: (v) => _store.setEnabled(s.bookSourceUrl, v),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 20),
                  tooltip: '删除',
                  onPressed: () =>
                      _confirmDelete(s.bookSourceUrl, s.bookSourceName),
                ),
              ],
            ),
      onTap: () {
        if (_bulkMode) {
          setState(() {
            if (chosen) {
              _selected.remove(s.bookSourceUrl);
            } else {
              _selected.add(s.bookSourceUrl);
            }
          });
        } else {
          _showDetail(s.bookSourceUrl);
        }
      },
      onLongPress: () {
        if (!_bulkMode) {
          setState(() {
            // 批量管理作用于全部书源：先退出搜索，避免「看不见的被选中」。
            _filter.reset();
            _searchCtrl.clear();
            _searching = false;
            _bulkMode = true;
            _selected
              ..clear()
              ..add(s.bookSourceUrl);
          });
        }
      },
    );
  }

  Widget _noImported(BuildContext context, {bool searching = false}) {
    if (searching) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('没有匹配的书源', style: Theme.of(context).textTheme.bodyLarge),
            const SizedBox(height: 6),
            Text(
              '换个关键词，或关掉「仅看已启用」再试。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('还没有导入书源', style: Theme.of(context).textTheme.bodyLarge),
          const SizedBox(height: 6),
          Text(
            '导入「阅读 3.0」格式的书源 JSON（文件 / 粘贴 / 订阅链接），'
            '即可和内置书源一起搜索、看榜、换源。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _showImportSheet,
            icon: const Icon(Icons.add),
            label: const Text('导入书源'),
          ),
        ],
      ),
    );
  }

  Widget _builtinHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('内置书源 ${builtinSources.length} 个',
                  style: Theme.of(context).textTheme.titleSmall),
              const Spacer(),
              const TagPill('只读'),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '内置书源固化在应用内，始终可用，不能停用或删除。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _builtinTile(BuildContext context, NovelSource s) {
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: Theme.of(context).hintColor.withValues(alpha: 0.15),
        child: Text(
          s.name.isEmpty ? '?' : s.name[0],
          style: TextStyle(
            color: Theme.of(context).hintColor,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      title: Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        _hostOf(s.baseUrl),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodySmall,
      ),
      onTap: () => _openWeb(s.baseUrl),
    );
  }

  /// 底部批量操作栏：启用 / 停用 / 删除（作用于已选条目）。
  Widget _bulkBar() {
    final ready = _selected.isNotEmpty;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: ready ? () => _bulkEnabled(true) : null,
                child: const Text('启用'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton(
                onPressed: ready ? () => _bulkEnabled(false) : null,
                child: const Text('停用'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton(
                onPressed: ready ? _bulkDelete : null,
                child: const Text('删除'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _bulkEnabled(bool value) {
    final n = _store.setEnabledAll(_selected, value);
    _snack(value ? '已启用 $n 个书源' : '已停用 $n 个书源');
    setState(_selected.clear);
  }

  Future<void> _bulkDelete() async {
    final count = _selected.length;
    final ok = await _confirm('批量删除', '确定删除已选的 $count 个书源吗？删除后无法恢复。');
    if (ok != true || !mounted) return;
    final n = _store.removeMany(_selected);
    PetStore.I.emit(PetAction.sourceRemove);
    setState(() {
      _selected.clear();
      if (_store.isEmpty) _bulkMode = false;
    });
    _snack('已删除 $n 个书源');
  }

  // ---------- 详情 ----------

  /// 导入书源详情（底部弹层）：完整信息 + 单源操作。
  void _showDetail(String url) {
    final s = _store.byUrl(url);
    if (s == null) return;
    final adapter = _adapterOf(url);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                  s.bookSourceName.isEmpty ? s.bookSourceUrl : s.bookSourceName,
                  style: Theme.of(ctx).textTheme.titleMedium),
              const SizedBox(height: 2),
              Text(
                s.enabled ? '已启用' : '已停用',
                style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                      color: s.enabled
                          ? Theme.of(ctx).colorScheme.primary
                          : Theme.of(ctx).hintColor,
                    ),
              ),
              const SizedBox(height: 10),
              _kv(ctx, '地址', s.bookSourceUrl),
              _kv(ctx, '类型', '${s.typeLabel}${s.isTextSource ? '' : '（v1.1 暂不支持阅读）'}'),
              if (s.bookSourceGroup != null && s.bookSourceGroup!.isNotEmpty)
                _kv(ctx, '分组', s.bookSourceGroup!),
              _kv(ctx, '搜索', s.searchUrl ?? '（未配置）'),
              _kv(ctx, '发现', _exploreText(adapter)),
              _kv(ctx, '权重', '${s.weight}'),
              _kv(ctx, '响应', s.respondTime ?? '（无）'),
              _kv(ctx, '更新', s.lastUpdateTime ?? '（无）'),
              _kv(ctx, '并发率', s.concurrentRate ?? '不限'),
              _kv(ctx, '备注', s.bookSourceComment ?? '（无）'),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: () {
                      Navigator.pop(ctx);
                      unawaited(_diagnose(s));
                    },
                    icon: const Icon(Icons.bug_report_outlined, size: 18),
                    label: const Text('诊断'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _openWeb(s.bookSourceUrl),
                    icon: const Icon(Icons.public, size: 18),
                    label: const Text('查看网站'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _copy(s.bookSourceUrl),
                    icon: const Icon(Icons.copy, size: 18),
                    label: const Text('复制地址'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () {
                      _store.setEnabled(s.bookSourceUrl, !s.enabled);
                      Navigator.pop(ctx);
                    },
                    icon: Icon(s.enabled ? Icons.toggle_off : Icons.toggle_on,
                        size: 18),
                    label: Text(s.enabled ? '停用' : '启用'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () {
                      Navigator.pop(ctx);
                      _confirmDelete(s.bookSourceUrl, s.bookSourceName);
                    },
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('删除'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 单源诊断：真实跑一遍搜索 → 目录 → 首章正文，把过程逐行摊开。
  ///
  /// 目的不是给个通过/不通过，而是让用户（或书源作者）看见**哪一步、为什么**
  /// 断了 —— 规则引擎的失败默认都是静默的，这一层是唯一的解释入口。
  Future<void> _diagnose(BookSource s) async {
    final nav = Navigator.of(context);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('正在试跑'),
        content: Row(
          children: [
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Expanded(child: Text('搜索 → 目录 → 首章正文，最长 45 秒', style: Theme.of(ctx).textTheme.bodySmall)),
          ],
        ),
      ),
    );
    BatchTestResult? r;
    try {
      r = await BatchTester().testOne(s);
    } catch (e) {
      r = BatchTestResult(source: s, error: '$e', log: ['未预期异常：$e']);
    }
    if (!mounted) return;
    nav.pop();
    final text = [
      '书源：${s.bookSourceName}',
      '地址：${s.bookSourceUrl}',
      '结论：${r.verdict}${r.error == null ? '' : ' — ${r.error}'}',
      '总耗时：${(r.ms / 1000).toStringAsFixed(1)}s',
      '',
      ...r.log,
    ].join('\n');
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${s.bookSourceName} · ${r!.verdict}'),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: SelectableText(text,
                style: const TextStyle(fontSize: 12.5, height: 1.6)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: text));
              _snack('诊断信息已复制');
            },
            child: const Text('复制'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  static String _exploreText(LegadoSource? adapter) {
    if (adapter == null) return '（未登记）';
    if (adapter.exploreNeedsJs) return '脚本解析，发现页不可用';
    return adapter.hasExplore ? '支持' : '（未配置）';
  }

  LegadoSource? _adapterOf(String url) {
    for (final s in importedSources) {
      if (s.id == url) return s;
    }
    return null;
  }

  Widget _kv(BuildContext ctx, String k, String v) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 64,
              child: Text(k, style: Theme.of(ctx).textTheme.bodySmall),
            ),
            Expanded(
              child:
                  SelectableText(v, style: Theme.of(ctx).textTheme.bodySmall),
            ),
          ],
        ),
      );

  Future<bool> _confirm(String title, String message) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _confirmDelete(String url, String name) async {
    if (await _confirm('删除书源', '确定删除「$name」吗？')) {
      _store.remove(url);
      PetStore.I.emit(PetAction.sourceRemove);
    }
  }

  // ---------- 导入 / 导出 ----------

  /// 导出全部导入书源：优先复制到剪贴板；剪贴板被拒时改为弹窗展示 JSON 自行取走。
  Future<void> _export() async {
    if (_store.isEmpty) {
      _snack('还没有书源可导出');
      return;
    }
    // 大库的编码在后台 isolate 做，1000 条时点导出不再卡一下 UI。
    final json = await _store.exportJsonAsync();
    if (!mounted) return;
    final size = formatBytes(utf8.encode(json).length);
    try {
      await Clipboard.setData(ClipboardData(text: json));
      _snack('已复制全部书源 JSON（$size）到剪贴板');
      PetStore.I.emit(PetAction.exportData);
    } catch (_) {
      if (!mounted) return;
      // ponytail: 内容过大时剪贴板会失败，这里只弹窗兜底；需要自动落盘再说
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('导出书源'),
          content: SizedBox(
            width: 460,
            height: 380,
            child: SingleChildScrollView(child: SelectableText(json)),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    }
  }

  void _showImportSheet() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.only(bottom: 4),
              child: Text('导入书源'),
            ),
            ListTile(
              leading: const Icon(Icons.content_paste),
              title: const Text('粘贴导入'),
              subtitle: const Text('粘贴「阅读 3.0」格式的书源 JSON'),
              onTap: () {
                Navigator.pop(sheetCtx);
                _importFromText();
              },
            ),
            ListTile(
              leading: const Icon(Icons.insert_drive_file),
              title: const Text('从文件导入'),
              subtitle: const Text('浏览手机 / 电脑上的 JSON 文件'),
              onTap: () {
                Navigator.pop(sheetCtx);
                _importFromFile();
              },
            ),
            ListTile(
              leading: const Icon(Icons.auto_awesome),
              title: const Text('内置精选书源'),
              subtitle: const Text('离线内置书源包（无需联网），导入后可在本页单独删除'),
              onTap: () {
                Navigator.pop(sheetCtx);
                _importBuiltin();
              },
            ),
            ListTile(
              leading: const Icon(Icons.link),
              title: const Text('从订阅链接导入'),
              subtitle: const Text('用网络地址获取书源 JSON'),
              onTap: () {
                Navigator.pop(sheetCtx);
                _importFromUrl();
              },
            ),
            ListTile(
              leading: const Icon(Icons.travel_explore),
              title: const Text('从网络获取并测试'),
              subtitle: const Text('下载公开书源合集，全链路测试后一键导入可用源'),
              onTap: () {
                Navigator.pop(sheetCtx);
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => SourceFetchPage(store: _store),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  void _report(SourceImportReport r) {
    if (!r.hasAny) {
      _snack(r.error ?? r.summary);
      return;
    }
    _snack(r.summary);
    PetStore.I.emit(PetAction.sourceImport);
    // 刚导入的书源很可能是一堆失效的老收藏，导入后立刻批量验活。
    // 但删不删由用户拍板：瞬时网络抖动也会让好源搜不出东西，
    // 宁可多留一个废源，也别把用户刚导入的源悄悄删了。
    unawaited(_verifyAfterImport());
  }

  /// 导入后批量检测：先给出完整结论，未通过的源由用户决定去留。
  Future<void> _verifyAfterImport() async {
    if (!mounted) return;
    _snack('正在检测书源可用性…');
    final report = await SourceHealthStore.I.run(
      concurrency: AppStore.I.checkConcurrency,
      onProgress: _progress,
    );
    if (!mounted) return;
    if (!report.hasFailure) {
      _snack(report.summary);
      PetStore.I.emit(PetAction.sourceHealthy);
      if (mounted) setState(() {});
      return;
    }
    PetStore.I.emit(PetAction.sourceFailed);
    await _showFailedDialog(report, allowRemove: true);
    if (mounted) setState(() {});
  }

  /// 检测进度提示（节流）：1000 条源不必刷 200 次 SnackBar。
  void _progress(int done, int total) {
    if (!mounted) return;
    final step = total <= 50 ? 5 : (total ~/ 20).clamp(1, total);
    if (done != total && done % step != 0) return;
    _snack('检测中…$done/$total');
  }

  /// 列出检测不通过的书源与原因；[allowRemove] 时提供「移除未通过」操作。
  ///
  /// 返回后用户若选了移除，才真正从仓库删除并提示数量。
  Future<void> _showFailedDialog(
    SourceCheckReport report, {
    required bool allowRemove,
  }) async {
    final failed = report.failed;
    if (failed.isEmpty) return;
    // 极端情况（1000 条全废）不必把 1000 行都塞进对话框：
    // 只列前 100 条，其余引导到「阅读记录」的完整清单。
    const maxRows = 100;
    final shown = failed.length > maxRows ? failed.sublist(0, maxRows) : failed;
    final hidden = failed.length - shown.length;
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${failed.length} 个书源未通过检测'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(report.summary),
              const SizedBox(height: 12),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: shown.length + (hidden > 0 ? 1 : 0),
                  itemBuilder: (ctx, i) {
                    if (i >= shown.length) {
                      return Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          '…还有 $hidden 个，完整清单见「阅读记录」',
                          style: const TextStyle(fontSize: 11),
                        ),
                      );
                    }
                    final f = shown[i];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            f.name,
                            style: const TextStyle(
                                fontWeight: FontWeight.w600, fontSize: 13),
                          ),
                          Text(
                            f.error ?? '不可用',
                            style: TextStyle(
                              fontSize: 11,
                              color: Theme.of(ctx).colorScheme.error,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        actions: [
          if (allowRemove) ...[
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'keep'),
              child: const Text('全部保留'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, 'remove'),
              child: const Text('移除未通过'),
            ),
          ] else
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('知道了'),
            ),
        ],
      ),
    );
    if (action != 'remove') return;
    final removed = _store.removeMany(failed.map((f) => f.url));
    await _store.flush();
    if (mounted) _snack('已移除 $removed 个未通过的书源');
  }

  /// 手动体检：只标记不删除，用户可自行决定停用哪些。
  Future<void> _manualCheck() async {
    _snack('正在检测书源可用性…');
    final report = await SourceHealthStore.I.run(
      concurrency: AppStore.I.checkConcurrency,
      onProgress: _progress,
    );
    if (!mounted) return;
    if (report.hasFailure) {
      await _showFailedDialog(report, allowRemove: false);
    } else {
      _snack(report.summary);
    }
    if (mounted) setState(() {});
  }

  Future<String?> _prompt(
    String title,
    String hint, {
    String confirm = '确定',
    TextInputType? keyboard,
    int maxLines = 1,
  }) async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: maxLines,
          keyboardType: keyboard,
          decoration: InputDecoration(hintText: hint),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: Text(confirm),
          ),
        ],
      ),
    );
    controller.dispose();
    return text;
  }

  Future<void> _importFromText() async {
    final text =
        await _prompt('粘贴书源 JSON', '在此粘贴书源 JSON…', confirm: '导入', maxLines: 8);
    if (text == null || text.isEmpty || !mounted) return;
    // 大 JSON 的 jsonDecode 在后台 isolate 做，避免粘贴 1000 条后卡住界面。
    final report = await _store.importFromTextAsync(text);
    if (!mounted) return;
    _report(report);
  }

  Future<void> _importFromFile() async {
    // 打开内置文件浏览器选文件（跟本地书导入同一套目录逻辑）；
    // 浏览器里留了「手输路径」给读不了目录的场景兜底。
    final path = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const SourceFilePickPage()),
    );
    if (path == null || path.isEmpty || !mounted) return;
    final report = await _store.importFromFile(path);
    if (!mounted) return;
    _report(report);
  }

  /// 导入随包内置的精选书源（离线资产）。
  ///
  /// 与其它导入完全同路径：导入后就是普通导入源，可单条删除 / 批量删除。
  Future<void> _importBuiltin() async {
    try {
      final text = await rootBundle.loadString(
        'assets/sources/curated_sources.json',
      );
      if (!mounted) return;
      final report = await _store.importFromTextAsync(text);
      if (!mounted) return;
      _report(report);
    } catch (e) {
      _snack('内置书源读取失败：$e');
    }
  }

  Future<void> _importFromUrl() async {
    final url = await _prompt('从订阅链接导入', 'https://…（书源 JSON 直链）',
        confirm: '获取', keyboard: TextInputType.url);
    if (url == null || url.isEmpty || !mounted) return;
    _snack('正在获取订阅…');
    try {
      final resp = await SourceHttpClient().get(
        url,
        timeout: const Duration(seconds: 20),
        retries: 1,
      );
      if (!resp.ok) throw SourceHttpException('HTTP ${resp.statusCode}');
      if (!mounted) return;
      final report = await _store.importFromTextAsync(resp.body);
      if (!mounted) return;
      _report(report);
    } catch (e) {
      _snack('获取失败：$e');
    }
  }

  // ---------- 小工具 ----------

  /// 打开网站：优先系统原生桥，桌面端退回 url_launcher。
  Future<void> _openWeb(String url) async {
    if (await NativeBridge.openUrl(url)) return;
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {
      _snack('没有找到可用的浏览器');
    }
  }

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    _snack('地址已复制');
  }

  void _snack(String text) {
    if (!mounted) return;
    // 直接 showSnackBar 是**排队**的：一次导入 1000 条时进度提示会排上百条，
    // 之后好几分钟屏幕一直在滑入滑出（本身也是卡顿感来源）。
    // 先收掉上一条，队列里永远只有最新的一条。
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  static String _hostOf(String url) {
    final host = Uri.tryParse(url)?.host ?? '';
    return host.isEmpty ? url : host;
  }
}
