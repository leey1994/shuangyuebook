// 书内搜索（纯函数）的回归测试：命中定位、高亮偏移、限流与空输入。
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_reader/data/book_search.dart';
import 'package:novel_reader/models.dart';

Chapter _ch(int i) => Chapter(title: '第${i + 1}章 标题$i', url: 'u$i');

void main() {
  final chapters = [_ch(0), _ch(1), _ch(2)];
  final texts = <String, List<String>>{
    'u0': [
      '第一段没有',
      '这一段很长很长，他说好的好的就走了，然后又说了一遍好的，剩下的全是无关的填充文字凑长度用的',
      '另一段',
    ],
    'u1': ['好的反义词是坏'],
    'u2': ['这一章空着'],
  };

  List<BookHit> run(String q, {int limit = 100}) => searchBookTexts(
      chapters: chapters, texts: texts, query: q, limit: limit);

  test('正文命中：章/段下标正确，高亮偏移对得上', () {
    final hits = run('好的');
    final h = hits.firstWhere((h) => h.chapterIndex == 0 && h.paraIndex == 1);
    expect(h.snippet.substring(h.matchStart, h.matchStart + h.matchLen), '好的');
    expect(h.snippet, contains('…')); // 段落够长，两侧应有省略号
    // 第二处也在同一段里，但每段只取第一处
    expect(
        hits.where((h) => h.chapterIndex == 0 && h.paraIndex == 1).length, 1);
  });

  test('标题命中也算一处，paraIndex = 0', () {
    final hits = run('标题1');
    expect(hits.first.chapterIndex, 1);
    expect(hits.first.paraIndex, 0);
    expect(hits.first.snippet, contains('标题1'));
  });

  test('大小写不敏感（拉丁字母）', () {
    final hits = searchBookTexts(
      chapters: const [Chapter(title: 't', url: 'a')],
      texts: const {'a': ['Hello World']},
      query: 'hello',
    );
    expect(hits, hasLength(1));
    expect(hits.single.matchLen, 5);
  });

  test('limit 截断', () {
    expect(run('好的', limit: 1), hasLength(1));
  });

  test('空查询 / 无缓存的章：不炸、结果合理', () {
    expect(run('  '), isEmpty);
    // u2 有缓存但没有目标词
    expect(run('不存在的词xyz'), isEmpty);
    // 没有任何缓存时标题命中仍在
    final hits = searchBookTexts(
      chapters: const [Chapter(title: '风起', url: 'zz')],
      texts: const {},
      query: '风起',
    );
    expect(hits, hasLength(1));
    expect(hits.single.paraIndex, 0);
  });

  test('短段落贴边：省略号与偏移不越界', () {
    final hits = searchBookTexts(
      chapters: const [Chapter(title: 't', url: 'a')],
      texts: const {'a': ['好的']},
      query: '好的',
    );
    final h = hits.single;
    expect(h.snippet, '好的');
    expect(h.matchStart, 0);
    expect(h.matchStart + h.matchLen, h.snippet.length);
  });
}
