// 本地书导入：内置文件浏览器 + 常见目录批量扫描。
//
// 为什么不引 file_picker：爽阅要同时跑 Android 和 Windows，系统文件选择器
// 在两端的返回类型与授权模型都不一样（Android 要存储权限、Windows 走对话框）。
// 自己列目录反而更一致，也顺便支持「一键扫描常见目录」。
import 'dart:io';

import 'package:flutter/material.dart';

import '../local/file_scan.dart';
import '../store.dart';
import '../theme.dart';

/// 打开本地书导入页。
Future<void> showLocalImport(BuildContext context) => Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const LocalImportPage()),
    );

/// 本地书导入：目录浏览 → 多选 → 解析入库。
class LocalImportPage extends StatefulWidget {
  const LocalImportPage({super.key});

  @override
  State<LocalImportPage> createState() => _LocalImportPageState();
}

class _LocalImportPageState extends State<LocalImportPage> {
  Directory? _dir;
  List<File> _files = const [];
  List<String> _shortcuts = const [];
  final Set<String> _picked = {};

  bool _loading = true;
  Object? _error;

  /// 导入进度：正在处理第几个 / 共几个。
  int _done = 0;
  int _total = 0;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _shortcuts = defaultScanRoots();
    _open(_initialDir());
  }

  /// 起始目录：Android 用外部存储根，Windows 用用户主目录。
  String _initialDir() {
    final roots = _shortcuts;
    if (roots.isEmpty) return Directory.systemTemp.path;
    return roots.first;
  }

  Future<void> _open(String path) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final d = Directory(path);
      final files = await novelFilesIn(d);
      final dirs = <Directory>[];
      await for (final e in d.list(followLinks: false)) {
        if (e is Directory && !isSkippedDirName(pathFileName(e.path))) {
          dirs.add(e);
        }
      }
      dirs.sort((a, b) => a.path.compareTo(b.path));
      if (!mounted) return;
      setState(() {
        _dir = d;
        _files = files;
        _dirs = dirs;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e;
      });
    }
  }

  List<Directory> _dirs = const [];

  Future<void> _scanShortcuts() async {
    final roots = _shortcuts;
    if (roots.isEmpty) return;
    final all = <File>[];
    for (final r in roots) {
      final d = Directory(r);
      if (!await d.exists()) continue;
      all.addAll(await scanNovelFiles(d, maxDepth: 4));
    }
    if (!mounted) return;
    setState(() {
      _files = all;
      _dirs = const [];
    });
    _snack('扫描到 ${all.length} 本');
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _import() async {
    if (_picked.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _done = 0;
      _total = _picked.length;
    });
    var ok = 0;
    var fail = 0;
    for (final p in _picked) {
      final added = await AppStore.I.importLocalBook(p);
      if (added) {
        ok++;
      } else {
        fail++;
      }
      if (mounted) setState(() => _done++);
    }
    if (!mounted) return;
    setState(() => _busy = false);
    _snack(fail == 0 ? '已导入 $ok 本' : '导入 $ok 本，$fail 本失败或已在书架');
    if (ok > 0) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('导入本地书'),
        actions: [
          if (_picked.isNotEmpty)
            TextButton(
              onPressed: _busy ? null : _import,
              child: _busy ? Text('$_done/$_total') : const Text('导入'),
            ),
        ],
      ),
      body: Column(
        children: [
          _toolbar(),
          const Divider(height: 1),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _toolbar() {
    final current = _dir?.path ?? '';
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  current,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              if (current.isNotEmpty)
                IconButton(
                  tooltip: '上一级',
                  icon: const Icon(Icons.arrow_upward, size: 18),
                  onPressed: () {
                    final p = _dir?.parent;
                    if (p != null) _open(p.path);
                  },
                ),
            ],
          ),
          if (_shortcuts.isNotEmpty)
            SizedBox(
              height: 34,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (final r in _shortcuts)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ActionChip(
                        label: Text(
                          pathFileName(r).isEmpty ? r : pathFileName(r),
                          style: const TextStyle(fontSize: 12),
                        ),
                        onPressed: () => _open(r),
                      ),
                    ),
                  ActionChip(
                    avatar: const Icon(Icons.radar, size: 15),
                    label: const Text('扫描全部', style: TextStyle(fontSize: 12)),
                    onPressed: _scanShortcuts,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('打不开这个目录'),
              const SizedBox(height: 8),
              Text('$_error',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () => _open(_initialDir()),
                child: const Text('回到起始目录'),
              ),
            ],
          ),
        ),
      );
    }
    if (_files.isEmpty && _dirs.isEmpty) {
      return const Center(child: Text('这个目录里没有 txt / epub'));
    }
    return ListView(
      children: [
        if (_files.isEmpty && _dirs.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text('子目录', style: Theme.of(context).textTheme.bodySmall),
          ),
        for (final d in _dirs)
          ListTile(
            leading: const Icon(Icons.folder_outlined),
            title: Text(pathFileName(d.path),
                maxLines: 1, overflow: TextOverflow.ellipsis),
            onTap: () => _open(d.path),
          ),
        if (_files.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                Text('书籍（${_files.length}）',
                    style: Theme.of(context).textTheme.bodySmall),
                const Spacer(),
                TextButton(
                  onPressed: () => setState(() {
                    if (_picked.length == _files.length) {
                      _picked.clear();
                    } else {
                      _picked
                        ..clear()
                        ..addAll(_files.map((f) => f.path));
                    }
                  }),
                  child: Text(_picked.length == _files.length ? '取消全选' : '全选'),
                ),
              ],
            ),
          ),
          for (final f in _files)
            CheckboxListTile(
              dense: true,
              value: _picked.contains(f.path),
              title: Text(pathBaseName(f.path),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                '${pathExtension(f.path).toUpperCase()} · '
                '${_sizeOf(f)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              onChanged: (v) => setState(() {
                if (v ?? false) {
                  _picked.add(f.path);
                } else {
                  _picked.remove(f.path);
                }
              }),
            ),
        ],
      ],
    );
  }

  static String _sizeOf(File f) {
    final len = f.lengthSync();
    if (len < 1024) return '$len B';
    if (len < 1024 * 1024) return '${(len / 1024).toStringAsFixed(0)} KB';
    return '${(len / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}

/// 常见书籍目录（Android 外部存储 / Windows 用户目录）。
///
/// Android 上需要「所有文件访问」权限才能列这些目录；拿不到时列表为空，
/// 用户仍可通过「上一级」从可读目录进入。
List<String> defaultScanRoots() {
  final home = Platform.environment['USERPROFILE'] ??
      Platform.environment['HOME'] ??
      '';
  if (Platform.isWindows) {
    return [
      if (home.isNotEmpty) home,
      ..._windowsBookDirs(home),
    ];
  }
  return const [
    '/storage/emulated/0',
    '/storage/emulated/0/Books',
    '/storage/emulated/0/Download',
    '/storage/emulated/0/Documents',
  ];
}

List<String> _windowsBookDirs(String home) {
  if (home.isEmpty) return const [];
  return [
    '$home\\Books',
    '$home\\Downloads',
    '$home\\Documents',
  ];
}

/// 主题一致性辅助：导入页的强调色取全局主题主色。
Color importAccent(BuildContext context) =>
    AppThemes.material(Theme.of(context).brightness == Brightness.dark
            ? AppThemes.black
            : AppThemes.white)
        .colorScheme
        .primary;
