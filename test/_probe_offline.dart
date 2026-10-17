// 离线验证：读已抓下的 HTML，跑引擎规则。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/legado/analyze_css.dart';
import 'package:shuangyue/legado/analyze_rule.dart';

const dir = 'C:/Users/leey1/AppData/Local/Temp/opencode/feilu_html';

String read(String n) => File('$dir/$n').readAsStringSync();

void main() {
  test('offline feilu rules', () {
    // ---- 1) 阶段拆分 bug：`.nodeContent@p@html` ----
    for (final r in ['.nodeContent@p@html', '.content@p@text', 'class.DivTd3@tag.a', 'div@p']) {
      print('$r -> ${parseCssStages(r).map((s) => '${s.type.name}:${s.value}').join(' | ')}');
    }

    // ---- 2) wap 章页正文 ----
    final ch = read('wap_ch1.html');
    final e1 = AnalyzeRule(ch, baseUrl: 'https://wap.faloo.com');
    final v1 = e1.getStrings('.nodeContent@p@html');
    print('wap .nodeContent@p@html 段数=${v1.length} 总长=${v1.join().length}');
    final v1b = e1.getStrings('.nodeContent@html');
    print('wap .nodeContent@html 段数=${v1b.length} 总长=${v1b.join().length}');
    if (v1b.isNotEmpty) {
      print('  预览: ${v1b.first.substring(0, 80)}');
    }
    final v1c = e1.getStrings('.nodeContent@p@text');
    print('wap .nodeContent@p@text 段数=${v1c.length} 总长=${v1c.join().length}');

    // ---- 3) b.faloo 目录 ----
    final book = read('bfaloo_book.html');
    final e2 = AnalyzeRule(book, baseUrl: 'https://b.faloo.com');
    for (final r in [
      'class.DivTd@tag.a',
      'class.DivTd3@tag.a',
      'id.mulu class.DivTd3@tag.a',
      'class.DivTr@tag.a',
    ]) {
      final raw = e2.getRawList(r);
      print('b.faloo $r -> ${raw.length} 项');
      if (raw.isNotEmpty) {
        final n = e2.getStrings('text', ctx: raw.first).length;
        final h = e2.getStrings('href', ctx: raw.first).length;
        print('    首项 text=$n href=$h');
      }
    }

    // ---- 4) b.faloo 章页正文 ----
    final bch = read('bfaloo_ch1.html');
    final e3 = AnalyzeRule(bch, baseUrl: 'https://b.faloo.com');
    final v3 = e3.getStrings('class.noveContent@html');
    print('b.faloo class.noveContent@html 段数=${v3.length} 总长=${v3.join().length}');
    final v3b = e3.getStrings('class.noveContent@p@html');
    print('b.faloo class.noveContent@p@html 段数=${v3b.length} 总长=${v3b.join().length}');
    final v3c = e3.getStrings('.noveContent@html');
    print('b.faloo .noveContent@html 段数=${v3c.length} 总长=${v3c.join().length}');
    if (v3c.isNotEmpty) {
      print('  预览: ${v3c.first.substring(0, 100)}');
    }
  });
}
