import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'models.dart';
import 'net.dart';
import 'sources/registry.dart';
import 'sources/source.dart';

/// 封面图（磁盘缓存：首次下载落盘，二次启动直接读文件不走网络；失败回退占位）。
///
/// 同时支持两种来源：
///  - **网络地址**（在线书封面）：下载后落盘缓存；
///  - **本地路径**（EPUB 抽出的封面）：直接读文件，不走网络。
class CoverImage extends StatefulWidget {
  final String? url;
  final double? width;
  final double? height;

  /// 加载中/失败占位（null = 灰底书图标；传 SizedBox.shrink() 则透明）。
  final Widget? placeholder;
  final BoxFit fit;
  final int? cacheWidth;

  /// 无封面时用作占位的插画（null = 灰底书图标）。
  final String? fallbackAsset;

  const CoverImage({
    super.key,
    this.url,
    this.width = 60,
    this.height = 82,
    this.placeholder,
    this.fit = BoxFit.cover,
    this.cacheWidth,
    this.fallbackAsset,
  });

  @override
  State<CoverImage> createState() => _CoverImageState();
}

class _CoverImageState extends State<CoverImage> {
  static const int _maxNetworkDownloads = 6;
  static Directory? _dir;
  static Future<Directory?>? _dirFut;
  // 同一 URL 的下载在进程内共享，避免列表里同一封面并发重复下载
  static final Map<String, Future<File?>> _pending = {};
  static final Map<String, File?> _done = {};
  static final Queue<Completer<void>> _downloadQueue = Queue();
  static int _activeNetworkDownloads = 0;

  /// 封面目录当前占用字节；-1 = 还没扫过（下次遍历时补算）。
  static int _bytes = -1;
  static Future<void>? _sweeping;

  static Future<Directory?> _cacheDir() {
    final f = _dirFut;
    if (f != null) return f;
    final nf = _openCacheDir();
    _dirFut = nf;
    // 打不开（路径服务偶发不可用）就别把这个失败结果常驻，下次再试。
    nf.then((d) {
      if (d == null && identical(_dirFut, nf)) _dirFut = null;
    });
    return nf;
  }

  static Future<Directory?> _openCacheDir() async {
    try {
      final d =
          Directory('${(await getApplicationSupportDirectory()).path}/covers');
      if (!await d.exists()) await d.create(recursive: true);
      return _dir = d;
    } catch (_) {
      return null;
    }
  }

  static Future<void> _touch(File f) async {
    try {
      await f.setLastModified(DateTime.now());
    } catch (_) {}
  }

  /// 封面目录按字节上限 LRU 淘汰：超过 [CoverCache.maxBytes] 时删最久未用的，
  /// 一次清到 80%，避免每下一张就全目录扫一遍。并发调用合并成一次。
  static Future<void> _evictIfNeeded() {
    if (_bytes >= 0 && _bytes <= CoverCache.maxBytes) return Future.value();
    return _sweeping ??= _sweep().whenComplete(() => _sweeping = null);
  }

  static Future<void> _sweep([int limit = CoverCache.maxBytes]) async {
    final d = _dir;
    if (d == null) return;
    try {
      final files = <(File, DateTime, int)>[];
      var total = 0;
      await for (final e in d.list()) {
        if (e is! File) continue;
        try {
          final st = await e.stat();
          files.add((e, st.modified, st.size));
          total += st.size;
        } catch (_) {}
      }
      _bytes = total;
      if (total <= limit) return;
      files.sort((a, b) => a.$2.compareTo(b.$2)); // 旧 → 新
      final target = limit * 8 ~/ 10;
      final gone = <String>{};
      for (final f in files) {
        if (total <= target) break;
        try {
          await f.$1.delete();
          total -= f.$3;
          gone.add(f.$1.path);
        } catch (_) {}
      }
      _bytes = total;
      // 被淘汰的封面从进程内命中表里摘掉，下次出现会重新下载而不是永久占位。
      _done.removeWhere((_, f) => f != null && gone.contains(f.path));
    } catch (_) {}
  }

  File? _file;
  bool _failed = false;

  Widget get _fallback {
    final ph = widget.placeholder;
    if (ph != null) return ph;
    final asset = widget.fallbackAsset;
    if (asset != null) {
      return Image.asset(asset,
          width: widget.width, height: widget.height, fit: widget.fit);
    }
    return Container(
      width: widget.width,
      height: widget.height,
      color: const Color(0xFFE0E0E0),
      child: const Icon(Icons.menu_book, size: 28),
    );
  }

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(covariant CoverImage old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) _resolve();
  }

  String _name(String url) {
    var h = 5381;
    for (final u in url.codeUnits) {
      h = ((h << 5) + h + u) & 0x7fffffff;
    }
    final ext = url.toLowerCase().contains('.png') ? 'png' : 'jpg';
    return '${h.toRadixString(16)}.$ext';
  }

  static Future<void> _acquireDownloadSlot() async {
    if (_activeNetworkDownloads < _maxNetworkDownloads) {
      _activeNetworkDownloads++;
      return;
    }
    final waiter = Completer<void>();
    _downloadQueue.add(waiter);
    await waiter.future;
  }

  static void _releaseDownloadSlot() {
    if (_downloadQueue.isNotEmpty) {
      // 把当前占用的槽位直接交给队首，计数保持不变，避免释放与唤醒之间
      // 新请求插队导致短暂突破并发上限。
      _downloadQueue.removeFirst().complete();
    } else {
      _activeNetworkDownloads--;
    }
  }

  Future<File?> _fetch(String url) async {
    try {
      // 本地路径（EPUB 抽出的封面）：直接读文件，不走网络也不复制
      if (!url.startsWith('http://') && !url.startsWith('https://')) {
        final local = File(url);
        return await local.exists() ? local : null;
      }
      _dir ??= await _cacheDir();
      final d = _dir;
      if (d == null) return null;
      final f = File('${d.path}/${_name(url)}');
      if (await f.exists()) {
        // 命中即刷新 mtime：淘汰按「最后使用时间」而不是「最后下载时间」。
        unawaited(_touch(f));
        return f;
      }
      // 推荐页一次会出现 30 张封面。限制并发下载，避免把连接池、带宽与
      // 图片解码线程瞬间占满；磁盘已缓存的封面不经过此队列。
      await _acquireDownloadSlot();
      try {
        final r = await Net.client
            .get(Uri.parse(url))
            .timeout(const Duration(seconds: 15));
        if (r.statusCode != 200 || r.bodyBytes.length < 500) return null;
        await f.writeAsBytes(r.bodyBytes);
        if (_bytes >= 0) _bytes += r.bodyBytes.length;
        unawaited(_evictIfNeeded());
        return f;
      } finally {
        _releaseDownloadSlot();
      }
    } catch (_) {
      return null;
    }
  }

  Future<void> _resolve() async {
    final url = widget.url;
    _file = null;
    _failed = false;
    if (url == null || url.isEmpty) {
      _failed = true;
      return;
    }
    if (_done.containsKey(url)) {
      _file = _done[url];
      _failed = _file == null;
      return;
    }
    final p = _pending.putIfAbsent(url, () => _fetch(url));
    final f = await p;
    _pending.remove(url);
    _done[url] = f;
    if (!mounted) return;
    setState(() {
      _file = f;
      _failed = f == null;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) return _fallback;
    final f = _file;
    if (f == null) return _fallback;
    // 限制解码尺寸：原图可能上千像素，全尺寸解码会内存暴涨导致闪退
    var cw = widget.cacheWidth;
    if (cw == null) {
      final w = widget.width;
      cw = (w != null ? (w * 2.5).round() : 900).clamp(1, 1048576).toInt();
    }
    final img = Image.file(
      f,
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      cacheWidth: cw,
      errorBuilder: (_, __, ___) => _fallback,
    );
    return img;
  }
}

/// 封面磁盘缓存（`<support>/covers`）的容量治理与统计入口。
///
/// 读写仍由 [CoverImage] 负责；设置页用这里拿占用大小、执行清理，
/// 让「已缓存」统计和「清除缓存」覆盖到封面目录 —— 旧实现只算章节缓存，
/// 封面目录只涨不降。
class CoverCache {
  CoverCache._();

  /// 磁盘上限 64MB（约 1500 张 40KB 封面）。超过后按最后使用时间淘汰。
  static const int maxBytes = 64 << 20;

  /// 封面目录占用字节数（目录不存在 = 0）。
  static Future<int> size() async {
    final d = await _CoverImageState._cacheDir();
    if (d == null) return 0;
    var total = 0;
    try {
      await for (final e in d.list()) {
        if (e is File) total += await e.length();
      }
    } catch (_) {}
    return total;
  }

  /// 删掉全部封面文件并清空进程内命中表（正在下载的会在完成后重新落盘）。
  static Future<void> clear() async {
    _CoverImageState._done.clear();
    final d = await _CoverImageState._cacheDir();
    if (d == null) return;
    try {
      await for (final e in d.list()) {
        if (e is File) {
          try {
            await e.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
    _CoverImageState._bytes = 0;
  }

  /// 测试用：把目录压到 [limit] 字节以下（真机走下载后的自动淘汰）。
  @visibleForTesting
  static Future<void> trimForTest(int limit) async {
    await _CoverImageState._cacheDir();
    await _CoverImageState._sweep(limit);
  }

  /// 测试用：忘掉已缓存的目录与占用计数（换临时目录时调用）。
  @visibleForTesting
  static void resetForTest() {
    _CoverImageState._dir = null;
    _CoverImageState._dirFut = null;
    _CoverImageState._bytes = -1;
    _CoverImageState._sweeping = null;
    _CoverImageState._done.clear();
  }
}

/// 无封面时按书名稳定分配 6 张占位插画之一。
///
/// 用书名哈希而非随机：同一本书每次打开都拿到同一张图，滚动列表也不会闪。
String coverFallbackAsset(String title) {
  var h = 5381;
  for (final u in title.codeUnits) {
    h = ((h << 5) + h + u) & 0x7fffffff;
  }
  return 'assets/images/cover_${(h % 6) + 1}.jpg';
}

/// 描边小标签（状态/书源等，参考样式：圆角描边胶囊）。
class TagPill extends StatelessWidget {
  final String text;
  final bool dim;
  const TagPill(this.text, {super.key, this.dim = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = dim ? theme.hintColor : theme.colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.55)),
      ),
      child: Text(text,
          style: theme.textTheme.labelMedium?.copyWith(
              color: color, fontWeight: FontWeight.w600, fontSize: 12)),
    );
  }
}

/// 横向滚动容器：桌面鼠标滚轮纵滚转横移 + 常驻可拖滚动条。
/// Windows 上横向列表默认不响应滚轮，只靠拖拽容易被认为“划不动”。
class HScrollView extends StatefulWidget {
  final Widget Function(BuildContext context, ScrollController controller)
      builder;
  const HScrollView({super.key, required this.builder});

  @override
  State<HScrollView> createState() => _HScrollViewState();
}

class _HScrollViewState extends State<HScrollView> {
  final ScrollController _c = ScrollController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerSignal: (e) {
        // 纵向滚轮（无横向分量）转为横向滚动；Shift+滚轮自带 dx 由内层滚动器处理
        if (e is PointerScrollEvent &&
            e.scrollDelta.dx == 0 &&
            e.scrollDelta.dy != 0 &&
            _c.hasClients) {
          final p = _c.position;
          _c.jumpTo((_c.offset - e.scrollDelta.dy)
              .clamp(p.minScrollExtent, p.maxScrollExtent)
              .toDouble());
        }
      },
      child: Scrollbar(
        controller: _c,
        thumbVisibility: true,
        child: widget.builder(context, _c),
      ),
    );
  }
}

/// 通用书籍列表项（参考样式：大标题 + 描边标签 + 作者 + 最新章节）。
class BookTile extends StatelessWidget {
  final Book book;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final String? trailingText;
  final Widget? trailing;

  /// 聚合列表中显示所属书源名。
  final bool showSource;

  /// 书单等场景：标题额外加大。
  final bool bigTitle;

  /// 底部附加行（书架放阅读进度条）。
  final Widget? extra;
  const BookTile({
    super.key,
    required this.book,
    this.onTap,
    this.onLongPress,
    this.trailingText,
    this.trailing,
    this.showSource = false,
    this.bigTitle = false,
    this.extra,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final srcName = showSource ? sourceById(book.sourceId)?.name : null;
    final author =
        (book.author != null && book.author!.isNotEmpty) ? book.author! : null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        leading: CoverImage(
          url: book.cover,
          width: 76,
          height: 104,
          fallbackAsset: coverFallbackAsset(book.title),
        ),
        title: Text(
          book.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleMedium?.copyWith(
            fontSize: bigTitle ? 19 : 17,
            fontWeight: FontWeight.w700,
          ),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if ((book.status?.isNotEmpty ?? false) || srcName != null)
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    if (book.status?.isNotEmpty ?? false) TagPill(book.status!),
                    if (srcName != null) TagPill(srcName, dim: true),
                  ],
                ),
              if (author != null) ...[
                const SizedBox(height: 4),
                Text('作者：$author',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall),
              ],
              if (book.latest != null && book.latest!.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text('最新：${book.latest}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall),
              ],
              if (extra != null) ...[const SizedBox(height: 6), extra!],
            ],
          ),
        ),
        trailing: trailing ??
            (trailingText == null
                ? null
                : Text(trailingText!,
                    style: theme.textTheme.titleMedium
                        ?.copyWith(color: theme.colorScheme.primary))),
        onTap: onTap,
        onLongPress: onLongPress,
      ),
    );
  }
}

/// 换源对话框：在其它书源搜索同名书，选择后回调。
/// 返回选中的 (source, book)；取消返回 null。
void showSourceSwitch(
  BuildContext context,
  Book current, {
  required void Function(NovelSource src, Book book) onSelected,
}) {
  final others = allSources.where((s) => s.id != current.sourceId).toList();
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('换源'),
      content: SizedBox(
        width: 420,
        child: FutureBuilder<List<(NovelSource, Book)>>(
          // 并行搜索全部候选源（原来逐个 await 最坏要等 4×20s）
          future: () async {
            final out = <(NovelSource, Book)>[];
            final results = await Future.wait(others.map((s) async {
              try {
                final r = await s.search(current.title);
                return r.isEmpty ? null : (s, r.first);
              } catch (_) {
                return null;
              }
            }));
            for (final r in results) {
              if (r != null) out.add(r);
            }
            return out;
          }(),
          builder: (ctx, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            final items = snap.data ?? [];
            if (items.isEmpty) {
              return const Text('其它书源均未找到该书');
            }
            return ListView(
              shrinkWrap: true,
              children: [
                for (final (s, b) in items)
                  ListTile(
                    leading: CoverImage(url: b.cover, width: 40, height: 56),
                    title: Text(b.title,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                      '${s.name} · ${b.author ?? ""}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () {
                      Navigator.of(ctx).pop();
                      onSelected(s, b);
                    },
                  ),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('取消'),
        ),
      ],
    ),
  );
}
