// 书源 AI 生成：模型列表自动获取（成功 / 失败兜底）、配置持久化、模板与 JSON 解析。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuangyue/data/llm_settings.dart';
import 'package:shuangyue/legado/source_generator.dart';

/// 起一个本地 OpenAI 兼容接口；[modelsBody] 为 null 时 /models 返回 500。
Future<HttpServer> _mockServer({Object? modelsBody}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  unawaited(server.forEach((req) async {
    if (req.uri.path.endsWith('/models')) {
      if (modelsBody == null) {
        req.response.statusCode = 500;
        req.response.write('boom');
      } else {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(modelsBody));
      }
    } else {
      req.response.statusCode = 404;
    }
    await req.response.close();
  }));
  return server;
}

void main() {
  test('OpenAI 协议端点拼接：兼容各种 baseUrl 写法', () {
    LlmConfig cfg(String base) => LlmConfig(baseUrl: base, apiKey: 'k', model: 'm');

    // 标准：/v1 根地址
    expect(cfg('https://api.openai.com/v1').chatUrl,
        'https://api.openai.com/v1/chat/completions');
    expect(cfg('https://api.openai.com/v1').modelsUrl,
        'https://api.openai.com/v1/models');
    // 尾斜杠
    expect(cfg('https://api.openai.com/v1/').chatUrl,
        'https://api.openai.com/v1/chat/completions');
    // 不带 /v1（DeepSeek 这类官方就支持裸域名的兼容端点）
    expect(cfg('https://api.deepseek.com').chatUrl,
        'https://api.deepseek.com/chat/completions');
    // 有人把全路径当接口地址填：原样使用，models 回退到 /v1/models
    expect(cfg('https://gw.test/v1/chat/completions').chatUrl,
        'https://gw.test/v1/chat/completions');
    expect(cfg('https://gw.test/v1/chat/completions').modelsUrl,
        'https://gw.test/v1/models');
    // Gemini 的 OpenAI 兼容层（带尾路径）
    expect(cfg('https://x.test/v1beta/openai/').chatUrl,
        'https://x.test/v1beta/openai/chat/completions');
    expect(cfg('https://x.test/v1beta/openai/').modelsUrl,
        'https://x.test/v1beta/openai/models');
  });

  test('模型型号自动获取：解析 data[].id 并排序', () async {
    final server = await _mockServer(modelsBody: {
      'data': [
        {'id': 'qwen-plus'},
        {'id': 'gpt-4o-mini'},
      ]
    });
    addTearDown(() => server.close(force: true));

    final client = LlmClient(LlmConfig(
      baseUrl: 'http://127.0.0.1:${server.port}/v1',
      apiKey: 'k',
      model: 'x',
    ));
    expect(await client.listModels(), ['gpt-4o-mini', 'qwen-plus']);
  });

  test('模型列表接口失败要抛错（调用方据此退回手填）', () async {
    final server = await _mockServer(modelsBody: null);
    addTearDown(() => server.close(force: true));

    final client = LlmClient(LlmConfig(
      baseUrl: 'http://127.0.0.1:${server.port}/v1',
      apiKey: 'k',
      model: 'x',
    ));
    expect(() => client.listModels(), throwsA(isA<LlmException>()));
  });

  test('配置持久化：保存后重建能读回', () async {
    SharedPreferences.setMockInitialValues({});
    final sp = await SharedPreferences.getInstance();

    LlmSettings.I.init(sp);
    expect(LlmSettings.I.configured, isFalse);

    LlmSettings.I.save(
        baseUrl: 'https://api.test/v1',
        apiKey: 'sk-1',
        model: 'm1',
        models: ['m1', 'm2']);
    expect(LlmSettings.I.configured, isTrue);

    // 模拟重启：同一 sp 重新 init
    LlmSettings.I.init(sp);
    expect(LlmSettings.I.baseUrl, 'https://api.test/v1');
    expect(LlmSettings.I.apiKey, 'sk-1');
    expect(LlmSettings.I.model, 'm1');
  });

  test('搜索模板补全：{{key}} 编码 + 相对地址按站点补全', () {
    expect(
        resolveTemplate('/search?q={{key}}', '剑 来', 'https://a.test/x/'),
        'https://a.test/search?q=%E5%89%91%20%E6%9D%A5');
    expect(resolveTemplate('https://b.test/s?k={{key}}', 'a', 'https://a.test'),
        'https://b.test/s?k=a');
    expect(resolveTemplate('', 'a', 'https://a.test'), isNull);
  });

  test('parseSourceJson：容忍代码块，拒绝无 bookSourceUrl 的对象', () {
    const ok = '```json\n{"bookSourceName":"x","bookSourceUrl":"https://x.test"}\n```';
    expect(parseSourceJson(ok)?.bookSourceUrl, 'https://x.test');
    expect(parseSourceJson('{"foo":1}'), isNull);
    expect(parseSourceJson('随便说说'), isNull);
  });
}
