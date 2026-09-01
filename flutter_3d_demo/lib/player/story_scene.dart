import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../story/story_models.dart';
import 'spatial_photo.dart';

/// 故事场景渲染：根据全局时间定位当前镜头，应用镜头模板对应的相机运动，
/// 并处理镜头间的空间化转场（上一张退入空间、下一张从侧后方进入）。
class StoryScene extends StatelessWidget {
  const StoryScene({
    super.key,
    required this.story,
    required this.time,
    required this.parallax,
  });

  final StorySpec story;
  final double time;

  /// 用户拖动视差，-1..1
  final Offset parallax;

  static const double transitionDuration = 0.9;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final stage = constraints.biggest;
        final loc = story.locate(time);
        final shot = story.chapters[loc.chapterIndex].shots[loc.shotIndex];
        final enterT =
            (loc.localTime / transitionDuration).clamp(0.0, 1.0).toDouble();

        final children = <Widget>[
          // 氛围背景：当前照片的高斯模糊放大铺底
          _AmbientBackdrop(asset: shot.asset),
        ];

        // 转场：渲染上一个镜头的退出动画
        if (enterT < 1.0 && loc.globalShotIndex > 0) {
          final prev = _shotAtGlobal(loc.globalShotIndex - 1);
          if (prev != null) {
            children.add(_buildShot(
              prev,
              stage,
              progress: 1.0,
              exitT: enterT,
              enterT: 1.0,
              parallax: Offset.zero,
            ));
          }
        }

        children.add(_buildShot(
          shot,
          stage,
          progress: loc.progress,
          exitT: 0.0,
          enterT: enterT,
          parallax: parallax,
          time: time,
        ));

        return Stack(fit: StackFit.expand, children: children);
      },
    );
  }

  ShotSpec? _shotAtGlobal(int globalIndex) {
    int acc = 0;
    for (final c in story.chapters) {
      for (final s in c.shots) {
        if (acc == globalIndex) return s;
        acc++;
      }
    }
    return null;
  }

  Widget _buildShot(
    ShotSpec shot,
    Size stage, {
    required double progress,
    required double exitT,
    required double enterT,
    required Offset parallax,
    double time = 0,
  }) {
    if (shot.template == ShotTemplate.cardSpace) {
      return _buildCardSpace(shot, stage, progress, exitT, enterT, time);
    }
    if (shot.template == ShotTemplate.converge) {
      return _buildConverge(shot, stage, progress, exitT, enterT);
    }

    final double cardW = shot.portrait ? stage.width * 0.58 : stage.width * 0.8;
    final double ease = Curves.easeOutCubic.transform(progress);

    // 镜头模板 → 相机运动（作用于整个卡片，等价于相机移动）
    double scale = 1.0;
    double dx = 0;
    double dy = 0;
    double rotY = 0;
    double focusBlur = 0;
    double spread = 1.0;
    switch (shot.template) {
      case ShotTemplate.dollyIn:
        scale = _lerp(1.16, 1.0, ease);
        dy = _lerp(14, 0, ease);
        spread = _lerp(0.4, 1.0, ease);
      case ShotTemplate.parallaxPan:
        dx = _lerp(0.075, -0.075, progress) * stage.width;
        scale = 1.06;
        spread = 1.0 + 0.6 * math.sin(progress * math.pi);
      case ShotTemplate.microOrbit:
        rotY = _lerp(-0.07, 0.07, progress);
        scale = 1.08;
        spread = 1.2;
      case ShotTemplate.focusPull:
        scale = _lerp(1.0, 1.09, ease);
        focusBlur = _lerp(6.0, 0.0, ease);
        spread = _lerp(0.6, 1.0, ease);
      case ShotTemplate.staticParticles:
        scale = _lerp(1.02, 1.06, progress);
        spread = 0.7;
      default:
        break;
    }

    // 互动镜头的用户视差输入（松手后由上层弹性回 0）
    rotY += parallax.dx * 0.12;
    final double rotX = -parallax.dy * 0.07;
    dx += parallax.dx * 10;
    dy += parallax.dy * 8;

    // 进入动画：从侧后方旋转进入
    final enterEase = Curves.easeOutCubic.transform(enterT);
    final enterDx = (1 - enterEase) * stage.width * 0.35;
    final enterRotY = (1 - enterEase) * 0.4;
    final enterScale = _lerp(0.88, 1.0, enterEase);
    final enterOpacity = Curves.easeOut.transform((enterT * 1.6).clamp(0.0, 1.0));

    // 退出动画：退入空间深处
    final exitEase = Curves.easeInCubic.transform(exitT);
    final exitDx = exitEase * -stage.width * 0.22;
    final exitRotY = exitEase * -0.35;
    final exitScale = _lerp(1.0, 0.82, exitEase);
    final exitOpacity = 1 - Curves.easeIn.transform((exitT * 1.4).clamp(0.0, 1.0));

    final matrix = Matrix4.identity()
      ..setEntry(3, 2, 0.0012)
      ..translateByDouble(dx + enterDx + exitDx, dy, 0, 1)
      ..rotateY(rotY + enterRotY + exitRotY)
      ..rotateX(rotX)
      ..scaleByDouble(scale * enterScale * exitScale, scale * enterScale * exitScale, scale * enterScale * exitScale, 1);

    return Center(
      child: Opacity(
        opacity: (enterOpacity * exitOpacity).clamp(0.0, 1.0),
        child: Transform(
          alignment: Alignment.center,
          transform: matrix,
          child: SpatialPhotoCard(
            asset: shot.asset,
            width: cardW,
            portrait: shot.portrait,
            parallax: parallax,
            layerSpread: spread,
            focusBlur: focusBlur,
          ),
        ),
      ),
    );
  }

  /// 空间卡片：多张照片在纵深空间弧形排布，相机缓慢环绕推进（高潮章节）
  Widget _buildCardSpace(
    ShotSpec shot,
    Size stage,
    double progress,
    double exitT,
    double enterT,
    double time,
  ) {
    final assets = [shot.asset, ...shot.extraAssets];
    final n = assets.length;
    final ease = Curves.easeInOut.transform(progress);
    final orbit = _lerp(-0.16, 0.16, ease);
    final push = _lerp(0.92, 1.08, ease);
    final cardW = stage.width * 0.52;

    final enterEase = Curves.easeOutCubic.transform(enterT);
    final exitEase = Curves.easeInCubic.transform(exitT);

    final cards = <Widget>[];
    for (int i = 0; i < n; i++) {
      final rel = i - (n - 1) / 2; // -1, 0, 1
      final baseX = rel * stage.width * 0.42;
      final baseZ = -rel.abs() * 0.35; // 两侧卡片退后
      final baseRotY = -rel * 0.38;
      final floatY = math.sin(time * 0.9 + i * 2.0) * 6;

      final m = Matrix4.identity()
        ..setEntry(3, 2, 0.0012)
        ..rotateY(orbit)
        ..scaleByDouble(push * (1 - exitEase * 0.15) * _lerp(0.85, 1.0, enterEase),
            push * (1 - exitEase * 0.15) * _lerp(0.85, 1.0, enterEase), 1, 1)
        ..translateByDouble(
          baseX + (1 - enterEase) * stage.width * 0.5,
          floatY,
          baseZ * 300,
          1,
        )
        ..rotateY(baseRotY);

      cards.add(
        Transform(
          alignment: Alignment.center,
          transform: m,
          child: Opacity(
            opacity: enterEase * (1 - exitEase),
            child: SpatialPhotoCard(
              asset: assets[i],
              width: cardW,
              glow: 0.8,
              borderOpacity: 0.5,
            ),
          ),
        ),
      );
    }

    return Stack(fit: StackFit.expand, children: [
      const SizedBox.shrink(),
      ...cards.map((c) => Center(child: c)),
    ]);
  }

  /// 片尾：分散的空间卡片向中心收拢，叠成回忆封面
  Widget _buildConverge(
    ShotSpec shot,
    Size stage,
    double progress,
    double exitT,
    double enterT,
  ) {
    final assets = [shot.asset, ...shot.extraAssets];
    final n = assets.length;
    final gather = Curves.easeInOutCubic.transform((progress / 0.72).clamp(0.0, 1.0));
    final coverIn = Curves.easeOut.transform(((progress - 0.55) / 0.45).clamp(0.0, 1.0));
    final cardW = stage.width * 0.46;

    final enterEase = Curves.easeOutCubic.transform(enterT);

    final cards = <Widget>[];
    for (int i = 0; i < n; i++) {
      final angle = (i / n) * math.pi * 2 + 0.5;
      final scatterR = stage.width * 0.52;
      final sx = math.cos(angle) * scatterR;
      final sy = math.sin(angle) * scatterR * 0.5;
      final sz = -0.5 - 0.25 * (i % 3);
      final sRot = (i.isEven ? 1 : -1) * (0.4 + 0.12 * i);

      final x = _lerp(sx, 0, gather);
      final y = _lerp(sy, 0, gather);
      final z = _lerp(sz * 400, -i * 6.0, gather);
      final rot = _lerp(sRot, 0, gather);
      final scale = _lerp(0.62, 1.0, gather) * enterEase;

      final m = Matrix4.identity()
        ..setEntry(3, 2, 0.0012)
        ..translateByDouble(x, y, z, 1)
        ..rotateZ(rot * (1 - gather))
        ..rotateY(_lerp(sRot, 0, gather))
        ..scaleByDouble(scale, scale, scale, 1);

      cards.add(
        Center(
          child: Transform(
            alignment: Alignment.center,
            transform: m,
            child: Opacity(
              opacity: (enterEase * (i == 0 ? 1.0 : 1.0 - coverIn))
                  .clamp(0.0, 1.0),
              child: SpatialPhotoCard(
                asset: assets[i],
                width: cardW,
                glow: gather * 0.6,
              ),
            ),
          ),
        ),
      );
    }

    return Stack(fit: StackFit.expand, children: [
      ...cards,
      // 封面标题
      if (coverIn > 0)
        Center(
          child: Opacity(
            opacity: coverIn,
            child: Transform.translate(
              offset: Offset(0, cardW * 0.75 + 20),
              child: _CoverTitle(story: story),
            ),
          ),
        ),
    ]);
  }

  double _lerp(double a, double b, double t) => a + (b - a) * t;
}

class _CoverTitle extends StatelessWidget {
  const _CoverTitle({required this.story});

  final StorySpec story;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          story.title,
          style: const TextStyle(
            fontSize: 30,
            fontWeight: FontWeight.w700,
            color: Colors.white,
            letterSpacing: 2,
            shadows: [Shadow(color: Colors.black54, blurRadius: 12)],
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '${story.dateLabel} · ${story.photoCount}张照片',
          style: TextStyle(
            fontSize: 14,
            color: Colors.white.withValues(alpha: 0.75),
            letterSpacing: 1.2,
          ),
        ),
      ],
    );
  }
}

/// 氛围背景：当前照片模糊放大铺底，让卡片悬浮在"现场"中
class _AmbientBackdrop extends StatelessWidget {
  const _AmbientBackdrop({required this.asset});

  final String asset;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        ImageFiltered(
          imageFilter: ui.ImageFilter.blur(sigmaX: 40, sigmaY: 40),
          child: Transform.scale(
            scale: 1.3,
            child: Image.asset(asset, fit: BoxFit.cover),
          ),
        ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xCC06090F), Color(0x5506090F), Color(0xE606090F)],
              stops: [0.0, 0.45, 1.0],
            ),
          ),
        ),
      ],
    );
  }
}
