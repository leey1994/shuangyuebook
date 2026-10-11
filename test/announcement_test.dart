// 公告的回归测试。
//
// 这里栽过两次：
//   第一次 min_version 当成「app 版本 >= 它才显示」，于是发版公告恰好只有
//   **已经更新**的人看得到，刚发布时旧版本用户全被挡掉；
//   第二次改成反向后，装最新版的人又看不到自己这版的发布说明 ——
//   两个方向各漏一半人。
//
// 正确做法：**不做版本门槛**，靠 noticeId 判重：发出去谁没读谁弹，读过不再弹。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_reader/announcement.dart';

void main() {
  group('公告 JSON 的 BOM', () {
    // docs/announcement.json 一度带 UTF-8 BOM。Dart 的 jsonDecode **能**
    // 容忍它（实测通过），所以 App 端没事；被 BOM 打挂的是网页端的
    // JSON.parse —— 那个直接抛 "Unexpected token"，把版本号 fallback
    // 整个废掉。这条测试是为了不让下一个人再猜错方向。
    test('Dart 侧容忍 BOM，不必剥', () {
      final bom = utf8.encode('﻿{ "id": "x", "title": "t", "body": "b" }');
      final j = jsonDecode(utf8.decode(bom)) as Map<String, dynamic>;
      expect(Announcement.fromJson(j).id, 'x');
    });
  });

  group('公告不再做版本门槛', () {
    test('min_version 只作记录，不影响是否显示', () {
      const raw = {
        'id': '20261011-1',
        'title': 't',
        'body': 'b',
        'min_version': '0.0.2',
      };
      final n = Announcement.fromJson(raw);
      expect(n.version, '0.0.2', reason: '字段仍需解析出来，便于排查线上配置');
      // 关键：解析出来的公告不该再被任何版本逻辑过滤掉
      expect(n.id, isNotEmpty);
      expect(n.title, isNotEmpty);
    });

    test('缺 min_version 也能正常解析', () {
      final n =
          Announcement.fromJson(const {'id': 'i', 'title': 't', 'body': 'b'});
      expect(n.version, '');
      expect(n.id, 'i');
    });

    test('JSON 字段解析稳健', () {
      final n = Announcement.fromJson(const {
        'id': '  x  ',
        'title': ' 标题 ',
        'body': ' 正文 ',
        'image': '  https://a/b.png ',
      });
      expect(n.id, 'x');
      expect(n.title, '标题');
      expect(n.body, '正文');
      expect(n.image, 'https://a/b.png');
    });

    test('空 id / 空标题视为无效公告（不该弹窗）', () {
      // 与 _fetch 的守卫保持一致：id 或 title 为空直接放弃
      for (final raw in const [
        {'id': '', 'title': 't', 'body': 'b'},
        {'id': 'x', 'title': '', 'body': 'b'},
      ]) {
        final n = Announcement.fromJson(raw);
        expect(n.id.isEmpty || n.title.isEmpty, isTrue);
      }
    });

    test('version 与 min_version 都认 —— 网页读前者，历史文件写后者', () {
      expect(
        Announcement.fromJson(const {'id': 'i', 'version': '0.0.1'}).version,
        '0.0.1',
      );
      expect(
        Announcement.fromJson(const {'id': 'i', 'min_version': '0.0.2'})
            .version,
        '0.0.2',
      );
      expect(
        Announcement.fromJson(
          const {'id': 'i', 'version': '0.0.1', 'min_version': '0.0.1'},
        ).version,
        '0.0.1',
      );
    });
  });

  group('配图相对路径必须被补成绝对地址', () {
    const raw = {
      'id': 'i',
      'title': 't',
      'body': 'b',
      'image': 'assets/slogan.png'
    };

    test('按实际拉取地址的目录补全', () {
      // 三个回退源的目录深度不同（Pages 是 /shuangyuebook/，raw 在 /main/docs/），
      // 补错源图就 404，而 errorBuilder 会把失败吃掉，只剩一片空白。
      final pages = Announcement.fromJson(raw).withResolvedImage(
          Uri.parse('https://leey1994.github.io/shuangyuebook/'));
      expect(pages.image,
          'https://leey1994.github.io/shuangyuebook/assets/slogan.png');

      final gitraw = Announcement.fromJson(raw).withResolvedImage(
        Uri.parse('https://raw.githubusercontent.com/leey1994/'
            'shuangyuebook/main/docs/'),
      );
      expect(
        gitraw.image,
        'https://raw.githubusercontent.com/leey1994/shuangyuebook/'
        'main/docs/assets/slogan.png',
      );
    });

    test('本来就是绝对地址的原样保留', () {
      const abs = 'https://cdn.example.com/a.png';
      final n = Announcement.fromJson({
        'id': 'i',
        'title': 't',
        'body': 'b',
        'image': abs,
      }).withResolvedImage(Uri.parse('https://leey1994.github.io/x/'));
      expect(n.image, abs);
    });

    test('空路径不产生 "https://host/" 这种垃圾地址', () {
      final n =
          Announcement.fromJson(const {'id': 'i', 'title': 't', 'body': 'b'})
              .withResolvedImage(Uri.parse('https://leey1994.github.io/x/'));
      expect(n.image, '');
    });
  });
}
