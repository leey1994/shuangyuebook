// 爽阅 Windows 更新器（独立进程，随包发布放置在主程序同目录）。
//
// 职责收敛：多镜像流式下载 → 解压校验 → 等主程序退出 → 整体换装 → 重启主程序。
// UI 进程只负责点确认并拉起本进程（detached）后退出 —— 下载/替换全程与 UI 无关。
//
// 用法（--appdir/--appexe 必传，其余为镜像下载地址，http(s)/file 均可）：
//   updater.exe --appdir <运行目录> --appexe novel_reader.exe <url1> [url2] …
//
// 关键设计：
//  - 启动即把自身复制到 %TEMP% 再由副本接管：否则运行目录里的 updater.exe
//    被自己锁住，新包里的 updater.exe 永远替换不进去。
//  - 换装走「先整批改名 _old → 搬新文件 → 删 _old」而不是逐文件覆盖：
//    任一文件被锁只会让那一步失败重试，不会留下新旧混杂的半成品；
//    失败可整体回滚。
//  - 全程写运行目录 updater.log；任何失败都尝试把旧文件拉回来并重启旧版，
//    绝不把用户留在打不开的状态。
import 'dart:io';
import 'package:archive/archive.dart';

void _log(String dir, String msg) {
  try {
    File('$dir/updater.log').writeAsStringSync(
        '${DateTime.now().toIso8601String()}  $msg\n',
        mode: FileMode.append);
  } catch (_) {}
}

/// rename 移动条目（文件/目录均适用，同盘原子）；被锁直接抛异常由调用方重试。
void _move(FileSystemEntity e, String to) {
  e.renameSync(to);
}

void main(List<String> rawArgs) async {
  var appDir = '';
  var appExe = '';
  final urls = <String>[];
  for (final a in rawArgs) {
    if (a.startsWith('--appdir=')) {
      appDir = a.substring(9);
    } else if (a.startsWith('--appexe=')) {
      appExe = a.substring(9);
    } else if (a.startsWith('http') || a.startsWith('file:')) {
      urls.add(a);
    }
  }
  // 说明：换装采用「整批改名 _old → 搬入新文件」二段式，运行中的更新器自身
  // 会随旧文件一起挪出后再让新包覆盖，天然无自锁 —— 无需 TEMP 自复制桥
  // （顺带避开杀软对「exe 自复制到 TEMP 再拉起」的误伤特征）。
  _log(appDir, '启动，${urls.length} 条镜像，target=$appDir/$appExe');
  try {
    if (appDir.isEmpty || appExe.isEmpty || urls.isEmpty) {
      throw Exception('参数不完整');
    }
    _sweepStale(appDir);
    final stageRoot = Directory(
        '${Directory.systemTemp.path}/shuangyue_update');
    if (!stageRoot.existsSync()) stageRoot.createSync(recursive: true);
    final tmpZip = File(
        '${stageRoot.path}/shuangyue_update_${DateTime.now().millisecondsSinceEpoch}.zip');

    // 1. 逐镜像下载
    var ok = false;
    for (final url in urls) {
      try {
        _log(appDir, '下载 $url');
        if (url.startsWith('file:')) {
          final src = File(Uri.parse(url).toFilePath());
          tmpZip.writeAsBytesSync(src.readAsBytesSync());
        } else {
          final c = HttpClient()
            ..connectionTimeout = const Duration(seconds: 30)
            ..autoUncompress = false;
          final rq = await c.getUrl(Uri.parse(url));
          final rs = await rq.close().timeout(const Duration(seconds: 60));
          if (rs.statusCode != 200) {
            throw Exception('HTTP ${rs.statusCode}');
          }
          final sink = tmpZip.openWrite();
          await rs.pipe(sink);
          c.close();
        }
        final len = tmpZip.lengthSync();
        if (len < 1024 * 1024) {
          throw Exception('内容过小（$len 字节），疑似错误页/截断');
        }
        ok = true;
        _log(appDir, '下载完成 ${len} 字节');
        break;
      } catch (e) {
        _log(appDir, '线路失败：$e');
        try {
          if (tmpZip.existsSync()) tmpZip.deleteSync();
        } catch (_) {}
      }
    }
    if (!ok) throw Exception('所有下载线路都失败了');

    // 2. 解压校验（CRC 随解压失败抛出）
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final stage = Directory('${appDir}_update_$stamp');
    if (stage.existsSync()) stage.deleteSync(recursive: true);
    stage.createSync(recursive: true);
    final zip = ZipDecoder().decodeBytes(tmpZip.readAsBytesSync());
    for (final f in zip.files) {
      if (!f.isFile) continue;
      final out = File('${stage.path}/${f.name}');
      out.parent.createSync(recursive: true);
      out.writeAsBytesSync(f.content as List<int>);
    }
    if (!File('${stage.path}/$appExe').existsSync()) {
      throw Exception('压缩包里没有 $appExe，解压不完整');
    }
    try {
      tmpZip.deleteSync();
    } catch (_) {}
    _log(appDir, '解压完成，共 ${zip.files.length} 个文件');

    // 3. 等主程序退出：旧 exe 不可写时 rename 会抛 → 重试至多 60 秒
    final oldDir = Directory('$appDir._old_$stamp');
    if (oldDir.existsSync()) oldDir.deleteSync(recursive: true);
    oldDir.createSync();
    var movedAll = false;
    for (var t = 0; t < 60; t++) {
      try {
        final outOfWay = <String, bool>{};
        for (final e in Directory(appDir).listSync()) {
          final n = e.path.split(RegExp(r'[/\\]')).last;
          if (n == 'updater.log' || outOfWay[n] == true) continue;
          _move(e, '${oldDir.path}/$n');
          outOfWay[n] = true;
        }
        movedAll = true;
        break;
      } catch (_) {
        sleep(const Duration(seconds: 1));
      }
    }
    if (!movedAll) throw Exception('主程序迟迟未退出，旧文件保留原状');
    _log(appDir, '旧文件已整体换出');

    // 4. 搬入新文件
    for (final e in Directory(stage.path).listSync()) {
      final n = e.path.split(RegExp(r'[/\\]')).last;
      _move(e, '$appDir/$n');
    }
    stage.deleteSync(recursive: true);
    _log(appDir, '新文件就位');

    // 5. 延迟清 _old（FAILED 新文件缺失等异常时可用于人工恢复）
    _log(appDir, '收尾：删除备份目录');
    _cleanupOld(oldDir);
    _log(appDir, '更新完成，重启 $appExe');
    await Process.start('$appDir/$appExe', [], workingDirectory: appDir,
            mode: ProcessStartMode.detached)
        .then((_) {});
    exit(0);
  } catch (e) {
    _log(appDir, '更新失败：$e');
    // 尽力把旧文件搬回来
    final parent = Directory(appDir).parent;
    final oldDirs = parent
        .listSync()
        .whereType<Directory>()
        .where((d) => d.path.startsWith('$appDir._old_'))
        .toList();
    for (final old in oldDirs) {
      try {
        for (final e in old.listSync()) {
          final n = e.path.split(RegExp(r'[/\\]')).last;
          _move(e, '$appDir/$n');
        }
        _log(appDir, '已从 ${old.path} 恢复旧版本文件');
        old.deleteSync(recursive: true);
        break;
      } catch (_) {}
    }
    final exe = File('$appDir/$appExe');
    if (exe.existsSync()) {
      try {
        await Process.start(exe.path, [], workingDirectory: appDir,
                mode: ProcessStartMode.detached)
            .then((_) {});
        _log(appDir, '已恢复启动旧版本');
      } catch (_) {}
    }
    exit(1);
  }
}

/// 启动清扫：上次更新的残留（备份目录 / 半截下载）能删就删。
void _sweepStale(String appDir) {
  final parent = Directory(appDir).parent;
  for (final e in parent.listSync()) {
    if (e is Directory) {
      final n = e.path.split(RegExp(r'[/\\]')).last;
      if (n.startsWith('${appDir.split(RegExp(r'[/\\]')).last}._old_')) {
        try {
          e.deleteSync(recursive: true);
          _log(appDir, '清扫残留备份 $n');
        } catch (_) {}
      }
    }
  }
}

/// 换装成功后的备份目录清理：10 秒内删不干净就留给下次（下次换新版本时清理）。
void _cleanupOld(Directory oldDir) {
  var done = false;
  for (var t = 0; t < 10; t++) {
    try {
      oldDir.deleteSync(recursive: true);
      done = true;
      break;
    } catch (_) {
      sleep(const Duration(seconds: 1));
    }
  }
  if (!done) {
    // 删不干净说明有文件仍被占用：改随缘（下次更新器运行时会清 .old_ 残留）
    _log(oldDir.parent.path, '备份目录暂时删不掉，留待下次清理');
  }
}
