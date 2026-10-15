// 我的：小墨陪伴面板 + 阅读统计（7 日柱状图）+ 成就徽章 + 全部设置。
// 原「设置」独立页已整体并入本页，行卡片与面页其余部分保持同一风格。
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/format.dart';
import '../data/shelf_sort.dart';
import '../data/stats_store.dart';
import '../legado/source_store.dart';
import '../pet/pet_event.dart';
import '../pet/pet_painter.dart';
import '../pet/pet_store.dart';
import '../sources/registry.dart';
import '../store.dart';
import '../theme.dart';
import '../tts_voices.dart';
import '../ui/brand.dart';
import '../ui/source/source_manager_page.dart';
import '../update_check.dart';
import 'bookmarks_page.dart';
import 'local_import_page.dart';
import 'stats_page.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen>
    with AutomaticKeepAliveClientMixin {
  int? _cacheBytes;
  bool _checking = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadCacheSize();
  }

  Future<void> _loadCacheSize() async {
    try {
      final n = await AppStore.I.cacheSize();
      if (mounted) setState(() => _cacheBytes = n);
    } catch (_) {
      if (mounted) setState(() => _cacheBytes = 0);
    }
  }

  Future<void> _checkUpdate() async {
    if (_checking) return;
    setState(() => _checking = true);
    try {
      await UpdateChecker.check(context, manual: true);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final store = SourceStore.shared;
    return ListenableBuilder(
      listenable: Listenable.merge([
        AppStore.I,
        StatsStore.I,
        PetStore.I,
        if (store != null) store,
      ]),
      builder: (context, _) {
        final theme = Theme.of(context);
        final narrow = MediaQuery.sizeOf(context).width < kNarrowBreakpoint;
        final body = ListView(
          padding: EdgeInsets.fromLTRB(narrow ? 16 : 22, 0, narrow ? 16 : 22, 28),
          children: [
            _petCard(theme),
            const SizedBox(height: 14),
            _statsCard(theme),
            _badgeSection(theme),
            _sourceSection(theme),
            _readingSection(theme),
            _shelfSection(theme),
            _petSection(theme),
            _cacheSection(theme),
            _aboutSection(theme),
          ],
        );
        return Column(
          children: [
            _appBar(theme, narrow: narrow),
            Expanded(
              child: narrow
                  ? body
                  : Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 680),
                        child: body,
                      ),
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _appBar(ThemeData theme, {required bool narrow}) {
    return SizedBox(
      height: 52,
      child: Padding(
        padding: EdgeInsets.fromLTRB(narrow ? 16 : 22, 6, narrow ? 8 : 14, 0),
        child: Row(
          children: [
            Text('我的',
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontSize: 20, fontWeight: FontWeight.w800)),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- 小墨面板

  Widget _petCard(ThemeData theme) {
    final pet = PetStore.I;
    const stages = PetStage.values;
    final hasNext = pet.stage.index + 1 < stages.length;
    final next = hasNext ? stages[pet.stage.index + 1] : null;
    final remain = ((1 - pet.stageProgress) * 100).round();
    final dark = theme.brightness == Brightness.dark;
    final sub = !pet.enabled
        ? '桌宠已关闭 · 可在下方「桌宠」里重新打开'
        : next != null
            ? '已陪伴 ${pet.companionDays} 天 · 距离「${next.label}」还有 $remain%'
            : '已陪伴 ${pet.companionDays} 天 · 已是最终形态「${pet.stage.label}」';
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: const Alignment(-0.8, -0.8),
          end: const Alignment(0.8, 0.8),
          colors: dark
              ? const [Color(0xFF17241C), Color(0xFF141E18)]
              : const [Color(0xFFE7F1E2), Color(0xFFF4F9F0)],
        ),
        border: Border.all(
            color: dark ? const Color(0xFF22352A) : const Color(0xFFD8E6D2)),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          const Mascot(size: 52),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('小墨 · ${pet.stage.label}',
                    style: const TextStyle(
                        fontSize: 14.5, fontWeight: FontWeight.w800)),
                const SizedBox(height: 3),
                Text(sub,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 11, color: Brand.fg3(context))),
                const SizedBox(height: 8),
                ProgBar(
                  pet.stageProgress,
                  height: 6,
                  track: dark
                      ? const Color(0xFF23302A)
                      : const Color(0xFFD9E7D3),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          BrandBtn('戳一戳',
              style: BrandBtnStyle.outline,
              height: 30,
              radius: 999,
              onTap: _petTap),
        ],
      ),
    );
  }

  void _petTap() {
    final ok = PetStore.I.pet();
    if (!ok) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('小墨在打盹，等会儿再戳')));
    }
  }

  // ---------------------------------------------------------------- 统计

  Widget _statsCard(ThemeData theme) {
    final stats = StatsStore.I;
    final total = stats.totalSeconds;
    final (totalNum, totalUnit) = total >= 3600
        ? ((total / 3600).toStringAsFixed(1), 'h')
        : total >= 60
            ? ('${total ~/ 60}', 'm')
            : ('0', 'm');
    final days = stats.recentDays(7);
    var maxSeconds = 1;
    for (final d in days) {
      if (d.$2 > maxSeconds) maxSeconds = d.$2;
    }
    final dark = theme.brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 15, 6, 12),
      decoration: BoxDecoration(
        color: Brand.card(context),
        border: Border.all(color: Brand.hair(context)),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        children: [
          Row(
            children: [
              _statItem(theme, totalNum, totalUnit, '累计阅读'),
              _statDivider(theme),
              _statItem(theme, '${stats.streak}', '天', '连续天'),
              _statDivider(theme),
              _statItem(theme, '${stats.finishedBooks}', '本', '读完'),
            ],
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (var i = 0; i < days.length; i++) ...[
                  if (i > 0) const SizedBox(width: 11),
                  Expanded(
                    child: Container(
                      height: 6 + (days[i].$2 / maxSeconds) * 44,
                      decoration: BoxDecoration(
                        color: i == days.length - 1
                            ? null
                            : (dark
                                ? const Color(0xFF233029)
                                : const Color(0xFFDDE9DA)),
                        gradient: i == days.length - 1
                            ? const LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [Color(0xFF3E8A50), Brand.green])
                            : null,
                        borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(5),
                            bottom: Radius.circular(2)),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                for (var i = 0; i < days.length; i++) ...[
                  if (i > 0) const SizedBox(width: 11),
                  Expanded(
                    child: Text(
                      _weekdayOf(days[i].$1),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 9.5,
                        fontWeight: i == days.length - 1
                            ? FontWeight.w700
                            : FontWeight.w500,
                        color: i == days.length - 1
                            ? Brand.green
                            : Brand.fg3(context),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _statDivider(ThemeData theme) => Container(
        width: 1,
        height: 30,
        color: Brand.hair(context).withValues(alpha: 0.9),
      );

  Widget _statItem(
      ThemeData theme, String value, String unit, String label) {
    return Expanded(
      child: Column(
        children: [
          Text.rich(TextSpan(
            text: value,
            style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
            children: [
              TextSpan(
                  text: unit,
                  style: const TextStyle(
                      fontSize: 11, fontWeight: FontWeight.w600)),
            ],
          )),
          const SizedBox(height: 3),
          Text(label,
              style: theme.textTheme.labelSmall
                  ?.copyWith(fontSize: 10.5, color: Brand.fg3(context))),
        ],
      ),
    );
  }

  /// 'yyyy-MM-dd' → 周一…周日。
  String _weekdayOf(String dateKey) {
    const names = ['一', '二', '三', '四', '五', '六', '日'];
    final d = DateTime.tryParse(dateKey);
    if (d == null) return '';
    return names[(d.weekday - 1).clamp(0, 6)];
  }

  // ---------------------------------------------------------------- 成就

  Widget _badgeSection(ThemeData theme) {
    final stats = StatsStore.I;
    final preview = kReadingBadges.take(5).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHead('成就',
            padding: const EdgeInsets.fromLTRB(0, 16, 0, 11),
            action: '查看全部 ${kReadingBadges.length} 枚 ›',
            grayAction: true,
            onAction: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const StatsPage()))),
        if (preview.isNotEmpty)
          Row(
            children: [
              for (var i = 0; i < preview.length; i++)
                Expanded(
                  child: _badgeChip(theme, preview[i], i,
                      stats.badges.contains(preview[i].id)),
                ),
            ],
          ),
      ],
    );
  }

  /// 徽章配色（效果图 09）：首读绿 / 连续金 / 夜读蓝 / 听书绿 / 换源蓝。
  (Color, Color) _badgeColors(String id) {
    if (id.startsWith('streak')) return (Brand.gold, Brand.goldSoft);
    if (id.startsWith('hours')) {
      return (const Color(0xFF5B6FA8), const Color(0xFFE8ECF7));
    }
    if (id.startsWith('books')) return (Brand.green, Brand.greenSoft);
    return switch (id) {
      'first' => (Brand.green, Brand.greenSoft),
      'night' => (const Color(0xFF5B6FA8), const Color(0xFFE8ECF7)),
      'tts' => (Brand.green, Brand.greenSoft),
      'switch' => (const Color(0xFF5B6FA8), const Color(0xFFE8ECF7)),
      'source' => (Brand.gold, Brand.goldSoft),
      'local' => (Brand.red, Brand.redSoft),
      _ => (Brand.green, Brand.greenSoft),
    };
  }

  Widget _badgeChip(
      ThemeData theme, ReadingBadge b, int index, bool earned) {
    final (color, soft) = _badgeColors(b.id);
    final dark = theme.brightness == Brightness.dark;
    return Column(
      children: [
        Container(
          height: 46,
          decoration: BoxDecoration(
            color: earned
                ? (dark ? color.withValues(alpha: 0.2) : soft)
                : (dark ? const Color(0xFF1C2422) : const Color(0xFFEFF2ED)),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Center(
            child: Icon(
              earned ? _badgeIcon(b.id) : Icons.lock_outline,
              size: 21,
              color: earned
                  ? color
                  : (dark
                      ? const Color(0xFF5A6660)
                      : const Color(0xFFB9C4B7)),
            ),
          ),
        ),
        const SizedBox(height: 5),
        Text(b.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 9.5,
              fontWeight: earned ? FontWeight.w600 : FontWeight.w500,
              color: earned ? theme.hintColor : Brand.fg3(context),
            )),
      ],
    );
  }

  IconData _badgeIcon(String id) {
    if (id.startsWith('streak')) return Icons.local_fire_department_rounded;
    if (id.startsWith('hours')) return Icons.schedule_rounded;
    if (id.startsWith('books')) return Icons.menu_book_rounded;
    return switch (id) {
      'first' => Icons.auto_stories_rounded,
      'night' => Icons.nightlight_round,
      'tts' => Icons.headphones_rounded,
      'switch' => Icons.swap_horiz_rounded,
      'source' => Icons.travel_explore_rounded,
      'local' => Icons.folder_special_rounded,
      _ => Icons.emoji_events_rounded,
    };
  }

  // ---------------------------------------------------------------- 设置区

  /// 设置分组卡：标题 + 白卡行列表（与「我的」其余卡片同风格）。
  Widget _section(String title, List<Widget> rows) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHead(title,
            padding: const EdgeInsets.fromLTRB(0, 16, 0, 11),
            grayAction: true),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
          decoration: BoxDecoration(
            color: Brand.card(context),
            border: Border.all(color: Brand.hair(context)),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(children: rows),
        ),
      ],
    );
  }

  Widget _divider() =>
      Container(height: 1, color: Brand.hair(context).withValues(alpha: 0.6));

  /// 卡片内的一行：图标（或自定义前置件）+ 标题/副标题 + 右侧值或控件。
  Widget _row({
    IconData? icon,
    Widget? leading,
    required String label,
    String? subtitle,
    String? value,
    Widget? trailing,
    VoidCallback? onTap,
    bool accent = false,
  }) {
    final theme = Theme.of(context);
    final fg3 = Brand.fg3(context);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            if (leading != null)
              leading
            else
              Icon(icon ?? Icons.circle_outlined,
                  size: 19, color: accent ? Brand.green : theme.hintColor),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style:
                          theme.textTheme.bodyMedium?.copyWith(fontSize: 13.5)),
                  if (subtitle != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(subtitle,
                          style: theme.textTheme.labelSmall
                              ?.copyWith(fontSize: 11, color: fg3)),
                    ),
                ],
              ),
            ),
            if (value != null) ...[
              const SizedBox(width: 8),
              Text(value,
                  style: theme.textTheme.labelSmall
                      ?.copyWith(fontSize: 11, color: fg3)),
            ],
            if (trailing != null) ...[
              const SizedBox(width: 4),
              trailing,
            ] else if (onTap != null)
              Icon(Icons.chevron_right,
                  size: 14, color: fg3.withValues(alpha: 0.75)),
          ],
        ),
      ),
    );
  }

  /// 滑块行（字号 / 行距）：标题与当前值一行，滑块占满下一行。
  Widget _sliderRow({
    required IconData icon,
    required String label,
    required String display,
    required double value,
    required double min,
    required double max,
    int? divisions,
    required ValueChanged<double> onChanged,
  }) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 2),
      child: Column(
        children: [
          Row(
            children: [
              Icon(icon, size: 19, color: theme.hintColor),
              const SizedBox(width: 12),
              Expanded(
                child: Text(label,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontSize: 13.5)),
              ),
              Text(display,
                  style: theme.textTheme.labelSmall?.copyWith(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: Brand.green)),
            ],
          ),
          Slider(
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  Widget _switchRow({
    required IconData icon,
    required String label,
    String? subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return _row(
      icon: icon,
      label: label,
      subtitle: subtitle,
      trailing: Switch(
        value: value,
        onChanged: onChanged,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }

  // ---- 书源与内容
  Widget _sourceSection(ThemeData theme) {
    final store = SourceStore.shared;
    return _section('书源与内容', [
      _row(
        icon: Icons.layers_outlined,
        label: '书源管理',
        subtitle: '导入 / 停用 / 导出「阅读 3.0」书源',
        value: '${builtinSources.length} 内置 · ${store?.sources.length ?? 0} 导入',
        accent: true,
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => SourceManagerPage(store: store))),
      ),
      _divider(),
      _row(
        icon: Icons.folder_open_outlined,
        label: '导入本地书',
        subtitle: '从手机 / 电脑目录导入 TXT、EPUB，支持多选与批量扫描',
        onTap: () => showLocalImport(context),
      ),
    ]);
  }

  // ---- 阅读
  Widget _readingSection(ThemeData theme) {
    final store = AppStore.I;
    final p = store.prefs;
    return _section('阅读', [
      _row(
        icon: Icons.auto_stories_outlined,
        label: '翻页方式',
        subtitle: p.pageMode.hint,
        trailing: DropdownButton<PageMode>(
          value: p.pageMode,
          underline: const SizedBox.shrink(),
          items: [
            for (final m in PageMode.values)
              DropdownMenuItem(
                  value: m,
                  child: Text(m.label, style: const TextStyle(fontSize: 13))),
          ],
          onChanged: (v) {
            if (v != null) store.setPageMode(v);
          },
        ),
      ),
      _divider(),
      _row(
        icon: Icons.palette_outlined,
        label: '阅读背景',
        value: readerBgOf(p.bgIndex, p.theme).name,
        trailing: Wrap(
          spacing: 4,
          children: [
            for (var i = 0; i < kReaderBgs.length; i++)
              GestureDetector(
                onTap: () => store.setBgIndex(i),
                child: Container(
                  width: 20,
                  height: 20,
                  margin: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    color: kReaderBgs[i].bg,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: p.bgIndex == i
                          ? Theme.of(context).colorScheme.primary
                          : const Color(0x33888888),
                      width: p.bgIndex == i ? 2 : 1,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
      _divider(),
      _switchRow(
        icon: Icons.article_outlined,
        label: '页眉',
        subtitle: '阅读时顶部显示章节名',
        value: p.showHeader,
        onChanged: store.setShowHeader,
      ),
      _divider(),
      _switchRow(
        icon: Icons.vertical_align_bottom,
        label: '页脚',
        subtitle: '阅读时底部显示时间、页码与电量',
        value: p.showFooter,
        onChanged: store.setShowFooter,
      ),
      _divider(),
      _sliderRow(
        icon: Icons.format_size,
        label: '字号',
        display: '${p.fontSize.round()}',
        value: p.fontSize,
        min: 12,
        max: 32,
        divisions: 20,
        onChanged: store.setFontSize,
      ),
      _divider(),
      _sliderRow(
        icon: Icons.format_line_spacing,
        label: '行距',
        display: p.lineHeight.toStringAsFixed(1),
        value: p.lineHeight,
        min: 1.2,
        max: 2.6,
        divisions: 14,
        onChanged: store.setLineHeight,
      ),
      _divider(),
      _row(
        icon: Icons.dark_mode_outlined,
        label: '主题',
        trailing: SegmentedButton<int>(
          showSelectedIcon: false,
          style: const ButtonStyle(
            visualDensity: VisualDensity.compact,
            textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 12)),
          ),
          segments: const [
            ButtonSegment(value: AppThemes.white, label: Text('锦绣白')),
            ButtonSegment(value: AppThemes.black, label: Text('极光黑')),
          ],
          selected: {
            p.theme == AppThemes.black ? AppThemes.black : AppThemes.white
          },
          onSelectionChanged: (s) {
            store.setTheme(s.first);
            PetStore.I.emit(PetAction.themeChange);
          },
        ),
      ),
      _divider(),
      _row(
        icon: Icons.headphones_outlined,
        label: '听书设置',
        subtitle: '在线音色需要联网，失败会自动回退系统语音',
        value: '${ttsVoiceLabel(p.ttsVoice)} · ${ttsRateLabel(p.ttsRate)}',
        onTap: _openTtsSheet,
      ),
    ]);
  }

  // ---- 书架与记录
  Widget _shelfSection(ThemeData theme) {
    final store = AppStore.I;
    return _section('书架与记录', [
      _row(
        icon: Icons.sort,
        label: '书架排序',
        value:
            '${store.shelfSort.label} · ${store.shelfAscending ? '正序' : '倒序'}',
        onTap: () => _pickSort(context),
      ),
      _divider(),
      _row(
        icon: Icons.bar_chart_outlined,
        label: '阅读记录',
        subtitle: '累计时长、连续天数、最近 7 天',
        onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const StatsPage())),
      ),
      _divider(),
      _row(
        icon: Icons.bookmarks_outlined,
        label: '全部书签',
        subtitle: '跨书查看书签并跳回原文',
        onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const BookmarksPage())),
      ),
    ]);
  }

  /// 书架排序方式 + 升降序选择弹层。
  Future<void> _pickSort(BuildContext context) async {
    final store = AppStore.I;
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final m in ShelfSortMode.values)
              ListTile(
                title: Text(m.label),
                trailing: store.shelfSort == m
                    ? Icon(Icons.check,
                        color: Theme.of(ctx).colorScheme.primary)
                    : null,
                onTap: () {
                  store.setShelfSort(m);
                  Navigator.of(ctx).pop();
                },
              ),
            const Divider(height: 1),
            ListTile(
              leading: Icon(store.shelfAscending
                  ? Icons.arrow_upward
                  : Icons.arrow_downward),
              title: Text(store.shelfAscending ? '当前：正序' : '当前：倒序'),
              onTap: () {
                store.setShelfAscending(!store.shelfAscending);
                Navigator.of(ctx).pop();
              },
            ),
          ],
        ),
      ),
    );
  }

  // ---- 桌宠
  Widget _petSection(ThemeData theme) {
    final pet = PetStore.I;
    final left = pet.toNextStage;
    return _section('桌宠', [
      _row(
        leading: SizedBox(
          width: 30,
          height: 30,
          child: CustomPaint(
            painter: PetPainter(
              stage: pet.stage,
              mood: PetMood.calm,
              phase: 0.6,
            ),
          ),
        ),
        label: '小墨 · ${pet.stage.label}',
        subtitle: left == 0
            ? '已长成书灵，会一直陪着你'
            : '再读 ${(left * kSecondsPerExp ~/ 60) ~/ 60} 小时 '
                '${(left * kSecondsPerExp ~/ 60) % 60} 分钟升到下一形态',
        trailing: Switch(
          value: pet.enabled,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          onChanged: (v) {
            pet.setEnabled(v);
            pet.emit(PetAction.petToggle);
          },
        ),
      ),
      _divider(),
      _row(
        icon: Icons.videocam_outlined,
        label: '屏幕挖孔位置',
        subtitle: '桌宠会绕开摄像头；凑到附近时会探头看一眼',
        trailing: DropdownButton<PunchHole>(
          value: AppStore.I.punchHole,
          underline: const SizedBox.shrink(),
          items: [
            for (final h in PunchHole.values)
              DropdownMenuItem(value: h, child: Text(h.label)),
          ],
          onChanged: (v) => AppStore.I.setPunchHole(v ?? PunchHole.none),
        ),
      ),
    ]);
  }

  // ---- 离线缓存
  Widget _cacheSection(ThemeData theme) {
    final store = AppStore.I;
    final p = store.prefs;
    return _section('离线缓存', [
      _row(
        icon: Icons.download_outlined,
        label: '自动缓存后续章节',
        subtitle: '阅读时在后台自动下载后面的章节，便于离线与加速翻页',
        trailing: DropdownButton<int>(
          value: const [0, 20, 50, 100].contains(p.autoCache)
              ? p.autoCache
              : 50,
          underline: const SizedBox.shrink(),
          items: const [
            DropdownMenuItem(value: 0, child: Text('关闭')),
            DropdownMenuItem(value: 20, child: Text('后 20 章')),
            DropdownMenuItem(value: 50, child: Text('后 50 章')),
            DropdownMenuItem(value: 100, child: Text('后 100 章')),
          ],
          onChanged: (v) => store.setAutoCache(v ?? 50),
        ),
      ),
      _divider(),
      _row(
        icon: Icons.storage_outlined,
        label: '已缓存 ${_cacheBytes == null ? '…' : formatBytes(_cacheBytes!)}',
        subtitle: '在书籍详情页点「下载离线」保存整本书',
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.refresh, size: 18),
              onPressed: _loadCacheSize,
            ),
            TextButton(
              onPressed: _clearCache,
              child: const Text('清除'),
            ),
          ],
        ),
      ),
    ]);
  }

  Future<void> _clearCache() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清除缓存'),
        content: const Text('将删除全部离线章节与封面缓存（不影响书架与阅读进度）'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('清除')),
        ],
      ),
    );
    if (ok != true) return;
    await AppStore.I.clearCache();
    PetStore.I.emit(PetAction.clearCache);
    if (!mounted) return;
    setState(() => _cacheBytes = 0);
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('缓存已清除')));
  }

  // ---- 关于
  Widget _aboutSection(ThemeData theme) {
    return _section('关于', [
      _row(
        icon: Icons.system_update_outlined,
        label: '当前版本 v$kAppVersion',
        subtitle: _checking ? '正在检查更新…' : '发现新版本时启动会自动提示',
        trailing: FilledButton.tonal(
          onPressed: _checking ? null : _checkUpdate,
          child: const Text('检查更新'),
        ),
      ),
      _divider(),
      _row(
        icon: Icons.language,
        label: '静态主页',
        subtitle: 'https://leey1994.github.io/shuangyuebook/',
        onTap: () => launchUrl(
            Uri.parse('https://leey1994.github.io/shuangyuebook/'),
            mode: LaunchMode.externalApplication),
      ),
      _divider(),
      _row(
        icon: Icons.person_outline,
        label: 'Leey',
        subtitle: '邮箱：leey1994@163.com · 仅供个人学习与技术研究使用',
      ),
    ]);
  }

  // ---------------------------------------------------------------- 听书设置

  void _openTtsSheet() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final theme = Theme.of(ctx);
          final prefs = AppStore.I.prefs;
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('听书设置',
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 4),
                  Text('在线音色需要联网，失败会自动回退系统语音',
                      style: theme.textTheme.labelSmall
                          ?.copyWith(fontSize: 11.5, color: Brand.fg3(ctx))),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      PillChip('系统语音',
                          selected: prefs.ttsVoice.isEmpty,
                          onTap: () {
                            AppStore.I.setTtsVoice('');
                            setSheet(() {});
                          }),
                      for (final e in kEdgeVoices.entries)
                        PillChip(
                          e.value.$1.replaceAll('（在线）', ''),
                          selected: prefs.ttsVoice == e.key,
                          onTap: () {
                            AppStore.I.setTtsVoice(e.key);
                            setSheet(() {});
                          },
                        ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      Text('语速',
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(fontSize: 13)),
                      const Spacer(),
                      Text(ttsRateLabel(prefs.ttsRate),
                          style: theme.textTheme.bodyMedium?.copyWith(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: Brand.green)),
                    ],
                  ),
                  Slider(
                    value: prefs.ttsRate.clamp(0.1, 1.0),
                    min: 0.1,
                    max: 1.0,
                    onChanged: (v) {
                      AppStore.I.setTtsRate(v);
                      setSheet(() {});
                    },
                  ),
                  Row(
                    children: [
                      Text('音调',
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(fontSize: 13)),
                      const Spacer(),
                      Text(prefs.ttsPitch.toStringAsFixed(1),
                          style: theme.textTheme.bodyMedium?.copyWith(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: Brand.green)),
                    ],
                  ),
                  Slider(
                    value: prefs.ttsPitch.clamp(0.5, 2.0),
                    min: 0.5,
                    max: 2.0,
                    onChanged: (v) {
                      AppStore.I.setTtsPitch(v);
                      setSheet(() {});
                    },
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
