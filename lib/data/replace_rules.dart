// 全局替换净化规则（对齐「阅读 3.0」的替换净化）：
//
// 书源自带的 `ruleContent.replaceRegex` 只能治一个源；开源书源里最常见的
// 「本章未完，请点击下一页」「笔趣阁…最快更新」这类广告行每个站写法都不同，
// 用户需要自己维护一份**跨书源生效**的规则表。
//
// 规则只作用在正文段落上，且不写进章节缓存 —— 改了规则立刻生效，不用清缓存。
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 一条净化规则。
class ReplaceRule {
  ReplaceRule({
    required this.name,
    required this.pattern,
    this.replacement = '',
    this.isRegex = true,
    this.enabled = true,
  });

  String name;
  String pattern;
  String replacement;

  /// true = 按正则替换；false = 纯文本替换（用户不懂正则时的安全选项）。
  bool isRegex;
  bool enabled;

  Map<String, dynamic> toJson() => {
        'name': name,
        'pattern': pattern,
        'replacement': replacement,
        'isRegex': isRegex,
        'enabled': enabled,
      };

  factory ReplaceRule.fromJson(Map<String, dynamic> j) => ReplaceRule(
        name: '${j['name'] ?? ''}',
        pattern: '${j['pattern'] ?? ''}',
        replacement: '${j['replacement'] ?? ''}',
        isRegex: j['isRegex'] != false,
        enabled: j['enabled'] != false,
      );

  ReplaceRule copy() => ReplaceRule(
        name: name,
        pattern: pattern,
        replacement: replacement,
        isRegex: isRegex,
        enabled: enabled,
      );

  /// 规则能否生效（空查找串没有意义，坏正则会被跳过）。
  String? get error {
    if (pattern.isEmpty) return '查找内容不能为空';
    if (!isRegex) return null;
    try {
      RegExp(pattern);
      return null;
    } catch (e) {
      return '正则有误：$e';
    }
  }

  String apply(String text) {
    if (pattern.isEmpty) return text;
    try {
      if (isRegex) {
        return text.replaceAll(RegExp(pattern), replacement);
      }
      return text.replaceAll(pattern, replacement);
    } catch (_) {
      return text;
    }
  }
}

/// 规则表：持久化在 SharedPreferences，正文返回前统一应用。
class ReplaceRules extends ChangeNotifier {
  ReplaceRules._();
  static final ReplaceRules I = ReplaceRules._();

  static const String _key = 'replaceRules';

  final List<ReplaceRule> _rules = [];
  List<ReplaceRule>? _compiledCache;
  SharedPreferences? _sp;

  List<ReplaceRule> get rules => List.unmodifiable(_rules);

  /// 真正会生效的规则（启用且正则合法）；按当前表缓存，改动后失效。
  List<ReplaceRule> get _active {
    final cached = _compiledCache;
    if (cached != null) return cached;
    final list = [
      for (final r in _rules)
        if (r.enabled && r.error == null) r,
    ];
    return _compiledCache = list;
  }

  void init(SharedPreferences? sp) {
    _sp = sp;
    final raw = sp?.getString(_key);
    if (raw == null || raw.isEmpty) return;
    try {
      final list = jsonDecode(raw);
      if (list is! List) return;
      _rules
        ..clear()
        ..addAll([
          for (final e in list)
            if (e is Map) ReplaceRule.fromJson(Map<String, dynamic>.from(e)),
        ]);
      _compiledCache = null;
    } catch (_) {
      // 坏数据按空表处理，不影响阅读
    }
  }

  void add(ReplaceRule r) {
    _rules.add(r);
    _changed();
  }

  void removeAt(int i) {
    if (i < 0 || i >= _rules.length) return;
    _rules.removeAt(i);
    _changed();
  }

  void replaceAt(int i, ReplaceRule r) {
    if (i < 0 || i >= _rules.length) return;
    _rules[i] = r;
    _changed();
  }

  void toggle(int i, bool on) {
    if (i < 0 || i >= _rules.length) return;
    _rules[i].enabled = on;
    _changed();
  }

  /// 对一段文字按全部规则依次替换（预览与正文共用同一实现）。
  String applyTo(String text) {
    var s = text;
    for (final r in _active) {
      s = r.apply(s);
    }
    return s;
  }

  /// 正文段落净化。规则写坏把整章清空时保留原文 —— 阅读器不能因为有规则就白屏。
  List<String> apply(List<String> paras) {
    if (_active.isEmpty) return paras;
    final out = <String>[];
    for (final p in paras) {
      final s = applyTo(p);
      if (s.trim().isNotEmpty) out.add(s);
    }
    return out.isEmpty ? paras : out;
  }

  void _changed() {
    _compiledCache = null;
    final sp = _sp;
    if (sp != null) {
      try {
        sp.setString(_key, jsonEncode([for (final r in _rules) r.toJson()]));
      } catch (_) {}
    }
    notifyListeners();
  }
}
