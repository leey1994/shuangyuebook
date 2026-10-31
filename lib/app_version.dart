// 运行时版本号：以安装包为准（Android PackageManager / 构建设置），
// 不再只信编译期 --dart-define。
//
// 背景：本地 `flutter build apk` 不带 --dart-define=APP_VERSION 时，
// 安装器显示 1.0.5、关于页却显示 1.0.0，更新检查还会把当前版本判成旧版。
// Android 直接问系统要 versionName；其他平台回退到构建注入值。
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 编译期注入的版本（CI 会传 --dart-define=APP_VERSION=X.Y.Z+B）。
/// 运行时以安装包 versionName 优先，见 [AppVersion.load]。
const String kAppVersion =
    String.fromEnvironment('APP_VERSION', defaultValue: '1.0.0');

class AppVersion {
  AppVersion._();

  static const MethodChannel _channel =
      MethodChannel('dev.reader.novel_reader/native');

  /// versionName（如 1.0.5）。
  static String name = kAppVersion;

  /// versionCode（构建号）；0 = 未知。
  static int code = 0;

  /// 关于页显示用：只显示 versionName，避免和安装器/系统设置里的版本对不上。
  static String get display => name;

  static Future<void> load() async {
    if (kIsWeb) return;
    try {
      final r = await _channel.invokeMapMethod<String, dynamic>('getAppVersion');
      final n = r?['name']?.toString().trim() ?? '';
      final c = int.tryParse(r?['code']?.toString() ?? '') ?? 0;
      if (n.isNotEmpty) name = n;
      if (c > 0) code = c;
    } catch (_) {
      // 非 Android / 通道未注册：保留构建注入值
    }
  }
}
