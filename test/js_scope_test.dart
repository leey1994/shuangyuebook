// 书源 JS 作用域对齐：Rhino 里规则脚本就是「全局脚本」，var/function 落全局。
// 于是「规则脚本定义的工具函数 → 被后面的规则或 jsLib 函数调用」这条链必须成立
// （聚合类书源的 explore `<js>` 常这么写：先定义 styles()，再由后续动作调用）。
import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/legado/js_engine.dart';
import 'package:shuangyue/legado/models.dart';
import 'package:shuangyue/legado/online_repo.dart';

BookSource _src() => BookSource.fromJson({
      'bookSourceName': '作用域',
      'bookSourceUrl': 'https://example.test',
      'bookSourceType': 0,
      'customOrder': 0,
      'enabled': true,
      'searchUrl': 'https://example.test/s',
      'jsLib': 'function fromLib(x) { return "Lib(" + x + ")" + TAG; }',
      'ruleSearch': {'bookList': '.x', 'name': 'a@text', 'bookUrl': 'a@href'},
      'ruleToc': {
        'chapterList': '.c a',
        'chapterName': 'text',
        'chapterUrl': 'href',
      },
      'ruleContent': {'content': '.content'},
    });

String? _run(String code) {
  final s = _src();
  return JsBridge.evalCode(code, env: OnlineRepo.jsEnvFor(s, JsSession()));
}

void main() {
  test('规则脚本的 var/function 对后续求值可见', () {
    expect(_run('var tagA = "A"; function joinB(x) { return x + tagA; } '
        'joinB("1");'), '1A');
    expect(_run('joinB("2");'), '2A');
  });

  test('jsLib 函数能读到脚本定义的全局', () {
    // TAG 由上一例之外的脚本定义；这里先定义再调 jsLib 里的函数
    expect(_run('var TAG = "!"; 1;'), '1');
    expect(_run('fromLib("x");'), 'Lib(x)!');
  });

  test('jsLib 函数能在同一次求值里被定义后调用', () {
    expect(_run('var TAG = "?"; fromLib("y");'), 'Lib(y)?');
  });
}
