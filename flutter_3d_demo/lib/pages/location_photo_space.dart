// 地点照片 3D 浏览浮层：双击地球仪地标卡后，以"3D 回忆空间"的方式
// 浏览同一拍摄地聚类的全部照片。交互仿 interactive_story_page（简化版）：
// 半环阵列左右拖动环视 + 惯性吸附、点击小卡聚焦、焦点卡 2.5D 分层视差。
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../player/particles.dart';
import '../player/spatial_photo.dart';
import 'photo_map_shared.dart';

/// 全屏深色浮层，浏览 [photos]（同一拍摄地的全部照片，>=1）。
///
/// 与 [PhotoPeekOverlay] 一样作为浮层直接插入页面 Stack：
/// ```dart
/// Stack(children: [
///   GlobePhotoMap(...),
///   if (showSpace)
///     LocationPhotoSpace(
///       photos: cluster.members, // 聚合组全部成员
///       placeName: clusterName,  // 可空字符串
///       onClose: () => setState(() => showSpace = false),
///     ),
/// ])
/// ```
class LocationPhotoSpace extends StatefulWidget {
  const LocationPhotoSpace({
    super.key,
    required this.photos,
    required this.placeName,
    required this.onClose,
  }) : assert(photos.length >= 1, 'photos 至少一张');

  /// 该地点的全部照片（>=1）。只用 thumbAsset 缩略图路径，
  /// 不假设 assets/photos/ 下存在同名高清大图。
  final List<PhotoMapMarker> photos;

  /// 地点名，可空字符串（空时标题显示兜底文案"拍摄地"）。
  final String placeName;

  /// 关闭浮层（点返回按钮 / 点空白区域）。
  final VoidCallback onClose;

  @override
  State<LocationPhotoSpace> createState() => _LocationPhotoSpaceState();
}

class _LocationPhotoSpaceState extends State<LocationPhotoSpace>
    with TickerProviderStateMixin {
  double _focusFloat = 0;
  late final AnimationController _snap;
  double _snapFrom = 0, _snapTo = 0;
  late final AnimationController _time;

  Offset _parallax = Offset.zero;
  late final AnimationController _parallaxReset;
  Offset _parallaxStart = Offset.zero;

  static const double _spacing = 0.26; // 相邻卡片角度间隔（弧度）

  /// 缩略图预缓存窗口（焦点两侧张数）：环阵列本身只构建焦点角 ±2.4rad
  /// 内的卡片（约 ±9 张），预缓存放宽到 ±12 张覆盖快速滑动；窗口外由
  /// Image.asset 按需解码。大地点组（上百张）打开时不再一次性解码全部。
  static const int _precacheWindow = 12;

  int get _count => widget.photos.length;
  int get _focusIndex => _focusFloat.round().clamp(0, _count - 1);
  bool get _single => _count == 1;

  @override
  void initState() {
    super.initState();
    _snap = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 420))
      ..addListener(() {
        setState(() {
          _focusFloat = ui.lerpDouble(_snapFrom, _snapTo,
              Curves.easeOutCubic.transform(_snap.value))!;
        });
      });
    _time = AnimationController(vsync: this, duration: const Duration(seconds: 10))
      ..repeat();
    _parallaxReset = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 350))
      ..addListener(() {
        setState(() {
          _parallax = Offset.lerp(_parallaxStart, Offset.zero,
              Curves.easeOut.transform(_parallaxReset.value))!;
        });
      });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _precacheAround(0);
    });
  }

  /// 预缓存 [center] 前后 [_precacheWindow] 张缩略图（ImageCache 去重，
  /// 重复调用廉价）；窗口外卡片由 _RingThumb 的 Image.asset 按需解码。
  void _precacheAround(int center) {
    final lo = math.max(0, center - _precacheWindow);
    final hi = math.min(_count - 1, center + _precacheWindow);
    for (var i = lo; i <= hi; i++) {
      precacheImage(AssetImage(widget.photos[i].thumbAsset), context);
    }
  }

  @override
  void dispose() {
    _snap.dispose();
    _time.dispose();
    _parallaxReset.dispose();
    super.dispose();
  }

  void _snapToIndex(int index) {
    _snapFrom = _focusFloat;
    _snapTo = index.clamp(0, _count - 1).toDouble();
    _snap.forward(from: 0);
    _precacheAround(_snapTo.round()); // 快速滑动后预热目标窗口
  }

  void _onOrbitDrag(DragUpdateDetails d) {
    _snap.stop();
    setState(() {
      _focusFloat = (_focusFloat - d.delta.dx * 0.012)
          .clamp(-0.6, _count - 1 + 0.6);
    });
  }

  void _onOrbitEnd(DragEndDetails d) {
    final v = -d.velocity.pixelsPerSecond.dx;
    int target = _focusFloat.round();
    if (v.abs() > 400) {
      target += (v / 900).round().clamp(-3, 3);
    }
    _snapToIndex(target);
  }

  void _onParallaxDrag(DragUpdateDetails d) {
    _parallaxReset.stop();
    setState(() {
      _parallax = Offset(
        (_parallax.dx + d.delta.dx / 260).clamp(-1.0, 1.0),
        (_parallax.dy + d.delta.dy / 260).clamp(-1.0, 1.0),
      );
    });
  }

  void _onParallaxEnd(DragEndDetails _) {
    _parallaxStart = _parallax;
    _parallaxReset.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: AnimatedBuilder(
        animation: _time,
        builder: (context, _) {
          return Stack(
            fit: StackFit.expand,
            children: [
              _buildBackground(),
              IgnorePointer(
                child: ParticleField(time: _time.value * 10, opacity: 0.7),
              ),
              if (!_single) _buildOrbitRing(context),
              _buildFocusedCard(context),
              _buildTopBar(),
              _buildBottom(),
            ],
          );
        },
      ),
    );
  }

  /// 深色渐变底（黑 0.92）+ 空白点击关闭（环阵之下的兜底手势层，
  /// 单张照片退化时没有环阵，空白点击由这里接住）
  Widget _buildBackground() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onClose,
      child: const DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xEB000000), Color(0xEB060810), Color(0xF2000000)],
          ),
        ),
      ),
    );
  }

  /// 半环照片阵列：焦点两侧向空间深处排开（单张退化为无环）
  Widget _buildOrbitRing(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final stage = constraints.biggest;
        final center = Offset(stage.width / 2, stage.height * 0.44);
        final radius = stage.width * 0.62;

        final cards = <MapEntry<int, double>>[];
        for (int i = 0; i < _count; i++) {
          if (i == _focusIndex) continue;
          final a = (i - _focusFloat) * _spacing;
          if (a.abs() > 2.4) continue;
          cards.add(MapEntry(i, a));
        }
        // 先画远处（z 小），后画近处
        cards.sort((a, b) => math.cos(a.value).compareTo(math.cos(b.value)));

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onClose, // 环内空白 = 空白区域，点击关闭
          onHorizontalDragUpdate: _onOrbitDrag,
          onHorizontalDragEnd: _onOrbitEnd,
          child: Stack(
            fit: StackFit.expand,
            children: [
              const SizedBox.shrink(),
              for (final e in cards)
                () {
                  final i = e.key;
                  final a = e.value;
                  final z = math.cos(a); // 1 最近 … -1 最远
                  final near = (z + 1) / 2;
                  final w = ui.lerpDouble(72, 150, near)!;
                  final h = w * 3 / 4;
                  final x = center.dx + math.sin(a) * radius;
                  final y = center.dy - near * 26 + a.abs() * 10;
                  final m = Matrix4.identity()
                    ..setEntry(3, 2, 0.0015)
                    ..translateByDouble(x - w / 2, y - h / 2, (z - 1) * 160, 1)
                    ..rotateY(-a * 0.55);
                  return Positioned(
                    left: 0,
                    top: 0,
                    child: Transform(
                      alignment: Alignment.center,
                      transform: m,
                      child: Opacity(
                        opacity: ui.lerpDouble(0.25, 0.95, near)!,
                        child: _RingThumb(
                          asset: widget.photos[i].thumbAsset,
                          width: w,
                          onTap: () => _snapToIndex(i),
                        ),
                      ),
                    ),
                  );
                }(),
            ],
          ),
        );
      },
    );
  }

  /// 焦点大卡：拖动做 2.5D 分层视差 + 弹性回正。
  /// 多卡时横拖属于环视，卡上只接竖拖视差；单卡退化时无环视竞争，接全向拖动。
  Widget _buildFocusedCard(BuildContext context) {
    final photo = widget.photos[_focusIndex];
    return LayoutBuilder(
      builder: (context, constraints) {
        final stage = constraints.biggest;
        final w = stage.width * (_single ? 0.84 : 0.68);
        return Align(
          alignment: const Alignment(0, -0.12),
          child: GestureDetector(
            onPanUpdate: _single ? _onParallaxDrag : null,
            onPanEnd: _single ? _onParallaxEnd : null,
            onVerticalDragUpdate: _single ? null : _onParallaxDrag,
            onVerticalDragEnd: _single ? null : _onParallaxEnd,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 350),
              transitionBuilder: (child, anim) => FadeTransition(
                opacity: anim,
                child: ScaleTransition(
                  scale: Tween(begin: 0.94, end: 1.0).animate(anim),
                  child: child,
                ),
              ),
              child: Transform(
                key: ValueKey(_focusIndex),
                alignment: Alignment.center,
                transform: Matrix4.identity()
                  ..setEntry(3, 2, 0.0012)
                  ..rotateY(_parallax.dx * 0.14)
                  ..rotateX(-_parallax.dy * 0.08),
                child: SpatialPhotoCard(
                  asset: photo.thumbAsset,
                  width: w,
                  parallax: _parallax,
                  layerSpread: 1.15,
                  glow: 0.5,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildTopBar() {
    final title = widget.placeName.isEmpty ? '拍摄地' : widget.placeName;
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.black.withValues(alpha: 0.72), Colors.transparent],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              children: [
                IconButton(
                  tooltip: '返回',
                  icon: const Icon(Icons.arrow_back_ios_new,
                      color: Colors.white, size: 20),
                  onPressed: widget.onClose,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 17,
                              fontWeight: FontWeight.w600)),
                      Text('$_count 张照片',
                          style: TextStyle(
                              fontSize: 12,
                              color: Colors.white.withValues(alpha: 0.55))),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBottom() {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      // 纯展示层：不拦截手势，点按落到底部提示上也算"点空白关闭"
      child: IgnorePointer(
        child: SafeArea(
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 14),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.transparent,
                  Colors.black.withValues(alpha: 0.7),
                ],
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  child: Text(
                    '第 ${_focusIndex + 1} / $_count 张',
                    key: ValueKey(_focusIndex),
                    style: const TextStyle(
                        fontSize: 15, color: Colors.white, letterSpacing: 0.5),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _single ? '点空白关闭' : '左右滑动浏览 · 点空白关闭',
                  style: TextStyle(
                      fontSize: 11,
                      color: Colors.white.withValues(alpha: 0.45)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 环阵列里的小卡：尺寸/透明度随角距离衰减由父级控制，点击转聚焦
class _RingThumb extends StatelessWidget {
  const _RingThumb(
      {required this.asset, required this.width, required this.onTap});

  final String asset;
  final double width;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final h = width * 3 / 4;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: width,
        height: h,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withValues(alpha: 0.5)),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withValues(alpha: 0.45), blurRadius: 12),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.asset(asset, fit: BoxFit.cover),
        ),
      ),
    );
  }
}
