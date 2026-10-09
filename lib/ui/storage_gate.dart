// 存储权限引导页（Android 11+ 的「所有文件访问」）。
//
// 为什么不用运行时权限弹窗：Android 11 起遍历用户书库必须走
// Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION 这个授权页，
// 系统不给弹窗，只能自己解释清楚再把用户送过去。
//
// Windows / iOS 直接跳过本页 —— 它们没有这个限制。
import 'dart:io';

import 'package:flutter/material.dart';

import '../platform/native_bridge.dart';
import '../theme.dart';

/// 是否需要存储权限页。
///
/// Android 10 及以下用普通运行时权限（原生侧自动处理），无需引导页；
/// Android 11+ 才需要「所有文件访问」。
bool get needsStorageGate => Platform.isAndroid;

/// 权限是否已就绪（非 Android 恒为 true）。
Future<bool> storageReady() => NativeBridge.hasStoragePermission();

/// 在首页之前插入权限门：未授权时先拦一道，授权后继续。
class StorageGate extends StatefulWidget {
  const StorageGate({super.key, required this.child});

  final Widget child;

  @override
  State<StorageGate> createState() => _StorageGateState();
}

class _StorageGateState extends State<StorageGate> {
  bool _checking = true;
  bool _granted = true;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final ok = !needsStorageGate || await storageReady();
    if (!mounted) return;
    setState(() {
      _granted = ok;
      _checking = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    // 检查中先显示空白，避免闪一下「无权限」再跳回首页
    if (_checking) {
      return const ColoredBox(
        color: Colors.white,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_granted) return widget.child;
    return _StoragePermissionPage(onGranted: _check);
  }
}

class _StoragePermissionPage extends StatelessWidget {
  const _StoragePermissionPage({required this.onGranted});

  final Future<void> Function() onGranted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: AppThemes.scaffold(
          theme.brightness == Brightness.dark ? AppThemes.black : AppThemes.white),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: ListView(
              padding: const EdgeInsets.all(28),
              shrinkWrap: true,
              children: [
                Icon(Icons.folder_open,
                    size: 56, color: theme.colorScheme.primary),
                const SizedBox(height: 20),
                Text('需要文件访问权限',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleLarge),
                const SizedBox(height: 12),
                Text(
                  '导入本地书需要读取你手机里的 TXT / EPUB 文件。\n\n'
                  '接下来会跳转到系统设置，打开「所有文件访问」开关后返回即可。'
                  '\n\n不授权也能用 —— 你仍然可以在「发现」里看在线书。',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 28),
                FilledButton(
                  onPressed: () async {
                    await NativeBridge.requestStoragePermission();
                    // 从系统设置返回时重新查一次
                    await onGranted();
                  },
                  child: const Text('去授权'),
                ),
                const SizedBox(height: 10),
                TextButton(
                  onPressed: () async {
                    // 用户选择跳过：本次会话不再拦，但下次冷启动仍会问
                    await onGranted();
                  },
                  child: const Text('暂不授权'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
