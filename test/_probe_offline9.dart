// 离线验证 #9：晋江 noveltext 正文规则 + 清洗质量。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/legado/analyze_rule.dart';
import 'package:shuangyue/legado/online_book_service.dart';

const dir = 'C:/Users/leey1/AppData/Local/Temp/opencode/src_dump';

void main() {
  test('offline-9 jjwxc noveltext', () {
    final t = File('$dir/jjwxc_ch_app.html').readAsStringSync();
    final e = AnalyzeRule(t, baseUrl: 'https://www.jjwxc.net');
    for (final r in [
      'class.noveltext@textNodes',
      'class.noveltext@text',
      'class.novelbody@textNodes',
    ]) {
      final v = e.getStrings(r);
      final cleaned = OnlineBookService.cleanChapterText(v.join('\n'));
      print('jjwxc "$r" -> ${v.length} 项 / 清洗后 ${cleaned.length} 字');
      if (cleaned.isNotEmpty) {
        final lines = cleaned.split('\n');
        print('   首3行: ${lines.take(3).map((s) => s.length > 40 ? s.substring(0, 40) : s).toList()}');
        print('   末2行: ${lines.reversed.take(2).map((s) => s.length > 40 ? s.substring(0, 40) : s).toList()}');
      }
    }
  });
}
