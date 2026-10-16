// 书源文件选择：内置目录浏览器（与本地书导入同一套目录逻辑）。
//
// 为什么不引系统文件选择器：和本地书导入同一个理由（见
// local_import_page.dart 顶部注释）—— Android 要存储权限、Windows 走
// 对话框，返回类型与授权模型两端都不一样；自己列目录两端行为一致，
// 也省得为用户「从文件导入书源」专门加一个插件依赖。
import 'dart:io';

import 'package:flutter/material.dart';

import '../../data/natural_sort.dart';
import '../../local/file_scan.dart';
import '../../platform/native_bridge.dart';

/// 选择书源 JSON / TXT 文件；确认返回文件路径，取消返回 null。
class SourceFilePickPage extends StatefulWidget {
  const SourceFilePickPage({super.key});

  @override
  State<SourceFilePickPage> createState() => _SourceFilePickPageState();
}

class _SourceFilePickPageState extends State<SourceFilePickPage> {
  List<String> _roots = const [];
  Directory? _dir;
  List<Directory> _dirs = const [];
  List<File> _files = const [];
  bool _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _roots = defaultScanRoots();
    _open(_initialDir());
  }

  /// 起始目录：手机上优先 Download（书源文件最常见的落脚点），
  /// 桌面端用用户主目录。
  String _initialDir() {
    if (!Platform.isAndroid) {
      return _roots.isEmpty ? Directory.systemTemp.path : _roots.first;
    }
    for (final r in _roots) {
      if (_name(r).toLowerCase() == 'download') return r;
    }
    return _roots.isEmpty ? '/' : _roots.first;
  }

  /// 跨平台文件名（Windows 路径是反斜杠，统一成 / 再取尾段）。
  static String _name(String path) =>
      pathFileName(path.replaceAll('\\', '/'));

  Future<void> _open(String path) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final d = Directory(path);
      final dirs = <Directory>[];
      final files = <File>[];
      await for (final e in d.list(followLinks: false)) {
        if (e is Directory) {
          if (!isSkippedDirName(_name(e.path))) dirs.add(e);
        } else if (e is File) {
          final name = _name(e.path);
          if (!name.startsWith('.') &&
              kSourceFileExtensions.contains(pathExtension(name))) {
            files.add(e);
          }
        }
      }
      dirs.sort((a, b) => naturalCompare(a.path, b.path));
      files.sort((a, b) => naturalCompare(a.path, b.path));
      if (!mounted) return;
      setState(() {
        _dir = d;
        _dirs = dirs;
        _files = files;
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

  /// 无权限时的兜底：手工输入路径（桌面端复制粘贴也方便）。
  Future<void> _manualPath() async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('输入书源文件路径'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
              hintText: '例如 /storage/emulated/0/Download/书源.json'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('确定')),
        ],
      ),
    );
    controller.dispose();
    if (text == null || text.isEmpty || !mounted) return;
    Navigator.of(context).pop(text);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('选择书源文件'),
        actions: [
          TextButton(
            onPressed: _manualPath,
            child: const Text('手输路径'),
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
          if (_roots.isNotEmpty)
            SizedBox(
              height: 34,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (final r in _roots)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ActionChip(
                        label: Text(
                          _rootLabel(r),
                          style: const TextStyle(fontSize: 12),
                        ),
                        onPressed: () => _open(r),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  static String _rootLabel(String r) {
    final seg = _name(r);
    if (seg.isEmpty) return r;
    // Android 外部存储根 /storage/emulated/0 → 显示成「内部存储」
    if (RegExp(r'^\d+$').hasMatch(seg)) return '内部存储';
    return seg;
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
              const Icon(Icons.folder_off_outlined, size: 40),
              const SizedBox(height: 10),
              const Text('打不开这个目录', style: TextStyle(fontSize: 14)),
              const SizedBox(height: 6),
              Text(
                '$_error',
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11.5),
              ),
              const SizedBox(height: 14),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (Platform.isAndroid)
                    OutlinedButton(
                      onPressed: () =>
                          NativeBridge.requestStoragePermission(),
                      child: const Text('去授权'),
                    ),
                  const SizedBox(width: 10),
                  OutlinedButton(
                    onPressed: () => _open(_dir?.path ?? _initialDir()),
                    child: const Text('重试'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                'Android 11+ 需要在系统设置里给「所有文件访问」权限，\n'
                '否则读不了共享目录（也可用右上角「手输路径」）。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11),
              ),
            ],
          ),
        ),
      );
    }
    if (_dirs.isEmpty && _files.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            '这个目录里没有 .json / .txt 文件\n'
            '换个目录找找（书源文件常见于 Download / Documents）',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13),
          ),
        ),
      );
    }
    return ListView(
      children: [
        for (final d in _dirs)
          ListTile(
            leading: const Icon(Icons.folder_outlined, size: 22),
            title: Text(_name(d.path),
                maxLines: 1, overflow: TextOverflow.ellipsis),
            onTap: () => _open(d.path),
          ),
        for (final f in _files)
          ListTile(
            leading: const Icon(Icons.description_outlined, size: 22),
            title: Text(_name(f.path),
                maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: const Icon(Icons.chevron_right, size: 18),
            onTap: () => Navigator.of(context).pop(f.path),
          ),
      ],
    );
  }
}
