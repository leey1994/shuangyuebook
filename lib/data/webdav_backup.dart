// WebDAV 备份：对齐 legado 系衍生版的「云端备份」。
//
// 用固定文件名 shuangyue_backup.json 覆盖式上传（不做 LIST/PROPFIND，
// 各家 WebDAV 对 PROPFIND 的 XML 解析差异大，覆盖式最稳、也最好排查）。
// 账号密码存在本机 SharedPreferences；备份内容走 BackupService.collect()，
// 与本地导出完全同一份口径（含明敏密钥剔除）。
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'backup.dart';
import '../store.dart';

class WebDavBackup {
  WebDavBackup._();

  static const String _kUrl = 'webdavUrl';
  static const String _kUser = 'webdavUser';
  static const String _kPass = 'webdavPass';
  static const String _kFileName = 'shuangyue_backup.json';

  static String get url => AppStore.I.sp?.getString(_kUrl)?.trim() ?? '';
  static String get user => AppStore.I.sp?.getString(_kUser) ?? '';
  static String get password => AppStore.I.sp?.getString(_kPass) ?? '';

  static bool get configured => url.isNotEmpty;

  static Future<void> save(String url, String user, String password) async {
    final sp = AppStore.I.sp;
    if (sp == null) return;
    await sp.setString(_kUrl, url.trim());
    await sp.setString(_kUser, user.trim());
    await sp.setString(_kPass, password);
  }

  /// 备份文件 URI：[url] 可指向一个目录（末尾自动补 /），也可直接给完整文件地址。
  static Uri fileUri() {
    final raw = url;
    final base = raw.endsWith('/') ? raw : '$raw/';
    return Uri.parse('$base$_kFileName');
  }

  /// 目录 URI（用于 MKCOL 兜底）。
  static Uri dirUri() => Uri.parse(url.endsWith('/') ? url : '$url/');

  static Map<String, String> get _headers {
    final auth = base64Encode(utf8.encode('$user:$password'));
    return {
      'Authorization': 'Basic $auth',
      'Content-Type': 'application/json; charset=utf-8',
      'Accept': '*/*',
    };
  }

  /// 上传备份。目录不存在时先 MKCOL 再重试一次。
  static Future<void> upload() async {
    if (!configured) throw Exception('还没配置 WebDAV 服务器');
    final data = await BackupService.collect();
    final body = utf8.encode(jsonEncode(data));
    final uri = fileUri();
    var r = await http
        .put(uri, headers: _headers, body: body)
        .timeout(const Duration(seconds: 30));
    if (r.statusCode == 409 || r.statusCode == 404) {
      // 父目录不存在：建目录再试一次（405/301 都视为已存在）
      try {
        final mk = http.Request('MKCOL', dirUri())..headers.addAll(_headers);
        await http.Client().send(mk).timeout(const Duration(seconds: 15));
      } catch (_) {}
      r = await http
          .put(uri, headers: _headers, body: body)
          .timeout(const Duration(seconds: 30));
    }
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw Exception('上传失败（HTTP ${r.statusCode}）：检查地址/账号/密码');
    }
  }

  /// 下载并恢复云端备份。
  static Future<BackupReport> download() async {
    if (!configured) throw Exception('还没配置 WebDAV 服务器');
    final r = await http
        .get(fileUri(), headers: _headers)
        .timeout(const Duration(seconds: 30));
    if (r.statusCode == 404) {
      throw Exception('云端还没有备份，请先上传一次');
    }
    if (r.statusCode != 200) {
      throw Exception('下载失败（HTTP ${r.statusCode}）');
    }
    final text = utf8.decode(r.bodyBytes, allowMalformed: true);
    final report = await BackupService.restoreFromText(text);
    if (report.error != null) throw Exception(report.error!);
    return report;
  }
}
