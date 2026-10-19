import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'pet/pet_event.dart';
import 'pet/pet_store.dart';
import 'store.dart';
import 'theme.dart';

/// 公告里的一个可点击按钮（如「网盘下载」）。老版本客户端会忽略这个字段，
/// 只能看到正文里的纯文本网址，所以正文里也要把地址写全。
class AnnouncementLink {
  final String label;
  final String url;

  const AnnouncementLink({required this.label, required this.url});
}

/// 公告数据（源文件：仓库 docs/announcement.json，GitHub Pages / raw 分发）。
/// 发布流程 = 修改该文件并 push；客户端启动 + 周期轮询自动拉取。
class Announcement {
  final String id;
  final String title;
  final String body;
  final String image;

  /// 正文下方的按钮（可空）。用途：GitHub 直连不通时给一条网盘下载线路。
  final List<AnnouncementLink> links;

  /// 这条公告对应的版本号，**仅作记录，不参与显示判断**。
  ///
  /// 曾经拿它做门槛，方向先写反过一次（只有已更新的用户才看得到），改过来后
  /// 又发现：装最新版的人恰恰看不到自己这一版的发布说明 —— 两种方向各漏一半人。
  /// 正确做法就是不做版本门槛，靠 `noticeId` 判重：发出去谁没读谁弹，读过不再弹。
  /// 字段保留只为兼容发布脚本与历史文件。
  final String version;

  const Announcement({
    required this.id,
    required this.title,
    required this.body,
    this.image = '',
    this.links = const [],
    this.version = '',
  });

  /// [fromJson] 之后拿到的公告，其中 image 可能仍是相对路径。
  Announcement withResolvedImage(Uri base) {
    if (image.isEmpty) return this;
    final uri = Uri.parse(image);
    if (uri.hasScheme) return this;
    return Announcement(
      id: id,
      title: title,
      body: body,
      image: base.resolve(image).toString(),
      links: links,
      version: version,
    );
  }

  factory Announcement.fromJson(Map<String, dynamic> j) => Announcement(
        id: (j['id'] as String? ?? '').trim(),
        title: (j['title'] as String? ?? '').trim(),
        body: (j['body'] as String? ?? '').trim(),
        image: (j['image'] as String? ?? '').trim(),
        links: _parseLinks(j['links']),
        // 官网脚本读 `version`，历史文件写的是 `min_version` —— 两个都认，
        // 否则改文件名时 App 端和网页端会各自拿到一半。
        version: (j['version'] as String? ?? j['min_version'] as String? ?? '')
            .trim(),
      );

  static List<AnnouncementLink> _parseLinks(Object? raw) {
    if (raw is! List) return const [];
    final out = <AnnouncementLink>[];
    for (final e in raw) {
      if (e is! Map) continue;
      final label = (e['label'] as String? ?? '').trim();
      final url = (e['url'] as String? ?? '').trim();
      // 只放行 http(s)：公告是远端内容，别让它变成任意 scheme 的启动器。
      if (label.isEmpty || !url.startsWith('http')) continue;
      out.add(AnnouncementLink(label: label, url: url));
    }
    return List.unmodifiable(out);
  }
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
        // 注：Dart 的 jsonDecode 能容忍 UTF-8 BOM（实测过），这里不用剥。
        // 会被 BOM 打挂的是网页端的 JSON.parse —— 那边才有必要剥。
        final j = jsonDecode(utf8.decode(r.bodyBytes));
        if (j is! Map<String, dynamic>) continue;
        if (j['enabled'] == false) return null;
        // 不做版本门槛：靠 noticeId 判重即可。版本门槛两种方向都会漏人，
        // 详见 Announcement.version 的说明。
        //
        // image 常常在 json 里写成 "assets/xxx.png" 这种相对路径，好让人在
        // 仓库里改公告时不用关心部署域名。Image.network 只吃绝对地址，所以
        // 这里按**实际拉到 json 的那个地址**补全 —— 三个回退源各自的目录
        // 深度不同（Pages 是 /shuangyuebook/，raw 是 /main/docs/），用错了
        // 图就 404，而 errorBuilder 会把失败悄悄吃掉，只能看到空白。
        final base = Uri.parse(u).resolve('.');
        return Announcement.fromJson(j).withResolvedImage(base);
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
    final theme = Theme.of(context);
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
                        // 公告配图现在也用来放二维码：限制最大边长，免得
                        // 574px 的原图在窄屏上横向溢出。
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(
                            maxWidth: 320,
                            maxHeight: 320,
                          ),
                          child: Image.network(
                            notice.image,
                            fit: BoxFit.contain,
                            // 公告正文里的链接可能指向上一次发版，图片加载失败
                            // 时留一条灰字，比整块空白更容易排查。
                            errorBuilder: (_, __, ___) => Text(
                              '（配图加载失败）',
                              style: text.bodySmall?.copyWith(
                                color: theme.colorScheme.outline,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    // 可选中复制：正文里会写网盘地址，长按能直接拷走。
                    SelectableText(
                      notice.body,
                      style: text.bodyLarge?.copyWith(height: 1.8),
                    ),
                    if (notice.links.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      for (final l in notice.links)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: SizedBox(
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              icon: const Icon(Icons.open_in_new, size: 18),
                              label: Text(l.label),
                              onPressed: () async {
                                final ok = await launchUrl(
                                  Uri.parse(l.url),
                                  mode: LaunchMode.externalApplication,
                                );
                                if (!ok && context.mounted) {
                                  ScaffoldMessenger.of(context)
                                      .showSnackBar(const SnackBar(
                                    content: Text('打不开链接，可长按正文复制地址'),
                                    duration: Duration(seconds: 2),
                                  ));
                                }
                              },
                            ),
                          ),
                        ),
                    ],
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
