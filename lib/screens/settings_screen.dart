import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/shelf_sort.dart';
import '../pet/pet_event.dart';
import '../pet/pet_painter.dart';
import '../pet/pet_store.dart';
import '../sources/registry.dart';
import '../store.dart';
import '../theme.dart';
import '../ui/source/source_manager_page.dart';
import '../update_check.dart';
import 'bookmarks_page.dart';
import 'local_import_page.dart';
import 'stats_page.dart';

/// 设置：阅读偏好、缓存管理、关于。
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  int _cacheMb = -1;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    _refreshCache();
  }

  Future<void> _refreshCache() async {
    final bytes = await AppStore.I.cacheSize();
    if (mounted) setState(() => _cacheMb = bytes);
  }

  Future<void> _checkUpdate() async {
    if (_checking) return;
    setState(() => _checking = true);
    try {
      await UpdateChecker.check(context, manual: true);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  String _fmt(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  /// 书架排序方式 + 升降序选择弹层。
  Future<void> _pickSort(BuildContext context) async {
    final store = AppStore.I;
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final m in ShelfSortMode.values)
              ListTile(
                title: Text(m.label),
                trailing: store.shelfSort == m
                    ? Icon(Icons.check,
                        color: Theme.of(ctx).colorScheme.primary)
                    : null,
                onTap: () {
                  store.setShelfSort(m);
                  Navigator.of(ctx).pop();
                },
              ),
            const Divider(height: 1),
            ListTile(
              leading: Icon(store.shelfAscending
                  ? Icons.arrow_upward
                  : Icons.arrow_downward),
              title: Text(store.shelfAscending ? '当前：正序' : '当前：倒序'),
              onTap: () {
                store.setShelfAscending(!store.shelfAscending);
                Navigator.of(ctx).pop();
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = AppStore.I;
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListenableBuilder(
        listenable: store,
        builder: (context, _) {
          final p = store.prefs;
          return ListView(
            children: [
              const _SectionHeader('书源'),
              ListTile(
                leading: const Icon(Icons.library_books_outlined),
                title: const Text('书源管理'),
                subtitle: Text(
                    '导入 / 停用 / 导出「阅读 3.0」书源。当前启用 ${allSources.length - 1} 个，其中 ${builtinSources.length} 个为内置固化源。'),
                trailing: const Icon(Icons.chevron_right, size: 18),
                onTap: () => SourceManagerPage.show(context),
              ),
              ListTile(
                leading: const Icon(Icons.folder_open_outlined),
                title: const Text('导入本地书'),
                subtitle: const Text('从手机 / 电脑目录导入 TXT、EPUB，支持多选与批量扫描'),
                trailing: const Icon(Icons.chevron_right, size: 18),
                onTap: () => showLocalImport(context),
              ),
              const Divider(),
              const _SectionHeader('阅读'),
              ListTile(
                title: const Text('翻页方式'),
                subtitle: Text('${p.pageMode.label} · ${p.pageMode.hint}'),
                trailing: DropdownButton<PageMode>(
                  value: p.pageMode,
                  underline: const SizedBox.shrink(),
                  items: [
                    for (final m in PageMode.values)
                      DropdownMenuItem(
                          value: m,
                          child: Text(m.label,
                              style: const TextStyle(fontSize: 13))),
                  ],
                  onChanged: (v) {
                    if (v != null) store.setPageMode(v);
                  },
                ),
              ),
              ListTile(
                title: const Text('阅读背景'),
                subtitle: Text(readerBgOf(p.bgIndex, p.theme).name),
                trailing: Wrap(
                  spacing: 4,
                  children: [
                    for (var i = 0; i < kReaderBgs.length; i++)
                      GestureDetector(
                        onTap: () => store.setBgIndex(i),
                        child: Container(
                          width: 22,
                          height: 22,
                          margin: const EdgeInsets.all(2),
                          decoration: BoxDecoration(
                            color: kReaderBgs[i].bg,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: p.bgIndex == i
                                  ? Theme.of(context).colorScheme.primary
                                  : const Color(0x33888888),
                              width: p.bgIndex == i ? 2 : 1,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              SwitchListTile(
                title: const Text('页眉'),
                subtitle: const Text('阅读时顶部显示章节名'),
                value: p.showHeader,
                onChanged: store.setShowHeader,
              ),
              SwitchListTile(
                title: const Text('页脚'),
                subtitle: const Text('阅读时底部显示时间、页码与电量'),
                value: p.showFooter,
                onChanged: store.setShowFooter,
              ),
              ListTile(
                title: Text('字号（${p.fontSize.round()}）'),
                subtitle: Slider(
                  value: p.fontSize,
                  min: 12,
                  max: 32,
                  divisions: 20,
                  onChanged: store.setFontSize,
                ),
              ),
              ListTile(
                title: Text('行距（${p.lineHeight.toStringAsFixed(1)}）'),
                subtitle: Slider(
                  value: p.lineHeight,
                  min: 1.2,
                  max: 2.6,
                  divisions: 14,
                  onChanged: store.setLineHeight,
                ),
              ),
              ListTile(
                title: const Text('主题'),
                subtitle: SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: AppThemes.white, label: Text('锦绣白')),
                    ButtonSegment(value: AppThemes.black, label: Text('极光黑')),
                  ],
                  selected: {
                    p.theme == AppThemes.black
                        ? AppThemes.black
                        : AppThemes.white
                  },
                  onSelectionChanged: (s) => store.setTheme(s.first),
                ),
              ),
              const Divider(),
              const _SectionHeader('书架与记录'),
              ListTile(
                leading: const Icon(Icons.sort),
                title: const Text('书架排序'),
                subtitle: Text('${store.shelfSort.label} · '
                    '${store.shelfAscending ? '正序' : '倒序'}'),
                trailing: const Icon(Icons.chevron_right, size: 18),
                onTap: () => _pickSort(context),
              ),
              ListTile(
                leading: const Icon(Icons.bar_chart_outlined),
                title: const Text('阅读记录'),
                subtitle: const Text('累计时长、连续天数、最近 7 天'),
                trailing: const Icon(Icons.chevron_right, size: 18),
                onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(builder: (_) => const StatsPage())),
              ),
              ListTile(
                leading: const Icon(Icons.bookmarks_outlined),
                title: const Text('全部书签'),
                subtitle: const Text('跨书查看书签并跳回原文'),
                trailing: const Icon(Icons.chevron_right, size: 18),
                onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => const BookmarksPage())),
              ),
              const Divider(),
              const _SectionHeader('桌宠'),
              const _PetTile(),
              const Divider(),
              const _SectionHeader('离线缓存'),
              ListTile(
                title: const Text('自动缓存后续章节'),
                subtitle: const Text('阅读时在后台自动下载后面的章节，便于离线与加速翻页'),
                trailing: DropdownButton<int>(
                  value: const [0, 20, 50, 100].contains(p.autoCache)
                      ? p.autoCache
                      : 50,
                  items: const [
                    DropdownMenuItem(value: 0, child: Text('关闭')),
                    DropdownMenuItem(value: 20, child: Text('后 20 章')),
                    DropdownMenuItem(value: 50, child: Text('后 50 章')),
                    DropdownMenuItem(value: 100, child: Text('后 100 章')),
                  ],
                  onChanged: (v) => store.setAutoCache(v ?? 50),
                ),
              ),
              ListTile(
                title: Text('已缓存 ${_cacheMb < 0 ? '…' : _fmt(_cacheMb)}'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.refresh),
                      onPressed: _refreshCache,
                    ),
                    TextButton(
                      onPressed: () async {
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: const Text('清除缓存'),
                            content: const Text('将删除全部离线章节（不影响书架与进度）'),
                            actions: [
                              TextButton(
                                  onPressed: () => Navigator.pop(ctx, false),
                                  child: const Text('取消')),
                              FilledButton(
                                  onPressed: () => Navigator.pop(ctx, true),
                                  child: const Text('清除')),
                            ],
                          ),
                        );
                        if (ok == true) {
                          await store.clearCache();
                          PetStore.I.emit(PetAction.clearCache);
                          _refreshCache();
                        }
                      },
                      child: const Text('清除'),
                    ),
                  ],
                ),
                subtitle: const Text('在书籍详情页点「下载离线」保存整本书'),
              ),
              const Divider(),
              const _SectionHeader('关于'),
              const ListTile(
                title: Text('爽阅'),
                subtitle: Text(
                  '多源聚合阅读 · Android / Windows\n'
                  '仅用于个人学习与技术研究，请勿用于商业用途。',
                ),
              ),
              ListTile(
                leading: const Icon(Icons.system_update_outlined),
                title: const Text('当前版本 v$kAppVersion'),
                subtitle: Text(_checking ? '正在检查更新…' : '发现新版本时启动会自动提示'),
                trailing: FilledButton.tonal(
                  onPressed: _checking ? null : _checkUpdate,
                  child: const Text('检查更新'),
                ),
              ),
              const ListTile(
                leading: Icon(Icons.person_outline),
                title: Text('Leey'),
                subtitle: Text('邮箱：leey1994@163.com'),
              ),
              ListTile(
                leading: const Icon(Icons.language),
                title: const Text('静态主页'),
                subtitle:
                    const Text('https://leey1994.github.io/shuangyuebook/'),
                trailing: const Icon(Icons.open_in_new, size: 18),
                onTap: () => launchUrl(
                    Uri.parse('https://leey1994.github.io/shuangyuebook/'),
                    mode: LaunchMode.externalApplication),
              ),
              const SizedBox(height: 32),
            ],
          );
        },
      ),
    );
  }
}

/// 桌宠开关 + 当前形态。成长值是现算的，所以这里跟着阅读时长实时变。
class _PetTile extends StatefulWidget {
  const _PetTile();

  @override
  State<_PetTile> createState() => _PetTileState();
}

class _PetTileState extends State<_PetTile> {
  @override
  void initState() {
    super.initState();
    PetStore.I.addListener(_onPet);
  }

  @override
  void dispose() {
    PetStore.I.removeListener(_onPet);
    super.dispose();
  }

  void _onPet() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final pet = PetStore.I;
    final left = pet.toNextStage;
    return SwitchListTile(
      value: pet.enabled,
      onChanged: (v) {
        pet.setEnabled(v);
        pet.emit(PetAction.petToggle);
      },
      title: Row(
        children: [
          SizedBox(
            width: 34,
            height: 34,
            child: CustomPaint(
              painter: PetPainter(
                stage: pet.stage,
                mood: PetMood.calm,
                phase: 0.6,
              ),
            ),
          ),
          const SizedBox(width: 14),
          Text('小墨 · ${pet.stage.label}'),
        ],
      ),
      subtitle: Text(left == 0
          ? '已长成书灵，会一直陪着你'
          : '再读 ${(left * kSecondsPerExp ~/ 60) + 1} 分钟升到下一形态'),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String text;
  const _SectionHeader(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(text,
          style: Theme.of(context)
              .textTheme
              .titleSmall
              ?.copyWith(color: Theme.of(context).colorScheme.primary)),
    );
  }
}
