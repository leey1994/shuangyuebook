// 书源变量持久化验收：`source.getVariable/setVariable` 必须跨会话、跨重启。
//
// 背景：legado 把书源变量存在书源数据库里。爽阅早期只放在 JsSession 内存，
// 「搜索时存 token、正文时取 token」的源在正文阶段拿到空串，表现为正文空。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/legado/source_vars.dart';
import 'package:shuangyue/platform/native_bridge.dart';

const _src = 'https://example.com';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('svars_');
  });

  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  AppDirs dirs() => AppDirs(files: tmp.path, cache: tmp.path);

  test('写入后可读，删除后为空', () {
    final v = SourceVars(dirsOverride: dirs());
    expect(v.get(_src, 'token'), '');
    v.set(_src, 'token', 'abc123');
    expect(v.get(_src, 'token'), 'abc123');
    v.set(_src, 'token', null);
    expect(v.get(_src, 'token'), '');
  });

  test('落盘后新实例能读到（模拟重启）', () async {
    final a = SourceVars(dirsOverride: dirs());
    a.set(_src, 'device', 'D-42');
    await a.flush();

    final b = SourceVars(dirsOverride: dirs());
    await b.load();
    expect(b.get(_src, 'device'), 'D-42');
    expect(b.loaded, isTrue);
  });

  test('不同书源互不串味', () {
    final v = SourceVars(dirsOverride: dirs());
    v.set('https://a.com', 'k', '1');
    v.set('https://b.com', 'k', '2');
    expect(v.get('https://a.com', 'k'), '1');
    expect(v.get('https://b.com', 'k'), '2');
    v.removeSource('https://a.com');
    expect(v.get('https://a.com', 'k'), '');
    expect(v.get('https://b.com', 'k'), '2');
  });

  test('单源变量条数与单值长度有上限', () {
    final v = SourceVars(dirsOverride: dirs());
    for (var i = 0; i < SourceVars.maxPerSource + 10; i++) {
      v.set(_src, 'k$i', '$i');
    }
    expect(v.of(_src).length, SourceVars.maxPerSource);
    // 最早写入的被淘汰，最新的还在
    expect(v.get(_src, 'k0'), '');
    expect(v.get(_src, 'k${SourceVars.maxPerSource + 9}'),
        '${SourceVars.maxPerSource + 9}');

    final long = '中文' * 40000; // 远超上限
    v.set(_src, 'big', long);
    expect(v.get(_src, 'big').length, SourceVars.maxValueChars);
  });
}
