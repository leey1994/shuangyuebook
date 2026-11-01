// 「用 AI 生成书源」：分步向导。
//
// 一次只做一步（搜索 → 书详情 → 目录 → 正文）：每步引导用户浏览对应的
// 页面，模型只喂这一页的上下文、只实测这一步 —— 失败当场定位当场重试，
// 不再整轮重跑。全部通过才把书源入库。
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../data/llm_settings.dart';
import '../../legado/models.dart' show BookSource;
import '../../legado/source_generator.dart';
import '../../legado/source_store.dart';
import '../../theme.dart';
import '../brand.dart';
import 'page_collector_page.dart';

/// 打开生成向导。
Future<void> showAiSource(BuildContext context, SourceStore store) =>
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => AiSourcePage(store: store),
    ));

/// 打开模型配置页。
Future<void> showLlmSettings(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => const LlmSettingsPage(),
    ));

class AiSourcePage extends StatefulWidget {
  const AiSourcePage({super.key, required this.store});
  final SourceStore store;

  @override
  State<AiSourcePage> createState() => _AiSourcePageState();
}

class _AiSourcePageState extends State<AiSourcePage> {
  final _site = TextEditingController();
  final _keyword = TextEditingController(text: '剑');
  final _searchTpl = TextEditingController();
  final _log = <String>[];

  int _step = 0; // GenStep.values 下标
  BookSource? _draft;
  String? _bookUrl; // 第 1 步实测到的书页地址
  CollectedPage? _page; // 当前步浏览采集的页面
  bool _running = false;
  String? _error;

  GenStep get _cur => GenStep.values[_step];

  @override
  void dispose() {
    _site.dispose();
    _keyword.dispose();
    _searchTpl.dispose();
    super.dispose();
  }

  void say(String s) {
    if (mounted) setState(() => _log.add(s));
  }

  Future<void> _browse() async {
    final pages = await collectPages(context, _site.text.trim());
    if (!mounted || pages.isEmpty) return;
    setState(() {
      _page = pages.last; // 用户最后停留的页就是本步要的
      _log.clear();
      _error = null;
    });
  }

  Future<void> _runStep() async {
    final site = _site.text.trim();
    if (_cur == GenStep.search && site.isEmpty) {
      setState(() => _error = '先填小说站地址，例如 https://book.example.com');
      return;
    }
    final cfg = LlmSettings.I.config;
    if (cfg == null) {
      setState(() => _error = '还没配置模型接口，先点右上角「模型设置」');
      return;
    }
    setState(() {
      _running = true;
      _error = null;
      _log.clear();
    });
    try {
      final gen = SourceGenerator(llm: LlmClient(cfg));
      final StepResult r;
      switch (_cur) {
        case GenStep.search:
          r = await gen.generateSearchStep(
            siteUrl: site,
            keyword: _keyword.text.trim().isEmpty ? '剑' : _keyword.text.trim(),
            page: _page,
            searchUrlTemplate: _searchTpl.text,
            log: say,
          );
          if (r.ok && r.bookUrl != null) _bookUrl = r.bookUrl;
        case GenStep.detail:
          r = await gen.generateDetailStep(
              draft: _draft!, bookUrl: _bookUrl!, page: _page, log: say);
        case GenStep.toc:
          r = await gen.generateTocStep(
              draft: _draft!, bookUrl: _bookUrl!, page: _page, log: say);
        case GenStep.content:
          r = await gen.generateContentStep(
              draft: _draft!, bookUrl: _bookUrl!, page: _page, log: say);
      }
      if (!r.ok) {
        setState(() => _error = '「${_cur.label}」这步没通过实测：${r.detail}\n'
            '可以重试，或重新浏览本步页面再试');
        return;
      }
      _draft = r.source;
      if (_step < GenStep.values.length - 1) {
        setState(() {
          _step++;
          _page = null;
          _log.add('—— ${GenStep.values[_step - 1].label} 完成 ——');
        });
      } else {
        // 全部通过：入库
        final resp = await widget.store
            .importFromTextAsync(jsonEncode([_draft!.toJson()]));
        if (!mounted) return;
        if (resp.hasAny) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text('书源「${_draft!.bookSourceName}」已加入')));
          Navigator.of(context).pop();
        } else {
          setState(() => _error = '生成成功但入库失败：${resp.summary}');
        }
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  String get _stepHint => switch (_cur) {
        GenStep.search =>
          '浏览到搜索结果页：在站点里搜「${_keyword.text}」，看到结果列表后点完成。',
        GenStep.detail => '浏览到这本书的详情页（书名 / 简介 / 最新章节）。',
        GenStep.toc =>
          '浏览到目录列表。很多站目录就在详情页里 —— 那就停在详情页直接完成。',
        GenStep.content => '浏览到正文页（能看到章节文字的那一页）。',
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('AI 生成书源'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: '模型设置',
            onPressed: () async {
              await showLlmSettings(context);
              if (mounted) setState(() {});
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        children: [
          // 步骤条
          Row(
            children: [
              for (var i = 0; i < GenStep.values.length; i++) ...[
                if (i > 0)
                  Expanded(
                      child: Container(
                          height: 2,
                          color: i <= _step
                              ? Brand.green
                              : theme.dividerColor)),
                _stepDot(theme, GenStep.values[i], i),
              ],
            ],
          ),
          const SizedBox(height: 14),
          if (_cur == GenStep.search) ...[
            TextField(
              controller: _site,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: '小说站地址',
                hintText: 'https://book.example.com',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _keyword,
              decoration: const InputDecoration(
                labelText: '搜索关键词示例',
                helperText: '用来实测搜索规则，选一个该站能搜到的书名',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _searchTpl,
              decoration: const InputDecoration(
                labelText: '搜索地址模板（可选）',
                hintText: 'https://site.com/search?q={{key}}',
              ),
            ),
            const SizedBox(height: 14),
          ],
          // 当前步卡片
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Brand.card(context),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('第 ${_step + 1} 步 · 生成${_cur.label}规则',
                        style: theme.textTheme.titleSmall),
                    const Spacer(),
                    TextButton(
                      onPressed: _running ? null : _browse,
                      child: Text(_page == null ? '浏览本页' : '重新浏览'),
                    ),
                  ],
                ),
                Text(_stepHint, style: theme.textTheme.bodySmall),
                if (_page != null) ...[
                  const SizedBox(height: 6),
                  Text('已采集：${_page!.url}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11.5, color: Brand.fg3(context))),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),
          BrandBtn(_running ? '生成中…' : '生成${_cur.label}规则并实测',
              onTap: _running ? null : _runStep),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!,
                style: TextStyle(color: theme.colorScheme.error, fontSize: 13)),
          ],
          if (_log.isNotEmpty) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Brand.card(context),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('进度', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 6),
                  for (final line in _log)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Text(line,
                          style: const TextStyle(
                              fontFamily: 'monospace', fontSize: 12)),
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 20),
          Text(
            '每一步：浏览页面 → 模型只看这一页、只生成这一步的规则 → 本机引擎实测，'
            '通过才进入下一步。哪一步失败就重试或重新浏览那一页，不影响已完成的部分。',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _stepDot(ThemeData theme, GenStep g, int i) {
    final done = i < _step;
    final cur = i == _step;
    return GestureDetector(
      onTap: () {
        if (!done || _running) return;
        setState(() {
          _step = i; // 允许回看已完成步骤（重新生成会覆盖该步）
          _page = null;
          _log.clear();
        });
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Column(
          children: [
            CircleAvatar(
              radius: 12,
              backgroundColor: done || cur
                  ? Brand.green
                  : theme.dividerColor,
              child: done
                  ? const Icon(Icons.check, size: 14, color: Colors.white)
                  : Text('${i + 1}',
                      style: const TextStyle(fontSize: 11, color: Colors.white)),
            ),
            const SizedBox(height: 3),
            Text(g.label,
                style: TextStyle(
                    fontSize: 10.5,
                    color: cur ? Brand.green : Brand.fg3(context))),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 模型配置

class LlmSettingsPage extends StatefulWidget {
  const LlmSettingsPage({super.key});

  @override
  State<LlmSettingsPage> createState() => _LlmSettingsPageState();
}

class _LlmSettingsPageState extends State<LlmSettingsPage> {
  late final _base = TextEditingController(text: LlmSettings.I.baseUrl);
  late final _key = TextEditingController(text: LlmSettings.I.apiKey);
  late final _model = TextEditingController(text: LlmSettings.I.model);
  late List<String> _models = List.of(LlmSettings.I.models);

  bool _loading = false;
  bool _manual = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (LlmSettings.I.baseUrl.isNotEmpty && LlmSettings.I.apiKey.isNotEmpty) {
      // 已配置过：进页面就自动拉一次型号（失败自动切手填）
      _loadModels(silent: true);
    } else {
      _manual = true;
    }
  }

  @override
  void dispose() {
    _base.dispose();
    _key.dispose();
    _model.dispose();
    super.dispose();
  }

  Future<void> _loadModels({bool silent = false}) async {
    final base = _base.text.trim();
    final key = _key.text.trim();
    if (base.isEmpty || key.isEmpty) {
      setState(() {
        _error = '先填接口地址和 API Key';
        _manual = true;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final client = LlmClient(LlmConfig(
        baseUrl: base,
        apiKey: key,
        model: _model.text.trim().isEmpty ? 'placeholder' : _model.text.trim(),
      ));
      final models = await client.listModels();
      if (!mounted) return;
      setState(() {
        _models = models;
        _manual = false;
        if (!models.contains(_model.text.trim())) _model.text = models.first;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '自动获取型号失败：$e';
        _manual = true; // 失败兜底：手填
      });
      if (!silent) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('获取型号失败，请手动填写')));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _save() {
    final base = _base.text.trim();
    final key = _key.text.trim();
    final model = _model.text.trim();
    if (base.isEmpty || key.isEmpty || model.isEmpty) {
      setState(() => _error = '接口地址 / API Key / 型号都要填');
      return;
    }
    LlmSettings.I.save(
      baseUrl: base,
      apiKey: key,
      model: model,
      models: _models,
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(title: const Text('模型设置')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        children: [
          TextField(
            controller: _base,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: '接口地址',
              hintText: 'https://api.openai.com/v1',
              helperText: 'OpenAI 兼容的 /v1 根地址（不填 /chat/completions）',
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _key,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'API Key'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Text('模型型号', style: theme.textTheme.titleSmall),
              const Spacer(),
              TextButton.icon(
                onPressed: _loading ? null : () => _loadModels(),
                icon: _loading
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.refresh, size: 16),
                label: const Text('自动获取'),
              ),
            ],
          ),
          if (!_manual && _models.isNotEmpty)
            DropdownButtonFormField<String>(
              initialValue:
                  _models.contains(_model.text) ? _model.text : _models.first,
              items: [
                for (final m in _models)
                  DropdownMenuItem(
                      value: m,
                      child: Text(m, style: const TextStyle(fontSize: 13))),
              ],
              onChanged: (v) {
                if (v != null) setState(() => _model.text = v);
              },
            )
          else
            TextField(
              controller: _model,
              decoration: const InputDecoration(
                labelText: '模型型号',
                hintText: 'gpt-4o-mini / qwen-plus / …',
                helperText: '自动获取失败时可以手动填',
              ),
              onChanged: (_) => setState(() {}),
            ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!,
                style: TextStyle(color: theme.colorScheme.error, fontSize: 13)),
          ],
          const SizedBox(height: 18),
          BrandBtn('保存', onTap: _save),
          const SizedBox(height: 16),
          Text(
            'Key 只保存在本机（随备份导出）。页面 HTML 会发给你填的模型服务，'
            '请自行确认服务的隐私条款。',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
