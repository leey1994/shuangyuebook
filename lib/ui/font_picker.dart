// 字体选择面板（阅读器与「我的」共用）。
//
// 应用不内置字体文件：这里列出的每一款都是「点了才下载」的网络字体，
// 下载一次存在本机（应用支持目录，清缓存不会删），之后离线可用。
import 'package:flutter/material.dart';

import '../data/font_store.dart';
import '../store.dart';
import '../theme.dart' show Brand;

/// 字体显示名（'' = 系统默认）。
String fontFamilyLabel(String family) =>
    family.isEmpty ? '系统默认' : (FontStore.byId(family)?.name ?? '系统默认');

/// 打开字体选择面板。
///
/// 选中未下载的字体时会先下载（带进度），下完自动切换并关闭面板；
/// 下载失败只提示，不改当前字体。
Future<void> showFontPicker(
  BuildContext context, {
  Color? bg,
  Color? fg,
  Color? dim,
}) async {
  final store = AppStore.I;
  final messenger = ScaffoldMessenger.of(context);
  final theme = Theme.of(context);
  final bgColor = bg ?? theme.colorScheme.surface;
  final fgColor = fg ?? theme.colorScheme.onSurface;
  final dimColor = dim ?? theme.colorScheme.onSurface.withValues(alpha: 0.55);
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: bgColor,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
    builder: (ctx) => ListenableBuilder(
      listenable: FontStore.I,
      builder: (ctx, _) {
        final current = store.prefs.fontFamily;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Text('字体',
                        style: TextStyle(
                            color: fgColor,
                            fontSize: 15,
                            fontWeight: FontWeight.w700)),
                    const Spacer(),
                    Text('不内置 · 选中才下载',
                        style: TextStyle(color: dimColor, fontSize: 11)),
                  ],
                ),
                const SizedBox(height: 4),
                _fontTile(ctx, messenger, fgColor, dimColor, null, current),
                for (final f in kRemoteFonts)
                  _fontTile(ctx, messenger, fgColor, dimColor, f, current),
                const SizedBox(height: 6),
                Text('字体只下载一次，存在本机，之后断网也能用；清理阅读缓存不会删。',
                    style: TextStyle(color: dimColor, fontSize: 11)),
              ],
            ),
          ),
        );
      },
    ),
  );
}

Widget _fontTile(
  BuildContext ctx,
  ScaffoldMessengerState messenger,
  Color fg,
  Color dim,
  RemoteFont? f,
  String current,
) {
  final id = f?.id ?? '';
  final ready = f == null || FontStore.I.isReady(id);
  final selected = current == id;
  final st = f == null ? FontStatus.ready : FontStore.I.statusOf(id);
  return InkWell(
    onTap: () async {
      final store = AppStore.I;
      if (f == null) {
        store.setFontFamily('');
        Navigator.of(ctx).pop();
        return;
      }
      if (ready) {
        store.setFontFamily(id);
        Navigator.of(ctx).pop();
        return;
      }
      final ok = await FontStore.I.ensure(id);
      if (!ctx.mounted) return;
      if (ok) {
        store.setFontFamily(id);
        Navigator.of(ctx).pop();
      } else {
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
              content: Text(FontStore.I.errorOf(id) ?? '字体下载失败，换个网络再试')));
      }
    },
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(
        children: [
          Icon(
            selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
            size: 18,
            color: selected ? Brand.green : dim,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(f?.name ?? '系统默认',
                    style: TextStyle(
                        color: fg,
                        fontSize: 13.5,
                        fontFamily: ready && f != null ? f.family : null)),
                Text(
                  f == null ? '跟随系统字体' : '${f.note} · ${f.sizeLabel}',
                  style: TextStyle(color: dim, fontSize: 11),
                ),
              ],
            ),
          ),
          if (f != null && !ready)
            st == FontStatus.downloading
                ? ValueListenableBuilder<double>(
                    valueListenable: FontStore.I.progressOf(id),
                    builder: (_, v, __) => SizedBox(
                      width: 56,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          LinearProgressIndicator(
                              value: v <= 0 ? null : v, minHeight: 3),
                          const SizedBox(height: 3),
                          Text('${(v * 100).round()}%',
                              style: TextStyle(color: dim, fontSize: 10)),
                        ],
                      ),
                    ),
                  )
                : Text(st == FontStatus.failed ? '重试' : '下载',
                    style: const TextStyle(color: Brand.green, fontSize: 12))
          else if (f != null)
            Text('已下载', style: TextStyle(color: dim, fontSize: 11)),
        ],
      ),
    ),
  );
}
