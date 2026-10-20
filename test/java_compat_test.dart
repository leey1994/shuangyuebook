// Packages.* 兼容层验收：以「原版书源脚本会怎么用」为准。
//
// 运行（需 QuickJS 原生库在 PATH）：
//   $env:PATH = "C:\Users\leey1\Desktop\A\A1\shuangyue\build\windows\x64\quickjs_engine_native\Release;" +
//               "C:\Users\leey1\Desktop\A\A1\shuangyue\build\windows\x64\plugins\quickjs_engine\Release;" + $env:PATH
//   flutter test test/java_compat_test.dart -r expanded
import 'dart:convert';
import 'dart:io' show ZLibEncoder, gzip, Directory;

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/legado/cookie_jar.dart';
import 'package:shuangyue/legado/js_engine.dart';
import 'package:shuangyue/legado/source_vars.dart';
import 'package:shuangyue/platform/native_bridge.dart';

/// 在一个共享运行时里求值（与真实书源一致：同 scope 复用全局）。
String? ev(String code, {String scope = 'compat-test'}) {
  final r = JsBridge.evalCode(code, env: JsEnv(scopeKey: scope));
  if (r == null) {
    // ignore: avoid_print
    print('  ↳ 求值失败：${JsBridge.lastError}');
  }
  return r;
}

void b64(String label, List<int> bytes) {
  // ignore: avoid_print
  print('  $label = ${base64.encode(bytes)}');
}

void main() {
  test('Packages.java.util.Base64', () {
    expect(ev("Packages.java.util.Base64.getEncoder().encodeToString([72,105])"), 'SGk=');
    expect(ev("Packages.java.util.Base64.getDecoder().decode('SGk=').join(',')"), '72,105');
    expect(ev("Packages.java.util.Base64.getUrlEncoder().encodeToString([251,255])"), '-_8=');
  });

  test('android.util.Base64 / hutool HexUtil', () {
    expect(ev("Packages.android.util.Base64.encodeToString([1,2,3], 0)"), 'AQID');
    expect(ev("Packages.android.util.Base64.decode('AQID', 0).join(',')"), '1,2,3');
    expect(ev("Packages.cn.hutool.core.util.HexUtil.encodeHexStr([255,0,16])"), 'ff0010');
    expect(ev("Packages.cn.hutool.core.util.HexUtil.decodeHex('ff0010').join(',')"), '255,0,16');
  });

  test('MessageDigest 与 crypto 包一致', () {
    final md5 = crypto.md5.convert(utf8.encode('abc')).bytes;
    final sha256 = crypto.sha256.convert(utf8.encode('abc')).bytes;
    final got = ev("Packages.cn.hutool.core.util.HexUtil.encodeHexStr("
        "Packages.java.security.MessageDigest.getInstance('MD5').digest('abc'))");
    expect(got, md5.map((b) => b.toRadixString(16).padLeft(2, '0')).join());
    final got256 = ev("Packages.cn.hutool.core.util.HexUtil.encodeHexStr("
        "Packages.java.security.MessageDigest.getInstance('SHA-256').digest('abc'))");
    expect(got256, sha256.map((b) => b.toRadixString(16).padLeft(2, '0')).join());
  });

  test('HmacSHA256', () {
    final want = crypto.Hmac(crypto.sha256, utf8.encode('key')).convert(utf8.encode('msg')).bytes;
    final got = ev("Packages.cn.hutool.core.util.HexUtil.encodeHexStr("
        "Packages.javax.crypto.Mac.getInstance('HmacSHA256')"
        ".init(new Packages.javax.crypto.spec.SecretKeySpec([107,101,121],'HmacSHA256'))"
        ".doFinal('msg'))");
    expect(got, want.map((b) => b.toRadixString(16).padLeft(2, '0')).join());
  });

  test('AES/CBC/PKCS5Padding 加解密往返', () {
    final key = List<int>.generate(16, (i) => 48 + i);
    final iv = List<int>.generate(16, (i) => 65 + i);
    b64('key', key);
    b64('iv', iv);
    final kb = key.join(',');
    final ib = iv.join(',');
    final enc = ev("(function(){var c=Packages.javax.crypto.Cipher.getInstance('AES/CBC/PKCS5Padding');"
        "c.init(1,new Packages.javax.crypto.spec.SecretKeySpec([$kb]),"
        "new Packages.javax.crypto.spec.IvParameterSpec([$ib]));"
        "return Packages.cn.hutool.core.util.HexUtil.encodeHexStr(c.doFinal('hello world'));})()");
    expect(enc, isNotNull);
    // 回解
    final dec = ev("(function(){var c=Packages.javax.crypto.Cipher.getInstance('AES/CBC/PKCS5Padding');"
        "c.init(2,new Packages.javax.crypto.spec.SecretKeySpec([$kb]),"
        "new Packages.javax.crypto.spec.IvParameterSpec([$ib]));"
        "return Packages.java.lang.String(c.doFinal(Packages.cn.hutool.core.util.HexUtil.decodeHex('$enc')),'UTF-8');})()");
    expect(dec, 'hello world');
  });

  test('AES/GCM/NoPadding 加解密往返', () {
    final key = List<int>.filled(16, 7).join(',');
    final iv = List<int>.filled(12, 3).join(',');
    final enc = ev("(function(){var c=Packages.javax.crypto.Cipher.getInstance('AES/GCM/NoPadding');"
        "c.init(1,new Packages.javax.crypto.spec.SecretKeySpec([$key]),"
        "new Packages.javax.crypto.spec.GCMParameterSpec(128,[$iv]));"
        "return Packages.cn.hutool.core.util.HexUtil.encodeHexStr(c.doFinal('abcdef'));})()");
    expect(enc, isNotNull);
    final dec = ev("(function(){var c=Packages.javax.crypto.Cipher.getInstance('AES/GCM/NoPadding');"
        "c.init(2,new Packages.javax.crypto.spec.SecretKeySpec([$key]),"
        "new Packages.javax.crypto.spec.GCMParameterSpec(128,[$iv]));"
        "return Packages.java.lang.String(c.doFinal(Packages.cn.hutool.core.util.HexUtil.decodeHex('$enc')),'UTF-8');})()");
    expect(dec, 'abcdef');
  });

  test('BigInteger：补码/sign/modPow/toString', () {
    expect(ev("new Packages.java.math.BigInteger([255]).toString()"), '-1');
    expect(ev("new Packages.java.math.BigInteger([128]).toString()"), '-128');
    expect(ev("new Packages.java.math.BigInteger(255).toByteArray().join(',')"), '0,255');
    expect(ev("new Packages.java.math.BigInteger('5').modPow(new Packages.java.math.BigInteger('3'),"
        "new Packages.java.math.BigInteger('13')).toString()"), '8');
    expect(ev("new Packages.java.math.BigInteger('255').toString(16)"), 'ff');
    expect(ev("Packages.java.math.BigInteger.ONE.add(Packages.java.math.BigInteger.TEN).toString()"), '11');
    expect(ev("new Packages.java.math.BigInteger([1,0]).intValue()"), '256');
  });

  test('Arrays / ByteBuffer / ByteArrayOutputStream', () {
    expect(ev("Packages.java.util.Arrays.copyOf([1,2,3],5).join(',')"), '1,2,3,0,0');
    expect(ev("Packages.java.util.Arrays.copyOfRange([1,2,3,4],1,3).join(',')"), '2,3');
    expect(ev("Packages.java.util.Arrays.toString([1,2])"), '[1, 2]');
    expect(ev("(function(){var b=Packages.java.nio.ByteBuffer.allocate(8);b.put([1,2,3]);"
        "return b.array().join(',');})()"), '1,2,3,0,0,0,0,0');
    expect(ev("(function(){var o=new Packages.java.io.ByteArrayOutputStream();o.write([65,66]);o.write(67);"
        "return o.toString('UTF-8');})()"), 'ABC');
  });

  test('Charset / GBK 编解码', () {
    expect(ev("Packages.java.nio.charset.Charset.forName('GBK').name()"), 'GBK');
    expect(ev("new Packages.java.lang.String([196,227,186,195],'GBK')"), '你好');
    final gbkBytes = ev("Packages.java.nio.charset.Charset.forName('GBK').encode('你好')"
        ".array().join(',')");
    expect(gbkBytes, '196,227,186,195');
  });

  test('Inflater(raw) 与 GZIPInputStream', () {
    final raw = ZLibEncoder(raw: true).convert(utf8.encode('爽阅 reader'));
    final gz = gzip.encode(utf8.encode('爽阅 gzip'));
    b64('rawdeflate', raw);
    b64('gzip', gz);
    final rawJoin = raw.join(',');
    expect(
        ev("(function(){var i=new Packages.java.util.zip.Inflater(true);"
            "i.setInput([$rawJoin]);var out=new Array(64);var n=i.inflate(out);"
            "return n;})()"),
        isNotNull);
    expect(
        ev("(function(){var i=new Packages.java.util.zip.Inflater(true);"
            "i.setInput([$rawJoin]);var out=new Array(64);i.inflate(out);"
            "return Packages.java.lang.String(out,'UTF-8');})()"),
        '爽阅 reader');
    expect(
        ev("(function(){var s=new Packages.java.util.zip.GZIPInputStream("
            "new Packages.java.io.ByteArrayInputStream([${gz.join(',')}]));"
            "var b=new Array(64);var n=s.read(b,0,64);return n;})()"),
        isNotNull);
    expect(
        ev("(function(){var s=new Packages.java.util.zip.GZIPInputStream("
            "new Packages.java.io.ByteArrayInputStream([${gz.join(',')}]));"
            "var b=new Array(64);var n=s.read(b,0,64);"
            "return Packages.java.lang.String(b.slice(0,n),'UTF-8');})()"),
        '爽阅 gzip');
  });

  test('org.jsoup 选择器走宿主解析', () {
    const html = '<div id="a"><p class="x">hi</p><p class="x">yo</p><span>z</span></div>';
    final h = jsonEncode(html);
    expect(ev("Packages.org.jsoup.Jsoup.parse($h).select('.x').text()"), 'hi yo');
    expect(ev("Packages.org.jsoup.Jsoup.parse($h).select('p').size()"), '2');
    expect(ev("Packages.org.jsoup.Jsoup.parse($h).select('p').get(0).text()"), 'hi');
    expect(ev("Packages.org.jsoup.Jsoup.parse($h).select('#a').select('span').text()"), 'z');
    expect(ev("Packages.org.jsoup.Jsoup.parse($h).title()"), '');
  });

  test('jsoup：表格片段与字符串上的元素式调用', () {
    // `<tr>` 片段直接解析会被 HTML5 解析器丢弃 → 必须撑 table 外壳（若雨中文）
    const row = '<tr><td>0</td><td><a href="/Book/12/index.html">书名</a></td>'
        '<td>2</td><td>4</td><td>5</td></tr>';
    final r = jsonEncode(row);
    expect(ev("Packages.org.jsoup.Jsoup.parse($r).select('td').size()"), '5');
    expect(
        ev("Packages.org.jsoup.Jsoup.parse($r).select('td').get(1)"
            ".select('a').attr('href')"),
        '/Book/12/index.html');
    // `result` 是 outerHtml 字符串时，脚本仍可写 result.select(...)（legado 是 Element）
    expect(
        ev("(function(){var result=$r;"
            "return result.select('td').get(0).text();})()"),
        '0');
    expect(
        ev("(function(){var result=$r;"
            "return result.select('td').get(1).select('a').text();})()"),
        '书名');
  });

  test('source.setVariable 跨会话可见（持久层）', () async {
    final tmp = await Directory.systemTemp.createTemp('svars_js_');
    final prev = SourceVars.shared;
    SourceVars.shared =
        SourceVars(dirsOverride: AppDirs(files: tmp.path, cache: tmp.path));
    try {
      const url = 'https://example.com';
      final e1 = JsEnv(scopeKey: url, sourceUrl: url, session: JsSession());
      expect(
          JsBridge.evalCode("source.setVariable('token','v1'); 'ok'",
              env: e1),
          'ok');
      // 新会话（模拟「正文阶段另起一次操作」）仍能读到
      final e2 = JsEnv(scopeKey: url, sourceUrl: url, session: JsSession());
      expect(JsBridge.evalCode("source.getVariable('token')", env: e2), 'v1');
      // 其它书源读不到
      final e3 = JsEnv(
          scopeKey: 'https://other.com',
          sourceUrl: 'https://other.com',
          session: JsSession());
      expect(JsBridge.evalCode("source.getVariable('token')", env: e3), '');
      // 无参 getVariable() 返回全部变量的 JSON（聚合源 getArguments 靠它）
      final all = JsBridge.evalCode(
          "JSON.parse(source.getVariable())['token']", env: e1);
      expect(all, 'v1');
      // 没有任何变量时必须返回空串（聚合源靠 JSON.parse 抛错落回默认值）
      expect(JsBridge.evalCode("source.getVariable()", env: e3), '');
      // 缺失时可给默认值
      expect(
          JsBridge.evalCode("source.getVariable('nope','dft')", env: e1), 'dft');
      // 单参 setVariable 整体覆盖
      JsBridge.evalCode(
          "source.setVariable(JSON.stringify({a:'1',b:'2'}))", env: e1);
      expect(JsBridge.evalCode("source.getVariable('b')", env: e1), '2');
    } finally {
      SourceVars.shared = prev;
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    }
  });

  test('java.getCookie / cookie.setCookie / removeCookie 走 Cookie 仓库', () {
    final prev = LegadoCookieJar.shared;
    final jar = LegadoCookieJar();
    LegadoCookieJar.shared = jar;
    try {
      jar.setFor('https://a.com/', 'sid=S1; uid=U9');
      final env = JsEnv(
        scopeKey: 'https://a.com',
        sourceUrl: 'https://a.com',
        session: JsSession(),
        getCookie: (tag, key) => LegadoCookieJar.I.getFor(tag, key),
      );
      expect(JsBridge.evalCode("java.getCookie('https://a.com/')", env: env),
          contains('sid=S1'));
      expect(
          JsBridge.evalCode("java.getCookie('https://a.com/','uid')", env: env),
          'U9');
      // 跨站读不到
      expect(
          JsBridge.evalCode("java.getCookie('https://b.com/','uid')", env: env),
          '');
      // 写：脚本 setCookie → 仓库可见
      JsBridge.evalCode(
          "cookie.setCookie('https://a.com/','new=N9')", env: env);
      expect(jar.getFor('https://a.com/', 'new'), 'N9');
      // 删：removeCookie 清空该地址
      JsBridge.evalCode("cookie.removeCookie('https://a.com/')", env: env);
      expect(jar.getFor('https://a.com/'), '');
    } finally {
      LegadoCookieJar.shared = prev;
    }
  });

  test('System / UUID / Integer / StringBuilder', () {
    expect(ev("Packages.java.lang.System.currentTimeMillis() > 1600000000000"), 'true');
    expect(
        ev("(function(){var a=[0,0,0];Packages.java.lang.System.arraycopy([7,8,9],1,a,0,2);"
            "return a.join(',');})()"),
        '8,9,0');
    expect(ev("Packages.java.util.UUID.randomUUID().toString().length"), '36');
    expect(ev("Packages.java.lang.Integer.parseInt('ff',16)"), '255');
    expect(ev("(function(){var s=new Packages.java.lang.StringBuilder();s.append('a').append(1);return s.toString();})()"), 'a1');
  });

  test('importClass 后可裸用类名', () {
    expect(ev("(function(){var BigInteger=importClass(Packages.java.math.BigInteger);"
        "return BigInteger.ONE.toString();})()"), '1');
    expect(ev("(function(){var imp=new JavaImporter();"
        "return Packages.java.util.Arrays.toString([1]);})()"), '[1]');
  });

  // 上游 BaseSource 有三个「只在运行期存在」的键值方法，书源脚本靠它们跨卡片
  // 传状态：七猫聚合在 QMA.list 里 `source.put('qma_status', …)`，缺了会直接
  // TypeError: not a function（整个搜索变空）。
  test('source / book 的 put·get·remove（BaseSource 会话期键值）', () {
    const e = 'qma-put';
    expect(ev('typeof source.put', scope: e), 'function');
    expect(ev('typeof source.get', scope: e), 'function');
    expect(ev('typeof source.remove', scope: e), 'function');
    expect(ev('typeof book.put', scope: e), 'function');

    expect(ev("source.put('qma_status','搜索完成'); source.get('qma_status')",
        scope: e), '搜索完成');
    // 跨求值仍在（同一书源共用一个运行时）
    expect(ev("source.get('qma_status')", scope: e), '搜索完成');
    // 未设置返回 null（上游 putMap 语义）
    expect(ev("source.get('nope') === null", scope: e), 'true');
    // null / undefined 按空串存
    expect(ev("source.put('nil', null); source.get('nil')", scope: e), '');
    // remove 后回到 null
    expect(
        ev("source.remove('qma_status'); source.get('qma_status') === null",
            scope: e),
        'true');
    // book 与 source 是两张表，互不干扰
    ev("book.put('k','b1')", scope: e);
    expect(ev("source.get('k') === null", scope: e), 'true');
    expect(ev("book.get('k')", scope: e), 'b1');
  });

  // 上游 java.createSymmetricCrypto(transformation, key, iv) 返回 SymmetricCrypto，
  // 书源用它解接口密文 / 加密请求体（74小说网、书豪小说网、爱丽丝书屋…）。
  // 期望值来自 .NET Aes（独立实现，避免自证）。
  test('java.createSymmetricCrypto（AES CBC/ECB + PKCS5）', () {
    const k = '0123456789abcdef';
    const iv = 'abcdefghijklmnop';
    const cbc = 'LhWZ3icXB83uRhrCT+jm6DARZP2tvOQL15ifaUu+YvY=';
    expect(
        ev("java.createSymmetricCrypto('AES/CBC/PKCS5Padding','$k','$iv')"
            ".encryptBase64('shuangyue-legado')"),
        cbc);
    expect(
        ev("java.createSymmetricCrypto('AES/CBC/PKCS5Padding','$k','$iv')"
            ".decryptStr('$cbc')"),
        'shuangyue-legado');
    // 中文 → UTF-8 多字节
    expect(
        ev("java.createSymmetricCrypto('AES/CBC/PKCS5Padding','$k','$iv')"
            ".encryptBase64('斗破苍穹')"),
        'lDk4Bg7swad3ykkp2YoNCA==');
    // 只写 'AES' → Java Cipher.getInstance("AES") 默认 ECB/PKCS5Padding
    expect(
        ev("java.createSymmetricCrypto('AES','$k')"
            ".encryptBase64('shuangyue-legado')"),
        '/R5caNYTEKxxi6nkL6PRSDdyIuBhqSTFkc2cJ+oWPtQ=');
    // 十六进制输出 / 输入
    final hex = ev("java.createSymmetricCrypto('AES/CBC/PKCS5Padding','$k','$iv')"
        ".encryptHex('shuangyue-legado')");
    expect(hex!.length, 64);
    expect(
        ev("java.createSymmetricCrypto('AES/CBC/PKCS5Padding','$k','$iv')"
            ".decryptStr('$hex')"),
        'shuangyue-legado');
    // key/iv 也可以是字节数组（爱丽丝书屋：java.base64DecodeToByteArray(...)）
    expect(
        ev("java.createSymmetricCrypto('AES/CBC/PKCS5Padding',"
            "java.base64DecodeToByteArray('MDEyMzQ1Njc4OWFiY2RlZg=='),"
            "java.base64DecodeToByteArray('YWJjZGVmZ2hpamtsbW5vcA=='))"
            ".encryptBase64('shuangyue-legado')"),
        cbc);
    expect(ev("java.base64DecodeToByteArray('aGVsbG8=').join(',')"),
        '104,101,108,108,111');
  });

  test('java.deviceID / androidId 稳定，timeFormat 支持格式串', () {
    final id = ev('java.deviceID()');
    expect(id, isNotEmpty);
    expect(ev('java.androidId()'), id);
    expect(ev('java.deviceID()'), id);
    // timeFormat(t, format) 的第二参必须生效（原先被忽略）
    expect(ev("java.timeFormat(1700000000000,'yyyy')"), '2023');
    expect(ev("java.timeFormat(1700000000000,'yyyy-MM-dd').length"), '10');
  });

  test('source 登录态与 book 变量（持久层）', () async {
    final tmp = await Directory.systemTemp.createTemp('svars_login_');
    final prev = SourceVars.shared;
    SourceVars.shared =
        SourceVars(dirsOverride: AppDirs(files: tmp.path, cache: tmp.path));
    try {
      const url = 'https://login.example.com';
      String? e(String code) => JsBridge.evalCode(code,
          env: JsEnv(scopeKey: url, sourceUrl: url));
      expect(e('JSON.stringify(source.getLoginInfoMap())'), '{}');
      expect(e('source.getLoginHeader() === null'), 'true');
      e("source.putLoginInfo({user:'u1',pass:'p1'})");
      expect(e('source.getLoginInfoMap().user'), 'u1');
      // book 级变量：按 bookUrl 前缀落到书源变量表
      e("book.setVariable('durChapter','12')");
      expect(e("book.getVariable('durChapter')"), '12');
      expect(e("book.getVariable('nope','默认')"), '默认');
    } finally {
      SourceVars.shared = prev;
      await tmp.delete(recursive: true);
    }
  });
}
