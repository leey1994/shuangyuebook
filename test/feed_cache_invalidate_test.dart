// FeedCache 前缀作废（invalidatePrefixAsync）回归测试。
//
// 背景：旧实现 invalidatePrefix 是「内存立刻删、磁盘后台删」，调用方紧接着
// 取数时 reach() 会从磁盘把旧值读回来 —— 排行榜下拉刷新「刷了等于没刷」。
// 这里固定该语义：异步版必须等磁盘删完才返回。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shuangyue/feed_cache.dart';
import 'package:shuangyue/models.dart';

/// 把 getApplicationSupportDirectory 指到临时目录（FeedCache 磁盘层落地用）。
class _TmpPathPlatform extends PathProviderPlatform {
  _TmpPathPlatform(this.dir);
  final Directory dir;
  @override
  Future<String?> getApplicationSupportPath() async => dir.path;
}

void main() {
  late Directory tmp;

  /// FeedCache.init 在 support 目录下建 feed_cache/ 子目录存文件。
  Directory cacheDir(Directory base) => Directory('${base.path}/feed_cache');

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('sy_feedcache_');
    PathProviderPlatform.instance = _TmpPathPlatform(tmp);
    FeedCache.clearForTest();
    await FeedCache.init();
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Book makeBook(String title) => Book(
        sourceId: 's1',
        id: 'b',
        url: 'https://x.test/b',
        title: title,
      );

  test('reach 写盘后，await invalidatePrefixAsync 再读是空的', () async {
    const key = 'rank|s1|tab';
    final fresh = await FeedCache.reach<Paged<Book>>(key, () async {
      return Paged(items: [makeBook('旧数据')]);
    });
    expect(fresh.items.first.title, '旧数据');
    // 写盘是异步的：稍等它落地
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(cacheDir(tmp).listSync().whereType<File>(), isNotEmpty);

    // 关键断言：异步作废完成后，再读必须重新 fetch（拿「新数据」）
    await FeedCache.invalidatePrefixAsync('rank');
    final next = await FeedCache.reach<Paged<Book>>(key, () async {
      return Paged(items: [makeBook('新数据')]);
    });
    expect(next.items.first.title, '新数据');
  });

  test('await 完成后磁盘文件确实被删掉', () async {
    const key = 'rank|s1|tab2';
    await FeedCache.reach<Paged<Book>>(key, () async {
      return Paged(items: [makeBook('x')]);
    });
    await Future<void>.delayed(const Duration(milliseconds: 100)); // 等写盘落地
    expect(cacheDir(tmp).listSync().whereType<File>(), isNotEmpty);

    await FeedCache.invalidatePrefixAsync('rank');
    final files = cacheDir(tmp)
        .listSync()
        .whereType<File>()
        .where((f) => f.uri.pathSegments.last.startsWith('rank'))
        .toList();
    expect(files, isEmpty);
  });

  test('旧 void 版：内存立刻失效，磁盘随后被清（最终一致）', () async {
    const key = 'rank|s1|tab3';
    await FeedCache.reach<Paged<Book>>(key, () async {
      return Paged(items: [makeBook('v1')]);
    });
    await Future<void>.delayed(const Duration(milliseconds: 100)); // 等写盘落地
    // ignore: deprecated_member_use_from_same_package
    FeedCache.invalidatePrefix('rank');
    // void 版只保证「内存立刻没了」；磁盘删除是后台异步的，时序不定 ——
    // 这正是刷新必须用异步版的原因（此处不断言旧值会不会被读回）。
    expect(FeedCache.get<Paged<Book>>(key), isNull);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final files = cacheDir(tmp)
        .listSync()
        .whereType<File>()
        .where((f) => f.uri.pathSegments.last.startsWith('rank'))
        .toList();
    expect(files, isEmpty); // 磁盘最终也被清掉
  });

  test('其它前缀不受影响', () async {
    const rankKey = 'rank|a';
    const homeKey = 'home|a';
    await FeedCache.reach<Paged<Book>>(rankKey, () async {
      return Paged(items: [makeBook('r')]);
    });
    await FeedCache.reach<List<Book>>(homeKey, () async => [makeBook('h')]);
    await FeedCache.invalidatePrefixAsync('rank');
    expect(FeedCache.get<Paged<Book>>(rankKey), isNull);
    final home = FeedCache.get<List<Book>>(homeKey);
    expect(home, isNotNull);
    expect(home!.first.title, 'h');
  });

  test('JSON 往返保持 Paged<Book> 字段', () {
    final p = Paged(items: [makeBook('书名')], nextUrl: 'https://x.test/next');
    // FeedCache 磁盘层就是按「items[].toJson() + nextUrl」编码的
    final enc = jsonEncode({
      'items': [for (final e in p.items) e.toJson()],
      'nextUrl': p.nextUrl,
    });
    final dec = jsonDecode(enc) as Map<String, dynamic>;
    final back = Paged<Book>(
      items: [
        for (final e in dec['items'] as List)
          Book.fromJson((e as Map<String, dynamic>)),
      ],
      nextUrl: dec['nextUrl'] as String?,
    );
    expect(back.items.first.title, '书名');
    expect(back.nextUrl, 'https://x.test/next');
  });
}
