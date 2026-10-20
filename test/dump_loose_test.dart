import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/legado/online_repo.dart';

void main() {
  test('dump', () {
    const raw = '[\n// comment\n{"title":"a","url":"/x"}, /* inline */\n'
        "{'title':'multi\nline'}]";
    final loose = OnlineRepo.debugLenientJson(raw) ?? 'NULL';
    File('build/loose2.txt').writeAsStringSync(loose);
    print('WROTE ${loose.length}');
  });
}
