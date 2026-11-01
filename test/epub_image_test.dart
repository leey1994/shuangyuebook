// EPUB 插图闭环：解析时抽出的图片要落盘，正文占位标记要改写成可渲染的本地路径，
// 否则用户看到的还是「［插图］」。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/local/epub_parser.dart';
import 'package:shuangyue/sources/local_source.dart';

ArchiveFile _f(String name, List<int> data) =>
    ArchiveFile(name, data.length, data);

void main() {
  test('插图落盘 + 标记改写成绝对路径', () async {
    final dir = Directory.systemTemp.createTempSync('sy_epub_img_');
    addTearDown(() => dir.deleteSync(recursive: true));

    const png = <int>[137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 0];
    final zip = Archive()
      ..add(_f('mimetype', utf8.encode('application/epub+zip')))
      ..add(_f('META-INF/container.xml', utf8.encode('''<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>''')))
      ..add(_f('OEBPS/content.opf', utf8.encode('''<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>插图测试</dc:title>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
    <item id="p1" href="images/p1.png" media-type="image/png"/>
  </manifest>
  <spine><itemref idref="c1"/></spine>
</package>''')))
      ..add(_f('OEBPS/nav.xhtml', utf8.encode('''<html xmlns="http://www.w3.org/1999/xhtml"
 xmlns:epub="http://www.idpf.org/2007/ops"><body>
<nav epub:type="toc"><ol><li><a href="ch1.xhtml">第一章</a></li></ol></nav></body></html>''')))
      ..add(_f('OEBPS/ch1.xhtml', utf8.encode(
          '<html><body><p>前文</p><img src="images/p1.png"/><p>后文</p></body></html>')))
      ..add(_f('OEBPS/images/p1.png', png));

    final epub = File('${dir.path}/book.epub')
      ..writeAsBytesSync(Uint8List.fromList(ZipEncoder().encode(zip)));

    final src = LocalSource(cacheDir: dir);
    final detail = await src.fetchDetail(LocalSource.bookForPath(epub.path));
    final paras = await src.fetchChapter(detail, detail.chapters.first);

    final marker = paras.firstWhere(
        (p) => p.startsWith(EpubParser.imageMarkerPrefix),
        orElse: () => '');
    expect(marker, isNotEmpty, reason: '正文里应保留插图占位');

    final path = marker
        .substring(EpubParser.imageMarkerPrefix.length)
        .replaceAll(EpubParser.imageMarkerSuffix, '');
    expect(File(path).existsSync(), isTrue, reason: '插图应已落盘');
    expect(File(path).readAsBytesSync(), png);
  });
}
