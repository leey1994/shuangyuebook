// ignore_for_file: avoid_print
// 书源冒烟：dart run tool/source_smoke.dart
// 每源：home → rankTabs → 搜「斗罗」→ 详情（章数+首章题）→ 首章中文 ≥300 → PASS/FAIL。
// shenwen 搜索未登录 302 返回 [] 属设计行为 → 豁免，回退首页首书继续。
import 'package:novel_reader/models.dart';
import 'package:novel_reader/sources/registry.dart';

final _han = RegExp(r'[^\u4e00-\u9fa5]');
int hanCount(String s) => s.replaceAll(_han, '').length;

Future<void> main() async {
  var pass = 0;
  var fail = 0;
  for (final src in allSources) {
    final buf = StringBuffer();
    var ok = true;
    Book? pick;
    BookDetail? detail;
    try {
      final home = await src.fetchHome();
      buf.write('home=${home.length} ');
      if (home.isEmpty) {
        ok = false;
        buf.write('[空首页] ');
      }
      final tabs = await src.fetchRankTabs();
      buf.write('tabs=${tabs.length} ');
      if (tabs.isEmpty) {
        ok = false;
        buf.write('[空榜单] ');
      } else {
        final r = await src.fetchRank(tabs.first);
        buf.write('rank=${r.items.length}${r.nextUrl != null ? '+next' : ''} ');
        if (r.items.isEmpty) {
          ok = false;
          buf.write('[空排行] ');
        }
      }
      // 搜索
      List<Book> hits;
      try {
        hits = await src.search('斗罗');
      } catch (e) {
        hits = [];
        ok = false;
        buf.write('[搜索抛错:${_clip('$e', 60)}] ');
      }
      buf.write('search=${hits.length} ');
      if (hits.isNotEmpty) {
        pick = hits.first;
      } else if (src.id == 'shenwen') {
        // 未登录 302 → [] 为设计行为；回退首页首书
        final home = await src.fetchHome();
        pick = home.isEmpty ? null : home.first;
        buf.write('(豁免→首页首书) ');
      }
      if (pick == null) {
        ok = false;
        buf.write('[无目标书] ');
      } else {
        detail = await src.fetchDetail(pick);
        buf.write('章数=${detail.chapters.length} ');
        if (detail.chapters.isEmpty) {
          ok = false;
          buf.write('[空目录] ');
        } else {
          final c0 = detail.chapters.first;
          buf.write('首章「${_clip(c0.title, 18)}」 ');
          final paras = await src.fetchChapter(detail, c0);
          final n = hanCount(paras.join());
          buf.write('字数=$n ');
          // 200：序/楔子短正文实测 ~280 字（如神文《警察陆令》序），坏提取仍会 <50
          if (n < 200) {
            ok = false;
            buf.write('[正文过短] ');
          }
        }
      }
    } catch (e) {
      ok = false;
      buf.write('[异常:${_clip('$e', 80)}] ');
    }
    print('${ok ? 'PASS' : 'FAIL'} ${src.id.padRight(10)} ${src.name}  $buf');
    if (ok) {
      pass++;
    } else {
      fail++;
    }
  }
  print('---\n合计 PASS=$pass FAIL=$fail / ${allSources.length}');
}

String _clip(String s, int n) => s.length <= n ? s : s.substring(0, n);
