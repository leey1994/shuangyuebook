// 番茄书源联网探针：首页推荐 → 详情目录 → 正文，打印前几段验证可读。
//
// 用法：dart run tool/fanqie_probe.dart [书名关键词]
// 不碰 Flutter 运行时，纯 Dart（http + html），可直接命令行跑。
import 'package:shuangyue/sources/fanqie.dart';

Future<void> main(List<String> args) async {
  final src = FanqieSource();

  final home = await src.fetchHome();
  print('首页推荐 ${home.length} 本');
  for (final b in home.take(5)) {
    print('  ${b.title} / ${b.author} / ${b.id}');
  }
  if (home.isEmpty) return;

  final pick = home.first;
  final detail = await src.fetchDetail(pick);
  print('\n详情：${detail.book.title} / ${detail.book.author} / '
      '${detail.book.status} / ${detail.chapters.length} 章');
  print('简介：${(detail.book.intro ?? '').replaceAll('\n', ' ').trim()}');
  if (detail.chapters.isEmpty) return;

  final ch = detail.chapters.first;
  print('\n第 1 章：${ch.title}');
  final paras = await src.fetchChapter(detail, ch);
  print('段落 ${paras.length}');
  for (final p in paras.take(5)) {
    print('  $p');
  }

  // 中段再抽一章，确认长目录和正文稳定（不只第一章能读）。
  if (detail.chapters.length > 20) {
    final mid = detail.chapters[detail.chapters.length ~/ 2];
    final midParas = await src.fetchChapter(detail, mid);
    print('\n中段章节：${mid.title}（${midParas.length} 段）');
    print('  ${midParas.first}');
  }

  try {
    await src.search('斗破');
    print('\n搜索结果：意外成功（搜索限制已解除？）');
  } catch (e) {
    print('\n搜索：$e');
  }
}
