// 「先浏览一遍」页面采集器：给 AI 书源生成提供高质量上下文。
//
// 用户在内置浏览里把「首页 → 搜索 → 书详情 → 目录 → 正文」走一遍，
// 每一步的地址被记录下来，返回给生成页 —— 模型直接看到每一步的真实结构，
// 比从首页猜准得多，也快得多。
//
// Android 用可见 WebView；桌面端没有 WebView 实现，退化为「手动粘贴地址」
// （在自己浏览器里操作，把各页地址一行一个粘进来）。
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../legado/source_generator.dart';

/// 打开采集页；返回采集到的页面（按经过顺序，去重，含渲染后 DOM）。
/// 取消 / 空采集返回空表。
Future<List<CollectedPage>> collectPages(
    BuildContext context, String initialUrl) async {
  final r = await Navigator.of(context).push<List<CollectedPage>>(
    MaterialPageRoute(builder: (_) => PageCollectorPage(initialUrl: initialUrl)),
  );
  return r ?? const [];
}

class PageCollectorPage extends StatefulWidget {
  const PageCollectorPage({super.key, required this.initialUrl});
  final String initialUrl;

  @override
  State<PageCollectorPage> createState() => _PageCollectorPageState();
}

class _PageCollectorPageState extends State<PageCollectorPage> {
  /// url → 页面（LinkedHashMap 保序；同一页刷新只更新 DOM）
  final _pages = <String, CollectedPage>{};
  late final _ctrlField = TextEditingController(text: widget.initialUrl);
  late final _paste = TextEditingController();

  bool get _webviewSupported => !kIsWeb && Platform.isAndroid;

  WebViewController? _web;

  @override
  void initState() {
    super.initState();
    if (_webviewSupported) _initWebview();
  }

  void _initWebview() {
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (url) {
          _ctrlField.text = url;
          _remember(url);
          _grabDom(url);
        },
      ));
    final u = Uri.tryParse(widget.initialUrl);
    if (u != null && u.hasScheme) {
      _web!.loadRequest(u);
      _remember(widget.initialUrl);
    }
  }

  /// 搜索结果页大量是 JS 动态渲染：静态重抓只能拿到空壳，
  /// 浏览时顺手把渲染后的 DOM 取回来，AI 才有得看。
  Future<void> _grabDom(String url) async {
    try {
      final dom = await _web!
          .runJavaScriptReturningResult('document.documentElement.outerHTML');
      if (dom is! String || dom.trim().isEmpty) return;
      final clean = url.split('#').first;
      _pages[clean] = CollectedPage(url: clean, html: dom);
      if (mounted) setState(() {});
    } catch (_) {}
  }

  void _remember(String url) {
    final clean = url.split('#').first;
    if (clean.isEmpty) return;
    _pages.putIfAbsent(clean, () => CollectedPage(url: clean));
    if (mounted) setState(() {});
  }

  void _go() {
    final text = _ctrlField.text.trim();
    final uri = Uri.tryParse(
        text.contains('://') ? text : 'https://$text');
    if (uri == null || !uri.hasScheme) return;
    _web?.loadRequest(uri);
  }

  /// 结束采集：把已采集页面带回（Android 返回键同样带回，不丢）。
  void _finish() => Navigator.of(context).pop(_pages.values.toList());

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _finish();
      },
      child: Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.close),
            onPressed: _finish,
          ),
          title: Text(_webviewSupported ? '浏览采集（走完读一遍流程）' : '粘贴各页地址'),
          actions: [
            TextButton(
              onPressed: _pages.isEmpty ? null : _finish,
              child: Text('完成（${_pages.length}）'),
            ),
          ],
        ),
        body: _webviewSupported ? _browseBody(theme) : _pasteBody(theme),
      ),
    );
  }

  // ---- Android：内嵌浏览 ----

  Widget _browseBody(ThemeData theme) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _ctrlField,
                  keyboardType: TextInputType.url,
                  onSubmitted: (_) => _go(),
                  style: const TextStyle(fontSize: 13),
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: '输入网址，像平时一样：搜索 → 点书 → 目录 → 正文',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              IconButton(icon: const Icon(Icons.arrow_forward), onPressed: _go),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Text(
            '按顺序走：首页 → 搜索 → 书详情 → 目录 → 正文，走完点右上角「完成」。',
            style: theme.textTheme.bodySmall,
          ),
        ),
        Expanded(child: WebViewWidget(controller: _web!)),
        if (_pages.isNotEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            color: Theme.of(context).cardColor,
            child: Text(
              '已记录 ${_pages.length} 页（含渲染后内容）：\n${_pages.keys.toList().reversed.take(4).join('\n')}',
              maxLines: 5,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ),
      ],
    );
  }

  // ---- 桌面：手动粘贴 ----

  Widget _pasteBody(ThemeData theme) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          '桌面端没有内置网页内核。请在自己的浏览器里打开这本书站，'
          '按「首页 → 搜索 → 书详情 → 目录 → 正文」走一遍，'
          '把每一步的地址复制下来，一行一个粘到下面（顺序就是模型阅读顺序）。',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _paste,
          maxLines: 10,
          decoration: const InputDecoration(
            hintText:
                'https://site.com\nhttps://site.com/search?q=剑\n'
                'https://site.com/book/1\nhttps://site.com/book/1/toc\n'
                'https://site.com/book/1/12.html',
            border: OutlineInputBorder(),
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 12),
        Text('已识别 ${_pasteUrls.length} 个地址',
            style: theme.textTheme.bodySmall),
        const SizedBox(height: 14),
        FilledButton.icon(
          onPressed: _pasteUrls.isEmpty ? null : _finishPaste,
          icon: const Icon(Icons.check),
          label: const Text('完成'),
        ),
      ],
    );
  }

  List<CollectedPage> get _pasteUrls => [
        for (final line in _paste.text.split(RegExp(r'[\s]+')))
          if (line.trim().isNotEmpty) CollectedPage(url: line.trim()),
      ];

  void _finishPaste() => Navigator.of(context).pop(_pasteUrls);
}
