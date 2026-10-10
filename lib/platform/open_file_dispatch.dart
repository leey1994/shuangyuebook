// 外部「打开方式」进来的文件分派。
//
// 一份文件被系统丢给爽阅时，按扩展名决定去哪：
//   txt / epub → 导入书架并直接进阅读器
//   json       → 按「阅读 3.0」书源导入
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../legado/source_store.dart';
import '../pet/pet_event.dart';
import '../pet/pet_store.dart';
import '../screens/reader_screen.dart';
import '../store.dart';
import 'open_file_service.dart';

/// 挂上文件打开处理（在 App 就绪处调用一次）。
///
/// [context] 只用于启动瞬间取一次 Navigator；真正的分派全程用
/// [NavigatorState]，避免跨异步间隙持有 BuildContext。
void installOpenFileHandler(BuildContext context) {
  final svc = OpenFileService.instance;
  // 立刻抓一次 NavigatorState：之后全程用它，不再跨异步间隙碰 BuildContext
  final navigator = Navigator.of(context);
  svc.onOpenFile = (path) => _dispatch(navigator, path);
  svc.listen();
  // 冷启动：主动取一次（原生侧存着启动时那个路径）
  unawaited(svc.consumeLaunchFile().then((p) {
    if (p != null && p.isNotEmpty) _dispatch(navigator, p);
  }));
}

Future<void> _dispatch(NavigatorState navigator, String path) async {
  final ext = _ext(path);
  switch (ext) {
    case 'txt':
    case 'epub':
      final ok = await AppStore.I.importLocalBook(path);
      if (!navigator.mounted) return;
      PetStore.I.emit(PetAction.openExternal);
      ScaffoldMessenger.of(navigator.context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(ok ? '已导入书架' : '已在书架，或无法解析')));
      if (!ok) return;
      // 导入后直接进阅读器
      final entry = AppStore.I.shelfEntry(path);
      if (entry != null) {
        navigator.push(MaterialPageRoute<void>(
          builder: (_) => ReaderScreen(book: entry.book),
        ));
      }

    case 'json':
      final store = SourceStore.shared;
      if (store == null) {
        _snack(navigator, '书源仓库还没准备好，请稍后再试');
        return;
      }
      final report = await store.importFromFile(path);
      if (report.hasAny) PetStore.I.emit(PetAction.sourceImport);
      _snack(navigator, '书源导入：${report.summary}');

    default:
      _snack(navigator, '暂不支持的文件类型：.${_ext(path)}');
  }
}

void _snack(NavigatorState n, String m) {
  if (!n.mounted) return;
  ScaffoldMessenger.of(n.context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(m)));
}

String _ext(String path) {
  final i = path.lastIndexOf('.');
  return i < 0 ? '' : path.substring(i + 1).toLowerCase();
}

/// 是否有可导入的本地书文件（导入页用它做拖拽/粘贴判断）。
bool isImportableBook(String path) {
  final e = _ext(path);
  return e == 'txt' || e == 'epub';
}

/// 供 CLI / 测试用：直接判断文件是否存在且可读。
bool readableFile(String path) {
  try {
    return File(path).existsSync();
  } catch (_) {
    return false;
  }
}
