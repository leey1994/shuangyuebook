// 书源请求头清洗：非 ASCII 头值（作者留的中文占位）以前会让 http 包
// 抛「无效的请求头」，整条书源不可用；现在剔除后照常发请求。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/legado/http_client.dart';

void main() {
  test('非 ASCII 头值被剔除，请求照常发出', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final got = <String, String>{};
    server.listen((req) async {
      got['cookie'] = req.headers.value('cookie') ?? '';
      got['ua'] = req.headers.value('user-agent') ?? '';
      req.response
        ..statusCode = 200
        ..write('ok');
      await req.response.close();
    });
    addTearDown(() => server.close(force: true));
    final client = SourceHttpClient();
    final r = await client.get(
      'http://127.0.0.1:${server.port}/x',
      headers: {
        'Cookie': 'cf_clearance=abc; 其他你抓到的Cookie',
        'User\u2011Agent': 'bad-name-dropped',
      },
    );
    expect(r.statusCode, 200);
    expect(r.body, 'ok');
    // 非 ASCII 字符被剔除，ASCII 部分保留（书名号外的中文全部消失）
    expect(got['cookie'], 'cf_clearance=abc; Cookie');
    // 名字里带 U+2011 的头被整体丢弃，不会覆盖默认 UA
    expect(got['ua'], contains('Chrome'));
  });
}
