// Release 资产挑选的回归测试。
//
// v1.0.3 起安卓按 ABI 拆包（arm64-v8a / armeabi-v7a），而更新逻辑原来是
// 「assets 里第一个 .apk 就是它」—— 两个包同时挂上去，第一个恰好是 32 位包时
// 64 位机就会装到错架构的包（Android 14 起部分机型直接 32 位不支持，
// 表现是「解析软件包时出现问题」）。这里把挑选规则钉死。
import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/update_check.dart';

void main() {
  group('资产文件名 → 架构标记', () {
    test('拆包命名', () {
      expect(assetAbiTag('shuangyue-v1.0.3+9-arm64-v8a.apk'), 'arm64');
      expect(assetAbiTag('shuangyue-v1.0.3+9-armeabi-v7a.apk'), 'arm');
      expect(assetAbiTag('shuangyue-v1.0.3+9-x86_64.apk'), 'x64');
      // x86_64 里含 "x86"：顺序错了就会判成 32 位 x86
      expect(assetAbiTag('app-x86-release.apk'), 'x86');
    });

    test('通用包 / 老命名不带标记', () {
      expect(assetAbiTag('novel_reader_android.apk'), '');
      expect(assetAbiTag('shuangyue-v1.0.3+9-universal.apk'), '');
    });
  });

  group('按设备架构挑 APK', () {
    const arm64 = ('shuangyue-v1.0.3+9-arm64-v8a.apk', 'u/arm64');
    const v7a = ('shuangyue-v1.0.3+9-armeabi-v7a.apk', 'u/v7a');

    test('64 位设备拿到 arm64 包（与上传顺序无关）', () {
      expect(pickApkUrl([v7a, arm64], 'arm64'), 'u/arm64');
      expect(pickApkUrl([arm64, v7a], 'arm64'), 'u/arm64');
    });

    test('32 位设备拿到 armeabi-v7a 包', () {
      expect(pickApkUrl([arm64, v7a], 'arm'), 'u/v7a');
      expect(pickApkUrl([v7a, arm64], 'arm'), 'u/v7a');
    });

    test('通用包优先于架构不匹配的包', () {
      const uni = ('novel_reader_android.apk', 'u/uni');
      expect(pickApkUrl([arm64, uni], 'arm'), 'u/uni');
      expect(pickApkUrl([v7a, uni], 'arm64'), 'u/uni');
    });

    test('同架构仍然压过通用包', () {
      const uni = ('novel_reader_android.apk', 'u/uni');
      expect(pickApkUrl([uni, arm64], 'arm64'), 'u/arm64');
    });

    test('架构未知 / 全都对不上时仍给一个下载入口', () {
      expect(pickApkUrl([arm64, v7a], null), 'u/arm64');
      expect(pickApkUrl([arm64], 'x86'), 'u/arm64');
      expect(pickApkUrl([], 'arm64'), isNull);
    });
  });

  group('版本比较', () {
    test('tag 前缀 / 构建号 / 分段数值', () {
      expect(compareVersion('v1.0.3', '1.0.2'), 1);
      expect(compareVersion('1.0.3+9', '1.0.3'), 0);
      expect(compareVersion('1.0.10', '1.0.9'), 1);
      expect(compareVersion('1.0', '1.0.1'), -1);
    });
  });
}
