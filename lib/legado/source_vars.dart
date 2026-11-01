// 书源变量的跨会话持久化（对齐 legado 的 BookSourceVariableEntity）。
//
// 为什么要做：legado 的 `source.getVariable(k)` / `source.setVariable(k, v)`
// 落在书源级数据库里，**重启也在**。书源脚本普遍用它缓存 token / cookie /
// 设备指纹：
//   - 搜索时 `setVariable('token', …)`，正文时 `getVariable('token')` 取；
//   - 首次算好签名参数，后续请求直接复用，避免重复算（有的源还算一次就要等）。
// 爽阅早期只放在 JsSession 内存里，会话一结束就丢，于是「跨请求取变量」的源
// 在正文阶段拿到空串，表现为「目录正常、正文空」。
//
// 落盘位置：<files>/source_vars.json
// 结构：{"version": 1, "vars": {"<bookSourceUrl>": {"k": "v"}}}
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../platform/native_bridge.dart';

/// 书源变量仓库（进程内单例）。
class SourceVars {
  SourceVars({AppDirs? dirsOverride}) : _dirsOverride = dirsOverride;

  static SourceVars? shared;

  /// 兜底单例：服务层在没初始化时也能用（不落盘，只存内存）。
  static SourceVars get I => shared ??= SourceVars();

  final AppDirs? _dirsOverride;

  /// 书源地址 → (变量名 → 值)。
  final Map<String, Map<String, String>> _bySource = {};

  File? _file;
  Timer? _saveTimer;
  bool _loaded = false;

  /// 单源最多保留多少条变量：脚本偶尔会写入递增键名，不设上限会写爆磁盘。
  static const int maxPerSource = 64;

  /// 单值上限（字符）。超过就截断，保住落盘体积可控。
  static const int maxValueChars = 64 * 1024;

  /// 是否已从磁盘加载。
  bool get loaded => _loaded;

  /// 读取书源变量；没有则返回空串（legado 返回 null，脚本侧都按假值处理）。
  String get(String sourceUrl, String key) {
    if (sourceUrl.isEmpty || key.isEmpty) return '';
    return _bySource[sourceUrl]?[key] ?? '';
  }

  /// 写入书源变量（[value] 为 null 表示删除）。
  void set(String sourceUrl, String key, String? value) {
    if (sourceUrl.isEmpty || key.isEmpty) return;
    if (value == null) {
      final m = _bySource[sourceUrl];
      if (m == null || !m.containsKey(key)) return;
      m.remove(key);
      if (m.isEmpty) _bySource.remove(sourceUrl);
    } else {
      final v = value.length > maxValueChars
          ? value.substring(0, maxValueChars)
          : value;
      final m = _bySource.putIfAbsent(sourceUrl, () => <String, String>{});
      if (m[key] == v) return;
      // 超出上限时先淘汰最早写入的（Dart Map 保持插入序）
      while (m.length >= maxPerSource && !m.containsKey(key)) {
        m.remove(m.keys.first);
      }
      m[key] = v;
    }
    _saveSoon();
  }

  /// 全部书源变量的快照（备份用）。
  Map<String, Map<String, String>> snapshot() => {
        for (final e in _bySource.entries) e.key: Map<String, String>.of(e.value),
      };

  /// 整表替换（备份恢复用）。
  void restoreAll(Map<String, Map<String, String>> data) {
    _bySource
      ..clear()
      ..addAll(data);
    _saveSoon();
  }

  /// 整源变量的快照（诊断 / 导出用）。
  Map<String, String> of(String sourceUrl) =>
      Map<String, String>.unmodifiable(_bySource[sourceUrl] ?? const {});

  /// 书源被删除时连带清掉它的变量。
  void removeSource(String sourceUrl) {
    if (_bySource.remove(sourceUrl) != null) _saveSoon();
  }

  Future<void> load() async {
    final dirs = _dirsOverride ?? await NativeBridge.appDirs();
    _file = File('${dirs.files}/source_vars.json');
    try {
      if (await _file!.exists()) {
        final data = jsonDecode(await _file!.readAsString());
        if (data is Map && data['vars'] is Map) {
          (data['vars'] as Map).forEach((k, v) {
            if (v is! Map) return;
            final m = <String, String>{};
            v.forEach((ik, iv) {
              if (iv == null) return;
              m['$ik'] = '$iv';
            });
            if (m.isNotEmpty) _bySource['$k'] = m;
          });
        }
      }
    } catch (_) {
      // 读取失败以空表启动，脚本侧退化为“取不到变量”
    }
    _loaded = true;
  }

  /// 只读模式（体检分身用）：读同一份文件，但不回写 —— 写盘归主线程。
  bool readOnly = false;

  /// 立即落盘（测试与退出前调用）。
  Future<void> flush() => readOnly ? Future.value() : _save();

  void _saveSoon() {
    if (readOnly) return;
    if (_file == null && _dirsOverride == null) return; // 没初始化过：只存内存
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 800), () {
      unawaited(_save());
    });
  }

  Future<void> _save() async {
    var file = _file;
    if (file == null) {
      // 没调过 load()（例如单元测试里直接构造）：按注入目录惰性解析落盘路径
      final d = _dirsOverride;
      if (d == null) return;
      file = _file = File('${d.files}/source_vars.json');
    }
    try {
      await file.parent.create(recursive: true);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(
        jsonEncode({'version': 1, 'vars': _bySource}),
      );
      await tmp.rename(file.path);
    } catch (_) {
      // 忽略保存失败
    }
  }

  /// 清空所有书源变量（书源管理页「清空缓存」用）。
  void clearAll() {
    if (_bySource.isEmpty) return;
    _bySource.clear();
    _saveSoon();
  }
}
