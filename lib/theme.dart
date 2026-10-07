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
        colorScheme: base.colorScheme.copyWith(surface: const Color(0xFF0B0F14)),
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
  static TextTheme _text(TextTheme base, {required Color fg, required Color dim}) {
    return base.copyWith(
      headlineSmall: base.headlineSmall?.copyWith(
          fontSize: 22, fontWeight: FontWeight.w700, color: fg, height: 1.3),
      titleLarge: base.titleLarge?.copyWith(
          fontSize: 21, fontWeight: FontWeight.w700, color: fg, height: 1.35),
      titleMedium: base.titleMedium?.copyWith(
          fontSize: 17, fontWeight: FontWeight.w700, color: fg, height: 1.4),
      titleSmall: base.titleSmall?.copyWith(
          fontSize: 15, fontWeight: FontWeight.w700, color: fg, height: 1.4),
      bodyLarge: base.bodyLarge
          ?.copyWith(fontSize: 16, color: fg, height: 1.6),
      bodyMedium: base.bodyMedium
          ?.copyWith(fontSize: 15, color: fg, height: 1.55),
      bodySmall: base.bodySmall
          ?.copyWith(fontSize: 13, color: dim, height: 1.45),
      labelLarge: base.labelLarge?.copyWith(fontWeight: FontWeight.w600, color: fg),
      labelMedium:
          base.labelMedium?.copyWith(fontSize: 13, fontWeight: FontWeight.w600, color: dim),
      labelSmall: base.labelSmall?.copyWith(fontSize: 12, color: dim),
    );
  }
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
