import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../store.dart';
import '../theme.dart';
import '../update_check.dart';

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
              const _SectionHeader('阅读'),
              SwitchListTile(
                title: const Text('翻页模式'),
                subtitle: Text(p.paginate ? '左右翻页（点两侧翻页，中间呼出菜单）' : '上下滚动'),
                value: p.paginate,
                onChanged: store.setPaginate,
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
                  selected: {p.theme == AppThemes.black
                      ? AppThemes.black
                      : AppThemes.white},
                  onSelectionChanged: (s) => store.setTheme(s.first),
                ),
              ),
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
                subtitle: const Text('https://leey1994.github.io/shuangyuebook/'),
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
