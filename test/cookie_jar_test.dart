// Cookie 仓库（对齐 legado CookieManager）的行为测试：域/路径匹配、过期、
// Secure、脚本 API（java.getCookie / cookie.setCookie / cookie.removeCookie）、落盘。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/legado/cookie_jar.dart';
import 'package:shuangyue/platform/native_bridge.dart';

void main() {
  group('LegadoCookieJar', () {
    test('吸收 Set-Cookie 并按主机回填请求头', () {
      final jar = LegadoCookieJar();
      jar.absorb(Uri.parse('https://a.com/x/y'), {
        'set-cookie': 'sid=abc; Path=/; HttpOnly',
      });
      expect(jar.headerFor(Uri.parse('https://a.com/')), 'sid=abc');
      // 别的站拿不到
      expect(jar.headerFor(Uri.parse('https://b.com/')), isNull);
    });

    test('Domain 子域可见，hostOnly 不外泄', () {
      final jar = LegadoCookieJar();
      jar.absorb(Uri.parse('https://www.a.com/'), {
        'set-cookie': 'wide=1; Domain=.a.com; Path=/',
      });
      jar.absorb(Uri.parse('https://www.a.com/'), {
        'set-cookie': 'narrow=2; Path=/',
      });
      expect(jar.headerFor(Uri.parse('https://m.a.com/')), 'wide=1');
      expect(jar.headerFor(Uri.parse('https://www.a.com/')), contains('narrow=2'));
      expect(jar.headerFor(Uri.parse('https://www.b.com/')), isNull);
    });

    test('多条 Set-Cookie（Expires 里含逗号）能正确拆分', () {
      final jar = LegadoCookieJar();
      jar.absorb(Uri.parse('https://a.com/'), {
        'set-cookie': 'a=1; Expires=Wed, 21 Oct 2099 07:28:00 GMT, b=2; Path=/',
      });
      final h = jar.headerFor(Uri.parse('https://a.com/'))!;
      expect(h, contains('a=1'));
      expect(h, contains('b=2'));
    });

    test('Max-Age=0 / 空值 即删除', () {
      final jar = LegadoCookieJar();
      jar.absorb(Uri.parse('https://a.com/'), {'set-cookie': 'k=v'});
      expect(jar.headerFor(Uri.parse('https://a.com/')), 'k=v');
      jar.absorb(Uri.parse('https://a.com/'), {'set-cookie': 'k=; Max-Age=0'});
      expect(jar.headerFor(Uri.parse('https://a.com/')), isNull);
    });

    test('过期时间已过的 Cookie 不会被带上', () {
      final jar = LegadoCookieJar();
      jar.absorb(Uri.parse('https://a.com/'), {
        'set-cookie': 'old=1; Expires=Wed, 21 Oct 2015 07:28:00 GMT',
      });
      expect(jar.headerFor(Uri.parse('https://a.com/')), isNull);
    });

    test('Secure 只对 https 生效', () {
      final jar = LegadoCookieJar();
      jar.absorb(Uri.parse('https://a.com/'), {'set-cookie': 's=1; Secure'});
      expect(jar.headerFor(Uri.parse('https://a.com/')), 's=1');
      expect(jar.headerFor(Uri.parse('http://a.com/')), isNull);
    });

    test('路径匹配：/foo 不匹配 /foobar', () {
      final jar = LegadoCookieJar();
      jar.setFor('https://a.com/foo/bar', 'p=1');
      // setFor 用默认路径 /foo
      expect(jar.headerFor(Uri.parse('https://a.com/foo/baz')), 'p=1');
      expect(jar.headerFor(Uri.parse('https://a.com/foobar')), isNull);
    });

    test('脚本 API：setFor / getFor(带 key) / removeFor', () {
      final jar = LegadoCookieJar();
      jar.setFor('https://a.com/', 'token=T1; uid=U9');
      expect(jar.getFor('https://a.com/'), 'token=T1; uid=U9');
      expect(jar.getFor('https://a.com/', 'token'), 'T1');
      expect(jar.getFor('https://a.com/', 'nope'), '');
      jar.removeFor('https://a.com/');
      expect(jar.getFor('https://a.com/'), '');
      expect(jar.length, 0);
    });

    test('落盘后新实例能读到（模拟重启）', () async {
      final dir = await Directory.systemTemp.createTemp('cookie_jar_test_');
      final dirs = AppDirs(files: dir.path, cache: dir.path);
      final a = LegadoCookieJar(dirsOverride: dirs);
      a.absorb(Uri.parse('https://a.com/'), {'set-cookie': 'sid=persist'});
      await a.flush();

      final b = LegadoCookieJar(dirsOverride: dirs);
      await b.load();
      expect(b.loaded, isTrue);
      expect(b.headerFor(Uri.parse('https://a.com/')), 'sid=persist');
      b.clear();
      await b.flush();

      final c = LegadoCookieJar(dirsOverride: dirs);
      await c.load();
      expect(c.headerFor(Uri.parse('https://a.com/')), isNull);
      await dir.delete(recursive: true);
    });

    test('数量上限：超出后淘汰最老，不无限增长', () {
      final jar = LegadoCookieJar();
      for (var i = 0; i < LegadoCookieJar.maxCookies + 20; i++) {
        jar.setFor('https://a.com/', 'k$i=$i');
      }
      expect(jar.length, lessThanOrEqualTo(LegadoCookieJar.maxCookies));
    });
  });
}
