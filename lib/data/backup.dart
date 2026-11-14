// 数据备份 / 恢复：书架、阅读进度、书签、偏好、书源、变量、阅读统计。
//
// 为什么要做：这些数据全在 SharedPreferences 与应用私有目录里，卸载 / 换机
// 就没了；「阅读 3.0」的备份是一个 zip，我们只做单文件 JSON —— 够用、可读、
// 不引新依赖（archive 只在 EPUB 里用）。
//
// 备份目录故意放在用户可见的地方（Android: Documents/爽阅备份，
// 桌面: 文档/爽阅备份）：卸载重装后备份还在，恢复时直接从这里列文件。
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../legado/models.dart';
import '../legado/source_store.dart';
import '../legado/source_vars.dart';
import '../store.dart';
import 'stats_store.dart';

/// 恢复结果（[error] 非空表示整体失败，其余计数仅作提示）。
class BackupReport {
  const BackupReport({this.error, this.prefs = 0, this.sources = 0});

  final String? error;
  final int prefs;
  final int sources;
}

/// 备份文件读写。全部走 JSON，一个文件装下所有用户数据。
abstract final class BackupService {
  static const String appTag = 'shuangyue';
  static const int formatVersion = 1;

  static const String _prefix = 'shuangyue_backup_';

  /// 不进备份的敏感键：备份文件落在用户可见的文档目录（还可能被网盘同步），
  /// LLM 的明文 API Key 不能跟着走。恢复时同样跳过 —— 既不覆盖本机已配置的
  /// Key，也不让来路不明的备份把 Key 塞进来。
  static const Set<String> _sensitiveKeys = {'llmApiKey'};

  /// 仅测试用：指定备份目录，跳过 path_provider。
  static Directory? debugDir;

  /// 用户可见的备份目录。
  static Future<Directory> dir() async {
    final override = debugDir;
    if (override != null) {
      if (!await override.exists()) await override.create(recursive: true);
      return override;
    }
    Directory d;
    if (Platform.isAndroid) {
      d = Directory('/storage/emulated/0/Documents/爽阅备份');
    } else {
      final base = await getApplicationDocumentsDirectory();
      d = Directory('${base.path}${Platform.pathSeparator}爽阅备份');
    }
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// 汇总全部用户数据（导出 / WebDAV / 局域网备份共用同一份口径）。
  /// 敏感键（llmApiKey）不进备份 —— 见 [_sensitiveKeys]。
  static Future<Map<String, dynamic>> collect() async {
    final prefs = <String, dynamic>{};
    final sp = AppStore.I.sp;
    if (sp != null) {
      for (final k in sp.getKeys()) {
        if (_sensitiveKeys.contains(k)) continue; // 明文密钥不落备份
        final v = sp.get(k);
        if (v != null) prefs[k] = v;
      }
    }
    final store = SourceStore.shared;
    return <String, dynamic>{
      'app': appTag,
      'version': formatVersion,
      'createdAt': DateTime.now().toIso8601String(),
      'prefs': prefs,
      'sources': [for (final s in store?.sources ?? const <BookSource>[]) s.toJson()],
      'vars': SourceVars.I.snapshot(),
      'stats': StatsStore.I.toJsonMap(),
    };
  }

  /// 导出全部用户数据，返回写好的文件。
  static Future<File> export() async {
    final data = await collect();
    final d = await dir();
    final f = File('${d.path}${Platform.pathSeparator}$_prefix${_stamp(DateTime.now())}.json');
    await f.writeAsString(jsonEncode(data), flush: true);
    return f;
  }

  /// 目录里已有的备份，最新在前。
  static Future<List<File>> list() async {
    final d = await dir();
    final files = <File>[];
    await for (final e in d.list()) {
      if (e is File &&
          e.uri.pathSegments.last.startsWith(_prefix) &&
          e.path.endsWith('.json')) {
        files.add(e);
      }
    }
    files.sort((a, b) => b.path.compareTo(a.path)); // 文件名带时间戳
    return files;
  }

  /// 恢复：prefs 整表替换，书源按 url 合并（同 url 覆盖），变量 / 统计整表替换。
  static Future<BackupReport> restore(File f) async =>
      restoreFromText(await f.readAsString());

  /// 从备份 JSON 文本恢复（WebDAV 云端恢复 / 局域网导入用同一条链路）。
  static Future<BackupReport> restoreFromText(String text) async {
    Map<String, dynamic> data;
    try {
      data = jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {
      return const BackupReport(error: '不是有效的备份文件');
    }
    if (data['app'] != appTag) {
      return const BackupReport(error: '这不是爽阅的备份文件');
    }
    if (((data['version'] as num?)?.toInt() ?? 0) > formatVersion) {
      return const BackupReport(error: '备份来自更新版本，请先升级应用');
    }

    var prefCount = 0;
    final rawPrefs = data['prefs'];
    final sp = AppStore.I.sp;
    if (sp != null && rawPrefs is Map) {
      // 整表替换：备份里没有的键（比如上次阅读残留的 progress:*）应当消失。
      // 但敏感键（本机 API Key）不进备份，clear() 会把本机配置一起抹掉 ——
      // 先留一份，恢复完再写回去，做到「既不导出也不覆盖」。
      final kept = <String, Object>{};
      for (final k in _sensitiveKeys) {
        final v = sp.get(k);
        if (v != null) kept[k] = v;
      }
      await sp.clear();
      for (final e in rawPrefs.entries) {
        final k = '${e.key}';
        if (_sensitiveKeys.contains(k)) continue; // 与导出对称：密钥不进不出
        final v = e.value;
        try {
          if (v is String) {
            await sp.setString(k, v);
          } else if (v is bool) {
            await sp.setBool(k, v);
          } else if (v is int) {
            await sp.setInt(k, v);
          } else if (v is double) {
            await sp.setDouble(k, v);
          } else if (v is List) {
            await sp.setStringList(k, [for (final x in v) '$x']);
          } else {
            continue;
          }
          prefCount++;
        } catch (_) {
          // 单键失败不影响整体
        }
      }
      for (final e in kept.entries) {
        final v = e.value;
        if (v is String) {
          await sp.setString(e.key, v);
        } else if (v is bool) {
          await sp.setBool(e.key, v);
        } else if (v is int) {
          await sp.setInt(e.key, v);
        } else if (v is double) {
          await sp.setDouble(e.key, v);
        } else if (v is List) {
          await sp.setStringList(e.key, [for (final x in v) '$x']);
        }
      }
      await AppStore.I.reloadFromPrefs();
    }

    var sourceCount = 0;
    final rawSources = data['sources'];
    final store = SourceStore.shared;
    if (store != null && rawSources is List && rawSources.isNotEmpty) {
      final r = await store.importFromTextAsync(jsonEncode(rawSources));
      sourceCount = r.added + r.updated;
    }

    final rawVars = data['vars'];
    if (rawVars is Map) {
      SourceVars.I.restoreAll({
        for (final e in rawVars.entries)
          if (e.value is Map)
            '${e.key}': {
              for (final v in (e.value as Map).entries) '${v.key}': '${v.value}',
            },
      });
    }

    final rawStats = data['stats'];
    if (rawStats is Map) {
      await StatsStore.I.restoreFrom(Map<String, dynamic>.from(rawStats));
    }

    return BackupReport(prefs: prefCount, sources: sourceCount);
  }

  static String _stamp(DateTime t) =>
      '${t.year}${_two(t.month)}${_two(t.day)}_${_two(t.hour)}${_two(t.minute)}${_two(t.second)}';

  static String _two(int n) => n.toString().padLeft(2, '0');
}
