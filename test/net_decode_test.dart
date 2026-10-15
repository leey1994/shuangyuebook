// 正文字符集判定：先严格 UTF-8，解不动再按 GBK。
//
// 栽过的坑：伪速读谷章节页 meta 写 gb2312、实际发 UTF-8，旧逻辑
// 「先 UTF-8 再按声明重解」会把好页面解成「銆銆绗1绔」乱码。
import 'dart:convert';

import 'package:fast_gbk/fast_gbk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/net.dart';

void main() {
  test('声明 gb2312 但实际是 UTF-8 的页面，按 UTF-8 解', () {
    final bytes = utf8.encode('<meta charset="gb2312"><p>第1章 陨落的天才</p>');
    expect(Net.decodeBody(bytes), contains('第1章 陨落的天才'));
  });

  test('真 GBK 页面仍按 GBK 解', () {
    final bytes = gbk.encode('<p>斗之力，三段！</p>');
    expect(Net.decodeBody(bytes), contains('斗之力，三段！'));
  });
}
