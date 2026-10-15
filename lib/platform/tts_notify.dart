import 'dart:io';

import 'package:flutter/services.dart';

/// Android 锁屏听书：前台服务 + 通知栏控制（上一段 / 暂停 / 下一段 / 停止）。
///
/// 非 Android 平台全部为 no-op —— 调用方无需自己判断平台。
class TtsNotify {
  TtsNotify._();

  static const MethodChannel _channel =
      MethodChannel('dev.reader.novel_reader/tts_notify');

  /// 仅 Android 提供锁屏听书；其他平台所有方法 no-op。
  static bool supported = Platform.isAndroid;

  /// 通知栏动作回调：'prev' / 'toggle' / 'next' / 'stop'。
  static void Function(String action)? onAction;

  static bool _bound = false;

  static void _bind() {
    if (_bound || !supported) return;
    _bound = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'action') {
        final a = call.arguments?.toString();
        if (a != null) TtsNotify.onAction?.call(a);
      }
      return null;
    });
  }

  /// Android 13+ 通知权限（用户拒绝也不影响 App 内听书，只是没有锁屏控制）。
  static Future<void> requestPermission() async {
    if (!supported) return;
    _bind();
    try {
      await _channel.invokeMethod<void>('requestPermission');
    } catch (_) {}
  }

  /// 显示 / 更新「正在朗读」通知（同一条原地更新）。
  static Future<void> show({
    required String title,
    required String text,
    required bool playing,
  }) async {
    if (!supported) return;
    _bind();
    try {
      await _channel.invokeMethod<void>('show', {
        'title': title,
        'text': text,
        'playing': playing,
      });
    } catch (_) {}
  }

  /// 结束听书：撤下通知并停掉前台服务。
  static Future<void> hide() async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<void>('hide');
    } catch (_) {}
  }
}
