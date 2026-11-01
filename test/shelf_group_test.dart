// 书架分组：分组名持久化、批量移入、删组把书退回未分组（不删书）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuangyue/models.dart';
import 'package:shuangyue/store.dart';

Book _b(String id) => Book(sourceId: 's', id: id, url: 'https://t.test/$id', title: id);

void main() {
  test('分组增删与批量分配', () async {
    final dir = Directory.systemTemp.createTempSync('sy_group_');
    addTearDown(() => dir.deleteSync(recursive: true));
    SharedPreferences.setMockInitialValues({});
    AppStore.I.debugSetCacheDir(dir);
    await AppStore.I.init();

    AppStore.I.addToShelf(_b('g1'));
    AppStore.I.addToShelf(_b('g2'));
    AppStore.I.setShelfGroup(['https://t.test/g1'], '玄幻');
    AppStore.I.setShelfGroup(['https://t.test/g2'], '玄幻');

    expect(AppStore.I.shelfGroups, contains('玄幻'));
    expect(AppStore.I.shelf.where((e) => e.group == '玄幻').length, 2);

    AppStore.I.removeShelfGroup('玄幻');
    expect(AppStore.I.shelfGroups, isNot(contains('玄幻')));
    expect(AppStore.I.shelf.every((e) => e.group.isEmpty), isTrue);
    expect(AppStore.I.shelf.length, 2); // 书还在
  });
}
