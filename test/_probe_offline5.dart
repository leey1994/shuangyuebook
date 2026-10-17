// 离线验证 #5：唐三正文规则为何取 0（存盘页上直接跑 content 规则）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/legado/analyze_rule.dart';

const dir = 'C:/Users/leey1/AppData/Local/Temp/opencode/src_dump';
String read(String n) => File('$dir/$n').readAsStringSync();

void main() {
  test('offline-5 content rules', () {
    final xt = AnalyzeRule(read('mini_ch_xtang.html'),
        baseUrl: 'http://www.xtangsanshu.com');
    print('xt #content 元素数: '
        '${xt.getRawList('id.content').length} / ${xt.getRawList('#content').length}');
    for (final r in [
      'id.content@html',
      'id.content@text',
      'id.content@textNodes',
      'id.content',
      'class.showtxt@html',
      'class.showtxt@textNodes',
    ]) {
      final v = xt.getStrings(r);
      print('xt "$r" -> ${v.length} 项, 长度 ${v.map((s) => s.length).toList()}');
    }
  });
}
