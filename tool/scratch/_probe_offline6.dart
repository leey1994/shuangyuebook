// 离线验证 #6：cleanChapterText 升级后唐三/顶点正文可读性 + 话本www 目录疑点。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/legado/analyze_rule.dart';
import 'package:shuangyue/legado/online_book_service.dart';

const dir = 'C:/Users/leey1/AppData/Local/Temp/opencode/src_dump';
String read(String n) => File('$dir/$n').readAsStringSync();

void main() {
  test('offline-6 clean + ihuaben toc', () {
    // 唐三：旧管线 len=0，新管线应出正文
    final xt = AnalyzeRule(read('mini_ch_xtang.html'),
        baseUrl: 'http://www.xtangsanshu.com');
    final xtHtml = xt.getStrings('id.content@html').join('\n');
    final xtText = OnlineBookService.cleanChapterText(xtHtml);
    print('唐三 清洗后 len=${xtText.length} | 前80: ${xtText.replaceAll('\n', '⏎').substring(0, xtText.length > 80 ? 80 : xtText.length)}');
    print('唐三 尾部40: ${xtText.length > 40 ? xtText.substring(xtText.length - 40) : xtText}');

    // 顶点：新 content 规则候选 id.txt@textNodes
    final dd = AnalyzeRule(read('mini_ch_dingdian.html'),
        baseUrl: 'http://www.dingdian888.com');
    for (final r in ['id.txt@textNodes', 'id.txt@text', 'id.txt@html']) {
      final v = dd.getStrings(r);
      final t = OnlineBookService.cleanChapterText(v.join('\n'));
      print('顶点 "$r" -> 原始 ${v.length} 项 / 清洗后 len=${t.length}'
          '${t.isEmpty ? '' : ' | 前60: ${t.replaceAll('\n', '⏎').substring(0, t.length > 60 ? 60 : t.length)}'}');
    }

    // 话本 www：书页上的「章节目录」匹配 + 书页自带章节行数
    final ihb = AnalyzeRule(read('ihuaben_book.html'),
        baseUrl: 'http://www.ihuaben.com');
    print('话本www 书页 text.章节目录@href -> ${ihb.getStrings('text.章节目录@href')}');
    print('话本www 书页 chapter-row 数 -> ${ihb.getRawList('class.chapter-row').length}');

    // 回归：纯文本内容不被破坏
    const plain = '　　“额——”他愣了一下。\n\n　　第二段文字。';
    final cleaned = OnlineBookService.cleanChapterText(plain);
    print('回归 纯文本 -> ${cleaned.length} 字 | 2 行=${cleaned.split('\n').length}');
  });
}
