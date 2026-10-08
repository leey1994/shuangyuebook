import 'banshanren.dart';
import 'huangjinwu.dart';
import 'libahao.dart';
import 'minyuan.dart';
import 'quanben.dart';
import 'shenwen.dart';
import 'shuku52.dart';
import 'source.dart';
import 'suduguu.dart';
import 'sushujuan.dart';
import 'yewa.dart';
import 'zzbook.dart';

/// 全部可用书源。
final List<NovelSource> allSources = [
  YewaSource(),
  SuduGuuSource(),
  HuangJinWuSource(),
  Shuku52Source(),
  BanshanrenSource(),
  ShenwenSource(),
  ZzbookSource(),
  SushujuanSource(),
  LibahaoSource(),
  MinyuanSource(),
  QuanbenSource(),
];

NovelSource? sourceById(String id) {
  for (final s in allSources) {
    if (s.id == id) return s;
  }
  return null;
}
