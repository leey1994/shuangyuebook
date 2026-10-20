import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/legado/js_engine.dart';
import 'package:shuangyue/legado/models.dart';
import 'package:shuangyue/legado/online_book_service.dart';
import 'package:shuangyue/legado/webview_engine.dart';

/// 覆盖两条「书源当脚本执行」的 WebView 链路：
///   1. 章网址尾缀 `,{"webView":true}` → 先渲染出 HTML，再按 ruleContent 解析；
///   2. 脚本里的 `java.webView(url)` → 挂起 → 渲染结果回灌 webViewCache。
void main() {
  tearDown(() => WebViewEngine.debugRenderer = null);

  test('渲染替身：fetchRenderedHtml 走 debugRenderer', () async {
    WebViewEngine.debugRenderer = (url) async => '<html><body>$url</body></html>';
    final html = await WebViewEngine.instance
        .fetchRenderedHtml(url: 'https://demo.test/a');
    expect(html, contains('https://demo.test/a'));
  });

  test('splitUrlSuffix 识别 webView 选项', () {
    final (u, s) = OnlineBookService.splitUrlSuffix(
        'https://www.tadu.com/book/1/2/,{"webView":true}');
    expect(u, 'https://www.tadu.com/book/1/2/');
    expect(s, contains('webView'));
    final (u2, s2) = OnlineBookService.splitUrlSuffix('https://a.test/x');
    expect(u2, 'https://a.test/x');
    expect(s2, isEmpty);
  });

  test('尾缀 webView=true 的章节：渲染后按规则取正文', () async {
    WebViewEngine.debugRenderer = (url) async =>
        '<html><body><div id="partContent">'
        '<p>第一段测试正文，长度足够用于校验。</p>'
        '<p>第二段测试正文，继续补充内容。</p>'
        '</div></body></html>';
    final source = BookSource.fromJson({
      'bookSourceName': '测试书源',
      'bookSourceUrl': 'https://wv.test',
      'bookSourceType': 0,
      'ruleContent': {'content': '#partContent@html'},
    });
    final text = await OnlineBookService().fetchChapterText(
      source,
      'https://wv.test/book/1/2.html,{"webView":true}',
    );
    expect(text, contains('第一段测试正文'));
    expect(text, contains('第二段测试正文'));
  });

  test('java.webView 在脚本层挂起，等待服务层渲染', () {
    final session = JsSession();
    final env = JsEnv(scopeKey: 'wv-suspend-test', session: session);
    Object? thrown;
    try {
      JsBridge.evalCode("java.webView('https://wv.test/page')", env: env);
    } catch (e) {
      thrown = e;
    }
    expect(thrown, isA<JsSuspendException>());
    final e = thrown as JsSuspendException;
    expect(e.kind, 'webview');
    expect(e.target, 'https://wv.test/page');
    // 渲染结果回灌后重跑，脚本拿到 HTML 而不是再挂起。
    session.webViewCache['https://wv.test/page'] = '<html>ok</html>';
    final out = JsBridge.evalCode(
        "String(java.webView('https://wv.test/page'))", env: env);
    expect(out, contains('ok'));
  });
}
