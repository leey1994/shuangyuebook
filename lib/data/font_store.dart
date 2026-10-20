// 在线阅读字体：应用**不内置任何字体文件**，用户选中哪款才从网络下载一次，
// 存到应用支持目录（不随「清理缓存」删除），下载后注册进 Flutter 字体表即刻可用。
//
// 为什么这样做：
//   * 内置一套中文字体就是 8~15 MB，装包会大一倍，而多数用户根本不用；
//   * 网络字体按需下载既能给「要换字体的用户」完整选择，又不多占安装包；
//   * 下载失败/断网时不注册家族名，正文照旧用系统字体，不会出现空字或乱排。
//
// 用法：
//   FontStore.I.warmUpSelected(prefs.fontFamily);   // 进阅读器时预热已选字体
//   await FontStore.I.ensure(font.id);              // 用户点选时下载并注册
//   FontStore.I.activeFont(prefs.fontFamily)        // 取已就绪的字体（否则 null）
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:path_provider/path_provider.dart';

/// 一款可下载的阅读字体。
///
/// [urls] 是同一文件的多个镜像，按顺序尝试（jsDelivr 主站 + fastly 备用）；
/// [bytes] 只用于界面提示体积，不参与校验。
class RemoteFont {
  const RemoteFont({
    required this.id,
    required this.name,
    required this.note,
    required this.urls,
    required this.bytes,
    required this.ext,
    this.fallback = const ['Noto Serif SC', 'SimSun', 'serif'],
  });

  final String id;
  final String name;
  final String note;
  final List<String> urls;
  final int bytes;
  final String ext;

  /// 字体家族名：加 `sy_` 前缀，避免和系统里同名（用户自己装过思源宋体）
  /// 冲突 —— 否则「明明选了却没换」会很莫名其妙。
  String get family => 'sy_$id';

  /// 缺字回退链（生僻字、符号）。
  final List<String> fallback;

  String get sizeLabel => '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  String get fileName => '$id.$ext';
}

/// 下载状态。
enum FontStatus { idle, downloading, ready, failed }

/// 可下载字体清单。
///
/// 只收**能直接拿到 TTF/OTF 文件**的地址：Flutter 的 FontLoader 不认 woff2，
/// 所以 Google Fonts 的网页字体链接不能用。目前三款覆盖「宋 / 黑 / 楷」。
const List<RemoteFont> kRemoteFonts = [
  RemoteFont(
    id: 'noto_serif_sc',
    name: '思源宋体',
    note: '衬线 · 接近纸书印刷体',
    urls: [
      'https://cdn.jsdelivr.net/gh/googlefonts/noto-cjk@main/Serif/SubsetOTF/SC/NotoSerifSC-Regular.otf',
      'https://fastly.jsdelivr.net/gh/googlefonts/noto-cjk@main/Serif/SubsetOTF/SC/NotoSerifSC-Regular.otf',
    ],
    bytes: 11629004,
    ext: 'otf',
  ),
  RemoteFont(
    id: 'noto_sans_sc',
    name: '思源黑体',
    note: '无衬线 · 屏幕清晰',
    urls: [
      'https://cdn.jsdelivr.net/gh/googlefonts/noto-cjk@main/Sans/SubsetOTF/SC/NotoSansSC-Regular.otf',
      'https://fastly.jsdelivr.net/gh/googlefonts/noto-cjk@main/Sans/SubsetOTF/SC/NotoSansSC-Regular.otf',
    ],
    bytes: 8333000,
    ext: 'otf',
    fallback: ['Noto Sans SC', 'PingFang SC', 'Microsoft YaHei', 'sans-serif'],
  ),
  RemoteFont(
    id: 'lxgw_wenkai',
    name: '霞鹜文楷',
    note: '手写楷体 · 有笔锋',
    urls: [
      'https://cdn.jsdelivr.net/gh/lxgw/LxgwWenKai-Lite@main/fonts/TTF/LXGWWenKaiLite-Regular.ttf',
      'https://fastly.jsdelivr.net/gh/lxgw/LxgwWenKai-Lite@main/fonts/TTF/LXGWWenKaiLite-Regular.ttf',
    ],
    bytes: 13946000,
    ext: 'ttf',
    fallback: ['LXGW WenKai', 'KaiTi', 'STKaiti', 'serif'],
  ),
];

/// 字体下载 / 注册中心（单例）。
class FontStore extends ChangeNotifier {
  FontStore._();

  static final FontStore I = FontStore._();

  /// 清单里按 id 取。
  static RemoteFont? byId(String id) {
    for (final f in kRemoteFonts) {
      if (f.id == id) return f;
    }
    return null;
  }

  static bool _looksLikeFont(Uint8List b) {
    if (b.length < 1024) return false;
    // 00 01 00 00（TrueType）/ OTTO（CFF）/ 74 72 75 65（'true'）/ ttcf
    final h = b;
    return (h[0] == 0 && h[1] == 1 && h[2] == 0 && h[3] == 0) ||
        (h[0] == 0x4F && h[1] == 0x54 && h[2] == 0x54 && h[3] == 0x4F) ||
        (h[0] == 0x74 && h[1] == 0x72 && h[2] == 0x75 && h[3] == 0x65) ||
        (h[0] == 0x74 && h[1] == 0x74 && h[2] == 0x63 && h[3] == 0x66);
  }

  @visibleForTesting
  static bool looksLikeFont(Uint8List b) => _looksLikeFont(b);

  Directory? _dir;
  final Set<String> _ready = <String>{};
  final Map<String, FontStatus> _status = <String, FontStatus>{};
  final Map<String, String> _errors = <String, String>{};
  final Map<String, ValueNotifier<double>> _progress = {};
  final Map<String, Future<bool>> _inflight = {};
  int _gen = 0;

  /// 字体表版本号：注册成功一次 +1。阅读器把它并进「排版签名」，
  /// 下载完成的瞬间才会重新分页（否则会一直用旧字体的行高）。
  int get generation => _gen;

  /// 已就绪且与被选 id 一致时返回字体对象，否则 null（调用方据此决定是否
  /// 把家族名塞进 TextStyle）。
  RemoteFont? activeFont(String id) {
    if (id.isEmpty) return null;
    final f = byId(id);
    if (f == null || !_ready.contains(id)) return null;
    return f;
  }

  /// 只给需要的场景用（例如显示当前字体名）。
  RemoteFont? fontOf(String id) => id.isEmpty ? null : byId(id);

  FontStatus statusOf(String id) => _status[id] ?? FontStatus.idle;

  String? errorOf(String id) => _errors[id];

  bool isReady(String id) => _ready.contains(id);

  ValueListenable<double> progressOf(String id) =>
      _progress.putIfAbsent(id, () => ValueNotifier<double>(0));

  /// 已下载的文件（用于「删除」与体积统计）。
  Future<File?> fileOf(RemoteFont f) async {
    final d = await _ensureDir();
    if (d == null) return null;
    final file = File('${d.path}/${f.fileName}');
    return await file.exists() ? file : null;
  }

  Future<Directory?> _ensureDir() async {
    final cached = _dir;
    if (cached != null && await cached.exists()) return cached;
    try {
      final base = await getApplicationSupportDirectory();
      final d = Directory('${base.path}/fonts');
      if (!await d.exists()) await d.create(recursive: true);
      _dir = d;
      return d;
    } catch (_) {
      return null; // 测试环境 / 存储不可用：降级为不下载
    }
  }

  /// 仅测试用：指定字体目录，跳过 path_provider。
  @visibleForTesting
  void debugSetDir(Directory? d) {
    _dir = d;
    _ready.clear();
    _status.clear();
    _errors.clear();
    _inflight.clear();
    _gen = 0;
  }

  /// 启动预热：上次选的就是网络字体时，进阅读器就先把文件备好
  /// （不阻塞阅读，失败就静默保持系统字体）。
  void warmUpSelected(String id) {
    if (id.isEmpty || _ready.contains(id)) return;
    if (statusOf(id) == FontStatus.downloading) return;
    unawaited(ensure(id));
  }

  /// 下载并注册；已在飞行中则共用同一个 Future。返回是否可用。
  Future<bool> ensure(String id) {
    final f = byId(id);
    if (f == null) return Future.value(false);
    if (_ready.contains(id)) return Future.value(true);
    final pend = _inflight[id];
    if (pend != null) return pend;
    final fut = _ensureInner(f);
    _inflight[id] = fut;
    return fut.whenComplete(() => _inflight.remove(id));
  }

  Future<bool> _ensureInner(RemoteFont f) async {
    final dir = await _ensureDir();
    if (dir == null) {
      _fail(f.id, '存储不可用');
      return false;
    }
    final file = File('${dir.path}/${f.fileName}');
    Uint8List? bytes;
    if (await file.exists()) {
      try {
        bytes = await file.readAsBytes();
      } catch (_) {
        bytes = null;
      }
      if (bytes != null && !_looksLikeFont(bytes)) bytes = null; // 坏文件重下
    }
    if (bytes == null) {
      bytes = await _download(f, file);
      if (bytes == null) return false;
    }
    if (!_looksLikeFont(bytes)) {
      _fail(f.id, '文件不是有效字体');
      return false;
    }
    try {
      final loader = FontLoader(f.family)
        ..addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
      await loader.load();
    } catch (_) {
      _fail(f.id, '字体加载失败');
      return false;
    }
    _ready.add(f.id);
    _status[f.id] = FontStatus.ready;
    _errors.remove(f.id);
    _progress.putIfAbsent(f.id, () => ValueNotifier<double>(1)).value = 1;
    _gen++;
    notifyListeners();
    return true;
  }

  /// 依次试镜像；边下边记进度。返回 null = 全部失败。
  Future<Uint8List?> _download(RemoteFont f, File file) async {
    _status[f.id] = FontStatus.downloading;
    _errors.remove(f.id);
    notifyListeners();
    final part = File('${file.path}.part');
    for (final url in f.urls) {
      final progress = _progress.putIfAbsent(f.id, () => ValueNotifier<double>(0));
      progress.value = 0;
      IOSink? sink;
      HttpClient? client;
      try {
        client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 20)
          ..userAgent = 'ShuangYue/1.0';
        final req = await client.getUrl(Uri.parse(url));
        req.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
        final resp = await req.close().timeout(const Duration(seconds: 30));
        if (resp.statusCode != 200) {
          await resp.drain<void>();
          continue;
        }
        final total = resp.contentLength > 0 ? resp.contentLength : f.bytes;
        sink = part.openWrite();
        var got = 0;
        final buf = BytesBuilder(copy: false);
        await for (final chunk in resp.timeout(const Duration(seconds: 120))) {
          sink.add(chunk);
          buf.add(chunk);
          got += chunk.length;
          if (total > 0) progress.value = (got / total).clamp(0.0, 1.0);
        }
        await sink.flush();
        await sink.close();
        sink = null;
        final bytes = buf.takeBytes();
        if (!_looksLikeFont(bytes)) {
          try {
            await part.delete();
          } catch (_) {}
          continue;
        }
        // 先落 .part 再改名：中途被杀不会留下半截字体文件
        await part.rename(file.path);
        progress.value = 1;
        _status[f.id] = FontStatus.idle;
        return bytes;
      } catch (_) {
        // 换下一个镜像
      } finally {
        try {
          await sink?.close();
        } catch (_) {}
        client?.close(force: true);
      }
    }
    try {
      if (await part.exists()) await part.delete();
    } catch (_) {}
    _progress.putIfAbsent(f.id, () => ValueNotifier<double>(0)).value = 0;
    _fail(f.id, '下载失败，换个网络再试');
    return null;
  }

  void _fail(String id, String why) {
    _status[id] = FontStatus.failed;
    _errors[id] = why;
    notifyListeners();
  }

  /// 删除已下载的字体文件（已注册进引擎的那份本次进程内仍可用，重启后消失）。
  Future<void> delete(String id) async {
    final f = byId(id);
    if (f == null) return;
    final file = await fileOf(f);
    if (file != null) {
      try {
        await file.delete();
      } catch (_) {}
    }
    _ready.remove(id);
    _status[id] = FontStatus.idle;
    _errors.remove(id);
    _gen++;
    notifyListeners();
  }
}
