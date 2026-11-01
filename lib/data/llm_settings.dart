// 书源 AI 生成的模型配置（OpenAI 兼容接口）：存在 SharedPreferences，
// 与书源一起走 App 自己的备份（所有 sp 键都会被导出）。
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../legado/source_generator.dart';

class LlmSettings extends ChangeNotifier {
  LlmSettings._();
  static final LlmSettings I = LlmSettings._();

  static const String _kBase = 'llmBaseUrl';
  static const String _kKey = 'llmApiKey';
  static const String _kModel = 'llmModel';

  SharedPreferences? _sp;

  String baseUrl = '';
  String apiKey = '';
  String model = '';

  /// 用户上次拉取到的模型列表（仅本次进程内缓存，避免每次进页面都请求）。
  List<String> models = const [];

  bool get configured =>
      baseUrl.trim().isNotEmpty &&
      apiKey.trim().isNotEmpty &&
      model.trim().isNotEmpty;

  LlmConfig? get config => configured
      ? LlmConfig(baseUrl: baseUrl.trim(), apiKey: apiKey.trim(), model: model.trim())
      : null;

  void init(SharedPreferences? sp) {
    _sp = sp;
    baseUrl = sp?.getString(_kBase) ?? '';
    apiKey = sp?.getString(_kKey) ?? '';
    model = sp?.getString(_kModel) ?? '';
  }

  /// 保存配置；[models] 传入时一并缓存。
  void save({
    required String baseUrl,
    required String apiKey,
    required String model,
    List<String>? models,
  }) {
    this.baseUrl = baseUrl.trim();
    this.apiKey = apiKey.trim();
    this.model = model.trim();
    if (models != null) this.models = models;
    final sp = _sp;
    if (sp != null) {
      sp.setString(_kBase, this.baseUrl);
      sp.setString(_kKey, this.apiKey);
      sp.setString(_kModel, this.model);
    }
    notifyListeners();
  }
}
