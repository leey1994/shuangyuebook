// 公告版本门槛的回归测试。
//
// 这里栽过一次：min_version 原本被当成「app 版本 ≥ 它才显示」，于是发版公告
// 恰好只有**已经更新**的人看得到，刚发布时全被挡掉，公告一次都不弹。
// 正确语义是反过来：公告写给还没更新的人，升到对应版本后自动不再显示。
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_reader/announcement.dart';

void main() {
  Announcement at(String version) => Announcement(
        id: 'x',
        title: 't',
        body: 'b',
        version: version,
      );

  group('公告版本门槛方向', () {
    test('还没更新的用户要能看到公告（这是发版公告的意义）', () {
      expect(at('1.2.1').shouldShowFor('1.2.0'), isTrue);
      expect(at('1.2.1').shouldShowFor('1.1.0'), isTrue);
      expect(at('2.0.0').shouldShowFor('1.9.9'), isTrue);
    });

    test('升到对应版本后不再显示，免得对着已有功能看更新说明', () {
      expect(at('1.2.1').shouldShowFor('1.2.1'), isFalse);
      expect(at('1.2.1').shouldShowFor('1.3.0'), isFalse);
    });

    test('版本号逐段比较，不是字符串比较', () {
      // 字符串比较下 '1.10.0' < '1.9.0'，这里必须按段比
      expect(at('1.10.0').shouldShowFor('1.9.0'), isTrue);
      expect(at('1.9.0').shouldShowFor('1.10.0'), isFalse);
    });

    test('没写版本号 = 不做门槛，始终展示', () {
      expect(at('').shouldShowFor('0.0.1'), isTrue);
      expect(at('').shouldShowFor('99.0.0'), isTrue);
    });
  });

  group('JSON 解析', () {
    test('min_version 会读进 version 字段', () {
      final n = Announcement.fromJson(const {
        'id': '20261010-3',
        'title': 't',
        'body': 'b',
        'min_version': '1.2.1',
      });
      expect(n.version, '1.2.1');
      expect(n.shouldShowFor('1.2.0'), isTrue);
      expect(n.shouldShowFor('1.2.1'), isFalse);
    });

    test('缺字段时安全降级', () {
      final n =
          Announcement.fromJson(const {'id': 'i', 'title': 't', 'body': 'b'});
      expect(n.version, '');
      expect(n.image, '');
      expect(n.shouldShowFor('1.0.0'), isTrue);
    });
  });
}
