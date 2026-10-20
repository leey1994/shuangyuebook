// 书源批量全链路测试：搜索 → 详情/目录 → 首章正文。
//
// 与 tool/legado_compat_probe_test.dart 的探针同口径（真实网络、双关键词兜底、
// 首章乱码检测），但做成 App 内可调用的服务：供「网络获取并测试」页面使用。
import 'dart:async';

import '../models.dart';
import '../sources/legado_source.dart';
import 'models.dart';
import 'online_book_service.dart';

/// 单源探测结果。
class BatchTestResult {
  BatchTestResult({
    required this.source,
    this.search = 'skip',
    this.error,
    this.resultCount = 0,
    this.sample = '',
    this.detail = 'skip',
    this.chapters = 0,
    this.content = 'skip',
    this.chars = 0,
    this.ms = 0,
  });

  final BookSource source;

  /// ok / empty / err / skip
  final String search;
  final int resultCount;

  /// 搜索命中的第一本书名（人工核对用）。
  final String sample;

  /// ok / empty / err / skip
  final String detail;
  final int chapters;

  /// ok / short / gibberish / err / skip
  final String content;
  final int chars;

  /// 首个失败原因（可直接展示）。
  final String? error;

  final int ms;

  bool get fullOk => search == 'ok' && detail == 'ok' && content == 'ok';

  bool get searchOk => search == 'ok';

  String get verdict {
    if (fullOk) return '完全可用';
    if (searchOk) return '仅搜索可用';
    return '不可用';
  }

  /// 第一个失败环节的可读原因。
  String? get failReason {
    if (search == 'skip') return error ?? '跳过';
    if (search == 'err') return error ?? '搜索请求失败';
    if (search == 'empty') return '搜索无结果';
    if (detail == 'err') return error ?? '目录请求失败';
    if (detail == 'empty') return '目录为空';
    if (content == 'err') return error ?? '正文获取失败';
    if (content == 'short') return '正文过短（<80 字）';
    if (content == 'gibberish') return '正文疑似乱码';
    return null;
  }
}

String _brief(Object e) {
  var s = e.toString();
  if (s.startsWith('Exception: ')) s = s.substring(11);
  return s.length > 90 ? '${s.substring(0, 90)}…' : s;
}

/// 批量测试器：小并发跑全链路，逐源回调进度，支持中途取消。
class BatchTester {
  BatchTester({
    this.concurrency = 2,
    this.timeout = const Duration(seconds: 45),
    this.keywords = const ['斗破苍穹', '凡人修仙传'],
  });

  final int concurrency;
  final Duration timeout;
  final List<String> keywords;

  Future<List<BatchTestResult>> run(
    List<BookSource> sources, {
    void Function(int done, int total, BatchTestResult result)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final results = <BatchTestResult>[];
    if (sources.isEmpty) return results;
    var next = 0;
    Future<void> worker() async {
      while (true) {
        if (isCancelled?.call() ?? false) return;
        final i = next++;
        if (i >= sources.length) return;
        BatchTestResult r;
        try {
          r = await testOne(sources[i]);
        } catch (e) {
          r = BatchTestResult(
            source: sources[i],
            search: 'err',
            error: _brief(e),
          );
        }
        results.add(r);
        onProgress?.call(results.length, sources.length, r);
      }
    }

    final n = concurrency.clamp(1, sources.length);
    await Future.wait([for (var i = 0; i < n; i++) worker()]);
    return results;
  }

  /// 单源全链路：搜索（双关键词兜底）→ 详情/目录 → 首章正文。
  Future<BatchTestResult> testOne(BookSource source) async {
    final sw = Stopwatch()..start();
    if (source.bookSourceType != 0) {
      return BatchTestResult(
        source: source,
        error: '非文本小说源（类型 ${source.bookSourceType}）',
        ms: sw.elapsedMilliseconds,
      );
    }
    if (source.searchUrl?.trim().isEmpty ?? true) {
      return BatchTestResult(
        source: source,
        error: '未配置搜索地址（searchUrl）',
        ms: sw.elapsedMilliseconds,
      );
    }

    final ls = LegadoSource(source);
    final svc = OnlineBookService();

    var books = <Book>[];
    String? sErr;
    try {
      for (final k in keywords) {
        books = await ls.search(k).timeout(timeout);
        if (books.isNotEmpty) break;
      }
    } catch (e) {
      sErr = _brief(e);
    }
    final search = sErr != null ? 'err' : (books.isNotEmpty ? 'ok' : 'empty');
    if (search != 'ok') {
      return BatchTestResult(
        source: source,
        search: search,
        error: sErr ?? '搜索无结果',
        ms: sw.elapsedMilliseconds,
      );
    }

    final book = books.firstWhere(
      (b) => b.url.startsWith('http'),
      orElse: () => books.first,
    );

    var chapters = 0;
    var chapterUrl = '';
    var chapterTitle = '';
    String? dErr;
    try {
      final info = await svc.fetchInfo(source, book.url).timeout(timeout);
      chapters = info.chapters.length;
      if (info.chapters.isNotEmpty) {
        chapterUrl = info.chapters.first.url;
        chapterTitle = info.chapters.first.title;
      }
    } catch (e) {
      dErr = _brief(e);
    }
    final detail = dErr != null ? 'err' : (chapters > 0 ? 'ok' : 'empty');
    if (detail != 'ok') {
      return BatchTestResult(
        source: source,
        search: search,
        resultCount: books.length,
        sample: book.title,
        detail: detail,
        chapters: chapters,
        error: dErr ?? '目录为空',
        ms: sw.elapsedMilliseconds,
      );
    }

    String? cErr;
    var chars = 0;
    var gib = 0;
    try {
      final text = await svc
          .fetchChapterText(
            source,
            chapterUrl,
            book: {
              'name': book.title,
              'author': book.author,
              'bookUrl': book.url,
              'durChapterTitle': chapterTitle,
              'chapterTitle': chapterTitle,
            },
          )
          .timeout(timeout);
      final flat = text.replaceAll(RegExp(r'\s+'), '');
      chars = flat.length;
      gib = RegExp(r'[銆绗鈥锛鐨鏄鐞鎾]').allMatches(flat).length;
    } catch (e) {
      cErr = _brief(e);
    }
    final content = cErr != null
        ? 'err'
        : (chars < 80 ? 'short' : (gib >= 3 ? 'gibberish' : 'ok'));
    return BatchTestResult(
      source: source,
      search: search,
      resultCount: books.length,
      sample: book.title,
      detail: detail,
      chapters: chapters,
      content: content,
      chars: chars,
      error: cErr,
      ms: sw.elapsedMilliseconds,
    );
  }
}
