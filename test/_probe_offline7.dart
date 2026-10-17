// 离线验证 #7：话本目录选择器具体化（书页 vs 目录页）+ 唐三尾巴净化复查。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/legado/analyze_rule.dart';
import 'package:shuangyue/legado/online_book_service.dart';

const dir = 'C:/Users/leey1/AppData/Local/Temp/opencode/src_dump';
String read(String n) => File('$dir/$n').readAsStringSync();

void main() {
  test('offline-7 ihuaben selector', () {
    for (final f in ['ihuaben_toc.html', 'ihuaben_book.html']) {
      final e = AnalyzeRule(read(f), baseUrl: 'http://www.ihuaben.com');
      print('$f：'
          ' chapter-row=${e.getRawList('class.chapter-row').length}'
          ' wrap>row=${e.getRawList('class.hb-list-chapters-wrap@class.chapter-row').length}');
    }
    // 唐三尾巴（URL 行过滤后）
    final xt = AnalyzeRule(read('mini_ch_xtang.html'),
        baseUrl: 'http://www.xtangsanshu.com');
    final t = OnlineBookService.cleanChapterText(
        xt.getStrings('id.content@html').join('\n'));
    print('唐三 清洗后 len=${t.length} 尾部30: ${t.substring(t.length - 30)}');
    print('尾部仍是 URL? ${RegExp(r'^https?://\S+$').hasMatch(t.split('\n').last)}');
  });
}
