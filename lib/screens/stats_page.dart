import 'package:flutter/material.dart';

import '../data/format.dart';
import '../data/stats_store.dart';

/// 阅读统计：累计时长、连续天数、读完书数、最近 7 天柱状图。
class StatsPage extends StatelessWidget {
  const StatsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final stats = StatsStore.I;
    return Scaffold(
      appBar: AppBar(title: const Text('阅读记录')),
      body: ListenableBuilder(
        listenable: stats,
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
            ],
          );
        },
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
