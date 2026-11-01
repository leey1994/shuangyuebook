// 「阅读 2.0」书源要明确拒收，不能悄悄当成 3.0 导进来（结构不同，硬导只会得到坏源）。
import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/legado/source_store.dart';

void main() {
  test('2.0 扁平规则被拒收，3.0 嵌套规则正常入库', () async {
    final text = '''
[
  {"bookSourceName":"老源","bookSourceUrl":"https://v2.test",
   "ruleSearchList":"class.book-list@tag.li","ruleSearchName":"tag.a@text",
   "ruleBookContent":"id.content@text"},
  {"bookSourceName":"新源","bookSourceUrl":"https://v3.test",
   "ruleSearch":{"bookList":"class.book-list@tag.li","name":"tag.a@text"},
   "ruleContent":{"content":"id.content@text"}}
]
''';
    final store = SourceStore();
    final r = await store.importFromTextAsync(text);

    expect(r.legado2, 1);
    expect(r.added, 1);
    expect(store.sources.map((s) => s.bookSourceUrl), ['https://v3.test']);
    expect(r.summary, contains('阅读 2.0'));
  });

  test('混写 3.0 嵌套对象的源按 3.0 处理（不被误拒）', () {
    expect(
        looksLikeLegado2({
          'bookSourceUrl': 'x',
          'ruleSearchList': 'class.a@tag.li',
          'ruleSearch': {'bookList': 'class.b@tag.li'},
        }),
        isFalse);
    expect(looksLikeLegado2({'bookSourceUrl': 'x', 'ruleChapterList': 'class.a@tag.li'}),
        isTrue);
  });
}
