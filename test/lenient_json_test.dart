import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/legado/online_repo.dart';

void main() {
  test('宽松 JSON：单引号 / 无引号键 / 尾逗号 / 注释', () {
    const raw = "[{title:'分类',url:'',style:{layout_flexGrow:1,}},"
        "{title:\"长篇\",url:'/b/1',},]";
    final loose = OnlineRepo.debugLenientJson(raw);
    print('LOOSE: $loose');
    final d = jsonDecode(loose!) as List;
    expect(d.length, 2);
    expect((d[0] as Map)['title'], '分类');
    expect((d[1] as Map)['url'], '/b/1');
  });

  test('宽松 JSON：注释与裸换行', () {
    const raw = '[\n// 注释\n{"title":"a","url":"/x"}, /* 行内 */\n'
        "{'title':'多\n行'}]";
    final loose = OnlineRepo.debugLenientJson(raw);
    print('LOOSE2: $loose');
    final d = jsonDecode(loose!) as List;
    expect((d[1] as Map)['title'], '多\n行');
  });
}
