import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 2.5D 分层照片卡。
///
/// 没有真实深度图时的验证做法：把同一张照片拆成"背景层（放大+微模糊）"
/// 与"主体层"，两层按不同速率响应相机与手势偏移，形成前后景视差。
/// 对应开发文档降级矩阵中的"前景/背景双层视差"。
class SpatialPhotoCard extends StatelessWidget {
  const SpatialPhotoCard({
    super.key,
    required this.asset,
    required this.width,
    this.portrait = false,
    this.parallax = Offset.zero,
    this.layerSpread = 1.0,
    this.focusBlur = 0.0,
    this.glow = 0.0,
    this.borderOpacity = 0.65,
  });

  final String asset;
  final double width;
  final bool portrait;

  /// 用户拖动/陀螺仪视差输入，范围约 -1..1
  final Offset parallax;

  /// 分层强度系数（镜头安全区）
  final double layerSpread;

  /// 焦点转移镜头的背景模糊半径
  final double focusBlur;

  /// 金色辉光强度 0..1
  final double glow;
  final double borderOpacity;

  @override
  Widget build(BuildContext context) {
    final double height = portrait ? width * 4 / 3 : width * 3 / 4;
    final double spread = layerSpread;

    Widget backgroundLayer = Transform.scale(
      scale: 1.16,
      child: Transform.translate(
        offset: Offset(parallax.dx * 20 * spread, parallax.dy * 14 * spread),
        child: Image.asset(
          asset,
          fit: BoxFit.cover,
          width: width,
          height: height,
        ),
      ),
    );
    final double blur = 1.6 + focusBlur;
    if (blur > 0.05) {
      backgroundLayer = ImageFiltered(
        imageFilter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: backgroundLayer,
      );
    }

    final Widget subjectLayer = Transform.translate(
      offset: Offset(parallax.dx * 6 * spread, parallax.dy * 4 * spread),
      child: Image.asset(
        asset,
        fit: BoxFit.cover,
        width: width,
        height: height,
      ),
    );

    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.45),
            blurRadius: 30,
            offset: const Offset(0, 16),
          ),
          if (glow > 0)
            BoxShadow(
              color: const Color(0xFFFFC36B).withValues(alpha: 0.35 * glow),
              blurRadius: 46,
              spreadRadius: 2,
            ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Stack(
          fit: StackFit.expand,
          children: [
            backgroundLayer,
            // 主体层：中心区域清晰，通过径向渐隐与背景层融合，模拟主体 Mask
            ShaderMask(
              shaderCallback: (rect) => const RadialGradient(
                radius: 0.85,
                colors: [Colors.white, Colors.white, Colors.transparent],
                stops: [0.0, 0.62, 1.0],
              ).createShader(rect),
              blendMode: BlendMode.dstATop,
              child: subjectLayer,
            ),
            // 边缘压暗，隐藏分层接缝
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  radius: 1.05,
                  colors: [Colors.transparent, Color(0x59000000)],
                  stops: [0.72, 1.0],
                ),
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: Colors.white.withValues(alpha: borderOpacity),
                  width: 1.2,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
