// 书源登录 / Cookie 管理（对齐「阅读 3.0」的登录态维护）。
//
// 很多书源（爱丽丝书屋、篱笆好文学等）需要登录态才能看正文。Cookie 仓库
// （[LegadoCookieJar]）本身就能存登录态，但原来没有入口去拿 —— 于是：
//   - Android：直接开一个可见 WebView 让用户登录，登录后把页面 Cookie 收进仓库；
//   - 其它平台（Windows 没有 WebView 实现）：提供「手动粘贴 Cookie」兜底。
import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../legado/cookie_jar.dart';
import '../../legado/models.dart';
import '../brand.dart';

/// 打开书源登录 / Cookie 管理弹层。
void showSourceLogin(BuildContext context, BookSource source) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => SourceLoginPage(source: source),
    ),
  );
}

/// 登录页 / Cookie 管理：Android 是可见 WebView；其余平台是手动粘贴。
class SourceLoginPage extends StatefulWidget {
  const SourceLoginPage({super.key, required this.source});
  final BookSource source;

  @override
  State<SourceLoginPage> createState() => _SourceLoginPageState();
}

class _SourceLoginPageState extends State<SourceLoginPage> {
  final _cookieCtrl = TextEditingController();
  bool _saving = false;
  bool _showManual = !_webviewSupported;

  static bool get _webviewSupported => !kIsWeb && Platform.isAndroid;

  String get _baseUrl {
    final raw = widget.source.loginUrl ?? widget.source.bookSourceUrl;
    return raw.split(RegExp(r'[#?]')).first; // 去掉 ##分组 / 查询尾缀
  }

  String get _currentCookies =>
      LegadoCookieJar.I.getFor(widget.source.bookSourceUrl);

  Future<void> _saveManual() async {
    final c = _cookieCtrl.text.trim();
    if (c.isEmpty) return;
    setState(() => _saving = true);
    try {
      LegadoCookieJar.I.setFor(widget.source.bookSourceUrl, c);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Cookie 已保存')));
        _cookieCtrl.clear();
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _clear() async {
    LegadoCookieJar.I.removeFor(widget.source.bookSourceUrl);
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已清除登录态')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasCookie = _currentCookies.isNotEmpty;
    final body = _webviewSupported
        ? (_showManual ? _manualPanel(theme, hasCookie) : _webviewArea())
        : _manualPanel(theme, hasCookie);
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text('登录 · ${widget.source.bookSourceName}'),
        actions: [
          if (_webviewSupported && !_showManual)
            TextButton(
              onPressed: _harvestFromWebview,
              child: const Text('已登录，收下'),
            ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: '清除登录态',
            onPressed: hasCookie ? _clear : null,
          ),
        ],
      ),
      body: body,
    );
  }

  Widget _webviewArea() {
    final ctrl = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36')
      ..loadRequest(Uri.parse(_baseUrl));
    return WebViewWidget(controller: ctrl);
  }

  Future<void> _harvestFromWebview() async {
    try {
      final uri = Uri.parse(_baseUrl);
      final cookies =
          await WebViewCookieManager().getCookies(domain: uri);
      final parts = <String>[];
      for (final c in cookies) {
        parts.add('${c.name}=${c.value}');
      }
      // 登录脚本可能用 document.cookie 记录会话（WebManager 不一定走 HTTP Set-Cookie）
      final jar = LegadoCookieJar.I;
      if (parts.isNotEmpty) {
        jar.setFor(widget.source.bookSourceUrl, parts.join('; '));
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(parts.isEmpty
                ? '没有读到 Cookie（页面可能未登录）'
                : '已保存 ${parts.length} 个 Cookie')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('读取 Cookie 失败：$e')));
      }
    }
  }

  Widget _manualPanel(ThemeData theme, bool hasCookie) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(hasCookie ? '当前已有登录态 Cookie' : '还没有登录态 Cookie',
              style: theme.textTheme.bodyMedium),
          const SizedBox(height: 6),
          Text(
            '把浏览器登录后的 Cookie 粘进来（格式：name1=value1; name2=value2）。'
            '\n登录地址：$_baseUrl',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _cookieCtrl,
            maxLines: 3,
            decoration: const InputDecoration(
              hintText: '粘贴 Cookie 串',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              BrandBtn('保存 Cookie',
                  onTap: _saving ? null : _saveManual),
              const SizedBox(width: 10),
              if (_webviewSupported && _showManual == false)
                BrandBtn('改用网页登录',
                    style: BrandBtnStyle.outline,
                    onTap: () => setState(() => _showManual = false)),
              if (_webviewSupported && _showManual)
                BrandBtn('改用网页登录',
                    style: BrandBtnStyle.outline,
                    onTap: () => setState(() => _showManual = true)),
            ],
          ),
        ],
      ),
    );
  }
}
