// 原生书源探针：对 lib/sources/ 的 4 个新适配器逐个跑「搜索 → 详情/目录 →
// 首章正文」，输出每一步的结果（真实网络，用于发版前抽查站点改版）。
//
// 运行（全量）：
//   flutter test tool/native_src_probe_test.dart -r expanded
// 只跑某几个：
//   flutter test tool/native_src_probe_test.dart -r expanded --dart-define=ONLY=gdbzkz,douyinxs
// 换关键词：
//   flutter test tool/native_src_probe_test.dart -r expanded --dart-define=Q=剑来
// ignore_for_file: avoid_print
import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/sources/douyinxs.dart';
import 'package:shuangyue/sources/gdbzkz.dart';
import 'package:shuangyue/sources/sanyt.dart';
import 'package:shuangyue/sources/source.dart';
import 'package:shuangyue/sources/sudugu_cc.dart';

void main() {
  test('probe new native sources', () async {
    final all = <NovelSource>[
      GdbzkzSource(),
      DouyinxsSource(),
      SuduguCcSource(),
      SanytSource(),
    ];
    const only = String.fromEnvironment('ONLY');
    final picks = only.isEmpty
        ? all
        : all.where((s) => only.split(',').contains(s.id)).toList();

    const query = String.fromEnvironment('Q', defaultValue: '斗破苍穹');

    var searchOk = 0, tocOk = 0, textOk = 0;
    for (final s in picks) {
      final tag = '【${s.name}】';
      final sw = Stopwatch()..start();
      try {
        final books = await s.search(query);
        if (books.isEmpty) {
          print('$tag 搜索 0 结果 (${sw.elapsedMilliseconds}ms)');
          continue;
        }
        searchOk++;
        final b = books.first;
        print('$tag 搜索 OK x${books.length} (${sw.elapsedMilliseconds}ms) '
            '例「${b.title}」${b.author ?? ''} ${b.url}');
        final detail = await s.fetchDetail(b);
        if (detail.chapters.isEmpty) {
          print('$tag 目录 X 0 章');
          continue;
        }
        tocOk++;
        final c = detail.chapters.first;
        print('$tag 目录 OK x${detail.chapters.length} 首章「${c.title}」');
        final text = await s.fetchChapter(detail, c);
        final flat = text.join().replaceAll(RegExp(r'\s+'), '');
        // 乱码嗅探：UTF-8 字节被按 GBK 解出来的典型字（伪速读谷栽过）
        final bad = RegExp(r'[銆绗鈥锛鐨鏄鐞鎾]').allMatches(flat).length;
        if (bad >= 3) {
          print('$tag 正文 X 疑似乱码（$bad 处）：${flat.substring(0, 50)}');
          continue;
        }
        if (flat.length < 80) {
          print('$tag 正文 X 仅 ${flat.length} 字');
          continue;
        }
        textOk++;
        print('$tag 正文 OK ${flat.length} 字：${flat.substring(0, 50)}');
      } catch (e) {
        print('$tag 异常 (${sw.elapsedMilliseconds}ms): $e');
      }
    }
    print('--- 合计 ${picks.length} 源：搜索 $searchOk · 目录 $tocOk · 正文 $textOk');
  }, timeout: const Timeout(Duration(minutes: 15)));
}
