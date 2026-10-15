// 「用爽阅打开」文件关联服务。
//
// 背景：在文件管理器里打开 .txt / .epub / .json 时，系统的「打开方式」里
// 应该有爽阅。两条链路接收：
//   - **冷启动**：系统带 VIEW intent 拉起 App → 原生先存住路径，
//     Dart 就绪后用 [consumeLaunchFile] 取走；
//   - **热启动**（App 已在后台）：原生通过 EventChannel 推送。
//
// 通道与 native 通道必须分开：Flutter 的 setMethodCallHandler 在同一通道上
// 后设置会覆盖先设置，两处共用会互相打断。
import 'dart:async';

import 'native_bridge.dart';

/// 文件打开回调：交给 UI 层按扩展名分派。
typedef OpenFileHandler = Future<void> Function(String path);

class OpenFileService {
  OpenFileService._();

  static final OpenFileService instance = OpenFileService._();

  bool _listening = false;
  StreamSubscription<String>? _sub;

  /// 业务回调（在 App 就绪处挂上）。
  OpenFileHandler? onOpenFile;

  /// 开始监听热启动事件。
  void listen() {
    if (_listening) return;
    _listening = true;
    _sub = NativeBridge.fileOpened.listen((path) {
      unawaited(onOpenFile?.call(path));
    });
  }

  /// 取走冷启动时系统传入的文件路径（取后失效）；没有则返回 null。
  Future<String?> consumeLaunchFile() => NativeBridge.takeLaunchFile();

  void dispose() {
    _sub?.cancel();
    _sub = null;
    _listening = false;
  }
}
