// 书源仓库：导入 / 导出 / 持久化（JSON 文件）/ 启用状态管理。
//
// 持久化位置：App files 目录下的 book_sources.json
// 结构：{"version": 1, "sources": [ {...书源JSON...} ]}
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../platform/native_bridge.dart';
import 'models.dart';
import 'source_vars.dart';

/// 导入结果统计。
class SourceImportReport {
  const SourceImportReport({
    this.added = 0,
    this.updated = 0,
    this.invalid = 0,
    this.error,
  });

  final int added;
  final int updated;
  final int invalid;
  final String? error;

  bool get hasAny => added + updated > 0;

  String get summary {
    if (error != null) return error!;
    final parts = <String>[
      if (added > 0) '新增 $added 个',
      if (updated > 0) '更新 $updated 个',
      if (invalid > 0) '跳过 $invalid 个无效条目',
    ];
    return parts.isEmpty ? '没有可导入的书源' : parts.join('，');
  }
}

/// 书源仓库（可监听，UI 依赖它刷新）。
class SourceStore extends ChangeNotifier {
  SourceStore({AppDirs? dirsOverride, List<BookSource>? initial})
      : _dirsOverride = dirsOverride {
    if (initial != null) _sources.addAll(initial);
  }

  /// 进程内共享实例（在线书籍内容读取器按 bookSourceUrl 查找书源时使用）。
  static SourceStore? shared;

  final AppDirs? _dirsOverride;
  final List<BookSource> _sources = [];
  AppDirs? _dirs;
  File? _file;
  Timer? _saveTimer;

  /// 内置资产清理的版本号：同一版本只清理一次。
  ///
  /// 历史版本预置过的书源地址清单（`legacyBuiltinUrls`）只在**升级后首次启动**
  /// 生效一次；否则用户手动重新导入同址书源后，每次启动都会被再删一遍。
  int _builtinSyncVersion = 0;

  /// 当前资产清理逻辑的版本。改清理规则时 +1。
  static const int kBuiltinSyncVersion = 1;

  List<BookSource> get sources => List.unmodifiable(_sources);

  int get enabledCount => _sources.where((s) => s.enabled).length;

  bool get isEmpty => _sources.isEmpty;

  BookSource? byUrl(String url) {
    for (final s in _sources) {
      if (s.bookSourceUrl == url) return s;
    }
    return null;
  }

  List<BookSource> get enabled =>
      _sources.where((s) => s.enabled).toList(growable: false);

  // ---------- 加载 / 保存 ----------

  Future<void> load() async {
    _dirs = _dirsOverride ?? await NativeBridge.appDirs();
    _file = File('${_dirs!.files}/book_sources.json');
    try {
      if (await _file!.exists()) {
        final data = jsonDecode(await _file!.readAsString());
        if (data is Map && data['sources'] is List) {
          // 老版本文件没有该字段：它在那些版本里已经按旧清单清理过了，
          // 视为“已清理”，避免升级后又删一遍用户手动重新导入的书源。
          final v = data['builtinSyncVersion'];
          _builtinSyncVersion =
              v is num ? v.toInt() : kBuiltinSyncVersion;
          for (final item in data['sources'] as List) {
            try {
              final s = BookSource.fromJson(item);
              if (s.bookSourceUrl.isNotEmpty) _sources.add(s);
            } catch (_) {
              // 跳过坏条目
            }
          }
        }
      }
    } catch (_) {
      // 读取失败时以空列表启动
    }
    notifyListeners();
  }

  // ---------- 变更 ----------

  /// 批量导入；同一 bookSourceUrl 视为更新（保留原启用状态）。
  ({int added, int updated}) addAll(List<BookSource> items) {
    var added = 0;
    var updated = 0;
    for (final s in items) {
      final i = _sources.indexWhere((x) => x.bookSourceUrl == s.bookSourceUrl);
      if (i >= 0) {
        // 保留用户当前的启用状态
        final keepEnabled = _sources[i].enabled;
        _sources[i] =
            s.enabled == keepEnabled ? s : s.copyWith(enabled: keepEnabled);
        updated++;
      } else {
        _sources.add(s);
        added++;
      }
    }
    if (added + updated > 0) {
      _saveSoon();
      notifyListeners();
    }
    return (added: added, updated: updated);
  }

  void remove(String url) {
    final before = _sources.length;
    _sources.removeWhere((s) => s.bookSourceUrl == url);
    if (_sources.length != before) {
      // 连带清掉该源的脚本变量（legado 删除书源时同样清 BookSourceVariable）
      SourceVars.shared?.removeSource(url);
      _saveSoon();
      notifyListeners();
    }
  }

  void setEnabled(String url, bool value) {
    final i = _sources.indexWhere((s) => s.bookSourceUrl == url);
    if (i < 0 || _sources[i].enabled == value) return;
    _sources[i] = _sources[i].copyWith(enabled: value);
    _saveSoon();
    notifyListeners();
  }

  /// 批量设置启用状态（书源管理「批量管理」用）。
  ///
  /// 返回实际变更的数量（已处于目标状态的条目不计入）。
  int setEnabledAll(Iterable<String> urls, bool value) {
    final targets = urls.toSet();
    if (targets.isEmpty) return 0;
    var changed = 0;
    for (var i = 0; i < _sources.length; i++) {
      final s = _sources[i];
      if (!targets.contains(s.bookSourceUrl) || s.enabled == value) continue;
      _sources[i] = s.copyWith(enabled: value);
      changed++;
    }
    if (changed > 0) {
      _saveSoon();
      notifyListeners();
    }
    return changed;
  }

  /// 批量删除（书源管理「批量管理」用）。返回实际删除的数量。
  int removeMany(Iterable<String> urls) {
    final targets = urls.toSet();
    if (targets.isEmpty) return 0;
    final before = _sources.length;
    _sources.removeWhere((s) => targets.contains(s.bookSourceUrl));
    final removed = before - _sources.length;
    if (removed > 0) {
      for (final u in targets) {
        SourceVars.shared?.removeSource(u);
      }
      _saveSoon();
      notifyListeners();
    }
    return removed;
  }

  // ---------- 导入 / 导出 ----------

  /// 从 JSON 文本导入（支持数组或单个对象；容忍 BOM 与首尾空白）。
  SourceImportReport importFromText(String text) {
    final trimmed = text.trim().replaceFirst('\uFEFF', '');
    if (trimmed.isEmpty) {
      return const SourceImportReport(error: '内容为空');
    }
    dynamic decoded;
    try {
      decoded = jsonDecode(trimmed);
    } catch (_) {
      return const SourceImportReport(error: '不是合法的 JSON（书源应为 JSON 数组或对象）');
    }
    final items = BookSource.listFromJson(decoded);
    if (items.isEmpty) {
      return const SourceImportReport(
        error: '没有解析到有效书源（需要 bookSourceUrl 与 bookSourceName）',
      );
    }
    final total = decoded is List ? decoded.length : 1;
    final r = addAll(items);
    return SourceImportReport(
      added: r.added,
      updated: r.updated,
      invalid: total - items.length,
    );
  }

  /// 从文件导入。
  Future<SourceImportReport> importFromFile(String path) async {
    try {
      final text = await File(path).readAsString();
      return importFromText(text);
    } catch (e) {
      return SourceImportReport(error: '读取文件失败：$e');
    }
  }

  /// 导出为 JSON 文本（数组格式，与阅读 3.0 互通）。
  String exportJson() {
    final list = _sources.map((s) => s.toJson()).toList();
    return const JsonEncoder.withIndent('  ').convert(list);
  }

  /// 立即落盘（测试与退出前调用；平时是防抖保存）。
  Future<void> flush() => _save();

  /// 同步内置书源资产（App 启动时调用）。
  ///
  /// 现在**不预置任何导入书源** —— 原生内置适配器（lib/sources/）已经够用，
  /// 导入区留给用户自己填。资产文件保留下来只当「清理清单」用：
  ///
  /// - `sources`：预置清单，当前为空；
  /// - `legacyBuiltinUrls`：历史版本预置过的地址。这些从旧版本升级上来的用户
  ///   本地已经有它们，启动时按地址删掉，导入区才能真正回到「默认为空」。
  ///   只删地址完全一致的条目，用户自己导入的同名站点不受影响；
  ///   且按 [kBuiltinSyncVersion] **只清一次**，用户重新导入后不会再被删。
  Future<int> syncBuiltinSources() async {
    try {
      final text = await rootBundle.loadString(
        'assets/sources/builtin_sources.json',
      );
      var removed = 0;
      var cleaned = false;
      if (_builtinSyncVersion < kBuiltinSyncVersion) {
        removed = _dropLegacyBuiltinSources(text);
        _builtinSyncVersion = kBuiltinSyncVersion;
        cleaned = true;
      }
      var added = 0;
      final seeded = _seededFrom(text);
      if (seeded.isNotEmpty) {
        final report = importFromText(seeded);
        added = report.added + report.updated;
      }
      if (removed > 0 || added > 0 || cleaned) await flush();
      return added + removed;
    } catch (_) {
      return 0;
    }
  }

  /// 从资产里取出预置书源数组（`sources` 字段；兼容旧的纯数组格式）。
  String _seededFrom(String builtinJson) {
    try {
      final decoded = jsonDecode(builtinJson);
      if (decoded is List) return jsonEncode(decoded);
      if (decoded is Map && decoded['sources'] is List) {
        return jsonEncode(decoded['sources']);
      }
    } catch (_) {
      return '';
    }
    return '';
  }

  /// 按内置资产里的 `legacyBuiltinUrls` 清单移除历史内置源。
  ///
  /// 只删「书源地址完全一致」的条目：用户自己导入的同名站点不受影响。
  int _dropLegacyBuiltinSources(String builtinJson) {
    final legacy = <String>{};
    void collect(dynamic decoded) {
      if (decoded is Map) {
        final urls = decoded['legacyBuiltinUrls'];
        if (urls is List) legacy.addAll(urls.map((u) => u.toString().trim()));
      } else if (decoded is List) {
        for (final item in decoded) {
          if (item is Map) collect(item);
        }
      }
    }

    try {
      collect(jsonDecode(builtinJson));
    } catch (_) {
      return 0;
    }
    legacy.removeWhere((u) => u.isEmpty);
    if (legacy.isEmpty) return 0;
    final before = _sources.length;
    _sources.removeWhere((s) => legacy.contains(s.bookSourceUrl));
    return before - _sources.length;
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    super.dispose();
  }

  // ---------- 持久化 ----------

  void _saveSoon() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), () {
      unawaited(_save());
    });
  }

  Future<void> _save() async {
    final file = _file;
    if (file == null) return;
    try {
      await file.parent.create(recursive: true);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(
        jsonEncode({
          'version': 1,
          'builtinSyncVersion': _builtinSyncVersion,
          'sources': _sources.map((s) => s.toJson()).toList(),
        }),
      );
      await tmp.rename(file.path);
    } catch (_) {
      // 忽略保存失败
    }
  }
}
