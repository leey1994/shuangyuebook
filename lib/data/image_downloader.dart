// 漫画图片字节下载：书源 header（UA/Cookie/Referer）一条链。
//
// 阅读器与「缓存全书」共用同一条取图链路，避免两处各自维护防盗链头。
import 'dart:typed_data';

import '../legado/cookie_jar.dart';
import '../legado/http_client.dart';
import '../legado/online_book_service.dart';
import '../sources/legado_source.dart';
import '../sources/source.dart';

const String kImageUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

/// 取图片原始字节。[referer] 通常是书籍页地址（多数站点按它豁免防盗链）。
Future<Uint8List> fetchImageBytes(
  String url, {
  required NovelSource src,
  required String referer,
  SourceHttpClient? client,
}) async {
  final headers = <String, String>{
    'User-Agent': kImageUserAgent,
    'Accept': 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
    'Referer': referer,
  };
  if (src is LegadoSource) {
    headers.addAll(OnlineBookService.headerMap(src.source));
    final host = Uri.parse(url).host;
    final ck = LegadoCookieJar.I.getFor(src.source.bookSourceUrl, host);
    if (ck.isNotEmpty) headers['Cookie'] = ck;
  }
  final resp = await (client ?? SourceHttpClient()).get(url, headers: headers);
  if (!resp.ok) throw Exception('图片加载失败（HTTP ${resp.statusCode}）');
  final b = resp.bytes;
  if (b.isEmpty) throw Exception('图片内容为空');
  return Uint8List.fromList(b);
}
