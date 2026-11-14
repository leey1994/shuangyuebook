// 可用书源池：「能拿来读」的源，与「登记过的全部源」区分开。
//
// 为什么单独一层：搜索要广（所有源都问一遍，宁可多问），但**阅读链路**
//（打开详情、换源、热榜匹配）必须只用真正能取到正文的源 —— 一个连不上的
// 源混进来，用户看到的就是「换源换了五次还在转圈」。
//
// 判定口径：
//   · 内置固化书源：永远可用（手写适配器，跟着 App 发版，坏了自己就报错）；
//   · 导入书源：体检判为「请求层失败」的排除；搜不到探针词（可疑）和
//     没体检过的都保留 —— 检测误判不该连累阅读，用户仍可在书源管理里
//     手动停用。
library;

import '../legado/source_health.dart';
import '../sources/registry.dart';
import '../sources/source.dart';

/// 参与阅读 / 换源 / 热榜匹配的源。顺序：内置源优先，再按导入顺序。
List<NovelSource> usableSources() {
  final health = SourceHealthStore.shared;
  final out = <NovelSource>[...builtinSources];
  for (final s in importedSources) {
    if (health == null || health.isUsable(s.id)) out.add(s);
  }
  return out;
}

/// 只有内置源（无导入源 / 冷启动时的最小可用集）。
List<NovelSource> builtinOnlySources() => List<NovelSource>.of(builtinSources);
