// 封面磁盘缓存（CoverCache）容量治理回归测试。
//
// 背景：covers/ 目录原来只写不删，设置页的「已缓存」也只算章节缓存，
// 长期使用磁盘只涨不降。这里固定三件事：统计包含封面、超限按最旧淘汰、
// 清除缓存真的把封面文件删掉。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shuangyue/widgets.dart';

class _TmpPathPlatform extends PathProviderPlatform {
  _TmpPathPlatform(this.dir);
  final Directory dir;
  @override
  Future<String?> getApplicationSupportPath() async => dir.path;
}

void main() {
  late Directory tmp;
  late Directory covers;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('sy_covers_');
    PathProviderPlatform.instance = _TmpPathPlatform(tmp);
    CoverCache.resetForTest();
    covers = Directory('${tmp.path}/covers')..createSync(recursive: true);
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  void writeCover(String name, int bytes, DateTime mtime) {
    final f = File('${covers.path}/$name')
      ..writeAsBytesSync(List.filled(bytes, 7));
    f.setLastModifiedSync(mtime);
  }

  test('size 统计 covers 目录；trim 先淘汰最旧的', () async {
    final now = DateTime.now();
    writeCover('old.jpg', 1000, now.subtract(const Duration(days: 3)));
    writeCover('mid.jpg', 1000, now.subtract(const Duration(days: 2)));
    writeCover('new.jpg', 1000, now.subtract(const Duration(days: 1)));

    expect(await CoverCache.size(), 3000);

    // 上限 2500 → 清到 80%（2000）：删掉最旧的 1 张后 2000 ≤ 2000，停手。
    await CoverCache.trimForTest(2500);
    expect(File('${covers.path}/old.jpg').existsSync(), isFalse);
    expect(File('${covers.path}/mid.jpg').existsSync(), isTrue);
    expect(File('${covers.path}/new.jpg').existsSync(), isTrue);
    expect(await CoverCache.size(), 2000);
  });

  test('clear 删掉全部封面文件', () async {
    writeCover('a.jpg', 500, DateTime.now());
    writeCover('b.jpg', 500, DateTime.now());
    expect(await CoverCache.size(), 1000);

    await CoverCache.clear();
    expect(covers.listSync().whereType<File>(), isEmpty);
    expect(await CoverCache.size(), 0);
  });
}
