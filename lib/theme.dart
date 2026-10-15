import 'package:flutter/material.dart';

/// 两套主题：0 锦绣白（默认） / 1 极光黑。
class AppThemes {
  static const white = 0;
  static const black = 1;

  static String name(int t) => t == black ? '极光黑' : '锦绣白';

  /// 主题对应的页面底色（状态栏/顶缝同色用）。
  static Color scaffold(int t) =>
      t == black ? const Color(0xFF0B0F14) : const Color(0xFFF1F6EE);

  /// 全局 Material 主题。
  static ThemeData material(int t) {
    if (t == black) {
      final base = ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF3DDC97),
          brightness: Brightness.dark,
        ),
      );
      return base.copyWith(
        scaffoldBackgroundColor: const Color(0xFF0B0F14),
        canvasColor: const Color(0xFF0B0F14),
        cardColor: const Color(0xFF151B22),
        colorScheme:
            base.colorScheme.copyWith(surface: const Color(0xFF0B0F14)),
        hintColor: const Color(0xFF8B97A5),
        dividerTheme: const DividerThemeData(
            color: Color(0xFF232B34), thickness: 1, space: 1),
        textTheme: _text(
          base.textTheme,
          fg: const Color(0xFFE9EEF4),
          dim: const Color(0xFF97A3B0),
        ),
      );
    }
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2F6B3C)),
    );
    return base.copyWith(
      scaffoldBackgroundColor: const Color(0xFFF1F6EE),
      canvasColor: const Color(0xFFF1F6EE),
      cardColor: const Color(0xFFFBFDF9),
      colorScheme: base.colorScheme.copyWith(surface: const Color(0xFFF1F6EE)),
      hintColor: const Color(0xFF5B6660),
      dividerTheme: const DividerThemeData(
          color: Color(0xFFDDE5DA), thickness: 1, space: 1),
      textTheme: _text(
        base.textTheme,
        fg: const Color(0xFF1E2420),
        dim: const Color(0xFF5B6660),
      ),
    );
  }

  /// 排版规范：正文加大加高行距、标题加粗、主/次文字高对比，
  /// 保证 Windows 下长时间阅读不费力。
  static TextTheme _text(TextTheme base,
      {required Color fg, required Color dim}) {
    return base.copyWith(
      headlineSmall: base.headlineSmall?.copyWith(
          fontSize: 22, fontWeight: FontWeight.w700, color: fg, height: 1.3),
      titleLarge: base.titleLarge?.copyWith(
          fontSize: 21, fontWeight: FontWeight.w700, color: fg, height: 1.35),
      titleMedium: base.titleMedium?.copyWith(
          fontSize: 17, fontWeight: FontWeight.w700, color: fg, height: 1.4),
      titleSmall: base.titleSmall?.copyWith(
          fontSize: 15, fontWeight: FontWeight.w700, color: fg, height: 1.4),
      bodyLarge: base.bodyLarge?.copyWith(fontSize: 16, color: fg, height: 1.6),
      bodyMedium:
          base.bodyMedium?.copyWith(fontSize: 15, color: fg, height: 1.55),
      bodySmall:
          base.bodySmall?.copyWith(fontSize: 13, color: dim, height: 1.45),
      labelLarge:
          base.labelLarge?.copyWith(fontWeight: FontWeight.w600, color: fg),
      labelMedium: base.labelMedium
          ?.copyWith(fontSize: 13, fontWeight: FontWeight.w600, color: dim),
      labelSmall: base.labelSmall?.copyWith(fontSize: 12, color: dim),
    );
  }
}

/// 宽/窄屏分界（逻辑像素）：<= 视为安卓尺寸（底部菜单 + 单列），> 为宽屏（左侧栏 + 多栏）。
const double kNarrowBreakpoint = 720;

/// 品牌点缀与徽记色（效果图 CSS 变量的 Flutter 侧唯一出处）。
///
/// 墨绿为基因色（主题 seed 已用 [green]），朱砂 / 藤黄只做点缀：
/// 徽标、名次、热度、Top1 特写，别把页面刷成红黄绿。
class Brand {
  Brand._();

  static const green = Color(0xFF2F6B3C); // 主色（浅色主题 seed）
  static const greenBright = Color(0xFF3E8A50); // 渐变亮端
  static const greenDeep = Color(0xFF1F4A38); // 横幅渐变暗端
  static const greenSoft = Color(0xFFE7F2E3); // 浅色源标签底
  static const red = Color(0xFFD9503F); // 朱砂
  static const redSoft = Color(0xFFFDECE8); // 朱砂浅底
  static const gold = Color(0xFFE5B83D); // 藤黄
  static const goldSoft = Color(0xFFFBF0DA);

  /// 名次色：1 朱砂 / 2 赭橙 / 3 藤黄 / 4+ 灰。
  static Color rank(int r) => switch (r) {
        1 => red,
        2 => const Color(0xFFE5853D),
        3 => const Color(0xFFD9A83D),
        _ => const Color(0xFF9AA69F),
      };

  /// 三级文字里的最弱一级（fg / fg2 走主题，fg3 由此补）。
  static Color fg3(BuildContext c) => Theme.of(c).brightness == Brightness.dark
      ? const Color(0xFF6B7683)
      : const Color(0xFF93A098);

  /// 卡片底 / 描边（跟随主题；效果图 --card / --hair）。
  static Color card(BuildContext c) => Theme.of(c).cardColor;
  static Color hair(BuildContext c) =>
      Theme.of(c).dividerTheme.color ?? const Color(0xFFDDE5DA);
}

/// 阅读器配色（与全局主题同步）。
({Color bg, Color fg, Color dim}) readerColors(int t) => t == AppThemes.black
    ? (
        bg: const Color(0xFF0E1116),
        fg: const Color(0xFFD8DEE6),
        dim: const Color(0xFF7A8694),
      )
    : (
        bg: const Color(0xFFF1F6EE),
        fg: const Color(0xFF1F2A20),
        dim: const Color(0xFF5F6E60),
      );

/// 阅读背景配色（正文底色 / 正文色 / 次要色）。
class ReaderBg {
  const ReaderBg(this.name, this.bg, this.fg, this.dim);

  final String name;
  final Color bg;
  final Color fg;
  final Color dim;

  bool get isDark => bg.computeLuminance() < 0.5;
}

/// 六种阅读背景（旧版融合）：日夜各三档，按阅读时段与偏好切换。
///
/// [index] 超出范围时回退到与全局主题一致的那档。
const List<ReaderBg> kReaderBgs = [
  // —— 日间 ——
  ReaderBg('纸白', Color(0xFFFFFFFF), Color(0xFF1A1A1A), Color(0xFF8A8A8A)),
  ReaderBg('米黄', Color(0xFFF7F0E1), Color(0xFF2E2A22), Color(0xFF8B8371)),
  ReaderBg('护眼绿', Color(0xFFE8F0E4), Color(0xFF22301F), Color(0xFF6E7F6B)),
  // —— 夜间 ——
  ReaderBg('浅灰', Color(0xFF20242A), Color(0xFFD6DCE4), Color(0xFF818B98)),
  ReaderBg('夜间', Color(0xFF12151A), Color(0xFFC9D1DA), Color(0xFF6F7884)),
  ReaderBg('纯黑', Color(0xFF000000), Color(0xFFBFC6CE), Color(0xFF646C77)),
];

/// 取阅读背景配色：[index] 越界时按全局主题回退到日间首位 / 夜间首位。
ReaderBg readerBgOf(int index, int theme) {
  if (index >= 0 && index < kReaderBgs.length) return kReaderBgs[index];
  return theme == AppThemes.black ? kReaderBgs[4] : kReaderBgs[0];
}

/// 背景是否属于夜间档（决定默认文字色是否需要反转）。
bool readerBgIsDark(int index, int theme) => readerBgOf(index, theme).isDark;
