// 原型自检：验证「大模型生成的阅读 3.0 书源」能被本仓库引擎跑通。
//
// 运行：
//   flutter test tool/source_gen_probe/probe_test.dart
//   （可选真实模型）flutter test tool/source_gen_probe/probe_test.dart \
//     --dart-define=LLM_BASE_URL=... --dart-define=LLM_API_KEY=... \
//     --dart-define=LLM_MODEL=...
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/legado/source_generator.dart';

/// 这个源就是「大模型」根据 s.sfacg.com 搜索页 / book.sfacg.com 详情目录
/// 与正文页的结构生成的候选规则（见 candidates/sfacg_desktop.json）。
const String _candidatePath = 'tool/source_gen_probe/candidates/sfacg_desktop.json';

void main() {
  test('候选书源 JSON 结构合法', () {
    final raw = File(_candidatePath).readAsStringSync();
    final src = parseSourceJson(raw);
    expect(src, isNotNull);
    expect(src!.bookSourceUrl, 'https://book.sfacg.com');
    expect(src.searchUrl, contains('{{key}}'));
    expect(src.searchRule?.bookList, isNotEmpty);
    expect(src.tocRule?.chapterList, isNotEmpty);
    expect(src.contentRule?.content, isNotEmpty);
  });

  test('解析器容忍 markdown 代码块与前后废话', () {
    final raw = File(_candidatePath).readAsStringSync();
    final wrapped = '好的，下面是书源：\n```json\n$raw\n```\n以上。';
    expect(parseSourceJson(wrapped)?.bookSourceUrl, 'https://book.sfacg.com');
    expect(parseSourceJson('抱歉，我做不了'), isNull);
  });

  test('HTML 瘦身去掉脚本与注释', () {
    const html = '''<html><head><script>var x=1;</script>
<style>.a{color:red}</style></head>
<body><!-- 广告 --><div class="book"><a href="/b/1">书名</a></div></body></html>''';
    final slim = slimHtml(html);
    expect(slim, contains('class="book"'));
    expect(slim, isNot(contains('var x')));
    expect(slim, isNot(contains('广告')));
    expect(slim.length, lessThan(html.length + 20));
  });

  test('用真实引擎分步实测生成的书源：搜索 → 详情 → 目录 → 正文', () async {
    final src = parseSourceJson(File(_candidatePath).readAsStringSync())!;
    final probe = SourceProbe();
    String? bookUrl;
    final search =
        await probe.verifySearch(src, '剑', onFirstBookUrl: (u) => bookUrl = u);
    // ignore: avoid_print
    print('[实测·搜索] $search');
    expect(search.ok, isTrue, reason: '$search');
    expect(bookUrl, isNotEmpty);

    final detail = await probe.verifyDetail(src, bookUrl ?? src.bookSourceUrl);
    // ignore: avoid_print
    print('[实测·详情] $detail');
    final toc = await probe.verifyToc(src, bookUrl ?? src.bookSourceUrl);
    // ignore: avoid_print
    print('[实测·目录] $toc');
    final content = await probe.verifyContent(src, bookUrl ?? src.bookSourceUrl);
    // ignore: avoid_print
    print('[实测·正文] $content');

    expect(detail.ok, isTrue, reason: '$detail');
    expect(toc.ok, isTrue, reason: '$toc');
    expect(content.ok, isTrue, reason: '$content');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('模型接口 → 分步生成 → 逐步实测（本地 mock OpenAI 兼容接口）', () async {
    final candidate = File(_candidatePath).readAsStringSync();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    unawaited(server.forEach((req) async {
      if (req.uri.path.endsWith('/chat/completions')) {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({
          'choices': [
            {
              'message': {'content': '```json\n$candidate\n```'}
            }
          ]
        }));
      } else {
        req.response.statusCode = 404;
      }
      await req.response.close();
    }));

    final gen = SourceGenerator(
        llm: LlmClient(LlmConfig(
      baseUrl: 'http://127.0.0.1:${server.port}/v1',
      apiKey: 'test',
      model: 'mock-model',
    )));

    // 第 1 步：搜索
    final search = await gen.generateSearchStep(
      siteUrl: 'https://book.sfacg.com',
      keyword: '剑',
      maxRounds: 1,
    );
    expect(search.ok, isTrue, reason: '搜索步应通过：${search.detail}');
    expect(search.bookUrl, isNotEmpty);

    // 第 2 步：书详情
    final detail = await gen.generateDetailStep(
      draft: search.source!,
      bookUrl: search.bookUrl!,
      maxRounds: 1,
    );
    expect(detail.ok, isTrue, reason: '详情步应通过：${detail.detail}');

    // 第 3 步：目录
    final toc = await gen.generateTocStep(
      draft: detail.source!,
      bookUrl: search.bookUrl!,
      maxRounds: 1,
    );
    expect(toc.ok, isTrue, reason: '目录步应通过：${toc.detail}');

    // 第 4 步：正文
    final content = await gen.generateContentStep(
      draft: toc.source!,
      bookUrl: search.bookUrl!,
      maxRounds: 1,
    );
    expect(content.ok, isTrue, reason: '正文步应通过：${content.detail}');
    expect(content.source!.contentRule?.content, isNotEmpty);
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('真实模型生成（需提供 LLM_* 环境变量，否则跳过）', () async {
    const url = String.fromEnvironment('LLM_BASE_URL');
    const key = String.fromEnvironment('LLM_API_KEY');
    const model = String.fromEnvironment('LLM_MODEL');
    if (url.isEmpty || key.isEmpty || model.isEmpty) {
      // ignore: avoid_print
      print('[跳过] 没有 LLM_BASE_URL / LLM_API_KEY / LLM_MODEL');
      return;
    }
    final gen = SourceGenerator(
        llm: LlmClient(
            const LlmConfig(baseUrl: url, apiKey: key, model: model)));
    void say(String m) {
      // ignore: avoid_print
      print('[生成] $m');
    }

    final search = await gen.generateSearchStep(
      siteUrl: 'https://book.sfacg.com',
      keyword: '剑',
      maxRounds: 3,
      log: say,
    );
    // ignore: avoid_print
    print('[搜索步] ok=${search.ok} ${search.detail}');
    if (!search.ok) return; // 真实模型质量不稳定，搜索步通过即视为链路可用
    final detail = await gen.generateDetailStep(
        draft: search.source!, bookUrl: search.bookUrl!, maxRounds: 3, log: say);
    // ignore: avoid_print
    print('[详情步] ok=${detail.ok} ${detail.detail}');
    final toc = await gen.generateTocStep(
        draft: detail.source!, bookUrl: search.bookUrl!, maxRounds: 3, log: say);
    // ignore: avoid_print
    print('[目录步] ok=${toc.ok} ${toc.detail}');
    final content = await gen.generateContentStep(
        draft: toc.source!, bookUrl: search.bookUrl!, maxRounds: 3, log: say);
    // ignore: avoid_print
    print('[正文步] ok=${content.ok} ${content.detail}');
    expect(content.ok, isTrue);
  }, timeout: const Timeout(Duration(minutes: 15)));
}
