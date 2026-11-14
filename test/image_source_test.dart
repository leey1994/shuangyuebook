// 图片书源（legado bookSourceType=2 / 漫画模式）离线回归。
//
// 全部通过 MockClient 注入，不打真实网络。覆盖：
//  1. CSS 规则逐条产出绝对图片地址（相对地址按章节页解析）；
//  2. `url,{...}` 请求选项尾缀被剥掉（不把选项文本当 URL）；
//  3. nextContentUrl 图片分页追加；
//  4. LegadoSource.isImageBook 只认 type=2。
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shuangyue/legado/http_client.dart';
import 'package:shuangyue/legado/models.dart';
import 'package:shuangyue/legado/online_book_service.dart';
import 'package:shuangyue/sources/legado_source.dart';

BookSource _src({String? nextContentUrl}) => BookSource.fromJson({
      'bookSourceName': '漫画测试源',
      'bookSourceUrl': 'https://m.test',
      'bookSourceType': 2,
      'enabled': true,
      'searchUrl': 'https://m.test/s?q={{key}}',
      'ruleContent': {
        'content': 'class.p@tag.img@src',
        if (nextContentUrl != null) 'nextContentUrl': nextContentUrl,
      },
    });

OnlineBookService _service(MockClient mock) =>
    OnlineBookService(client: SourceHttpClient(client: mock));

void main() {
  test('CSS 规则产出绝对图片地址，不被正文清洗丢掉', () async {
    final mock = MockClient((req) async {
      if (req.url.path == '/c/1.html') {
        return http.Response(
            '<div class="p"><img src="/imgs/1.jpg"></div>'
            '<div class="p"><img src="2.webp"></div>',
            200,
            headers: {'content-type': 'text/html; charset=utf-8'});
      }
      return http.Response('', 404);
    });
    final imgs = await _service(mock)
        .fetchChapterImages(_src(), 'https://m.test/c/1.html');
    expect(imgs, ['https://m.test/imgs/1.jpg', 'https://m.test/c/2.webp']);
  });

  test('ruleContent 返回 <img>/<amp-img> 片段（包子漫画式）也能提取图片', () async {
    final src = BookSource.fromJson({
      'bookSourceName': '漫画测试源',
      'bookSourceUrl': 'https://m.test',
      'bookSourceType': 2,
      'enabled': true,
      'ruleContent': {
        // @js 规则常拼出整段 img 标签；这里用 @text 规则模拟返回 HTML 文本
        'content': 'class.pages@html',
      },
    });
    final mock = MockClient((req) async {
      if (req.url.path == '/c/1.html') {
        return http.Response(
            '<div class="pages">'
            '<amp-img data-src="/imgs/a.jpg"></amp-img>'
            '<img data-original="/imgs/b.webp">'
            '<img src="https://cdn.test/c.jpg">'
            '</div>',
            200,
            headers: {'content-type': 'text/html; charset=utf-8'});
      }
      return http.Response('', 404);
    });
    final imgs = await OnlineBookService(client: SourceHttpClient(client: mock))
        .fetchChapterImages(src, 'https://m.test/c/1.html');
    expect(imgs, [
      'https://m.test/imgs/a.jpg',
      'https://m.test/imgs/b.webp',
      'https://cdn.test/c.jpg',
    ]);
  });

  test('规则只吐 1 张时，从章节页懒加载属性补齐整章图', () async {
    final src = BookSource.fromJson({
      'bookSourceName': '懒加载漫画源',
      'bookSourceUrl': 'https://m.test',
      'bookSourceType': 2,
      'enabled': true,
      'ruleContent': {'content': 'class.one@tag.img@src'},
    });
    final mock = MockClient((req) async {
      if (req.url.path == '/c/1.html') {
        return http.Response(
            '<div class="comic-contain">'
            '<amp-img data-src="/imgs/1.jpg"></amp-img>'
            '<amp-img data-src="/imgs/2.jpg"></amp-img>'
            '<img data-original="/imgs/3.jpg">'
            '<img src="/static/logo.png">'
            '<div class="one"><img src="/imgs/1.jpg"></div>'
            '</div>',
            200,
            headers: {'content-type': 'text/html; charset=utf-8'});
      }
      return http.Response('', 404);
    });
    final imgs = await OnlineBookService(client: SourceHttpClient(client: mock))
        .fetchChapterImages(src, 'https://m.test/c/1.html');
    expect(imgs, [
      'https://m.test/imgs/1.jpg',
      'https://m.test/imgs/2.jpg',
      'https://m.test/imgs/3.jpg',
    ]);
  });

  test('规则只拿到推荐位图时，按「同目录序号最多」补齐本章图', () async {
    final src = BookSource.fromJson({
      'bookSourceName': 'JS 数组漫画源',
      'bookSourceUrl': 'https://m.test',
      'bookSourceType': 2,
      'enabled': true,
      'ruleContent': {'content': 'class.reco@tag.img@src'},
    });
    final mock = MockClient((req) async {
      if (req.url.path == '/c/1.html') {
        return http.Response(
            '<div class="reco"><img src="https://cdn.test/other/1.jpg"></div>'
            '<script>var a=["https://cdn.test/comic/82/1.jpg",'
            '"https://cdn.test/comic/82/2.jpg",'
            '"https://cdn.test/comic/82/3.jpg"];</script>',
            200,
            headers: {'content-type': 'text/html; charset=utf-8'});
      }
      return http.Response('', 404);
    });
    final imgs = await OnlineBookService(client: SourceHttpClient(client: mock))
        .fetchChapterImages(src, 'https://m.test/c/1.html');
    expect(imgs.take(3), [
      'https://cdn.test/comic/82/1.jpg',
      'https://cdn.test/comic/82/2.jpg',
      'https://cdn.test/comic/82/3.jpg',
    ]);
    expect(imgs.last, 'https://cdn.test/other/1.jpg');
  });

  test('图片地址带 ,{...} 选项尾缀时只保留纯地址', () async {
    final mock = MockClient((req) async => http.Response(
        '<div class="p"><img src="/p/3.jpg,{"headers":{"Referer":"x"}}"></div>',
        200));
    final imgs = await _service(mock)
        .fetchChapterImages(_src(), 'https://m.test/c/1.html');
    expect(imgs, ['https://m.test/p/3.jpg']);
  });

  test('nextContentUrl 图片分页：后续页按该页地址解析并追加', () async {    final mock = MockClient((req) async {
      if (req.url.path == '/c/1.html') {
        return http.Response(
            '<div class="p"><img src="/1.jpg"></div>'
            '<a class="nx" href="2.html">next</a>',
            200);
      }
      if (req.url.path == '/c/2.html') {
        return http.Response('<div class="p"><img src="/3.jpg"></div>', 200);
      }
      return http.Response('', 404);
    });
    final imgs = await _service(mock).fetchChapterImages(
        _src(nextContentUrl: 'class.nx@href'), 'https://m.test/c/1.html');
    expect(imgs, ['https://m.test/1.jpg', 'https://m.test/3.jpg']);
  });

  test('图片源判定：type=2 是漫画，type=0 是文本小说', () {
    expect(LegadoSource(_src()).isImageBook, isTrue);
    final text = BookSource.fromJson({
      'bookSourceName': '文本源',
      'bookSourceUrl': 'https://t.test',
      'bookSourceType': 0,
      'enabled': true,
    });
    expect(LegadoSource(text).isImageBook, isFalse);
  });
}
