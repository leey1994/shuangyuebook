import 'huangjinwu.dart';
import 'shuku52.dart';
import 'source.dart';
import 'suduguu.dart';
import 'yewa.dart';

/// 全部可用书源。
final List<NovelSource> allSources = [
  YewaSource(),
  SuduGuuSource(),
  HuangJinWuSource(),
  Shuku52Source(),
];

NovelSource? sourceById(String id) {
  for (final s in allSources) {
    if (s.id == id) return s;
  }
  return null;
}
