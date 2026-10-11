import 'package:flutter/material.dart';

import '../data/format.dart';
import '../data/stats_store.dart';
import '../legado/source_health.dart';

/// 阅读统计：累计时长、连续天数、读完书数、最近 7 天柱状图、当日书源体检。
class StatsPage extends StatelessWidget {
  const StatsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final stats = StatsStore.I;
    return Scaffold(
      appBar: AppBar(title: const Text('阅读记录')),
      body: ListenableBuilder(
        listenable: Listenable.merge([stats, SourceHealthStore.I]),
        builder: (context, _) {
          final days = stats.recentDays(7);
          var maxSeconds = 1;
          for (final d in days) {
            if (d.$2 > maxSeconds) maxSeconds = d.$2;
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: [
              _totalCard(context, stats),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _miniCard(context,
                        icon: Icons.local_fire_department_rounded,
                        value: '${stats.streak}',
                        unit: '天',
                        label: '连续阅读'),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _miniCard(context,
                        icon: Icons.check_circle_rounded,
                        value: '${stats.finishedBooks}',
                        unit: '本',
                        label: '读完的书'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _weeklyCard(context, days, maxSeconds),
              const SizedBox(height: 12),
              _sourceCard(context),
            ],
          );
        },
      ),
    );
  }

  /// 今日书源体检：多少可用、多少失效，各是谁、为什么。
  Widget _sourceCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final health = SourceHealthStore.I;
    final today = health.today;
    if (today.isEmpty) {
      return Card(
        margin: EdgeInsets.zero,
        child: ListTile(
          leading: Icon(Icons.fact_check_outlined, color: scheme.primary),
          title: const Text('今日书源检测'),
          subtitle: Text(
            health.checkedToday ? '今天没有需要检测的导入书源' : '每天首次启动自动检测一次',
          ),
        ),
      );
    }
    final bad = today.where((h) => !h.ok).toList();
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.fact_check_outlined, size: 20),
                const SizedBox(width: 8),
                const Text('今日书源检测',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                const Spacer(),
                Text('${health.todayOk}/${today.length}',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: bad.isEmpty ? scheme.primary : scheme.error)),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              bad.isEmpty
                  ? '全部可用 · 每天首次启动自动检测'
                  : '${bad.length} 个失效，其余 ${health.todayOk} 个可用',
              style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            // 失效的排前面：这是用户唯一需要动手处理的信息
            for (final h in [...bad, ...today.where((x) => x.ok)])
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      h.ok ? Icons.check_circle : Icons.error_outline,
                      size: 16,
                      color: h.ok ? scheme.primary : scheme.error,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(h.name,
                              style: const TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.w600)),
                          Text(
                            h.ok
                                ? '${h.ms}ms · ${h.books} 条结果'
                                : (h.error ?? '不可用'),
                            style: TextStyle(
                                fontSize: 11,
                                color: h.ok
                                    ? scheme.onSurfaceVariant
                                    : scheme.error),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _totalCard(BuildContext context, StatsStore stats) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(Icons.menu_book_rounded, color: scheme.primary, size: 30),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('累计阅读',
                      style: TextStyle(
                          fontSize: 12, color: scheme.onSurfaceVariant)),
                  const SizedBox(height: 2),
                  Text(
                    formatDuration(stats.totalSeconds),
                    style: const TextStyle(
                        fontSize: 22, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  Text('共 ${stats.readDays} 天有阅读记录',
                      style: TextStyle(
                          fontSize: 11.5, color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _miniCard(
    BuildContext context, {
    required IconData icon,
    required String value,
    required String unit,
    required String label,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
        child: Column(
          children: [
            Icon(icon, color: scheme.primary, size: 22),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(value,
                    style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        height: 1.1)),
                const SizedBox(width: 3),
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(unit,
                      style: TextStyle(
                          fontSize: 11.5, color: scheme.onSurfaceVariant)),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(label,
                style:
                    TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }

  Widget _weeklyCard(
    BuildContext context,
    List<(String, int)> days,
    int maxSeconds,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('最近 7 天',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text('只统计阅读器打开的时间',
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
            const SizedBox(height: 16),
            SizedBox(
              height: 150,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (var i = 0; i < days.length; i++)
                    Expanded(
                      child: _bar(context, days[i], maxSeconds,
                          isToday: i == days.length - 1),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bar(
    BuildContext context,
    (String, int) day,
    int maxSeconds, {
    required bool isToday,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final seconds = day.$2;
    final ratio = (seconds / maxSeconds).clamp(0.0, 1.0);
    final barHeight = seconds <= 0 ? 4.0 : (8 + ratio * 96).toDouble();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3.5),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          SizedBox(
            height: 14,
            child: seconds <= 0
                ? null
                : FittedBox(
                    child: Text(
                      _shortDuration(seconds),
                      style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurfaceVariant),
                    ),
                  ),
          ),
          const SizedBox(height: 2),
          Container(
            height: barHeight,
            decoration: BoxDecoration(
              color: seconds <= 0
                  ? scheme.outlineVariant.withValues(alpha: 0.5)
                  : scheme.primary.withValues(alpha: 0.45 + ratio * 0.5),
              borderRadius: BorderRadius.circular(6),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            isToday ? '今天' : day.$1.substring(8),
            style: TextStyle(
              fontSize: 10,
              fontWeight: isToday ? FontWeight.w700 : FontWeight.w400,
              color: isToday ? scheme.primary : scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  /// 柱状图上方的紧凑时长（与 formatDuration 的长格式区分）。
  static String _shortDuration(int seconds) {
    if (seconds < 60) return '${seconds}s';
    if (seconds < 3600) return '${seconds ~/ 60}m';
    return '${(seconds / 3600).toStringAsFixed(1)}h';
  }
}
