import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/sources/local_source.dart';

void main() {
  test('TXT 在分身里解析，正文按章现切', () async {
    final dir = await Directory.systemTemp.createTemp('local_book_test');
    addTearDown(() => dir.delete(recursive: true));

    final f = File('${dir.path}/书.txt')
      ..writeAsStringSync('前言\n第一章 开始\n甲\n乙\n第二章 结束\n丙\n');

    final src = LocalSource(cacheDir: dir);
    final detail = await src.fetchDetail(LocalSource.bookForPath(f.path));

    final titles = detail.chapters.map((c) => c.title).toList();
    expect(titles, contains('第二章 结束'));

    final second = detail.chapters[titles.indexOf('第二章 结束')];
    final ch = await src.fetchChapter(detail, second);
    expect(ch.join('\n'), contains('丙'));

    // 缓存命中：同一路径不再重复解析
    expect(identical(await src.load(f.path), await src.load(f.path)), isTrue);
  });
}
