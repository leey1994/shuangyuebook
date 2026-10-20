// data: URI 本地响应（legado AnalyzeUrl.getByteArrayIfDataUri 的等价行为）。
//
// 番茄小说、七猫聚合这类 API 书源的 searchUrl 是 `@js: fqSearchUrl(...)`：
// 脚本自己用 java.ajax 取到 JSON，再以 `data:;base64,<b64>` 交回规则管线。
// 上游把 data: 在本地解码成响应体、完全不发请求；不实现就会抛
// 「无效的地址：data:…」。
import 'dart:convert';

import 'package:fast_gbk/fast_gbk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/legado/analyze_url.dart';
import 'package:shuangyue/legado/http_client.dart';

void main() {
  final client = SourceHttpClient();

  test('base64 形式的 data: 直接解码为正文，不发请求', () async {
    final json = '{"code":0,"data":{"items":[{"name":"斗破苍穹"}]}}';
    final uri = 'data:;base64,${base64Encode(utf8.encode(json))}';
    final r = await client.get(uri);
    expect(r.statusCode, 200);
    expect(r.body, json);
    expect(r.finalUrl, isEmpty, reason: 'data: 没有可用主机，交给调用方回退');
    expect(r.bytes, utf8.encode(json));
  });

  test('meta 里声明 charset 时按其解码', () async {
    final html = '<p>斗之力，三段！</p>';
    final uri =
        'data:text/html;charset=gbk;base64,${base64Encode(gbk.encode(html))}';
    final r = await client.get(uri);
    expect(r.body, html);
  });

  test('URL 安全的 base64（-_ 且无 padding）也能解', () async {
    final text = '{"ok":1}';
    final b64 = base64Url.encode(utf8.encode(text)).replaceAll('=', '');
    final r = await client.get('data:application/json;base64,$b64');
    expect(r.body, text);
  });

  test('非 base64 的 data: 按百分号编码解码', () async {
    final r = await client.get('data:text/plain,hello%20world%20%E4%B8%AD');
    expect(r.body, 'hello world 中');
  });

  test('普通地址不受影响（仍走网络校验）', () async {
    expect(
      () => client.get('/search.html?q=1'),
      throwsA(isA<SourceHttpException>()),
    );
  });

  test('resolveUrl 不把 data: 当成相对路径', () {
    final uri = 'data:;base64,${base64Encode(utf8.encode('{"a":1}'))}';
    expect(resolveUrl(uri, 'https://api.example.com'), uri);
    // 普通相对路径仍然补全
    expect(
      resolveUrl('/search.html?q=1', 'https://www.example.com'),
      'https://www.example.com/search.html?q=1',
    );
  });
}
