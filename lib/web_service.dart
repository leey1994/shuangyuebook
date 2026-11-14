// WiFi 传书 / 局域网书架：对齐 legado Web 服务。
//
// 手机和电脑连同一 WiFi，浏览器打开 http://<手机IP>:6274 就能：
//   · 看书架（书名/作者/进度）
//   · 传 TXT/EPUB 到手机（落应用私有目录后直接进书架）
//   · 粘贴书源 JSON 一键导入
//   · 下载 / 恢复备份 JSON
//
// 只对局域网私有地址开放（127/10/172.16-31/192.168），不引第三方依赖，
// 纯 dart:io HttpServer。进程退出自动关停；设置页可随时开关。
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'data/backup.dart';
import 'legado/source_store.dart';
import 'sources/registry.dart';
import 'store.dart';

class WebService {
  WebService._();

  static final WebService I = WebService._();

  static const int defaultPort = 6274;

  HttpServer? _server;

  bool get running => _server != null;

  int get port => _server?.port ?? defaultPort;

  /// 可访问地址（本机 + 各网卡 IPv4），UI 直接列出来让用户抄。
  Future<List<String>> urls() async {
    final out = <String>['http://127.0.0.1:$port'];
    try {
      for (final i in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
        for (final a in i.addresses) {
          if (a.isLoopback || !_isLan(a.address)) continue;
          final u = 'http://${a.address}:$port';
          if (!out.contains(u)) out.add(u);
        }
      }
    } catch (_) {}
    return out;
  }

  bool _isLan(String ip) {
    final p = ip.split('.');
    if (p.length != 4) return false;
    final a = int.tryParse(p[0]) ?? -1;
    final b = int.tryParse(p[1]) ?? -1;
    if (a == 10 || a == 127) return true;
    if (a == 172 && b >= 16 && b <= 31) return true;
    if (a == 192 && b == 168) return true;
    return false;
  }

  bool _allow(HttpRequest req) {
    final ip = req.connectionInfo?.remoteAddress.address ?? '';
    return ip.isEmpty || ip == '127.0.0.1' || _isLan(ip);
  }

  Future<List<String>> start({int port = defaultPort}) async {
    if (_server != null) return urls();
    final srv = await HttpServer.bind(InternetAddress.anyIPv4, port, shared: true);
    _server = srv;
    srv.listen(_handle, onError: (_) {});
    return urls();
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    if (s != null) await s.close(force: true);
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    res.headers.add('Cache-Control', 'no-store');
    if (!_allow(req)) {
      res.statusCode = HttpStatus.forbidden;
      res.write('仅局域网可访问');
      await res.close();
      return;
    }
    try {
      final path = req.uri.path;
      switch (path) {
        case '/':
        case '/index.html':
          res.headers.contentType = ContentType.html;
          res.write(_page());
        case '/api/shelf':
          res.headers.contentType = ContentType.json;
          res.write(jsonEncode([
            for (final e in AppStore.I.shelf)
              {
                'title': e.book.title,
                'author': e.book.author ?? '',
                'source': sourceNameOf(e.book.sourceId),
                'chapter': e.chapterIndex,
                'chapters': e.chapterCount,
                'updatedAt': e.updatedAt.toIso8601String(),
              }
          ]));
        case '/api/backup':
          final data = await BackupService.collect();
          res.headers.add('Content-Disposition',
              'attachment; filename="shuangyue_backup.json"');
          res.headers.contentType = ContentType.json;
          res.write(jsonEncode(data));
        case '/api/book':
          await _uploadBook(req, res);
        case '/api/source':
          await _importSource(req, res);
        case '/api/restore':
          await _restore(req, res);
        default:
          res.statusCode = HttpStatus.notFound;
          res.write('404');
      }
    } catch (e) {
      res.statusCode = HttpStatus.internalServerError;
      res.write('失败：$e');
    }
    await res.close();
  }

  Future<List<int>> _body(HttpRequest req, int max) async {
    final bytes = <int>[];
    await for (final chunk in req) {
      bytes.addAll(chunk);
      if (bytes.length > max) throw Exception('内容过大');
    }
    return bytes;
  }

  Future<void> _uploadBook(HttpRequest req, HttpResponse res) async {
    if (req.method != 'POST') {
      res.statusCode = HttpStatus.methodNotAllowed;
      res.write('POST only');
      return;
    }
    // queryParameters 已经是解码后的值；再叠一层 decodeComponent 遇到含 %
    // 的文件名会抛「Illegal percent encoding in URI」。这里只做安全化。
    var name = req.uri.queryParameters['name'] ?? '';
    name = name.split(RegExp(r'[/\\]')).last.replaceAll(RegExp(r'[^\w.\u4e00-\u9fa5-]'), '_');
    if (name.isEmpty) throw Exception('缺少文件名');
    final low = name.toLowerCase();
    if (!low.endsWith('.txt') && !low.endsWith('.epub')) {
      throw Exception('只支持 .txt / .epub');
    }
    final bytes = await _body(req, 60 << 20);
    if (bytes.isEmpty) throw Exception('文件为空');
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/local_books');
    if (!await dir.exists()) await dir.create(recursive: true);
    final f = File('${dir.path}/$name');
    await f.writeAsBytes(bytes, flush: true);
    final ok = await AppStore.I.importLocalBook(f.path);
    res.headers.contentType = ContentType.json;
    res.write(jsonEncode({
      'ok': true,
      'path': f.path,
      'imported': ok,
      'tip': ok ? '已进书架' : '已在书架或解析失败（文件已保存）',
    }));
  }

  Future<void> _importSource(HttpRequest req, HttpResponse res) async {
    if (req.method != 'POST') {
      res.statusCode = HttpStatus.methodNotAllowed;
      res.write('POST only');
      return;
    }
    final bytes = await _body(req, 8 << 20);
    final text = utf8.decode(bytes, allowMalformed: true);
    final store = SourceStore.shared;
    if (store == null) throw Exception('书源仓库未就绪');
    final r = await store.importFromTextAsync(text);
    await store.flush();
    // 导入后立即让登记表生效，不用重启 App
    syncImportedSources(store.enabled);
    res.headers.contentType = ContentType.json;
    res.write(jsonEncode({
      'added': r.added,
      'updated': r.updated,
      'error': r.error,
    }));
  }

  Future<void> _restore(HttpRequest req, HttpResponse res) async {
    if (req.method != 'POST') {
      res.statusCode = HttpStatus.methodNotAllowed;
      res.write('POST only');
      return;
    }
    final bytes = await _body(req, 16 << 20);
    final r = await BackupService.restoreFromText(
        utf8.decode(bytes, allowMalformed: true));
    res.headers.contentType = ContentType.json;
    res.write(jsonEncode({'error': r.error, 'prefs': r.prefs, 'sources': r.sources}));
  }

  String _esc(String s) => const HtmlEscape().convert(s);

  String _page() {
    final rows = StringBuffer();
    for (final e in AppStore.I.shelf) {
      rows.write('<tr><td>${_esc(e.book.title)}</td>'
          '<td>${_esc(e.book.author ?? '')}</td>'
          '<td>${_esc(sourceNameOf(e.book.sourceId))}</td>'
          '<td>${e.chapterIndex + 1}/${e.chapterCount}</td></tr>');
    }
    return '''<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>爽阅 · WiFi 传书</title><style>
body{font:14px/1.6 system-ui,"Microsoft YaHei",sans-serif;max-width:760px;margin:24px auto;padding:0 16px;color:#222}
h1{font-size:20px} h2{font-size:16px;margin-top:28px;border-bottom:1px solid #eee;padding-bottom:6px}
.card{border:1px solid #e5e5e5;border-radius:12px;padding:14px 16px;margin:12px 0;background:#fafafa}
table{border-collapse:collapse;width:100%;font-size:13px}td,th{padding:6px 8px;border-bottom:1px solid #eee;text-align:left}
textarea{width:100%;height:110px;font:12px monospace;box-sizing:border-box}
button{background:#2f6b3c;color:#fff;border:0;border-radius:8px;padding:8px 16px;cursor:pointer}
input[type=file]{margin-right:8px} .tip{color:#888;font-size:12px} #msg{color:#2f6b3c;font-size:13px;min-height:20px}
</style></head><body>
<h1>爽阅 · WiFi 传书 <span class="tip">（同一 WiFi 下可用，勿在公共网络开启）</span></h1>
<div id="msg"></div>
<h2>书架</h2>
<div class="card"><table><tr><th>书名</th><th>作者</th><th>来源</th><th>进度</th></tr>
$rows</table><p class="tip"><a href="/api/shelf">shelf.json</a> · <a href="/api/backup">下载备份</a></p></div>
<h2>传书到手机（TXT / EPUB）</h2>
<div class="card"><input type="file" id="book" accept=".txt,.epub">
<button onclick="sendBook()">上传并加入书架</button></div>
<h2>导入书源（阅读 3.0 JSON）</h2>
<div class="card"><textarea id="src" placeholder='粘贴书源 JSON（单个对象或数组）'></textarea><br>
<button onclick="sendSource()">导入</button></div>
<script>
const msg=t=>document.getElementById('msg').textContent=t;
async function sendBook(){
  const f=document.getElementById('book').files[0]; if(!f){msg('先选一个文件');return;}
  msg('上传中…'); const r=await fetch('/api/book?name='+encodeURIComponent(f.name),{method:'POST',body:f});
  const j=await r.json().catch(()=>({})); msg(j.tip||j.error||('HTTP '+r.status));
}
async function sendSource(){
  const t=document.getElementById('src').value.trim(); if(!t){msg('先粘贴书源 JSON');return;}
  msg('导入中…'); const r=await fetch('/api/source',{method:'POST',body:t});
  const j=await r.json().catch(()=>({})); msg(j.error||('已导入 '+j.added+' 个，更新 '+j.updated+' 个'));
}
</script></body></html>''';
  }
}
