import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

/// 应用版本：构建时由 --dart-define=APP_VERSION 注入（取自 pubspec.yaml 的 version）。
const String kAppVersion =
    String.fromEnvironment('APP_VERSION', defaultValue: '1.0.2');

const String _repo = 'leey1994/shuangyuebook';
const MethodChannel _installChannel =
    MethodChannel('dev.reader.novel_reader/update');

/// 版本号比较：a > b → 1，相等 → 0，a < b → -1。
/// 去掉前导 v/V 与 +构建号后按 '.' 分段做数值比较（0.1.10 > 0.1.9）。
int compareVersion(String a, String b) {
  List<int> parts(String s) => s
      .replaceFirst(RegExp(r'^[vV]'), '')
      .split('+')
      .first
      .split('.')
      .map((e) => int.tryParse(e.trim()) ?? 0)
      .toList();
  final pa = parts(a), pb = parts(b);
  final n = pa.length > pb.length ? pa.length : pb.length;
  for (var i = 0; i < n; i++) {
    final x = i < pa.length ? pa[i] : 0;
    final y = i < pb.length ? pb[i] : 0;
    if (x != y) return x > y ? 1 : -1;
  }
  return 0;
}

/// 启动时静默检查 GitHub Release：发现比当前更新的版本则弹窗提示，
/// 公告内容即该 Release 的版本说明（body）。网络失败/无 Release 静默跳过。
/// [manual] 为 true（设置页手动检查）时给出结果反馈：已是最新 / 检查失败。
///
/// 更新动作全自动：
/// - 安卓：下载 APK → 系统安装器安装
/// - Windows：下载 zip → 解压 → 辅助脚本等待本进程退出后替换运行目录 → 重启
class UpdateChecker {
  UpdateChecker._();

  static Future<void> check(BuildContext context, {bool manual = false}) async {
    try {
      final r = await http
          .get(
            Uri.parse('https://api.github.com/repos/$_repo/releases/latest'),
            headers: {
              'User-Agent': 'shuangyuebook-updater',
              'Accept': 'application/vnd.github+json',
            },
          )
          .timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
      final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
      final tag = (j['tag_name'] as String? ?? '').trim();
      if (tag.isEmpty || compareVersion(tag, kAppVersion) <= 0) {
        if (manual && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('已是最新版本（当前 v$kAppVersion）'),
            duration: Duration(seconds: 2),
          ));
        }
        return;
      }
      if (!context.mounted) return;

      final notes = (j['body'] as String? ?? '').trim();
      final htmlUrl = j['html_url'] as String? ??
          'https://github.com/$_repo/releases/latest';
      String? apkUrl;
      String? zipUrl;
      for (final a in (j['assets'] as List? ?? [])) {
        final m = a as Map;
        final name = (m['name'] as String? ?? '').toLowerCase();
        final url = m['browser_download_url'] as String?;
        if (url == null) continue;
        if (name.endsWith('.apk')) {
          apkUrl ??= url;
        } else if (name.endsWith('.zip') && name.contains('windows')) {
          zipUrl ??= url;
        }
      }
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => _UpdateDialog(
            tag: tag, notes: notes, htmlUrl: htmlUrl, apkUrl: apkUrl, zipUrl: zipUrl),
      );
    } catch (_) {
      // 网络异常 / API 限流 / 无 release：静默跳过，不影响正常使用
      if (manual && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('检查更新失败，请检查网络后重试'),
          duration: Duration(seconds: 2),
        ));
      }
    }
  }
}

class _UpdateDialog extends StatefulWidget {
  final String tag;
  final String notes;
  final String htmlUrl;
  final String? apkUrl; // 安卓安装包资产
  final String? zipUrl; // Windows 压缩包资产
  const _UpdateDialog({
    required this.tag,
    required this.notes,
    required this.htmlUrl,
    required this.apkUrl,
    required this.zipUrl,
  });

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  http.Client? _client;
  bool _busy = false;
  double? _pct; // null = 不确定进度（下载阶段才有百分比）
  String? _phase; // 下载完成后的阶段文案（解压/重启）
  String? _error;

  @override
  void dispose() {
    _client?.close(); // 下载中途关闭对话框则中断连接
    super.dispose();
  }

  Future<void> _update() async {
    final isAndroid = Platform.isAndroid;
    final url = isAndroid ? widget.apkUrl : widget.zipUrl;
    // 缺少对应资产：退回打开 Release 页面手动下载
    if (url == null) {
      await launchUrl(Uri.parse(widget.htmlUrl),
          mode: LaunchMode.externalApplication);
      if (mounted) Navigator.of(context).pop();
      return;
    }
    setState(() {
      _busy = true;
      _pct = null;
      _phase = null;
      _error = null;
    });
    try {
      final dir = await getTemporaryDirectory();
      final target = File(
          '${dir.path}/${isAndroid ? 'update.apk' : 'shuangyue_update.zip'}');

      // ---- 流式下载（边下边写盘，显示百分比）----
      final client = http.Client();
      _client = client;
      final resp =
          await client.send(http.Request('GET', Uri.parse(url)))
              .timeout(const Duration(seconds: 30));
      final total = resp.contentLength ?? 0;
      final sink = target.openWrite();
      var got = 0;
      var lastPct = -1.0;
      await for (final chunk in resp.stream) {
        sink.add(chunk);
        got += chunk.length;
        if (total > 0 && mounted) {
          final p = (got / total * 100).floorToDouble();
          if (p != lastPct) {
            lastPct = p;
            setState(() => _pct = p / 100);
          }
        }
      }
      await sink.close();
      if (!mounted) return;

      if (isAndroid) {
        // ---- 安卓：拉起系统安装器（FileProvider 由原生侧包装）----
        await _installChannel.invokeMethod('installApk', {'path': target.path});
        if (mounted) Navigator.of(context).pop();
        return;
      }

      // ---- Windows：解压 → 自替换脚本 → 退出重启 ----
      setState(() => _phase = '正在解压…');
      final stage = Directory('${dir.path}/shuangyue_update');
      if (stage.existsSync()) stage.deleteSync(recursive: true);
      stage.createSync(recursive: true);
      var r = await Process.run(
          'tar', ['-xf', target.path, '-C', stage.path]);
      if (r.exitCode != 0) {
        // 旧系统无 tar 时退回 PowerShell
        r = await Process.run('powershell', [
          '-NoProfile',
          '-Command',
          "Expand-Archive -Force -Path '${target.path}' -Destination '${stage.path}'",
        ]);
        if (r.exitCode != 0) throw Exception('解压失败: ${r.stderr}');
      }
      if (!mounted) return;
      setState(() => _phase = '正在重启应用…');
      _spawnUpdater(stage, target);
      // 给脚本一点启动时间，然后退出本进程交给它替换文件
      await Future.delayed(const Duration(milliseconds: 800));
      exit(0);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _pct = null;
        _phase = null;
        _error = '更新失败：$e';
      });
    }
  }

  /// 写一个等待旧 exe 退出的批处理：替换运行目录 → 启动新版本 → 自删。
  /// 探测方式：运行中的 exe 不可写，copy 成功即代表旧进程已退出。
  void _spawnUpdater(Directory stage, File zip) {
    final exe = Platform.resolvedExecutable;
    final exeDir = File(exe).parent.path;
    final exeName = exe.substring(exe.lastIndexOf(Platform.pathSeparator) + 1);
    if (!File('${stage.path}${Platform.pathSeparator}$exeName').existsSync()) {
      throw Exception('解压不完整：缺少 $exeName');
    }
    final bat =
        File('${zip.parent.path}${Platform.pathSeparator}update_helper.bat');
    const nl = '\r\n';
    final lines = [
      '@echo off',
      'setlocal',
      'rem shuangyue self-update: wait until old exe is gone, replace, restart',
      ':waitexe',
      'copy /Y "$stage\\$exeName" "$exeDir\\$exeName" >nul 2>&1',
      'if errorlevel 1 (ping -n 2 127.0.0.1 >nul & goto waitexe)',
      'xcopy /E /Y /I "$stage\\*" "$exeDir\\" >nul',
      'if exist "$stage" rmdir /S /Q "$stage"',
      'if exist "$zip" del /Q "$zip"',
      'start "" "$exe"',
      '(goto) 2>nul & del "%~f0"',
    ];
    // SystemEncoding = 本机 ANSI 代码页，保证含中文/空格的路径写进 bat 不乱码
    bat.writeAsStringSync(lines.join(nl), encoding: const SystemEncoding());
    Process.start('cmd.exe', ['/c', bat.path],
        mode: ProcessStartMode.detached);
  }

  @override
  Widget build(BuildContext context) {
    final busyText = _phase ??
        (_pct == null ? '正在下载…' : '正在下载 ${(_pct! * 100).toStringAsFixed(0)}%');
    return AlertDialog(
      title: Text('发现新版本 ${widget.tag}'),
      content: SizedBox(
        width: 420,
        child: _busy
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LinearProgressIndicator(value: _phase != null ? 1 : _pct),
                  const SizedBox(height: 12),
                  Text(busyText),
                ],
              )
            : _error != null
                ? Text(_error!, style: const TextStyle(color: Colors.red))
                : ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 320),
                    child: SingleChildScrollView(
                      child: Text(
                        widget.notes.isEmpty
                            ? '（该版本未填写发布说明）'
                            : widget.notes,
                      ),
                    ),
                  ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('稍后'),
        ),
        FilledButton(
          onPressed: _busy ? null : _update,
          child: const Text('立即更新'),
        ),
      ],
    );
  }
}
