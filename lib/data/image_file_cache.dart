// 漫画图片字节的磁盘缓存：让「图片书源」真的能离线看。
//
// 章节缓存只存图片 URL 列表，若字节每次都联网拉，批量下载完照样断网即白屏
//（对齐 legado 图片源：下载 = 图片落本地，离线可读）。
// 目录放在 AppStore 的 cache 根下 —— clearCache() 会连它一起清掉。
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

class ImageFileCache {
  ImageFileCache._();

  static Directory? _dir;

  /// 仅测试用：重置进程内目录缓存（换 mock 平台路径后重新解析）。
  @visibleForTesting
  static void debugReset() => _dir = null;

  static Future<Directory?> _ensure() async {
    final d = _dir;
    if (d != null) return d;
    try {
      final base = await getApplicationSupportDirectory();
      final dir = Directory('${base.path}/novel_cache/image_cache');
      if (!await dir.exists()) await dir.create(recursive: true);
      _dir = dir;
      return dir;
    } catch (_) {
      return null; // 目录拿不到：降级为纯网络，不阻断阅读
    }
  }

  /// 文件名 = URL 的 sha256（避免中文 / 查询串 / 超长路径），保留扩展名不用管。
  static String fileName(String url) =>
      '${sha256.convert(utf8.encode(url)).toString()}.img';

  static Future<Uint8List?> read(String url) async {
    final d = await _ensure();
    if (d == null) return null;
    try {
      final f = File('${d.path}/${fileName(url)}');
      if (!await f.exists()) return null;
      final bytes = await f.readAsBytes();
      return bytes.isEmpty ? null : Uint8List.fromList(bytes);
    } catch (_) {
      return null;
    }
  }

  static Future<void> write(String url, Uint8List bytes) async {
    if (bytes.isEmpty) return;
    final d = await _ensure();
    if (d == null) return;
    try {
      await File('${d.path}/${fileName(url)}')
          .writeAsBytes(bytes, flush: false);
    } catch (_) {}
  }

  static Future<bool> has(String url) async => (await read(url)) != null;

  /// 已缓存图片占用字节数（设置页展示 / 清理）。
  static Future<int> size() async {
    final d = await _ensure();
    if (d == null || !await d.exists()) return 0;
    var n = 0;
    try {
      await for (final f in d.list()) {
        if (f is File) n += await f.length();
      }
    } catch (_) {}
    return n;
  }
}
