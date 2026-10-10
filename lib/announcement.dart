import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'pet/pet_event.dart';
import 'pet/pet_store.dart';
import 'store.dart';
import 'theme.dart';
import 'update_check.dart' show compareVersion, kAppVersion;

/// 公告数据（源文件：仓库 docs/announcement.json，GitHub Pages / raw 分发）。
/// 发布流程 = 修改该文件并 push；客户端启动 + 周期轮询自动拉取。
class Announcement {
  final String id;
  final String title;
  final String body;
  final String image;
  const Announcement({
    required this.id,
    required this.title,
    required this.body,
    this.image = '',
  });

  factory Announcement.fromJson(Map<String, dynamic> j) => Announcement(
        id: (j['id'] as String? ?? '').trim(),
        title: (j['title'] as String? ?? '').trim(),
        body: (j['body'] as String? ?? '').trim(),
        image: (j['image'] as String? ?? '').trim(),
      );
}

/// 拉取公告 → 与本地已读 id 比对 → 不同则全屏弹出（关闭后记录）。
class NoticeChecker {
  NoticeChecker._();

  static bool _busy = false;
  static const _kSeen = 'noticeId';

  /// 分发地址依次尝试：GitHub Pages（CDN）→ raw → Contents API。
  /// 统一加时间戳参数穿透 CDN 缓存；Accept: raw 让 API 直返文件字节。
  static const _urls = [
    'https://leey1994.github.io/shuangyuebook/announcement.json',
    'https://raw.githubusercontent.com/leey1994/shuangyuebook/main/docs/announcement.json',
    'https://api.github.com/repos/leey1994/shuangyuebook/contents/docs/announcement.json',
  ];

  /// 检查新公告；有未读新公告则全屏显示并等待关闭，返回是否显示过。
  static Future<bool> check(BuildContext context) async {
    if (_busy) return false;
    _busy = true;
    try {
      final n = await _fetch();
      if (n == null || n.id.isEmpty || n.title.isEmpty) return false;
      final sp = await SharedPreferences.getInstance();
      if (sp.getString(_kSeen) == n.id) return false;
      if (!context.mounted) return false;
      PetStore.I.emit(PetAction.notice);
      await Navigator.of(context).push(MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => NoticePage(notice: n),
      ));
      await sp.setString(_kSeen, n.id);
      return true;
    } catch (_) {
      // 网络失败 / 解析失败：静默跳过，不影响正常使用
      return false;
    } finally {
      _busy = false;
    }
  }

  static Future<Announcement?> _fetch() async {
    for (final u in _urls) {
      try {
        final sep = u.contains('?') ? '&' : '?';
        final r = await http.get(
          Uri.parse('$u${sep}t=${DateTime.now().millisecondsSinceEpoch}'),
          headers: {
            'User-Agent': 'shuangyuebook-notice',
            'Accept': 'application/vnd.github.raw',
          },
        ).timeout(const Duration(seconds: 6));
        if (r.statusCode != 200) continue;
        final j = jsonDecode(utf8.decode(r.bodyBytes));
        if (j is! Map<String, dynamic>) continue;
        if (j['enabled'] == false) return null;
        final minV = (j['min_version'] as String? ?? '').trim();
        if (minV.isNotEmpty && compareVersion(kAppVersion, minV) < 0) {
          return null;
        }
        return Announcement.fromJson(j);
      } catch (_) {
        continue; // 该地址不可达 → 换下一个
      }
    }
    return null;
  }
}

/// 全屏公告页：右上角关闭 + 底部「知道了」，关闭即记为已读。
class NoticePage extends StatelessWidget {
  final Announcement notice;
  const NoticePage({super.key, required this.notice});

  @override
  Widget build(BuildContext context) {
    final t = AppStore.I.prefs.theme;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: AppThemes.scaffold(t),
      body: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: IconButton(
                icon: const Icon(Icons.close),
                tooltip: '关闭',
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      notice.title,
                      style: text.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    if (notice.image.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.network(
                          notice.image,
                          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    Text(
                      notice.body,
                      style: text.bodyLarge?.copyWith(height: 1.8),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text('知道了'),
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
