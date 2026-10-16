// 从网络获取书源合集：下载 JSON → 解析为 BookSource 列表。
//
// 导入仍走 SourceStore.importFromText（统一去重/持久化），本文件只负责
// 「拿下来 + 解析出来」，供「网络获取并测试」页面使用。
import 'dart:convert';

import 'http_client.dart';
import 'models.dart';

/// 预设合集（可编辑；也可以在页面里填任意订阅地址）。
class SourceCollectionPreset {
  const SourceCollectionPreset(this.name, this.url);

  final String name;
  final String url;
}

const List<SourceCollectionPreset> kSourceCollectionPresets = [
  SourceCollectionPreset(
    'yiove 书源库 · 1-80',
    'https://shuyuan-api.yiove.com/import/book-sources/1-80',
  ),
  SourceCollectionPreset(
    '大辉狼精选集 good.json',
    'https://cdn.jsdelivr.net/gh/shidahuilang/shuyuan-bak@main/good.json',
  ),
];

/// 下载并解析书源合集（重复 bookSourceUrl 只保留第一条）。
Future<List<BookSource>> fetchSourceCollection(String url) async {
  final u = url.trim();
  if (u.isEmpty) throw Exception('地址为空');
  final resp = await SourceHttpClient().get(
    u,
    timeout: const Duration(seconds: 45),
    retries: 1,
  );
  if (!resp.ok) throw Exception('下载失败：HTTP ${resp.statusCode}');
  return parseSourceCollection(resp.body);
}

/// 解析合集文本：JSON 数组 / `{"sources":[…]}` / 多行单条 JSON 均可。
List<BookSource> parseSourceCollection(String text) {
  final out = <BookSource>[];
  final seen = <String>{};

  void add(dynamic raw) {
    final list = raw is List ? raw : [raw];
    for (final e in list) {
      if (e is! Map) continue;
      try {
        final bs = BookSource.fromJson(e);
        if (bs.bookSourceUrl.trim().isEmpty) continue;
        if (!seen.add(bs.bookSourceUrl)) continue;
        out.add(bs);
      } catch (_) {
        // 单条坏数据不拖累整批
      }
    }
  }

  final trimmed = text.trim();
  try {
    final decoded = jsonDecode(trimmed);
    if (decoded is List) {
      add(decoded);
      return out;
    }
    if (decoded is Map) {
      final inner = decoded['sources'] ?? decoded['items'] ?? decoded['data'];
      add(inner ?? decoded);
      return out;
    }
  } catch (_) {
    // 不是整段合法 JSON → 按行兜底
  }
  for (final line in const LineSplitter().convert(trimmed)) {
    final l = line.trim();
    if (l.isEmpty) continue;
    try {
      add(jsonDecode(l));
    } catch (_) {}
  }
  return out;
}
