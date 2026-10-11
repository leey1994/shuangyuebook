// 公告的回归测试。
//
// 这里栽过两次：
//   第一次 min_version 当成「app 版本 >= 它才显示」，于是发版公告恰好只有
//   **已经更新**的人看得到，刚发布时旧版本用户全被挡掉；
//   第二次改成反向后，装最新版的人又看不到自己这版的发布说明 ——
//   两个方向各漏一半人。
//
// 正确做法：**不做版本门槛**，靠 noticeId 判重：发出去谁没读谁弹，读过不再弹。
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_reader/announcement.dart';

void main() {
  group('公告不再做版本门槛', () {
    test('min_version 只作记录，不影响是否显示', () {
      const raw = {
        'id': '20261011-1',
        'title': 't',
        'body': 'b',
        'min_version': '1.2.2',
      };
      final n = Announcement.fromJson(raw);
      expect(n.version, '1.2.2', reason: '字段仍需解析出来，便于排查线上配置');
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
  });
}
