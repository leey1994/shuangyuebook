// JS API 面探针：逐个成员打印 typeof，找出脚本会用但引擎没实现的成员。
//
//   flutter test tool/api_surface_test.dart -r expanded
// ignore_for_file: avoid_print
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/legado/js_engine.dart';
import 'package:shuangyue/legado/models.dart';
import 'package:shuangyue/legado/online_repo.dart';

const _members = [
  'java.ajax', 'java.ajaxAll', 'java.connect', 'java.get', 'java.post',
  'java.put', 'java.log', 'java.toast', 'java.longToast', 'java.getString',
  'java.getElement', 'java.getElements', 'java.base64Encode', 'java.base64Decode',
  'java.hexEncodeToString', 'java.hexDecodeToString', 'java.md5Encode',
  'java.md5Encode16', 'java.encodeURI', 'java.timeFormat', 'java.androidId',
  'java.deviceID', 'java.getCookie', 'java.setCookie', 'java.startBrowser',
  'java.startBrowserAwait', 'java.showBrowser', 'java.showReadingBrowser',
  'java.refreshExplore', 'java.getWebViewUA', 'java.reLoginView',
  'java.createSymmetricCrypto', 'java.qread', 'java.htmlFormat',
  'java.randomUUID', 'java.strToBytes', 'java.bytesToStr', 'java.t2s', 'java.s2t',
  'java.setContent', 'java.getStringList', 'java.clearCookie',
  'java.getVerificationCode', 'java.upLoginData', 'java.reUiView',
  'java.refreshTocUrl', 'java.downloadFile', 'java.readFile',
  'java.aesEncodeToBase64String', 'java.digestHex', 'java.createAsymmetricCrypto',
  'java.toURL',
  'source.getVariable', 'source.setVariable', 'source.get', 'source.put',
  'source.getKey', 'source.getLoginInfo', 'source.getLoginInfoMap',
  'source.getLoginHeader', 'source.getLoginHeaderMap', 'source.loginUi',
  'source.bookSourceUrl', 'source.bookSourceName', 'source.searchUrl',
  'source.bookSourceComment', 'source.bookSourceGroup',
  'cookie.getCookie', 'cookie.setCookie', 'cookie.removeCookie', 'cookie.getKey',
  'result.replace', 'result.match', 'result.data', 'result.length',
];

void main() {
  test('api surface', () {
    final src = BookSource.fromJson({
      'bookSourceName': 'api面',
      'bookSourceUrl': 'https://example.test',
      'bookSourceComment': '注释',
      'bookSourceGroup': '分组',
      'bookSourceType': 0,
      'customOrder': 0,
      'enabled': true,
      'searchUrl': 'https://example.test/s',
      'ruleSearch': {'bookList': '.x', 'name': 'a@text', 'bookUrl': 'a@href'},
      'ruleToc': {'chapterList': '.c a', 'chapterName': 'text', 'chapterUrl': 'href'},
      'ruleContent': {'content': '.content'},
    });
    final env = OnlineRepo.jsEnvFor(src, JsSession());
    final keys = jsonEncode(_members);
    final out = JsBridge.evalCode(
      'JSON.stringify(($keys).map(function (k) {'
      ' var parts = k.split(".");'
      ' var o = this[parts[0]];'
      ' try { return k + "=" + (o == null ? "undefined" : typeof o[parts[1]]); }'
      ' catch (e) { return k + "=ERR"; }'
      ' }))',
      env: env,
    );
    final list = out == null ? <String>[] : (jsonDecode(out) as List).cast<String>();
    final missing = <String>[];
    for (final kv in list) {
      final i = kv.indexOf('=');
      final k = kv.substring(0, i);
      final v = kv.substring(i + 1);
      if (v == 'undefined' || v == 'ERR') missing.add(k);
      print('${v.padRight(10)} $k');
    }
    print('\n缺失 ${missing.length}/${list.length}: ${missing.join(", ")}');
  });
}
