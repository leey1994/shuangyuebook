// 新 UI 品牌组件库：与效果图里的 CSS 组件一一对应
// （.cover / cv1-cv16 / .chip / .btn / .sh / .rk / .src / .prog）。
// 只做展示，不持业务状态；所有新页面从这里取件，保证 1:1 观感一致。
import 'package:flutter/material.dart';

import '../models.dart';
import '../pet/pet_painter.dart';
import '../pet/pet_store.dart';
import '../theme.dart';
import '../widgets.dart' show CoverImage;

/// 标题竖排 / 正文衬线字体栈（效果图 --serif：Noto Serif SC → 思源宋体 → 宋体）。
const List<String> kSerifFallback = [
  'Noto Serif SC',
  'Source Han Serif SC',
  'SimSun',
  'Songti SC',
  'serif',
];

/// 封面渐变池（效果图 cv1–cv16），按书名稳定取用 ——
/// 同一本书每次打开都是同一抹色，滚动列表不会闪。
const List<(Color, Color)> kCoverGradients = [
  (Color(0xFF1F4A38), Color(0xFF2F6B3C)),
  (Color(0xFF6E2A24), Color(0xFFA8432F)),
  (Color(0xFF1E3A57), Color(0xFF2E5C8A)),
  (Color(0xFF2A2340), Color(0xFF4A3B6B)),
  (Color(0xFF4A3A1E), Color(0xFF7A6230)),
  (Color(0xFF2C3E50), Color(0xFF4A6B8A)),
  (Color(0xFF4E2A26), Color(0xFF7A463A)),
  (Color(0xFF111C30), Color(0xFF22365C)),
  (Color(0xFF14303A), Color(0xFF235062)),
  (Color(0xFF33234A), Color(0xFF543A75)),
  (Color(0xFF233327), Color(0xFF3B5A44)),
  (Color(0xFF3A1F2E), Color(0xFF6B2E4A)),
  (Color(0xFF20323E), Color(0xFF3A5A6E)),
  (Color(0xFF1C3244), Color(0xFF2E5E7A)),
  (Color(0xFF40342A), Color(0xFF6B5A42)),
  (Color(0xFF2A2E4E), Color(0xFF474E8A)),
];

int _hash(String s) {
  var h = 5381;
  for (final c in s.codeUnits) {
    h = ((h << 5) + h + c) & 0x7fffffff;
  }
  return h;
}

/// 书籍封面：优先真实封面（磁盘缓存），无图 / 失败时回落「渐变 + 竖排书名」。
///
/// [width]/[height] 为 null 时填满父约束（配合 AspectRatio / Expanded 用）。
class BookCover extends StatelessWidget {
  const BookCover(
    this.book, {
    super.key,
    this.width,
    this.height,
    this.radius = 9,
  });

  final Book book;
  final double? width;
  final double? height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final url = book.cover;
    final fallback = _GradientCover(title: book.title);
    final content = (url != null && url.isNotEmpty)
        ? CoverImage(
            url: url,
            width: width,
            height: height,
            fit: BoxFit.cover,
            // 宽度可能是 double.infinity（撑满父级），此时交给 CoverImage 自己定解码上限
            cacheWidth: (width != null && width!.isFinite)
                ? (width! * 3).round()
                : 600,
            placeholder: fallback,
          )
        : fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: RepaintBoundary(
        // 封面是列表里最重的绘制（图片解码 + 圆角裁剪）。
        // 单独隔开一个重绘边界：滚动时兄弟节点变化不会连带把封面重画一遍。
        child: (width != null && height != null)
            ? SizedBox(width: width, height: height, child: content)
            : content,
      ),
    );
  }
}

/// 无封面占位：16 色渐变 + 右缘竖排书名 + 斜向高光（对应效果图 .cover::after）。
class _GradientCover extends StatelessWidget {
  const _GradientCover({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final g = kCoverGradients[_hash(title) % kCoverGradients.length];
    final chars = title.runes.take(6).map(String.fromCharCode).toList();
    return LayoutBuilder(builder: (context, c) {
      final h = c.maxHeight.isFinite ? c.maxHeight : 120.0;
      final fs = (h * 0.115).clamp(9.0, 14.0);
      return DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [g.$1, g.$2],
          ),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: const Alignment(-0.7, -0.7),
                  end: const Alignment(0.7, 0.7),
                  stops: const [0.0, 0.56],
                  colors: [
                    Colors.white.withValues(alpha: 0.17),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
            Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.all(7),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final ch in chars)
                      Text(
                        ch,
                        style: TextStyle(
                          fontFamilyFallback: kSerifFallback,
                          fontWeight: FontWeight.w700,
                          fontSize: fs,
                          height: 1.22,
                          color: Colors.white.withValues(alpha: 0.93),
                          shadows: const [
                            Shadow(
                                blurRadius: 3,
                                color: Color(0x4D000000),
                                offset: Offset(0, 1)),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    });
  }
}

/// 小墨徽标（应用图标即小墨形象；缺资源时退化为墨绿字印）。
class Mascot extends StatelessWidget {
  const Mascot({super.key, this.size = 27, this.stage});

  final double size;

  /// 为空时跟随当前养成阶段（PetStore），与顶带里溜达的那只永远同一形态。
  final PetStage? stage;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: PetPainter(
          stage: stage ?? PetStore.I.stage,
          mood: PetMood.calm,
          phase: 0,
        ),
      ),
    );
  }
}

/// 胶囊筛选片（.chip / .chip.on）。
class PillChip extends StatelessWidget {
  const PillChip(
    this.text, {
    super.key,
    this.selected = false,
    this.onTap,
    this.height = 29,
    this.icon,
  });

  final String text;
  final bool selected;
  final VoidCallback? onTap;
  final double height;
  final Widget? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fg = selected ? Colors.white : theme.hintColor;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: height,
        padding: const EdgeInsets.symmetric(horizontal: 13),
        decoration: BoxDecoration(
          color: selected ? Brand.green : Brand.card(context),
          border: Border.all(color: selected ? Brand.green : Brand.hair(context)),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[icon!, const SizedBox(width: 4)],
            Text(text,
                style: theme.textTheme.labelSmall?.copyWith(
                    color: fg,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

/// 名次数字（.rk / .rk1-.rk4）。
class RankNum extends StatelessWidget {
  const RankNum(this.rank, {super.key, this.size = 16.5});
  final int rank;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size * 1.25,
      child: Text(
        '$rank',
        textAlign: TextAlign.center,
        style: TextStyle(
            fontFamilyFallback: kSerifFallback,
            fontSize: size,
            fontWeight: FontWeight.w800,
            color: Brand.rank(rank)),
      ),
    );
  }
}

/// 来源胶囊（.src；accent = 朱砂浅底计数药丸，如「6 个来源」）。
class SrcPill extends StatelessWidget {
  const SrcPill(this.text, {super.key, this.accent = false});
  final String text;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final bg = accent
        ? (dark ? const Color(0xFF3A201C) : Brand.redSoft)
        : (dark ? const Color(0xFF1D2A21) : Brand.greenSoft);
    final fg = accent ? Brand.red : (dark ? const Color(0xFF63C88D) : Brand.green);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1.5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(text,
          style: TextStyle(
              fontSize: 10, fontWeight: FontWeight.w600, color: fg, height: 1.5)),
    );
  }
}

/// 区块标题行（.sh）：加粗标题 + 右侧动作（绿字 / 灰字 + 可选箭头）。
class SectionHead extends StatelessWidget {
  const SectionHead(
    this.title, {
    super.key,
    this.action,
    this.onAction,
    this.actionIcon,
    this.grayAction = false,
    this.padding = const EdgeInsets.fromLTRB(16, 15, 16, 9),
  });

  final String title;
  final String? action;
  final VoidCallback? onAction;
  final Widget? actionIcon;
  final bool grayAction;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final actionColor = grayAction ? Brand.fg3(context) : Brand.green;
    return Padding(
      padding: padding,
      child: Row(
        children: [
          Text(title,
              style: theme.textTheme.titleSmall?.copyWith(
                  fontSize: 15.5, fontWeight: FontWeight.w800)),
          const Spacer(),
          if (action != null || actionIcon != null)
            GestureDetector(
              onTap: onAction,
              behavior: HitTestBehavior.opaque,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (actionIcon != null) ...[actionIcon!, const SizedBox(width: 2)],
                  if (action != null)
                    Text(action!,
                        style: theme.textTheme.labelSmall?.copyWith(
                            color: actionColor,
                            fontSize: 12,
                            fontWeight: FontWeight.w500)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// 品牌按钮变体（.btn：p 主色 / o 描边 / g 灰底 / hairline 细描边图标钮）。
enum BrandBtnStyle { primary, outline, grey, hairline }

/// 品牌按钮：高 38、圆角 12（效果图 .btn 规格）。
class BrandBtn extends StatelessWidget {
  const BrandBtn(
    this.label, {
    super.key,
    this.style = BrandBtnStyle.primary,
    this.onTap,
    this.icon,
    this.height = 38,
    this.radius = 12,
    this.flex,
  }) : child = null;

  /// 图标钮变体（无文字）。
  const BrandBtn.icon(
    Widget this.child, {
    super.key,
    this.style = BrandBtnStyle.hairline,
    this.onTap,
    this.height = 38,
    this.radius = 12,
  })  : label = null,
        icon = null,
        flex = null;

  final String? label;
  final Widget? child;
  final Widget? icon;
  final BrandBtnStyle style;
  final VoidCallback? onTap;
  final double height;
  final double radius;
  final int? flex;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (bg, border, fg) = switch (style) {
      BrandBtnStyle.primary => (Brand.green, Brand.green, Colors.white),
      BrandBtnStyle.outline => (
          Colors.transparent,
          Brand.green,
          Brand.green
        ),
      BrandBtnStyle.grey => (
          theme.brightness == Brightness.dark
              ? const Color(0xFF20292B)
              : const Color(0xFFEAF0E7),
          Colors.transparent,
          theme.hintColor
        ),
      BrandBtnStyle.hairline => (
          Colors.transparent,
          Brand.hair(context),
          theme.hintColor
        ),
    };
    Widget inner = child != null
        ? DefaultTextStyle(
            style: TextStyle(color: fg), child: IconTheme(data: IconThemeData(color: fg, size: 20), child: child!))
        : Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[
                IconTheme(data: IconThemeData(color: fg, size: 16), child: icon!),
                if (label != null) const SizedBox(width: 6),
              ],
              if (label != null)
                Text(label!,
                    style: TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600, color: fg)),
            ],
          );
    final btn = GestureDetector(
      onTap: onTap,
      child: Container(
        height: height,
        padding: EdgeInsets.symmetric(horizontal: label != null ? 16 : 0),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: bg,
          border: Border.all(color: border),
          borderRadius: BorderRadius.circular(radius),
        ),
        child: inner,
      ),
    );
    if (flex != null) return Expanded(flex: flex!, child: btn);
    return btn;
  }
}

/// 细进度条（.prog）。
class ProgBar extends StatelessWidget {
  const ProgBar(
    this.value, {
    super.key,
    this.height = 4,
    this.color,
    this.track,
  });

  final double value; // 0..1
  final double height;
  final Color? color;
  final Color? track;

  @override
  Widget build(BuildContext context) {
    final v = value.clamp(0.0, 1.0);
    return ClipRRect(
      borderRadius: BorderRadius.circular(height / 2),
      child: SizedBox(
        height: height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(
                color: track ??
                    (Theme.of(context).brightness == Brightness.dark
                        ? const Color(0xFF232B34)
                        : const Color(0xFFDDE9DA))),
            FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: v,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: color != null
                        ? [color!, color!]
                        : const [Color(0xFF8FD9AE), Brand.green],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 关键词高亮标题（.brow .bt mark）：命中片段染朱砂。
class MarkedTitle extends StatelessWidget {
  const MarkedTitle(this.title, this.query, {super.key, this.style});

  final String title;
  final String query;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final base = style ??
        Theme.of(context).textTheme.bodyMedium?.copyWith(
            fontSize: 14.5, fontWeight: FontWeight.w700, height: 1.2);
    final q = query.trim();
    final idx = q.isEmpty ? -1 : title.toLowerCase().indexOf(q.toLowerCase());
    if (idx < 0) {
      return Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: base);
    }
    return RichText(
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      text: TextSpan(style: base, children: [
        TextSpan(text: title.substring(0, idx)),
        TextSpan(
            text: title.substring(idx, idx + q.length),
            style: base?.copyWith(color: Brand.red)),
        TextSpan(text: title.substring(idx + q.length)),
      ]),
    );
  }
}
