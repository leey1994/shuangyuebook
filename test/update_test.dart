import 'package:flutter_test/flutter_test.dart';
import 'package:novel_reader/update_check.dart';

void main() {
  test('compareVersion 数值分段比较', () {
    expect(compareVersion('v0.1.0', '0.1.0'), 0);
    expect(compareVersion('0.1.1', '0.1.0'), 1);
    expect(compareVersion('0.1.0', '0.2.0'), -1);
    // 数值而非字典序：0.1.10 > 0.1.9
    expect(compareVersion('0.1.10', '0.1.9'), 1);
    // 段数不同按 0 补齐
    expect(compareVersion('0.2', '0.1.9'), 1);
    expect(compareVersion('v0.0.9+3', '0.1.0'), -1);
    expect(compareVersion('V1.0.0', '0.9.9'), 1);
  });
}
