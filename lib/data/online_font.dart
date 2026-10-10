// 在线正文字体：霞鹜文楷。
//
// 为什么改成在线：随包分发要多背 13.5MB，APK 直接从 16MB 涨到 30MB。
// 绝大多数用户其实用系统字体就够，所以把字体从安装包里拿掉，改成
// 「用户主动点了才下载」。
//
// 流程：点击 → 询问是否下载（告知体积与联网）→ 下载到 App 私有目录 →
// 用 [FontLoader] 注册为字体族 → 立即生效并持久化。
// 下载失败不阻塞阅读，继续用系统字体。
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../platform/native_bridge.dart';

/// 在线字体下载地址，按顺序回退。
///
/// 1. 本项目自己的 Release 资产 —— 想完全自控就往这个 tag 挂一个同名文件；
/// 2. jsDelivr 的 GitHub 镜像 —— 开箱即用，不依赖自己有没有挂资产；
/// 3. GitHub raw —— 兜底。
///
/// 换字体只需改这个列表。
const List<String> kOnlineFontUrls = [
  'https://github.com/leey1994/shuangyuebook/releases/download/fonts/'
      'LXGWWenKai-Lite-Regular.ttf',
  'https://cdn.jsdelivr.net/gh/akira399/sakura-read@main/assets/fonts/'
      'LXGWWenKai-Regular.ttf',
  'https://raw.githubusercontent.com/akira399/sakura-read/main/assets/fonts/'
      'LXGWWenKai-Regular.ttf',
];

/// 下载后注册给 Flutter 使用的字体族名（不能和系统族重名）。
const String kOnlineFontFamily = 'LXGWWenKaiOnline';

/// 字体文件的展示名（设置项里显示）。
const String kOnlineFontLabel = '霞鹜文楷';

/// 字体下载与注册。
class OnlineFont {
  OnlineFont._();

  static final OnlineFont instance = OnlineFont._();

  bool _loaded = false;
  bool _loading = false;
  String? _error;

  /// 字体是否已经可用（本次进程内）。
  bool get available => _loaded;

  bool get loading => _loading;

  String? get error => _error;

  /// 缓存路径；解析不出目录时返回 null。
  Future<File?> _file() async {
    final dirs = await NativeBridge.appDirs();
    return File('${dirs.files}/fonts/LXGWWenKai-Lite-Regular.ttf');
  }

  Future<bool> restore() async {
    if (_loaded) return true;
    final f = await _file();
    if (f == null || !await f.exists()) return false;
    return _register(f);
  }

  /// 下载并注册。返回是否成功。
  Future<bool> download(
      {void Function(int received, int total)? onProgress}) async {
    if (_loaded) return true;
    if (_loading) return false;
    _loading = true;
    _error = null;
    try {
      final f = await _file();
      if (f == null) {
        _error = '无法确定缓存目录';
        return false;
      }
      await f.parent.create(recursive: true);

      // 逐条线路回退：任何一条拿到「足够大的东西」就收工
      String? lastErr;
      for (final url in kOnlineFontUrls) {
        if (await _fetch(url, f, onProgress: onProgress)) {
          return await _register(f);
        }
        lastErr = _error;
        // 某条线路下到半截垃圾，先清掉再试下一条
        try {
          if (await f.exists()) await f.delete();
        } catch (_) {
          // 清理失败不影响继续尝试
        }
      }
      _error = lastErr ?? '下载失败';
      return false;
    } catch (e) {
      _error = '下载失败：$e';
      return false;
    } finally {
      _loading = false;
    }
  }

  /// 单条线路下载。[target] 写满即返回 true；任何异常返回 false 由上层换线。
  Future<bool> _fetch(
    String url,
    File target, {
    void Function(int received, int total)? onProgress,
  }) async {
    HttpClientResponse? resp;
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url));
      resp = await req.close().timeout(const Duration(seconds: 30));
      if (resp.statusCode != HttpStatus.ok) {
        _error = '下载失败（HTTP ${resp.statusCode}）';
        return false;
      }
      final total = resp.contentLength;
      final sink = target.openWrite();
      var got = 0;
      await for (final chunk in resp) {
        sink.add(chunk);
        got += chunk.length;
        onProgress?.call(got, total > 0 ? total : got);
      }
      await sink.close();
      // 下到的不是字体（比如 HTML 错误页）就别注册，免得正文变成方块
      if (got < 1024 * 512) {
        _error = '下载内容异常（${(got / 1024).round()} KB）';
        return false;
      }
      return true;
    } catch (e) {
      _error = '下载失败：$e';
      return false;
    } finally {
      client.close(force: true);
    }
  }

  /// 删掉缓存（设置页可手动清理）。
  Future<void> removeCache() async {
    final f = await _file();
    if (f != null && await f.exists()) {
      try {
        await f.delete();
      } catch (_) {
        // 删不掉不影响使用
      }
    }
  }

  /// 已占用的磁盘字节数；没有则 0。
  Future<int> cacheSize() async {
    final f = await _file();
    if (f == null || !await f.exists()) return 0;
    return f.length();
  }

  Future<bool> _register(File f) async {
    try {
      final bytes = await f.readAsBytes();
      final loader = FontLoader(kOnlineFontFamily)
        ..addFont(Future.value(ByteData.view(bytes.buffer)));
      await loader.load();
      _loaded = true;
      _error = null;
      return true;
    } catch (e) {
      _error = '字体加载失败：$e';
      return false;
    }
  }

  /// 供 UI 判断当前选中的字体是否需要走在线流程。
  static bool needsOnline(String? family) =>
      family == kOnlineFontFamily || family == 'LXGWWenKai';
}
