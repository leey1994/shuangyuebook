// 起点书源联网探针：首页 → 搜索 → 详情目录 → 免费正文 / VIP 章节报错。
//
// 用法：dart run tool/qidian_probe.dart [关键词]
import 'package:shuangyue/sources/qidian.dart';

Future<void> main(List<String> args) async {
  final src = QidianSource();
  final kw = args.isEmpty ? '万相之王' : args.first;

  final found = await src.search(kw);
  print('搜索「$kw」→ ${found.length} 本');
  for (final b in found.take(5)) {
    print('  ${b.title} / ${b.author} / ${b.status} / ${b.id}');
  }
  if (found.isEmpty) return;

  final pick = found.first;
  final d = await src.fetchDetail(pick);
  print('\n详情：${d.book.title} / ${d.book.author} / ${d.book.status} / '
      '${d.chapters.length} 章');
  print('简介：${(d.book.intro ?? '').replaceAll('\n', ' ').trim()}');
  print('封面：${d.book.cover}');
  if (d.chapters.isEmpty) return;

  for (final idx in [0, d.chapters.length ~/ 2, d.chapters.length - 1]) {
    final ch = d.chapters[idx];
    try {
      final ps = await src.fetchChapter(d, ch);
      print('\n[${idx + 1}] ${ch.title} → ${ps.length} 段');
      print('  ${ps.first}');
    } catch (e) {
      print('\n[${idx + 1}] ${ch.title} → $e');
    }
  }

  final home = await src.fetchHome();
  print('\n首页推荐 ${home.length} 本：'
      '${home.take(3).map((b) => b.title).join(' / ')}');
}
