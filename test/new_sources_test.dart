// 新增原生书源的解析逻辑离线单测（网络路径由 tool/native_src_probe_test.dart 实测）。
import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/dom.dart';
import 'package:shuangyue/sources/douyinxs.dart';
import 'package:shuangyue/sources/gdbzkz.dart';
import 'package:shuangyue/sources/sanyt.dart';
import 'package:shuangyue/sources/source.dart';
import 'package:shuangyue/sources/sudugu_cc.dart';

void main() {
  test('chapterLinks：倒序目录自动校正为升序', () {
    final doc = parseHtml('''
      <div class="listmain"><dl>
        <dd><a href="/b/9528223.html">正文 分卷_第325章：大结局</a></dd>
        <dd><a href="/b/9528222.html">正文 分卷_第324章：不死不休</a></dd>
        <dd><a href="/b/1.html">正文 分卷_第1章：开始</a></dd>
      </dl></div>
    ''');
    final chapters = chapterLinks(doc, '.listmain dl dd a', 'http://x.com/');
    expect(chapters.length, 3);
    expect(chapters.first.title, contains('第1章'));
    expect(chapters.last.title, contains('第325章'));
    expect(chapters.first.url, 'http://x.com/b/1.html');
  });

  test('chapterLinks：升序目录保持原序、去重', () {
    final doc = parseHtml('''
      <ul><li><a href="/a/1.shtml">第一章 开始</a></li>
      <li><a href="/a/2.shtml">第二章 继续</a></li>
      <li><a href="/a/2.shtml">第二章 继续</a></li></ul>
    ''');
    final chapters = chapterLinks(doc, 'li a', 'http://x.com/toc/');
    expect(chapters.length, 2);
    expect(chapters.first.title, '第一章 开始');
    expect(chapters.last.url, 'http://x.com/a/2.shtml');
  });

  test('鬼吹灯：正文滤掉站名广告行', () {
    final doc = parseHtml('''
      <div id="content" class="showtxt">一秒记住【800♂小÷说◎网 .】，精彩无弹窗免费阅读！<br/>
      萧炎纵身而起，朗声叫到道：“是，师傅！”<br/>
      天辰也不迟疑。</div>
    ''');
    final paras = GdbzkzSource().contentOf(doc, 'http://x.com/a/1.html');
    expect(paras.length, 2);
    expect(paras.first, startsWith('萧炎'));
  });

  test('抖音小说：正文丢掉首段章节标题', () {
    final doc = parseHtml('''
      <article id="content" class="content">
        <p> 第639章 仪式开始 </p>
        <p>“你觉得我是傻子吗？”</p>
      </article>
    ''');
    final paras = DouyinxsSource().contentOf(doc, 'http://x.com/a/1.html');
    expect(paras.length, 1);
    expect(paras.single, startsWith('“你觉得'));
  });

  test('若雨中文：手打中占位章抛错不缓存', () {
    final doc = parseHtml('''
      <div id="BookText"><div id="content_tip"><b>最新网址：www.3yt.info</b></div>
      RT。<br/>《斗破苍穹》新书元尊已在起点上传。<br/>正在手打中，请稍等片刻，<br/>
      内容更新后，请重新刷新页面，即可获取最新更新！</div>
    ''');
    expect(() => SanytSource().contentOf(doc, 'http://x.com/a/1.shtml'),
        throwsException);
  });

  test('若雨中文：正文正常提取、去掉 content_tip', () {
    final doc = parseHtml('''
      <div id="BookText"><div id="content_tip"><b>最新网址：www.3yt.info</b></div>
      “斗之力，三段！”望着测验魔石碑上面闪亮得甚至有些刺眼的五个大字，
      少年面无表情，唇角有着一抹自嘲，紧握的手掌因为大力，而导致略微尖锐的指甲深深地刺进了掌心之中。<br/>
      斗之力，三段。级别：低级。</div>
    ''');
    final paras = SanytSource().contentOf(doc, 'http://x.com/a/1.shtml');
    expect(paras.any((p) => p.contains('最新网址')), isFalse);
    expect(paras.first, contains('斗之力'));
  });

  test('伪速读谷：库内坏书的正文双重编码可还原（真样本）', () {
    // 真样本：/1933/ 章节页 .con 段落（库内数据坏成 GBK 乱码，站点自己发的）
    final doc = parseHtml('<div class="con">銆銆鈥滄枟涔嬪姏锛屼笁娈碉紒鈥</div>');
    final paras = SuduguCcSource()
        .contentOf(doc, 'https://www.sudugu.cc/1933/1639714.html');
    expect(paras.single, contains('斗之力，三段'));
    expect(RegExp(r'[銆绗鈥锛鐨鏄]').hasMatch(paras.single), isFalse);
  });

  test('伪速读谷：正常书正文原样通过、不误伤', () {
    final doc = parseHtml('<div class="con">他现在，才十岁。</div>');
    final paras = SuduguCcSource()
        .contentOf(doc, 'https://www.sudugu.cc/1776/1490986.html');
    expect(paras.single, '他现在，才十岁。');
  });
}
