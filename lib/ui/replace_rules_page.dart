// 替换净化规则管理页（对齐「阅读 3.0」的替换净化）。
//
// 规则跨书源生效，正文返回前统一应用（见 ReplaceRules.apply / AppStore.chapterText），
// 不进章节缓存，所以改完规则回阅读器立刻就是净化后的样子。
import 'package:flutter/material.dart';

import '../data/replace_rules.dart';
import '../theme.dart';
import 'brand.dart';

/// 打开替换净化页。
Future<void> showReplaceRules(BuildContext context) => Navigator.of(context)
    .push(MaterialPageRoute<void>(builder: (_) => const ReplaceRulesPage()));

class ReplaceRulesPage extends StatelessWidget {
  const ReplaceRulesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rules = ReplaceRules.I;
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('替换净化'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '新增规则',
            onPressed: () => _edit(context, null),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: rules,
        builder: (context, _) {
          final list = rules.rules;
          if (list.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Mascot(size: 56),
                    const SizedBox(height: 14),
                    Text(
                      '还没有净化规则\n常见用法：把「本章未完，请点击下一页继续阅读」这类\n广告行替换成空，所有书源一起生效',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 16),
                    BrandBtn('新增规则',
                        style: BrandBtnStyle.outline,
                        onTap: () => _edit(context, null)),
                  ],
                ),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
            itemCount: list.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, i) {
              final r = list[i];
              final err = r.error;
              return Container(
                decoration: BoxDecoration(
                  color: Brand.card(context),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: ListTile(
                  title: Text(r.name.isEmpty ? '(未命名规则)' : r.name),
                  subtitle: Text(
                    err ??
                        '${r.isRegex ? '正则' : '文本'}：${r.pattern}'
                            '${r.replacement.isEmpty ? '  →  （删除）' : '  →  ${r.replacement}'}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: err == null
                        ? null
                        : TextStyle(color: theme.colorScheme.error),
                  ),
                  leading: Switch(
                    value: r.enabled,
                    onChanged: (v) => rules.toggle(i, v),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.edit_outlined, size: 18),
                        tooltip: '编辑',
                        onPressed: () => _edit(context, i),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, size: 18),
                        tooltip: '删除',
                        onPressed: () => rules.removeAt(i),
                      ),
                    ],
                  ),
                  onTap: () => _edit(context, i),
                ),
              );
            },
          );
        },
      ),
    );
  }

  void _edit(BuildContext context, int? index) {
    final rules = ReplaceRules.I;
    final existing = index == null ? null : rules.rules[index];
    final name = TextEditingController(text: existing?.name ?? '');
    final pattern = TextEditingController(text: existing?.pattern ?? '');
    final replacement =
        TextEditingController(text: existing?.replacement ?? '');
    var isRegex = existing?.isRegex ?? true;
    final sample = TextEditingController(
        text: '本章未完，请点击下一页继续阅读！最新章节请访问 www.example.com');

    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          final draft = ReplaceRule(
            name: name.text,
            pattern: pattern.text,
            replacement: replacement.text,
            isRegex: isRegex,
          );
          final err = draft.error;
          final preview = sample.text.isEmpty ? '' : draft.apply(sample.text);
          return AlertDialog(
            title: Text(index == null ? '新增规则' : '编辑规则'),
            content: SizedBox(
              width: 460,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: name,
                      decoration: const InputDecoration(labelText: '名称（可空）'),
                      onChanged: (_) => setState(() {}),
                    ),
                    TextField(
                      controller: pattern,
                      decoration: InputDecoration(
                        labelText: '查找内容',
                        errorText: err,
                        helperText: isRegex
                            ? '正则表达式，如 本章未完.*?继续阅读'
                            : '按原文逐字匹配',
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                    TextField(
                      controller: replacement,
                      decoration: const InputDecoration(
                        labelText: '替换为（留空 = 删除）',
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('按正则匹配'),
                      value: isRegex,
                      onChanged: (v) => setState(() => isRegex = v),
                    ),
                    const Divider(),
                    TextField(
                      controller: sample,
                      maxLines: 2,
                      decoration: const InputDecoration(labelText: '试一下（示例文本）'),
                      onChanged: (_) => setState(() {}),
                    ),
                    const SizedBox(height: 8),
                    Text('结果：${preview.isEmpty ? '（空）' : preview}',
                        style: Theme.of(ctx).textTheme.bodySmall),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('取消')),
              TextButton(
                onPressed: err != null
                    ? null
                    : () {
                        final rule = ReplaceRule(
                          name: name.text.trim(),
                          pattern: pattern.text,
                          replacement: replacement.text,
                          isRegex: isRegex,
                        );
                        if (index == null) {
                          rules.add(rule);
                        } else {
                          rules.replaceAt(index, rule);
                        }
                        Navigator.of(ctx).pop();
                      },
                child: const Text('保存'),
              ),
            ],
          );
        },
      ),
    );
  }
}
