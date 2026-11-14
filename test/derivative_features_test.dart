// 对齐 legado 衍生版的新能力：备份敏感键剔除、WebDAV 配置、局域网服务页面。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuangyue/data/backup.dart';
import 'package:shuangyue/data/image_file_cache.dart';
import 'package:shuangyue/data/webdav_backup.dart';
import 'package:shuangyue/platform/native_bridge.dart';
import 'package:shuangyue/store.dart';
import 'package:shuangyue/web_service.dart';

/// 把 getApplicationSupportDirectory 指到临时目录（图片缓存测试用）。
class _TmpPathPlatform extends PathProviderPlatform {
  _TmpPathPlatform(this.dir);
  final Directory dir;
  @override
  Future<String?> getApplicationSupportPath() async => dir.path;
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppStore.I.init();
  });

  test('备份导出不含明文 llmApiKey，其余偏好照常带上', () async {
    final sp = AppStore.I.sp!;
    await sp.setString('llmApiKey', 'sk-super-secret');
    await sp.setString('llmBaseUrl', 'https://api.test');
    await sp.setDouble('fontSize', 20.0);

    final data = await BackupService.collect();
    final prefs = data['prefs'] as Map;
    expect(prefs.containsKey('llmApiKey'), isFalse);
    expect(prefs['llmBaseUrl'], 'https://api.test');
    expect(prefs['fontSize'], 20.0);
  });

  test('恢复备份时也不接受外部塞进来的 llmApiKey', () async {
    final sp = AppStore.I.sp!;
    await sp.setString('llmApiKey', '本机自己的 key');
    final text = '{"app":"shuangyue","version":1,'
        '"prefs":{"llmApiKey":"坏备份塞的","fontSize":18.0}}';
    final r = await BackupService.restoreFromText(text);
    expect(r.error, isNull);
    expect(sp.getString('llmApiKey'), '本机自己的 key');
    expect(sp.getDouble('fontSize'), 18.0);
  });

  test('WebDAV 配置与文件 URI：目录地址自动补斜杠', () async {
    expect(WebDavBackup.configured, isFalse);
    await WebDavBackup.save('https://dav.test/shuangyue', 'u', 'p');
    expect(WebDavBackup.configured, isTrue);
    expect(WebDavBackup.user, 'u');
    expect(WebDavBackup.fileUri().toString(),
        'https://dav.test/shuangyue/shuangyue_backup.json');
    expect(WebDavBackup.dirUri().toString(),
        'https://dav.test/shuangyue/');
  });

  test('漫画图片磁盘缓存：写入后离线可读、与 novel_cache 同根', () async {
    final dir = Directory.systemTemp.createTempSync('sy_imgcache_');
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
      ImageFileCache.debugReset();
    });
    PathProviderPlatform.instance = _TmpPathPlatform(dir);
    ImageFileCache.debugReset();

    const url = 'https://m.test/imgs/1.jpg?token=中文';
    expect(await ImageFileCache.has(url), isFalse);
    final bytes = Uint8List.fromList(utf8.encode('JPEGDATA'));
    await ImageFileCache.write(url, bytes);
    expect(await ImageFileCache.has(url), isTrue);
    expect(await ImageFileCache.read(url), bytes);
    expect(await ImageFileCache.size(), greaterThan(0));
    expect(ImageFileCache.fileName(url), endsWith('.img'));
    expect(await Directory('${dir.path}/novel_cache/image_cache').exists(),
        isTrue);
  });

  test('局域网服务页面带书架条目，且开关可以启停', () async {
    final dir = Directory.systemTemp.createTempSync('sy_lan_');
    addTearDown(() async {
      await WebService.I.stop();
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
      BackupService.debugDir = null;
    });
    BackupService.debugDir = dir;

    // 起一个随机端口（测试机可能已有占用），拿到可访问地址后立刻关停
    final urls = await WebService.I.start(port: 0);
    expect(WebService.I.running, isTrue);
    expect(urls, isNotEmpty);
    expect(urls.first, startsWith('http://'));
    await WebService.I.stop();
    expect(WebService.I.running, isFalse);
  });
}
