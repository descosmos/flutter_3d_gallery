import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 金色光尘粒子层。位置由时间驱动，确定性强，配合 StoryController 的
/// Ticker 重绘即可，无需自身动画控制器。
class ParticleField extends StatelessWidget {
  const ParticleField({super.key, required this.time, this.opacity = 1.0});

  /// 秒
  final double time;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    if (opacity <= 0.01) {
      return const SizedBox.shrink();
    }
    return RepaintBoundary(
      child: CustomPaint(
        painter: _ParticlePainter(time: time, opacity: opacity),
        size: Size.infinite,
      ),
    );
  }
}

class _ParticlePainter extends CustomPainter {
  _ParticlePainter({required this.time, required this.opacity});

  final double time;
  final double opacity;

  static const int _count = 56;
  static const int _bokehCount = 7;

  double _hash(int i, int salt) {
    final x = math.sin(i * 127.1 + salt * 311.7) * 43758.5453;
    return x - x.floorToDouble();
  }

  @override
  void paint(Canvas canvas, Size size) {
    // 远景大光斑（bokeh）
    for (int i = 0; i < _bokehCount; i++) {
      final bx = _hash(i, 11) * size.width +
          math.sin(time * 0.12 + i * 2.1) * 26;
      final span = size.height + 160;
      final by = span - ((time * (6 + _hash(i, 12) * 8) + _hash(i, 13) * span) % span) - 80;
      final radius = 14 + _hash(i, 14) * 30;
      final twinkle = 0.05 + 0.05 * (0.5 + 0.5 * math.sin(time * 1.2 + i));
      final paint = Paint()
        ..color = Color.fromRGBO(255, 205, 130, twinkle * opacity)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18);
      canvas.drawCircle(Offset(bx, by), radius, paint);
    }

    // 金色细尘，缓慢上浮 + 左右摇摆 + 闪烁
    for (int i = 0; i < _count; i++) {
      final baseX = _hash(i, 1) * size.width;
      final speed = 14 + _hash(i, 2) * 34;
      final span = size.height + 40;
      final y = span - ((time * speed + _hash(i, 3) * span) % span) - 20;
      final x = baseX + math.sin(time * 0.6 + i * 1.3) * (8 + _hash(i, 4) * 16);
      final r = 0.8 + _hash(i, 5) * 1.8;
      final twinkle = 0.25 + 0.75 * (0.5 + 0.5 * math.sin(time * 2.2 + i * 1.7));
      final warm = _hash(i, 6) > 0.25;
      final color = warm
          ? Color.fromRGBO(255, 214, 140, 0.75 * twinkle * opacity)
          : Color.fromRGBO(190, 220, 255, 0.6 * twinkle * opacity);
      canvas.drawCircle(Offset(x, y), r, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(_ParticlePainter oldDelegate) =>
      oldDelegate.time != time || oldDelegate.opacity != opacity;
}
