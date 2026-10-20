// 发现页 exploreUrl 的三种写法：行格式 / JSON（含宽松 JSON）/ JS 脚本。
// JS 形态是 legado 3.x 的主流写法（124 源里 27 个），原实现直接丢空。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/legado/models.dart';
import 'package:shuangyue/legado/online_repo.dart';
import 'package:shuangyue/legado/source_vars.dart';

BookSource _src(String exploreUrl, {String? jsLib}) => BookSource.fromJson({
      'bookSourceName': '测试源',
      'bookSourceUrl': 'https://example.test',
      'bookSourceGroup': 'test',
      'bookSourceType': 0,
      'customOrder': 0,
      'enabled': true,
      'searchUrl': 'https://example.test/s?q={{key}}',
      'exploreUrl': exploreUrl,
      'jsLib': jsLib,
      'ruleSearch': {
        'bookList': '.list li',
        'name': 'a@text',
        'bookUrl': 'a@href',
      },
      'ruleExplore': {
        'bookList': '.list li',
        'name': 'a@text',
        'bookUrl': 'a@href',
      },
    });

void main() {
  setUp(() => OnlineRepo.debugClearCategoryCache());

  test('行格式', () {
    final s = _src('玄幻::https://e.test/l/1/{{page}}.html\n'
        '排行,https://e.test/rank/');
    final c = OnlineRepo.parseExploreCategories(s);
    expect(c.map((e) => e.title), ['玄幻', '排行']);
    expect(c.first.url, contains('{{page}}'));
  });

  test('JSON 数组：url 为空的是分组标题，跳过', () {
    final s = _src(jsonEncode([
      {'title': '男生', 'url': ''},
      {'title': '玄幻', 'url': '/l/1/'},
    ]));
    final c = OnlineRepo.parseExploreCategories(s);
    expect(c.length, 1);
    expect(c.single.title, '玄幻');
  });

  test('宽松 JSON：单引号 + 无引号键 + 尾逗号（晋江系写法）', () {
    final s = _src("[{title:'分类',url:''},{title:'纯爱',url:'/topten.php?t=1',},]");
    final c = OnlineRepo.parseExploreCategories(s);
    expect(c.single.title, '纯爱');
  });

  test('JS：直接返回数组', () {
    final s = _src('@js:\nvar out = [];\n'
        'out.push({title: "玄幻", url: "/l/1/{{page}}.html"});\n'
        'out.push({title: "都市", url: "/l/2/{{page}}.html"});\nout');
    final c = OnlineRepo.parseExploreCategories(s);
    expect(c.map((e) => e.title), ['玄幻', '都市']);
  });

  test('JS：<js> 块 + jsLib 全局函数', () {
    // 注意：jsLib 里声明的函数在全局作用域，看不到规则脚本里的局部 `var`
    // （脚本每次求值是独立函数作用域）；真实书源都把目标集合当参数传入。
    final s = _src(
      '<js>\nvar out = [];\n'
      "mk(out, 'A', '/a/');\nmk(out, 'B', '/b/');\nJSON.stringify(out);\n</js>",
      jsLib: 'function mk(list, t, u) { list.push({title: t, url: u}); }',
    );
    final c = OnlineRepo.parseExploreCategories(s);
    expect(c.map((e) => e.title), ['A', 'B']);
  });

  test('JS：select 分栏按 default 取默认分类，选择器本身不算分类', () {
    final s = _src('@js:\n'
        'var groups = {"男生": [{title:"玄幻小说", url:"/l/4/"}],'
        ' "女生": [{title:"古代言情", url:"/l/16/"}]};\n'
        'var list = [];\n'
        'list.push({title:"频道", type:"select", chars:["男生","女生"],'
        ' default:"女生", action:"java.refreshExplore()"});\n'
        'var selected = infoMap["频道"] || "男生";\n'
        'groups[selected].forEach(function (it) { list.push(it); });\n'
        'infoMap.save();\n'
        'JSON.stringify(list);');
    final c = OnlineRepo.parseExploreCategories(s);
    expect(c.map((e) => e.title), ['古代言情']);
    // 选择状态被记住：下次直接命中，不再走默认
    expect(SourceVars.I.get('https://example.test', '@exploreInfo'),
        contains('女生'));
  });
}
