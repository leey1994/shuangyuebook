import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/local/epub_parser.dart';

/// EPUB 多级目录（nav/NCX 嵌套层级）解析自检。
/// 用户反馈「对 EPUB 的多级目录支持不好」——目录树必须拆出卷/章层级。
ArchiveFile _f(String name, String content) {
  final data = utf8.encode(content);
  return ArchiveFile(name, data.length, data);
}

void main() {
  Uint8List epubBytes({required String navDoc, required String opfExtra}) {
    final zip = Archive()
      ..add(_f('mimetype', 'application/epub+zip'))
      ..add(_f('META-INF/container.xml', '''<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>'''))
      ..add(_f('OEBPS/content.opf', '''<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>层级测试</dc:title><dc:creator>作者</dc:creator>
    <dc:identifier id="id">uid-1</dc:identifier>
  </metadata>
  <manifest>
    $opfExtra
    <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
    <item id="c2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine><itemref idref="c1"/><itemref idref="c2"/></spine>
</package>'''))
      ..add(_f('OEBPS/nav.xhtml', navDoc))
      ..add(_f(
          'OEBPS/ch1.xhtml',
          '<html><body><h1>第一章甲</h1><p>正文一</p></body></html>'))
      ..add(_f(
          'OEBPS/ch2.xhtml',
          '<html><body><h1>第二章乙</h1><p>正文二</p></body></html>'));
    return Uint8List.fromList(ZipEncoder().encode(zip));
  }

  const navTwoLevel = '''<html xmlns="http://www.w3.org/1999/xhtml"
      xmlns:epub="http://www.idpf.org/2007/ops"><body>
<nav epub:type="toc"><ol>
  <li><a href="cover.xhtml">第一卷</a><ol>
    <li><a href="ch1.xhtml">第一章 甲</a></li>
    <li><a href="ch2.xhtml">第二章 乙</a></li>
  </ol></li>
</ol></nav></body></html>''';

  const navFlat = '''<html xmlns="http://www.w3.org/1999/xhtml"
      xmlns:epub="http://www.idpf.org/2007/ops"><body>
<nav epub:type="toc"><ol>
  <li><a href="ch1.xhtml">第一章</a></li>
  <li><a href="ch2.xhtml">第二章</a></li>
</ol></nav></body></html>''';

  const navItem =
      '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>';

  test('EPUB3 nav 嵌套 <ol> → 卷(depth0) + 章(depth1)', () {
    final r = EpubParser.parse(epubBytes(navDoc: navTwoLevel, opfExtra: navItem));
    // 卷条目免空正文不进章节表；章 depth=1、标题取目录
    expect(r.chapters.map((c) => (c.title, c.depth)).toList(), [
      ('第一章 甲', 1),
      ('第二章 乙', 1),
    ]);
  });

  test('EPUB2 NCX 嵌套 navPoint → 卷(depth0) + 章(depth1)', () {
    final zip = Archive()
      ..add(_f('META-INF/container.xml', '''<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>'''))
      ..add(_f('OEBPS/content.opf', '''<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>NCX测试</dc:title><dc:creator>作者</dc:creator>
    <dc:identifier id="id">uid-2</dc:identifier>
  </metadata>
  <manifest>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
    <item id="c2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine toc="ncx"><itemref idref="c1"/><itemref idref="c2"/></spine>
</package>'''))
      ..add(_f('OEBPS/toc.ncx', '''<?xml version="1.0"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head><meta name="dtb:uid" content="uid-2"/></head>
  <docTitle><text>NCX测试</text></docTitle>
  <navMap>
    <navPoint id="v1" playOrder="1">
      <navLabel><text>第一卷</text></navLabel>
      <content src="ch1.xhtml"/>
      <navPoint id="c1" playOrder="2">
        <navLabel><text>第一章</text></navLabel><content src="ch1.xhtml"/>
      </navPoint>
      <navPoint id="c2" playOrder="3">
        <navLabel><text>第二章</text></navLabel><content src="ch2.xhtml"/>
      </navPoint>
    </navPoint>
  </navMap>
</ncx>'''))
      ..add(_f(
          'OEBPS/ch1.xhtml',
          '<html><body><h1>正文一</h1><p>甲</p></body></html>'))
      ..add(_f(
          'OEBPS/ch2.xhtml',
          '<html><body><h1>正文二</h1><p>乙</p></body></html>'));

    final r = EpubParser.parse(Uint8List.fromList(ZipEncoder().encode(zip)));
    // 卷条目 ch1 先到先得（depth0=卷「第一卷」），同文件后到的章不覆盖；
    // ch2 取子 navPoint（depth1=章）。
    expect(r.chapters[0].depth, 0);
    expect(r.chapters[0].title, '第一卷');
    expect(r.chapters[1].depth, 1);
    expect(r.chapters[1].title, '第二章');
  });

  test('平铺目录（无嵌套）全部 depth0，不误分层', () {
    final r = EpubParser.parse(epubBytes(navDoc: navFlat, opfExtra: navItem));
    expect(r.chapters.map((c) => c.depth), everyElement(0));
    expect(r.chapters.map((c) => c.title), contains('第一章'));
  });
}
