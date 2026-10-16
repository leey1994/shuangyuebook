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

/// 全部预设于 2026-10-16 在移动网络（手机端）实测直连可下：最快 0.3s、
/// 最慢 5.6s、最大 2.7MB。原「大辉狼精选集」已移除：good.json 达 16MB，
/// 唯一镜像 jsdelivr 在境内被拦（秒断），换什么线路都撑不过下载超时。
const List<SourceCollectionPreset> kSourceCollectionPresets = [
  SourceCollectionPreset(
    'yiove 书源库 · 1-80',
    'https://shuyuan-api.yiove.com/import/book-sources/1-80',
  ),
  SourceCollectionPreset(
    'yiove 稳定合集',
    'https://shuyuan-api.yiove.com/import/book-source-collection/'
        'eaedccd4-1252-4962-a565-c7a342f95f90',
  ),
  SourceCollectionPreset(
    'Xiu 精品书源',
    'https://cdn.jsdmirror.com/gh/XIU2/Yuedu/shuyuan',
  ),
  SourceCollectionPreset(
    '一程书源合集',
    'https://cdn.mgz.la/shuyuan/'
        '250701%E6%9C%80%E5%90%8E%E4%B8%80%E7%89%88%E4%B8%80%E7%A8%8B.json',
  ),
  SourceCollectionPreset(
    '破冰书源',
    'https://legado.miaogongzi.org/'
        '%E9%98%85%E8%AF%BB%E4%B9%A6%E6%BA%90/sy.json',
  ),
  SourceCollectionPreset(
    '关耳女频',
    'https://cdn.mgz.la/shuyuan/guaner25.02.03.txt',
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
