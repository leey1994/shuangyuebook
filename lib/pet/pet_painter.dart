// 桌宠「小墨」的绘制。
//
// 为什么不是十几张位图：那样「各个形态要看起来像同一只」全靠手感，改一次配色
// 就可能画走样。这里改成**一个**参数化画法 —— 阶段只允许改体型与装饰，
// 轮廓和五官位置一律不动。于是不管长到第几形态，那颗朱红印、那对页角耳、
// 那双豆豆眼、顶尖底圆的水滴头都原样保留，认得出是同一只。
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 成长阶段（造型不变，只变胖瘦与装饰）。
enum PetStage {
  drop('墨滴'), // 只有一颗头
  paper('纸兽'), // 长出身体与书页波浪底
  fox('墨狐'), // 拖起一卷墨尾
  spirit('书灵'); // 身侧浮起书页光环

  const PetStage(this.label);

  final String label;
}

/// 情绪。只改五官画法，五官**位置**永远不变。
enum PetMood { calm, cheer, sleep, sad, focus }

const Color kPetInk = Color(0xFF2C3140);
const Color kPetInkSoft = Color(0xFF737B90);
const Color kPetPaper = Color(0xFFF8F3E6);
const Color kPetPaperShade = Color(0xFFE2D7BE);
const Color kPetSeal = Color(0xFFD8454A);

/// 每阶段的身体高度占比（占总高）；[drop] 没有身体。
const List<double> _bodyFraction = [0, 0.30, 0.34, 0.30];

/// 每阶段的整体尺寸（占总高）。养成系的重点就是「看得见地长大」，
/// 所以墨滴必须真的最小，不能只是少画几笔。
const List<double> _sizeScale = [0.70, 0.85, 0.95, 1.0];

/// 页角耳随阶段长大的倍率。
const List<double> _earScale = [0.90, 1.00, 1.08, 1.15];

/// 头含尖端共占多少个 r（尖端在 cyHead 之上 1.62r，圆的底在其下 r）。
const double _headSpan = 2.62;

class PetPainter extends CustomPainter {
  const PetPainter({
    required this.stage,
    required this.mood,
    required this.phase,
    this.squash = 0,
    this.blink = false,
  });

  final PetStage stage;

  final PetMood mood;

  /// 动画相位（秒），由 widget 用 ticker 推进。
  final double phase;

  /// 点击回弹：正数压扁、负数拉伸，范围约 -1..1。
  final double squash;

  /// 眼睛是否闭合（眨眼瞬间）。
  final bool blink;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final h = size.height;
    final cx = size.width / 2;

    final i = stage.index;
    // 按阶段的整体尺寸画，再贴着底边对齐 —— 小的就是真的小
    final hv = h * _sizeScale[i];
    final bh = hv * _bodyFraction[i];
    final r = (hv - bh) / _headSpan;
    final shift = h - hv; // 底对齐，多出来的空间留在上方
    final cyHead = r * 1.62 + shift;
    final bob = math.sin(phase * 1.7) * h * 0.028;
    final breathe = 1 + math.sin(phase * 2.6) * 0.022;

    canvas.save();
    // 以脚底为轴做压扁/拉伸，点击时才有弹性手感
    canvas.translate(cx, h);
    canvas.scale(1 + squash * 0.16, (1 - squash * 0.13) * breathe);
    canvas.translate(-cx, -h);

    final fill = Paint()..color = kPetPaper;
    final shade = Paint()..color = kPetPaperShade;
    final line = Paint()
      ..color = kPetInk
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.0, r * 0.15)
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;

    if (i >= 3) _halo(canvas, cx, cyHead, r, bob);
    if (i >= 2) _tail(canvas, cx, cyHead + r * 0.72, r, bob);
    // 耳朵画在头**之前**：压在头后面长出来，接缝处被头的实心填充盖掉，
    // 不会像画在头上那样把头的轮廓戳出一道缺口
    _ears(canvas, cx, cyHead, r, bob, fill, line);
    if (i >= 1) _body(canvas, cx, cyHead + r * 0.72, r, bh, fill, shade, line);
    _head(canvas, cx, cyHead, r, bob, fill, line);
    _seal(canvas, cx, cyHead, r, i);
    _eyes(canvas, cx, cyHead, r);
    if (i >= 1) _mouth(canvas, cx, cyHead, r);
    if (i >= 3) _pages(canvas, cx, cyHead, r, bob);

    canvas.restore();
  }

  /// 顶尖底圆的水滴头 —— 角色轮廓的根，所有阶段共用。
  void _head(Canvas canvas, double cx, double hy, double r, double bob,
      Paint fill, Paint line) {
    final tip = Offset(cx, hy - r * 1.62 + bob);
    final p = Path()
      ..moveTo(tip.dx, tip.dy)
      ..cubicTo(cx + r * 0.30, hy - r * 1.05 + bob, cx + r, hy - r * 0.55 + bob,
          cx + r, hy + bob)
      // 下半圆：右 → 底 → 左
      ..arcToPoint(Offset(cx - r, hy + bob),
          radius: Radius.circular(r), clockwise: true)
      ..cubicTo(cx - r, hy - r * 0.55 + bob, cx - r * 0.30, hy - r * 1.05 + bob,
          tip.dx, tip.dy)
      ..close();
    canvas.drawPath(p, fill);
    canvas.drawPath(p, line);
  }

  /// 一对页角耳（折角的纸页），随阶段变大但形状不变。
  ///
  /// 关键是让耳**长在头的最宽处往外翘**：贴着水滴上段那条陡边画，耳朵的描边
  /// 会和头的描边叠成一块黑楔子（墨滴阶段尤其明显），看着像裂了。
  void _ears(Canvas canvas, double cx, double hy, double r, double bob,
      Paint fill, Paint line) {
    final s = _earScale[stage.index];
    for (final dir in const [1.0, -1.0]) {
      final p = Path()
        // 耳根伸到头的轮廓内一点，保证连得上（被头的填充盖住）
        ..moveTo(cx + dir * r * 0.55, hy - r * 0.52 + bob)
        ..lineTo(cx + dir * r * 1.40 * s, hy - r * 1.30 * s + bob)
        ..lineTo(cx + dir * r * 1.10 * s, hy - r * 0.24 + bob)
        ..close();
      canvas.drawPath(p, fill);
      canvas.drawPath(p, line);
    }
  }

  /// 身体 + 书页波浪底边（墨滴阶段没有身体）。
  void _body(Canvas canvas, double cx, double by, double r, double bh,
      Paint fill, Paint shade, Paint line) {
    final bw = r * 1.78;
    final top = by - r * 0.34; // 与头重叠，避免出现接缝
    final wave = bw * 0.20;
    final p = Path()
      ..moveTo(cx - bw / 2, top)
      ..lineTo(cx + bw / 2, top)
      ..lineTo(cx + bw / 2, top + bh - wave)
      ..quadraticBezierTo(
          cx + bw * 0.25, top + bh + wave * 0.55, cx, top + bh - wave)
      ..quadraticBezierTo(
          cx - bw * 0.25, top + bh + wave * 0.55, cx - bw / 2, top + bh - wave)
      ..close();
    // 落地阴影
    canvas.drawOval(
      Rect.fromCenter(
          center: Offset(cx, top + bh + wave * 0.30),
          width: bw * 0.95,
          height: math.max(2, r * 0.34)),
      Paint()..color = kPetInk.withValues(alpha: 0.16),
    );
    canvas.drawPath(p, fill);
    // 底部一层暗一档的纸色，做出厚度
    canvas.save();
    canvas.clipPath(p);
    canvas.drawRect(
      Rect.fromLTRB(cx - bw / 2, top + bh * 0.55, cx + bw / 2, top + bh + wave),
      shade,
    );
    canvas.restore();
    canvas.drawPath(p, line);
  }

  /// 墨狐的一卷墨尾。
  void _tail(Canvas canvas, double cx, double by, double r, double bob) {
    final x0 = cx - r * 0.74;
    final y0 = by + r * 0.30 + bob;
    final p = Path()
      ..moveTo(x0, y0)
      ..cubicTo(x0 - r * 0.95, y0 + r * 0.20, x0 - r * 0.85, y0 + r * 1.15,
          x0 - r * 0.10, y0 + r * 0.92);
    canvas.drawPath(
      p,
      Paint()
        ..color = kPetInk
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.4, r * 0.30)
        ..strokeCap = StrokeCap.round,
    );
  }

  /// 书灵身侧的朱色光环。
  void _halo(Canvas canvas, double cx, double hy, double r, double bob) {
    canvas.drawOval(
      Rect.fromCenter(
          center: Offset(cx, hy + r * 0.45 + bob),
          width: r * 2.7,
          height: r * 2.9),
      Paint()
        ..color = kPetSeal.withValues(alpha: 0.16)
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.0, r * 0.12),
    );
  }

  /// 书灵身侧浮动的两片小书页。
  void _pages(Canvas canvas, double cx, double hy, double r, double bob) {
    for (final dir in const [1.0, -1.0]) {
      final fy = hy + r * (0.10 + 0.16 * math.sin(phase * 2 + dir));
      final s = r * 0.42;
      final p = Path()
        ..moveTo(cx + dir * r * 1.30, fy - s / 2 + bob)
        ..lineTo(cx + dir * r * 1.30 + dir * s, fy - s * 0.34 + bob)
        ..lineTo(cx + dir * r * 1.30 + dir * s, fy + s / 2 + bob)
        ..lineTo(cx + dir * r * 1.30, fy + s * 0.30 + bob)
        ..close();
      canvas.drawPath(p, Paint()..color = kPetPaper);
      canvas.drawPath(
        p,
        Paint()
          ..color = kPetInkSoft
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(0.8, r * 0.08),
      );
    }
  }

  /// 额头朱红印 —— 最强身份标识，四个阶段都在同一个位置。
  void _seal(Canvas canvas, double cx, double hy, double r, int i) {
    canvas.drawCircle(
      Offset(cx, hy - r * 0.52),
      r * (0.145 + 0.015 * i),
      Paint()..color = kPetSeal,
    );
  }

  /// 豆豆眼。位置恒定，只改形状表达情绪。
  void _eyes(Canvas canvas, double cx, double hy, double r) {
    final ex = r * 0.38;
    final ey = hy + r * 0.10;
    final er = r * 0.175;
    final closed = blink || mood == PetMood.sleep;

    for (final dir in const [1.0, -1.0]) {
      final c = Offset(cx + dir * ex, ey);
      if (closed) {
        canvas.drawLine(
          Offset(c.dx - er, c.dy),
          Offset(c.dx + er, c.dy),
          Paint()
            ..color = kPetInk
            ..strokeWidth = math.max(1.0, r * 0.11)
            ..strokeCap = StrokeCap.round,
        );
        continue;
      }
      final Path shape;
      switch (mood) {
        case PetMood.cheer:
          // ^ ^：两段折线
          shape = Path()
            ..moveTo(c.dx - er, c.dy + er * 0.5)
            ..lineTo(c.dx, c.dy - er * 0.7)
            ..lineTo(c.dx + er, c.dy + er * 0.5);
        case PetMood.sad:
          shape = Path()
            ..moveTo(c.dx - er, c.dy + er * 0.6)
            ..quadraticBezierTo(
                c.dx, c.dy - er * 0.9, c.dx + er, c.dy + er * 0.6);
        default:
          shape = Path()..addOval(Rect.fromCircle(center: c, radius: er));
      }
      canvas.drawPath(
        shape,
        Paint()
          ..color = kPetInk
          ..style = mood == PetMood.calm ||
                  mood == PetMood.focus ||
                  mood == PetMood.sleep
              ? PaintingStyle.fill
              : PaintingStyle.stroke
          ..strokeWidth = math.max(1.0, r * 0.11)
          ..strokeCap = StrokeCap.round,
      );
      if (mood == PetMood.calm || mood == PetMood.focus) {
        // 一点高光，让眼睛有神
        canvas.drawCircle(
          Offset(c.dx + er * 0.30, c.dy - er * 0.34),
          er * 0.34,
          Paint()..color = Colors.white,
        );
      }
    }
  }

  /// 嘴（墨滴阶段太小不画）。
  void _mouth(Canvas canvas, double cx, double hy, double r) {
    final my = hy + r * 0.50;
    final mw = r * 0.26;
    final p = Paint()
      ..color = kPetInk
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.0, r * 0.10)
      ..strokeCap = StrokeCap.round;
    switch (mood) {
      case PetMood.cheer:
        final path = Path()
          ..moveTo(cx - mw, my - mw * 0.3)
          ..quadraticBezierTo(cx, my + mw * 0.9, cx + mw, my - mw * 0.3);
        canvas.drawPath(path, p);
        // 腮红
        for (final d in const [1.0, -1.0]) {
          canvas.drawOval(
            Rect.fromCenter(
                center: Offset(cx + d * r * 0.66, my + mw * 0.15),
                width: r * 0.26,
                height: r * 0.16),
            Paint()..color = kPetSeal.withValues(alpha: 0.45),
          );
        }
      case PetMood.sad:
        canvas.drawPath(
          Path()
            ..moveTo(cx - mw, my + mw * 0.35)
            ..quadraticBezierTo(cx, my - mw * 0.55, cx + mw, my + mw * 0.35),
          p,
        );
      case PetMood.sleep:
        canvas.drawOval(
            Rect.fromCenter(
                center: Offset(cx, my + mw * 0.2), width: mw, height: mw * 1.2),
            p);
        // 旁边三个小 z
        for (var k = 0; k < 3; k++) {
          final zx = cx + mw * 1.9 + k * mw * 0.5;
          final zy = my - k * mw * 0.7;
          final zs = mw * (0.6 - k * 0.08);
          canvas.drawPath(
            Path()
              ..moveTo(zx, zy)
              ..lineTo(zx + zs, zy)
              ..moveTo(zx + zs, zy)
              ..lineTo(zx, zy + zs)
              ..lineTo(zx + zs, zy + zs),
            Paint()
              ..color = kPetInkSoft
              ..style = PaintingStyle.stroke
              ..strokeWidth = math.max(0.8, r * 0.07)
              ..strokeCap = StrokeCap.round,
          );
        }
      default:
        canvas.drawPath(
          Path()
            ..moveTo(cx - mw * 0.8, my)
            ..quadraticBezierTo(cx, my + mw * 0.7, cx + mw * 0.8, my),
          p,
        );
    }
  }

  @override
  bool shouldRepaint(PetPainter old) =>
      old.stage != stage ||
      old.mood != mood ||
      old.blink != blink ||
      old.squash != squash ||
      // 相位一直在走，动画期间不缓存重绘；静止时（phase 不变）才省一次
      old.phase != phase;
}
