import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuangyue/data/font_store.dart';
import 'package:shuangyue/store.dart';

/// 网络字体：清单自检 + 「没下载就不该把家族名塞给正文」的降级行为。
///
/// 这里**不联网**：ensure() 只验证清单外的 id 直接返回 false，
/// 下载流程靠人工/真机验收（字体文件 8~13MB，不适合进单测）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('字体清单', () {
    test('id / 家族名唯一，地址是 https 且有备用镜像', () {
      final ids = kRemoteFonts.map((f) => f.id).toList();
      final families = kRemoteFonts.map((f) => f.family).toList();
      expect(ids.toSet().length, ids.length);
      expect(families.toSet().length, families.length);
      for (final f in kRemoteFonts) {
        expect(f.urls, isNotEmpty);
        expect(f.urls.length, greaterThanOrEqualTo(2), reason: '${f.id} 缺备用镜像');
        for (final u in f.urls) {
          expect(u.startsWith('https://'), isTrue, reason: u);
        }
        // Flutter 的 FontLoader 不认 woff2，必须是裸字体文件
        expect(u8ext(f.urls.first), anyOf('otf', 'ttf'), reason: f.id);
        expect(f.bytes, greaterThan(1024 * 1024));
        expect(f.name, isNotEmpty);
        expect(f.sizeLabel, endsWith('MB'));
        expect(f.family, startsWith('sy_'), reason: '要避开系统同名字体');
      }
    });

    test('byId 命中与未命中', () {
      expect(FontStore.byId(kRemoteFonts.first.id)?.name, kRemoteFonts.first.name);
      expect(FontStore.byId(''), isNull);
      expect(FontStore.byId('not_a_font'), isNull);
    });

    test('字体头字节校验：TTF / OTF / true / ttcf 通过，其它拒绝', () {
      Uint8List head(List<int> h) =>
          Uint8List.fromList([...h, ...List<int>.filled(2048, 0)]);
      expect(FontStore.looksLikeFont(head([0, 1, 0, 0])), isTrue);
      expect(FontStore.looksLikeFont(head([0x4F, 0x54, 0x54, 0x4F])), isTrue);
      expect(FontStore.looksLikeFont(head([0x74, 0x72, 0x75, 0x65])), isTrue);
      expect(FontStore.looksLikeFont(head([0x74, 0x74, 0x63, 0x66])), isTrue);
      // HTML 错误页 / 空文件 / 太短
      expect(FontStore.looksLikeFont(head([0x3C, 0x21, 0x44, 0x4F])), isFalse);
      expect(FontStore.looksLikeFont(Uint8List.fromList([0, 1, 0, 0])), isFalse);
      expect(FontStore.looksLikeFont(Uint8List(0)), isFalse);
    });
  });

  group('未下载时的降级', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('sy_font_');
      FontStore.I.debugSetDir(tmp);
    });

    tearDown(() async {
      FontStore.I.debugSetDir(null);
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('activeFont：空 id / 未知 id / 未下载的 id 都返回 null', () {
      expect(FontStore.I.activeFont(''), isNull);
      expect(FontStore.I.activeFont('not_a_font'), isNull);
      for (final f in kRemoteFonts) {
        expect(FontStore.I.activeFont(f.id), isNull);
        expect(FontStore.I.isReady(f.id), isFalse);
        expect(FontStore.I.statusOf(f.id), FontStatus.idle);
      }
    });

    test('fileOf：还没下载时是 null，且不会自己创建文件', () async {
      for (final f in kRemoteFonts) {
        expect(await FontStore.I.fileOf(f), isNull);
      }
    });

    test('ensure：清单外的 id 直接 false，不走网络', () async {
      expect(await FontStore.I.ensure('not_a_font'), isFalse);
      expect(await FontStore.I.ensure(''), isFalse);
    });

    test('warmUpSelected：空 id 什么也不做', () async {
      FontStore.I.warmUpSelected('');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      for (final f in kRemoteFonts) {
        expect(FontStore.I.statusOf(f.id), FontStatus.idle);
      }
    });
  });

  group('阅读偏好', () {
    test('默认跟随系统字体，「字体」并进排版签名', () async {
      SharedPreferences.setMockInitialValues({});
      AppStore.I.inited = false;
      await AppStore.I.init();
      final prefs = AppStore.I.prefs;
      expect(prefs.fontFamily, '');
      final before = prefs.layoutSignature;
      AppStore.I.setFontFamily('noto_serif_sc');
      expect(AppStore.I.prefs.fontFamily, 'noto_serif_sc');
      expect(AppStore.I.prefs.layoutSignature, isNot(before),
          reason: '换字体必须触发重排');
      // 落盘：重新读一次还在
      final sp = await SharedPreferences.getInstance();
      expect(sp.getString('fontFamily'), 'noto_serif_sc');
      AppStore.I.setFontFamily('');
      expect(AppStore.I.prefs.layoutSignature, before);
    });
  });
}

/// 取地址的扩展名（忽略 query）。
String u8ext(String url) {
  final path = Uri.parse(url).path;
  final dot = path.lastIndexOf('.');
  return dot < 0 ? '' : path.substring(dot + 1).toLowerCase();
}
