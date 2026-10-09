// 书源管理：导入书源的启用/删除/批量管理/详情（查看网站・复制地址）/导入导出；
// 内置固化书源只读展示，不归本页管理。
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:novel_reader/data/format.dart';
import 'package:novel_reader/legado/http_client.dart';
import 'package:novel_reader/legado/models.dart';
import 'package:novel_reader/legado/source_health.dart';
import 'package:novel_reader/legado/source_store.dart';
import 'package:novel_reader/platform/native_bridge.dart';
import 'package:novel_reader/sources/legado_source.dart';
import 'package:novel_reader/sources/registry.dart';
import 'package:novel_reader/sources/source.dart';
import 'package:novel_reader/widgets.dart';
import 'package:url_launcher/url_launcher.dart';

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

  static SourceStore _fresh() {
    final s = SourceStore();
    unawaited(s.load());
    return s;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _appBar(),
      body: ListenableBuilder(
        listenable: _store,
        builder: (context, _) => ListView(
          padding: EdgeInsets.only(bottom: _bulkMode ? 100 : 32),
          children: [
            _header(),
            const Divider(height: 1),
            for (final s in _store.sources) _tile(context, s),
            if (_store.sources.isEmpty) _noImported(context),
            const Divider(height: 1),
            _builtinHeader(),
            for (final s in builtinSources) _builtinTile(context, s),
          ],
        ),
      ),
      bottomNavigationBar: _bulkMode ? _bulkBar() : null,
    );
  }

  PreferredSizeWidget _appBar() {
    if (_bulkMode) {
      final total = _store.sources.length;
      final all = _selected.length == total;
      return AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: '退出批量管理',
          onPressed: () => setState(() {
            _bulkMode = false;
            _selected.clear();
          }),
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
                        _selected
                          ..clear()
                          ..addAll(_store.sources.map((s) => s.bookSourceUrl));
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
          icon: const Icon(Icons.checklist),
          tooltip: '批量管理',
          onPressed: _store.sources.isEmpty
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

  Widget _header() {
    final n = _store.sources.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
      child: Row(
        children: [
          Text('导入书源', style: Theme.of(context).textTheme.titleSmall),
          const Spacer(),
          Text(
            n == 0 ? '暂无' : '$n 个 · 已启用 ${_store.enabledCount}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
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
            _bulkMode = true;
            _selected
              ..clear()
              ..add(s.bookSourceUrl);
          });
        }
      },
    );
  }

  Widget _noImported(BuildContext context) {
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
    setState(() {
      _selected.clear();
      if (_store.sources.isEmpty) _bulkMode = false;
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
                  FilledButton.icon(
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
    }
  }

  // ---------- 导入 / 导出 ----------

  /// 导出全部导入书源：优先复制到剪贴板；剪贴板被拒时改为弹窗展示 JSON 自行取走。
  Future<void> _export() async {
    if (_store.sources.isEmpty) {
      _snack('还没有书源可导出');
      return;
    }
    final json = _store.exportJson();
    final size = formatBytes(utf8.encode(json).length);
    try {
      await Clipboard.setData(ClipboardData(text: json));
      _snack('已复制全部书源 JSON（$size）到剪贴板');
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
              subtitle: const Text('填写书源 JSON 文件的完整路径'),
              onTap: () {
                Navigator.pop(sheetCtx);
                _importFromFile();
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
    // 刚导入的书源很可能是一堆失效的老收藏，导入后立刻批量验活：
    // 搜不出东西的直接移除，并把「删了什么、为什么」告诉用户。
    unawaited(_verifyAfterImport());
  }

  /// 导入后批量检测：删掉搜不出东西的书源，并给出可读的结论。
  Future<void> _verifyAfterImport() async {
    if (!mounted) return;
    _snack('正在检测书源可用性…');
    final report = await SourceHealthStore.I.run(
      removeFailed: true,
      onProgress: (done, total) {
        if (mounted && (done == total || done % 5 == 0)) {
          _snack('检测中…$done/$total');
        }
      },
    );
    if (!mounted) return;
    if (!report.hasFailure) {
      _snack(report.summary);
      if (mounted) setState(() {});
      return;
    }
    await _showRemovedDialog(report);
    if (mounted) setState(() {});
  }

  /// 列出被移除的书源与原因。
  Future<void> _showRemovedDialog(SourceCheckReport report) => showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('已移除 ${report.removed.length} 个不可用书源'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(report.summary),
                const SizedBox(height: 12),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final f in report.failed)
                        Padding(
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
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('知道了'),
            ),
          ],
        ),
      );

  /// 手动体检：只标记不删除，用户可自行决定停用哪些。
  Future<void> _manualCheck() async {
    _snack('正在检测书源可用性…');
    final report = await SourceHealthStore.I.run(
      onProgress: (done, total) {
        if (mounted && (done == total || done % 5 == 0)) {
          _snack('检测中…$done/$total');
        }
      },
    );
    if (!mounted) return;
    await _showRemovedDialog(report);
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
    _report(_store.importFromText(text));
  }

  Future<void> _importFromFile() async {
    final path = await _prompt('从文件导入', '书源 JSON 文件的完整路径', confirm: '导入');
    if (path == null || path.isEmpty || !mounted) return;
    _report(await _store.importFromFile(path));
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
      _report(_store.importFromText(resp.body));
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
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  static String _hostOf(String url) {
    final host = Uri.tryParse(url)?.host ?? '';
    return host.isEmpty ? url : host;
  }
}
